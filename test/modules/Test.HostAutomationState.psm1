<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42b7c3e1-9d05-4a82-bf46-2e18c74a0d93
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host automation state capture restore
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
    Capture the host settings Enable-TestAutomation is about to change, so
    Disable-TestAutomation can put them back.
.DESCRIPTION
    Disable cannot guess what a knob was before automation touched it. "Display
    sleep was 10 minutes" and "display sleep was never set" are different
    machines, and restoring a plausible default to the second one is a silent
    change the operator never asked for. So Enable records the prior value of
    every knob it will write, once, before writing anything.

    Three rules shape the file:

      * Written ONCE, never overwritten. A second Enable run would otherwise
        capture the values Enable itself wrote and record them as the
        operator's -- which quietly makes the automation settings permanent.
      * Per-knob, not all-or-nothing. A partially-applied Enable (sudo declined
        halfway, a package missing) still leaves a usable record for the knobs
        it did reach.
      * Absent-before is recorded EXPLICITLY, as $null with Present = $false.
        "Remove what we added" and "restore what was there" are different
        actions, and a missing key cannot distinguish them.

    Reading is deliberately tolerant: every reader is wrapped so a knob this OS
    does not surface records as absent instead of ending the capture. A capture
    that stops halfway is worse than one with holes in it, because Enable
    proceeds either way.
#>

#requires -version 7

Set-StrictMode -Version Latest

# The version of the capture FORMAT, and equally of what its readers mean. Bump
# it whenever a reader starts being able to see something it could not see
# before, because "present = $false" is the answer a reader gives BOTH when the
# knob was genuinely unset and when it could not read the knob at all. A capture
# written by an older reader is trustworthy about the values it holds and not
# trustworthy about the ones it calls absent, and Invoke-HostKnobRestore is
# where that distinction has to be enforced -- removal is the branch an
# unreadable knob lands in, and a removal cannot be undone.
$script:HostAutomationStateSchemaVersion = 2

function Get-HostAutomationStateSchemaVersion {
<#
.SYNOPSIS
    The capture-format version this module writes and restores against.
.OUTPUTS
    [int]
#>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return $script:HostAutomationStateSchemaVersion
}

function Get-HostAutomationStatePath {
<#
.SYNOPSIS
    Path of the pre-automation capture file.
.DESCRIPTION
    Lives in the harness runtime dir (status/runtime/) alongside the other small
    operationally-interesting state -- so it is served at /runtime/ for
    inspection, and a runtime dir override moves it with everything else.
.OUTPUTS
    [string]
#>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not $env:YURUNA_RUNTIME_DIR) {
        if (-not (Get-Command Initialize-YurunaRuntimeDir -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $PSScriptRoot 'Test.YurunaDir.psm1') -Global -Force -DisableNameChecking -Verbose:$false
        }
        [void](Initialize-YurunaRuntimeDir)
    }
    return (Join-Path $env:YURUNA_RUNTIME_DIR 'host.pre-automation.json')
}

function Read-HostAutomationState {
<#
.SYNOPSIS
    The captured pre-automation state, or $null when this host has none.
.DESCRIPTION
    $null is the ordinary answer on a host enabled before the capture shipped,
    and Disable treats it as "reverse only what is provably ours" rather than as
    an error. A corrupt file is reported and treated the same way: guessing at
    half-parsed prior state is how a restore does damage.
.OUTPUTS
    [pscustomobject] or $null.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$Path = '')

    if (-not $Path) { $Path = Get-HostAutomationStatePath }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Warning "Could not read the pre-automation capture at $Path ($($_.Exception.Message)); treating this host as having no capture."
        return $null
    }
}

function New-HostAutomationKnob {
<#
.SYNOPSIS
    One captured knob: what it was, and whether it existed at all.
.PARAMETER Present
    $false records "there was no value here". Restoring then means REMOVING what
    Enable added, not writing some default back.
#>
    # A pure in-memory constructor: it returns a hashtable and touches nothing
    # on the host, so there is no state for -WhatIf to preview.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds and returns a hashtable; changes no system state.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Name,
        $Value = $null,
        [bool]$Present = $true,
        [string]$Note = ''
    )
    $knob = @{ name = $Name; present = $Present; value = $Value }
    if ($Note) { $knob['note'] = $Note }
    return $knob
}

