<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456701
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

# Returns "host.macos.utm" or "host.windows.hyper-v" based on the current platform.
function Get-HostType {
    if ($IsMacOS) {
        if (-not (Test-Path "/Applications/UTM.app")) {
            Write-Warning "Running on macOS but UTM not found at /Applications/UTM.app."
        }
        return "host.macos.utm"
    }
    if ($IsWindows) {
        $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
        if (-not $svc) {
            Write-Warning "Running on Windows but Hyper-V service (vmms) not found."
        }
        return "host.windows.hyper-v"
    }
    Write-Error "Unsupported platform. Only macOS (UTM) and Windows (Hyper-V) are supported."
    return $null
}

# Returns the ordered list of guest keys to test.
function Get-GuestList {
    return @("guest.amazon.linux", "guest.ubuntu.desktop", "guest.windows.11")
}

# Returns $true if the host type requires Administrator elevation.
function Test-ElevationRequired {
    param([string]$HostType)
    return ($HostType -eq "host.windows.hyper-v")
}

# Checks elevation if required. Returns $false and writes an error if elevation is needed but absent.
function Assert-Elevation {
    param([string]$HostType)
    if (-not (Test-ElevationRequired -HostType $HostType)) { return $true }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
    if (-not $isAdmin) {
        Write-Error "host.windows.hyper-v requires elevation. Re-run Invoke-TestRunner.ps1 as Administrator."
        return $false
    }
    return $true
}

# Runs git pull in the repo root. Returns $true on success.
function Invoke-GitPull {
    param([string]$RepoRoot)

    # Fetch latest from remote without modifying the working tree
    Write-Information "Fetching remote changes in: $RepoRoot" -InformationAction Continue
    $output = & git -C $RepoRoot fetch 2>&1
    Write-Information "$output" -InformationAction Continue
    if ($LASTEXITCODE -ne 0) {
        Write-Error "git fetch failed (exit $LASTEXITCODE)."
        return $false
    }

    # Determine local vs remote HEAD positions
    $local  = & git -C $RepoRoot rev-parse HEAD 2>$null
    $remote = & git -C $RepoRoot rev-parse '@{u}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Information "No upstream tracking branch found; skipping ahead/behind check." -InformationAction Continue
        return $true
    }

    if ($local -eq $remote) {
        Write-Information "Local branch is up to date with remote." -InformationAction Continue
        return $true
    }

    $mergeBase = & git -C $RepoRoot merge-base $local $remote 2>$null

    if ($mergeBase -eq $remote) {
        # Local is ahead of remote — local commits not yet pushed; that's fine
        Write-Information "Local branch is ahead of remote. Proceeding with local changes." -InformationAction Continue
        return $true
    }

    # Local is behind (or diverged from) remote
    $behind = & git -C $RepoRoot rev-list --count "$local..$remote" 2>$null
    if ($mergeBase -eq $local) {
        Write-Error "Local branch is behind remote by $behind commit(s). Pull or rebase before running tests."
    } else {
        Write-Error "Local branch has diverged from remote (behind by $behind commit(s)). Resolve before running tests."
    }
    return $false
}

# Returns the short git commit hash of HEAD.
function Get-CurrentGitCommit {
    param([string]$RepoRoot)
    $hash = & git -C $RepoRoot rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return "unknown" }
    return $hash.Trim()
}

# Checks that chromedriver exists for the Selenium prerequisite (Windows 11 image download).
function Test-SeleniumPrerequisite {
    param([string]$RepoRoot)
    $seleniumDir = Join-Path $RepoRoot "test/selenium"
    $driverName  = if ($IsWindows) { "chromedriver.exe" } else { "chromedriver" }
    $driverExe   = Join-Path $seleniumDir $driverName
    return (Test-Path $driverExe)
}

Export-ModuleMember -Function Get-HostType, Get-GuestList, Test-ElevationRequired, Assert-Elevation, Invoke-GitPull, Get-CurrentGitCommit, Test-SeleniumPrerequisite
