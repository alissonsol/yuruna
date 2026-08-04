<#PSScriptInfo
.VERSION 2026.08.04
.GUID 422a71b9-84cf-4d16-a903-1b7e6c05d284
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host macos utm disable-test-automation
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
    Restore the macOS host settings Enable-TestAutomation changed.
.DESCRIPTION
    Reads status/runtime/host.pre-automation.json -- written by
    Enable-TestAutomation before it changed anything -- and puts each captured
    knob back:

      * pmset displaysleep / sleep / disksleep, AC and battery SEPARATELY
      * every extended pmset guard (disablesleep, powernap, standby, ...)
      * com.apple.screensaver idleTime / askForPassword / askForPasswordDelay,
        in BOTH the user and -currentHost domains
      * hot corners (wvous-*-corner and -modifier), then killall Dock
      * com.utmapp.UTM NSAppSleepDisabled and KeepRunningAfterLastWindowClosed,
        NSGlobalDomain AppleSpacesSwitchOnActivation
      * sysadminctl -screenLock, the auto-logout delay, and the network-time setting

    Nothing is removed outright on this host: every knob above existed (or
    explicitly did not) before automation, and is restored to exactly that.

    Without a capture file, nothing is changed at all -- there is no additive,
    provably-ours object on macOS to reverse. Everything is reported instead.

    Needs sudo for pmset, the /Library/Preferences write and sysadminctl. The
    cache is primed once, up front, with a reason banner.
.PARAMETER StopServices
    Also stop the caching-proxy, stash, pool-control and download-agent VMs
    this host runs.
.EXAMPLE
    pwsh host/macos.utm/Disable-TestAutomation.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$StopServices
)

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

if (-not $IsMacOS) {
    Write-Error 'Disable-TestAutomation.ps1 (host/macos.utm) only runs on macOS.'
    exit 1
}

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostAutomationState.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostCondition.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Common.psm1')              -Force -DisableNameChecking

if (-not (Assert-SafeToDisable)) { exit 1 }

$state = Read-HostAutomationState
if (-not $state) {
    Write-Warning 'No pre-automation capture on this host (it was enabled before the capture shipped, or the file was removed).'
    Write-Warning 'Nothing will be changed: every macOS knob Enable touches is a pre-existing setting, so with no record of its prior value there is nothing safe to restore.'
}

$restored = [System.Collections.Generic.List[string]]::new()
$skipped  = [System.Collections.Generic.List[string]]::new()

