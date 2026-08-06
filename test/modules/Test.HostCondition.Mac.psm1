<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42d4a3b2-c1f0-4e89-5678-9a0b1c2d3e40
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host macos
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

# macOS sibling of Test.HostCondition.psm1: applies AND asserts the
# per-host preconditions for unattended VM testing on host.macos.utm
# (display sleep / screen lock, Accessibility + Screen Recording TCC
# grants, sudo cache priming). Loaded by the Test.HostCondition.psm1
# facade; callers continue to import the facade and resolve these
# names through its Export-ModuleMember. See Test.HostCondition.psm1
# for the per-platform split rationale.

# Test-YurunaCanPrompt: whether a question asked from this process can reach a
# person. One block here needs an interactive account password on top of root,
# and that is a different question from "can this process elevate".
Import-Module (Join-Path -Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) -ChildPath 'automation' -AdditionalChildPath 'Yuruna.Common.psm1') -Global -Force -DisableNameChecking

function Get-MacPmsetGuardList {
    <#
    .SYNOPSIS
    The canonical extended-pmset guard list (key + wanted value) that keeps
    macOS awake and CG-enumerable for unattended UTM capture. Consumed by BOTH
    Set-MacHostConditionSet (to apply + decide re-apply) and Assert-ScreenLock
    (to re-verify before each cycle), so the asserted set is exactly the applied
    set -- a host that drifts (MDM re-enables a guard, pmset reverts on an OS
    update) fails the gate instead of blanking UTM mid-run. Per-key rationale at
    https://yuruna.link/host/macos.

    A key absent from `pmset -g custom` normally counts as "this macOS no longer
    surfaces it under that name" and is left alone. AlwaysApply marks the keys
    where absence proves nothing instead -- Set- writes those unconditionally.

    AbsentEquivalent is the value whose BEHAVIOUR equals the key not being set,
    and only AlwaysApply keys need one: they are the keys written on a host that
    had no prior value, and pmset has no delete, so without it Disable has
    nothing to put back and the guard outlives the automation that added it.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param()
    return @(
        # AlwaysApply: macOS does not list disablesleep in `pmset -g custom`
        # until it has been written at least once, so on a Mac that never had
        # it set -- the exact host that needs it -- absence would otherwise read
        # as "already 1" and the write would never happen. With disablesleep 0 a
        # MacBook suspends the moment its lid closes, taking every running guest
        # and the rest of the cycle down with it.
        # AbsentEquivalent 0: a Mac that has never had disablesleep written
        # behaves exactly as one holding 0 -- it suspends on lid close -- so 0
        # is what returns the host to where it was, not a guess at a default.
        @{ Key = 'disablesleep'  ; Want = 1 ; AlwaysApply = $true ; AbsentEquivalent = 0 }
        @{ Key = 'powernap'      ; Want = 0 }
        @{ Key = 'standby'       ; Want = 0 }
        @{ Key = 'standbydelay'  ; Want = 0 }
        @{ Key = 'autopoweroff'  ; Want = 0 }
        @{ Key = 'hibernatemode' ; Want = 0 }
        @{ Key = 'ttyskeepawake' ; Want = 1 }
        @{ Key = 'tcpkeepalive'  ; Want = 1 }
        @{ Key = 'proximitywake' ; Want = 0 }
    )
}

function Get-MacPmsetGuardPending {
    <#
    .SYNOPSIS
    The guards that still need `sudo pmset -a <key> <want>`, decided from the
    output of `pmset -g custom`.
    .DESCRIPTION
    Kept as a pure function of that output so the rule can be exercised without
    a Mac (Test.HostConditionMacPmset.Tests.ps1) -- the alternative is a rule
    that only ever runs on the one host it is supposed to protect.

    A key present with the wrong value is pending. A key macOS does not list is
    NOT pending: absence means this release renamed or dropped it, and writing a
    name pmset no longer knows buys nothing but a sudo prompt. AlwaysApply keys
    invert that -- for those, absence carries no information at all (see
    Get-MacPmsetGuardList), so they are pending until they read back correct.
    .PARAMETER PmsetCustom
    The lines of `pmset -g custom`. Empty (pmset absent or failed) leaves every
    non-AlwaysApply guard alone rather than guessing.
    .PARAMETER Guard
    Guard entries to evaluate; defaults to the canonical Get-MacPmsetGuardList.
    .OUTPUTS
    The subset of Guard needing a write, in list order.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string[]]$PmsetCustom,
        [object[]]$Guard
    )
    if (-not $Guard) { $Guard = Get-MacPmsetGuardList }
    $pending = @()
    foreach ($g in $Guard) {
        # Every block pmset prints (Battery Power / AC Power / UPS Power) counts,
        # not just the first one: the writes go out with `-a`, so a key that is
        # right on battery and wrong on AC is drift that still needs re-applying.
        $lines = @($PmsetCustom | Select-String -Pattern ('^\s*' + [regex]::Escape($g.Key) + '\s+(\d+)'))
        if ($lines.Count -gt 0) {
            if (@($lines | Where-Object { [int]$_.Matches[0].Groups[1].Value -ne $g.Want }).Count -gt 0) { $pending += $g }
        } elseif ($g.AlwaysApply) {
            $pending += $g
        }
    }
    return @($pending)
}

function Get-MacDefaultsCommandArgument {
    <#
    .SYNOPSIS
    Assemble a complete `defaults` argument vector with the host selector ahead
    of the verb.
    .DESCRIPTION
    `defaults` takes its host selector BEFORE the verb --
    `defaults -currentHost write <domain> <key> -int 0`. Emitted verb-first it
    binds '-currentHost' as the DOMAIN and then rejects the type flag
    ("Unexpected argument -int; leaving defaults unchanged"), so the write
    exits non-zero having changed nothing and the matching read reports the key
    absent. Nothing about that is visible in a read-back of the intended
    domain, which is why the failure survives as a warning that no amount of
    re-running can clear.

    The knob tables in this repo carry the selector inside the domain+key
    vector because that is how the pair reads at the call site (capture, apply
    and restore all name the same knob). Splitting it back out has to happen in
    one place, or the three sites drift apart again.
    .PARAMETER Verb
    read / write / delete.
    .PARAMETER DefaultsArgs
    Domain + key, optionally led by '-currentHost' or '-host <name>'.
    .PARAMETER Trailing
    Anything that follows the key -- the type flag and the value on a write.
    .OUTPUTS
    [string[]] the full argv for `defaults`.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][ValidateSet('read', 'write', 'delete')][string]$Verb,
        [string[]]$DefaultsArgs = @(),
        [string[]]$Trailing = @()
    )
    $selector = @()
    $rest = @()
    $i = 0
    while ($i -lt $DefaultsArgs.Count) {
        $token = "$($DefaultsArgs[$i])"
        if ($token -eq '-currentHost') { $selector += $token; $i++; continue }
        # -host takes the host name as a separate token; both belong ahead of
        # the verb, and splitting them would produce `defaults -host read <name>`.
        if ($token -eq '-host' -and ($i + 1) -lt $DefaultsArgs.Count) {
            $selector += $token
            $selector += "$($DefaultsArgs[$i + 1])"
            $i += 2
            continue
        }
        break
    }
    for (; $i -lt $DefaultsArgs.Count; $i++) { $rest += "$($DefaultsArgs[$i])" }
    return [string[]]@($selector + @($Verb) + $rest + @($Trailing))
}

function Confirm-MacDefaultWrite {
    <#
    .SYNOPSIS
    Write a `defaults` key, then re-read it and confirm it took. A bare
    `defaults write ... 2>$null | Out-Null` swallows the exit code, so a
    failed write (locked domain, MDM-reverted key, typo) reads back as
    silent success. This writes, re-reads, and Write-Warnings when the value
    doesn't match -- callers gate $changed on the returned [bool] so a phantom
    success can't claim the host was configured when it wasn't.
    .PARAMETER DefaultsArgs
    The arguments that select the domain + key -- e.g.
    @('com.apple.dock','wvous-tl-corner') or
    @('-currentHost','com.apple.screensaver','askForPasswordDelay'). A leading
    '-currentHost' / '-host <name>' selector is re-emitted ahead of the verb by
    Get-MacDefaultsCommandArgument, which is where `defaults` requires it.
    .PARAMETER WriteType
    The value-type flag for the write, e.g. '-int' or '-bool'.
    .PARAMETER WriteValue
    The value to write, e.g. '0', '2147483647', 'YES', 'false'.
    .PARAMETER ExpectRead
    What `defaults read` returns for that written value once stored (defaults
    normalizes -bool YES/true->1, NO/false->0, and echoes -int values). The
    re-read is trimmed and compared ordinally against this.
    .OUTPUTS
    [bool] $true when the re-read matches ExpectRead; $false (with a warning)
    otherwise.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$DefaultsArgs,
        [string]$WriteType,
        [string]$WriteValue,
        [string]$ExpectRead
    )
    & defaults @(Get-MacDefaultsCommandArgument -Verb 'write' -DefaultsArgs $DefaultsArgs -Trailing @($WriteType, $WriteValue)) 2>$null | Out-Null
    $writeExit = $LASTEXITCODE
    $readBack = & defaults @(Get-MacDefaultsCommandArgument -Verb 'read' -DefaultsArgs $DefaultsArgs) 2>$null
    $readOk = ($LASTEXITCODE -eq 0)
    if ($readOk -and "$readBack".Trim() -eq $ExpectRead) { return $true }
    $actual = if ($readOk) { "$readBack".Trim() } else { '<unset>' }
    # The write's own exit code is part of the diagnosis: a rejected argument
    # vector and an MDM-reverted value both read back wrong, and only the code
    # separates "defaults refused the command" from "defaults accepted it and
    # something else put the value back".
    $why = if ($writeExit -ne 0) { " The write itself exited $writeExit." } else { ' The domain may be locked or MDM-managed.' }
    Write-Warning ("defaults write {0} {1} {2} did not take (read back '{3}', wanted '{4}').{5}" -f ($DefaultsArgs -join ' '), $WriteType, $WriteValue, $actual, $ExpectRead, $why)
    return $false
}

