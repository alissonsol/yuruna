<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 427e2e91-a49b-4c4a-99a0-cf1f450ad4c1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna install outcomes pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Fixture commands retain the signatures called by isolated production functions.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Extracted production blocks read their fixture variables through dynamic scope.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Test-local installer stubs change no host settings.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'The test-local module installer stub fails without contacting a package repository.')]
[CmdletBinding()]
param()
if (-not (Get-Command Describe -ErrorAction SilentlyContinue)) { throw 'Run this suite with Pester.' }
BeforeAll {
    $script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    function Get-SourceFunction {
        param([string]$Path, [string]$Name)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot $Path), [ref]$null, [ref]$null)
        return $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true).Extent.Text
    }
    function Write-SetupDetail { }
    function Write-SetupWarning { param($Message) $script:Warnings += $Message }
    function Write-SetupVerbose { }
    function Format-YurunaOperatorMessage { param($Key) return $Key }
}
Describe 'Installer adoption depends on health data' {
    It 'uses the missing address even when the probe message is translated' {
        . ([scriptblock]::Create((Get-SourceFunction 'install/setup.ps1' 'Test-ServiceVMAdoptable')))
        function Import-SetupModule { }
        function Initialize-YurunaHost { }
        function Restore-YurunaServiceVM { return $script:ServiceResult }
        $TestRoot = $script:RepoRoot
        $script:Rebuild = $false
        $script:ServiceResult = [pscustomobject]@{ Outcome = 'started'; Healthy = $false; Address = ''; Message = 'Adresse introuvable'; StateBefore = 'stopped' }
        (Test-ServiceVMAdoptable 'stash').Adopt | Should -BeTrue
        $script:ServiceResult.Address = '192.0.2.5'
        $script:ServiceResult.Message = 'no address is only a message, not probe state'
        (Test-ServiceVMAdoptable 'stash').Adopt | Should -BeFalse
    }
    It 'treats an unrelated outbound subnet block as advisory' -Skip:(-not $IsLinux) {
        . ([scriptblock]::Create((Get-SourceFunction 'install/setup.ps1' 'Test-NetworkSubnetConnectivity')))
        function ufw { }
        function sudo { $global:LASTEXITCODE = 0; return @('Status: active', '10.99.0.0/24 DENY OUT Anywhere') }
        $script:Warnings = @()
        Test-NetworkSubnetConnectivity | Should -BeTrue
        ($script:Warnings -join ' ') | Should -Match '10.99.0.0/24'
    }
}
Describe 'Successful local fallback resolves only its NAS failure' {
    It 'moves the NAS failure to warnings only when local fallback succeeds: <Success>' -ForEach @(
        @{ Success = $true }, @{ Success = $false }
    ) {
        $source = Get-Content (Join-Path $script:RepoRoot 'install/setup.ps1') -Raw
        $start = $source.IndexOf('    $nasFailureIndex =')
        $end = $source.IndexOf('# --- REGION: 5b.', $start)
        $body = $source.Substring($start, $end - $start).TrimEnd()
        $body = $body.Substring(0, $body.LastIndexOf('}'))
        $script:Failed = [Collections.Generic.List[string]]::new()
        $script:Failed.Add('unrelated failure')
        $script:Warned = [Collections.Generic.List[string]]::new()
        $script:FallbackSuccess = $Success
        $storageNetworkPath = '//fixture/share'
        $storageOnFailure = 'local'
        $storageLocalRoot = $TestDrive
        $storageKind = 'nas'
        function Invoke-SetupStep {
            param($Name, $Provides, $Action, [switch]$Critical)
            if (-not $Critical) { $script:Failed.Add("$Name -- unavailable"); return $false }
            return $script:FallbackSuccess
        }
        function Add-WarnedStep { param($Description) $script:Warned.Add($Description) }
        . ([scriptblock]::Create($body))
        $script:Failed[0] | Should -Be 'unrelated failure'
        if ($Success) {
            $script:Failed.Count | Should -Be 1
            $script:Warned.Count | Should -Be 1
            $storageKind | Should -Be 'local'
        } else {
            $script:Failed.Count | Should -Be 2
            $script:Warned.Count | Should -Be 0
            $storageKind | Should -Be 'nas'
        }
    }
}
Describe 'Installer process exit status is observable without closing interactive shells' {
    It 'returns process exit 1 when the completed install path recorded failure' {
        $source = Get-Content (Join-Path $script:RepoRoot 'install/windows.hyper-v.ps1') -Raw
        $footer = $source.Substring($source.LastIndexOf('Stop-InstallLog'))
        $fixture = Join-Path $TestDrive 'failure.ps1'
        [IO.File]::WriteAllText($fixture, "function Stop-InstallLog { }`n`$script:InstallSucceeded = `$false`n" + $footer)
        & pwsh -NoProfile -NonInteractive -File $fixture
        $LASTEXITCODE | Should -Be 1
    }
    It 'retains a materialized child failure for command invocations' {
        $source = Get-Content (Join-Path $script:RepoRoot 'install/windows.hyper-v.ps1') -Raw
        $start = $source.IndexOf('    $childExit = $LASTEXITCODE')
        $end = $source.IndexOf("`n}", $start)
        $fixture = Join-Path $TestDrive 'handoff.ps1'
        [IO.File]::WriteAllText($fixture, "`$global:LASTEXITCODE = 17`n" + $source.Substring($start, $end - $start))
        & pwsh -NoProfile -NonInteractive -File $fixture
        $LASTEXITCODE | Should -Be 17
    }
    It 'retains an interactive shell when the handoff block returns' {
        $source = Get-Content (Join-Path $script:RepoRoot 'install/windows.hyper-v.ps1') -Raw
        $start = $source.IndexOf('    $childExit = $LASTEXITCODE')
        $end = $source.IndexOf("`n}", $start)
        $body = $source.Substring($start, $end - $start)
        $body = $body.Replace('[Environment]::GetCommandLineArgs()', "@('pwsh', '-NoLogo')")
        $global:LASTEXITCODE = 19
        & ([scriptblock]::Create($body))
        $LASTEXITCODE | Should -Be 19
    }
}
Describe 'Shell installer failure boundaries' -Skip:(-not (Get-Command bash -ErrorAction SilentlyContinue)) {
    It 'reports a failed nested function from its exit trap' {
        $source = Get-Content (Join-Path $script:RepoRoot 'install/ubuntu.kvm.sh') -Raw
        $body = [regex]::Match($source, '(?ms)^yuruna_install_cleanup\(\) \{.*?^\}').Value
        $body = [regex]::Match($source, '(?ms)^yuruna_cleanup_tmp_paths\(\) \{.*?^\}').Value + "`n" + $body
        $fixture = Join-Path $TestDrive 'cleanup.sh'
        $content = @'
set -euo pipefail
SUDO_KEEPALIVE_PID=99999999
YURUNA_STATUS_BACKUP=""
_yuruna_step=fixture-stage
YURUNA_INSTALL_LOG=fixture.log
_yuruna_flush_log() { :; }
'@
        [IO.File]::WriteAllText($fixture, $content + "`n" + $body + "`ntrap yuruna_install_cleanup EXIT`nfailing_step() { false; }`nfailing_step`n")
        $output = & bash $fixture 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $output | Should -Match 'installer exited with code 1'
        $output | Should -Match 'fixture-stage'
        $output | Should -Match 'fixture.log'
    }
    It 'rejects an unpublished Microsoft suite before changing any apt file' {
        $source = Get-Content (Join-Path $script:RepoRoot 'install/ubuntu.kvm.sh') -Raw
        $body = [regex]::Match($source, '(?ms)^install_pwsh_apt\(\) \{.*?^\}').Value
        $fixture = Join-Path $TestDrive 'apt.sh'
        $stubs = @'
set -euo pipefail
curl() { return 22; }
lsb_release() { echo future; }
sudo() { echo UNEXPECTED_PRIVILEGED_WRITE; return 0; }
log() { :; }
'@
        [IO.File]::WriteAllText($fixture, $stubs + "`n" + $body + "`ninstall_pwsh_apt || exit `$?`n")
        $output = & bash $fixture 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $output | Should -Not -Match 'UNEXPECTED_PRIVILEGED_WRITE'
    }
}
Describe 'Installer optional-dependency failures remain visible in the summary' {
    It 'records a PowerShell YAML install failure in the Windows issue list' {
        $source = Get-Content (Join-Path $script:RepoRoot 'install/windows.hyper-v.ps1') -Raw
        . ([scriptblock]::Create((Get-SourceFunction 'install/windows.hyper-v.ps1' 'Add-InstallIssue')))
        $script:YurunaIssue = [Collections.Generic.List[string]]::new()
        function Write-Warn { }
        function Install-Module { throw 'gallery unavailable' }
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
        $attempt = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.TryStatementAst] -and
            $node.Body.Extent.Text -match 'Install-Module -Name powershell-yaml' -and $node.Body.Extent.Text.Length -lt 1000 }, $true)
        . ([scriptblock]::Create($attempt.Extent.Text))
        $script:YurunaIssue.Count | Should -Be 1
        $script:YurunaIssue[0] | Should -Match 'gallery unavailable'
    }
    It 'records the shell YAML failure even when installation continues' -Skip:(-not (Get-Command bash -ErrorAction SilentlyContinue)) {
        $source = Get-Content (Join-Path $script:RepoRoot 'install/ubuntu.kvm.sh') -Raw
        $start = $source.IndexOf("pwsh -NoProfile -Command '`n    if (Get-Module -ListAvailable -Name powershell-yaml")
        $end = $source.IndexOf('# --- REGION:', $start)
        $body = $source.Substring($start, $end - $start)
        $fixture = Join-Path $TestDrive 'yaml-summary.sh'
        $prefix = @'
set -euo pipefail
YURUNA_ISSUES=()
warn() { :; }
note_issue() { YURUNA_ISSUES+=("$*"); warn "$*"; }
pwsh() { return 1; }
'@
        [IO.File]::WriteAllText($fixture, $prefix + "`n" + $body + "`nprintf '%s\n' `"`${YURUNA_ISSUES[@]}`"`n")
        $output = & bash $fixture 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $output | Should -Match 'powershell-yaml install reported an error'
    }
}
Describe 'Windows installer stops only the processes its PID files still name' {
    BeforeAll {
        . ([scriptblock]::Create((Get-SourceFunction 'install/windows.hyper-v.ps1' 'Test-YurunaPidFileOwner')))
        . ([scriptblock]::Create((Get-SourceFunction 'install/windows.hyper-v.ps1' 'Stop-YurunaProcess')))
        $script:Pattern = @('Start-TestRunner.ps1', 'Invoke-TestRunnerInnerLoop.ps1')
    }
    BeforeEach {
        $script:SavedRuntimeDir = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR
        $script:Started = [datetime]::UtcNow.AddHours(-1)
        $script:CimQueries = 0
        $script:Listed = @()
        $script:Killed = [Collections.Generic.List[int]]::new()
        function Get-CimInstance { $script:CimQueries++; $script:Listed }
        function Get-NetTCPConnection { }
        function Get-Process { param([int]$Id) if ($script:Killed -contains $Id) { return $null }; [pscustomobject]@{ Id = $Id; ProcessName = 'pwsh'; StartTime = $script:Started } }
        function taskkill.exe { $script:Killed.Add([int]$args[1]) }
        function Write-Step { }
        function Write-Warn { }
    }
    AfterEach {
        if ($null -eq $script:SavedRuntimeDir) { Remove-Item Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntimeDir }
    }

    It 'accepts a process that runs a Yuruna script, or one that started when its start record says' {
        Test-YurunaPidFileOwner -ProcessId 4242 -CommandLine '"pwsh.exe" -File C:\yuruna\test\Start-TestRunner.ps1' -Pattern $script:Pattern | Should -BeTrue
        $start = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.start'
        Set-Content -LiteralPath $start -Value $script:Started.ToString('o') -NoNewline
        Test-YurunaPidFileOwner -ProcessId 4242 -CommandLine '' -Pattern $script:Pattern -StartFile $start | Should -BeTrue
    }
    It 'rejects a recycled PID held by another PowerShell process' {
        $start = Join-Path $env:YURUNA_RUNTIME_DIR 'runner.start'
        Set-Content -LiteralPath $start -Value $script:Started.AddMinutes(-5).ToString('o') -NoNewline
        Test-YurunaPidFileOwner -ProcessId 4242 -CommandLine '"pwsh.exe" -NoLogo' -Pattern $script:Pattern -StartFile $start | Should -BeFalse
        Test-YurunaPidFileOwner -ProcessId 4242 -CommandLine '"pwsh.exe" -NoLogo' -Pattern $script:Pattern | Should -BeFalse
    }
    It 'leaves alone the operator shell that reused a stale runner.pid, listing processes once' {
        Set-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'runner.pid') -Value '4242' -NoNewline
        $script:Listed = @([pscustomobject]@{ ProcessId = 4242; CommandLine = '"pwsh.exe" -NoLogo' })
        Stop-YurunaProcess -Confirm:$false
        $script:Killed.Count | Should -Be 0
        $script:CimQueries | Should -Be 1
    }
    It 'still stops the runner a PID file names when its command line cannot be read' {
        Set-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'runner.pid') -Value '4242' -NoNewline
        Set-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'runner.start') -Value $script:Started.ToString('o') -NoNewline
        Stop-YurunaProcess -Confirm:$false
        ($script:Killed -join ',') | Should -Be '4242'
    }
    It 'stops a runner found by its command line' {
        $script:Listed = @(
            [pscustomobject]@{ ProcessId = 5151; CommandLine = '"pwsh.exe" -File C:\yuruna\test\Start-TestRunner.ps1' }
            [pscustomobject]@{ ProcessId = 6161; CommandLine = '"pwsh.exe" -NoLogo' })
        Stop-YurunaProcess -Confirm:$false
        ($script:Killed -join ',') | Should -Be '5151'
        $script:CimQueries | Should -Be 1
    }
}
Describe 'Shell installers stop only the processes their PID files still name' -Skip:($IsWindows -or -not (Get-Command bash -ErrorAction SilentlyContinue)) {
    BeforeAll {
        # A copy of bash named pwsh: ps reports its comm as pwsh, as it does for
        # a real runner, and -c keeps it alive without taking on sleep's name.
        $script:FakePwsh = Join-Path $TestDrive 'bin/pwsh'
        $null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:FakePwsh)
        Copy-Item -LiteralPath (Get-Command bash -CommandType Application | Select-Object -First 1).Source -Destination $script:FakePwsh
        & chmod +x $script:FakePwsh
        function Invoke-ShellStop {
            param([string]$Installer, [string]$RuntimeDir)
            $source = Get-Content (Join-Path $script:RepoRoot $Installer) -Raw
            $bodies = foreach ($name in 'yuruna_epoch_from_utc', 'yuruna_process_start_epoch', 'pid_file_owner_ok', 'stop_yuruna_processes') {
                [regex]::Match($source, "(?ms)^$name\(\) \{.*?^\}").Value
            }
            # pgrep and the port probes are stubbed so only the PID-file channel
            # can pick a target; nothing else on the host is ever signaled.
            $stubs = "set -euo pipefail`nlog() { echo `"LOG: `$*`"; }`nwarn() { echo `"WARN: `$*`" >&2; }`npgrep() { :; }`nlsof() { :; }`nss() { :; }`n"
            $fixture = Join-Path $TestDrive ('stop-' + [guid]::NewGuid().ToString('N') + '.sh')
            [IO.File]::WriteAllText($fixture, $stubs + ($bodies -join "`n") + "`nstop_yuruna_processes`n")
            $saved = @{ Runtime = $env:YURUNA_RUNTIME_DIR; Dir = $env:YURUNA_DIR }
            try {
                $env:YURUNA_RUNTIME_DIR = $RuntimeDir
                $env:YURUNA_DIR = $TestDrive
                $output = & bash $fixture 2>&1 | Out-String
                return @{ Code = $LASTEXITCODE; Output = $output }
            } finally {
                $env:YURUNA_RUNTIME_DIR = $saved.Runtime
                $env:YURUNA_DIR = $saved.Dir
            }
        }
        function Start-FakeRunner {
            param([string[]]$Extra = @())
            # ArgumentList keeps 'sleep 20; :' one argument; Start-Process would join and re-split it.
            $info = [Diagnostics.ProcessStartInfo]::new($script:FakePwsh)
            $info.UseShellExecute = $false
            foreach ($arg in @('-c', 'sleep 20; :') + $Extra) { $info.ArgumentList.Add($arg) }
            $process = [Diagnostics.Process]::Start($info)
            $null = $process.StartTime
            return $process
        }
        function New-RuntimeDir {
            $dir = Join-Path $TestDrive ('runtime-' + [guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $dir
            return $dir
        }
    }

    It 'leaves alone a PowerShell process that reused a stale runner.pid (<Installer>)' -ForEach @(
        @{ Installer = 'install/ubuntu.kvm.sh' }, @{ Installer = 'install/macos.utm.sh' }
    ) {
        $runtime = New-RuntimeDir
        $victim = Start-FakeRunner
        try {
            Set-Content -LiteralPath (Join-Path $runtime 'runner.pid') -Value $victim.Id -NoNewline
            $r = Invoke-ShellStop -Installer $Installer -RuntimeDir $runtime
            $r.Code | Should -Be 0 -Because $r.Output
            $victim.HasExited | Should -BeFalse -Because 'no start record and no Yuruna script name the reused PID'
            # A start record from the earlier owner does not match the process now holding the PID.
            Set-Content -LiteralPath (Join-Path $runtime 'runner.start') -NoNewline -Value $victim.StartTime.ToUniversalTime().AddMinutes(-5).ToString('o')
            $r = Invoke-ShellStop -Installer $Installer -RuntimeDir $runtime
            $victim.HasExited | Should -BeFalse -Because $r.Output
        } finally {
            if (-not $victim.HasExited) { $victim.Kill() }
        }
    }

    It 'stops the process a PID file names when it started when the start record says (<Installer>)' -ForEach @(
        @{ Installer = 'install/ubuntu.kvm.sh' }, @{ Installer = 'install/macos.utm.sh' }
    ) {
        $runtime = New-RuntimeDir
        $victim = Start-FakeRunner
        try {
            Set-Content -LiteralPath (Join-Path $runtime 'inner.pid') -Value $victim.Id -NoNewline
            Set-Content -LiteralPath (Join-Path $runtime 'inner.start') -NoNewline -Value $victim.StartTime.ToUniversalTime().ToString('o')
            $r = Invoke-ShellStop -Installer $Installer -RuntimeDir $runtime
            $r.Code | Should -Be 0 -Because $r.Output
            $victim.WaitForExit(5000) | Should -BeTrue -Because $r.Output
        } finally {
            if (-not $victim.HasExited) { $victim.Kill() }
        }
    }

    It 'stops the process a PID file names when it runs a Yuruna script (<Installer>)' -ForEach @(
        @{ Installer = 'install/ubuntu.kvm.sh' }, @{ Installer = 'install/macos.utm.sh' }
    ) {
        $runtime = New-RuntimeDir
        $victim = Start-FakeRunner -Extra @('Start-TestRunner.ps1')
        try {
            Set-Content -LiteralPath (Join-Path $runtime 'runner.pid') -Value $victim.Id -NoNewline
            $r = Invoke-ShellStop -Installer $Installer -RuntimeDir $runtime
            $r.Code | Should -Be 0 -Because $r.Output
            $victim.WaitForExit(5000) | Should -BeTrue -Because $r.Output
        } finally {
            if (-not $victim.HasExited) { $victim.Kill() }
        }
    }
}
