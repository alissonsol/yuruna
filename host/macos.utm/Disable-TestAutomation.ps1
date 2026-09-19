<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42d0dcad-5f1c-4177-8e40-8f43c9920e55
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
    Restores values captured in status/runtime/host.pre-automation.json and
    removes Yuruna-owned additions. Missing captured values are reported and
    left unchanged. Refuses to restore settings during an active test cycle.
    Service shutdown is opt-in. See https://yuruna.link/42e220c4-0004.

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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# --- REGION: Platform guard
if (-not $IsMacOS) {
    Write-Error (Format-YurunaOperatorMessage -Key 'exceptions.host_bf69280290368131')
    exit 1
}

# --- REGION: Initialize host setup
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostAutomationState.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'test/modules/Test.HostCondition.psm1')       -Force -DisableNameChecking
Import-Module (Join-Path $RepoRoot 'automation/Yuruna.Common.psm1')              -Force -DisableNameChecking

if (-not (Assert-SafeToDisable)) { exit 1 }

# --- REGION: Read captured host settings
$state = Read-HostAutomationState
if (-not $state) {
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b151e82086a9c67b')
    Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_2679edd915af22f8')
}

$restored = [System.Collections.Generic.List[string]]::new()
$skipped  = [System.Collections.Generic.List[string]]::new()

# --- REGION: Script-local helpers
# See https://yuruna.link/42e220c4-0004
# Pass the script's bound cmdlet: WhatIf preferences do not cross module scope.
$Script:DisableCmdlet = $PSCmdlet

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
        -Apply $Apply -Absent $Absent -Cmdlet $Script:DisableCmdlet -Restored $restored -Skipped $skipped
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
            if ($r.ExitCode -ne 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_9a7684fc14fabdb7' -Arguments @{ flag = "$flag"; key = "$key"; v = "$v"; exitCode = "$($r.ExitCode)"; output = "$($r.Output)" }) }
        }.GetNewClosure()
    }
}