function Invoke-CaptureRead {
<#
.SYNOPSIS
    Run one capture reader, turning any failure into an absent knob.
.DESCRIPTION
    The single most important property of the capture is that it does not throw:
    it runs immediately before Enable changes the host, and an exception here
    would abort a setup for the sake of recording it. A reader that fails
    records absent-with-a-note, which Disable reads as "do not touch this".
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Reader
    )
    try {
        $value = & $Reader
        if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) {
            return (New-HostAutomationKnob -Name $Name -Present $false)
        }
        return (New-HostAutomationKnob -Name $Name -Value $value)
    } catch {
        Write-Verbose "capture '$Name': $($_.Exception.Message)"
        return (New-HostAutomationKnob -Name $Name -Present $false -Note "could not be read: $($_.Exception.Message)")
    }
}

function Get-LinuxPreAutomationState {
<#
.SYNOPSIS
    Capture the ubuntu.kvm knobs Enable-TestAutomation writes.
.DESCRIPTION
    Covers the gsettings idle/lock/dim set, the NTP state, and -- only on the
    standalone Enable path -- the libvirtd/virtlogd enabled-state. Group
    membership and the $HOME ACL are captured as "was the host already in this
    state", so Disable removes only what Enable actually added.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $knobs = @{}
    $haveGsettings = [bool](Get-Command -Name 'gsettings' -ErrorAction SilentlyContinue)
    foreach ($t in @(
        @('org.gnome.settings-daemon.plugins.power', 'sleep-inactive-ac-type'),
        @('org.gnome.settings-daemon.plugins.power', 'sleep-inactive-battery-type'),
        @('org.gnome.desktop.session',               'idle-delay'),
        @('org.gnome.desktop.screensaver',           'lock-enabled'),
        @('org.gnome.settings-daemon.plugins.power', 'idle-dim')
    )) {
        $schema = $t[0]; $key = $t[1]
        $knobs["gsettings/$schema/$key"] = Invoke-CaptureRead -Name "gsettings $schema $key" -Reader {
            if (-not $haveGsettings) { return $null }
            # A schema this GNOME build does not ship exits non-zero; that is
            # "absent", not a failure worth a note.
            $v = & gsettings get $schema $key 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
            return "$v".Trim()
        }.GetNewClosure()
    }

    $knobs['timedatectl/ntp'] = Invoke-CaptureRead -Name 'timedatectl NTP' -Reader {
        if (-not (Get-Command -Name 'timedatectl' -ErrorAction SilentlyContinue)) { return $null }
        $line = & timedatectl show --property=NTP --value 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return "$line".Trim()
    }

    foreach ($unit in @('libvirtd', 'virtlogd')) {
        $knobs["systemd/$unit"] = Invoke-CaptureRead -Name "systemctl is-enabled $unit" -Reader {
            if (-not (Get-Command -Name 'systemctl' -ErrorAction SilentlyContinue)) { return $null }
            # is-enabled exits non-zero for 'disabled' yet still PRINTS it, so
            # the output is the answer and the exit code is not.
            $v = & systemctl is-enabled $unit 2>$null
            if ([string]::IsNullOrWhiteSpace("$v")) { return $null }
            return "$v".Trim()
        }.GetNewClosure()
    }

    foreach ($grp in @('libvirt', 'kvm')) {
        $knobs["group/$grp"] = Invoke-CaptureRead -Name "membership of $grp" -Reader {
            $line = & getent group $grp 2>$null
            if (-not $line) { return 'no-such-group' }
            $members = (("$line" -split ':', 4)[3]) -split ','
            return $(if ($members -contains $env:USER) { 'member' } else { 'not-a-member' })
        }.GetNewClosure()
    }

    $knobs['acl/home'] = Invoke-CaptureRead -Name "libvirt-qemu search ACL on $HOME" -Reader {
        if (-not (Get-Command -Name 'getfacl' -ErrorAction SilentlyContinue)) { return $null }
        $acl = & getfacl -p $HOME 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return $(if ($acl -match '^user:libvirt-qemu:') { 'present' } else { 'absent' })
    }

    return $knobs
}

