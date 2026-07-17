<#PSScriptInfo
.VERSION 2026.07.17
.GUID 4206c748-f960-4178-9901-2341a0b2c3d4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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

# Adds the 'automation' subfolder of this repository to the current session's PATH,
# and persists it to the user-level PATH so it survives reboots and new terminal windows.
# Use the script's own directory as the repo root instead of `git rev-parse` -- in some
# environments Git refuses with "fatal: detected dubious ownership in repository" and
# asks the user to add the path to safe.directory, but that path isn't known up front.
$repoRoot = $PSScriptRoot
$automationPath = Join-Path $repoRoot "automation"

if (-not (Test-Path $automationPath)) {
    Write-Error "Automation folder not found: $automationPath"
    return
}

if ($env:PATH -split [IO.Path]::PathSeparator -notcontains $automationPath) {
    $env:PATH = $env:PATH + [IO.Path]::PathSeparator + $automationPath
    Write-Output "Added to current session PATH: $automationPath"
} else {
    Write-Output "Already in current session PATH: $automationPath"
}

# Persist to user-level PATH (survives reboots and new terminal windows)
if ($IsWindows -or $env:OS -eq "Windows_NT") {
    $userPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $userPaths = $userPath -split ";"
    if ($userPaths -notcontains $automationPath) {
        # Append (not prepend) so the automation dir never shadows a
        # system tool of the same name; split+filter drops any empty
        # segment so an empty/edge User PATH can't leave a leading ';'
        # (an empty PATH entry is the current directory on Windows).
        $newUserPath = ((@($userPath -split ';') + $automationPath) | Where-Object { $_ }) -join ';'
        [System.Environment]::SetEnvironmentVariable("PATH", $newUserPath, "User")
        Write-Output "Persisted to user PATH (Windows registry): $automationPath"
        # SetEnvironmentVariable('User') writes the registry but does not broadcast
        # into already-open shells, so the persisted entry only reaches terminals
        # started afterward. The current session was already patched above.
        Write-Output "Open a new terminal for the persisted PATH change to take effect."
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
    $exportLine = "`$env:PATH = `$env:PATH + [IO.Path]::PathSeparator + `"$automationPath`""
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
        # The profile is sourced only by shells started afterward, so the persisted
        # entry reaches new terminals; the current session was already patched above.
        Write-Output "Open a new terminal for the persisted PATH change to take effect."
    } else {
        Write-Output "Already persisted in PowerShell profile: $profilePath"
    }
}
