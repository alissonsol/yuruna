<#PSScriptInfo
.VERSION 2026.08.20
.GUID 42d5663b-af64-472f-8342-ab50456c2fc4
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host address dhcp beacon pool
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
    Keep the pool directory's idea of this host's address true, and keep the
    host's own address records from going stale behind it.

.DESCRIPTION
    The guest-side resolver (automation/yuruna-host-locate.sh and its Windows
    peer) can only be as right as the directory it asks. That directory --
    the pool aggregator on the caching-proxy machine -- discovers hosts by
    tailing the squid access log, which is PULL-only and therefore lags
    exactly when it matters: a host appears in the log when it or its guests
    pull through the proxy, so between cycles the view ages out and the
    recorded address is the one the host has just left.

    This module is the push half. On each tick it asks what address this host
    currently answers on, and when that has changed it:

      * rewrites runtime/ipaddresses.txt, which is otherwise written once at
        status-service start and is wrong from the first renewal onward;
      * announces to the aggregator, whose confirm probe re-reads this host's
        status.json and matches the hostId before moving the row;
      * generates one request through squid, so the log-tail path sees the
        new address too.

    Two paths on purpose, and the cheap one is the redundant one. The
    announce is deterministic and immediate; the nudge costs a single request
    and depends on none of the new code, so a lab whose aggregator predates
    the announce route still converges within one poll.

    Everything here is best-effort in the strict sense the pool-storage rules
    use: a wedged or absent proxy must never throw into the cycle, never
    block it, and never turn a passing run into a failing one. The worst
    outcome of a total failure is the behavior that exists today.
#>

Set-StrictMode -Version Latest

# Wall-clock caps, seconds. Backstops for an unreachable proxy, not
# normal-path budgets -- both calls are LAN round trips that finish in
# milliseconds when the peer is up. Small deliberately: this runs on a poll
# that has other work to do.
$script:AnnounceTimeoutSec = 4
$script:NudgeTimeoutSec    = 5

# The aggregator's port, and squid's. Properties of those services rather
# than of this host, so they are not configurable here: a lab that moves them
# has changed the caching-proxy build, which is where the change belongs.
$script:AggregatorPort = 9400
$script:SquidPort      = 3128

# Beacon period. The announce is re-sent even when nothing changed, so a
# collector that restarted (losing its in-memory view) re-learns this host
# without waiting for it to appear in the squid log again.
$script:BeaconIntervalSeconds = 300

# Two pieces of state, not one, because they answer different questions and a
# single field conflates them destructively. LastRecorded is "what the local
# records already say", and advances as soon as they are rewritten.
# LastAnnounced is "what the pool has accepted", and advances only on a
# confirmed announce so an unreachable directory is retried on the next tick
# rather than after a whole beacon interval.
#
# Sharing one field makes an unreachable directory re-log the address change
# and rewrite the same files on EVERY tick, forever: the announce never
# succeeds, the field never advances, and nothing downstream can tell a host
# that keeps moving from a host that simply cannot reach the pool.
$script:LastRecordedAddress  = ''
$script:LastAnnouncedAddress = ''
$script:LastAnnounceUtc      = [datetime]::MinValue

# Renumbering-rate warning. The beacon is the only thing that sees every
# address change, so it is the only place that can tell "the host moved once"
# from "the host is being handed a different address every lease". The second
# is a lab misconfiguration the discovery path merely survives -- it costs a
# directory round trip per guest per move, and it strands any guest whose
# network cannot reach the directory at all -- so it is worth naming once,
# with the remedy, rather than leaving the operator to infer it from a cycle
# log full of repaired addresses.
#
# Latched: said once per beacon process. A warning repeated every renewal is
# a warning nobody reads.
$script:AddressChangeCount   = 0
$script:FirstChangeUtc       = [datetime]::MinValue
$script:ChurnWarningIssued   = $false
$script:ChurnChangeThreshold = 3
$script:ChurnWindowMinutes   = 60

function Get-HostAddressBeaconState {
<#
.SYNOPSIS
    The address this module last successfully announced, and when.
.DESCRIPTION
    Exposed for the tests and for a diagnostic dump. Module-scoped rather
    than persisted: a restart re-announces on its first tick anyway, which is
    the behavior a restarted collector needs.
.OUTPUTS
    System.Collections.Hashtable
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    return @{
        LastRecordedAddress  = $script:LastRecordedAddress
        LastAnnouncedAddress = $script:LastAnnouncedAddress
        LastAnnounceUtc      = $script:LastAnnounceUtc
    }
}

function Reset-HostAddressBeaconState {
<#
.SYNOPSIS
    Forget the last-announced address so the next tick announces again.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param()
    if ($PSCmdlet.ShouldProcess('host address beacon', 'reset last-announced state')) {
        $script:LastRecordedAddress  = ''
        $script:LastAnnouncedAddress = ''
        $script:LastAnnounceUtc      = [datetime]::MinValue
        $script:AddressChangeCount   = 0
        $script:FirstChangeUtc       = [datetime]::MinValue
        $script:ChurnWarningIssued   = $false
    }
}

