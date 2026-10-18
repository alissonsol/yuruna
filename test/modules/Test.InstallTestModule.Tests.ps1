<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42318205-4701-4ec4-97ce-64b0837ff71b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test install pester psscriptanalyzer preflight pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Behavioral Pester guard on how the host installers provide the test
    modules: the newest Pester 6.x and PSScriptAnalyzer, and the preflight
    that says whether the installed Pester is one the runner will load.
.DESCRIPTION
    The gallery's newest Pester can be on a later major, so the line is
    requested by its own bounds, and the policy turns on choices no install
    log shows:

      * a line counts only its own copies. A Pester 5 installed alone is not a
        usable 6.x, and the helper answers for whichever major it is asked.
      * an unreachable gallery is a problem only when no usable copy of that line
        is present.
      * every failure reaches the installer's closing summary and none stops it.

    tools/Install-TestModule.ps1 holds the policy; the three installers only
    relay its MODULE-ISSUE lines. The bodies under test are lifted out of those
    files rather than copied, and the gallery commands are mocked, so the tests
    run anywhere and never install anything.

    Run: pwsh -NoProfile -Command "Invoke-Pester -Path test/modules/Test.InstallTestModule.Tests.ps1"
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = (Resolve-Path (Join-Path -Path $here -ChildPath '..' -AdditionalChildPath '..')).Path
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

    $moduleScript = Join-Path $script:RepoRoot 'tools/Install-TestModule.ps1'
    foreach ($name in @('Get-InstalledPester', 'Install-NewestPester', 'Install-PSScriptAnalyzerIfAbsent')) {
        $ast = Get-YurunaTestFunctionAst -Path $moduleScript -Name $name
        if (-not $ast) { throw "$name not found in tools/Install-TestModule.ps1" }
        . ([scriptblock]::Create($ast.Extent.Text))
    }
    $preflight = Join-Path $script:RepoRoot 'tools/Invoke-Preflight.ps1'
    foreach ($name in @('Select-ModuleVersion', 'Get-VersionBoundProblem')) {
        $ast = Get-YurunaTestFunctionAst -Path $preflight -Name $name
        if (-not $ast) { throw "$name not found in tools/Invoke-Preflight.ps1" }
        . ([scriptblock]::Create($ast.Extent.Text))
    }

    # Stand-ins for what Get-Module -ListAvailable returns for each installed copy.
    function Get-StandInModule {
        param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string[]]$Version)
        foreach ($v in $Version) { [pscustomobject]@{ Name = $Name; Version = [version]$v } }
    }
}

Describe 'Install-NewestPester -Major 5' {
    BeforeEach {
        Mock Find-Module { [pscustomobject]@{ Name = 'Pester'; Version = '5.9.1' } }
        Mock Install-Module { }
    }
    It 'installs the newest 5.x beside an older 5.x' {
        Mock Get-Module { Get-StandInModule -Name Pester -Version '5.8.0' } -ParameterFilter { $Name -eq 'Pester' }
        $out = @(Install-NewestPester -Major 5)
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Pester' -and $RequiredVersion -eq '5.9.1' -and $Scope -eq 'CurrentUser' -and $SkipPublisherCheck
        }
        Assert-Match 'installing Pester 5\.9\.1' ($out -join "`n") 'the install is announced with its version'
    }
    It 'asks the gallery only for the 5.x line' {
        # The gallery's newest Pester is a 6.x; an unbounded lookup would answer with it.
        Mock Get-Module { } -ParameterFilter { $Name -eq 'Pester' }
        $null = Install-NewestPester -Major 5
        Should -Invoke Find-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Pester' -and $MinimumVersion -eq '5.0' -and $MaximumVersion -eq '5.999.999'
        }
    }
    It 'does not count a lone Pester 6 as installed' {
        Mock Get-Module { Get-StandInModule -Name Pester -Version '6.2.0' } -ParameterFilter { $Name -eq 'Pester' }
        $null = Install-NewestPester -Major 5
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $RequiredVersion -eq '5.9.1' }
    }
    It 'leaves a host already on the newest 5.x alone, whatever else is installed' {
        Mock Get-Module { Get-StandInModule -Name Pester -Version '4.10.1', '5.9.1', '6.2.0' } -ParameterFilter { $Name -eq 'Pester' }
        $out = @(Install-NewestPester -Major 5)
        Should -Invoke Install-Module -Times 0 -Exactly
        Assert-Match 'Pester 5\.9\.1 is the newest 5\.x' ($out -join "`n") 'the host is reported as current'
    }
    It 'keeps a usable 5.x without an issue when the gallery is unreachable' {
        Mock Get-Module { Get-StandInModule -Name Pester -Version '5.8.0' } -ParameterFilter { $Name -eq 'Pester' }
        Mock Find-Module { throw "Unable to find repository 'PSGallery'." }
        $out = @(Install-NewestPester -Major 5) -join "`n"
        Assert-True ($out -notmatch 'MODULE-ISSUE') 'a host that can already run the suites has no issue to report'
        Assert-Match 'Pester 5\.8\.0 is installed' $out 'the version in use is named'
    }
    It 'reports a host with no usable Pester and no gallery' {
        Mock Get-Module { Get-StandInModule -Name Pester -Version '4.10.1' } -ParameterFilter { $Name -eq 'Pester' }
        Mock Find-Module { throw "Unable to find repository 'PSGallery'." }
        $out = @(Install-NewestPester -Major 5) -join "`n"
        Assert-Match '(?m)^MODULE-ISSUE: Pester 5 is not installed and PSGallery could not be reached' $out 'the gap reaches the closing summary'
    }
    It 'reports a failed install with the version it aimed for' {
        Mock Get-Module { } -ParameterFilter { $Name -eq 'Pester' }
        Mock Install-Module { throw 'disk full' }
        $out = @(Install-NewestPester -Major 5) -join "`n"
        Assert-Match '(?m)^MODULE-ISSUE: Installing Pester 5\.9\.1 failed: disk full' $out 'the failure names the version and the cause'
    }
}

