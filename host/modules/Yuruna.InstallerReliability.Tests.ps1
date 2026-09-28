<#PSScriptInfo
.VERSION 2026.09.27
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