# --- REGION: Extended pmset guards
# Read from Get-MacPmsetGuardList so this cannot drift from the set Enable
# applies: a guard added there is restored here without an edit.
foreach ($guard in (Get-MacPmsetGuardList)) {
    $key = $guard.Key
    # A guard the host never carried is normally left alone -- pmset has no
    # delete, and writing a value it never had would be an invention. The
    # exception is the AlwaysApply set, which Enable writes precisely BECAUSE
    # the key was absent: for those the guard list carries the value whose
    # behavior equals absence, so the host really does go back.
    $absentValue = if ($guard.ContainsKey('AbsentEquivalent')) { "$($guard.AbsentEquivalent)" } else { '' }
    $absentBlock = if ($absentValue) {
        {
            $r = Invoke-YurunaSudo -Argument @('pmset', '-a', $key, $absentValue) -TolerateBlocked
            if ($r.ExitCode -ne 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_9e5168a03fb971f1' -Arguments @{ key = "$key"; absentValue = "$absentValue"; exitCode = "$($r.ExitCode)"; output = "$($r.Output)" }) }
        }.GetNewClosure()
    } else { $null }
    Restore-Knob -Name "pmset/guard/$key" -Description "pmset $key" -Apply {
        param($v)
        $r = Invoke-YurunaSudo -Argument @('pmset', '-a', $key, "$v") -TolerateBlocked
        if ($r.ExitCode -ne 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_c3577106b0f799eb' -Arguments @{ key = "$key"; v = "$v"; exitCode = "$($r.ExitCode)"; output = "$($r.Output)" }) }
    }.GetNewClosure() -Absent $absentBlock
}

# --- REGION: Screen saver / screen lock, both domains
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
    # `defaults` takes the host selector BEFORE the verb. Emitted verb-first it
    # binds '-currentHost' as the domain and rejects the rest, so the three
    # ByHost knobs would be neither written nor deleted and "Disable puts the
    # Mac back" would not be true for them. Get-MacDefaultsCommandArgument
    # re-emits the selector where it belongs, from the same knob table the
    # capture and the apply paths use.
    $dWrite  = @(Get-MacDefaultsCommandArgument -Verb 'write'  -DefaultsArgs $spec.Args -Trailing @($spec.Type))
    $dDelete = @(Get-MacDefaultsCommandArgument -Verb 'delete' -DefaultsArgs $spec.Args)
    $dLabel  = ($spec.Args -join ' ')
    $dIsBool = ($spec.Type -eq '-bool')
    Restore-Knob -Name "defaults/$($spec.Key)" -Description $spec.Desc -Apply {
        param($v)
        # A captured value has to be spoken back in the vocabulary of the type it
        # is written as. `defaults read` renders a boolean as 1 / 0, and
        # `defaults write -bool` accepts only true / false / yes / no -- a digit
        # exits 255 with the usage text, so without this translation every
        # boolean knob reports a failed restore and stays exactly as the
        # automation left it.
        $value = if ($dIsBool) { if ("$v".Trim() -in @('0', 'false', 'no', 'NO', 'FALSE')) { 'false' } else { 'true' } } else { "$v" }
        & defaults @dWrite $value
        if ($LASTEXITCODE -ne 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_4e1b665678bb8be4' -Arguments @{ dLabel = "$dLabel"; lASTEXITCODE = "$LASTEXITCODE" }) }
    }.GetNewClosure() -Absent {
        # The key did not exist before automation, so delete rather than write a
        # zero: macOS treats "unset" and "set to the default value" differently
        # in a few of these panes.
        & defaults @dDelete 2>$null
    }.GetNewClosure()
}

# --- REGION: Hot corners
$cornerChanged = $false
foreach ($corner in @('tl', 'tr', 'bl', 'br')) {
    foreach ($part in @('corner', 'modifier')) {
        # Through the same builder as every other knob, even though the dock
        # domain carries no host selector: the rule that a knob table is turned
        # into an argv in one place is what keeps a selector added to one table
        # from being emitted in the wrong position by the site that forgot.
        $dArgs   = @('com.apple.dock', "wvous-$corner-$part")
        $dWrite  = @(Get-MacDefaultsCommandArgument -Verb 'write'  -DefaultsArgs $dArgs -Trailing @('-int'))
        $dDelete = @(Get-MacDefaultsCommandArgument -Verb 'delete' -DefaultsArgs $dArgs)
        $dLabel  = ($dArgs -join ' ')
        $before = $restored.Count
        Restore-Knob -Name "defaults/dock/wvous-$corner-$part" -Description "Hot corner $corner ($part)" -Apply {
            param($v)
            & defaults @dWrite "$v"
            if ($LASTEXITCODE -ne 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_4e1b665678bb8be4' -Arguments @{ dLabel = "$dLabel"; lASTEXITCODE = "$LASTEXITCODE" }) }
        }.GetNewClosure() -Absent {
            & defaults @dDelete 2>$null
        }.GetNewClosure()
        if ($restored.Count -ne $before) { $cornerChanged = $true }
    }
}
if ($cornerChanged -and $PSCmdlet.ShouldProcess('Dock', (Format-YurunaOperatorMessage -Key 'host.operator_9b6d3debb275f79f'))) {
    # The Dock caches hot-corner state; without this the plist is correct and
    # the live behavior is still the automation's until the next login.
    & killall Dock 2>$null
}

# --- REGION: Unified screen lock and auto-logout
Restore-Knob -Name 'sysadminctl/screenLock' -Description (Format-YurunaOperatorMessage -Key 'host.unified_screen_lock_description') -Apply {
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
        throw (Format-YurunaOperatorMessage -Key 'exceptions.host_c499e6600386ccd3' -Arguments @{ text = "$text" })
    }
    # Not Invoke-YurunaSudo: `-password -` leaves sysadminctl reading the
    # ACCOUNT password off whatever stdin it inherits, and it does that with a
    # plain read that never turns terminal echo off -- so an operator typing at
    # its prompt watches their password appear in the clear. The shared helper
    # reads it masked and pipes it in, which is also what keeps it out of argv.
    $r = Set-MacScreenLockState -State $target -Reason "restore the unified screen lock to '$target'"
    if (-not $r.Attempted) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_b719fe2e9aee1899' -Arguments @{ target = "$target"; output = "$($r.Output)"; target2 = "$(Get-MacScreenLockManualCommand -State $target)" }) }
    if ($r.ExitCode -ne 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_35a1dbbdd2006dae' -Arguments @{ target = "$target"; output = "$($r.Output)" }) }
}

Restore-Knob -Name 'autologout' -Description 'Auto-logout delay' -Apply {
    param($v)
    $r = Invoke-YurunaSudo -Argument @('defaults', 'write', '/Library/Preferences/.GlobalPreferences', 'com.apple.autologout.AutoLogOutDelay', '-int', "$v") -TolerateBlocked
    if ($r.ExitCode -ne 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_37d35a4c65c7d70a' -Arguments @{ output = "$($r.Output)" }) }
} -Absent {
    $r = Invoke-YurunaSudo -Argument @('defaults', 'delete', '/Library/Preferences/.GlobalPreferences', 'com.apple.autologout.AutoLogOutDelay') -TolerateBlocked
    if ($r.ExitCode -ne 0) { Write-Verbose "auto-logout delete: $($r.Output)" }
}

# --- REGION: Host clock
Restore-Knob -Name 'networktime' -Description 'Network time' -Apply {
    param($v)
    $onOff = if ("$v" -match 'On') { 'on' } else { 'off' }
    $r = Invoke-YurunaSudo -Argument @('systemsetup', '-setusingnetworktime', $onOff) -TolerateBlocked
    if ($r.ExitCode -ne 0) { throw (Format-YurunaOperatorMessage -Key 'exceptions.host_4ff2b596d293bb78' -Arguments @{ onOff = "$onOff"; output = "$($r.Output)" }) }
}

# --- REGION: Services (opt-in)
if ($StopServices) {
    Stop-YurunaServiceVMSet -RepoRoot $RepoRoot -Cmdlet $PSCmdlet -Restored $restored -Skipped $skipped
}

# --- REGION: Report
Write-DisableReport -Platform 'macos.utm' -Restored $restored -Skipped $skipped

Write-Output ''
Write-Output (Format-YurunaOperatorMessage -Key 'host.operator_87f50089fdd7e8c5')
Write-DisableManualStep -What (Format-YurunaOperatorMessage -Key 'host.operator_9fbf219357a24e5f') -Command @(
    (Format-YurunaOperatorMessage -Key 'host.operator_8da23b13d6bee38a')
)
Write-DisableManualStep -What (Format-YurunaOperatorMessage -Key 'host.operator_dd54e1221e1df026') -Command @(
    (Format-YurunaOperatorMessage -Key 'host.operator_df3396f890eae3df')
)
Write-DisableManualStep -What (Format-YurunaOperatorMessage -Key 'host.operator_51ad715d8bf6eabf')
Write-DisableManualStep -What (Format-YurunaOperatorMessage -Key 'host.operator_c65c4b6881513631') `
    -Command (Get-PoolStorageManualTeardown -RepoRoot $RepoRoot)
Write-DisableManualStep -What (Format-YurunaOperatorMessage -Key 'host.operator_dcce50e7f8a2921d')
Write-DisableCommonEpilogue -StateCaptured ([bool]$state) -StopServices ([bool]$StopServices)