function Write-HostAddressRecord {
<#
.SYNOPSIS
    Refresh runtime/ipaddresses.txt to the addresses this host holds now.
.DESCRIPTION
    Same file and same format Start-StatusService writes at startup (IPv4
    line, then IPv6 line, loopback excluded). Rewritten here because startup
    is the only moment it was ever written: after one DHCP renewal the footer
    it feeds names an address nobody answers, and an operator reading it goes
    looking for a host that has already moved.
.PARAMETER RuntimeDir
    The runtime directory holding ipaddresses.txt.
.PARAMETER Address
    The current IPv4 address to record.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$Address
    )
    $path = Join-Path $RuntimeDir 'ipaddresses.txt'
    if (-not $PSCmdlet.ShouldProcess($path, "Record host address $Address")) { return }
    try {
        $v6 = @()
        try {
            $v6 = @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                Where-Object { $_.OperationalStatus -eq 'Up' } |
                ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
                ForEach-Object { $_.Address } |
                Where-Object { -not [System.Net.IPAddress]::IsLoopback($_) } |
                Where-Object { $_.AddressFamily -eq 'InterNetworkV6' } |
                ForEach-Object { $_.ToString() })
        } catch {
            Write-Verbose "host address record: IPv6 enumeration failed -- $($_.Exception.Message)"
        }
        $lines = @($Address)
        if ($v6.Count -gt 0) { $lines += ($v6 -join ',') }
        Set-Content -LiteralPath $path -Value $lines -ErrorAction Stop
    } catch {
        Write-Verbose "host address record: could not write '$path' -- $($_.Exception.Message)"
    }
}

function Send-HostAddressAnnounce {
<#
.SYNOPSIS
    Tell the pool aggregator this host's current address. Returns $true when
    the aggregator recorded it.
.DESCRIPTION
    The body carries only the hostId and the status port: the ADDRESS is
    taken by the aggregator from the connection's source, which is what makes
    the route safe to leave unauthenticated -- an announcer can only ever
    advertise itself, and the aggregator confirms the claim by re-reading
    this host's status.json before it moves anything.

    A non-2xx is deliberately treated as "not done" rather than logged and
    forgotten: the aggregator answers 503 when it accepted the announce but
    could not make it durable, and the contract is that the announcer keeps
    its catch-up cadence until it sees a success.
.PARAMETER CacheAddress
    The caching-proxy machine's address (the pool services host).
.PARAMETER HostId
    This host's stable hostId (runtime/host.uuid).
.PARAMETER StatusPort
    The port this host's status service listens on.
.OUTPUTS
    System.Boolean
#>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$CacheAddress,
        [Parameter(Mandatory)][string]$HostId,
        [Parameter(Mandatory)][int]$StatusPort
    )
    try {
        $uri  = "http://${CacheAddress}:$($script:AggregatorPort)/api/v1/host-announce"
        $body = @{ hostId = $HostId; statusPort = $StatusPort } | ConvertTo-Json -Compress
        $null = Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType 'application/json' `
            -TimeoutSec $script:AnnounceTimeoutSec -NoProxy -ErrorAction Stop
        return $true
    } catch {
        Write-Verbose "host address announce: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-HostAddressSquidNudge {
<#
.SYNOPSIS
    Put this host's current address into the squid access log.
.DESCRIPTION
    The aggregator's original discovery path reads that log, so one request
    through the proxy is enough to make a renumbered host visible to a
    collector that has never heard of the announce route. The target is a
    page on the caching-proxy machine itself, so this needs no internet
    egress and cannot be defeated by a lab with no route out.

    Failure is not reported: this is the redundant path, and the announce
    above is the one whose outcome decides anything.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param([Parameter(Mandatory)][string]$CacheAddress)
    if (-not $PSCmdlet.ShouldProcess($CacheAddress, 'nudge squid access log')) { return }
    try {
        $null = Invoke-WebRequest -Uri "http://$CacheAddress/squid-meta" `
            -Proxy "http://${CacheAddress}:$($script:SquidPort)" `
            -TimeoutSec $script:NudgeTimeoutSec -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Verbose "host address nudge: $($_.Exception.Message)"
    }
}

function Write-HostAddressChangeRecord {
<#
.SYNOPSIS
    Append one machine-readable row per address change to
    runtime/hostaddress.changes.ndjson.
.DESCRIPTION
    The human log records that the host moved but not when, so nothing could
    answer the only question that makes a green cycle on a renumbering host
    mean anything: did any address change actually fall inside the cycle, and
    how many? Without a timestamp, a cycle that passed because the network went
    quiet is indistinguishable from one that passed through the churn.

    Append-only NDJSON, and never rotated here: the runner reads it at cycle end
    and the file is small (one short row per change, a few dozen a day).
.PARAMETER RuntimeDir
    The runtime directory the beacon writes into.
.PARAMETER Previous
    The address the host held before the change. Empty on the first observation.
.PARAMETER Current
    The address the host holds now.
.PARAMETER ChangedAtUtc
    ISO-8601 'Z' timestamp of the change, supplied by the caller so the row and
    the human log line carry the same instant.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Previous,
        [Parameter(Mandatory)][string]$Current,
        [Parameter(Mandatory)][string]$ChangedAtUtc
    )
    $path = Join-Path $RuntimeDir 'hostaddress.changes.ndjson'
    if (-not $PSCmdlet.ShouldProcess($path, "Record address change to $Current")) { return }
    try {
        $row = [ordered]@{
            event        = 'host_address_change'
            previous     = $Previous
            current      = $Current
            changedAtUtc = $ChangedAtUtc
        } | ConvertTo-Json -Compress
        # Append with a shared-write-friendly call: the runner reads this file
        # concurrently and a rewrite would give it a truncated view.
        [System.IO.File]::AppendAllText($path, "$row`n")
    } catch {
        Write-Verbose "host address change record: $($_.Exception.Message)"
    }
}

