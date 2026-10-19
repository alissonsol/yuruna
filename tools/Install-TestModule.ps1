<#PSScriptInfo
.VERSION 2026.10.18.2
.GUID 42ffd71c-f88c-4908-9c29-47d3a28662d0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna install pester psscriptanalyzer test tooling
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
    Install the PowerShell modules the test suites and the lint need: the
    newest Pester 6.x and PSScriptAnalyzer.
.DESCRIPTION
    The bootstrap installers for every host platform run this once the checkout
    exists, so the version policy is written down once instead of in three
    installers in two languages.

    The runner, the focused gates and the pre-commit test pass all load the
    6.x line, so the newest 6.x is what gets installed, and the runner selects
    the highest 6.x it finds. Nothing is removed: an older line left on a host
    is never loaded, because every tool imports by resolved path inside the
    6.x window. The gallery's newest Pester can sit on a later major, so the
    line is requested by its own bounds rather than by an unqualified
    Install-Module.

    -Check installs nothing. It exits 0 when a 6.x copy is installed and 1 when
    none is, which is the answer the pre-commit test pass reads.

    PSScriptAnalyzer is installed when absent, the same presence policy
    Enable-TestAutomation applies to it.

    Each problem is one `MODULE-ISSUE: <text>` line on stdout, for an installer
    collecting them into its closing summary, and the script still exits 0: a
    missing test module does not stop a host install. A non-zero exit means the
    script itself could not run.
.EXAMPLE
    pwsh -NoProfile -File tools/Install-TestModule.ps1
#>
[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'

# The highest installed Pester on one major line, or $null. A copy on another
# major line does not count toward this one.
function Get-InstalledPester {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Major)
    Get-Module -ListAvailable -Name Pester -ErrorAction SilentlyContinue |
        Where-Object { $_.Version -ge [version]"$Major.0" -and $_.Version -lt [version]"$($Major + 1).0" } |
        Sort-Object Version -Descending | Select-Object -First 1
}

function Install-NewestPester {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][int]$Major)
    $installed = Get-InstalledPester -Major $Major
    try {
        # A range lookup answers with the single newest version inside it.
        $newest = Find-Module -Name Pester -Repository PSGallery -MinimumVersion "$Major.0" -MaximumVersion "$Major.999.999" -ErrorAction Stop |
            Select-Object -First 1
    } catch {
        if ($installed) {
            Write-Output "  Pester $($installed.Version) is installed; PSGallery could not be reached to look for a newer $Major.x ($($_.Exception.Message))."
        } else {
            Write-Output "MODULE-ISSUE: Pester $Major is not installed and PSGallery could not be reached ($($_.Exception.Message)). Retry with: pwsh -Command 'Install-Module Pester -MaximumVersion $Major.999.999 -Scope CurrentUser -SkipPublisherCheck'"
        }
        return
    }
    if ($installed -and $installed.Version -ge [version]"$($newest.Version)") {
        Write-Output "  Pester $($installed.Version) is the newest $Major.x"
        return
    }
    Write-Output "  installing Pester $($newest.Version) (CurrentUser scope)"
    try {
        # -SkipPublisherCheck: Windows ships Pester 3.4.0 signed by Microsoft,
        # and the Pester 5 and 6 packages carry a different publisher certificate,
        # so without it PowerShellGet refuses the install as a publisher change.
        Install-Module -Name Pester -RequiredVersion "$($newest.Version)" -Repository PSGallery -Scope CurrentUser `
            -Force -SkipPublisherCheck -AllowClobber -ErrorAction Stop
    } catch {
        Write-Output "MODULE-ISSUE: Installing Pester $($newest.Version) failed: $($_.Exception.Message) Retry with: pwsh -Command 'Install-Module Pester -MaximumVersion $Major.999.999 -Scope CurrentUser -SkipPublisherCheck'"
    }
}

function Install-PSScriptAnalyzerIfAbsent {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $installed = Get-Module -ListAvailable -Name PSScriptAnalyzer -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($installed) {
        Write-Output "  PSScriptAnalyzer $($installed.Version) already installed"
        return
    }
    Write-Output '  installing PSScriptAnalyzer (CurrentUser scope)'
    try {
        Install-Module -Name PSScriptAnalyzer -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    } catch {
        Write-Output "MODULE-ISSUE: Installing PSScriptAnalyzer failed: $($_.Exception.Message) Retry with: pwsh -Command 'Install-Module PSScriptAnalyzer -Scope CurrentUser'"
    }
}

if ($Check) {
    if (Get-InstalledPester -Major 6) { exit 0 }
    exit 1
}

# Pester and PSScriptAnalyzer report their own failures, so one that fails
# does not stop the other; the catch around each covers anything neither
# anticipated.
try {
    Install-NewestPester -Major 6
} catch {
    Write-Output "MODULE-ISSUE: Installing Pester 6 failed unexpectedly: $($_.Exception.Message)"
}
try {
    Install-PSScriptAnalyzerIfAbsent
} catch {
    Write-Output "MODULE-ISSUE: Installing the test modules failed unexpectedly: $($_.Exception.Message)"
}
exit 0
