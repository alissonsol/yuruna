<#PSScriptInfo
.VERSION 2026.10.11
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
    newest Pester 5.x and PSScriptAnalyzer.
.DESCRIPTION
    The bootstrap installers for every host platform run this once the checkout
    exists, so the version policy is written down once instead of in three
    installers in two languages.

    Pester is held to the 5.x line. tools/Invoke-TestSuite.ps1 refuses Pester 6,
    which removes Assert-MockCalled and Assert-VerifiableMock that suites still
    call, and the gallery's newest Pester is a 6.x -- so an unqualified
    Install-Module would add a version the runner will not load. The newest 5.x
    goes in beside whatever is already present; nothing is removed, and the
    runner selects the highest 5.x it finds.

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
param()

$ErrorActionPreference = 'Stop'

# The highest installed Pester the runner would load, or $null.
function Get-InstalledPester5 {
    [CmdletBinding()]
    param()
    Get-Module -ListAvailable -Name Pester -ErrorAction SilentlyContinue |
        Where-Object { $_.Version -ge [version]'5.0' -and $_.Version -lt [version]'6.0' } |
        Sort-Object Version -Descending | Select-Object -First 1
}

function Install-NewestPester5 {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $installed = Get-InstalledPester5
    try {
        # A range lookup answers with the single newest version inside it.
        $newest = Find-Module -Name Pester -Repository PSGallery -MinimumVersion 5.0 -MaximumVersion 5.999.999 -ErrorAction Stop |
            Select-Object -First 1
    } catch {
        if ($installed) {
            Write-Output "  Pester $($installed.Version) is installed; PSGallery could not be reached to look for a newer 5.x ($($_.Exception.Message))."
        } else {
            Write-Output "MODULE-ISSUE: Pester 5 is not installed and PSGallery could not be reached ($($_.Exception.Message)). Retry with: pwsh -Command 'Install-Module Pester -MaximumVersion 5.999.999 -Scope CurrentUser -SkipPublisherCheck'"
        }
        return
    }
    if ($installed -and $installed.Version -ge [version]"$($newest.Version)") {
        Write-Output "  Pester $($installed.Version) is the newest 5.x"
        return
    }
    Write-Output "  installing Pester $($newest.Version) (CurrentUser scope)"
    try {
        # -SkipPublisherCheck: Windows ships Pester 3.4.0 signed by Microsoft,
        # and Pester 5 carries a different publisher certificate, so without it
        # PowerShellGet refuses the install as a publisher change.
        Install-Module -Name Pester -RequiredVersion "$($newest.Version)" -Repository PSGallery -Scope CurrentUser `
            -Force -SkipPublisherCheck -AllowClobber -ErrorAction Stop
    } catch {
        Write-Output "MODULE-ISSUE: Installing Pester $($newest.Version) failed: $($_.Exception.Message) Retry with: pwsh -Command 'Install-Module Pester -MaximumVersion 5.999.999 -Scope CurrentUser -SkipPublisherCheck'"
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

# Each module reports its own failure, so one that fails does not stop the
# other; the outer catch covers anything neither anticipated.
try {
    Install-NewestPester5
    Install-PSScriptAnalyzerIfAbsent
} catch {
    Write-Output "MODULE-ISSUE: Installing the test modules failed unexpectedly: $($_.Exception.Message)"
}
exit 0