function Write-HostAddressBaselineRecord {
<#
.SYNOPSIS
    Append the first address this beacon observed, as a baseline rather than
    as a change.
.DESCRIPTION
    The record file used to come into existence only when the host MOVED, and
    that made two opposite facts look identical from the outside: a host that
    has held one address since boot has no file, and a host whose beacon never
    started has no file either. The reader returns "cannot measure" for both,
    so the one host that is provably bounded reports the same thing as the one
    nothing is watching -- and a stable fleet reads as an unmonitored one.

    Writing the first observation as its own event fixes both directions. The
    file now exists for as long as the beacon has run, so its ABSENCE means
    exactly one thing: nothing is watching this host. And because the row is
    not a change, the first tick after a beacon restart no longer books a
    phantom move against whatever cycle happens to be running -- which is what
    an empty 'previous' used to record.
.PARAMETER RuntimeDir
    The runtime directory the beacon writes into.
.PARAMETER Current
    The address the host holds at the first observation.
.PARAMETER ObservedAtUtc
    ISO-8601 'Z' timestamp of the observation. Named changedAtUtc on the row
    like every other, so one reader parses the file.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][string]$Current,
        [Parameter(Mandatory)][string]$ObservedAtUtc
    )
    $path = Join-Path $RuntimeDir 'hostaddress.changes.ndjson'
    if (-not $PSCmdlet.ShouldProcess($path, "Record address baseline $Current")) { return }
    try {
        $row = [ordered]@{
            event        = 'host_address_baseline'
            previous     = ''
            current      = $Current
            changedAtUtc = $ObservedAtUtc
        } | ConvertTo-Json -Compress
        [System.IO.File]::AppendAllText($path, "$row`n")
    } catch {
        Write-Verbose "host address baseline record: $($_.Exception.Message)"
    }
}

function Get-HostAddressChangeCount {
<#
.SYNOPSIS
    How many host address changes were recorded inside a time window.
.DESCRIPTION
    The measurement behind the churn assertion. A cycle that passes on this host
    is only evidence that yuruna survives IP instability if instability actually
    happened while it ran, so the runner pairs its verdict with this count.

    Rows that cannot be parsed are skipped rather than throwing: this feeds a
    report, and a malformed row is not worth failing a cycle over.
.PARAMETER RuntimeDir
    The runtime directory holding hostaddress.changes.ndjson.
.PARAMETER StartUtc
    Window start, inclusive.
.PARAMETER EndUtc
    Window end, inclusive.
.OUTPUTS
    System.Int32
#>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][datetime]$StartUtc,
        [Parameter(Mandatory)][datetime]$EndUtc
    )
    # -1, never 0, when there is nothing to read. A cycle that met no address
    # change and a cycle whose record was never written are different facts, and
    # only one of them is evidence about surviving churn. Collapsing them is how
    # five cycles were read as "no churn happened" when three of them had churn.
    #
    # The baseline row is what keeps that distinction honest in the other
    # direction. It parses -- so a host whose beacon is running and whose
    # address has never moved reports a real 0 -- but it is not a change, so it
    # never counts. Without it the file appeared only once a host had already
    # moved, and the most stable hosts in the lab were the ones reporting that
    # they could not be measured.
    $path = Join-Path $RuntimeDir 'hostaddress.changes.ndjson'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return -1 }
    $count = 0
    $parsed = 0
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $row = $line | ConvertFrom-Json -ErrorAction Stop
            $at  = ([datetime]$row.changedAtUtc).ToUniversalTime()
            $parsed++
            if ([string]$row.event -eq 'host_address_baseline') { continue }
            if ($at -ge $StartUtc -and $at -le $EndUtc) { $count++ }
        } catch {
            Write-Verbose "host address change count: skipping unparseable row -- $($_.Exception.Message)"
        }
    }
    # A file whose every row was unreadable is not a quiet network either.
    if ($parsed -eq 0) { return -1 }
    return $count
}

