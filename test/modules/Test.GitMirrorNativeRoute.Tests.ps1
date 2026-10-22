<#PSScriptInfo
.VERSION 2026.10.22
.GUID 4271842b-e024-4afd-9528-b8212179e1c4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $script:Root 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    function Invoke-NativeRouteGit {
        param([string]$Directory, [string[]]$Arguments)
        $output = @(& git -C $Directory @Arguments 2>&1)
        if ($LASTEXITCODE) { throw "Fixture Git failed: $($output -join ' ')" }
        return ($output -join "`n").Trim()
    }
    $outageAst = [Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $script:Root 'tools/Invoke-GitMirrorNativeOutage.ps1'), [ref]$null, [ref]$null)
    foreach ($definition in $outageAst.FindAll({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -in @('Read-NativeRunnerState', 'Set-NativeOutageMode',
                    'New-NativeOutageLogStream', 'Read-NativeOutageLog')
            }, $true)) { . ([scriptblock]::Create($definition.Extent.Text)) }
}

Describe 'Native route evidence is measured from the frozen origin' {
    BeforeEach {
        $script:Work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Origin = Join-Path $script:Work origin
        [IO.Directory]::CreateDirectory($script:Origin) | Out-Null
        $null = Invoke-NativeRouteGit $script:Origin @('init', '-q', '-b', 'main')
        $null = Invoke-NativeRouteGit $script:Origin @('config', 'user.name', 'Fixture')
        $null = Invoke-NativeRouteGit $script:Origin @('config', 'user.email', 'fixture@example.invalid')
        [IO.File]::WriteAllText((Join-Path $script:Origin VERSION), 'frozen candidate')
        $null = Invoke-NativeRouteGit $script:Origin @('add', '.')
        $null = Invoke-NativeRouteGit $script:Origin @('commit', '-qm', 'fixture')
        $script:Sha = Invoke-NativeRouteGit $script:Origin @('rev-parse', 'HEAD')
        $script:Tree = Invoke-NativeRouteGit $script:Origin @('rev-parse', 'HEAD^{tree}')
        $script:Config = Join-Path $script:Work config.yml
        [IO.File]::WriteAllText($script:Config, @'
repositories:
  frameworkUrl: https://github.com/alissonsol/yuruna.git
  projectUrl: file:///operator/project
  mirror:
    mode: prefer
    url: http://127.0.0.1:1
    verificationPublicKeys: []
    mirrorOnlyMaxAgeSeconds: 604800
vmStart: {}
'@)
        $script:Upstreams = Join-Path $script:Work upstreams.json
        @{ repositories = @(@{ name = 'framework'; canonicalUrl = 'https://github.com/alissonsol/yuruna.git'
                    localPath = $script:Origin; candidateCommit = $script:Sha }) } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:Upstreams
        $script:Evidence = Join-Path $script:Work evidence.json
        $script:Environment = @{
            YURUNA_RUNTIME_DIR = (Join-Path $script:Work runtime)
            GIT_CONFIG_COUNT = '3'; GIT_CONFIG_NOSYSTEM = '1'
            GIT_CONFIG_GLOBAL = $(if ($IsWindows) { 'NUL' } else { '/dev/null' })
            GIT_CONFIG_KEY_0 = "url.$(([Uri]::new($script:Origin)).AbsoluteUri).insteadOf"
            GIT_CONFIG_VALUE_0 = 'https://github.com/alissonsol/yuruna.git'
            GIT_CONFIG_KEY_1 = 'credential.helper'; GIT_CONFIG_VALUE_1 = ''
            GIT_CONFIG_KEY_2 = 'protocol.file.allow'; GIT_CONFIG_VALUE_2 = 'always'
        }
        $script:Arguments = @('-NoProfile', '-File', (Join-Path $script:Root 'tools/Invoke-GitMirrorNativeRoute.ps1'),
            '-Scenario', 'GM-MISSING-TRUST', '-ConfigPath', $script:Config, '-UpstreamsPath', $script:Upstreams,
            '-FrameworkTree', $script:Tree, '-OutputPath', $script:Evidence, '-DisposableTarget')
    }

    It 'records actual origin confirmation and preserves nondefault operator configuration' {
        $before = [IO.File]::ReadAllBytes($script:Config)
        $process = Invoke-BoundedNativeCommand -FilePath (Get-Process -Id $PID).Path -ArgumentList $script:Arguments `
            -Environment $script:Environment -TimeoutSeconds 30
        $process.ExitCode | Should -Be 0 -Because $process.StdErr
        $evidence = Get-Content -Raw -LiteralPath $script:Evidence | ConvertFrom-Json -AsHashtable
        $evidence.passed | Should -BeTrue
        $evidence.configPreserved | Should -BeTrue
        $evidence.samples.Count | Should -Be 1
        $evidence.samples[0].selectedSha | Should -BeExactly $script:Sha
        $evidence.samples[0].verification | Should -BeExactly 'origin-direct'
        $evidence.samples[0].fallbackReason | Should -BeExactly 'mirror-untrusted'
        @($evidence.samples[0].attempts | Where-Object source -CEQ mirror).Count | Should -Be 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:Config)) | Should -BeExactly ([Convert]::ToBase64String($before))
        Get-Content -Raw $script:Config | Should -Match 'file:///operator/project'
    }

    It 'rejects a successful origin that advanced beyond the frozen candidate' {
        [IO.File]::WriteAllText((Join-Path $script:Origin VERSION), 'later commit')
        $null = Invoke-NativeRouteGit $script:Origin @('commit', '-qam', 'advanced')
        $process = Invoke-BoundedNativeCommand -FilePath (Get-Process -Id $PID).Path -ArgumentList $script:Arguments `
            -Environment $script:Environment -TimeoutSeconds 30
        $process.ExitCode | Should -Not -Be 0
        $evidence = Get-Content -Raw -LiteralPath $script:Evidence | ConvertFrom-Json -AsHashtable
        $evidence.passed | Should -BeFalse
        $evidence.samples[0].success | Should -BeTrue
        $evidence.samples[0].selectedSha | Should -Not -Be $script:Sha
        $evidence.failure | Should -Match 'same candidate'
    }

    It 'requires the explicit disposable target acknowledgment before producing evidence' {
        $process = Invoke-BoundedNativeCommand -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList @($script:Arguments | Where-Object { $_ -cne '-DisposableTarget' }) `
            -Environment $script:Environment -TimeoutSeconds 30
        $process.ExitCode | Should -Not -Be 0
        Test-Path -LiteralPath $script:Evidence | Should -BeFalse
    }

    It 'measures a production-signed mirror decision while the host origin transport is actually unavailable' {
        $service = Join-Path $script:Root 'test/extension/caching-proxy-service'
        $binary = Join-Path $script:Work ('mirror-fixture' + $(if ($IsWindows) { '.exe' } else { '' }))
        $build = Invoke-BoundedNativeCommand -FilePath go -ArgumentList @('test', '-c', '-o', $binary, '.') `
            -WorkingDirectory $service -TimeoutSeconds 120 -Environment @{
                GOCACHE = $(if ($env:GOCACHE) { $env:GOCACHE } else { Join-Path $TestDrive go-cache })
            }
        $build.ExitCode | Should -Be 0 -Because $build.StdErr
        $fixturePath = Join-Path $script:Work service.json
        @{
            root = (Join-Path $script:Work mirror); stateRoot = (Join-Path $script:Work state)
            readerRoot = (Join-Path $script:Work reader); repositories = @('alissonsol/yuruna')
            signingKey = (Join-Path $service 'testdata/git-mirror/receipts/test-key.pem')
            refreshIntervalMilliseconds = 0
        } | ConvertTo-Json | Set-Content -LiteralPath $fixturePath
        $start = [Diagnostics.ProcessStartInfo]::new($binary)
        $start.ArgumentList.Add('-test.run=^TestGitMirrorFixtureProcess$')
        $start.UseShellExecute = $false
        $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $start.Environment['YURUNA_GIT_MIRROR_FIXTURE_CONFIG'] = $fixturePath
        foreach ($key in $script:Environment.Keys) { $start.Environment[$key] = $script:Environment[$key] }
        $worker = [Diagnostics.Process]::Start($start)
        $errors = $worker.StandardError.ReadToEndAsync()
        try {
            $line = $worker.StandardOutput.ReadLineAsync()
            $line.Wait(15000) | Should -BeTrue
            $line.Result | Should -Match '^\{'
            $url = ($line.Result | ConvertFrom-Json).baseURL
            $vectors = Get-Content -Raw (Join-Path $service 'testdata/git-mirror/receipts/vectors.json') | ConvertFrom-Json
            $config = [IO.File]::ReadAllText($script:Config).Replace('http://127.0.0.1:1', $url).
                Replace('verificationPublicKeys: []', "verificationPublicKeys: ['$($vectors.publicKey)']")
            [IO.File]::WriteAllText($script:Config, $config)
            $arguments = @($script:Arguments | ForEach-Object {
                    if ($_ -ceq 'GM-MISSING-TRUST') { 'GM-MIRROR-FIRST-HOST-OFFLINE' } else { $_ }
                })
            $process = Invoke-BoundedNativeCommand -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments `
                -Environment $script:Environment -TimeoutSeconds 40
            $process.ExitCode | Should -Be 0 -Because $process.StdErr
            $evidence = Get-Content -Raw -LiteralPath $script:Evidence | ConvertFrom-Json -AsHashtable
            $evidence.passed | Should -BeTrue
            $evidence.hostOutageConnections | Should -Be 0
            $evidence.samples.Count | Should -Be 2
            $evidence.samples[-1].verification | Should -BeExactly 'mirror-confirmed'
            $evidence.samples[-1].selectedSha | Should -BeExactly $script:Sha
            @($evidence.samples[-1].attempts | Where-Object source -CEQ origin).Count | Should -Be 0
        } finally {
            $worker.StandardInput.Close()
            if (-not $worker.WaitForExit(5000)) { $worker.Kill($true); $null = $worker.WaitForExit(5000) }
            if ($errors.Wait(2000) -and $errors.Result) { Write-Verbose $errors.Result }
            $worker.Dispose()
        }
    }
}

Describe 'Native outage observations use production state records' {
    It 'observes short recovery messages while the redirected writer remains open' {
        $path = Join-Path $TestDrive live-runner.log
        $writer = New-NativeOutageLogStream -Path $path
        try {
            Read-NativeOutageLog -Path $path | Should -BeExactly ''
            $message = 'Repository access recovered; ending the transient network hold.'
            $bytes = [Text.Encoding]::UTF8.GetBytes($message)
            $writer.Write($bytes, 0, $bytes.Length)
            Read-NativeOutageLog -Path $path | Should -BeExactly $message
        } finally { $writer.Dispose() }
    }

    It 'retains outer module recovery diagnostics in the actual child invocation' {
        $target = Join-Path $TestDrive diagnostic-target
        [IO.Directory]::CreateDirectory((Join-Path $target test)) | Out-Null
        $ConfigPath = Join-Path $target config.yml
        [IO.File]::WriteAllText($ConfigPath, '{}')
        [IO.File]::WriteAllText((Join-Path $target test/Start-TestRunner.ps1), @'
[CmdletBinding()]
param([string]$ConfigPath, [switch]$NoStatusService, [switch]$NoGitPull, [string]$logLevel)
$module = New-Module -ScriptBlock {
    function Invoke-RecoveryProbe { Write-Verbose 'Repository access recovered; ending the transient network hold.' }
    Export-ModuleMember -Function Invoke-RecoveryProbe
}
Import-Module $module
Invoke-RecoveryProbe
'@)
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:Root tools/Invoke-GitMirrorNativeOutage.ps1), [ref]$null, [ref]$null)
        $launch = @($ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.ForEachStatementAst] -and
                    $node.Condition.Extent.Text.Contains("'test/Start-TestRunner.ps1'")
                }, $true))
        $launch.Count | Should -Be 1
        $arguments = @(& ([scriptblock]::Create($launch[0].Condition.Extent.Text)))
        $process = Invoke-BoundedNativeCommand -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList $arguments -TimeoutSeconds 10
        $process.ExitCode | Should -Be 0 -Because $process.StdErr
        $process.StdOut | Should -Match ([regex]::Escape('Repository access recovered; ending the transient network hold.'))
    }

    It 'distinguishes a configuration gate hold from another paused failure' {
        $runtime = Join-Path $TestDrive 'observed-runtime'
        [IO.Directory]::CreateDirectory($runtime) | Out-Null
        [IO.File]::WriteAllText((Join-Path $runtime runner.state.json), '{"current":"paused"}')
        [IO.File]::WriteAllText((Join-Path $runtime status.json), '{"runnerFault":{"failureClass":"config_gate_failed"}}')
        [IO.File]::WriteAllText((Join-Path $runtime runner.preambleStall.json), '{"streak":3}')
        $record = Read-NativeRunnerState
        $record.state | Should -BeExactly 'paused'
        $record.failureClass | Should -BeExactly 'config_gate_failed'
        $record.streak | Should -Be 3
        [IO.File]::WriteAllText((Join-Path $runtime status.json), '{"runnerFault":{"failureClass":"source_integrity"}}')
        (Read-NativeRunnerState).failureClass | Should -BeExactly 'source_integrity'
    }

    It 'does not manufacture a gate failure or stall when state files are absent' {
        $runtime = Join-Path $TestDrive missing-runtime
        Test-Path -LiteralPath $runtime | Should -BeFalse
        $record = Read-NativeRunnerState
        $record.state | Should -BeNullOrEmpty
        $record.failureClass | Should -BeNullOrEmpty
        $record.streak | Should -Be 0
    }

    It 'changes only the owned relay control and preserves unrelated files' {
        $control = Join-Path $TestDrive control.json
        $unrelated = Join-Path $TestDrive operator.json
        [IO.File]::WriteAllText($unrelated, '{"preserved":true}')
        Set-NativeOutageMode reset
        (Get-Content -Raw $control | ConvertFrom-Json).mode | Should -BeExactly 'reset'
        Set-NativeOutageMode healthy
        (Get-Content -Raw $control | ConvertFrom-Json).mode | Should -BeExactly 'healthy'
        Test-Path "$control.next" | Should -BeFalse
        Get-Content -Raw $unrelated | Should -BeExactly '{"preserved":true}'
    }
}

Describe 'Standalone native guest adapter programs remain executable' {
    BeforeAll {
        $script:GuestAst = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:Root 'tools/Invoke-GitMirrorNativeGuest.ps1'), [ref]$null, [ref]$null)
        $script:Programs = @($script:GuestAst.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.StringConstantExpressionAst] -and
                    $node.StringConstantType -eq 'SingleQuotedHereString'
                }, $true))
    }
    It 'parses the complete Windows guest program after data substitution' {
        $program = @($script:Programs | Where-Object { $_.Value.StartsWith('$ErrorActionPreference') })
        $program.Count | Should -Be 1
        $errors = @()
        $null = [Management.Automation.Language.Parser]::ParseInput(
            $program[0].Value.Replace('__PAYLOAD__', "'{}'"), [ref]$null, [ref]$errors)
        $errors.Count | Should -Be 0
    }
    It 'compiles the Unix guest program without requiring a guest or executing payloads' {
        $program = @($script:Programs | Where-Object { $_.Value.StartsWith('import base64,') })
        $program.Count | Should -Be 1
        $path = Join-Path $TestDrive remote-guest.py
        [IO.File]::WriteAllText($path, $program[0].Value.Replace('__PAYLOAD__', "'{}'"))
        $process = Invoke-BoundedNativeCommand -FilePath python3 `
            -ArgumentList @('-c', 'import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())', $path) -TimeoutSeconds 10
        $process.ExitCode | Should -Be 0 -Because $process.StdErr
    }
}