Describe 'Get-InstalledPester' {
    It 'answers from the line it is asked for and no other' {
        Mock Get-Module { Get-StandInModule -Name Pester -Version '5.9.1', '6.2.0' } -ParameterFilter { $Name -eq 'Pester' }
        Assert-StringEqual -Expected '6.2.0' -Actual (Get-InstalledPester -Major 6).Version.ToString() 'the 6.x line answers with its copy'
        Assert-StringEqual -Expected '5.9.1' -Actual (Get-InstalledPester -Major 5).Version.ToString() 'the 5.x line answers with its copy'
    }
    It 'answers nothing for a line that is not installed' {
        Mock Get-Module { Get-StandInModule -Name Pester -Version '5.9.1' } -ParameterFilter { $Name -eq 'Pester' }
        Assert-True ($null -eq (Get-InstalledPester -Major 6)) 'a 5.x alone is not a 6.x'
    }
}

Describe 'Install-NewestPester -Major 6' {
    BeforeEach {
        Mock Find-Module { [pscustomobject]@{ Name = 'Pester'; Version = '6.2.0' } }
        Mock Install-Module { }
    }
    It 'installs the newest 6.x beside an installed 5.x' {
        Mock Get-Module { Get-StandInModule -Name Pester -Version '5.9.1' } -ParameterFilter { $Name -eq 'Pester' }
        $out = @(Install-NewestPester -Major 6)
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Pester' -and $RequiredVersion -eq '6.2.0' -and $Scope -eq 'CurrentUser' -and $SkipPublisherCheck
        }
        Assert-Match 'installing Pester 6\.2\.0' ($out -join "`n") 'the install is announced with its version'
    }
    It 'asks the gallery only for the 6.x line' {
        # The gallery's newest Pester can be on a later major, and an unbounded lookup would answer with it.
        Mock Get-Module { } -ParameterFilter { $Name -eq 'Pester' }
        $null = Install-NewestPester -Major 6
        Should -Invoke Find-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Pester' -and $MinimumVersion -eq '6.0' -and $MaximumVersion -eq '6.999.999'
        }
    }
    It 'does not count a lone Pester 5 as installed' {
        Mock Get-Module { Get-StandInModule -Name Pester -Version '5.9.1' } -ParameterFilter { $Name -eq 'Pester' }
        $null = Install-NewestPester -Major 6
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $RequiredVersion -eq '6.2.0' }
    }
    It 'leaves a host already on the newest 6.x alone, whatever else is installed' {
        Mock Get-Module { Get-StandInModule -Name Pester -Version '5.9.1', '6.1.0', '6.2.0' } -ParameterFilter { $Name -eq 'Pester' }
        $out = @(Install-NewestPester -Major 6)
        Should -Invoke Install-Module -Times 0 -Exactly
        Assert-Match 'Pester 6\.2\.0 is the newest 6\.x' ($out -join "`n") 'the host is reported as current'
    }
    It 'keeps a usable 6.x without an issue when the gallery is unreachable' {
        Mock Get-Module { Get-StandInModule -Name Pester -Version '6.1.0' } -ParameterFilter { $Name -eq 'Pester' }
        Mock Find-Module { throw "Unable to find repository 'PSGallery'." }
        $out = @(Install-NewestPester -Major 6) -join "`n"
        Assert-True ($out -notmatch 'MODULE-ISSUE') 'a host that can already run the 6.x has no issue to report'
        Assert-Match 'Pester 6\.1\.0 is installed' $out 'the version in use is named'
    }
    It 'reports a host with no usable 6.x and no gallery' {
        Mock Get-Module { Get-StandInModule -Name Pester -Version '5.9.1' } -ParameterFilter { $Name -eq 'Pester' }
        Mock Find-Module { throw "Unable to find repository 'PSGallery'." }
        $out = @(Install-NewestPester -Major 6) -join "`n"
        Assert-Match '(?m)^MODULE-ISSUE: Pester 6 is not installed and PSGallery could not be reached' $out 'the gap reaches the closing summary'
    }
    It 'reports a failed install with the version it aimed for' {
        Mock Get-Module { } -ParameterFilter { $Name -eq 'Pester' }
        Mock Install-Module { throw 'disk full' }
        $out = @(Install-NewestPester -Major 6) -join "`n"
        Assert-Match '(?m)^MODULE-ISSUE: Installing Pester 6\.2\.0 failed: disk full' $out 'the failure names the version and the cause'
    }
}