function Get-MacDangerousHotCornerMap {
    <#
    .SYNOPSIS
    The canonical map of hot-corner action codes (as they appear in
    `defaults read com.apple.dock wvous-<corner>-corner`) that blank or lock
    the display during an unattended run and drop the UTM window from the CG
    window list. Shared by BOTH Assert-ScreenLock (to flag a dangerous
    binding) and Set-MacHostConditionSet (to neutralize it), so the asserted
    set is exactly the applied set -- a code added to one path can't silently
    be missed by the other. Safe codes (0=none, 2=Mission Control,
    3=Show App Windows, 4=Desktop, 11=Launchpad, 12=Notification Center,
    14=Quick Note) are intentionally absent and left untouched.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    # Keys are digit strings ('5'/'10'/'13') matched against trimmed
    # `defaults read` output, so the default case-insensitive @{} is safe --
    # digits have no case to collide.
    return @{
        '5'  = 'Start Screen Saver'
        '10' = 'Put Display to Sleep'
        '13' = 'Lock Screen'
    }
}

function Get-MacScreenLockDisabled {
    <#
    .SYNOPSIS
    Parse `sysadminctl -screenLock status` output: strip the macOS NSLog
    prefix ("YYYY-MM-DD ... sysadminctl[pid:tid] ") and decide whether the
    unified screen lock is disabled. Shared by Assert-ScreenLock and
    Set-MacHostConditionSet so the strip regex and the accepted "off" forms
    ("screenLock is off" OR "delay is -1") can't diverge between the gate and
    the apply path.
    .PARAMETER Raw
    The raw first line captured from `sysadminctl -screenLock status 2>&1`.
    .OUTPUTS
    [pscustomobject] with .Status (NSLog-stripped text for messages) and
    .Disabled ([bool] $true when the lock is off / delay is -1).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Raw)
    $status = "$Raw" -replace '^\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+\s+sysadminctl\[\d+:\w+\]\s+', ''
    return [pscustomobject]@{
        Status   = $status
        Disabled = ($status -match 'screenLock\s+(is\s+off|delay\s+is\s+-1)')
    }
}

function Assert-ScreenLock {
    <#
    .SYNOPSIS
    macOS: verify screen saver lock and display sleep won't blank the
    screen during long-running VM tests. Returns $true if settings are
    acceptable (or not on macOS). Prints instructions and returns $false
    otherwise.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    $issues = @()

    # 1. Display sleep idle time (pmset -g custom -> displaysleep).
    #    0 = never sleep (good); > 0 means display will blank.
    try {
        $pmsetLine = & pmset -g custom 2>$null | Select-String '^\s*displaysleep\s+(\d+)' | Select-Object -First 1
        if ($pmsetLine -and $pmsetLine.Matches[0].Groups[1].Value -ne "0") {
            $sleepMinutes = $pmsetLine.Matches[0].Groups[1].Value
            $issues += "Display sleep is set to $sleepMinutes minute(s)."
        }
    } catch {
        Write-Debug "pmset check failed: $_"
    }

    # 2. Screen saver idleTime (defaults read com.apple.screensaver idleTime).
    #    0 = disabled. A MISSING key is NOT safe -- macOS falls back to
    #    a built-in default (~1200s), which lets the screensaver engage
    #    after 20 min despite the script reporting "already disabled".
    #    Flag both missing AND non-zero. Check per-host domain too;
    #    either being unsafe engages the saver.
    try {
        $idleTime     = & defaults read              com.apple.screensaver idleTime 2>$null
        $idleTimeHead = $LASTEXITCODE
        $idleTimeHost = & defaults -currentHost read com.apple.screensaver idleTime 2>$null
        $idleTimeHostHead = $LASTEXITCODE
        if ($idleTimeHead -ne 0) {
            $issues += "Screen saver idleTime is unset (user domain) -- macOS default applies (~20 min)."
        } elseif ("$idleTime".Trim() -ne "0") {
            $issues += "Screen saver activates after $($idleTime.Trim()) second(s) (user domain)."
        }
        if ($idleTimeHostHead -ne 0) {
            $issues += "Screen saver idleTime is unset (currentHost) -- macOS default applies (~20 min)."
        } elseif ("$idleTimeHost".Trim() -ne "0") {
            $issues += "Screen saver activates after $($idleTimeHost.Trim()) second(s) (currentHost)."
        }
    } catch {
        Write-Debug "Screen saver check failed: $_"
    }

    # 3. Password after screen saver (askForPassword). Missing key on
    #    some macOS versions defaults to 1 (on) -- flag missing AND
    #    explicit 1. Check both domains.
    try {
        $askPw     = & defaults read              com.apple.screensaver askForPassword 2>$null
        $askPwHead = $LASTEXITCODE
        $askPwHost = & defaults -currentHost read com.apple.screensaver askForPassword 2>$null
        $askPwHostHead = $LASTEXITCODE
        if ($askPwHead -ne 0) {
            $issues += "Screen lock askForPassword is unset (user domain) -- macOS default may be 1."
        } elseif ("$askPw".Trim() -eq "1") {
            $issues += "Screen lock (password after screen saver) is enabled (user domain)."
        }
        if ($askPwHostHead -ne 0) {
            $issues += "Screen lock askForPassword is unset (currentHost) -- macOS default may be 1."
        } elseif ("$askPwHost".Trim() -eq "1") {
            $issues += "Screen lock (password after screen saver) is enabled (currentHost)."
        }
    } catch {
        Write-Debug "Screen lock password check failed: $_"
    }

    # 4. Hot corners bound to Start Screen Saver / Sleep Display / Lock
    #    Screen. A drifting cursor during an unattended run can trigger
    #    these and drop the UTM window from CGWindowList.
    try {
        $dangerousCorners = Get-MacDangerousHotCornerMap
        foreach ($corner in @('tl','tr','bl','br')) {
            $val = & defaults read com.apple.dock "wvous-$corner-corner" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $valTrim = "$val".Trim()
                if ($dangerousCorners.ContainsKey($valTrim)) {
                    $issues += "Hot corner '$corner' triggers '$($dangerousCorners[$valTrim])'."
                }
            }
        }
    } catch {
        Write-Debug "Hot-corner check failed: $_"
    }

    # 5. App Nap suppressed for UTM.app -- else macOS throttles UTM's UI
    #    thread and drops its window from CGWindowList even while the VM
    #    runs. Matches "UTM window for '<vm>' not found" symptom.
    try {
        $nap = & defaults read com.utmapp.UTM NSAppSleepDisabled 2>$null
        if ($LASTEXITCODE -ne 0 -or "$nap".Trim() -ne '1') {
            $issues += "App Nap is not suppressed for UTM.app (com.utmapp.UTM NSAppSleepDisabled not set to 1)."
        }
    } catch {
        Write-Debug "App Nap check failed: $_"
    }

    # 5b. UTM outlives its last window. Without this, closing the last
    #     window terminates UTM, and UTM's termination path saves the
    #     state of every running VM -- the service VMs the cycle depends
    #     on come back `suspended` instead of running.
    try {
        $keepRunning = & defaults read com.utmapp.UTM KeepRunningAfterLastWindowClosed 2>$null
        if ($LASTEXITCODE -ne 0 -or "$keepRunning".Trim() -ne '1') {
            $issues += "UTM.app quits with its last window (com.utmapp.UTM KeepRunningAfterLastWindowClosed not set to 1); closing a VM window would suspend every running VM."
        }
    } catch {
        Write-Debug "UTM last-window-closed check failed: $_"
    }

    # 6. sysadminctl unified screen lock (Ventura+). Overrides legacy
    #    askForPassword* keys -- the machine can still lock even when
    #    every individual defaults key is "safe". Accepted "disabled"
    #    forms from sysadminctl -screenLock status:
    #      * "screenLock delay is -1(.000000) seconds"
    #      * "screenLock is off"
    #    Anything else (e.g. "delay is 300 seconds") means a lock delay is active.
    try {
        $slParsed = Get-MacScreenLockDisabled -Raw (& sysadminctl -screenLock status 2>&1 | Select-Object -First 1)
        if (-not $slParsed.Disabled) {
            $issues += "sysadminctl $($slParsed.Status)"
        }
    } catch {
        Write-Debug "sysadminctl -screenLock check failed: $_"
    }

    # 7. Auto-logout after inactivity ("Log out after N minutes" in
    #    Security / Advanced). Kicks user to loginwindow -- same
    #    password-demand symptom as a lock. System-level pref;
    #    world-readable, no sudo.
    try {
        $autoLogout = & defaults read /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay 2>$null
        if ($LASTEXITCODE -eq 0 -and "$autoLogout".Trim() -ne "0") {
            $issues += "Auto-logout is active after $($autoLogout.Trim())s of inactivity (AutoLogOutDelay)."
        }
    } catch {
        Write-Debug "AutoLogOutDelay check failed: $_"
    }

    # 8. System sleep + disk sleep -> Never. Display-sleep alone (sec 1) isn't
    #    enough: a system/disk-sleep wake re-locks the screen on Ventura+
    #    regardless of screensaver settings. Set-MacHostConditionSet disables
    #    both, so the gate must re-verify them.
    # 9. Extended pmset guards (Power Nap, standby, autopoweroff, hibernate, ...)
    #    that Set-MacHostConditionSet applies. The gate re-verifies them from the
    #    same Get-MacPmsetGuardList Set- applies, so the asserted set is exactly
    #    the applied set and a drifted host fails here instead of blanking UTM
    #    mid-run. A key absent from 'pmset -g custom' (macOS-version dependent) is
    #    skipped here even when Set- force-writes it (AlwaysApply): a Mac with no
    #    lid never surfaces disablesleep at all, and failing the gate on a key
    #    that host cannot have would block a perfectly good desktop test host.
    #    A laptop that drifts back to 0 does list the key, so it still fails here.
    try {
        $pmCustom = & pmset -g custom 2>$null
        foreach ($k in @('sleep', 'disksleep')) {
            $line = $pmCustom | Select-String -Pattern ('^\s*' + $k + '\s+(\d+)') | Select-Object -First 1
            if ($line -and [int]$line.Matches[0].Groups[1].Value -ne 0) {
                $issues += "$k is set to $($line.Matches[0].Groups[1].Value) minute(s) -- a wake re-locks the screen (should be 0 / Never)."
            }
        }
        foreach ($g in (Get-MacPmsetGuardList)) {
            $gLine = $pmCustom | Select-String -Pattern ('^\s*' + [regex]::Escape($g.Key) + '\s+(\d+)') | Select-Object -First 1
            if ($gLine -and [int]$gLine.Matches[0].Groups[1].Value -ne $g.Want) {
                $issues += "pmset $($g.Key) is $($gLine.Matches[0].Groups[1].Value) (should be $($g.Want))."
            }
        }
    } catch {
        Write-Debug "pmset system-sleep / extended-guard check failed: $_"
    }

    if ($issues.Count -eq 0) { return $true }

    Write-Warning "==================================================================="
    Write-Warning " Screen lock / display sleep settings will blank the VM display."
    Write-Warning ""
    foreach ($issue in $issues) {
        Write-Warning "  * $issue"
    }
    Write-Warning ""
    Write-Warning " When the display blanks, UTM screen captures return a black"
    Write-Warning " image and OCR-based waitForText steps will time out."
    Write-Warning ""
    Write-Warning " Quick fix -- run from the repo root:"
    Write-Warning "   pwsh ./host/macos.utm/Enable-TestAutomation.ps1"
    Write-Warning ""
    Write-Warning " Or manually in System Settings:"
    Write-Warning "   1. Displays > Advanced > Prevent automatic sleeping when"
    Write-Warning "      the display is off  -> ON"
    Write-Warning "   2. Lock Screen > Start Screen Saver when inactive -> Never"
    Write-Warning "   3. Lock Screen > Require password after screen saver -> OFF"
    Write-Warning "   4. Energy > Turn display off -> Never  (or run:"
    Write-Warning "        sudo pmset -c displaysleep 0"
    Write-Warning "        sudo pmset -b displaysleep 0 )"
    Write-Warning "==================================================================="
    return $false
}