function Get-MacPreAutomationState {
<#
.SYNOPSIS
    Capture the macos.utm knobs Set-MacHostConditionSet writes.
.DESCRIPTION
    Display sleep is captured for AC and battery SEPARATELY, because pmset
    writes them separately (-c / -b) and a Mac restored to one value on both
    has silently lost its battery policy. The pmset guard list is read from
    Get-MacPmsetGuardList so this capture cannot drift from the set actually
    applied: a guard added there is captured here without an edit.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $knobs = @{}
    if (-not $IsMacOS) { return $knobs }

    # The apply side owns both the guard list and the `defaults` argument order,
    # so this capture reads them from there rather than restating either. A
    # capture that spells a command differently from the write it is recording
    # is a capture of the wrong thing.
    if (-not (Get-Command Get-MacDefaultsCommandArgument -ErrorAction SilentlyContinue)) {
        $macModule = Join-Path $PSScriptRoot 'Test.HostCondition.Mac.psm1'
        if (Test-Path -LiteralPath $macModule) {
            Import-Module $macModule -Global -Force -DisableNameChecking -Verbose:$false
        }
    }

    # `pmset -g custom` prints an AC Power block and a Battery Power block; the
    # same key appears in both with different values, so the block has to be
    # tracked while parsing rather than the first match taken.
    $custom = @(& pmset -g custom 2>$null)
    $section = ''
    $acValues  = @{}
    $batValues = @{}
    foreach ($line in $custom) {
        if ($line -match '^\s*AC Power:')      { $section = 'ac';  continue }
        if ($line -match '^\s*Battery Power:') { $section = 'bat'; continue }
        if ($line -match '^\s*([A-Za-z]+)\s+(\S+)\s*$') {
            $k = $Matches[1]; $v = $Matches[2]
            if ($section -eq 'ac')  { $acValues[$k]  = $v }
            if ($section -eq 'bat') { $batValues[$k] = $v }
        }
    }

    foreach ($key in @('displaysleep', 'sleep', 'disksleep')) {
        foreach ($pair in @(@{ Scope = 'ac'; Table = $acValues }, @{ Scope = 'battery'; Table = $batValues })) {
            $scope = $pair.Scope; $table = $pair.Table
            $knobs["pmset/$scope/$key"] = Invoke-CaptureRead -Name "pmset -$scope $key" -Reader {
                if ($table.ContainsKey($key)) { return "$($table[$key])" }
                return $null
            }.GetNewClosure()
        }
    }

    if (Get-Command Get-MacPmsetGuardList -ErrorAction SilentlyContinue) {
        foreach ($guard in (Get-MacPmsetGuardList)) {
            $key = $guard.Key
            $knobs["pmset/guard/$key"] = Invoke-CaptureRead -Name "pmset $key" -Reader {
                if ($acValues.ContainsKey($key)) { return "$($acValues[$key])" }
                return $null
            }.GetNewClosure()
        }
    }

    # Both domains: the user domain and -currentHost hold independent values,
    # and Set- writes both. Restoring only one leaves the Mac in a state it was
    # never in.
    foreach ($spec in @(
        @{ Key = 'screensaver/user/idleTime'                  ; Args = @('com.apple.screensaver', 'idleTime') }
        @{ Key = 'screensaver/user/askForPassword'            ; Args = @('com.apple.screensaver', 'askForPassword') }
        @{ Key = 'screensaver/user/askForPasswordDelay'       ; Args = @('com.apple.screensaver', 'askForPasswordDelay') }
        @{ Key = 'screensaver/currentHost/idleTime'           ; Args = @('-currentHost', 'com.apple.screensaver', 'idleTime') }
        @{ Key = 'screensaver/currentHost/askForPassword'     ; Args = @('-currentHost', 'com.apple.screensaver', 'askForPassword') }
        @{ Key = 'screensaver/currentHost/askForPasswordDelay'; Args = @('-currentHost', 'com.apple.screensaver', 'askForPasswordDelay') }
        @{ Key = 'dock/wvous-tl-corner'                       ; Args = @('com.apple.dock', 'wvous-tl-corner') }
        @{ Key = 'dock/wvous-tr-corner'                       ; Args = @('com.apple.dock', 'wvous-tr-corner') }
        @{ Key = 'dock/wvous-bl-corner'                       ; Args = @('com.apple.dock', 'wvous-bl-corner') }
        @{ Key = 'dock/wvous-br-corner'                       ; Args = @('com.apple.dock', 'wvous-br-corner') }
        @{ Key = 'dock/wvous-tl-modifier'                     ; Args = @('com.apple.dock', 'wvous-tl-modifier') }
        @{ Key = 'dock/wvous-tr-modifier'                     ; Args = @('com.apple.dock', 'wvous-tr-modifier') }
        @{ Key = 'dock/wvous-bl-modifier'                     ; Args = @('com.apple.dock', 'wvous-bl-modifier') }
        @{ Key = 'dock/wvous-br-modifier'                     ; Args = @('com.apple.dock', 'wvous-br-modifier') }
        @{ Key = 'utm/NSAppSleepDisabled'                     ; Args = @('com.utmapp.UTM', 'NSAppSleepDisabled') }
        @{ Key = 'utm/KeepRunningAfterLastWindowClosed'       ; Args = @('com.utmapp.UTM', 'KeepRunningAfterLastWindowClosed') }
        @{ Key = 'global/AppleSpacesSwitchOnActivation'       ; Args = @('NSGlobalDomain', 'AppleSpacesSwitchOnActivation') }
    )) {
        # The host selector belongs AHEAD of the verb; emitted verb-first,
        # `defaults` binds '-currentHost' as the domain and reports every ByHost
        # knob as absent -- so a capture built that way records "there was
        # nothing here" for three knobs that hold real values, and the restore
        # then deletes them.
        #
        # The argv is assembled INSIDE the reader so that resolving the builder
        # is covered by Invoke-CaptureRead's catch. This capture runs in the
        # seconds before the host is changed, and an install that cannot reach
        # the apply-side module has to record "could not be read" and let the
        # setup continue, not abort the setup for the sake of recording it.
        $specArgs = @($spec.Args)
        $knobs["defaults/$($spec.Key)"] = Invoke-CaptureRead -Name "defaults: $($specArgs -join ' ')" -Reader {
            $defaultsArgs = @(Get-MacDefaultsCommandArgument -Verb 'read' -DefaultsArgs $specArgs)
            $v = & defaults @defaultsArgs 2>$null
            # Exit code, not emptiness: a key legitimately holding "" is not the
            # same as a key that does not exist, and only the exit code says which.
            if ($LASTEXITCODE -ne 0) { return $null }
            return "$v".Trim()
        }.GetNewClosure()
    }

    $knobs['sysadminctl/screenLock'] = Invoke-CaptureRead -Name 'sysadminctl -screenLock status' -Reader {
        # sysadminctl reports on stderr; 2>&1 or the status is lost.
        $out = & sysadminctl -screenLock status 2>&1
        if ([string]::IsNullOrWhiteSpace("$out")) { return $null }
        return "$out".Trim()
    }

    $knobs['autologout'] = Invoke-CaptureRead -Name 'com.apple.autologout AutoLogOutDelay' -Reader {
        $v = & defaults read /Library/Preferences/.GlobalPreferences com.apple.autologout.AutoLogOutDelay 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return "$v".Trim()
    }

    $knobs['networktime'] = Invoke-CaptureRead -Name 'systemsetup -getusingnetworktime' -Reader {
        $v = & systemsetup -getusingnetworktime 2>$null
        if ([string]::IsNullOrWhiteSpace("$v")) { return $null }
        return "$v".Trim()
    }

    return $knobs
}