Describe 'Install-PSScriptAnalyzerIfAbsent' {
    BeforeEach { Mock Install-Module { } }
    It 'leaves an installed copy alone' {
        Mock Get-Module { Get-StandInModule -Name PSScriptAnalyzer -Version '1.25.0' } -ParameterFilter { $Name -eq 'PSScriptAnalyzer' }
        $out = @(Install-PSScriptAnalyzerIfAbsent) -join "`n"
        Should -Invoke Install-Module -Times 0 -Exactly
        Assert-Match 'PSScriptAnalyzer 1\.25\.0 already installed' $out 'the installed version is named'
    }
    It 'installs it when absent' {
        Mock Get-Module { } -ParameterFilter { $Name -eq 'PSScriptAnalyzer' }
        $null = Install-PSScriptAnalyzerIfAbsent
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'PSScriptAnalyzer' -and $Scope -eq 'CurrentUser' }
    }
    It 'reports a failed install' {
        Mock Get-Module { } -ParameterFilter { $Name -eq 'PSScriptAnalyzer' }
        Mock Install-Module { throw 'gallery unavailable' }
        $out = @(Install-PSScriptAnalyzerIfAbsent) -join "`n"
        Assert-Match '(?m)^MODULE-ISSUE: Installing PSScriptAnalyzer failed: gallery unavailable' $out 'the failure reaches the closing summary'
    }
}