function Get-HostAddressChurnVerdict {
<#
.SYNOPSIS
    Read the recorded address changes and say WHY the host is moving: not at
    all, once, or once per lease renewal.
.DESCRIPTION
    The distinction that matters is not how often the address changed but
    whether the changes are PERIODIC. A host that renumbers on reboots and
    cable events produces changes at irregular intervals -- ordinary lab life,
    and what the discovery path exists to absorb. A host that takes a new
    address on every renewal produces them at one interval, repeated, because
    the interval IS the renewal timer: its DHCP identity is not being honored,
    so every renewal is a fresh allocation rather than an extension.

    Reading periodicity instead of frequency is what makes this verdict
    independent of the lease time. The same fault shows as changes every ten
    minutes on a twenty-minute lease and every three days on a week-long one;
    a threshold on "changes per hour" would call the first a fault and the
    second healthy, while the pool drains faster in the second case, because
    each abandoned address is parked for a week instead of twenty minutes.

    Regularity is judged against the MEDIAN interval rather than the mean so a
    single reboot in the middle of an otherwise periodic series does not mask
    it -- the reboot contributes one outlying interval, and the median ignores
    it.
.PARAMETER RuntimeDir
    The runtime directory holding hostaddress.changes.ndjson.
.PARAMETER LookbackHours
    How far back to read. The window has to span several renewals to see a
    period at all, so it is generous by default.
.PARAMETER NowUtc
    Window end. Injectable so the verdict is testable against fixed records.
.OUTPUTS
    [hashtable] verdict ('unknown' | 'stable' | 'moved' | 'renewal-churn'),
    changes, distinctAddresses, medianIntervalMinutes, lookbackHours.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [int]$LookbackHours = 48,
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    $result = @{
        verdict               = 'unknown'
        changes               = -1
        distinctAddresses     = 0
        medianIntervalMinutes = 0.0
        lookbackHours         = $LookbackHours
    }
    $path = Join-Path $RuntimeDir 'hostaddress.changes.ndjson'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $result }

    $since = $NowUtc.AddHours(-1 * [math]::Abs($LookbackHours))
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $row = $line | ConvertFrom-Json -ErrorAction Stop
            $at  = ([datetime]$row.changedAtUtc).ToUniversalTime()
        } catch { continue }
        # The baseline says the beacon started here, not that the host moved
        # here. Counting it would turn every beacon restart into a change and
        # make a restarted beacon on a motionless host read as 'moved'.
        if ([string]$row.event -eq 'host_address_baseline') { continue }
        if ($at -lt $since -or $at -gt $NowUtc) { continue }
        $rows.Add([pscustomobject]@{ At = $at; Current = [string]$row.current })
    }
    $result.changes = $rows.Count
    $result.distinctAddresses = @($rows | ForEach-Object { $_.Current } |
        Where-Object { $_ } | Select-Object -Unique).Count
    if ($rows.Count -eq 0) { $result.verdict = 'stable'; return $result }
    # Two changes give one interval, which is a duration and not yet a period.
    # Three are the fewest that can repeat, and repetition is the whole signal.
    if ($rows.Count -lt 3) { $result.verdict = 'moved'; return $result }

    $ordered   = @($rows | Sort-Object At)
    $intervals = @(1..($ordered.Count - 1) | ForEach-Object {
        ($ordered[$_].At - $ordered[$_ - 1].At).TotalMinutes
    })
    $sorted = @($intervals | Sort-Object)
    $median = if ($sorted.Count % 2) { $sorted[[int](($sorted.Count - 1) / 2)] }
              else { ($sorted[$sorted.Count / 2 - 1] + $sorted[$sorted.Count / 2]) / 2 }
    $result.medianIntervalMinutes = [math]::Round($median, 1)
    if ($median -le 0) { $result.verdict = 'moved'; return $result }

    # A renewal timer is a timer: the intervals it produces cluster tightly.
    # A quarter of the period is loose enough for poll granularity and the
    # server's own jitter, and tight enough that reboot-driven changes -- which
    # follow no clock -- do not reach it.
    $within = @($intervals | Where-Object { [math]::Abs($_ - $median) -le ($median * 0.25) }).Count
    $result.verdict = if ($within -ge [math]::Ceiling($intervals.Count * 0.75)) { 'renewal-churn' } else { 'moved' }
    return $result
}

function Get-HostBridgeDhcpIdentity {
<#
.SYNOPSIS
    Is this host's bridge pinned to a DHCP identity that survives a renewal?
.DESCRIPTION
    The configuration half of the address-stability question, kept separate
    from the observed half on purpose: a pin that the DHCP server ignores
    looks identical to no pin at all from the address log, and identical to a
    working pin from the configuration. Only the pair distinguishes "nobody
    pinned it" from "it is pinned and the server does not care", and those
    have different remedies.

    Two backends, because the bridge has two builders. NetworkManager owns it
    on a desktop-rendered host, where the pin is `ipv4.dhcp-client-id`;
    systemd-networkd owns it where the generated netplan applied, where the
    pin is `dhcp-identifier: mac` and is written by
    Get-YurunaBridgeNetplanYaml. A host running neither (or a bridge that does
    not exist yet) reports 'unknown' rather than guessing.
.PARAMETER BridgeName
    Defaults to the framework bridge.
.OUTPUTS
    [hashtable] backend ('networkmanager' | 'networkd' | 'unknown'),
    pinned ([bool] or $null when unknown), detail, remedy.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$BridgeName = 'yuruna-br0')
    $result = @{ backend = 'unknown'; pinned = $null; detail = ''; remedy = '' }
    if (-not $IsLinux) {
        $result.detail = 'not a Linux host; the bridge DHCP identity is a KVM-host concept.'
        return $result
    }
    if (Get-Command nmcli -ErrorAction SilentlyContinue) {
        $shown = @(& nmcli -t -f connection.id,ipv4.dhcp-client-id connection show $BridgeName 2>$null)
        if ($LASTEXITCODE -eq 0 -and $shown.Count) {
            $result.backend = 'networkmanager'
            $idLine = @($shown | Where-Object { $_ -like 'ipv4.dhcp-client-id:*' })[0]
            $value  = if ($idLine) { ($idLine -split ':', 2)[1].Trim() } else { '' }
            # nmcli prints '--' for an unset property. Unset means NM's default,
            # which is a machine-id-derived DUID, not the MAC.
            $result.pinned = ($value -and $value -ne '--' -and $value -ne 'default')
            $result.detail = "NetworkManager profile '$BridgeName': ipv4.dhcp-client-id = $(if ($value) { $value } else { '(absent)' })."
            $result.remedy = "sudo nmcli connection modify '$BridgeName' ipv4.dhcp-client-id mac ipv4.dhcp-iaid mac ipv4.dhcp-send-release yes"
            return $result
        }
    }
    $netplanPath = '/etc/netplan/99-yuruna-external.yaml'
    if (Test-Path -LiteralPath $netplanPath) {
        $result.backend = 'networkd'
        $text = ''
        try { $text = [string](Get-Content -LiteralPath $netplanPath -Raw -ErrorAction Stop) }
        catch { $text = [string](& sudo cat $netplanPath 2>$null) }
        $result.pinned = ($text -match '(?m)^\s*dhcp-identifier:\s*mac\s*$')
        $result.detail = "netplan '$netplanPath': dhcp-identifier: mac $(if ($result.pinned) { 'present' } else { 'absent' })."
        $result.remedy = "re-run the host network setup so '$netplanPath' is regenerated with 'dhcp-identifier: mac', then: sudo netplan apply"
        return $result
    }
    $result.detail = "no NetworkManager profile and no '$netplanPath' for '$BridgeName'."
    return $result
}