function Test-MacSudoAvailable {
<#
.SYNOPSIS
    Whether this process can run ONE privileged command right now without a
    password prompt.
.DESCRIPTION
    The only source that can answer is sudo itself. A credential timestamp
    expires on its own clock (~5 minutes by default), a Homebrew cask
    post-install script can invalidate it with `sudo -k`, and an
    /etc/sudoers.d NOPASSWD rule can make elevation available with no
    timestamp at all. No environment variable tracks any of that, so a flag
    exported by whoever started the run answers a different question than the
    one a privileged write needs answered.

    Asking before every privileged block matters because sudo reads its
    password from /dev/tty, not from stdin. A child whose stdout is captured
    to a log and whose stdin is closed can still raise a password prompt on
    the terminal its parent has taken over -- where nothing displays it and
    nothing answers it. Probing first, and issuing every write with -n, turns
    that stall into an immediate answer.

    Cheap enough to call per block: `sudo -n true` neither prompts nor
    refreshes the timestamp.
.OUTPUTS
    [bool] $true when `sudo -n true` succeeds.
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    # Pinned locally: a non-zero exit IS the answer this function returns, and
    # with $PSNativeCommandUseErrorActionPreference true a cold timestamp throws
    # instead -- so the probe that exists to keep a host from stalling would
    # itself abort the settings pass on exactly the hosts it was written for.
    $PSNativeCommandUseErrorActionPreference = $false
    if (-not (Get-Command sudo -ErrorAction SilentlyContinue)) { return $false }
    & sudo -n true 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Initialize-SudoCache {
<#
.SYNOPSIS
    Prime the sudo credential cache once, with a friendly notice, so a
    long sequence of subsequent sudo calls runs without re-prompting.
.DESCRIPTION
    Host-prep PowerShell scripts (Set-MacHostConditionSet, the per-host
    Enable-TestAutomation.ps1 family) make many sudo invocations in
    succession -- pmset, defaults write /Library/Preferences,
    sysadminctl, systemctl, virsh net-*. With a default macOS / Linux
    sudoers config those share a per-tty timestamp that lasts ~5 min,
    so a single `sudo -v` up front is enough to keep the rest silent.
    Without this, the operator sees "[sudo] password for ..." on every
    individual call.

    Idempotent: if `sudo -n true` already succeeds (cache warm because
    the install/<host>.sh wrapper primed it, or a prior call in this
    pwsh process already cached), the function returns silently with no
    output and no prompt. Skipped entirely when running as root.

    NEVER prompts when $env:YURUNA_NONINTERACTIVE is '1' (the test runner
    sets it around every inner spawn): it returns $false silently instead.
    On an unattended host a prompt blocks the inherited terminal with
    nobody present to answer, so elevation there has to come from a
    launch-time prime or an /etc/sudoers.d drop-in, never from here.

    Designed to be called at the very top of any PowerShell script /
    function that will make multiple sudo calls in a row.
.PARAMETER Reasons
    One-line descriptions of what the caller will do with sudo. Printed
    inside a fenced box just above the password prompt so the operator
    knows why they are being asked. Empty array prints a generic notice.
.OUTPUTS
    [bool] $true on success (cache is now warm or no elevation needed),
    $false on failure (sudo missing, user canceled, wrong password).
    Never throws -- callers decide whether to proceed.
.EXAMPLE
    if (-not (Initialize-SudoCache -Reasons @('pmset display sleep', 'defaults write /Library/Preferences'))) {
        throw "Cannot proceed without sudo."
    }
#>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'The notice must reach the terminal the operator is watching, immediately above sudo''s own prompt. Every caller wraps this in [void](...), which discards the success stream -- so an information-stream notice is exactly what went missing and left operators facing an unexplained password prompt.')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string[]]$Reasons = @()
    )
    # Pinned locally: the warm-cache fast path below decides on the exit code of a
    # `sudo -n true` that is EXPECTED to fail on a cold timestamp, and the cold
    # path is the whole reason this function exists.
    $PSNativeCommandUseErrorActionPreference = $false
    # Windows has no sudo (UAC is a different model); only run on macOS / Linux.
    if (-not ($IsLinux -or $IsMacOS)) { return $true }
    # Already root: no sudo needed.
    try {
        $uid = (& '/usr/bin/id' -u 2>$null)
        if ("$uid".Trim() -eq '0') { return $true }
    } catch {
        Write-Verbose "Initialize-SudoCache: id command unavailable -- assuming non-root and proceeding."
    }
    if (-not (Get-Command sudo -ErrorAction SilentlyContinue)) {
        Write-Warning "Initialize-SudoCache: sudo not on PATH; downstream elevation will fail."
        return $false
    }
    # Cache already warm? Silent fast path -- no notice, no prompt.
    & sudo -n true 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    # A caller already took this run's ONE authorization and said so
    # (install/<host>.sh, install/setup.ps1). The timestamp is cold anyway --
    # it expired, or a brew cask post-install ran `sudo -k` -- and asking again
    # here would break the "you will be prompted ONCE" promise that caller
    # printed, for elevation this function does not itself need. Return $false
    # silently; every privileged write downstream probes for itself with
    # Test-MacSudoAvailable and reports the exact command to run when it cannot
    # elevate, which is an answer the operator can act on rather than a second
    # password box with no context.
    if ($env:YURUNA_SUDO_PRIMED -eq '1') {
        return $false
    }
    # Unattended: nobody is at the console to type a password. The test runner
    # spawns its inner with the call operator, so the inner inherits the launch
    # terminal -- `sudo -v` here would print its prompt to that terminal and
    # block the whole host until the watchdog killed it, with the status page
    # still showing the previous cycle's green. Decline exactly as the
    # wrapper-primed path does: return $false silently and let the caller
    # either skip the elevated work or fail it with an actionable message.
    # Elevation for an unattended host is a LAUNCH-time concern (or an
    # /etc/sudoers.d drop-in), never a mid-cycle one.
    if ($env:YURUNA_NONINTERACTIVE -eq '1') {
        Write-Verbose 'Initialize-SudoCache: YURUNA_NONINTERACTIVE=1 -- declining to prompt for sudo.'
        return $false
    }
    # Cache cold AND no wrapper context: print the friendly notice, then prompt.
    #
    # Write-Host, not Write-Output: every caller wraps this function as
    # `[void](Initialize-SudoCache ...)`, and that cast discards the whole
    # success stream -- a Write-Output notice would be swallowed, leaving the
    # operator with a bare "[sudo] password for ..." and no explanation. It also
    # keeps the [OutputType([bool])] contract honest: box lines on the success
    # stream make the return an ARRAY, and a non-empty array is always truthy,
    # so `if (-not (Initialize-SudoCache ...))` in test/Test-Config.ps1 would
    # never fire on the cold path.
    Write-Host ""
    Write-Host "  +---------------------------------------------------------------+"
    Write-Host "  | This script needs sudo for:                                   |"
    if ($Reasons.Count -gt 0) {
        foreach ($r in $Reasons) {
            $line = "    * $r"
            if ($line.Length -gt 63) { $line = $line.Substring(0, 60) + '...' }
            Write-Host ("  | {0,-61} |" -f $line)
        }
    } else {
        Write-Host "  |     (host configuration commands)                             |"
    }
    Write-Host "  | You will be prompted for your password ONCE, below.           |"
    Write-Host "  +---------------------------------------------------------------+"
    Write-Host ""
    & sudo -v
    return ($LASTEXITCODE -eq 0)
}

