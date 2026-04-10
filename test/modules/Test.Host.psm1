<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456701
.AUTHOR Alisson Sol
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

#requires -version 7

function Get-HostType {
    <#
    .SYNOPSIS
    Returns "host.macos.utm" or "host.windows.hyper-v" based on the current platform.
    #>
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

function Get-GuestList {
    <#
    .SYNOPSIS
    Returns the ordered list of guest keys to test.
    If the config hashtable contains a "guestOrder" array, that list is used
    (controlling both order and which guests to include).
    Otherwise the full default list is returned.
    #>
    param([hashtable]$Config = @{})

    $default = @("guest.amazon.linux", "guest.ubuntu.desktop", "guest.windows.11")

    if ($Config.guestOrder -and $Config.guestOrder.Count -gt 0) {
        $invalid = $Config.guestOrder | Where-Object { $_ -notin $default }
        if ($invalid) {
            Write-Warning "Unknown guest keys in guestOrder will be ignored: $($invalid -join ', ')"
        }
        return @($Config.guestOrder | Where-Object { $_ -in $default })
    }

    return $default
}

function Test-ElevationRequired {
    <#
    .SYNOPSIS
    Returns $true if the host type requires Administrator elevation.
    #>
    param([string]$HostType)
    return ($HostType -eq "host.windows.hyper-v")
}

function Assert-Elevation {
    <#
    .SYNOPSIS
    Checks elevation if required. Returns $false and writes an error if elevation is needed but absent.
    #>
    param([string]$HostType)
    if (-not (Test-ElevationRequired -HostType $HostType)) { return $true }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
    if (-not $isAdmin) {
        Write-Error "host.windows.hyper-v requires elevation. Re-run Invoke-TestRunner.ps1 as Administrator."
        return $false
    }
    return $true
}

function Assert-Accessibility {
    <#
    .SYNOPSIS
    On macOS, checks that the terminal has Accessibility permission (required for
    AXUIElementPostKeyboardEvent). Returns $true if granted or not on macOS.
    Prints setup instructions and returns $false if the permission is missing.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    # AXIsProcessTrusted() returns true when the calling process has Accessibility access.
    try {
        $jxa = "ObjC.import('ApplicationServices'); $.AXIsProcessTrusted();"
        $result = & osascript -l JavaScript -e $jxa 2>&1
        if ("$result" -eq "true") { return $true }
    } catch {
        Write-Debug "Accessibility check failed: $_"
    }

    Write-Warning "═══════════════════════════════════════════════════════════════════"
    Write-Warning " Accessibility permission is NOT granted for this terminal."
    Write-Warning ""
    Write-Warning " The test harness needs Accessibility access to send keystrokes"
    Write-Warning " to UTM VMs without requiring window focus."
    Write-Warning ""
    Write-Warning " To fix:"
    Write-Warning "   1. Open System Settings > Privacy & Security > Accessibility"
    Write-Warning "   2. Click the + button and add your terminal app"
    Write-Warning "      (Terminal.app, iTerm2, or whichever you use)"
    Write-Warning "   3. Ensure the toggle is ON"
    Write-Warning "   4. Restart the terminal and re-run the test"
    Write-Warning ""
    Write-Warning " Without this permission, keystrokes require UTM to stay focused"
    Write-Warning " and any window change will cause missed input."
    Write-Warning "═══════════════════════════════════════════════════════════════════"
    return $false
}

function Invoke-GitPull {
    <#
    .SYNOPSIS
    Runs git pull in the repo root. Returns $true on success.
    #>
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

    # Local is behind or diverged from remote
    $behind = & git -C $RepoRoot rev-list --count "$local..$remote" 2>$null
    if ($mergeBase -eq $local) {
        # Local is behind — safe to fast-forward pull
        Write-Information "Local branch is behind remote by $behind commit(s). Pulling..." -InformationAction Continue
        $pullOutput = & git -C $RepoRoot pull --ff-only 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Information "Pull succeeded: $pullOutput" -InformationAction Continue
            return $true
        }
        Write-Error "git pull --ff-only failed (exit $LASTEXITCODE): $pullOutput"
        return $false
    }

    # Diverged — local has commits not on remote AND remote has commits not on local
    $ahead = & git -C $RepoRoot rev-list --count "$remote..$local" 2>$null
    Write-Error "Local branch has diverged from remote ($ahead ahead, $behind behind). Rebase or merge manually."
    return $false
}

function Get-CurrentGitCommit {
    <#
    .SYNOPSIS
    Returns the short git commit hash of HEAD.
    #>
    param([string]$RepoRoot)
    $hash = & git -C $RepoRoot rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { return "unknown" }
    return $hash.Trim()
}

Export-ModuleMember -Function Get-HostType, Get-GuestList, Test-ElevationRequired, Assert-Elevation, Assert-Accessibility, Invoke-GitPull, Get-CurrentGitCommit