# Thin local shim over the shared driver so the three per-host scripts stay
# readable: -State, -Cmdlet and the two lists are the same on every call.
function Restore-Knob {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Apply,
        [scriptblock]$Absent
    )
    Invoke-HostKnobRestore -State $state -Name $Name -Description $Description `
        -Apply $Apply -Absent $Absent -Cmdlet $PSCmdlet -Restored $restored -Skipped $skipped
}

# Prime sudo once, before the run, with the reasons visible -- the same posture
# Enable uses. Under -WhatIf nothing elevated actually runs, so skip the prompt.
if ($state -and -not $WhatIfPreference) {
    [void](Initialize-SudoCache -Reasons @(
        'pmset (display sleep, system sleep, power-nap, hibernation)',
        'defaults write /Library/Preferences (auto-logout delay)',
        'sysadminctl -screenLock (Sonoma+ unified screen lock)',
        'systemsetup -setusingnetworktime (host clock)'
    ))
}

# --- REGION: pmset display/system/disk sleep, per power source
foreach ($key in @('displaysleep', 'sleep', 'disksleep')) {
    foreach ($scope in @('ac', 'battery')) {
        $flag = if ($scope -eq 'ac') { '-c' } else { '-b' }
        Restore-Knob -Name "pmset/$scope/$key" -Description "pmset $key ($scope)" -Apply {
            param($v)
            $r = Invoke-YurunaSudo -Argument @('pmset', $flag, $key, "$v") -TolerateBlocked
            if ($r.ExitCode -ne 0) { throw "pmset $flag $key $v failed (exit $($r.ExitCode)): $($r.Output)" }
        }.GetNewClosure()
    }
}

# --- REGION: extended pmset guards
# Read from Get-MacPmsetGuardList so this cannot drift from the set Enable
# applies: a guard added there is restored here without an edit.
foreach ($guard in (Get-MacPmsetGuardList)) {
    $key = $guard.Key
    Restore-Knob -Name "pmset/guard/$key" -Description "pmset $key" -Apply {
        param($v)
        $r = Invoke-YurunaSudo -Argument @('pmset', '-a', $key, "$v") -TolerateBlocked
        if ($r.ExitCode -ne 0) { throw "pmset -a $key $v failed (exit $($r.ExitCode)): $($r.Output)" }
    }.GetNewClosure()
}

# --- REGION: screen saver / screen lock, both domains
foreach ($spec in @(
    @{ Key = 'screensaver/user/idleTime'                  ; Args = @('com.apple.screensaver', 'idleTime')                       ; Type = '-int'; Desc = 'Screen saver idle time [user]' }
    @{ Key = 'screensaver/user/askForPassword'            ; Args = @('com.apple.screensaver', 'askForPassword')                 ; Type = '-int'; Desc = 'Screen lock password [user]' }
    @{ Key = 'screensaver/user/askForPasswordDelay'       ; Args = @('com.apple.screensaver', 'askForPasswordDelay')            ; Type = '-int'; Desc = 'Screen lock password delay [user]' }
    @{ Key = 'screensaver/currentHost/idleTime'           ; Args = @('-currentHost', 'com.apple.screensaver', 'idleTime')       ; Type = '-int'; Desc = 'Screen saver idle time [currentHost]' }
    @{ Key = 'screensaver/currentHost/askForPassword'     ; Args = @('-currentHost', 'com.apple.screensaver', 'askForPassword') ; Type = '-int'; Desc = 'Screen lock password [currentHost]' }
    @{ Key = 'screensaver/currentHost/askForPasswordDelay'; Args = @('-currentHost', 'com.apple.screensaver', 'askForPasswordDelay'); Type = '-int'; Desc = 'Screen lock password delay [currentHost]' }
    @{ Key = 'utm/NSAppSleepDisabled'                     ; Args = @('com.utmapp.UTM', 'NSAppSleepDisabled')                    ; Type = '-bool'; Desc = 'UTM app-nap suppression' }
    @{ Key = 'utm/KeepRunningAfterLastWindowClosed'       ; Args = @('com.utmapp.UTM', 'KeepRunningAfterLastWindowClosed')      ; Type = '-bool'; Desc = 'UTM survives its last window closing' }
    @{ Key = 'global/AppleSpacesSwitchOnActivation'       ; Args = @('NSGlobalDomain', 'AppleSpacesSwitchOnActivation')         ; Type = '-bool'; Desc = 'Spaces switch on activation' }
)) {
    $dArgs = $spec.Args; $dType = $spec.Type
    Restore-Knob -Name "defaults/$($spec.Key)" -Description $spec.Desc -Apply {
        param($v)
        & defaults write @dArgs $dType "$v"
        if ($LASTEXITCODE -ne 0) { throw "defaults write $($dArgs -join ' ') failed (exit $LASTEXITCODE)" }
    }.GetNewClosure() -Absent {
        # The key did not exist before automation, so delete rather than write a
        # zero: macOS treats "unset" and "set to the default value" differently
        # in a few of these panes.
        & defaults delete @dArgs 2>$null
    }.GetNewClosure()
}

# --- REGION: hot corners
$cornerChanged = $false
foreach ($corner in @('tl', 'tr', 'bl', 'br')) {
    foreach ($part in @('corner', 'modifier')) {
        $dArgs = @('com.apple.dock', "wvous-$corner-$part")
        $before = $restored.Count
        Restore-Knob -Name "defaults/dock/wvous-$corner-$part" -Description "Hot corner $corner ($part)" -Apply {
            param($v)
            & defaults write @dArgs -int "$v"
            if ($LASTEXITCODE -ne 0) { throw "defaults write $($dArgs -join ' ') failed (exit $LASTEXITCODE)" }
        }.GetNewClosure() -Absent {
            & defaults delete @dArgs 2>$null
        }.GetNewClosure()
        if ($restored.Count -ne $before) { $cornerChanged = $true }
    }
}
if ($cornerChanged -and $PSCmdlet.ShouldProcess('Dock', 'Restart so the restored hot corners take effect')) {
    # The Dock caches hot-corner state; without this the plist is correct and
    # the live behaviour is still the automation's until the next login.
    & killall Dock 2>$null
}

# --- REGION: unified screen lock, auto-logout, network time
Restore-Knob -Name 'sysadminctl/screenLock' -Description 'sysadminctl unified screen lock' -Apply {
    param($v)
    # The captured string is sysadminctl's own status line, e.g.
    #   "screenLock delay is 300.000000 seconds"  /  "screenLock is off"
    #   "screenLock delay is -1.000000 seconds"   (also means off)
    # The fractional part matters: a naive \d+ would capture the "000000" of
    # "300.000000" and restore a six-hundred-thousand-second lock delay.
    $text = "$v"
    $target = ''
    if ($text -match 'screenLock\s+delay\s+is\s+(-?\d+)(?:\.\d+)?\s*seconds') {
        $target = if ([int]$Matches[1] -lt 0) { 'off' } else { $Matches[1] }
    } elseif ($text -match 'screenLock\s+is\s+off') {
        $target = 'off'
    } else {
        throw "the captured status '$text' does not name an interval to restore"
    }
    $r = Invoke-YurunaSudo -Argument @('sysadminctl', '-screenLock', $target, '-password', '-') -TolerateBlocked
    if ($r.ExitCode -ne 0) { throw "sysadminctl -screenLock $target failed: $($r.Output)" }
}

Restore-Knob -Name 'autologout' -Description 'Auto-logout delay' -Apply {
    param($v)
    $r = Invoke-YurunaSudo -Argument @('defaults', 'write', '/Library/Preferences/.GlobalPreferences', 'com.apple.autologout.AutoLogOutDelay', '-int', "$v") -TolerateBlocked
    if ($r.ExitCode -ne 0) { throw "auto-logout write failed: $($r.Output)" }
} -Absent {
    $r = Invoke-YurunaSudo -Argument @('defaults', 'delete', '/Library/Preferences/.GlobalPreferences', 'com.apple.autologout.AutoLogOutDelay') -TolerateBlocked
    if ($r.ExitCode -ne 0) { Write-Verbose "auto-logout delete: $($r.Output)" }
}

Restore-Knob -Name 'networktime' -Description 'Network time' -Apply {
    param($v)
    $onOff = if ("$v" -match 'On') { 'on' } else { 'off' }
    $r = Invoke-YurunaSudo -Argument @('systemsetup', '-setusingnetworktime', $onOff) -TolerateBlocked
    if ($r.ExitCode -ne 0) { throw "systemsetup -setusingnetworktime $onOff failed: $($r.Output)" }
}

# --- REGION: services (opt-in)
if ($StopServices) {
    foreach ($svc in @('CachingProxyService', 'StashService', 'PoolControlService', 'DownloadAgentService')) {
        $script = Join-Path $RepoRoot "test/Stop-${svc}VM.ps1"
        if (-not (Test-Path -LiteralPath $script)) { $skipped.Add("test/Stop-${svc}VM.ps1 not found"); continue }
        if ($PSCmdlet.ShouldProcess("$svc VM", 'Stop')) {
            & pwsh -NoProfile -File $script
            $restored.Add("$svc VM stopped")
        }
    }
}

# --- REGION: report
Write-DisableReport -Platform 'macos.utm' -Restored $restored -Skipped $skipped

Write-Output ''
Write-Output 'NOT reversed (deliberately) -- run these yourself if you want them gone:'
Write-DisableManualStep -What 'Homebrew packages and PSGallery modules (powershell-yaml, PSScriptAnalyzer)' -Command @(
    'Uninstall-Module powershell-yaml, PSScriptAnalyzer'
)
Write-DisableManualStep -What 'Accessibility and Screen Recording (TCC) grants' -Command @(
    'System Settings > Privacy & Security > Accessibility / Screen Recording'
)
Write-DisableManualStep -What 'Cloned repos, VM images and run history under ~/yuruna'
Write-DisableManualStep -What 'networkStorage configuration, the vaulted credential and any mounts' `
    -Command (Get-PoolStorageManualTeardown -RepoRoot $RepoRoot)
Write-DisableManualStep -What "The manual Dock step, if you set it: right-click UTM > Options > Assign To > All Desktops"
# Stated plainly rather than offered as a switch: nothing here removes the
# vault, and a -IncludeVault flag that only silenced this line would advertise a
# removal that never happened.
Write-DisableManualStep -What 'The Yuruna credential vault -- it holds credentials that are painful to recreate, so it is never removed automatically' -Command @(
    'Get-SecretVault                     # find the Yuruna vault',
    'Unregister-SecretVault -Name <name> # then delete its store on disk'
)
if (-not $StopServices) {
    Write-DisableManualStep -What 'The caching-proxy / stash / pool-control / download-agent VMs (re-run with -StopServices to stop them)'
}

$capturePath = Get-HostAutomationStatePath
if ($state -and (Test-Path -LiteralPath $capturePath)) {
    Write-Output ''
    Write-Output "The capture is kept at $capturePath so this can be re-run; delete it once the host is where you want it."
}