function Invoke-MacPrivilegedSetting {
    <#
    .SYNOPSIS
    Run one privileged host-settings command through `sudo -n`, and report
    whether it took.
    .DESCRIPTION
    -n unconditionally, including in front of an operator. The capability probe
    that admitted this block ran seconds earlier against a timestamp that can
    expire inside the block, and the fallback for an expired one has to be an
    exit code rather than a prompt: sudo reads its password from /dev/tty, so a
    child whose output is captured raises that prompt where nobody can see it
    and waits forever, and an operator who already answered once gets a second
    box with no explanation of what it is for.

    Native output is consumed here rather than left on the success stream: the
    caller returns a count, and stray `pmset` chatter merged into that would
    turn an [int] into an array.
    .PARAMETER Argument
    The command and its arguments, e.g. @('pmset','-a','sleep','0').
    .OUTPUTS
    [bool] $true when sudo ran the command and it exited 0.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string[]]$Argument)
    # Pinned locally: this function reports a failed write through its return
    # value and a warning naming the command. With
    # $PSNativeCommandUseErrorActionPreference true the non-zero exit throws
    # first, so a single key this macOS release no longer carries would abort the
    # whole guard list instead of being recorded as rejected and skipped.
    $PSNativeCommandUseErrorActionPreference = $false
    $out = & sudo -n @Argument 2>&1
    if ($LASTEXITCODE -eq 0) { return $true }
    Write-Warning ("sudo {0} failed (exit {1}): {2}" -f ($Argument -join ' '), $LASTEXITCODE, ("$($out | Out-String)".Trim()))
    return $false
}