Describe 'install_test_modules in the macOS and Ubuntu installers' {
    BeforeAll {
        $script:ShellInstallers = @('install/macos.utm.sh', 'install/ubuntu.kvm.sh')
        $script:ShellBody = @{}
        foreach ($installer in $script:ShellInstallers) {
            $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot $installer) -Raw
            $script:ShellBody[$installer] = Get-YurunaTestShellFunction -Text $text -Name 'install_test_modules'
        }
        # pwsh answers with whatever lines and exit code the test chose.
        $script:ShellPrelude = @'
set -euo pipefail
YURUNA_ISSUES=()
log()  { printf 'LOG %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
note_issue() { YURUNA_ISSUES+=("$*"); printf 'ISSUE %s\n' "$*"; }
pwsh() { [[ -f "$FAKE_ROOT/pwsh.out" ]] && cat "$FAKE_ROOT/pwsh.out"; return "${FAKE_PWSH_EXIT:-0}"; }
'@
        function Invoke-InstallTestModuleShell {
            param([Parameter(Mandatory)][string]$Root, [string]$Output = '', [int]$ExitCode = 0, [switch]$NoScript)
            if (-not $NoScript) {
                New-Item -ItemType Directory -Path (Join-Path $Root 'tools') -Force | Out-Null
                Set-Content -LiteralPath (Join-Path $Root 'tools/Install-TestModule.ps1') -Value '# stand-in'
            }
            Set-Content -LiteralPath (Join-Path $Root 'pwsh.out') -Value $Output
            $body = @($script:ShellPrelude, $script:ShellBody['install/ubuntu.kvm.sh'],
                'install_test_modules', 'echo "COUNT ${#YURUNA_ISSUES[@]}"') -join "`n"
            return Invoke-YurunaTestShell -Body $body -Environment @{
                YURUNA_DIR = $Root; FAKE_ROOT = $Root; FAKE_PWSH_EXIT = "$ExitCode"
            }
        }
    }
    It 'is the same function in both installers' {
        # Each installer must run alone from a one-line download, so the relay is
        # duplicated by necessity; this keeps the copies from drifting apart.
        Assert-Equal -Expected $script:ShellBody['install/ubuntu.kvm.sh'] -Actual $script:ShellBody['install/macos.utm.sh'] `
            'install_test_modules differs between the macOS and Ubuntu installers'
    }
    It 'sends MODULE-ISSUE lines to the closing summary and prints the rest' {
        $root = Join-Path $TestDrive 'relay'
        $r = Invoke-InstallTestModuleShell -Root $root -Output (@(
                '  installing Pester 6.2.0 (CurrentUser scope)'
                'MODULE-ISSUE: Installing PSScriptAnalyzer failed: gallery unavailable'
            ) -join "`n")
        Assert-Match '(?m)^  installing Pester 6\.2\.0' $r.Output 'progress lines are printed as they came'
        Assert-Match '(?m)^ISSUE Installing PSScriptAnalyzer failed: gallery unavailable$' $r.Output 'the issue is recorded without its prefix'
        Assert-Match 'COUNT 1' $r.Output 'exactly the one reported problem is recorded'
        Assert-Equal -Expected 0 -Actual $r.ExitCode 'a module problem does not stop the install'
    }
    It 'records a script that could not run at all' {
        $root = Join-Path $TestDrive 'crash'
        $r = Invoke-InstallTestModuleShell -Root $root -Output 'ParserError: unexpected token' -ExitCode 1
        Assert-Match 'ISSUE tools/Install-TestModule\.ps1 could not run \(exit 1\)' $r.Output 'a crash is not mistaken for a clean run'
        Assert-Equal -Expected 0 -Actual $r.ExitCode 'the install continues past it'
    }
    It 'skips without an issue when the checkout carries no script' {
        $root = Join-Path $TestDrive 'absent'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $r = Invoke-InstallTestModuleShell -Root $root -NoScript
        Assert-Match 'WARN tools/Install-TestModule\.ps1 not found' $r.Output 'the skip is said out loud'
        Assert-Match 'COUNT 0' $r.Output 'an older checkout without the script is not an install issue'
    }
}

Describe 'Install-YurunaTestModule in the Windows installer' {
    BeforeAll {
        $ast = Get-YurunaTestFunctionAst -Path (Join-Path $script:RepoRoot 'install/windows.hyper-v.ps1') -Name 'Install-YurunaTestModule'
        if (-not $ast) { throw 'Install-YurunaTestModule not found in install/windows.hyper-v.ps1' }
        . ([scriptblock]::Create($ast.Extent.Text))
        function Write-Step { param([string]$m) Write-Output "STEP $m" }
        function Write-Warn { param([string]$m) $script:Warned.Add($m) }
        function Add-InstallIssue { param([string]$Message) $script:Issues.Add($Message) }
        # A stand-in for tools/Install-TestModule.ps1, run by a real child pwsh.
        function New-ModuleScriptRoot {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: writes a stand-in script under TestDrive, which Pester removes; not user-facing state.')]
            param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Body)
            New-Item -ItemType Directory -Path (Join-Path $Root 'tools') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Root 'tools/Install-TestModule.ps1') -Value $Body
            return $Root
        }
    }
    BeforeEach {
        $script:Issues = [Collections.Generic.List[string]]::new()
        $script:Warned = [Collections.Generic.List[string]]::new()
    }
    It 'sends MODULE-ISSUE lines to the issue list and prints the rest' {
        $root = New-ModuleScriptRoot -Root (Join-Path $TestDrive 'win-relay') -Body @'
Write-Output '  installing Pester 6.2.0 (CurrentUser scope)'
Write-Output 'MODULE-ISSUE: Installing PSScriptAnalyzer failed: gallery unavailable'
exit 0
'@
        $out = @(Install-YurunaTestModule -Root $root) -join "`n"
        Assert-Match '(?m)^  installing Pester 6\.2\.0' $out 'progress lines are printed'
        Assert-Equal -Expected 1 -Actual $script:Issues.Count 'exactly the one reported problem is recorded'
        Assert-StringEqual -Expected 'Installing PSScriptAnalyzer failed: gallery unavailable' -Actual $script:Issues[0] 'the issue is recorded without its prefix'
    }
    It 'records a script that could not run at all' {
        $root = New-ModuleScriptRoot -Root (Join-Path $TestDrive 'win-crash') -Body 'exit 3'
        $null = Install-YurunaTestModule -Root $root
        Assert-Match 'could not run \(exit 3\)' ($script:Issues -join "`n") 'a crash is not mistaken for a clean run'
    }
    It 'drops only Windows PowerShell''s per-user module path for the child, and keeps its own' {
        # Started through powershell.exe, the installer inherits Windows
        # PowerShell's per-user module directory; a module only that directory
        # holds must not count as installed for pwsh. Any other entry, such as a
        # user-scoped PSModulePath, still reaches the child.
        $root = New-ModuleScriptRoot -Root (Join-Path $TestDrive 'win-modpath') -Body @'
Write-Output ('CHILD-PATH: ' + $env:PSModulePath)
exit 0
'@
        $windowsPowerShellUser = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell' | Join-Path -ChildPath 'Modules'
        $custom = Join-Path $TestDrive 'user-scoped-modules'
        $saved = $env:PSModulePath
        try {
            $env:PSModulePath = @($windowsPowerShellUser, $custom, $saved) -join [IO.Path]::PathSeparator
            $out = @(Install-YurunaTestModule -Root $root) -join "`n"
            $child = ($out -split "`n" | Where-Object { $_ -like 'CHILD-PATH: *' } | Select-Object -First 1)
            Assert-NotNull $child 'the child reported its module path'
            $entries = @($child.Substring('CHILD-PATH: '.Length) -split [IO.Path]::PathSeparator)
            Assert-True ($entries -notcontains $windowsPowerShellUser) 'Windows PowerShell''s per-user directory does not reach the child'
            Assert-True ($entries -contains $custom) 'a user-scoped entry still reaches the child'
            Assert-True ($env:PSModulePath.StartsWith($windowsPowerShellUser)) 'the installer keeps its own module path afterwards'
        } finally { $env:PSModulePath = $saved }
    }
    It 'records an issue when pwsh is not on PATH yet' {
        $root = New-ModuleScriptRoot -Root (Join-Path $TestDrive 'win-nopwsh') -Body 'exit 0'
        Mock Get-Command { } -ParameterFilter { $Name -eq 'pwsh' }
        $null = Install-YurunaTestModule -Root $root
        Assert-Match 'pwsh is not on PATH yet' ($script:Issues -join "`n") 'the skipped step reaches the closing summary'
    }
}