function Get-WindowsPreAutomationState {
<#
.SYNOPSIS
    Capture the windows.hyper-v knobs Set-WindowsHostConditionSet writes.
.DESCRIPTION
    Includes the prior Enabled state of each BUILT-IN inbound ICMPv4 rule Enable
    switches on, recorded by rule name. Those rules already existed on the host;
    turning them off wholesale on Disable would break unrelated things, so only
    the ones Enable actually changed can be put back.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $knobs = @{}
    if (-not $IsWindows) { return $knobs }

    foreach ($scheme in @('AC', 'DC')) {
        $knobs["powercfg/monitor-timeout-$scheme"] = Invoke-CaptureRead -Name "powercfg monitor timeout ($scheme)" -Reader {
            $out = & powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
            $needle = if ($scheme -eq 'AC') { 'Current AC Power Setting Index' } else { 'Current DC Power Setting Index' }
            foreach ($line in $out) {
                if ("$line" -match [regex]::Escape($needle) + '\s*:\s*(0x[0-9a-fA-F]+)') {
                    return [string][Convert]::ToInt32($Matches[1], 16)
                }
            }
            return $null
        }.GetNewClosure()
    }

    # AC and DC separately: Set-WindowsHostConditionSet writes BOTH to 0 but only
    # reads AC to decide, so restoring the AC value to both would leave the host
    # in a state it was never in.
    foreach ($scheme in @('AC', 'DC')) {
        $knobs["powercfg/CONSOLELOCK-$scheme"] = Invoke-CaptureRead -Name "powercfg CONSOLELOCK ($scheme)" -Reader {
            $out = & powercfg /query SCHEME_CURRENT SUB_NONE CONSOLELOCK 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
            foreach ($line in $out) {
                if ("$line" -match "Current $scheme Power Setting Index\s*:\s*(0x[0-9a-fA-F]+)") {
                    return [string][Convert]::ToInt32($Matches[1], 16)
                }
            }
            return $null
        }.GetNewClosure()
    }

    $knobs['policy/InactivityTimeoutSecs'] = Invoke-CaptureRead -Name 'InactivityTimeoutSecs' -Reader {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        if (-not (Test-Path -LiteralPath $key)) { return $null }
        $item = Get-ItemProperty -LiteralPath $key -Name 'InactivityTimeoutSecs' -ErrorAction SilentlyContinue
        if (-not $item) { return $null }
        return [string]$item.InactivityTimeoutSecs
    }

    # Per-monitor scaling: DpiValue is a per-display offset under a key whose
    # name identifies the monitor, so the capture is keyed by that name and a
    # monitor absent at Disable time is reported rather than guessed at.
    $knobs['dpi/perMonitor'] = Invoke-CaptureRead -Name 'per-monitor DpiValue' -Reader {
        $root = 'HKCU:\Control Panel\Desktop\PerMonitorSettings'
        if (-not (Test-Path -LiteralPath $root)) { return $null }
        $map = @{}
        foreach ($sub in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $item = Get-ItemProperty -LiteralPath $sub.PSPath -Name 'DpiValue' -ErrorAction SilentlyContinue
            if ($item) { $map[$sub.PSChildName] = [string]$item.DpiValue }
            else { $map[$sub.PSChildName] = 'absent' }
        }
        if ($map.Count -eq 0) { return $null }
        return $map
    }

    foreach ($name in @('LogPixels', 'Win8DpiScaling')) {
        $knobs["dpi/$name"] = Invoke-CaptureRead -Name "Desktop\\$name" -Reader {
            $item = Get-ItemProperty -LiteralPath 'HKCU:\Control Panel\Desktop' -Name $name -ErrorAction SilentlyContinue
            if (-not $item) { return $null }
            return [string]$item.$name
        }.GetNewClosure()
    }

    $knobs['dpi/TextScaleFactor'] = Invoke-CaptureRead -Name 'TextScaleFactor' -Reader {
        $item = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Accessibility' -Name 'TextScaleFactor' -ErrorAction SilentlyContinue
        if (-not $item) { return $null }
        return [string]$item.TextScaleFactor
    }

    # Selected by PROTOCOL FILTER, deliberately matching Set-WindowsHostConditionSet
    # rule-for-rule. Selecting on DisplayName instead would miss every rule whose
    # name does not spell "ICMPv4" -- Enable would switch those on and Disable
    # would have no record to switch them back, which is the silent half-restore
    # this capture exists to prevent.
    $knobs['firewall/icmpv4BuiltIn'] = Invoke-CaptureRead -Name 'built-in ICMPv4 rule Enabled state' -Reader {
        if (-not (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue)) { return $null }

        # Two performance decisions, both worth a minute of an operator's day:
        #
        #   -PolicyStore ActiveStore -- the effective runtime policy, which is
        #   also what "is this rule enabled right now" means. Measured on a
        #   318-rule host: 2.6 s here against 43 s for the default store, which
        #   merges the persistent and GPO stores on every association traversal.
        #   Both stores select the identical rule set.
        #
        #   ONE batched pipeline into Get-NetFirewallPortFilter, joined on
        #   InstanceID (which equals the rule's Name), rather than a filter call
        #   per rule inside Where-Object. Per-rule costs one CIM association
        #   traversal each -- 318 of them, 55 s.
        $rules = @(Get-NetFirewallRule -PolicyStore ActiveStore -Direction Inbound -Action Allow -ErrorAction SilentlyContinue)
        if ($rules.Count -eq 0) { return $null }

        $echoRuleIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($filter in ($rules | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue)) {
            if ("$($filter.Protocol)" -ne 'ICMPv4') { continue }
            # IcmpType 8 is echo request; it may be listed as '8', '8:*' or among
            # others. 'Any' includes echo request, so it counts too -- the same
            # test Set-WindowsHostConditionSet applies.
            $types = ($filter.IcmpType -join ',')
            if ($types -match '(^|,)8(:|\*|,|$)' -or $types -match '(^|,)Any($|,)') {
                [void]$echoRuleIds.Add([string]$filter.InstanceID)
            }
        }

        $map = @{}
        foreach ($rule in $rules) {
            if (-not $echoRuleIds.Contains([string]$rule.Name)) { continue }
            # Our own rule is removed outright, not restored -- recording its
            # state would invite Disable to "restore" a rule it just deleted.
            if ($rule.DisplayName -like 'Yuruna:*') { continue }
            $map[$rule.Name] = [string]$rule.Enabled
        }
        if ($map.Count -eq 0) { return $null }
        return $map
    }

    return $knobs
}