function Set-MacHostConditionSet {
    <#
    .SYNOPSIS
    Configures macOS host settings needed for unattended VM testing:
    disables display sleep, screen saver idle, and screen lock password;
    triggers first-run prompts for the Accessibility and Screen Recording
    TCC permissions (both required -- keystroke injection + per-window
    capture). Requires sudo for pmset. Idempotent.
    .OUTPUTS
    [int] the number of conditions this run could not put in place. 0 means
    every knob is where the harness needs it. The caller maps a non-zero count
    onto its own exit contract -- see host/macos.utm/Enable-TestAutomation.ps1.
    .EXAMPLE
    Set-MacHostConditionSet          # apply all settings
    Set-MacHostConditionSet -WhatIf  # show what would change without applying
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param()

    if (-not $IsMacOS) {
        Write-Warning "Set-MacHostConditionSet is only supported on macOS."
        return 0
    }

    # Conditions this run wanted and could not establish. The count is the
    # return value, so a host that came out degraded is a distinguishable
    # outcome for the caller rather than a warning in a captured log nothing
    # reads. Only knobs that are genuinely required go in here; each addition
    # below records why that one qualifies, and the ones deliberately left out
    # say why they are advisory.
    $unmet = [System.Collections.Generic.List[string]]::new()

    # -- 0. Elevation is a CAPABILITY, asked of the machine ---------------
    # Every privileged block below probes `sudo -n true` immediately before it
    # writes, and every write goes out with -n. The two facts an environment
    # variable could carry -- who started this run, whether somebody typed a
    # password minutes ago -- do not answer whether root is reachable NOW: the
    # timestamp may have expired during a long step, a brew cask post-install
    # may have run `sudo -k`, or an /etc/sudoers.d rule may grant the write
    # with no timestamp involved at all.
    #
    # Initialize-SudoCache still runs first so an operator at a terminal is
    # asked once, visibly, with the reasons on screen, instead of meeting a
    # bare password prompt in the middle of a block. It declines silently when
    # nobody is there to ask, and the probes below then route each block to its
    # warn-with-the-exact-command arm.
    [void](Initialize-SudoCache -Reasons @(
        'pmset (display sleep, system sleep, power-nap, hibernation)',
        'defaults write /Library/Preferences (auto-logout delay)',
        'sysadminctl -screenLock off (Sonoma+ unified screen lock)'
    ))

    # -- 1. Display sleep -> Never (requires sudo) -------------------------
    # `pmset -g custom` reports the active profile; the writes below cover
    # every power source this machine HAS, so a single read of the current
    # value is enough to decide whether a write is needed.
    $changed = $false
    $pmCustomLines = @(& pmset -g custom 2>$null)
    # `pmset -g custom` prints a "Battery Power:" block only on a machine that
    # has a battery. On a desktop Mac `pmset -b` fails by design, and counting
    # that failure would report a perfectly healthy host as degraded on every
    # run -- so the power sources this machine actually has decide what is
    # required of it.
    $hasBattery = [bool](@($pmCustomLines | Select-String -Pattern '^\s*Battery Power:').Count)
    $currentSleep = "unknown"
    $pmLine = $pmCustomLines | Select-String '^\s*displaysleep\s+(\d+)' | Select-Object -First 1
    if ($pmLine) { $currentSleep = $pmLine.Matches[0].Groups[1].Value }

    if ($currentSleep -ne "0") {
        # Required: Assert-ScreenLock refuses a host whose displaysleep is not 0,
        # so leaving it is a cycle that cannot start rather than a cosmetic gap.
        if (-not (Test-MacSudoAvailable)) {
            Write-Warning "Display sleep is '$currentSleep' (expected 0) and root is not reachable without a password. Run 'sudo pmset -c displaysleep 0; sudo pmset -b displaysleep 0' to fix."
            $unmet.Add('display sleep')
        } elseif ($PSCmdlet.ShouldProcess("Display sleep (currently $currentSleep min)", "Set to 0 (Never) via sudo pmset")) {
            Write-Information "Setting display sleep to Never$(if ($hasBattery) { ' (AC and battery)' } else { ' (AC)' })..."
            $sleepOk = Invoke-MacPrivilegedSetting -Argument @('pmset', '-c', 'displaysleep', '0')
            if ($hasBattery) {
                $sleepOk = (Invoke-MacPrivilegedSetting -Argument @('pmset', '-b', 'displaysleep', '0')) -and $sleepOk
            }
            if ($sleepOk) { $changed = $true } else { $unmet.Add('display sleep') }
        }
    } else {
        Write-Information "Display sleep is already set to Never."
    }

    # -- 2. Screen saver idle time -> 0 (disabled) -------------------------
    # MISSING idleTime key is NOT the same as 0: macOS falls back to
    # ~1200s built-in default. Skip write only when the key EXISTS and is
    # exactly "0"; any other case (missing, empty, other number) triggers
    # an explicit write.
    $ssIdle = & defaults read com.apple.screensaver idleTime 2>$null
    $ssIdleRead = ($LASTEXITCODE -eq 0)
    if ($ssIdleRead -and "$ssIdle".Trim() -eq "0") {
        Write-Information "Screen saver idle activation is already disabled."
    } else {
        $label = if (-not $ssIdleRead) { 'unset -- macOS default applies' } else { "$($ssIdle.Trim())s" }
        if ($PSCmdlet.ShouldProcess("Screen saver idle time (currently $label)", "Set to 0 (disabled)")) {
            Write-Information "Disabling screen saver idle activation (was $label)..."
            & defaults write com.apple.screensaver idleTime -int 0 | Out-Null
            $changed = $true
        }
    }

    # -- 3. Screen lock (password after screen saver) -> OFF ---------------
    # Same "missing key != safe" as sec 2: some macOS versions default
    # askForPassword to 1. Write 0 unless the key is explicitly "0".
    $askPw = & defaults read com.apple.screensaver askForPassword 2>$null
    $askPwRead = ($LASTEXITCODE -eq 0)
    if ($askPwRead -and "$askPw".Trim() -eq "0") {
        Write-Information "Screen lock password is already disabled."
    } else {
        $label = if (-not $askPwRead) { 'unset -- macOS default applies' } else { "$($askPw.Trim())" }
        if ($PSCmdlet.ShouldProcess("Screen lock password (currently $label)", "Disable (askForPassword -> 0)")) {
            Write-Information "Disabling screen lock password requirement (was $label)..."
            & defaults write com.apple.screensaver askForPassword -int 0 | Out-Null
            $changed = $true
        }
    }

    # -- 2b. Screen saver idle -- per-host variant (Ventura+) --------------
    # Modern macOS stores screensaver prefs in the ByHost domain. Without
    # this, System Settings still shows non-zero idle time after sec 2 and
    # the saver still kicks in. Same missing-key-is-unsafe logic as sec 2.
    $ssIdleHost = & defaults -currentHost read com.apple.screensaver idleTime 2>$null
    $ssIdleHostRead = ($LASTEXITCODE -eq 0)
    if ($ssIdleHostRead -and "$ssIdleHost".Trim() -eq "0") {
        Write-Information "Screen saver idle activation (currentHost) is already disabled."
    } else {
        $label = if (-not $ssIdleHostRead) { 'unset -- macOS default applies' } else { "$($ssIdleHost.Trim())s" }
        if ($PSCmdlet.ShouldProcess("Screen saver idle time [currentHost] (currently $label)", "Set to 0 (disabled)")) {
            Write-Information "Disabling screen saver idle activation, currentHost (was $label)..."
            & defaults -currentHost write com.apple.screensaver idleTime -int 0 | Out-Null
            $changed = $true
        }
    }

    # -- 3b. Screen lock password -- per-host variant ---------------------
    # Same missing-key-is-unsafe logic as sec 3.
    $askPwHost = & defaults -currentHost read com.apple.screensaver askForPassword 2>$null
    $askPwHostRead = ($LASTEXITCODE -eq 0)
    if ($askPwHostRead -and "$askPwHost".Trim() -eq "0") {
        Write-Information "Screen lock password (currentHost) is already disabled."
    } else {
        $label = if (-not $askPwHostRead) { 'unset -- macOS default applies' } else { "$($askPwHost.Trim())" }
        if ($PSCmdlet.ShouldProcess("Screen lock password [currentHost] (currently $label)", "Disable (askForPassword -> 0)")) {
            Write-Information "Disabling screen lock password requirement, currentHost (was $label)..."
            & defaults -currentHost write com.apple.screensaver askForPassword -int 0 | Out-Null
            $changed = $true
        }
    }

    # -- 3c. "Require password after sleep/screen saver begins" delay -----
    # Sonoma+ lock-screen pane. A very large delay prevents lock from
    # engaging even if something re-enables askForPassword.
    # ShouldProcess-gated like every other write in this function: these two
    # were the only ones that applied unconditionally, so a -WhatIf preview
    # silently changed the host it was only supposed to describe.
    foreach ($domainArgs in @(
        @{ Args = @('com.apple.screensaver', 'askForPasswordDelay')               ; Label = 'user' }
        @{ Args = @('-currentHost', 'com.apple.screensaver', 'askForPasswordDelay'); Label = 'currentHost' }
    )) {
        if ($PSCmdlet.ShouldProcess("Screen lock password delay [$($domainArgs.Label)]", 'Set to 2147483647 (effectively never)')) {
            # Advisory, not required: no gate reads this key. sysadminctl's
            # unified lock overrides the legacy askForPassword* pair on
            # Ventura+ (see 3j), which is why Assert-ScreenLock checks that
            # instead. A failure here is still worth the warning
            # Confirm-MacDefaultWrite raises -- it is the only signal that a
            # managed domain is rejecting writes -- but it must not by itself
            # make a host report degraded.
            if (-not (Confirm-MacDefaultWrite -DefaultsArgs $domainArgs.Args -WriteType '-int' -WriteValue '2147483647' -ExpectRead '2147483647')) {
                Write-Verbose "Screen lock password delay [$($domainArgs.Label)] did not take; the unified screen lock (3j) is what the gate checks."
            }
        }
    }

    # -- 3d. System sleep -> Never (requires sudo) -------------------------
    # Display-sleep alone isn't enough: system sleep -> display locks on
    # wake regardless of screensaver settings.
    $currentSysSleep = "unknown"
    $sysLine = & pmset -g custom 2>$null | Select-String '^\s*[^d]\s*sleep\s+(\d+)' | Select-Object -First 1
    if ($sysLine) { $currentSysSleep = $sysLine.Matches[0].Groups[1].Value }

    if ($currentSysSleep -ne "0") {
        # Required for the same reason as display sleep: Assert-ScreenLock
        # refuses a host whose sleep / disksleep are non-zero.
        if (-not (Test-MacSudoAvailable)) {
            Write-Warning "System sleep is '$currentSysSleep' (expected 0) and root is not reachable without a password. Run 'sudo pmset -a sleep 0 disksleep 0' to fix."
            $unmet.Add('system sleep')
        } elseif ($PSCmdlet.ShouldProcess("System sleep (currently $currentSysSleep min)", "Set to 0 (Never) via sudo pmset")) {
            Write-Information "Setting system sleep to Never (all power sources)..."
            # -a covers AC + battery + UPS. Setting disksleep only on
            # -c leaves laptops on battery with disksleep=10; disk-sleep
            # wake re-checks lock state and on Ventura+ can trigger the
            # unified screen lock even with askForPassword=0.
            $sysOk  = Invoke-MacPrivilegedSetting -Argument @('pmset', '-a', 'sleep', '0')
            $diskOk = Invoke-MacPrivilegedSetting -Argument @('pmset', '-a', 'disksleep', '0')
            if ($sysOk -and $diskOk) { $changed = $true } else { $unmet.Add('system sleep') }
        }
    } else {
        Write-Information "System sleep is already set to Never."
    }

    # Extended pmset guards: Power Nap, standby, autopoweroff, hibernate
    # transitions hide UTM from CG enumeration on long runs. The guard list is
    # shared with Assert-ScreenLock (Get-MacPmsetGuardList) so the gate re-checks
    # exactly what is applied here. Per-key rationale, OptionalKey policy, and
    # precheck-before-sudo logic at https://yuruna.link/host/macos
    $pmsetGuards  = Get-MacPmsetGuardList
    $pmsetPending = @(Get-MacPmsetGuardPending -PmsetCustom (& pmset -g custom 2>$null) -Guard $pmsetGuards)
    if ($pmsetPending.Count -eq 0) {
        Write-Information "Extended pmset guards verified (no mismatched keys in 'pmset -g custom')."
    } elseif (-not (Test-MacSudoAvailable)) {
        # Name the exact commands: the operator has to run them by hand here,
        # and a generic "there is a mismatch" leaves them reading pmset output
        # against a guard list they can't see.
        Write-Warning "Extended pmset guards are not applied and root is not reachable without a password. Run these yourself before starting tests:"
        foreach ($g in $pmsetPending) { Write-Warning "  sudo pmset -a $($g.Key) $($g.Want)" }
        # Deliberately advisory. A key absent from `pmset -g custom` is pending
        # only because AlwaysApply says absence proves nothing, and a lidless
        # desktop Mac never surfaces disablesleep at all -- Assert-ScreenLock
        # skips exactly those keys for the same reason. Counting them would
        # report a healthy desktop host as degraded on every single run.
        Write-Verbose "Extended pmset guards are advisory here; Assert-ScreenLock re-checks the keys this macOS actually surfaces."
    } elseif ($PSCmdlet.ShouldProcess("Extended pmset guards", "Apply via sudo pmset -a")) {
        # ONLY the pending keys. `pmset` has no delete, so a key this host never
        # carried can never be taken back off it: the pre-automation capture
        # records it as absent, and the restore has nothing to write except a
        # value nobody chose. Get-MacPmsetGuardPending already draws exactly the
        # right line -- a key present with the wrong value, plus the AlwaysApply
        # keys whose absence carries no information and which the guard list
        # gives an AbsentEquivalent so the restore can undo them. Everything it
        # leaves out is a name this macOS release does not surface, and writing
        # one buys nothing but a host setting that outlives the automation.
        # Key names come from the pending set so this message cannot drift away
        # from what is actually written.
        Write-Information "Applying extended pmset guards ($(($pmsetPending | ForEach-Object { $_.Key }) -join ', '))..."
        # Warnings are suppressed per key and the rejected set is reported once,
        # because the two causes need different words and only a probe tells
        # them apart: a name this release dropped says nothing about the host,
        # while an elevation that expired mid-loop is the operator's to fix.
        $rejected = @()
        foreach ($g in $pmsetPending) {
            if (-not (Invoke-MacPrivilegedSetting -Argument @('pmset', '-a', "$($g.Key)", "$($g.Want)") -WarningAction SilentlyContinue)) {
                $rejected += $g.Key
            }
        }
        if ($rejected.Count -gt 0) {
            if (Test-MacSudoAvailable) {
                Write-Verbose "pmset rejected: $($rejected -join ', ') -- this macOS may not carry those keys."
            } else {
                Write-Warning "Root stopped being reachable without a password part-way through the extended pmset guards. Run these yourself before starting tests:"
                foreach ($k in $rejected) {
                    $want = @($pmsetPending | Where-Object { $_.Key -eq $k })[0].Want
                    Write-Warning "  sudo pmset -a $k $want"
                }
            }
        }
        $changed = $true
        $stillPending = @(Get-MacPmsetGuardPending -PmsetCustom (& pmset -g custom 2>$null) -Guard $pmsetGuards)
        if ($stillPending.Count -eq 0) {
            Write-Information "Extended pmset guards verified after applying."
        } else {
            # Not a warning: a Mac with no lid never surfaces disablesleep no
            # matter how often it is written, and Assert-ScreenLock skips
            # exactly those keys. Saying so once, where the write happened, is
            # the only place the state is ever observable.
            Write-Information "  'pmset -g custom' still does not report: $(($stillPending | ForEach-Object { $_.Key }) -join ', '). macOS lists a guard only on hardware that has it."
        }
    }

    # -- 3g. Hot corners -- neutralize screen-saver / sleep / lock triggers --
    # Dock stores hot-corner actions under wvous-{tl,tr,bl,br}-corner.
    # A drifting mouse during an unattended test can land in a corner
    # and trigger screensaver / display-sleep / lock -- making the UTM
    # window vanish from the CG window list. The dangerous-code map is
    # shared with Assert-ScreenLock (Get-MacDangerousHotCornerMap) so the
    # gate flags exactly the bindings this path neutralizes; safe codes
    # (0=none, Mission Control, Launchpad, ...) are absent and left alone.
    $dangerousCorners = Get-MacDangerousHotCornerMap
    $dockReloadNeeded = $false
    foreach ($corner in @('tl','tr','bl','br')) {
        $key = "wvous-$corner-corner"
        $val = & defaults read com.apple.dock $key 2>$null
        if ($LASTEXITCODE -eq 0) {
            $valTrim = "$val".Trim()
            if ($dangerousCorners.ContainsKey($valTrim)) {
                $action = $dangerousCorners[$valTrim]
                if ($PSCmdlet.ShouldProcess("Hot corner $corner (currently '$action' = $valTrim)", "Set to 0 (none)")) {
                    Write-Information "Neutralizing hot corner '$corner' ($action -> none)..."
                    $cornerCleared = Confirm-MacDefaultWrite -DefaultsArgs @('com.apple.dock', $key) -WriteType '-int' -WriteValue '0' -ExpectRead '0'
                    # Clear the modifier too -- otherwise the corner is
                    # merely hidden behind a modifier a wandering cursor
                    # might hit alongside a stuck Shift.
                    [void](Confirm-MacDefaultWrite -DefaultsArgs @('com.apple.dock', "wvous-$corner-modifier") -WriteType '-int' -WriteValue '0' -ExpectRead '0')
                    if ($cornerCleared) {
                        $dockReloadNeeded = $true
                        $changed = $true
                    }
                }
            }
        }
    }
    if ($dockReloadNeeded) {
        # Dock re-reads these only at launch; kick it so the change
        # takes effect immediately (Dock auto-relaunches).
        & killall Dock 2>$null | Out-Null
    } else {
        Write-Information "Hot corners: no dangerous bindings (screen-saver / sleep / lock) detected."
    }

    # -- 3h. UTM.app lifetime: App Nap + last-window-closed ---------------
    # macOS App Nap throttles background apps that haven't received
    # input. For UTM this can freeze the UI thread, stop updating the
    # window server, and drop the window from CGWindowListCopyWindowInfo
    # -- exactly the "UTM window for '<vm>' not found" symptom even when
    # the VM is fine. Opt UTM out unconditionally.
    $utmBundleId = 'com.utmapp.UTM'
    $napState = & defaults read $utmBundleId NSAppSleepDisabled 2>$null
    $napAlreadyOff = ($LASTEXITCODE -eq 0 -and "$napState".Trim() -eq '1')
    if (-not $napAlreadyOff) {
        if ($PSCmdlet.ShouldProcess("App Nap for $utmBundleId", "Disable (NSAppSleepDisabled = YES)")) {
            Write-Information "Disabling App Nap for UTM.app ($utmBundleId)..."
            if (Confirm-MacDefaultWrite -DefaultsArgs @($utmBundleId, 'NSAppSleepDisabled') -WriteType '-bool' -WriteValue 'YES' -ExpectRead '1') {
                $changed = $true
            }
        }
    } else {
        Write-Information "App Nap for UTM.app is already disabled."
    }

    # UTM's default is to terminate once its last window closes, and its
    # termination path SAVES THE STATE of every VM still running rather
    # than leaving them alone: they come back `suspended`, not `started`.
    # The service VMs (caching proxy, stash, pool-control) are long-lived
    # infrastructure that guests consume for the whole cycle, so closing a
    # VM window -- or the library window -- silently takes the cycle's
    # dependencies offline and every guest that needs the proxy or the
    # stash then fails. Keeping the app resident removes the window-close
    # route into that state. UTM reads this at launch, so a UTM already
    # running keeps its old behaviour until it is next started.
    $keepRunningState = & defaults read $utmBundleId KeepRunningAfterLastWindowClosed 2>$null
    $keepRunningAlready = ($LASTEXITCODE -eq 0 -and "$keepRunningState".Trim() -eq '1')
    if (-not $keepRunningAlready) {
        if ($PSCmdlet.ShouldProcess("UTM.app ($utmBundleId)", "Keep running after last window closed (KeepRunningAfterLastWindowClosed = YES)")) {
            Write-Information "Keeping UTM.app alive after its last window closes ($utmBundleId)..."
            if (Confirm-MacDefaultWrite -DefaultsArgs @($utmBundleId, 'KeepRunningAfterLastWindowClosed') -WriteType '-bool' -WriteValue 'YES' -ExpectRead '1') {
                $changed = $true
            }
        }
    } else {
        Write-Information "UTM.app already stays running after its last window closes."
    }

    # -- 3i. Clear any stuck ScreenSaverEngine ----------------------------
    # If a prior aborted run left the saver engaged, the engine process
    # may still be running when this script applies settings. Killing
    # is idempotent and harmless when nothing runs; swallow exit codes
    # so "no such process" isn't reported as failure.
    & killall ScreenSaverEngine 2>$null | Out-Null

    # -- 3j. sysadminctl unified screen lock (Ventura+) -------------------
    # `sysadminctl -screenLock` is the modern (macOS 13+) unified control
    # that System Settings > Lock Screen > "Require password after screen
    # saver begins or display is turned off" writes to.
    # CRITICAL: overrides legacy askForPassword / askForPasswordDelay.
    # A machine with idleTime=0, askForPassword=0, and
    # askForPasswordDelay=MAX_INT can still lock after minutes because
    # sysadminctl reports e.g. "screenLock delay is 300 seconds".
    #
    # "off" sets delay to -1 (disabled). sysadminctl requires the user's
    # password (not sudo) because it touches the secure keyring entry
    # backing lock-screen policy. `-password -` reads from stdin -- a
    # second prompt appears after the sudo prompt.
    # Get-MacScreenLockDisabled strips the NSLog prefix and applies the
    # shared "off" test (also used by Assert-ScreenLock's gate) so the
    # apply and assert paths agree on what counts as disabled.
    $slParsed = Get-MacScreenLockDisabled -Raw (& sysadminctl -screenLock status 2>&1 | Select-Object -First 1)
    $slStatus = $slParsed.Status
    if (-not $slParsed.Disabled) {
        # This block needs two different things and only one of them is root.
        # `-password -` reads the ACCOUNT password from stdin, so a run that
        # cannot put a question in front of a person cannot do this at all:
        # under a captured child stdin is closed, the read returns EOF, and the
        # attempt would be reported as a FAILED disable rather than one that was
        # never possible. Name the one-time command instead.
        if (-not ((Test-MacSudoAvailable) -and (Test-YurunaCanPrompt))) {
            Write-Warning "==================================================================="
            Write-Warning " sysadminctl unified screen lock is NOT yet disabled (status:"
            Write-Warning "   $slStatus)"
            Write-Warning ""
            Write-Warning " Run this ONE-TIME command yourself before starting tests:"
            Write-Warning ""
            Write-Warning "   sudo sysadminctl -screenLock off -password -"
            Write-Warning ""
            Write-Warning " sysadminctl asks for your account password from stdin in addition"
            Write-Warning " to sudo's prompt. State is persistent across reboots, so this"
            Write-Warning " warning will not reappear once it succeeds."
            Write-Warning "==================================================================="
            # Required: Assert-ScreenLock refuses a host whose unified lock is
            # active, and that lock overrides every legacy key above it.
            $unmet.Add('sysadminctl unified screen lock')
        } elseif ($PSCmdlet.ShouldProcess("sysadminctl $slStatus", "Disable (sysadminctl -screenLock off)")) {
            Write-Information "Disabling sysadminctl unified screen lock (you may be prompted for your account password)..."
            # 2>&1 so "password:" prompt and diagnostics both land on
            # the tty where the user expects them. -n on sudo, because only
            # sysadminctl's own account-password prompt belongs on that tty.
            # Out-Host rather than an uncaptured statement: this function
            # returns a count, and a merged stream left on the success stream
            # would arrive at the caller as part of it.
            & sudo -n sysadminctl -screenLock off -password - 2>&1 | Out-Host
            # Re-check: if we couldn't disable (wrong password, policy
            # override, MDM), surface the state so the user knows legacy
            # keys won't save them.
            $slAfterParsed = Get-MacScreenLockDisabled -Raw (& sysadminctl -screenLock status 2>&1 | Select-Object -First 1)
            if ($slAfterParsed.Disabled) {
                Write-Information "sysadminctl screen lock is now disabled."
                $changed = $true
            } else {
                Write-Warning "sysadminctl screen lock is STILL active after attempt: $($slAfterParsed.Status)"
                Write-Warning "  If this Mac is MDM-managed, a Configuration Profile may be"
                Write-Warning "  enforcing screen lock; check: profiles list ; profiles show -type configuration"
                $unmet.Add('sysadminctl unified screen lock')
            }
        }
    } else {
        Write-Information "sysadminctl unified screen lock is already disabled."
    }

    # -- 3k. Auto-logout after inactivity (Security -> Advanced) -----------
    # `com.apple.autologout.AutoLogOutDelay` (system-level) is the
    # "Log out after N minutes of inactivity" toggle in Lock Screen /
    # Security. macOS kicks the user back to loginwindow after the
    # delay -- indistinguishable from a lock ("demands password"), but
    # no screen-saver / pmset key we control would prevent it. System
    # level (/Library/Preferences/.GlobalPreferences); the WRITE
    # requires sudo, but the plist is mode 644 so the READ does not --
    # reading it through sudo would spend an elevation on a value anyone can
    # see, and on a host that cannot elevate it would hide the state entirely.
    $autoLogoutDelay = & defaults read /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay 2>$null
    $autoLogoutOff = ($LASTEXITCODE -ne 0 -or "$autoLogoutDelay".Trim() -eq "0")
    if (-not $autoLogoutOff) {
        # Required: Assert-ScreenLock refuses a host with an active auto-logout.
        # It kicks the session to loginwindow mid-cycle, which looks exactly
        # like a lock and no screen-saver or pmset key prevents it.
        if (-not (Test-MacSudoAvailable)) {
            Write-Warning "AutoLogOutDelay is '$($autoLogoutDelay.Trim())' (expected 0) and root is not reachable without a password. Run 'sudo defaults write /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay -int 0' to fix."
            $unmet.Add('auto-logout delay')
        } elseif ($PSCmdlet.ShouldProcess("Auto-logout delay (currently $($autoLogoutDelay.Trim())s)", "Set to 0 (disabled)")) {
            Write-Information "Disabling auto-logout after inactivity..."
            if (Invoke-MacPrivilegedSetting -Argument @('defaults', 'write', '/Library/Preferences/.GlobalPreferences', 'com.apple.autologout.AutoLogOutDelay', '-int', '0')) {
                $changed = $true
            } else {
                $unmet.Add('auto-logout delay')
            }
        }
    } else {
        Write-Information "Auto-logout after inactivity is already disabled."
    }

    # -- 3l. Spaces "switch to a Space with open windows" toggle ----------
    # When the harness calls `tell application "UTM" to activate` (the
    # AVF-guest keystroke fallback in Send-KeyUTM / Send-TextUTM), macOS
    # by default yanks the operator across Spaces to UTM's window -- which
    # is hostile when the operator has switched to VS Code on a different
    # Space to investigate something while a long test runs.
    # AppleSpacesSwitchOnActivation=false keeps the activation on the
    # current Space; UTM still becomes frontmost (so keystrokes route to
    # it), but the operator's view stays put. Dock must be restarted for
    # the change to take effect.
    $spacesAutoSwitch = & defaults read NSGlobalDomain AppleSpacesSwitchOnActivation 2>$null
    $spacesAutoSwitchOff = ($LASTEXITCODE -eq 0 -and "$spacesAutoSwitch".Trim() -eq "0")
    if (-not $spacesAutoSwitchOff) {
        if ($PSCmdlet.ShouldProcess("AppleSpacesSwitchOnActivation (currently $($spacesAutoSwitch))", "Set to false (don't switch Spaces on app activation)")) {
            Write-Information "Disabling 'switch to a Space with open windows' on app activation..."
            if (Confirm-MacDefaultWrite -DefaultsArgs @('NSGlobalDomain', 'AppleSpacesSwitchOnActivation') -WriteType '-bool' -WriteValue 'false' -ExpectRead '0') {
                & killall Dock 2>$null | Out-Null
                $changed = $true
            }
        }
    } else {
        Write-Information "Spaces auto-switch on app activation is already disabled."
    }

    # Pinning UTM.app to "All Desktops" (right-click Dock icon -> Options ->
    # Assign To -> All Desktops) is the other half of making cross-Space
    # debugging seamless -- but it's stored deep inside com.apple.spaces
    # app-bindings plist and is fragile to script. Left as a one-time
    # manual step; flagged here so the operator knows it exists.
    Write-Information "Tip (manual): right-click UTM in the Dock -> Options -> Assign To -> All Desktops."
    Write-Information "      Combined with the AppleSpacesSwitchOnActivation toggle above, this lets"
    Write-Information "      Invoke-TestRunner activate UTM without yanking the operator off VS Code."

    # -- 3m. Managed Configuration Profile detection (MDM override) -------
    # If MDM-managed, a Configuration Profile can enforce screen lock /
    # password delay / auto-logout at a level that OVERRIDES everything
    # above -- `defaults write` is silently ignored or reverted on next
    # mcxrefresh. We can't bypass a profile; warn the user so they
    # don't chase a ghost.
    try {
        $profOutput = & profiles list 2>&1
        $hasProfiles = ($LASTEXITCODE -eq 0 -and "$profOutput" -notmatch 'no configuration profiles')
        if ($hasProfiles) {
            Write-Warning "==================================================================="
            Write-Warning " Configuration Profile(s) detected on this Mac. If any profile"
            Write-Warning " enforces screen-lock / password / auto-logout policy, the settings"
            Write-Warning " applied by this script will be overridden. Inspect with:"
            Write-Warning "   profiles list"
            Write-Warning "   profiles show -type configuration"
            Write-Warning " Policy keys to look for: screenSaverPasswordDelay, askForPassword,"
            Write-Warning " loginWindowIdleTime, AutoLogOutDelay, forceLockOnSleep."
            Write-Warning "==================================================================="
        }
    } catch {
        Write-Debug "profiles list failed: $_"
    }

    # -- 4. Accessibility -- trigger the system prompt if not granted -------
    try {
        $jxa = "ObjC.import('ApplicationServices'); $.AXIsProcessTrusted();"
        $axResult = & osascript -l JavaScript -e $jxa 2>&1
        if ("$axResult" -eq "true") {
            Write-Information "Accessibility permission is already granted."
        } else {
            Write-Information "Requesting Accessibility permission (a system dialog should appear)..."
            # AXIsProcessTrustedWithOptions + kAXTrustedCheckOptionPrompt=true
            # triggers the macOS consent dialog.
            $jxaPrompt = @"
ObjC.import('CoreFoundation');
ObjC.import('ApplicationServices');
var opts = $.CFDictionaryCreateMutable(null, 1,
    $.kCFTypeDictionaryKeyCallBacks, $.kCFTypeDictionaryValueCallBacks);
var key = $.CFStringCreateWithCString(null, 'AXTrustedCheckOptionPrompt', 0);
$.CFDictionarySetValue(opts, key, $.kCFBooleanTrue);
$.AXIsProcessTrustedWithOptions(opts);
"@
            & osascript -l JavaScript -e $jxaPrompt 2>&1 | Out-Null
            Write-Information "  -> Grant access in the dialog, then re-run the test."
        }
    } catch {
        Write-Debug "Accessibility prompt failed: $_"
        Write-Warning "Could not check Accessibility status. Grant it manually in System Settings."
    }

    # -- 5. Screen Recording -- preflight + first-run prompt ----------------
    # Separate TCC bucket from Accessibility. Needed so
    # CGWindowListCopyWindowInfo returns window titles (the harness matches
    # UTM's per-VM window by title) and so `screencapture -l <windowId>`
    # works. Without it, tapOn loops on "UTM window for
    # <vm> not found". CGRequestScreenCaptureAccess prompts only on the
    # FIRST call per process; subsequent denied states need the user to
    # toggle System Settings manually and relaunch the terminal.
    #
    # ObjC.bindFunction is REQUIRED on some macOS releases -- without it,
    # $.CGPreflightScreenCaptureAccess() returns `undefined` (read as
    # "not granted") even when the grant is in place, misreporting state.
    try {
        $jxa = @"
ObjC.import('CoreGraphics');
try { ObjC.bindFunction('CGPreflightScreenCaptureAccess', ['bool', []]); } catch (e) {}
try { ObjC.bindFunction('CGRequestScreenCaptureAccess',  ['bool', []]); } catch (e) {}
var granted = $.CGPreflightScreenCaptureAccess();
if (!granted) { $.CGRequestScreenCaptureAccess(); }
(granted === true || granted === 1) ? 'true' : 'false'
"@
        $srResult = (& osascript -l JavaScript -e $jxa 2>&1 | Out-String).Trim()
        if ($srResult -eq 'true') {
            Write-Information "Screen Recording permission is already granted."
        } else {
            Write-Information "Requesting Screen Recording permission (a system dialog may appear)..."
            Write-Information "  -> If no dialog appears, macOS already remembered a previous denial."
            Write-Information "    Open System Settings > Privacy & Security > Screen Recording,"
            Write-Information "    enable your terminal app (Terminal.app, iTerm2, Ghostty, etc.),"
            Write-Information "    then FULLY QUIT and relaunch it before re-running the test."
        }
    } catch {
        Write-Debug "Screen Recording prompt failed: $_"
        Write-Warning "Could not check Screen Recording status. Grant it manually in System Settings."
    }

    # -- 6. Host clock -> network time on + stepped -------------------------
    # Guests inherit this clock at power-on; see Sync-MacHostClock for what
    # a drifting one does to them. Its two calls already use sudo -n, so a cold
    # timestamp reports rather than prompts.
    $clock = Sync-MacHostClock
    if ($clock.Succeeded) {
        Write-Information "Host clock: $($clock.Message)"
        $changed = $true
    } else {
        # Advisory: Assert-MacHostConditionSet reports clock drift and never
        # refuses on it, because the repair needs a credential the asserting
        # process cannot ask for. Degrading the whole step on it would make
        # that decision twice, in opposite directions.
        Write-Warning "Host clock not disciplined: $($clock.Message)"
    }

    if ($changed) {
        Write-Information ""
        Write-Information "Settings updated. Re-run Assert-MacHostConditionSet to verify:"
        Write-Information "  Assert-MacHostConditionSet -HostType 'host.macos.utm'"
    }

    # A preview changed nothing, so it has nothing to report as unmet: the
    # ShouldProcess-gated blocks above never ran and the probe-only branches
    # describe a host this run did not attempt to fix.
    if ($WhatIfPreference) { return 0 }

    if ($unmet.Count -gt 0) {
        Write-Warning "Host settings applied with $($unmet.Count) condition(s) still unmet: $($unmet -join ', ')."
    }
    return $unmet.Count
}