Describe 'Invoke-Preflight bounds for Pester' {
    It 'reports the newest copy below the ceiling, not a newer major beside it' {
        Mock Get-Module { Get-StandInModule -Name Pester -Version '5.9.1', '6.2.0', '7.0.0' } -ParameterFilter { $Name -eq 'Pester' }
        $version = Select-ModuleVersion -Name Pester -MaxVersion '7.0'
        Assert-StringEqual -Expected '6.2.0' -Actual $version 'the copy the runner loads is the one reported'
        Assert-StringEqual -Expected '' -Actual (Get-VersionBoundProblem -Version $version -MinVersion '6.0' -MaxVersion '7.0') `
            'a usable 6.x beside a 7.x passes'
    }
    It 'reports a lone newer major by its own version, as outside the bounds' {
        Mock Get-Module { Get-StandInModule -Name Pester -Version '7.0.0' } -ParameterFilter { $Name -eq 'Pester' }
        $version = Select-ModuleVersion -Name Pester -MaxVersion '7.0'
        Assert-StringEqual -Expected '7.0.0' -Actual $version 'the only copy present is the one named'
        Assert-StringEqual -Expected 'found 7.0.0, needs a version below 7.0' `
            -Actual (Get-VersionBoundProblem -Version $version -MinVersion '6.0' -MaxVersion '7.0') 'a 7.x alone fails the row'
    }
    It 'still holds the floor' {
        Assert-StringEqual -Expected 'found 5.9.1, needs 6.0 or newer' `
            -Actual (Get-VersionBoundProblem -Version '5.9.1' -MinVersion '6.0' -MaxVersion '7.0') 'a 5.x fails on the floor'
        Assert-StringEqual -Expected '' -Actual (Get-VersionBoundProblem -Version '7.0.1' -MinVersion '7.0') `
            'a row without a ceiling is unaffected by one'
    }
    It 'gives the Pester row the 6.x bounds' {
        $text = Get-Content -LiteralPath (Join-Path $script:RepoRoot 'tools/Invoke-Preflight.ps1') -Raw
        Assert-Match "Module = 'Pester';[^\r\n]*\r?\n\s*MinVersion = '6\.0'; MaxVersion = '7\.0'" $text `
            'the preflight must refuse a Pester the runner will not load'
    }
}