function Save-HostAutomationState {
<#
.SYNOPSIS
    Capture this host's pre-automation state, once. Returns the path written, or
    '' when a capture already existed (or -WhatIf suppressed the write).
.DESCRIPTION
    Call this from Enable-TestAutomation BEFORE any setting is changed.

    Refuses to overwrite an existing capture. That refusal is the whole point:
    the second Enable run sees the values the first one wrote, and recording
    those as "the operator's settings" would make the automation permanent while
    looking like it had been captured correctly.
.PARAMETER Platform
    'ubuntu.kvm' | 'macos.utm' | 'windows.hyper-v'. Selects the reader set.
.PARAMETER Force
    Overwrite an existing capture. For re-capturing a host deliberately returned
    to its own settings by hand; not part of any normal flow.
.OUTPUTS
    [string] path written, or ''.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ubuntu.kvm', 'macos.utm', 'windows.hyper-v')]
        [string]$Platform,
        [switch]$Force
    )

    $path = Get-HostAutomationStatePath
    if ((Test-Path -LiteralPath $path) -and -not $Force) {
        Write-Verbose "Pre-automation state was already captured at $path; leaving it as it is."
        return ''
    }

    $knobs = switch ($Platform) {
        'ubuntu.kvm'      { Get-LinuxPreAutomationState }
        'macos.utm'       { Get-MacPreAutomationState }
        'windows.hyper-v' { Get-WindowsPreAutomationState }
    }

    $doc = [ordered]@{
        schemaVersion = $script:HostAutomationStateSchemaVersion
        platform      = $Platform
        capturedUtc   = [datetime]::UtcNow.ToString('o')
        capturedBy    = $(if ($env:USER) { $env:USER } elseif ($env:USERNAME) { $env:USERNAME } else { 'unknown' })
        knobs         = $knobs
    }

    if (-not $PSCmdlet.ShouldProcess($path, 'Write the pre-automation state capture')) { return '' }
    try {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        # Depth 6: the per-monitor and firewall knobs nest a map inside a knob
        # inside the knob table, and the default depth of 2 would render those
        # as type names instead of values.
        $doc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding utf8
        Write-Verbose "Captured pre-automation state to $path ($($knobs.Count) knobs)."
        return $path
    } catch {
        # Never fatal: Enable's job is to configure the host, and failing that
        # because the record could not be written would trade a working host for
        # a bookkeeping problem. Disable degrades to "reverse only what is
        # provably ours", which it already handles.
        Write-Warning "Could not write the pre-automation capture to $path ($($_.Exception.Message)). Disable-TestAutomation will only be able to reverse what it can prove it added."
        return ''
    }
}