function Assert-Accessibility {
    <#
    .SYNOPSIS
    macOS: verify the terminal has Accessibility permission (needed
    for AXUIElementPostKeyboardEvent). Returns $true if granted (or
    not on macOS). Prints setup instructions and returns $false on
    missing permission.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    # AXIsProcessTrusted() true when the process has Accessibility access.
    try {
        $jxa = "ObjC.import('ApplicationServices'); $.AXIsProcessTrusted();"
        $result = & osascript -l JavaScript -e $jxa 2>&1
        if ("$result" -eq "true") { return $true }
    } catch {
        Write-Debug "Accessibility check failed: $_"
    }

    Write-Warning "==================================================================="
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
    Write-Warning "==================================================================="
    return $false
}

function Assert-ScreenRecording {
    <#
    .SYNOPSIS
    macOS: verify the terminal has Screen Recording permission (needed
    for CGWindowListCopyWindowInfo to include window titles -- the
    harness matches UTM's per-VM window by title -- and for
    `screencapture -l <windowId>`). Returns $true if granted (or not on
    macOS). Prints setup instructions and returns $false on missing
    permission.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    # Primary check: CGPreflightScreenCaptureAccess is the canonical
    # TCC query -- it reads the Screen Recording grant directly and is
    # the same call the OS uses internally. JavaScriptCore's $. bridge
    # needs a registered signature for C functions not shipped in its
    # built-in header set; AX* functions ship with signatures but
    # CGPreflight/CGRequest do not in every release. ObjC.bindFunction
    # registers the signature explicitly so the return type is correct.
    $jxaPre = @"
ObjC.import('CoreGraphics');
try { ObjC.bindFunction('CGPreflightScreenCaptureAccess', ['bool', []]); } catch (e) {}
var r = $.CGPreflightScreenCaptureAccess();
(r === true || r === 1) ? 'true' : 'false'
"@
    try {
        $result = (& osascript -l JavaScript -e $jxaPre 2>&1 | Out-String).Trim()
        Write-Debug "Assert-ScreenRecording: CGPreflight returned '$result'"
        if ($result -eq 'true') { return $true }
    } catch {
        Write-Debug "CGPreflight check failed: $_"
    }

    # Fallback: enumerate on-screen windows and require at least TWO
    # foreign windows with non-empty kCGWindowName. Used only when
    # CGPreflight is unavailable/broken (old macOS, custom JXA build).
    # Requiring two owners avoids false positives from a single
    # permissive-NSWindowSharingType window that would otherwise claim
    # the grant is in place when it isn't.
    $jxa = @"
ObjC.import('CoreGraphics');
var list = $.CGWindowListCopyWindowInfo((1 << 0) | (1 << 4), 0);
if (!list) { 'false' } else {
    var n = $.CFArrayGetCount(list);
    var nameKey  = $.CFStringCreateWithCString(null, 'kCGWindowName', 0);
    var ownerKey = $.CFStringCreateWithCString(null, 'kCGWindowOwnerName', 0);
    var owners = {};
    for (var i = 0; i < n; i++) {
        var d = $.CFArrayGetValueAtIndex(list, i);
        var nm = $.CFDictionaryGetValue(d, nameKey);
        if (!nm || $.CFStringGetLength(nm) === 0) continue;
        var ow = $.CFDictionaryGetValue(d, ownerKey);
        var owStr = ow ? ObjC.unwrap(ow) : '';
        if (owStr) owners[owStr] = true;
    }
    (Object.keys(owners).length >= 2) ? 'true' : 'false'
}
"@
    try {
        $result = (& osascript -l JavaScript -e $jxa 2>&1 | Out-String).Trim()
        Write-Debug "Assert-ScreenRecording: enumeration fallback returned '$result'"
        if ($result -eq 'true') { return $true }
    } catch {
        Write-Debug "Window-title enumeration failed: $_"
    }

    Write-Warning "==================================================================="
    Write-Warning " Screen Recording permission does NOT appear granted for this"
    Write-Warning " terminal. The harness needs it to enumerate UTM's windows --"
    Write-Warning " CGWindowList only returns titles to processes with this"
    Write-Warning " permission -- and to capture a specific VM window via"
    Write-Warning " screencapture -l <windowId>. Without it, tapOn"
    Write-Warning " loops on 'UTM window for <vm> not found'."
    Write-Warning ""
    Write-Warning " To fix:"
    Write-Warning "   1. Open System Settings > Privacy & Security > Screen Recording"
    Write-Warning "   2. Click + and add your terminal app"
    Write-Warning "      (Terminal.app, iTerm2, Ghostty, or whichever you use)"
    Write-Warning "   3. Ensure the toggle is ON"
    Write-Warning "   4. FULLY QUIT the terminal (Cmd-Q or killall) and relaunch it"
    Write-Warning "      -- macOS will NOT honor the grant in the running process."
    Write-Warning "   5. Re-run the test harness from the new terminal."
    Write-Warning ""
    Write-Warning " If the toggle IS on and you already relaunched the terminal,"
    Write-Warning " run this diagnostic and report the output:"
    Write-Warning ""
    Write-Warning "   osascript -l JavaScript -e 'ObjC.import(\"CoreGraphics\");"
    Write-Warning "     ObjC.bindFunction(\"CGPreflightScreenCaptureAccess\","
    Write-Warning "     [\"bool\",[]]); `$.CGPreflightScreenCaptureAccess();'"
    Write-Warning ""
    Write-Warning " If that prints 'true', override this check with"
    Write-Warning "   `$Env:YURUNA_SKIP_SCREEN_RECORDING_CHECK = '1'"
    Write-Warning " and re-run -- then please file an issue with the diagnostic"
    Write-Warning " output so the probe can be tuned for your macOS version."
    Write-Warning "==================================================================="

    if ($env:YURUNA_SKIP_SCREEN_RECORDING_CHECK -eq '1') {
        Write-Warning "YURUNA_SKIP_SCREEN_RECORDING_CHECK=1 -- proceeding anyway."
        return $true
    }
    return $false
}