function Set-HostBridgeDhcpIdentity {
<#
.SYNOPSIS
    Pin an already-built NetworkManager bridge to the DHCP identity a new one
    would be built with.
.DESCRIPTION
    The pin is set when the bridge is CREATED, and nobody rebuilds a working
    bridge -- so every host built before it existed keeps renumbering forever
    while the fix sits in a document. Applying it where the fault is detected
    is the difference between a remedy that reaches the fleet and one that
    reaches whoever reads the report.

    SAFE TO RUN UNATTENDED, and the reason is narrow enough to state exactly:
    `nmcli connection modify` writes the stored profile and does NOT reactivate
    it. The live connection keeps its address, no interface goes down, and no
    remote session is dropped; the setting takes effect at the next activation.
    An `nmcli connection up` here would be a different thing entirely and is
    deliberately absent.

    NETWORKD BRIDGES ARE REPORTED, NOT TOUCHED. Fixing one means rewriting
    /etc/netplan and running `netplan apply`, which re-plumbs the host's IP
    stack -- an operator action with eyes on the console, not something a
    health check does on its way past.

    Best-effort in the strict sense: every failure returns, none throws. A host
    that cannot elevate is named rather than retried, because a sudo that is
    refused once is refused all cycle.
.PARAMETER BridgeName
    Defaults to the framework bridge.
.OUTPUTS
    [hashtable] applied ([bool]), verified ([bool]), reason, detail.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([string]$BridgeName = 'yuruna-br0')
    $result = @{ applied = $false; verified = $false; reason = ''; detail = '' }
    $before = Get-HostBridgeDhcpIdentity -BridgeName $BridgeName
    $result.detail = $before.detail
    if ($before.backend -ne 'networkmanager') {
        $result.reason = "the bridge is not NetworkManager-managed (backend '$($before.backend)'), and the other backends are not safe to change unattended."
        return $result
    }
    if ($before.pinned -ne $false) {
        $result.reason = 'already pinned.'
        $result.verified = [bool]$before.pinned
        return $result
    }
    if (-not (Get-Command Invoke-YurunaSudo -ErrorAction SilentlyContinue)) {
        $result.reason = 'the shared sudo wrapper is unavailable in this session.'
        return $result
    }
    if (-not $PSCmdlet.ShouldProcess($BridgeName, 'Pin the DHCP client identity to the NIC MAC')) {
        $result.reason = 'skipped by -WhatIf.'
        return $result
    }
    try {
        # -TolerateBlocked: a host whose sudo will not run unattended has a
        # problem this function cannot fix and must not stall the cycle over.
        $r = Invoke-YurunaSudo -Argument @('nmcli', 'connection', 'modify', $BridgeName,
                'ipv4.dhcp-client-id', 'mac',
                'ipv4.dhcp-iaid', 'mac',
                'ipv4.dhcp-send-release', 'yes') -TolerateBlocked
        if ($r.Blocked) {
            # Naming the grant is the whole value of this branch. Unattended
            # elevation cannot bootstrap itself -- installing the rule needs the
            # sudo the rule exists to provide -- so one operator action is the
            # floor, and the message has to be the thing that makes it a
            # one-liner rather than an investigation.
            $result.reason = ('sudo refused to run unattended, so the profile was left as it is. Grant the one ' +
                'command with: sudo install -m 0440 -o root -g root host/ubuntu.kvm/yuruna-bridge-pin.sudoers ' +
                '/etc/sudoers.d/yuruna-bridge-pin')
            return $result
        }
        if ($r.ExitCode -ne 0) {
            $result.reason = "nmcli exited $($r.ExitCode): $(($r.Output -join ' ').Trim())"
            return $result
        }
    } catch {
        $result.reason = "the modify call failed: $($_.Exception.Message)"
        return $result
    }
    $result.applied = $true
    # Read it back rather than trusting the exit code. nmcli accepts a property
    # it then stores differently often enough that "it returned 0" and "the
    # profile now says mac" are separate claims, and only the second one is the
    # thing that stops the host renumbering.
    $after = Get-HostBridgeDhcpIdentity -BridgeName $BridgeName
    $result.verified = ($after.pinned -eq $true)
    $result.detail   = $after.detail
    $result.reason   = if ($result.verified) {
        'pinned; it takes effect at the next activation of the profile, so the address in use now is unchanged.'
    } else {
        'nmcli accepted the change but the profile does not read back as pinned.'
    }
    return $result
}

