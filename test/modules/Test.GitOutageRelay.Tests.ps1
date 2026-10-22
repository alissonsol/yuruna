<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42d6fef3-6ad4-49be-88bf-13de72c99714
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test git outage qualification
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    $script:relayRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:bare = Join-Path $TestDrive 'framework.git'
    $source = Join-Path $TestDrive 'source'
    $null = New-Item -ItemType Directory $source
    & git -C $source init --quiet --initial-branch main
    & git -C $source -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet --allow-empty -m 'outage fixture'
    $script:sha = ([string](& git -C $source rev-parse HEAD)).Trim()
    & git clone --quiet --bare $source $script:bare
    if ($LASTEXITCODE) { throw 'Could not create the native Git outage fixture.' }
    $script:control = Join-Path $TestDrive 'control.json'
    $script:evidence = Join-Path $TestDrive 'evidence.json'
    $script:config = Join-Path $TestDrive 'fixture.json'
    [IO.File]::WriteAllText($script:control, '{"mode":"reset"}')
    @{repositories=@{'alissonsol/yuruna'=$script:bare};controlPath=$script:control;evidencePath=$script:evidence} |
        ConvertTo-Json | Set-Content $script:config
    $python = Get-Command python3,python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $python) { throw 'The native outage relay requires Python 3.' }
    $start = [Diagnostics.ProcessStartInfo]::new($python.Source)
    foreach ($argument in @((Join-Path $script:relayRoot 'tools/git_mirror_outage_fixture.py'),'--config',$script:config,'--exit-on-stdin-close')) { $start.ArgumentList.Add($argument) }
    $start.UseShellExecute=$false; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true; $start.RedirectStandardInput=$true
    $script:relay = [Diagnostics.Process]::Start($start)
    $script:relayErrors = $script:relay.StandardError.ReadToEndAsync()
    $line = $script:relay.StandardOutput.ReadLineAsync()
    if (-not $line.Wait(10000)) { throw 'Outage relay did not become ready.' }
    $script:ready = $line.GetAwaiter().GetResult() | ConvertFrom-Json
    if (-not $script:ready.baseURL) { throw 'Outage relay returned no URL.' }
    function Invoke-RelayGit {
        param([string[]]$Arguments)
        $clear = @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -like 'GIT_*' -or $_ -match '^(?i)(http|https|all)_proxy$' })
        Invoke-BoundedNativeCommand -FilePath git -ArgumentList (@('-c','credential.helper=','-c','http.proxy=')+$Arguments) `
            -TimeoutSeconds 8 -RemoveEnvironmentVariable $clear -Environment @{GIT_CONFIG_NOSYSTEM='1';GIT_CONFIG_GLOBAL=$(if($IsWindows){'NUL'}else{'/dev/null'});GIT_TERMINAL_PROMPT='0'}
    }
    function Set-RelayMode {
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$Mode)
        if (-not $PSCmdlet.ShouldProcess($script:control,'Change fixture connectivity')) { return }
        $temporary = $script:control+'.tmp'
        [IO.File]::WriteAllText($temporary, (@{mode=$Mode}|ConvertTo-Json -Compress))
        [IO.File]::Move($temporary,$script:control,$true)
        $until = [DateTime]::UtcNow.AddSeconds(3)
        do {
            if (Test-Path $script:evidence) {
                $current = Get-Content $script:evidence -Raw | ConvertFrom-Json
                if ($current.transitions[-1].mode -eq $Mode) { return }
            }
            Start-Sleep -Milliseconds 20
        } while ([DateTime]::UtcNow -lt $until)
        throw "Relay never observed $Mode."
    }
    function Test-RelayProbe {
        $client = [Net.Sockets.TcpClient]::new()
        try { $null=$client.ConnectAsync('127.0.0.1',([uri]$script:ready.probeEndpoint).Port).GetAwaiter().GetResult(); return $true }
        catch { return $false } finally { $client.Dispose() }
    }
}

AfterAll {
    if ($script:relay -and -not $script:relay.HasExited) {
        $script:relay.StandardInput.Close()
        if (-not $script:relay.WaitForExit(5000)) { $script:relay.Kill($true); $null=$script:relay.WaitForExit(5000) }
    }
    if ($script:relay) { $script:relay.Dispose() }
}

Describe 'The native outage relay changes transport without changing Git content' {
    It 'refuses the independent TCP probe and resets Git during an outage' {
        Set-RelayMode reset -Confirm:$false
        Test-RelayProbe | Should -BeFalse
        $result = Invoke-RelayGit @('ls-remote','--exit-code',($script:ready.baseURL+'/alissonsol/yuruna.git'),'HEAD')
        $result.ExitCode | Should -Not -Be 0
    }

    It 'recovers the same full SHA after healthy reset healthy transitions' {
        foreach ($mode in @('healthy','reset','healthy')) {
            Set-RelayMode $mode -Confirm:$false
            $result = Invoke-RelayGit @('ls-remote','--exit-code',($script:ready.baseURL+'/alissonsol/yuruna.git'),'HEAD')
            if ($mode -eq 'healthy') {
                Test-RelayProbe | Should -BeTrue
                $result.ExitCode | Should -Be 0
                $result.StdOut | Should -Match $script:sha
            } else { Test-RelayProbe | Should -BeFalse; $result.ExitCode | Should -Not -Be 0 }
        }
        ([string](& git --git-dir $script:bare rev-parse HEAD)).Trim() | Should -BeExactly $script:sha
    }

    It 'supports a real shallow protocol two fetch and records transport evidence only' {
        Set-RelayMode healthy -Confirm:$false
        $checkout = Join-Path $TestDrive 'checkout'
        $result = Invoke-RelayGit @('-c','protocol.version=2','clone','--depth=1',($script:ready.baseURL+'/alissonsol/yuruna.git'),$checkout)
        $result.ExitCode | Should -Be 0 -Because $result.StdErr
        ([string](& git -C $checkout rev-parse HEAD)).Trim() | Should -BeExactly $script:sha
        (& git -C $checkout rev-parse --is-shallow-repository) | Should -Be 'true'
        $record = Get-Content $script:evidence -Raw | ConvertFrom-Json
        $record.healthyRequests | Should -BeGreaterThan 0
        $record.resetRequests | Should -BeGreaterThan 0
        $record.completedRequests | Should -BeGreaterThan 0
        $record.backendFailures | Should -Be 0
        @($record.transitions).Count | Should -BeGreaterOrEqual 4
        (Get-Content $script:evidence -Raw) | Should -Not -Match 'Authorization|password|token|requestBody'
    }

    It 'denies push and path traversal at the fixture origin' {
        Set-RelayMode healthy -Confirm:$false
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $false
        $handler.AllowAutoRedirect = $false
        $client = [Net.Http.HttpClient]::new($handler)
        try {
            foreach ($path in @('/alissonsol/yuruna.git/info/refs?service=git-receive-pack','/alissonsol/yuruna.git/git-receive-pack','/%2e%2e/HEAD')) {
                $response=$client.GetAsync($script:ready.baseURL+$path).GetAwaiter().GetResult()
                try { [int]$response.StatusCode | Should -Be 403 } finally { $response.Dispose() }
            }
        } finally { $client.Dispose() }
    }

    It 'exits cleanly when its controller closes input and persists final evidence' {
        $script:relay.StandardInput.Close()
        $script:relay.WaitForExit(5000) | Should -BeTrue
        $script:relay.ExitCode | Should -Be 0
        $record=Get-Content $script:evidence -Raw | ConvertFrom-Json
        $record.stoppedAt | Should -Not -BeNullOrEmpty
        Test-RelayProbe | Should -BeFalse
    }
}