function Get-HostAutomationKnob {
<#
.SYNOPSIS
    One knob from a capture: @{ present; value }, or $null when the capture has
    no record of it.
.DESCRIPTION
    $null and "present = $false" are different answers and callers must treat
    them differently. $null means "never captured" -- leave the setting alone.
    present=$false means "captured, and there was nothing there" -- remove what
    Enable added. Collapsing the two turns an unknown into a deletion.
.OUTPUTS
    [pscustomobject] with .present and .value, or $null.
#>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        $State,
        [Parameter(Mandatory)][string]$Name
    )
    if (-not $State) { return $null }
    if (-not $State.PSObject.Properties['knobs']) { return $null }
    $knobs = $State.knobs
    if (-not $knobs) { return $null }
    $prop = $knobs.PSObject.Properties[$Name]
    if (-not $prop) { return $null }
    return $prop.Value
}

function Assert-SafeToDisable {
<#
.SYNOPSIS
    $true when no other test runner owns this runtime dir.
.DESCRIPTION
    Restoring screen lock and display sleep underneath a live cycle would blank
    the display mid-capture and fail the run for reasons nothing in the
    transcript would explain. Uses the same PID+StartTime identity check the
    other entry points use, so a stale pid file does not block a legitimate
    Disable.
.OUTPUTS
    [bool]
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$RuntimeDir = '')

    if (-not $RuntimeDir) {
        if (-not $env:YURUNA_RUNTIME_DIR) {
            if (-not (Get-Command Initialize-YurunaRuntimeDir -ErrorAction SilentlyContinue)) {
                Import-Module (Join-Path $PSScriptRoot 'Test.YurunaDir.psm1') -Global -Force -DisableNameChecking -Verbose:$false
            }
            [void](Initialize-YurunaRuntimeDir)
        }
        $RuntimeDir = $env:YURUNA_RUNTIME_DIR
    }
    foreach ($m in @('Test.SingleInstance.psm1', 'Test.Prelude.psm1')) {
        $path = Join-Path $PSScriptRoot $m
        if (Test-Path -LiteralPath $path) { Import-Module $path -Global -Force -DisableNameChecking -Verbose:$false }
    }
    if (-not (Get-Command Assert-NoOtherRunner -ErrorAction SilentlyContinue)) { return $true }
    return (Assert-NoOtherRunner -RuntimeDir $RuntimeDir -CallerName 'Disable-TestAutomation')
}