function Get-HostAddressStabilityReport {
<#
.SYNOPSIS
    Combine the observed churn and the configured pin into one verdict with
    the remedy that actually applies.
.DESCRIPTION
    Neither input answers the question alone. The configuration says what was
    asked for; the address log says what the DHCP server did about it. Pairing
    them separates the two faults that look the same from either side:

      * not pinned, and renumbering every renewal -- pin it.
      * pinned, and STILL renumbering every renewal -- the server does not key
        leases on client-id. No pin will fix that; the address has to come
        from a reservation or be set statically.

    And it separates both from the case that reads like a fault and is not: a
    host the lab renumbers deliberately to prove the discovery path works.
    That one is named in the message rather than silently reported as broken,
    because advice that is confidently wrong some of the time teaches the
    operator to skip it.

    Severity is 'ok' / 'advisory' / 'warning'. Nothing here fails a cycle: an
    address that is drifting has already cost the lab whatever it was going to
    cost by the time this runs, and a health report that can fail a run is one
    operators stop running.
.OUTPUTS
    [hashtable] severity, verdict, message, remedy, churn, identity.
#>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [string]$BridgeName = 'yuruna-br0',
        [int]$LookbackHours = 48,
        [datetime]$NowUtc = [datetime]::UtcNow
    )
    $churn    = Get-HostAddressChurnVerdict -RuntimeDir $RuntimeDir -LookbackHours $LookbackHours -NowUtc $NowUtc
    $identity = Get-HostBridgeDhcpIdentity -BridgeName $BridgeName
    $report = @{
        severity = 'ok'; verdict = $churn.verdict; message = ''; remedy = ''
        churn    = $churn; identity = $identity
    }
    $rate = if ($churn.medianIntervalMinutes -gt 0) {
        [int][math]::Round(1440.0 / $churn.medianIntervalMinutes)
    } else { 0 }

    switch ($churn.verdict) {
        'renewal-churn' {
            # Periodic changes that all report the SAME address are a timer
            # resetting the link, not a timer allocating addresses: one address
            # is held throughout, so the pool-drain arithmetic below would be
            # asserting a leak that is provably not happening. The periodicity
            # is still worth a warning -- an address dropping on a clock breaks
            # every guest behind it each time -- so the verdict stands and only
            # the claim about the pool is withdrawn.
            $report.severity = 'warning'
            if ($churn.distinctAddresses -le 1) {
                $base = ("This host LOSES AND REACQUIRES one address on a timer: $($churn.changes) changes " +
                         "in the last $($churn.lookbackHours)h, one every $($churn.medianIntervalMinutes) min, " +
                         'but only ever on a single address. No lease is being leaked and the pool is not ' +
                         'draining, so the address itself is not the problem -- something is resetting this ' +
                         'link on a clock, and every guest behind it loses the wire each time even though ' +
                         'nothing renumbers. That is invisible in a guest log, which shows only the outage.')
                $report.message = "$base Look at the link and the renewal path, not at the DHCP identity."
                $report.remedy  = "confirm whether the interface drops carrier or the address at each tick; see docs/network.md, 'Pinning the host address'."
                return $report
            }
            # Reports the rate and stops there. Turning "N addresses a day" into
            # a drain -- let alone into exhaustion -- needs the lease period and
            # the scope size, and this beacon is handed NEITHER: it sees only its
            # own host's address log. The same rate is unremarkable on a short
            # lease and fatal on a long one, so asserting the fatal reading is a
            # guess wearing the costume of a measurement, and it sends whoever
            # reads it to the DHCP server to fix a pool that may be mostly free.
            # State the observation; name the two numbers that would settle it.
            $base = ("This host re-addresses on a short clock: $($churn.changes) changes " +
                     "in the last $($churn.lookbackHours)h, one every $($churn.medianIntervalMinutes) min, " +
                     "$($churn.distinctAddresses) distinct addresses -- about $rate a day. Whether that " +
                     'is harmless or is draining the pool depends on the lease period and the scope size, ' +
                     'which are facts about the DHCP server and are not visible from this host: at a ' +
                     'lease of L hours each address is held L hours, so roughly rate x L / 24 are held ' +
                     'at once. Compare that against the free-lease count on the server before treating ' +
                     'this as a pool problem. What IS certain from here is the churn itself -- an address ' +
                     'changing on a clock breaks every guest behind it each time it moves.')
            if ($identity.pinned -eq $false) {
                $report.message = "$base The bridge's DHCP identity is not pinned, so every renewal presents a client the server has not seen before."
                $report.remedy  = $identity.remedy
            } elseif ($identity.pinned -eq $true) {
                $report.message = "$base The bridge's DHCP identity IS pinned, so the server is not keying leases on it. A pin cannot fix this."
                $report.remedy  = "find what re-requests the lease on this clock (a renewal timer would fire at half the lease, so a much shorter period is something restarting the connection); a DHCP reservation for the bridge MAC, or a static address, makes the address stable regardless -- see docs/network.md, 'Pinning the host address'."
            } else {
                $report.message = "$base The bridge's DHCP identity could not be read ($($identity.detail))."
                $report.remedy  = "see docs/network.md, 'Pinning the host address'."
            }
            $report.message += " Unless this host is one the lab renumbers on purpose, in which case leave it be."
            return $report
        }
        'moved' {
            $report.severity = 'advisory'
            # "Changed address N times" is only sayable when more than one
            # address was actually seen. A window whose changes all report the
            # same current address records a host that kept LOSING and
            # REACQUIRING one address, not one that renumbered -- no second
            # address was ever observed and no extra lease was drawn. Saying it
            # moved 62 times invents a renumbering that leaves no trace anywhere
            # else, and it buries the signal that is really there: something is
            # dropping this host's address and handing the same one back.
            if ($churn.distinctAddresses -le 1) {
                $every = if ($churn.medianIntervalMinutes -gt 0) {
                    " about every $($churn.medianIntervalMinutes) min"
                } else { '' }
                $report.message = ("This host recorded $($churn.changes) address change(s) in the last " +
                    "$($churn.lookbackHours)h but was only ever observed on ONE address, so it did not " +
                    "renumber and took no extra lease from the pool: it kept losing that address and " +
                    "getting it back$every. Address-mobility questions do not apply -- the thing to look at " +
                    'is why the address keeps dropping, which is a link or renewal event rather than a move. ' +
                    'A guest that fails with no IPv4 while this host looks healthy is the symptom to expect.')
                return $report
            }
            $report.message  = ("This host changed address $($churn.changes) time(s) across " +
                "$($churn.distinctAddresses) distinct addresses in the last " +
                "$($churn.lookbackHours)h, at no fixed interval -- consistent with reboots or link events " +
                'rather than a renewal that is not being honored. The discovery path absorbs this.')
            return $report
        }
        'stable' {
            if ($identity.pinned -eq $false) {
                $report.severity = 'advisory'
                $report.message  = ("This host has held one address for the last $($churn.lookbackHours)h, but its " +
                    'bridge DHCP identity is not pinned -- it is holding the address by the DHCP server''s ' +
                    'goodwill, and a server restart or a lease-table eviction renumbers it.')
                $report.remedy   = $identity.remedy
                return $report
            }
            $report.message = "This host has held one address for the last $($churn.lookbackHours)h. $($identity.detail)"
            return $report
        }
        default {
            # The beacon writes a baseline row the first time it sees an
            # address, so the record exists for as long as it has run. Nothing
            # to read is therefore not "this host is quiet" -- it is "nothing is
            # watching this host", which is worth more than an advisory: an
            # unwatched host is exactly where unbounded renumbering hides.
            $report.severity = 'warning'
            $report.message  = ('No host address record to read. The beacon writes one the first time it ' +
                'observes an address, so its absence means the beacon is not running here -- this host''s ' +
                'address footprint is unmeasured, not proven quiet.')
            $report.remedy   = 'start the status service (the beacon runs alongside it) and confirm it writes runtime/hostaddress.changes.ndjson.'
            return $report
        }
    }
}

