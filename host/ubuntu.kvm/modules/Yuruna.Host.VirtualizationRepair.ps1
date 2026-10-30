<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42369f8d-10e5-451c-9a33-46b95af76542
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host ubuntu.kvm driver virtualization repair
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

# --- REGION: Virtualization repair
# --- REGION: Test-VirtualizationResponsive
function Test-VirtualizationResponsive {
    <#
    .SYNOPSIS
        Bounded, read-only probe of the libvirt control channel. Returns the
        versioned Yuruna.VirtualizationProbe record (schema version 1).
    .DESCRIPTION
        One `virsh list --name` round trip over the connection and locale pin every
        other virsh call in this driver uses (qemu:///system, LC_MESSAGES=C, LC_ALL
        cleared): without the URI an unprivileged user reaches qemu:///session, a
        different daemon, and without the pin the error text the classifier reads
        arrives translated. The call runs through Invoke-BoundedNativeCommand, so a
        wedged libvirtd is reported as a classified timeout instead of holding the
        caller, and the whole probe fits inside min(TimeoutSeconds, -Deadline).

        Classification, first match wins:
          * virsh missing or not launchable        -> Undetermined/missing-client
          * less than one second of budget left    -> Undetermined/deadline-exhausted
                                                       (nothing is launched)
          * no answer inside the cap               -> Unresponsive/timeout
          * output not drained or truncated        -> Undetermined/invalid-response
          * exit 0                                 -> Responsive/responsive
          * permission, authentication or polkit   -> Undetermined/permission-denied,
            refusal                                   with the libvirt group standing
                                                      (a stale login session is not a
                                                      daemon fault)
          * the control socket is missing or       -> Unresponsive/app-stopped only when
            refuses connections                       the daemon's service and socket
                                                      units are both positively not
                                                      running; otherwise
                                                      Undetermined/provider-error
          * any other failure                      -> Undetermined/provider-error
        Unresponsive is never inferred from an exit code alone: app-stopped needs
        the missing socket plus unit state that agrees, and only a timeout is
        otherwise treated as an unanswered hypervisor.

        Evidence keys, always present: connection, localePinned, client (present|
        missing), socket (reachable|absent|refused|denied|unknown), libvirtGroup
        (active|stale-session|not-member|unknown|not-probed), exitCode,
        drainTimedOut, outputTruncated. The diagnostic field is private: it may go
        to a private log and never to a public projection.

        Never throws, never prompts, changes nothing.
    .PARAMETER TimeoutSeconds
        Upper bound for the probe.
    .PARAMETER Deadline
        Optional shared deadline (New-YurunaDeadline / New-YurunaDeadlineFromExpiry);
        the probe never outlives it.
    .OUTPUTS
        [pscustomobject] Yuruna.VirtualizationProbe
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 20,
        [object]$Deadline
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $observedUtc = [DateTime]::UtcNow.ToString('o')
    $clock = if ($null -ne $Deadline -and $Deadline.ClockTicks) { $Deadline.ClockTicks } else { { [Environment]::TickCount64 } }
    $evidence = [ordered]@{
        connection      = [string]$script:VirshUri
        localePinned    = $true
        client          = 'present'
        socket          = 'unknown'
        libvirtGroup    = 'not-probed'
        exitCode        = -1
        drainTimedOut   = $false
        outputTruncated = $false
    }
    $state = 'Undetermined'; $reason = 'invalid-response'
    $started = $false; $timedOut = $false; $deadlineExhausted = $false; $diagnostic = ''
    try {
        do {
            if (-not (Get-Command -Name 'virsh' -CommandType Application -ErrorAction SilentlyContinue)) {
                $evidence.client = 'missing'; $reason = 'missing-client'
                break
            }
            $capSeconds = $TimeoutSeconds
            if ($null -ne $Deadline) {
                $bounded = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling 600
                if ($null -eq $bounded) { $reason = 'deadline-exhausted'; $deadlineExhausted = $true; break }
                $capSeconds = [Math]::Min($TimeoutSeconds, [int]$bounded)
            }
            $probeDeadline = New-YurunaDeadlineFromExpiry -ExpiryTick ([long](& $clock) + [long]$capSeconds * 1000) -ClockTicks $clock
            $result = Invoke-VirshBounded -VirshArgs @('list', '--name') -TimeoutSeconds $capSeconds
            $started = [bool]$result.Started
            $evidence.exitCode        = [int]$result.ExitCode
            $evidence.drainTimedOut   = [bool]$result['DrainTimedOut']
            $evidence.outputTruncated = [bool]$result['OutputTruncated']
            if (-not $started) { $evidence.client = 'missing'; $reason = 'missing-client'; break }
            if ($result.TimedOut) { $state = 'Unresponsive'; $reason = 'timeout'; $timedOut = $true; break }
            $text = "$($result.StdErr)`n$($result.StdOut)"
            if (-not (Test-DriverNativeResultComplete -Result $result)) { $reason = 'invalid-response'; $diagnostic = $text; break }
            if ($result.ExitCode -eq 0) { $state = 'Responsive'; $reason = 'responsive'; $evidence.socket = 'reachable'; break }
            $diagnostic = $text
            if ($text -match '(?i)permission denied|authentication (failed|unavailable)|access denied|not authorized|polkit') {
                $reason = 'permission-denied'; $evidence.socket = 'denied'
                $groupCap = Get-YurunaDeadlineBoundedSeconds -Deadline $probeDeadline -Ceiling 5
                if ($null -ne $groupCap) { $evidence.libvirtGroup = Get-KvmLibvirtGroupEvidence -TimeoutSeconds $groupCap }
                break
            }
            $socketFailure = [regex]::Match($text, "(?i)failed to connect socket to '[^']+':\s*(?<cause>no such file or directory|connection refused)")
            if ($socketFailure.Success) {
                $evidence.socket = if ($socketFailure.Groups['cause'].Value -match '(?i)refused') { 'refused' } else { 'absent' }
                # A missing socket only proves the daemon is stopped when systemd
                # agrees that neither the daemon nor its activation socket runs;
                # a socket unit that is active but refusing is a daemon fault.
                $unitCap = Get-YurunaDeadlineBoundedSeconds -Deadline $probeDeadline -Ceiling 10
                if ($null -eq $unitCap) { $reason = 'deadline-exhausted'; $deadlineExhausted = $true; break }
                $layout = Get-KvmDaemonLayout -TimeoutSeconds $unitCap
                $recipe = if ($layout.Resolved -and $script:KvmDaemonRecipe.ContainsKey([string]$layout.Layout)) { $script:KvmDaemonRecipe[[string]$layout.Layout] } else { $null }
                $stoppedUnits = 0
                $unitWords = [System.Collections.Generic.List[string]]::new()
                if ($recipe) {
                    foreach ($unitName in @($recipe.ControlService, $recipe.ControlSocket)) {
                        $unit = $layout.Units[$unitName]
                        if ($unit) {
                            [void]$unitWords.Add("$unitName=$($unit.ActiveState)/$($unit.SubState)")
                            if ($unit.LoadState -eq 'loaded' -and $unit.ActiveState -in @('inactive', 'failed')) { $stoppedUnits++ }
                        }
                    }
                }
                $diagnostic = "$text layout=$($layout.Layout) $($unitWords -join ' ')"
                if ($recipe -and $stoppedUnits -eq 2) { $state = 'Unresponsive'; $reason = 'app-stopped' }
                else { $reason = 'provider-error' }
                break
            }
            $reason = 'provider-error'
        } while ($false)
    } catch {
        # The record is the contract: an unexpected fault (under a caller's
        # ErrorActionPreference of Stop any non-terminating error is one)
        # becomes an Undetermined answer, which authorizes nothing.
        $state = 'Undetermined'; $reason = 'provider-error'
        $diagnostic = "$diagnostic $($_.Exception.Message)"
    }
    return New-KvmVirtualizationProbeRecord -State $state -Reason $reason -Started $started -TimedOut $timedOut `
        -DeadlineExhausted $deadlineExhausted -ObservedUtc $observedUtc -ObservedTick ([long](& $clock)) `
        -ElapsedMs $stopwatch.ElapsedMilliseconds -Evidence $evidence -Diagnostic $diagnostic
}

