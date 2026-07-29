<#PSScriptInfo
.VERSION 2026.07.29
.GUID 42b8c9d0-e1f2-4a34-9567-8f9a0b1c2d31
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host
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

# Cross-platform host-condition facade -- registry-backed dispatcher.
# Per-platform implementations live in Test.HostCondition.{Mac,Windows,
# Linux}.psm1; each contributes a (Set, Assert, AssertMinimum,
# RequiresElevation) record keyed by HostType.
#
# Architecture (facade contract, registry shape, capability matrix):
# https://yuruna.link/test/harness

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'Registry anchor; required to survive -Force re-imports of this facade.')]
param()

Import-Module (Join-Path $PSScriptRoot 'Test.Registry.psm1') -Force -DisableNameChecking -Global

# Backing store is a New-YurunaRegistry bundle anchored under
# $global:YurunaHostConditionProviders so the registrations survive
# -Force re-imports of this facade. Each entry is an [ordered]@{
#   HostType; Set; Assert; AssertMinimum; RequiresElevation
# } record.
$script:HostConditionRegistry = New-YurunaRegistry `
    -Name 'HostCondition' `
    -AnchorVar 'YurunaHostConditionProviders' `
    -Comparer 'OrdinalIgnoreCase'

function Register-HostConditionProvider {
    <#
    .SYNOPSIS
        Bind a (Set, Assert, AssertMinimum, RequiresElevation) record
        to $HostType in the host-condition registry.
    .PARAMETER HostType
        Stable host identifier ('host.windows.hyper-v', 'host.macos.utm',
        'host.ubuntu.kvm', or a future plugin's identifier).
    .PARAMETER Set
        Scriptblock invoked by the operator-facing Enable-TestAutomation
        path. Signature: `param([string]$HostType)`. May mutate host
        state; should honor -WhatIf via its own ShouldProcess.
    .PARAMETER Assert
        Scriptblock invoked by Assert-HostConditionSet at runtime.
        Signature: `param([string]$HostType)`. Must return [bool]
        and emit Write-Warning / Write-Error for any failed condition.
    .PARAMETER AssertMinimum
        Scriptblock invoked by Test-HostRequirement for one-off
        operator helpers (Remove-TestVMFiles.ps1 etc.). Lighter than
        Assert -- the screen-lock / TCC checks belong in Assert, not
        here, because they false-positive during interactive
        maintenance. Signature: `param()`. Returns [bool].
    .PARAMETER RequiresElevation
        Set $true when the host needs Administrator / root for the
        runtime cycle (Hyper-V cmdlets fail with permission denied
        otherwise). Test-ElevationRequired reads this.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Parameters are stored in the registry, not used by this function body.')]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][scriptblock]$Set,
        [Parameter(Mandatory)][scriptblock]$Assert,
        [Parameter(Mandatory)][scriptblock]$AssertMinimum,
        [bool]$RequiresElevation = $false,
        # Optional per-cycle display-surface ensure (e.g. attach a virtual
        # monitor on a headless Hyper-V host so screen-capture/OCR keeps
        # working). Signature: `param()`, returns a status string. $null
        # for hosts that need nothing (macOS/Linux). Invoked by
        # Initialize-HostDisplay; see docs/host-hyperv.md.
        [scriptblock]$Display = $null,
        # Optional inverse of $Display: tear the surface down when the host
        # stops running tests (e.g. disable the virtual display so a stale
        # one doesn't hang around). Signature: `param()`, returns a status
        # string. $null for hosts that need nothing. Invoked by
        # Remove-HostDisplay from Remove-TestVMFiles.
        [scriptblock]$DisplayTeardown = $null,
        # Optional "put this host's clock back under NTP discipline".
        # Signature: `param()`, returns @{ Succeeded; Message }. Invoked by
        # Sync-HostClock from the operator-facing paths only (Test-Config's
        # offer, Enable-TestAutomation) -- it needs privileges an unattended
        # cycle cannot obtain. $null for a host with no way to discipline
        # its own clock.
        [scriptblock]$ClockSync = $null
    )
    & $script:HostConditionRegistry.Register $HostType ([ordered]@{
        HostType          = $HostType
        Set               = $Set
        Assert            = $Assert
        AssertMinimum     = $AssertMinimum
        RequiresElevation = $RequiresElevation
        Display           = $Display
        DisplayTeardown   = $DisplayTeardown
        ClockSync         = $ClockSync
    })
}

function Get-HostClockSkew {
    <#
    .SYNOPSIS
        Signed seconds between this host's clock and real time (positive =
        host ahead), or $null when no time server answers.

    .DESCRIPTION
        Every hypervisor here seeds a guest's virtual clock from the host
        at power-on, so a host that has drifted starts every VM equally
        wrong -- and the guest's own NTP client steps it to real time
        seconds into the boot. That step lands in the middle of whatever
        the guest is bringing up. On a Kubernetes guest it leaves the
        control plane and part of the workload Running but never Ready,
        their status timestamps sitting in the future; Services lose every
        endpoint and each NodePort refuses, while a curl straight at the
        pod IP still answers 200. Nothing in that picture points back at a
        clock, which is why the host clock is worth measuring up front
        rather than reconstructing afterwards.

        Speaks NTP directly over UDP rather than shelling out to the
        platform's time client: on a drifting host that client is usually
        the thing that is broken or absent, its output is localized, and
        its timeouts are not ours to choose. One socket answers the same
        question identically on all three hosts.

        Returns $null -- never 0 -- when nothing answers, so an isolated
        lab reads as "unmeasured" and callers can skip rather than mistake
        an unreachable network for a disciplined clock.

    .PARAMETER TimeServer
        Servers to try in order; the first that answers wins.

    .PARAMETER Port
        NTP port. Exposed so the epoch/endianness arithmetic can be
        verified against a local responder instead of the public clock.

    .PARAMETER TimeoutMilliseconds
        Per-server send/receive timeout.

    .OUTPUTS
        [double] signed seconds, or $null when unmeasured.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [string[]]$TimeServer = @('time.cloudflare.com', 'pool.ntp.org', 'time.windows.com'),
        [int]$Port = 123,
        [int]$TimeoutMilliseconds = 3000
    )

    $ntpEpoch = [datetime]::new(1900, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    foreach ($server in $TimeServer) {
        $client = $null
        try {
            $client = [System.Net.Sockets.UdpClient]::new()
            $client.Client.ReceiveTimeout = $TimeoutMilliseconds
            $client.Client.SendTimeout    = $TimeoutMilliseconds
            $client.Connect($server, $Port)
            # 0x1B: leap indicator 0, version 3, mode 3 (client). Every
            # other byte of the request stays zero.
            $request = [byte[]]::new(48)
            $request[0] = 0x1B
            $sentAt = [datetime]::UtcNow
            [void]$client.Send($request, $request.Length)
            $remote   = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $response = $client.Receive([ref]$remote)
            $heardAt  = [datetime]::UtcNow
            if ($response.Length -lt 48) { continue }
            # Transmit timestamp: bytes 40-47, big-endian seconds + binary
            # fraction since 1900. The slices run backwards because
            # BitConverter reads little-endian.
            $seconds  = [System.BitConverter]::ToUInt32($response[43..40], 0)
            $fraction = [System.BitConverter]::ToUInt32($response[47..44], 0)
            if ($seconds -eq 0) { continue }
            $reference = $ntpEpoch.AddSeconds($seconds).AddSeconds($fraction / 4294967296.0)
            # The server's timestamp describes an instant in the middle of
            # the exchange, so compare it against the middle of ours --
            # otherwise the whole round trip is charged to the host as skew.
            $localAtReference = $sentAt.AddTicks((($heardAt - $sentAt).Ticks / 2))
            return [double]($localAtReference - $reference).TotalSeconds
        } catch {
            Write-Verbose "Host clock: no answer from '$server' ($($_.Exception.Message))."
        } finally {
            if ($client) { $client.Dispose() }
        }
    }
    return $null
}

# How far a host clock may sit from real time before it is worth reporting.
# An NTP-disciplined host holds milliseconds, so this is not a precision
# budget -- it is the line between "disciplined" and "nothing is correcting
# this clock", well clear of the seconds-scale wander of a host that syncs
# but syncs rarely.
$script:YurunaMaxHostClockSkewSeconds = 120

function Get-HostClockSkewLimit {
    <#
    .SYNOPSIS
        The skew, in seconds, past which a host clock is reported as drifted.
    .DESCRIPTION
        Exposed so a second reporting caller (Test-Config) states the same
        number instead of carrying its own copy of it.
    .OUTPUTS
        [int]
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    return $script:YurunaMaxHostClockSkewSeconds
}

# One clock measurement per process. A fresh process runs each cycle
# (the per-cycle child, then the inner it spawns), so once-per-process is
# once-per-cycle -- and the platform Assert that calls this runs more than
# once inside a single inner run. Without the memo the operator reads the
# same paragraph twice a cycle and pays a second NTP round trip for it.
$script:HostClockReported = $false

function Write-HostClockDriftWarning {
    <#
    .SYNOPSIS
        Measure this host's clock once per process and warn -- once -- when
        it has drifted past $MaxSkewSeconds. Returns nothing.

    .DESCRIPTION
        Shared by every platform's Assert-*HostConditionSet: the fault is
        the same everywhere (guests inherit the host clock at power-on and
        get stepped to real time mid-boot), so the threshold and the
        wording are held in one place rather than drifting between three.

        Warn-only, deliberately. Correcting a clock needs privileges an
        unattended runner does not hold and cannot ask for -- so a drifted
        host that refused its own cycles would sit refusing them until an
        operator noticed, trading a degraded cycle for no cycle at all. The
        repair is offered where someone is present to authorize it:
        test/Test-Config.ps1 and the per-host Enable-TestAutomation.ps1.

        An unmeasurable clock says nothing. A lab with no route to a time
        server is a normal deployment, not a fault to report every cycle.

    .OUTPUTS
        None.
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$HostType,
        [int]$MaxSkewSeconds = $script:YurunaMaxHostClockSkewSeconds
    )

    if ($script:HostClockReported) { return }
    $script:HostClockReported = $true

    $skew = Get-HostClockSkew
    if ($null -eq $skew) {
        Write-Verbose "Host clock: no time server answered; skew left unchecked."
        return
    }
    if ([math]::Abs($skew) -le $MaxSkewSeconds) {
        Write-Verbose "Host clock: $([math]::Round($skew, 1))s from real time (limit ${MaxSkewSeconds}s)."
        return
    }

    $offBy     = [math]::Round([math]::Abs($skew), 1)
    $direction = if ($skew -gt 0) { 'ahead of' } else { 'behind' }
    $hostFolder = ($HostType -replace '^host\.', '')
    Write-Warning "==================================================================="
    Write-Warning " Host clock is ${offBy}s $direction real time (limit: ${MaxSkewSeconds}s)."
    Write-Warning " Guests take this clock from their virtual RTC at power-on, and"
    Write-Warning " their own NTP client steps them to real time seconds into the"
    Write-Warning " boot. That step lands mid-startup: a Kubernetes guest comes up"
    Write-Warning " with its pods Running but never Ready and every NodePort"
    Write-Warning " refusing, hours before anything blames a clock."
    Write-Warning ""
    Write-Warning " This cycle continues. Fix the clock from a console that can"
    Write-Warning " answer for Administrator / sudo -- run from the repo root:"
    Write-Warning "   pwsh test/Test-Config.ps1"
    Write-Warning "   pwsh host/$hostFolder/Enable-TestAutomation.ps1"
    Write-Warning "==================================================================="
}

function Reset-HostClockReport {
    <#
    .SYNOPSIS
        Re-arm the once-per-process clock report.
    .DESCRIPTION
        Tests-only: production processes are per-cycle, so the memo is
        never re-armed in a live run.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('host clock report', 'Re-arm')) {
        $script:HostClockReported = $false
    }
}

function Sync-HostClock {
    <#
    .SYNOPSIS
        Platform dispatcher: put the host clock back under NTP discipline.
        Returns @{ Attempted; Succeeded; Message }.

    .DESCRIPTION
        Best-effort by contract. A host clock is fixed with privileged
        calls that can fail for reasons the caller cannot resolve (no
        elevation, a managed time service, an air-gapped network), so this
        never throws and reports what happened instead.

        Operator-facing only: the privileged calls underneath need an
        Administrator shell or a sudo credential the caller must be able to
        obtain, which an unattended runner cannot. Callers are
        test/Test-Config.ps1 (which asks first, and primes the sudo cache
        so the answer is honored) and the per-host Enable-TestAutomation.ps1.
        A running cycle only warns -- see Write-HostClockDriftWarning.

        No guest may be running. Correcting a drifted host steps its clock,
        and a step while guests are up is the very fault this exists to
        prevent -- guests take their time from the host.

    .OUTPUTS
        [hashtable] Attempted (bool), Succeeded (bool), Message (string).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([string]$HostType)

    $provider = Get-HostConditionProvider -HostType $HostType
    if (-not $provider -or -not $provider.ClockSync) {
        return @{ Attempted = $false; Succeeded = $false; Message = "No clock-sync capability registered for '$HostType'." }
    }
    if (-not $PSCmdlet.ShouldProcess("$HostType clock", 'Resynchronize against NTP')) {
        return @{ Attempted = $false; Succeeded = $false; Message = 'Skipped (WhatIf).' }
    }
    try {
        $result = & $provider.ClockSync
        if ($result -isnot [System.Collections.IDictionary]) {
            return @{ Attempted = $true; Succeeded = $false; Message = "Clock sync for '$HostType' returned no status record." }
        }
        return @{
            Attempted = $true
            Succeeded = [bool]$result.Succeeded
            Message   = [string]$result.Message
        }
    } catch {
        return @{ Attempted = $true; Succeeded = $false; Message = $_.Exception.Message }
    }
}

function Get-HostConditionProvider {
    <#
    .SYNOPSIS
        Look up the provider record for $HostType. Returns the record
        or $null when no provider is registered.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$HostType)
    return (& $script:HostConditionRegistry.Get $HostType)
}

function Get-HostConditionProviderMatrix {
    <#
    .SYNOPSIS
        Snapshot of every registered provider keyed by HostType. Used by
        the startup capability matrix to render coverage.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    return (& $script:HostConditionRegistry.GetMatrix)
}

function Clear-HostConditionProvider {
    <#
    .SYNOPSIS
        Drop every registered host-condition provider.
    .DESCRIPTION
        Tests-only: production code relies on -Force re-import to
        refresh registrations.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if ($PSCmdlet.ShouldProcess('Test.HostCondition registry', 'Clear all providers')) {
        & $script:HostConditionRegistry.Clear
    }
}

# Per-platform siblings. -Global so their exports stay reachable to
# callers that imported only this facade. Import order is immaterial:
# self-registration (Register-IfAvailable, below) resolves each
# platform's functions from the already-populated global session after
# all three siblings have loaded, so no sibling depends on another
# being imported first.
Import-Module (Join-Path $PSScriptRoot 'Test.HostCondition.Mac.psm1')     -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.HostCondition.Windows.psm1') -Global -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot 'Test.HostCondition.Linux.psm1')   -Global -Force -DisableNameChecking

# Self-register each platform by looking up its functions in the global
# session. Missing functions (a stripped-down install where one
# platform module was deleted) cause Register-IfAvailable to skip
# silently; the dispatcher then surfaces an "Unknown host type"
# warning rather than failing on a torn registration.
function script:Register-IfAvailable {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Helper drives Register-HostConditionProvider; the wrapper carries ShouldProcess-equivalent intent at module load.')]
    param(
        [Parameter(Mandatory)][string]$HostType,
        [Parameter(Mandatory)][string]$SetFn,
        [Parameter(Mandatory)][string]$AssertFn,
        [Parameter(Mandatory)][string]$MinimumFn,
        [bool]$RequiresElevation,
        # Optional: name of a per-cycle display-surface ensure function.
        # Resolved only when present; absent on hosts that need nothing.
        [string]$DisplayFn,
        # Optional: name of the inverse teardown function for the display
        # surface. Resolved only when present; absent on hosts that need nothing.
        [string]$TeardownFn,
        # Optional: name of this platform's clock-discipline function.
        # Resolved only when present.
        [string]$ClockSyncFn
    )
    $missing = @()
    foreach ($fn in @($SetFn, $AssertFn, $MinimumFn)) {
        if (-not (Get-Command -Name $fn -ErrorAction SilentlyContinue)) { $missing += $fn }
    }
    if ($missing.Count -gt 0) {
        # Write-Warning (not Write-Verbose) so a torn registration -- a known HostType whose
        # provider module half-loaded -- is visible at default verbosity instead of silently
        # skipped (which later surfaces only as "unknown host type, skipping checks" and passes).
        Write-Warning "Test.HostCondition: skipping $HostType registration; missing functions: $($missing -join ', ')"
        return
    }
    $displayBlock = $null
    if ($DisplayFn) {
        $displayCmd = Get-Command -Name $DisplayFn -ErrorAction SilentlyContinue
        if ($displayCmd) { $displayBlock = $displayCmd.ScriptBlock }
        else { Write-Verbose "Test.HostCondition: $HostType display ensure '$DisplayFn' not found; skipping that capability." }
    }
    $teardownBlock = $null
    if ($TeardownFn) {
        $teardownCmd = Get-Command -Name $TeardownFn -ErrorAction SilentlyContinue
        if ($teardownCmd) { $teardownBlock = $teardownCmd.ScriptBlock }
        else { Write-Verbose "Test.HostCondition: $HostType display teardown '$TeardownFn' not found; skipping that capability." }
    }
    $clockBlock = $null
    if ($ClockSyncFn) {
        $clockCmd = Get-Command -Name $ClockSyncFn -ErrorAction SilentlyContinue
        if ($clockCmd) { $clockBlock = $clockCmd.ScriptBlock }
        else { Write-Verbose "Test.HostCondition: $HostType clock sync '$ClockSyncFn' not found; skipping that capability." }
    }
    Register-HostConditionProvider -HostType $HostType `
        -Set             (Get-Command $SetFn).ScriptBlock `
        -Assert          (Get-Command $AssertFn).ScriptBlock `
        -AssertMinimum   (Get-Command $MinimumFn).ScriptBlock `
        -RequiresElevation $RequiresElevation `
        -Display         $displayBlock `
        -DisplayTeardown $teardownBlock `
        -ClockSync       $clockBlock
}
Register-IfAvailable -HostType 'host.windows.hyper-v' `
    -SetFn 'Set-WindowsHostConditionSet' -AssertFn 'Assert-WindowsHostConditionSet' -MinimumFn 'Test-WindowsHostMinimum' `
    -DisplayFn 'Install-YurunaVirtualDisplay' -TeardownFn 'Remove-YurunaVirtualDisplay' `
    -ClockSyncFn 'Sync-WindowsHostClock' `
    -RequiresElevation $true