function Test-HostRestorePreviewOnly {
<#
.SYNOPSIS
    Whether the operator asked for a preview, read from the CALLER's scope.
.DESCRIPTION
    ShouldProcess can only speak for the cmdlet object it belongs to, and that
    object knows it is previewing only when -WhatIf was BOUND to it. A per-host
    Disable script binds the switch; the local helper it calls one frame down
    does not, so the helper's cmdlet has no bound value and falls back to
    $WhatIfPreference -- resolved, at the moment ShouldProcess is asked, in
    whatever session state is current. Asked from inside this module that is the
    MODULE's copy, which is $false, and every restore then runs for real against
    a host the operator only asked to describe.

    $Cmdlet.GetVariableValue reaches the caller's own scope instead of this
    module's, which is the one place the answer is true regardless of which
    frame supplied the cmdlet.
.OUTPUTS
    [bool]
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Cmdlet)
    try { return [bool]$Cmdlet.GetVariableValue('WhatIfPreference') } catch { return $false }
}

function Invoke-HostKnobRestore {
<#
.SYNOPSIS
    Apply one captured knob, recording the outcome into the caller's restored /
    skipped lists. Shared by all three per-host Disable scripts.
.DESCRIPTION
    Three cases, and keeping them distinct is the whole job:

      * not captured  -> leave alone, and say so. We cannot know what it was, and
                         a plausible default is still a change nobody asked for.
      * captured, absent -> the knob did not exist before automation, so REMOVE
                         what Enable added (-Absent). With no -Absent handler it
                         is left alone and reported, because a setting we cannot
                         prove we created is not ours to delete.
      * captured, present -> write the prior value back.
.PARAMETER Cmdlet
    The caller's $PSCmdlet, so -WhatIf and -Confirm belong to the script the
    operator actually invoked rather than to this module.
#>
    # The ShouldProcess call is deliberately the CALLER's, passed in as -Cmdlet:
    # -WhatIf must belong to the Disable script the operator ran. Declaring
    # SupportsShouldProcess here would add a second, independent gate that the
    # operator's -WhatIf does not reach.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'ShouldProcess is invoked on the caller-supplied $PSCmdlet so -WhatIf belongs to the invoked script.')]
    [CmdletBinding()]
    param(
        $State,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Apply,
        [scriptblock]$Absent,
        [Parameter(Mandatory)]$Cmdlet,
        # AllowEmptyCollection: both lists are empty on the FIRST call of every
        # run, and Mandatory alone rejects an empty collection -- which would
        # fail each Disable script on its first knob.
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Restored,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Skipped
    )

    $knob = Get-HostAutomationKnob -State $State -Name $Name
    if (-not $knob) { $Skipped.Add("$Description (not captured)"); return }

    # ShouldProcess stays the primary gate -- it is what narrates a preview in
    # the operator's own words. The preview probe is the veto that catches the
    # case ShouldProcess cannot see, and it costs nothing on a real run because
    # it is only consulted after ShouldProcess has already said yes.
    $preview = Test-HostRestorePreviewOnly -Cmdlet $Cmdlet

    if (-not $knob.present) {
        if (-not $Absent) { $Skipped.Add("$Description (nothing was set before; left as it is)"); return }
        # "Absent" is the same answer a reader gives when it could not read the
        # knob, so it is only safe to act on when the reader that produced it is
        # the one this code ships with. An older capture's absent records are
        # left alone and reported: removing a value the host has held all along
        # is not reversible, and the report gives the operator the one thing
        # that is -- knowing which knob was skipped and why.
        $captureVersion = 0
        if ($State -and $State.PSObject.Properties['schemaVersion']) { $captureVersion = [int]$State.schemaVersion }
        if ($captureVersion -lt $script:HostAutomationStateSchemaVersion) {
            $Skipped.Add("$Description (recorded as absent by an older capture, which cannot tell 'was not set' from 'could not be read'; check and clear it by hand)")
            return
        }
        if ($Cmdlet.ShouldProcess($Description, 'Remove (nothing was set before automation)')) {
            # Reported through the caller's own list rather than an information
            # stream: a preference variable does not follow a call into this
            # module, so a line written here would be discarded and the veto
            # would look like a knob that simply needed nothing.
            if ($preview) { $Skipped.Add("$Description (preview only -- would be removed; nothing was changed)"); return }
            try {
                & $Absent
                $Restored.Add("$Description -> removed (was unset)")
            } catch {
                # One knob failing must not abandon the rest of the restore: a
                # half-restored host with a clear report beats an exception at
                # knob three and no report at all.
                $Skipped.Add("$Description (removal failed: $($_.Exception.Message))")
            }
        }
        return
    }

    if ($Cmdlet.ShouldProcess($Description, "Restore to '$($knob.value)'")) {
        if ($preview) { $Skipped.Add("$Description (preview only -- would be restored to '$($knob.value)'; nothing was changed)"); return }
        try {
            & $Apply $knob.value
            $Restored.Add("$Description -> $($knob.value)")
        } catch {
            $Skipped.Add("$Description (restore failed: $($_.Exception.Message))")
        }
    }
}