<#
.SYNOPSIS
    Build one Yuruna.VirtualizationProbe record (schema version 1).
.DESCRIPTION
    Every return path of the probe goes through here so the record always has
    every field and every evidence key, whichever branch produced it.
#>
function New-KvmVirtualizationProbeRecord {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only; nothing on disk or in process state changes.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][string]$Reason,
        [bool]$Started,
        [bool]$TimedOut,
        [bool]$DeadlineExhausted,
        [Parameter(Mandatory)][string]$ObservedUtc,
        [long]$ObservedTick,
        [long]$ElapsedMs,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Evidence,
        [AllowEmptyString()][string]$Diagnostic = ''
    )
    $arguments = @{} + $PSBoundParameters
    $arguments['Diagnostic'] = Format-VirtualizationProbeDiagnostic -Text $Diagnostic
    New-YurunaVirtualizationProbeRecord @arguments -HostType (Resolve-HostTag)
}

<#
.SYNOPSIS
    Classify this process's libvirt group standing for a permission-denied
    probe: active, stale-session, not-member, unknown or not-probed.
.DESCRIPTION
    Reuses Get-LibvirtGroupState from Test.HostCondition.Linux, the diagnosis
    the host preflight already depends on. The module is imported on demand
    (-Global, never -Force, so a resident copy other callers hold is reused).
    A copy without the bounded -TimeoutSeconds parameter is not called at all:
    an unbounded group read would break the probe's own deadline.