function Assert-HostAddressStability {
<#
.SYNOPSIS
    Warn once when this host is renumbering fast enough to be a lab
    misconfiguration rather than an ordinary lease renewal.
.DESCRIPTION
    Counts observed address changes inside a rolling window. Below the
    threshold nothing is said: one move is what the whole discovery path
    exists to absorb. Above it, the operator gets the concrete remedy --
    which MAC to reserve -- because the discovery path only survives churn,
    it does not fix it, and a guest on a network with no route to the pool
    directory is stranded by it outright.
#>
    [CmdletBinding()]
    [OutputType([void])]
    param()
    if ($script:ChurnWarningIssued) { return }
    $now = (Get-Date).ToUniversalTime()
    if ($script:FirstChangeUtc -eq [datetime]::MinValue -or
        ($now - $script:FirstChangeUtc).TotalMinutes -gt $script:ChurnWindowMinutes) {
        $script:FirstChangeUtc     = $now
        $script:AddressChangeCount = 1
        return
    }
    $script:AddressChangeCount++
    if ($script:AddressChangeCount -lt $script:ChurnChangeThreshold) { return }
    $script:ChurnWarningIssued = $true

    $mac = ''
    try {
        $bridgeMac = '/sys/class/net/yuruna-br0/address'
        if (Test-Path -LiteralPath $bridgeMac) {
            $mac = ([string](Get-Content -LiteralPath $bridgeMac -Raw -ErrorAction Stop)).Trim()
        }
    } catch { Write-Verbose "host address stability: could not read the bridge MAC -- $($_.Exception.Message)" }

    # The remedy is right for most hosts and wrong for one kind: a host kept
    # deliberately unstable to prove the harness survives renumbering, where
    # "pin the address" means "stop running the test". Naming both cases costs a
    # sentence and stops the warning training that operator to ignore it --
    # which is the failure mode of advice that is confidently wrong a fraction
    # of the time.
    $hint = if ($mac) { " Reserve $mac on the DHCP server, or give the bridge a static address." }
            else { ' Reserve this host''s bridge MAC on the DHCP server, or give it a static address.' }
    Write-Warning ("This host has changed address $($script:AddressChangeCount) times in under " +
        "$($script:ChurnWindowMinutes) minutes. Guests are repairing their coordinates through the pool " +
        "directory, which works but is not free, and a guest with no route to that directory cannot " +
        "recover at all.$hint Unless this host is one the lab keeps renumbering on purpose, in which " +
        "case leave it be: the number of changes that landed inside each cycle is recorded on its " +
        "cycle_end event. See docs/network.md, 'Host address stability'.")
}

