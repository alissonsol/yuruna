<#PSScriptInfo
.VERSION 0.1
.GUID 4206c748-f960-4178-9901-2341a0b2c3d4
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2019-2026 Alisson Sol et al.
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

#requires -version 7

# Adds the 'automation' subfolder of this repository to the current session's PATH,
# and persists it to the user-level PATH so it survives reboots and new terminal windows.
$repoRoot = git rev-parse --show-toplevel
$automationPath = Join-Path $repoRoot "automation"

if (-not (Test-Path $automationPath)) {
    Write-Error "Automation folder not found: $automationPath"
    return
}

# Add to current session
if ($env:PATH -split [IO.Path]::PathSeparator -notcontains $automationPath) {
    $env:PATH = $automationPath + [IO.Path]::PathSeparator + $env:PATH
    Write-Output "Added to current session PATH: $automationPath"
} else {
    Write-Output "Already in current session PATH: $automationPath"
}

# Persist to user-level PATH (survives reboots and new terminal windows)
if ($IsWindows -or $env:OS -eq "Windows_NT") {
    $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $userPaths = $userPath -split ";"
    if ($userPaths -notcontains $automationPath) {
        $newUserPath = $automationPath + ";" + $userPath
        [System.Environment]::SetEnvironmentVariable("PATH", $newUserPath, "User")
        Write-Output "Persisted to user PATH (Windows registry): $automationPath"
    } else {
        Write-Output "Already in user PATH (Windows registry): $automationPath"
    }
} else {
    # Linux/macOS: add to PowerShell profile
    $profilePath = $PROFILE.CurrentUserAllHosts
    $profileDir = Split-Path $profilePath -Parent
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    $exportLine = "`$env:PATH = `"$automationPath`" + [IO.Path]::PathSeparator + `$env:PATH"
    $guardStart = "# BEGIN Add-AutomationToPath"
    $guardEnd   = "# END Add-AutomationToPath"
    $block = @"
$guardStart
if (`$env:PATH -split [IO.Path]::PathSeparator -notcontains "$automationPath") {
    $exportLine
}
$guardEnd
"@
    if (-not (Test-Path $profilePath) -or -not (Select-String -Path $profilePath -Pattern ([regex]::Escape($guardStart)) -Quiet)) {
        Add-Content -Path $profilePath -Value "`n$block"
        Write-Output "Persisted to PowerShell profile: $profilePath"
    } else {
        Write-Output "Already persisted in PowerShell profile: $profilePath"
    }
}