#>
function Get-KvmLibvirtGroupEvidence {
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateRange(1, 60)][int]$TimeoutSeconds = 5)
    $command = Get-Command -Name 'Get-LibvirtGroupState' -CommandType Function -ErrorAction SilentlyContinue
    if (-not $command) {
        try {
            Import-Module (Join-Path $script:TestModulesDir 'Test.HostCondition.Linux.psm1') -Global -DisableNameChecking -ErrorAction Stop
        } catch {
            Write-Verbose "Get-KvmLibvirtGroupEvidence: Test.HostCondition.Linux did not load: $($_.Exception.Message)"
        }
        $command = Get-Command -Name 'Get-LibvirtGroupState' -CommandType Function -ErrorAction SilentlyContinue
    }
    if (-not $command -or -not $command.Parameters.ContainsKey('TimeoutSeconds')) { return 'not-probed' }
    $group = Get-LibvirtGroupState -TimeoutSeconds $TimeoutSeconds
    if (-not $group -or -not $group.Resolved) { return 'unknown' }
    if (@($group.ActiveGroups) -contains 'libvirt') { return 'active' }
    if ($group.CurrentUser -and @($group.LibvirtMembers) -contains [string]$group.CurrentUser) { return 'stale-session' }
    return 'not-member'
}

# The libvirt units the rung-2 detection reads, in one systemctl call. Both
# layouts are read every time so a host carrying both is recognized as mixed
# rather than silently treated as whichever one was asked about.
$script:KvmDaemonUnit = @(
    'libvirtd.service', 'libvirtd.socket', 'virtlogd.service', 'virtlogd.socket',
    'virtqemud.service', 'virtqemud.socket', 'virtnetworkd.service', 'virtnetworkd.socket'
)
# UnitFileState values under which a unit's own configuration starts it.
# Anything else -- disabled above all -- is an operator's choice (and the state
# Disable-TestAutomation.ps1 leaves behind) that a repair must not override.
$script:KvmUnitEnabledState = @('enabled', 'enabled-runtime', 'static', 'indirect', 'generated')
# The units each daemon layout's start recipe covers, in start order, with the
# activation sockets that make an idle service healthy. Only a qualified
# recipe is ever acted on; enabling the modular one is a change to this table
# together with evidence from a modular host.
$script:KvmDaemonRecipe = @{
    monolithic = [pscustomobject]@{
        Qualified      = $true
        StartOrder     = @('virtlogd.service', 'libvirtd.service')
        Socket         = @{ 'virtlogd.service' = @('virtlogd.socket'); 'libvirtd.service' = @('libvirtd.socket') }
        ControlService = 'libvirtd.service'
        ControlSocket  = 'libvirtd.socket'
    }
    modular = [pscustomobject]@{
        Qualified      = $false
        StartOrder     = @('virtlogd.service', 'virtqemud.service', 'virtnetworkd.service')
        Socket         = @{ 'virtlogd.service' = @('virtlogd.socket'); 'virtqemud.service' = @('virtqemud.socket'); 'virtnetworkd.service' = @('virtnetworkd.socket') }
        ControlService = 'virtqemud.service'
        ControlSocket  = 'virtqemud.socket'
    }
}

<#
.SYNOPSIS
    Read systemd's view of the named units in one bounded, read-only call.
.DESCRIPTION
    `systemctl show` prints one blank-line-separated block per unit, in the
    order the units were named, with values that are identifiers rather than
    translated prose. A unit systemd does not know still gets a block
    (LoadState=not-found), so a block count that differs from the unit count
    means the output was not what this parser understands.
.OUTPUTS
    [pscustomobject] @{ Resolved; Reason = ok|missing-client|timeout|
    invalid-response|unit-state-unknown; Units (hashtable by requested name of
    @{ Name; Id; LoadState; ActiveState; SubState; UnitFileState }); ExitCode }
