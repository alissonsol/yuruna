<#PSScriptInfo
.VERSION 2026.11.05
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
    newest Pester 6.x and the pinned PSScriptAnalyzer.
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
    Enable-TestAutomation applies to it, at the version pinned below and only
    after the downloaded package's SHA-512 matches the hash the gallery
    publishes for it; an installed copy stays whatever version it is.

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

# PSGallery modules this script installs by pin: the version and the SHA-512 the
# gallery publishes for the package (its OData PackageHash, base64). The bytes
# are checked before anything is unpacked, so a new upload, or anything that
# answers for the gallery, cannot change the code the lint and the suites load.
# The same pin lives in test/modules/Test.HostGit.psm1, which installs it on a
# host set up without the installers; Test.HostGitInstall keeps every copy
# equal. To move a pin, read the new version's PackageHash from
#   https://www.powershellgallery.com/api/v2/Packages(Id='<name>',Version='<version>')
# and compare it with the SHA-512 of the downloaded .nupkg.
$script:YurunaGalleryModulePin = @{
    'PSScriptAnalyzer' = @{ Version = '1.25.0'; Sha512 = '5/tXMmLmBLqymRSuYpIdJLl8L4i1GbQSd7QD72zhY/FLfRs23HNEmmjlrlqNlQKJGxDCZBMf0YE63ym/ExwWYw==' }
}

# This function also lives in install/windows.hyper-v.ps1, which must run alone
# before any checkout exists; Test.HostGitInstall keeps the two copies equal.
function Install-YurunaPinnedGalleryModule {
    <#
    .SYNOPSIS
        Install one gallery package named in the pin table, refusing any download whose SHA-512 differs from the pin.
    .DESCRIPTION
        Lays the module out the way PowerShellGet does (<root>/<Name>/<Version>/...),
        without the NuGet packaging entries. The files land in a sibling staging
        directory first and move into place in one rename, so an interrupted
        install never leaves a half module that Get-Module -ListAvailable would
        report as installed. Any failure is thrown for the caller to report in
        its own way.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$Name,
        # PowerShell's CurrentUser module directory unless a caller names another:
        # Documents on Windows, the XDG data directory elsewhere.
        [string]$ModuleRoot
    )
    $pin = $script:YurunaGalleryModulePin[$Name]
    if (-not $pin) { throw "$Name has no pinned version" }
    if (-not $ModuleRoot) {
        if ($IsWindows) {
            $ModuleRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell/Modules'
        } else {
            $data = if ($env:XDG_DATA_HOME) { $env:XDG_DATA_HOME } else { Join-Path $HOME '.local/share' }
            $ModuleRoot = Join-Path $data 'powershell/Modules'
        }
    }
    $package = Join-Path ([IO.Path]::GetTempPath()) ("yuruna-$Name-$($pin.Version)-" + [guid]::NewGuid().ToString('N') + '.nupkg')
    $staging = ''
    try {
        $uri = "https://www.powershellgallery.com/api/v2/package/$([uri]::EscapeDataString($Name))/$([uri]::EscapeDataString($pin.Version))"
        Invoke-WebRequest -Uri $uri -OutFile $package -TimeoutSec 300 -MaximumRedirection 5 -ErrorAction Stop | Out-Null
        $sha = [Security.Cryptography.SHA512]::Create()
        try { $actual = [Convert]::ToBase64String($sha.ComputeHash([IO.File]::ReadAllBytes($package))) } finally { $sha.Dispose() }
        if ($actual -cne $pin.Sha512) { throw "the package SHA-512 $actual does not match the pinned $($pin.Sha512)" }
        $nameDir = Join-Path $ModuleRoot $Name
        [void][IO.Directory]::CreateDirectory($nameDir)
        $staging = Join-Path $nameDir (".$($pin.Version)." + [guid]::NewGuid().ToString('N') + '.staging')
        $stagingFull = [IO.Path]::GetFullPath($staging) + [IO.Path]::DirectorySeparatorChar
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($package)
        try {
            foreach ($entry in $zip.Entries) {
                $relative = [uri]::UnescapeDataString($entry.FullName)
                if (-not $entry.Name) { continue }
                if ($relative -eq '[Content_Types].xml' -or $relative -like '_rels/*' -or $relative -like 'package/*' -or
                    ($relative -notmatch '/' -and $relative -like '*.nuspec')) { continue }
                $destination = [IO.Path]::GetFullPath((Join-Path $staging $relative))
                if (-not $destination.StartsWith($stagingFull, [StringComparison]::Ordinal)) {
                    throw "package entry $($entry.FullName) escapes the module directory"
                }
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination, $false)
            }
        } finally { $zip.Dispose() }
        if (-not (Test-Path -LiteralPath (Join-Path $staging "$Name.psd1") -PathType Leaf)) {
            throw "package carries no $Name.psd1 manifest"
        }
        $target = Join-Path $nameDir $pin.Version
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        [IO.Directory]::Move($staging, $target)
    } catch {
        if ($staging) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    } finally {
        Remove-Item -LiteralPath $package -Force -ErrorAction SilentlyContinue
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
    $version = $script:YurunaGalleryModulePin['PSScriptAnalyzer'].Version
    Write-Output "  installing PSScriptAnalyzer $version (CurrentUser scope)"
    try {
        Install-YurunaPinnedGalleryModule -Name 'PSScriptAnalyzer'
    } catch {
        Write-Output "MODULE-ISSUE: Installing PSScriptAnalyzer $version failed: $($_.Exception.Message) Retry with: pwsh -Command 'Install-Module PSScriptAnalyzer -RequiredVersion $version -Scope CurrentUser'"
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