function Invoke-HostAddressBeaconTick {
<#
.SYNOPSIS
    One beacon tick: notice an address change, record it, and publish it.
.DESCRIPTION
    Safe to call from any existing poll loop and cheap enough to call often:
    when the address has not changed and the beacon interval has not elapsed,
    the tick does nothing at all and touches no network.

    Announces on change AND on the interval AND on the first tick after
    start. Those three triggers together are what make the process lifetime
    stop mattering -- a status service that restarts, a collector that
    restarts, and a host that renumbers all converge without anyone deciding
    which of them happened.
.PARAMETER RuntimeDir
    The runtime directory holding host.uuid and ipaddresses.txt.
.PARAMETER CurrentAddress
    The address this host answers on now. Supplied by the caller (which has
    already resolved it for its own purposes) rather than resolved here, so
    this module holds no opinion about how a host finds its own address --
    that belongs to the per-host drivers.
.PARAMETER CacheAddress
    The caching-proxy machine's address. Empty means no pool directory in
    this lab, and the tick reduces to keeping the local record honest.
.PARAMETER StatusPort
    The port this host's status service listens on.
.OUTPUTS
    System.Boolean. True when this tick published something.
#>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RuntimeDir,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CurrentAddress,
        [Parameter()][AllowEmptyString()][string]$CacheAddress = '',
        [Parameter()][int]$StatusPort = 8080
    )
    if ([string]::IsNullOrWhiteSpace($CurrentAddress)) { return $false }

    $moved   = ($CurrentAddress -ne $script:LastRecordedAddress)
    $changed = ($CurrentAddress -ne $script:LastAnnouncedAddress)
    $due     = ((Get-Date).ToUniversalTime() - $script:LastAnnounceUtc).TotalSeconds -ge $script:BeaconIntervalSeconds
    if (-not $changed -and -not $due) { return $false }

    if (-not $PSCmdlet.ShouldProcess($CurrentAddress, 'publish host address')) { return $false }

    if ($moved) {
        # Logged at a level the operator sees, because a host renumbering
        # mid-cycle is the cause behind a whole class of guest failures and
        # is otherwise invisible in the cycle log.
        # -InformationAction Continue, not the caller's preference: this is the
        # only record of when the host moved, and $InformationPreference
        # defaults to SilentlyContinue -- so without it the line is written
        # nowhere and a failed cycle cannot be reconstructed afterwards.
        $changedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        # No previous address means this beacon has only just started looking,
        # so the host has not been seen to move -- it has been seen for the
        # first time. Recording that as a change books a move the host never
        # made against whatever cycle is running, and every beacon restart
        # would book another one.
        $isBaseline = [string]::IsNullOrWhiteSpace($script:LastRecordedAddress)
        if ($isBaseline) {
            Write-Information "[$changedAtUtc] Host address baseline: '$CurrentAddress'. Recording it so a stable host is distinguishable from an unwatched one." -InformationAction Continue
        } else {
            Write-Information "[$changedAtUtc] Host address changed: '$($script:LastRecordedAddress)' -> '$CurrentAddress'. Refreshing records and republishing to the pool directory." -InformationAction Continue
        }
        Write-HostAddressRecord -RuntimeDir $RuntimeDir -Address $CurrentAddress
        if ($isBaseline) {
            Write-HostAddressBaselineRecord -RuntimeDir $RuntimeDir -Current $CurrentAddress -ObservedAtUtc $changedAtUtc
        } else {
            Write-HostAddressChangeRecord -RuntimeDir $RuntimeDir -Previous $script:LastRecordedAddress -Current $CurrentAddress -ChangedAtUtc $changedAtUtc
        }
        $script:LastRecordedAddress = $CurrentAddress
        if (-not $isBaseline) { Assert-HostAddressStability }
    }

    if ([string]::IsNullOrWhiteSpace($CacheAddress)) {
        # No directory to publish to. The local record is already correct, and
        # with nothing to announce the announced-state advances too -- there is
        # no pending work for a retry to pick up.
        $script:LastAnnouncedAddress = $CurrentAddress
        $script:LastAnnounceUtc      = (Get-Date).ToUniversalTime()
        return $moved
    }

    $hostId = ''
    try {
        $uuidPath = Join-Path $RuntimeDir 'host.uuid'
        if (Test-Path -LiteralPath $uuidPath -PathType Leaf) {
            $hostId = ([string](Get-Content -LiteralPath $uuidPath -Raw -ErrorAction Stop)).Trim()
        }
    } catch {
        Write-Verbose "host address beacon: could not read host.uuid -- $($_.Exception.Message)"
    }
    if ([string]::IsNullOrWhiteSpace($hostId)) { return $false }

    $announced = Send-HostAddressAnnounce -CacheAddress $CacheAddress -HostId $hostId -StatusPort $StatusPort
    Invoke-HostAddressSquidNudge -CacheAddress $CacheAddress

    # Only a confirmed announce advances the state. A failed one leaves the
    # remembered address alone so the next tick retries immediately instead
    # of sleeping a whole beacon interval on an address the pool never took.
    if ($announced) {
        $script:LastAnnouncedAddress = $CurrentAddress
        $script:LastAnnounceUtc      = (Get-Date).ToUniversalTime()
    }
    return $announced
}

Export-ModuleMember -Function Get-HostAddressBeaconState, Reset-HostAddressBeaconState, Assert-HostAddressStability,
    Write-HostAddressRecord, Write-HostAddressChangeRecord, Write-HostAddressBaselineRecord,
    Get-HostAddressChangeCount,
    Get-HostAddressChurnVerdict, Get-HostBridgeDhcpIdentity, Set-HostBridgeDhcpIdentity,
    Get-HostAddressStabilityReport,
    Send-HostAddressAnnounce, Invoke-HostAddressSquidNudge,
    Invoke-HostAddressBeaconTick