#>
function Get-KvmDaemonUnitState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]]$Unit,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10
    )
    $units = @{}
    $emit = {
        param([bool]$Resolved, [string]$Reason, [int]$ExitCode)
        [pscustomobject]@{ Resolved = $Resolved; Reason = $Reason; Units = $units; ExitCode = $ExitCode }
    }
    $argumentList = @('show', '--no-pager', '-p', 'Id,LoadState,ActiveState,SubState,UnitFileState') + @($Unit)
    $result = Invoke-BoundedNativeCommand -FilePath 'systemctl' -ArgumentList $argumentList `
        -Environment @{ SYSTEMD_COLORS = '0'; SYSTEMD_PAGER = ''; LC_ALL = ''; LC_MESSAGES = 'C' } -TimeoutSeconds $TimeoutSeconds
    if (-not $result.Started) { return (& $emit $false 'missing-client' -1) }
    if ($result.TimedOut) { return (& $emit $false 'timeout' ([int]$result.ExitCode)) }
    if (-not (Test-DriverNativeResultComplete -Result $result)) { return (& $emit $false 'invalid-response' ([int]$result.ExitCode)) }
    if ($result.ExitCode -ne 0) { return (& $emit $false 'unit-state-unknown' ([int]$result.ExitCode)) }
    $blocks = @(([string]$result.StdOut).Trim() -split '\r?\n[ \t]*\r?\n' | Where-Object { $_.Trim() })
    if ($blocks.Count -ne @($Unit).Count) { return (& $emit $false 'invalid-response' 0) }
    for ($i = 0; $i -lt $blocks.Count; $i++) {
        $properties = @{}
        foreach ($line in ($blocks[$i] -split '\r?\n')) {
            $at = $line.IndexOf('=')
            if ($at -gt 0) { $properties[$line.Substring(0, $at).Trim()] = $line.Substring($at + 1).Trim() }
        }
        if (-not $properties.ContainsKey('LoadState') -or -not $properties.ContainsKey('ActiveState')) {
            $units.Clear()
            return (& $emit $false 'invalid-response' 0)
        }
        $units[[string]$Unit[$i]] = [pscustomobject]@{
            Name          = [string]$Unit[$i]
            Id            = [string]$properties['Id']
            LoadState     = [string]$properties['LoadState']
            ActiveState   = [string]$properties['ActiveState']
            SubState      = [string]$properties['SubState']
            UnitFileState = [string]$properties['UnitFileState']
        }
    }
    return (& $emit $true 'ok' 0)
}

<#
.SYNOPSIS
    Detect which libvirt daemon layout this host runs: monolithic (libvirtd),
    modular (virtqemud and friends), mixed, or unknown.
.DESCRIPTION
    A layout is in use when its control service is loaded with a
    UnitFileState its own configuration starts. Both in use is 'mixed', which
    no recipe may act on, since starting one layout's units while the other
    owns the sockets would fight over the same connection. When neither is in
    use but exactly one is installed (loaded or masked), that one is named, so
    the per-unit evaluation refuses its disabled or masked unit by name.
.OUTPUTS
    [pscustomobject] @{ Layout; Units; Resolved; Reason }
#>
function Get-KvmDaemonLayout {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([ValidateRange(1, 60)][int]$TimeoutSeconds = 10)
    $read = Get-KvmDaemonUnitState -Unit $script:KvmDaemonUnit -TimeoutSeconds $TimeoutSeconds
    if (-not $read.Resolved) {
        return [pscustomobject]@{ Layout = 'unknown'; Units = $read.Units; Resolved = $false; Reason = $read.Reason }
    }
    $testUnitEnabled = {
        param($UnitRecord)
        [bool]($UnitRecord -and $UnitRecord.LoadState -eq 'loaded' -and $script:KvmUnitEnabledState -contains $UnitRecord.UnitFileState)
    }
    $testUnitInstalled = {
        param($UnitRecord)
        [bool]($UnitRecord -and $UnitRecord.LoadState -in @('loaded', 'masked'))
    }
    $monolithic = & $testUnitEnabled $read.Units['libvirtd.service']
    $modular    = & $testUnitEnabled $read.Units['virtqemud.service']
    $layout = if ($monolithic -and $modular) { 'mixed' }
        elseif ($monolithic) { 'monolithic' }
        elseif ($modular) { 'modular' }
        else {
            # Neither control service is enabled. When exactly one layout is
            # installed at all, name it, so the per-unit evaluation reports the
            # operator's disabled or masked unit precisely instead of an
            # unknown layout; it refuses either way.
            $monolithicInstalled = & $testUnitInstalled $read.Units['libvirtd.service']
            $modularInstalled    = & $testUnitInstalled $read.Units['virtqemud.service']
            if ($monolithicInstalled -and -not $modularInstalled) { 'monolithic' }
            elseif ($modularInstalled -and -not $monolithicInstalled) { 'modular' }
            else { 'unknown' }
        }
    return [pscustomobject]@{ Layout = $layout; Units = $read.Units; Resolved = $true; Reason = 'ok' }
}

<#
.SYNOPSIS
    What rung 2 may do with one recipe unit: refuse, wait for it to settle, or
    treat it as running, socket-live or a start candidate.
.OUTPUTS
    [pscustomobject] @{ Kind = refuse|transitional|already-running|socket-live|candidate; Reason; Before }
#>
function Get-KvmUnitStartDisposition {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()]$Unit,
        [AllowNull()][AllowEmptyCollection()][object[]]$SocketUnit = @()
    )
    $emit = { param([string]$Kind, [string]$Reason, [string]$Before) [pscustomobject]@{ Kind = $Kind; Reason = $Reason; Before = $Before } }
    if ($null -eq $Unit) { return (& $emit 'refuse' 'unit-state-unknown' 'unknown') }
    $before = "$($Unit.ActiveState)/$($Unit.SubState)"
    if ($Unit.LoadState -ne 'loaded') {
        if ($Unit.LoadState -eq 'masked') { return (& $emit 'refuse' 'unit-masked' $before) }
        return (& $emit 'refuse' 'unit-state-unknown' $before)
    }
    if ($Unit.UnitFileState -in @('masked', 'masked-runtime')) { return (& $emit 'refuse' 'unit-masked' $before) }
    if ($script:KvmUnitEnabledState -notcontains $Unit.UnitFileState) { return (& $emit 'refuse' 'unit-disabled' $before) }
    switch ($Unit.ActiveState) {
        'failed' { return (& $emit 'refuse' 'unit-failed' $before) }
        'active' { return (& $emit 'already-running' 'already-running' $before) }
        { $_ -in @('activating', 'deactivating', 'reloading', 'refreshing', 'maintenance') } {
            return (& $emit 'transitional' 'unit-transitioning' $before)
        }
        'inactive' {
            if ($Unit.SubState -ne 'dead') { return (& $emit 'refuse' 'unit-state-unknown' $before) }
            foreach ($socket in @($SocketUnit)) {
                if ($socket -and $socket.LoadState -eq 'loaded' -and $socket.ActiveState -eq 'active') {
                    return (& $emit 'socket-live' 'socket-live' $before)
                }
            }
            return (& $emit 'candidate' 'started' $before)
        }
    }
    return (& $emit 'refuse' 'unit-state-unknown' $before)
}

<#
.SYNOPSIS
    Build one action row of a Yuruna.VirtualizationStartResult.
#>
function New-VirtualizationStartAction {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only; nothing on disk or in process state changes.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][ValidateSet('unit-start', 'service-start', 'network-start', 'wait', 'app-launch')][string]$Kind,
        [AllowEmptyString()][string]$Before = '',
        [AllowEmptyString()][string]$After = '',
        [Parameter(Mandatory)][ValidateSet('started', 'already-running', 'socket-live', 'refused', 'failed', 'unknown', 'skipped', 'preview')][string]$Result,
        [Parameter(Mandatory)][string]$Reason,
        [AllowEmptyCollection()][string[]]$Command = @(),
        [AllowNull()][Nullable[int]]$ExitCode = $null,
        [bool]$TimedOut = $false,
        [long]$ElapsedMs = 0
    )
    return (New-YurunaVirtualizationStartAction @PSBoundParameters)
}

<#
.SYNOPSIS
    Build a Yuruna.VirtualizationStartResult (schema version 1), deriving the
    outcome from the actions unless one is given.
.DESCRIPTION
    Derived precedence: any failed action -> failed; else any unknown ->
    unknown; else any started -> started; else any preview -> preview; else
    already-running. The reason is the first matching action's reason.
#>
function New-VirtualizationStartResult {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory record only; nothing on disk or in process state changes.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('started', 'already-running', 'refused', 'failed', 'unknown', 'unavailable', 'preview', '')][string]$Outcome = '',
        [AllowEmptyString()][string]$Reason = '',
        [Parameter(Mandatory)][string]$Layout,
        [AllowEmptyCollection()][object[]]$Action = @(),
        [Parameter(Mandatory)][string]$ObservedUtc,
        [long]$ElapsedMs
    )
    return (New-YurunaVirtualizationStartResult @PSBoundParameters -HostType (Resolve-HostTag))
}

<#
.SYNOPSIS
    Start libvirt's 'default' network when a dependent VM's persistent
    definition attaches to it and it is positively inactive; report every other
    required network without touching it.
.DESCRIPTION
    Emits one action row per decision. A network other than 'default' is never
    started: a bridge-backed network left stopped after a failed bridge build is
    a network-fabric repair, which this rung must not attempt. net-start needs
    no sudo; membership in the libvirt group is enough on qemu:///system.
#>
function Start-KvmDefaultNetworkIfRequired {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$DependentVMName,
        [Parameter(Mandatory)]$Deadline
    )
    $vmNames = @($DependentVMName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($vmNames.Count -eq 0) {
        New-VirtualizationStartAction -Target 'default' -Kind 'network-start' -Result 'skipped' -Reason 'network-not-required'
        return
    }
    $required = [System.Collections.Generic.SortedSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($vm in $vmNames) {
        $cap = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling 10
        if ($null -eq $cap) {
            New-VirtualizationStartAction -Target $vm -Kind 'network-start' -Result 'skipped' -Reason 'deadline-exhausted'
            continue
        }
        $list = Invoke-VirshBounded -VirshArgs @('domiflist', '--inactive', $vm) -TimeoutSeconds $cap
        if (-not (Test-DriverNativeResultComplete -Result $list) -or $list.ExitCode -ne 0) {
            New-VirtualizationStartAction -Target $vm -Kind 'network-start' -Result 'skipped' -Reason 'vm-unresolved' `
                -ExitCode ([int]$list.ExitCode) -TimedOut ([bool]$list.TimedOut) -ElapsedMs ([long]$list['ElapsedMs'])
            continue
        }
        foreach ($line in @(Get-BoundedNativeOutputLine -Result $list)) {
            $fields = @("$line".Trim() -split '\s+')
            if ($fields.Count -ge 3 -and $fields[1] -eq 'network') { [void]$required.Add([string]$fields[2]) }
        }
    }
    if ($required.Count -eq 0) {
        New-VirtualizationStartAction -Target 'default' -Kind 'network-start' -Result 'skipped' -Reason 'network-not-required'
        return
    }
    foreach ($network in $required) {
        $cap = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling 10
        if ($null -eq $cap) {
            New-VirtualizationStartAction -Target $network -Kind 'network-start' -Result 'skipped' -Reason 'deadline-exhausted'
            continue
        }
        $info = Invoke-VirshBounded -VirshArgs @('net-info', $network) -TimeoutSeconds $cap
        $before = Get-KvmNetworkActiveWord -Result $info
        if ($before -eq 'undefined') {
            New-VirtualizationStartAction -Target $network -Kind 'network-start' -Before 'undefined' -Result 'skipped' -Reason 'network-undefined'
            continue
        }
        if ($before -eq 'unknown') {
            New-VirtualizationStartAction -Target $network -Kind 'network-start' -Before 'unknown' -Result 'unknown' -Reason 'network-state-unknown' `
                -ExitCode ([int]$info.ExitCode) -TimedOut ([bool]$info.TimedOut)
            continue
        }
        if ($before -eq 'yes') {
            New-VirtualizationStartAction -Target $network -Kind 'network-start' -Before 'active' -After 'active' -Result 'already-running' -Reason 'already-running'
            continue
        }
        if ($network -ne 'default') {
            New-VirtualizationStartAction -Target $network -Kind 'network-start' -Before 'inactive' -Result 'skipped' -Reason 'network-not-default'
            continue
        }
        $command = @('virsh', '--connect', [string]$script:VirshUri, 'net-start', 'default')
        if (-not $PSCmdlet.ShouldProcess('default', (Format-YurunaOperatorMessage -Key 'host.kvm_start_network_action'))) {
            New-VirtualizationStartAction -Target 'default' -Kind 'network-start' -Before 'inactive' -Result 'preview' -Reason 'preview' -Command $command
            continue
        }
        $startCap = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling 30
        if ($null -eq $startCap) {
            New-VirtualizationStartAction -Target 'default' -Kind 'network-start' -Before 'inactive' -Result 'skipped' -Reason 'deadline-exhausted'
            continue
        }
        $start = Invoke-VirshBounded -VirshArgs @('net-start', 'default') -TimeoutSeconds $startCap
        $afterCap = Get-YurunaDeadlineBoundedSeconds -Deadline $Deadline -Ceiling 10
        $after = 'unknown'
        if ($null -ne $afterCap) { $after = Get-KvmNetworkActiveWord -Result (Invoke-VirshBounded -VirshArgs @('net-info', 'default') -TimeoutSeconds $afterCap) }
        $afterWord = switch ($after) { 'yes' { 'active' } 'no' { 'inactive' } default { [string]$after } }
        $common = @{ Target = 'default'; Kind = 'network-start'; Before = 'inactive'; After = $afterWord; Command = $command
            ExitCode = [int]$start.ExitCode; TimedOut = [bool]$start.TimedOut; ElapsedMs = [long]$start['ElapsedMs'] }
        if ($after -eq 'yes') { New-VirtualizationStartAction @common -Result 'started' -Reason 'started' }
        elseif ($start.TimedOut) { New-VirtualizationStartAction @common -Result 'unknown' -Reason 'start-timed-out' }
        elseif (-not $start.Started -or $start.ExitCode -ne 0) { New-VirtualizationStartAction @common -Result 'failed' -Reason 'start-failed' }
        else { New-VirtualizationStartAction @common -Result 'unknown' -Reason 'postcondition-unknown' }
    }
}

<#
.SYNOPSIS
    The 'Active:' word of a bounded `virsh net-info` result: yes, no,
    undefined (the network does not exist) or unknown.
#>
function Get-KvmNetworkActiveWord {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()][hashtable]$Result)
    if (-not (Test-DriverNativeResultComplete -Result $Result)) { return 'unknown' }
    if ($Result.ExitCode -ne 0) {
        $text = "$($Result.StdOut)`n$($Result.StdErr)"
        if ($text -match '(?i)network not found|no network with matching name') { return 'undefined' }
        return 'unknown'
    }
    foreach ($line in @(Get-BoundedNativeOutputLine -Result $Result)) {
        $m = [regex]::Match([string]$line, '^\s*Active:\s*(?<word>\S+)\s*$')
        if ($m.Success) {
            $word = $m.Groups['word'].Value.ToLowerInvariant()
            if ($word -in @('yes', 'no')) { return $word }
            return 'unknown'
        }
    }
    return 'unknown'
}