function Write-DisableReport {
<#
.SYNOPSIS
    The closing report every Disable script prints: what changed, what did not,
    and why.
.DESCRIPTION
    "Left as it is" is not filler. It is the part an operator needs, because a
    Disable that silently declines to touch something reads as a Disable that
    already handled it.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Platform,
        # Both are legitimately empty on a host that needed no restoring.
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Restored,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[string]]$Skipped
    )
    Write-Output ''
    Write-Output "=== Disable-TestAutomation ($Platform) ==="
    if ($Restored.Count -gt 0) {
        Write-Output 'Restored:'
        foreach ($r in $Restored) { Write-Output "  - $r" }
    } else {
        Write-Output 'Nothing needed restoring.'
    }
    if ($Skipped.Count -gt 0) {
        Write-Output ''
        Write-Output 'Left as it is:'
        foreach ($s in $Skipped) { Write-Output "  - $s" }
    }
}

function Get-PoolStorageManualTeardown {
<#
.SYNOPSIS
    The exact commands that would tear down networkStorage on this host, with
    the real mount point substituted in.
.DESCRIPTION
    Disable never tears storage down itself -- that is a surprise on a command
    that says "disable settings". But naming the mount point turns a vague
    caveat into something an operator can paste.
.OUTPUTS
    [string[]] commands, empty when no storage is configured.
#>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $configPath = Join-Path $RepoRoot 'test/test.config.yml'
    if (-not (Test-Path -LiteralPath $configPath)) { return [string[]]@() }
    try {
        if (-not (Get-Command Read-TestConfig -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $PSScriptRoot 'Test.Config.psm1') -Global -Force -DisableNameChecking -Verbose:$false
        }
        $cfg = Read-TestConfig -Path $configPath
        $localPath = ''
        if ($cfg -and $cfg.networkStorage -is [System.Collections.IDictionary] -and $cfg.networkStorage.Contains('pool')) {
            $pool = $cfg.networkStorage.pool
            if ($pool -is [System.Collections.IDictionary] -and $pool.Contains('localPath')) { $localPath = "$($pool.localPath)".Trim() }
        }
        if (-not $localPath) { return [string[]]@() }
        return [string[]]@(
            "Import-Module $RepoRoot/test/modules/Test.PoolStorage.psm1",
            "Dismount-PoolStoragePoint -MountPoint '$localPath'",
            "then clear the networkStorage.* keys in test/test.config.yml"
        )
    } catch {
        Write-Verbose "Get-PoolStorageManualTeardown: $($_.Exception.Message)"
        return [string[]]@()
    }
}

function Write-DisableManualStep {
<#
.SYNOPSIS
    Report something Disable deliberately did NOT undo, with the exact command
    that would.
.DESCRIPTION
    The value here is precision. "Storage was left configured" sends an operator
    hunting; the Dismount command they can paste does not. Everything Disable
    declines to touch goes through this, so the closing report is complete.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$What,
        [string[]]$Command = @()
    )
    Write-Output "  - $What"
    foreach ($c in $Command) { Write-Output "      $c" }
}

Export-ModuleMember -Function Get-HostAutomationStatePath, Get-HostAutomationStateSchemaVersion,
    Test-HostRestorePreviewOnly, Read-HostAutomationState, Save-HostAutomationState,
    Get-LinuxPreAutomationState, Get-MacPreAutomationState, Get-WindowsPreAutomationState,
    Get-HostAutomationKnob, Assert-SafeToDisable, Write-DisableManualStep,
    Invoke-HostKnobRestore, Write-DisableReport, Get-PoolStorageManualTeardown