Register-IfAvailable -HostType 'host.macos.utm' `
    -SetFn 'Set-MacHostConditionSet'     -AssertFn 'Assert-MacHostConditionSet'     -MinimumFn 'Test-MacHostMinimum' `
    -ClockSyncFn 'Sync-MacHostClock' `
    -RequiresElevation $false
Register-IfAvailable -HostType 'host.ubuntu.kvm' `
    -SetFn 'Set-LinuxHostConditionSet'   -AssertFn 'Assert-LinuxHostConditionSet'   -MinimumFn 'Test-LinuxHostMinimum' `
    -ClockSyncFn 'Sync-LinuxHostClock' `
    -RequiresElevation $false

function Assert-HostConditionSet {
    <#
    .SYNOPSIS
        Platform dispatcher: looks up the registered Assert callback
        for $HostType and invokes it. Returns $true when no provider
        is registered (operator can run on an unknown host without a
        hard failure; the runner's per-step gates still apply).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$HostType)
    $provider = Get-HostConditionProvider -HostType $HostType
    if (-not $provider) {
        Write-Warning "Unknown host type '$HostType' -- skipping condition checks."
        return $true
    }
    return [bool](& $provider.Assert -HostType $HostType)
}

function Initialize-HostDisplay {
    <#
    .SYNOPSIS
        Platform dispatcher: ensure the host has a usable display surface for
        screen-capture / OCR before a cycle (e.g. attach a virtual display on
        a headless Hyper-V host so DWM keeps painting the synthetic GPU).
    .DESCRIPTION
        Idempotent and cheap to call every cycle: the underlying ensure
        short-circuits when the surface is already present. No-op when the
        provider registers no Display callback (macOS/Linux, or an unknown
        host). Never throws -- a display-ensure failure must not abort the
        cycle; it degrades to the manual-workaround path (see
        docs/host-hyperv.md) and is surfaced as a warning.
    #>
    [CmdletBinding()]
    param([string]$HostType)
    $provider = Get-HostConditionProvider -HostType $HostType
    if (-not $provider -or -not $provider.Display) { return }
    try {
        $status = & $provider.Display
        switch ("$status") {
            'Activated'     { Write-Information "Virtual display attached for '$HostType' -- screen-capture is decoupled from the physical monitor." }
            'AlreadyActive' { Write-Verbose "Virtual display already active for '$HostType'." }
            'Failed'        { Write-Warning "Could not ensure a virtual display for '$HostType'; headless screen-capture/OCR may fail. See docs/host-hyperv.md." }
            'Disabled'      { Write-Verbose "Virtual display disabled for '$HostType' (YURUNA_VIRTUAL_DISPLAY not set to true)." }
            default         { Write-Verbose "Initialize-HostDisplay ('$HostType'): $status" }
        }
    } catch {
        Write-Warning "Initialize-HostDisplay ('$HostType') failed: $($_.Exception.Message)"
    }
}

function Remove-HostDisplay {
    <#
    .SYNOPSIS
        Platform dispatcher and inverse of Initialize-HostDisplay: tear down the
        display surface a machine no longer needs once it stops running tests
        (e.g. disable the usbmmidd virtual display on a Hyper-V host so a
        stale/duplicate monitor left by a mid-cycle KVM switch does not linger).
    .DESCRIPTION
        Idempotent and safe to call even when no surface was ever attached: the
        underlying teardown short-circuits when the driver was never staged or no
        virtual display is present. No-op when the provider registers no
        DisplayTeardown callback (macOS/Linux, or an unknown host). Never throws
        -- a teardown failure during cleanup must not abort the caller; it
        degrades to a warning. Invoked by Remove-TestVMFiles.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$HostType)
    $provider = Get-HostConditionProvider -HostType $HostType
    if (-not $provider -or -not $provider.DisplayTeardown) { return }
    if (-not $PSCmdlet.ShouldProcess("$HostType display surface", 'Tear down virtual display')) { return }
    try {
        $status = & $provider.DisplayTeardown
        switch ("$status") {
            'Removed'       { Write-Information "Virtual display removed for '$HostType'." }
            'AlreadyAbsent' { Write-Verbose "No virtual display to remove for '$HostType'." }
            'Failed'        { Write-Warning "Could not fully remove the virtual display for '$HostType'. See docs/host-hyperv.md." }
            default         { Write-Verbose "Remove-HostDisplay ('$HostType'): $status" }
        }
    } catch {
        Write-Warning "Remove-HostDisplay ('$HostType') failed: $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function `
    Register-HostConditionProvider, Get-HostConditionProvider, Get-HostConditionProviderMatrix, Clear-HostConditionProvider, `
    Assert-HostConditionSet, Initialize-HostDisplay, Remove-HostDisplay, `
    Get-HostClockSkew, Get-HostClockSkewLimit, Write-HostClockDriftWarning, Reset-HostClockReport, Sync-HostClock, `
    Assert-ScreenLock, Initialize-SudoCache, `
    Set-MacHostConditionSet, Assert-Accessibility, Assert-ScreenRecording, Assert-MacHostConditionSet, Test-MacHostMinimum, Sync-MacHostClock, `
    Set-WindowsHostConditionSet, Assert-WindowsHostConditionSet, Test-WindowsHostMinimum, Sync-WindowsHostClock, `
    Set-LinuxHostConditionSet, Assert-LinuxHostConditionSet, Test-LinuxHostMinimum, Sync-LinuxHostClock