# --- REGION: Start-VirtualizationServiceIfStopped
function Start-VirtualizationServiceIfStopped {
    <#
    .SYNOPSIS
        Start the libvirt daemon units that this function positively observes as
        stopped, and the 'default' network a dependent VM needs; refuse on anything
        it cannot establish. Returns a Yuruna.VirtualizationStartResult.
    .DESCRIPTION
        Runs its own detection immediately before acting and never trusts an
        earlier probe: one bounded `systemctl show` of every libvirt unit decides
        the layout (monolithic, modular, mixed or unknown) and each unit's state.
        Only a qualified layout recipe is acted on; the modular recipe is declared
        but unqualified and returns 'unavailable/layout-unqualified'.

        Every recipe unit is evaluated before any is started, so a refusal changes
        nothing: a unit that is not loaded, masked, disabled (an operator's choice
        this must not override), failed, or still transitioning after a bounded
        settle wait refuses the whole rung. An active unit is already running; an
        inactive service behind an active activation socket is idle by design and
        is not started (socket-live). Only an inactive/dead unit with no live
        socket is started, in recipe order, with
        `sudo -n systemctl --no-ask-password start <unit>`, which fails at once
        rather than prompting. A sudo refusal on the first start refuses the rung
        and the action's command carries the exact vector a sudoers rule must
        allow. Each start is confirmed by a fresh unit read; a start whose outcome
        cannot be confirmed is reported as unknown, never as started.

        The 'default' network step runs only for -DependentVMName guests and only
        once the daemon is running; see Start-KvmDefaultNetworkIfRequired.

        -WhatIf runs only the bounded read-only detection (and, when the daemon is
        already up, the read-only network lookups) and reports the planned starts
        as 'preview'. Every native call is capped by the remaining time of
        min(TimeoutSeconds, -Deadline); with less than one second left nothing is
        launched. Never throws and never prompts.
    .PARAMETER TimeoutSeconds
        Upper bound for the whole call.
    .PARAMETER Deadline
        Optional shared deadline; the call never outlives it.
    .PARAMETER DependentVMName
        Guests whose restoration depends on this hypervisor; decides whether the
        'default' network is required.
    .OUTPUTS
        [pscustomobject] Yuruna.VirtualizationStartResult
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 120,
        [object]$Deadline,
        [AllowEmptyCollection()][string[]]$DependentVMName = @()
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $observedUtc = [DateTime]::UtcNow.ToString('o')
    $clock = if ($null -ne $Deadline -and $Deadline.ClockTicks) { $Deadline.ClockTicks } else { { [Environment]::TickCount64 } }
    $expiry = [long](& $clock) + [long]$TimeoutSeconds * 1000
    if ($null -ne $Deadline) { $expiry = [Math]::Min($expiry, [long]$Deadline.ExpiryTick) }
    $budget = New-YurunaDeadlineFromExpiry -ExpiryTick $expiry -ClockTicks $clock
    $actions = [System.Collections.Generic.List[object]]::new()
    $finish = {
        param([string]$Outcome, [string]$Reason, [string]$Layout)
        New-VirtualizationStartResult -Outcome $Outcome -Reason $Reason -Layout $Layout -Action $actions.ToArray() `
            -ObservedUtc $observedUtc -ElapsedMs $stopwatch.ElapsedMilliseconds
    }

    $layout = 'unknown'
    $mutated = $false
    try {
        $cap = Get-YurunaDeadlineBoundedSeconds -Deadline $budget -Ceiling 10
        if ($null -eq $cap) { return (& $finish 'refused' 'deadline-exhausted' 'unknown') }
        $detected = Get-KvmDaemonLayout -TimeoutSeconds $cap
        if (-not $detected.Resolved) {
            $refusal = if ($detected.Reason -eq 'missing-client') { 'missing-client' } else { 'unit-state-unknown' }
            return (& $finish 'refused' $refusal 'unknown')
        }
        $layout = [string]$detected.Layout
        if ($layout -eq 'mixed') { return (& $finish 'refused' 'layout-ambiguous' $layout) }
        if (-not $script:KvmDaemonRecipe.ContainsKey($layout)) { return (& $finish 'refused' 'unit-state-unknown' $layout) }
        $recipe = $script:KvmDaemonRecipe[$layout]
        if (-not $recipe.Qualified) { return (& $finish 'unavailable' 'layout-unqualified' $layout) }

        # Evaluate every unit before acting; wait boundedly for transitional ones.
        $units = $detected.Units
        $settle = $null
        while ($true) {
            $dispositions = [ordered]@{}
            foreach ($unitName in $recipe.StartOrder) {
                $sockets = @(@($recipe.Socket[$unitName]) | ForEach-Object { $units[$_] })
                $dispositions[$unitName] = Get-KvmUnitStartDisposition -Unit $units[$unitName] -SocketUnit $sockets
            }
            $refusedUnit = @($dispositions.Keys | Where-Object { $dispositions[$_].Kind -eq 'refuse' }) | Select-Object -First 1
            if ($refusedUnit) {
                $row = $dispositions[$refusedUnit]
                $actions.Add((New-VirtualizationStartAction -Target $refusedUnit -Kind 'unit-start' -Before $row.Before -After $row.Before -Result 'refused' -Reason $row.Reason))
                return (& $finish 'refused' $row.Reason $layout)
            }
            $transitional = @($dispositions.Keys | Where-Object { $dispositions[$_].Kind -eq 'transitional' })
            if ($transitional.Count -eq 0) { break }
            if ($null -eq $settle) {
                $settle = New-YurunaDeadlineFromExpiry -ExpiryTick ([Math]::Min([long](& $clock) + 15000, $budget.ExpiryTick)) -ClockTicks $clock
            }
            $remaining = Get-YurunaDeadlineRemainingMs -Deadline $settle
            $readCap = $null
            if ($remaining -gt 0) {
                Start-Sleep -Milliseconds ([int][Math]::Min(1000, $remaining))
                $readCap = Get-YurunaDeadlineBoundedSeconds -Deadline $settle -Ceiling 5
            }
            if ($null -eq $readCap) {
                foreach ($unitName in $transitional) {
                    $actions.Add((New-VirtualizationStartAction -Target $unitName -Kind 'wait' -Before $dispositions[$unitName].Before -After $dispositions[$unitName].Before -Result 'refused' -Reason 'unit-transitioning'))
                }
                return (& $finish 'refused' 'unit-transitioning' $layout)
            }
            $reread = Get-KvmDaemonUnitState -Unit $script:KvmDaemonUnit -TimeoutSeconds $readCap
            if (-not $reread.Resolved) { return (& $finish 'refused' 'unit-state-unknown' $layout) }
            $units = $reread.Units
        }

        $candidates = [System.Collections.Generic.List[string]]::new()
        foreach ($unitName in $dispositions.Keys) {
            $row = $dispositions[$unitName]
            if ($row.Kind -eq 'candidate') { [void]$candidates.Add($unitName); continue }
            $actions.Add((New-VirtualizationStartAction -Target $unitName -Kind 'unit-start' -Before $row.Before -After $row.Before -Result $row.Kind -Reason $row.Reason))
        }

        $mutated = $false
        $halted = $false
        foreach ($unitName in $candidates) {
            $before = $dispositions[$unitName].Before
            $command = @('systemctl', '--no-ask-password', 'start', $unitName)
            if ($halted) {
                $actions.Add((New-VirtualizationStartAction -Target $unitName -Kind 'unit-start' -Before $before -Result 'skipped' -Reason 'start-failed' -Command $command))
                continue
            }
            $startCap = Get-YurunaDeadlineBoundedSeconds -Deadline $budget -Ceiling 60
            if ($null -eq $startCap) {
                if (-not $mutated) { return (& $finish 'refused' 'deadline-exhausted' $layout) }
                $actions.Add((New-VirtualizationStartAction -Target $unitName -Kind 'unit-start' -Before $before -Result 'unknown' -Reason 'deadline-exhausted' -Command $command))
                $halted = $true
                continue
            }
            if (-not $PSCmdlet.ShouldProcess($unitName, (Format-YurunaOperatorMessage -Key 'host.kvm_start_unit_action'))) {
                $actions.Add((New-VirtualizationStartAction -Target $unitName -Kind 'unit-start' -Before $before -Result 'preview' -Reason 'preview' -Command $command))
                continue
            }
            $start = Invoke-BoundedNativeCommand -FilePath 'sudo' -ArgumentList (@('-n') + $command) `
                -Environment @{ SYSTEMD_COLORS = '0' } -TimeoutSeconds $startCap
            $common = @{ Target = $unitName; Kind = 'unit-start'; Before = $before; Command = $command
                ExitCode = [int]$start.ExitCode; TimedOut = [bool]$start.TimedOut; ElapsedMs = [long]$start['ElapsedMs'] }
            if (-not $start.Started) {
                $actions.Add((New-VirtualizationStartAction @common -Result ($mutated ? 'failed' : 'refused') -Reason 'missing-client'))
                if (-not $mutated) { return (& $finish 'refused' 'missing-client' $layout) }
                $halted = $true
                continue
            }
            if (-not $start.TimedOut -and $start.ExitCode -ne 0 -and (Test-YurunaSudoRefusal -Output "$($start.StdOut)`n$($start.StdErr)")) {
                $actions.Add((New-VirtualizationStartAction @common -Result ($mutated ? 'failed' : 'refused') -Reason 'elevation-refused'))
                if (-not $mutated) { return (& $finish 'refused' 'elevation-refused' $layout) }
                $halted = $true
                continue
            }
            $mutated = $true
            $after = 'unknown'
            $isActive = $false
            $postCap = Get-YurunaDeadlineBoundedSeconds -Deadline $budget -Ceiling 5
            if ($null -ne $postCap) {
                $post = Get-KvmDaemonUnitState -Unit @($unitName) -TimeoutSeconds $postCap
                if ($post.Resolved -and $post.Units[$unitName]) {
                    $after = "$($post.Units[$unitName].ActiveState)/$($post.Units[$unitName].SubState)"
                    $isActive = ($post.Units[$unitName].ActiveState -eq 'active')
                }
            }
            if ($isActive) {
                $actions.Add((New-VirtualizationStartAction @common -After $after -Result 'started' -Reason 'started'))
                continue
            }
            $halted = $true
            if ($start.TimedOut) { $actions.Add((New-VirtualizationStartAction @common -After $after -Result 'unknown' -Reason 'start-timed-out')) }
            elseif ($start.ExitCode -ne 0) { $actions.Add((New-VirtualizationStartAction @common -After $after -Result 'failed' -Reason 'start-failed')) }
            else { $actions.Add((New-VirtualizationStartAction @common -After $after -Result 'unknown' -Reason 'postcondition-unknown')) }
        }

        $daemonRows = @($actions.ToArray())
        $daemonReachable = -not (@($daemonRows | Where-Object { $_.result -in @('failed', 'unknown', 'preview', 'refused', 'skipped') }).Count -gt 0)
        if ($daemonReachable) {
            foreach ($row in @(Start-KvmDefaultNetworkIfRequired -DependentVMName @($DependentVMName) -Deadline $budget)) { $actions.Add($row) }
        }
        return (& $finish '' '' $layout)
    } catch {
        # Never throw: under a caller's ErrorActionPreference of Stop any
        # non-terminating error is a throw. After a start was attempted its
        # outcome is unknown until a fresh probe; before, nothing changed.
        Write-Verbose "Start-VirtualizationServiceIfStopped: $($_.Exception.Message)"
        if ($mutated) { return (& $finish 'unknown' 'postcondition-unknown' $layout) }
        return (& $finish 'refused' 'unit-state-unknown' $layout)
    }
}