function Sync-MacHostClock {
    <#
    .SYNOPSIS
    Put the host clock back under NTP discipline: network time on, then a
    forced sync against the configured server. Returns @{ Succeeded; Message }.

    .DESCRIPTION
    UTM/Virtualization.framework seeds each guest's clock from this host
    at power-on, so a drifting host hands the same error to every VM it
    starts and the guest's own NTP client then steps the clock mid-boot
    -- which is what leaves a Kubernetes guest with pods Running but
    never Ready and its NodePorts refusing.

    `systemsetup -setusingnetworktime on` is the durable half (it survives
    reboots); `sntp -sS` is the immediate half, because turning the daemon
    on does not itself step a clock that is already hours out.

    Both need root. Reports rather than throws: a caller has to be free to
    carry on with a warning when sudo is not available, and this must never
    sit waiting on a password prompt -- hence sudo -n throughout. An
    interactive caller that wants the sync to succeed primes the credential
    cache first (Initialize-SudoCache), which asks once and visibly.

    .OUTPUTS
    [hashtable] Succeeded (bool), Message (string).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([string]$TimeServer = 'time.apple.com')

    if (-not $IsMacOS) {
        return @{ Succeeded = $false; Message = 'Sync-MacHostClock is only supported on macOS.' }
    }
    $manual = "Fix by hand: sudo systemsetup -setusingnetworktime on; sudo sntp -sS $TimeServer"
    if (-not $PSCmdlet.ShouldProcess('Host clock', "Enable network time and resynchronize against $TimeServer")) {
        return @{ Succeeded = $false; Message = 'Skipped (WhatIf).' }
    }

    $steps = @()
    # -n: never prompt. An unattended runner blocked on a hidden sudo
    # password prompt is a hang, not a failed clock sync.
    $netTimeOut = & sudo -n systemsetup -setusingnetworktime on 2>&1
    if ($LASTEXITCODE -eq 0) {
        $steps += 'network time on'
    } else {
        return @{ Succeeded = $false; Message = "systemsetup -setusingnetworktime failed: $(($netTimeOut | Out-String).Trim()). $manual" }
    }
    # -s steps the clock, -S sets it even for a large offset; timesyncd-
    # style slewing would take hours to close a multi-minute gap.
    $sntpOut = & sudo -n sntp -sS $TimeServer 2>&1
    if ($LASTEXITCODE -ne 0) {
        return @{ Succeeded = $false; Message = "sntp -sS $TimeServer failed: $(($sntpOut | Out-String).Trim()). $manual" }
    }
    $steps += "stepped against $TimeServer"
    return @{ Succeeded = $true; Message = "Host clock: $($steps -join ', ')." }
}

