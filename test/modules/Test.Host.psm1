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
    Write-Information "Running git pull in: $RepoRoot" -InformationAction Continue
    $output = & git -C $RepoRoot pull 2>&1
    Write-Information "$output" -InformationAction Continue
    if ($LASTEXITCODE -ne 0) {
        Write-Error "git pull failed (exit $LASTEXITCODE)."
        return $false
    }
    return $true
}

# Returns the short git commit hash of HEAD.
function Get-CurrentGitCommit {
    param([string]$RepoRoot)
    $hash = & git -C $RepoRoot rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return "unknown" }
    return $hash.Trim()
}

# Checks that chromedriver.exe exists for the Hyper-V Selenium prerequisite (Windows 11 image download).
function Test-SeleniumPrerequisite {
    param([string]$RepoRoot)
    $seleniumDir = Join-Path $RepoRoot "vde/host.windows.hyper-v/selenium"
    $driverExe   = Join-Path $seleniumDir "chromedriver.exe"
    return (Test-Path $driverExe)
}

Export-ModuleMember -Function Get-HostType, Get-GuestList, Test-ElevationRequired, Assert-Elevation, Invoke-GitPull, Get-CurrentGitCommit, Test-SeleniumPrerequisite
