<#PSScriptInfo
.VERSION 2026.08.14
.GUID 42c9f45e-6b21-4a83-9d0e-3f7a1c58be24
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
            if ($at -ge $StartUtc -and $at -le $EndUtc) { $count++ }
        } catch {
            Write-Verbose "host address change count: skipping unparseable row -- $($_.Exception.Message)"
        }
    }
    # A file whose every row was unreadable is not a quiet network either.
    if ($parsed -eq 0) { return -1 }
    return $count
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
        Write-Information "[$changedAtUtc] Host address changed: '$($script:LastRecordedAddress)' -> '$CurrentAddress'. Refreshing records and republishing to the pool directory." -InformationAction Continue
        Write-HostAddressRecord -RuntimeDir $RuntimeDir -Address $CurrentAddress
        Write-HostAddressChangeRecord -RuntimeDir $RuntimeDir -Previous $script:LastRecordedAddress -Current $CurrentAddress -ChangedAtUtc $changedAtUtc
        $script:LastRecordedAddress = $CurrentAddress
        Assert-HostAddressStability
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
    Write-HostAddressRecord, Write-HostAddressChangeRecord, Get-HostAddressChangeCount,
    Send-HostAddressAnnounce, Invoke-HostAddressSquidNudge,
    Invoke-HostAddressBeaconTick