function Assert-MacHostConditionSet {
    <#
    .SYNOPSIS
    Single gate for macOS prerequisites: Accessibility + Screen Recording
    permissions, screen lock / display sleep settings. Returns $true on
    non-macOS or when all conditions pass; $false with diagnostics on
    failure. Also reports the host clock -- warn-only, never a reason to
    refuse. Invoke once at startup and again before each test cycle.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.macos.utm") { return $true }

    if (-not (Assert-Accessibility    -HostType $HostType)) { return $false }
    if (-not (Assert-ScreenRecording  -HostType $HostType)) { return $false }
    if (-not (Assert-ScreenLock       -HostType $HostType)) { return $false }
    # Guests inherit this clock at power-on; see Write-HostClockDriftWarning.
    # Warn-only and once per cycle: the repair needs a sudo credential this
    # process cannot ask for, so a drifted host runs and says so rather than
    # refusing every cycle until an operator notices.
    Write-HostClockDriftWarning -HostType $HostType

    return $true
}

function Test-MacHostMinimum {
    <#
    .SYNOPSIS
        macOS UTM quick-check for [Test-HostRequirement] (UTM.app
        installed + utmctl on PATH). Emits actionable warnings on
        failure and returns $false; emits nothing and returns $true
        when both conditions are met.
    .DESCRIPTION
        Lighter than Assert-MacHostConditionSet (which also gates on
        Accessibility / Screen Recording TCC grants + display-sleep
        / screen-lock) -- this exists for one-off operator helpers
        (Remove-OrphanedVMFiles.ps1 etc.) where the TCC + screen
        checks would prompt unnecessarily during interactive
        maintenance.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $ok = $true
    if (-not (Test-Path '/Applications/UTM.app')) {
        Write-Warning "/Applications/UTM.app not found. Install UTM from https://mac.getutm.app."
        $ok = $false
    }
    if (-not (Get-Command utmctl -ErrorAction SilentlyContinue)) {
        Write-Warning "utmctl not found on PATH. The UTM.app bundle ships it at /Applications/UTM.app/Contents/MacOS/utmctl -- symlink it into /usr/local/bin or rerun host/macos.utm/Enable-TestAutomation.ps1."
        $ok = $false
    }
    return $ok
}

Export-ModuleMember -Function Assert-ScreenLock, Initialize-SudoCache, Test-MacSudoAvailable, Get-MacPmsetGuardList, Get-MacDefaultsCommandArgument, Set-MacHostConditionSet, Assert-Accessibility, Assert-ScreenRecording, Assert-MacHostConditionSet, Test-MacHostMinimum, Sync-MacHostClock
