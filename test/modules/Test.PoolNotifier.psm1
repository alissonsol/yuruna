<#PSScriptInfo
.VERSION 2026.07.22
.GUID 423e9a21-5b84-4f63-9c12-8e4a1d2f6b90
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool notifier alert spool
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
    Host-side pool-alert notifier: a bounded cycle-end spooler that delivers the
    aggregator's advisory pool-degraded alerts through the existing notification
    extension.
.DESCRIPTION
    The pool aggregator (read-only, in the caching-proxy guest) computes the
    quorum-degraded ALERT latch and exposes it as the yuruna_pool_alert_active gauge.
    It cannot deliver the alert itself (no pwsh, no notification transport, a
    root-owned + timer-transient NAS mount). So delivery is owned HERE, on the host
    the operator configured:

      read the latched gauge over HTTP  ->  enqueue a message file on the poolStorage
      NAS  (notifications/outgoing/)    ->  deliver via Send-Notification  ->  move to
      delivered/  (or failed/ after MaxAttempts).

    The NAS spool gives durability (a failed delivery is retried next cycle) + an audit
    trail, and decouples the detector (the guest aggregator) from the deliverer (this
    host, which has the transport + a persistent, writable NAS mount).

    Self-electing: the notifier runs ONLY where the pool-alert transport is configured
    (transports.yml is host-local + secret), so the operator designates the one host by
    configuring it there -- no fleet-wide flag, no fragile VM-ownership detection. If two
    hosts are ever configured, the shared NAS queue's atomic claim (rename into sending/)
    keeps each message delivered at most once.

    Fully bounded (HTTP timeouts + a per-cycle message cap) and never throws, so it is
    safe as an unattended-loop cycle-end hook (the "outer-loop hook must be prompt-safe
    AND subprocess-bounded" trap class). It is purely a delivery surface: no runner reads
    the degraded/alert state to gate a cycle (consensus-gated control is deferred).
#>

# The pool-alert EventCode the operator subscribes to in transports.yml.
$script:PoolAlertEventCode = 'pool.alert'

function Get-PoolNotifierSpoolRoot {
    <#
    .SYNOPSIS
        The pool-wide spool root on the poolStorage NAS (<LocalPath>/notifications). Not
        per-host: one queue the single notifier drains. $null when poolStorage is not
        configured (no replicate -> Get-YurunaPoolStorageConfig returns null -> no queue).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Config)
    if (-not $Config) { return $null }
    $local = [string]$Config.LocalPath
    if ([string]::IsNullOrWhiteSpace($local)) { return $null }
    return (Join-Path $local 'notifications')
}

function Initialize-PoolNotifierSpool {
    <#
    .SYNOPSIS
        Best-effort create the spool subdirectories (outgoing/sending/delivered/failed)
        under the NAS spool root. Requires the NAS to be mounted (the caller checks).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$SpoolRoot)
    try {
        foreach ($d in @($SpoolRoot,
                (Join-Path $SpoolRoot 'outgoing'), (Join-Path $SpoolRoot 'sending'),
                (Join-Path $SpoolRoot 'delivered'), (Join-Path $SpoolRoot 'failed'))) {
            if (-not (Test-Path -LiteralPath $d)) {
                if ($PSCmdlet.ShouldProcess($d, 'Create pool notifier spool dir')) {
                    New-Item -ItemType Directory -Force -Path $d | Out-Null
                }
            }
        }
        return $true
    } catch { Write-Verbose "Initialize-PoolNotifierSpool: $($_.Exception.Message)"; return $false }
}

function ConvertFrom-PrometheusPoolGauge {
    <#
    .SYNOPSIS
        PURE parser: extract the per-pool gating gauges from the aggregator's /metrics
        text. Returns @{ <pool> = @{ pool; alertActive; degraded; healthyFraction;
        healthyThreshold; membersHealthy; membersTotal } }. A pool only appears if it has
        at least one of these series; alertActive is true ONLY for an authored pool whose
        alert is latched (the aggregator emits yuruna_pool_alert_active for authored pools).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$MetricsText)
    $pools = @{}
    $rx = [regex]'^(yuruna_pool_(?:alert_active|degraded|healthy_fraction|healthy_threshold|members_healthy|members_total))\{pool="([^"]+)"\}\s+([-+0-9.eEnaN]+)\s*$'
    foreach ($line in ($MetricsText -split "`n")) {
        $m = $rx.Match($line.Trim())
        if (-not $m.Success) { continue }
        $metric = $m.Groups[1].Value
        $pool   = $m.Groups[2].Value
        $raw    = $m.Groups[3].Value
        $val = 0.0
        if (-not [double]::TryParse($raw, [ref]$val)) { continue }
        if (-not $pools.ContainsKey($pool)) {
            $pools[$pool] = @{ pool = $pool; alertActive = $false; degraded = $false; healthyFraction = $null; healthyThreshold = $null; membersHealthy = $null; membersTotal = $null }
        }
        switch ($metric) {
            'yuruna_pool_alert_active'      { $pools[$pool].alertActive      = ($val -ge 1) }
            'yuruna_pool_degraded'          { $pools[$pool].degraded         = ($val -ge 1) }
            'yuruna_pool_healthy_fraction'  { $pools[$pool].healthyFraction  = $val }
            'yuruna_pool_healthy_threshold' { $pools[$pool].healthyThreshold = $val }
            'yuruna_pool_members_healthy'   { $pools[$pool].membersHealthy   = [int]$val }
            'yuruna_pool_members_total'     { $pools[$pool].membersTotal     = [int]$val }
        }
    }
    return $pools
}

function Get-PoolMetricsCandidateUrl {
    <#
    .SYNOPSIS
        PURE: from an http(s):// metrics URL, return the candidate URLs to try in order
        -- HTTPS first (the aggregator serves TLS when its proxy-CA leaf is present), then
        HTTP (a proxy not yet upgraded), so the notifier works across a TLS rollout.
    #>
    [CmdletBinding()]
    [OutputType([string[]], [object[]])]
    param([Parameter(Mandatory)][string]$MetricsUrl)
    if ($MetricsUrl -match '^https?://(.+)$') {
        $rest = $Matches[1]
        return @("https://$rest", "http://$rest")
    }
    return @($MetricsUrl)
}

function Get-PoolAlertGaugeState {
    <#
    .SYNOPSIS
        Bounded fetch of the aggregator's /metrics + parse. Tries HTTPS then HTTP (TLS
        rollout tolerance). Returns the per-pool gauge hashtable, or $null on any failure
        (so the caller PRESERVES last state -- an unreachable aggregator is not a "clear").
    .DESCRIPTION
        /metrics is an OPEN, hostname-free, non-sensitive read, so the HTTPS attempt uses
        -SkipCertificateCheck (encryption without leaf-pinning) on the trusted LAN -- this
        avoids the scriptblock-as-cert-callback trap on the alert-delivery path. The
        token-bearing PUSH path (the forwarder) pins the pool CA, where the secret flows.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$MetricsUrl,
        [Parameter()][int]$TimeoutSec = 10
    )
    foreach ($u in (Get-PoolMetricsCandidateUrl -MetricsUrl $MetricsUrl)) {
        try {
            $iwrArgs = @{ Uri = $u; TimeoutSec = $TimeoutSec; UseBasicParsing = $true; ErrorAction = 'Stop' }
            if ($u -like 'https://*') { $iwrArgs['SkipCertificateCheck'] = $true }
            $resp = Invoke-WebRequest @iwrArgs -Verbose:$false
            if ($resp.StatusCode -eq 200) {
                $parsed = ConvertFrom-PrometheusPoolGauge -MetricsText ([string]$resp.Content)
                if ($parsed -and $parsed.Count -gt 0) { return $parsed }
                # A 200 whose body has NO recognized yuruna_pool_* series is not a valid scrape
                # (proxy/error page, wrong endpoint, truncated body). Do NOT parse it as
                # "no pools alerting" -- fall through so the loop ends at $null and the caller
                # PRESERVES prior alert state instead of falsely clearing a live alert.
                Write-Verbose "pool metrics ${u}: 200 but no recognized yuruna_pool_* series; treating as unrecognized."
            } else {
                Write-Verbose "pool metrics ${u} HTTP $($resp.StatusCode)"
            }
        } catch {
            Write-Verbose "Get-PoolAlertGaugeState ${u}: $($_.Exception.Message)"
        }
    }
    return $null
}

function Get-PoolNotifierReadiness {
    <#
    .SYNOPSIS
        Classifies this host's pool-alert election. Returns @{ Ready; State; Reason } where
        State is 'ready' (transports.yml has a deliverable pool-alert subscriber, so this host
        alone notifies), 'unconfigured' (absent / empty / no matching subscriber -- the graceful
        "alerts stay gauge/Loki-only" state), or 'unreadable' (the file EXISTS but a read/parse
        error this cycle). 'unreadable' is kept distinct from 'unconfigured' so a transient read
        failure does not silently de-elect the host and strand already-queued messages -- the
        caller warns and still drains rather than collapsing to the unconfigured no-op.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][string]$EventCode = '',
        [Parameter()][string]$TransportsPath = ''
    )
    if (-not $EventCode) { $EventCode = $script:PoolAlertEventCode }
    if (-not $TransportsPath) {
        # test/modules/Test.PoolNotifier.psm1 -> test -> repo root; the LIVE transports.yml
        # (host-local, secret, gitignored) sits under test/status/extension/notification/.
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $TransportsPath = Join-Path $repoRoot 'test' -AdditionalChildPath 'status', 'extension', 'notification', 'transports.yml'
    }
    if (-not (Test-Path -LiteralPath $TransportsPath)) { return @{ Ready = $false; State = 'unconfigured'; Reason = 'pool.alert transport not configured on this host' } }
    if (-not (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) { return @{ Ready = $false; State = 'unconfigured'; Reason = 'ConvertFrom-Yaml unavailable' } }
    $cfg = $null
    try {
        $cfg = Get-Content -Raw -LiteralPath $TransportsPath -ErrorAction Stop | ConvertFrom-Yaml -Ordered
    } catch {
        # The file is present but could not be read/parsed this cycle (a flapping host-local
        # read). Report it as 'unreadable', distinct from 'unconfigured', so the caller keeps
        # this host elected enough to drain what it already queued.
        return @{ Ready = $false; State = 'unreadable'; Reason = "transports.yml unreadable this cycle: $($_.Exception.Message)" }
    }
    if (-not ($cfg -is [System.Collections.IDictionary])) { return @{ Ready = $false; State = 'unconfigured'; Reason = 'transports.yml empty or not a mapping' } }
    if (-not $cfg.Contains('subscribers') -or -not ($cfg['subscribers'] -is [System.Collections.IDictionary])) { return @{ Ready = $false; State = 'unconfigured'; Reason = 'no subscribers configured' } }
    if (-not $cfg['subscribers'].Contains($EventCode)) { return @{ Ready = $false; State = 'unconfigured'; Reason = "no $EventCode subscriber" } }
    foreach ($s in @($cfg['subscribers'][$EventCode])) {
        # Require a transport the notification extension can actually deliver (email today). A
        # subscriber with an unsupported transport would hit the extension's default branch ->
        # no delivery attempt -> a false 'ok' in the ledger, so it must NOT self-elect this host.
        if ($s -is [System.Collections.IDictionary] -and ([string]$s['transport'] -eq 'email') -and -not [string]::IsNullOrWhiteSpace([string]$s['address'])) {
            return @{ Ready = $true; State = 'ready'; Reason = '' }
        }
    }
    return @{ Ready = $false; State = 'unconfigured'; Reason = "no deliverable $EventCode subscriber" }
}

function Test-PoolNotifierReady {
    <#
    .SYNOPSIS
        True when this host is elected to notify (transports.yml has a deliverable pool-alert
        subscriber). A thin bool over Get-PoolNotifierReadiness for callers that only need the
        election bit; the cycle uses Get-PoolNotifierReadiness so it can tell a genuinely
        unconfigured host from a transient 'unreadable' this cycle.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][string]$EventCode = '',
        [Parameter()][string]$TransportsPath = ''
    )
    return (Get-PoolNotifierReadiness -EventCode $EventCode -TransportsPath $TransportsPath).Ready
}

function New-PoolAlertSpoolMessage {
    <#
    .SYNOPSIS
        PURE: build the spool message (subject + human body + structured fields) for a
        pool's degraded alert. id = pool-<pool>-<unix> so a re-fire is a distinct message
        while a single fire is one stable file.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure builder: returns a new in-memory message object and changes no external state, so ShouldProcess would be noise.')]
    [OutputType([System.Collections.IDictionary], [System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Pool,
        [Parameter(Mandatory)][hashtable]$GaugePool,
        [Parameter()][long]$UnixSeconds = 0,
        [Parameter()][string]$NowUtc = ''
    )
    if ($UnixSeconds -le 0) { $UnixSeconds = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    if (-not $NowUtc) { $NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    $frac    = if ($null -ne $GaugePool.healthyFraction) { [double]$GaugePool.healthyFraction } else { $null }
    $thr     = if ($null -ne $GaugePool.healthyThreshold) { [double]$GaugePool.healthyThreshold } else { $null }
    $healthy = if ($null -ne $GaugePool.membersHealthy) { [int]$GaugePool.membersHealthy } else { $null }
    $totalM  = if ($null -ne $GaugePool.membersTotal) { [int]$GaugePool.membersTotal } else { $null }
    $pct    = if ($null -ne $frac) { [int][math]::Round($frac * 100, 0) } else { 'n/a' }
    $thrPct = if ($null -ne $thr) { [int][math]::Round($thr * 100, 0) } else { 'n/a' }
    $hStr   = if ($null -ne $healthy) { [string]$healthy } else { '?' }
    $tStr   = if ($null -ne $totalM) { [string]$totalM } else { '?' }
    $subject = "Yuruna pool '$Pool' DEGRADED -- $hStr/$tStr members healthy ($pct%)"
    $body = @"
Yuruna pool degraded alert

Pool:              $Pool
Healthy members:   $hStr / $tStr ($pct%)
Healthy threshold: $thrPct%
Detected (UTC):    $NowUtc

The pool's healthy fraction has stayed below its configured quorum threshold long
enough to latch the advisory 'degraded' state, and the alert hysteresis has fired.
This is an ADVISORY pool alert: it does not pause or stop any host's cycles. Open
the pool dashboard to see which members are unreachable or failing.
"@
    return [ordered]@{
        id               = "pool-$Pool-$UnixSeconds"
        eventCode        = $script:PoolAlertEventCode
        pool             = $Pool
        event            = 'pool_alert_fired'
        healthyFraction  = $frac
        healthyThreshold = $thr
        membersHealthy   = $healthy
        membersTotal     = $totalM
        subject          = $subject
        body             = $body
        createdUtc       = $NowUtc
        attempts         = 0
    }
}

function Write-PoolSpoolMessage {
    <#
    .SYNOPSIS
        Atomically write a spool message to outgoing/<id>.json (temp + rename) on the NAS.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$SpoolRoot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Message
    )
    $outDir = Join-Path $SpoolRoot 'outgoing'
    # pool ids are DNS-label-safe already; sanitize anyway so a stray id never escapes the dir.
    $safe = ([string]$Message['id'] -replace '[^A-Za-z0-9._-]', '_')
    $path = Join-Path $outDir "$safe.json"
    if (-not $PSCmdlet.ShouldProcess($path, 'Write pool alert spool message')) { return $false }
    try {
        if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
        $tmp = "$path.tmp"
        [System.IO.File]::WriteAllText($tmp, ($Message | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
        return $true
    } catch { Write-Verbose "Write-PoolSpoolMessage: $($_.Exception.Message)"; return $false }
}

function Read-PoolNotifierState {
    <#
    .SYNOPSIS
        Read the per-host edge-detection state (runtime/pool.notifier.state.json):
        { pools: { <pool>: { lastActive; lastFiredUnix } } }. Empty shape when absent.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$StatePath)
    if (-not (Test-Path -LiteralPath $StatePath)) { return @{ pools = @{} } }
    try {
        $obj = Get-Content -Raw -LiteralPath $StatePath -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($obj -isnot [System.Collections.IDictionary]) { return @{ pools = @{} } }
        if (-not $obj.ContainsKey('pools') -or $obj['pools'] -isnot [System.Collections.IDictionary]) { $obj['pools'] = @{} }
        return $obj
    } catch { Write-Verbose "Read-PoolNotifierState: $($_.Exception.Message)"; return @{ pools = @{} } }
}

function Write-PoolNotifierState {
    <#
    .SYNOPSIS
        Persist the per-host edge-detection state (the @{ pools = ... } shape from
        Read-PoolNotifierState) to runtime/pool.notifier.state.json as UTF-8 (no BOM).
        Returns $true on success, $false on any write failure.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][hashtable]$State
    )
    if (-not $PSCmdlet.ShouldProcess($StatePath, 'Write pool notifier state')) { return $false }
    try {
        [System.IO.File]::WriteAllText($StatePath, ($State | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch { Write-Verbose "Write-PoolNotifierState: $($_.Exception.Message)"; return $false }
}

function Add-PoolAlertSpoolEntry {
    <#
    .SYNOPSIS
        Rising-edge detector + enqueuer. For each pool whose alert gauge went 0->1 (and
        whose last fire is older than RearmCooldownSeconds), write a spool message to
        outgoing/ and stamp lastFiredUnix. Updates lastActive for every pool seen this
        poll. The cooldown absorbs an aggregator restart's brief gauge re-latch (which the
        slow cycle cadence usually hides anyway). $State is MUTATED in place; returns the
        count enqueued.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable]$GaugeState,
        [Parameter(Mandatory)][hashtable]$State,
        [Parameter(Mandatory)][string]$SpoolRoot,
        [Parameter()][int]$RearmCooldownSeconds = 900,
        [Parameter()][string]$NowUtc = ''
    )
    if (-not $NowUtc) { $NowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    $nowUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (-not $State.ContainsKey('pools') -or $State['pools'] -isnot [System.Collections.IDictionary]) { $State['pools'] = @{} }
    $enqueued = 0
    foreach ($pool in @($GaugeState.Keys)) {
        $g = $GaugeState[$pool]
        $cur = [bool]$g.alertActive
        $prev = $false
        $lastFiredUnix = [long]0
        if ($State['pools'].ContainsKey($pool) -and ($State['pools'][$pool] -is [System.Collections.IDictionary])) {
            $prev = [bool]$State['pools'][$pool]['lastActive']
            if ($State['pools'][$pool].ContainsKey('lastFiredUnix')) { $lastFiredUnix = [long]$State['pools'][$pool]['lastFiredUnix'] }
        } else {
            $State['pools'][$pool] = @{ lastActive = $false; lastFiredUnix = [long]0 }
        }
        if ($cur -and -not $prev) {
            if (($lastFiredUnix -le 0) -or (($nowUnix - $lastFiredUnix) -ge $RearmCooldownSeconds)) {
                $msg = New-PoolAlertSpoolMessage -Pool $pool -GaugePool $g -UnixSeconds $nowUnix -NowUtc $NowUtc
                if (Write-PoolSpoolMessage -SpoolRoot $SpoolRoot -Message $msg -Confirm:$false) {
                    $enqueued++
                    $State['pools'][$pool]['lastFiredUnix'] = $nowUnix
                }
            }
        }
        $State['pools'][$pool]['lastActive'] = $cur
    }
    return $enqueued
}

function Send-PoolAlertViaExtension {
    <#
    .SYNOPSIS
        Deliver ONE spool message through the notification dispatcher (-Synchronous so the
        per-extension delivery outcome lands in the ledger), and CONFIRM via that ledger.
        Delivered iff >=1 new ledger record and none is 'fail'. The Resend POST is itself
        bounded (-TimeoutSec in the extension), so this never hangs. Readiness is
        pre-checked by the caller, so a "no subscriber -> false ok" can't reach here.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'Temporarily redirects the cross-module cycle-folder anchor ($global:__YurunaCycleFolder, set by Test.Log) so the dispatcher writes its delivery ledger into the notifier work dir; saved + restored in finally.')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Message,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter(Mandatory)][string]$Ledger
    )
    # Send-YurunaNotification, not the extensions' contract verb Send-Notification:
    # the extensions load -Global, so the bare name resolves to whichever transport
    # loaded last, which has no -Synchronous and no delivery ledger. This runs
    # in-process in the long-lived outer runner, so binding the wrong one loses
    # every pool alert after the first -- and quietly, because the catch below
    # downgrades it to a Write-Verbose.
    if (-not (Get-Command Send-YurunaNotification -ErrorAction SilentlyContinue)) { Write-Verbose 'Send-YurunaNotification unavailable'; return $false }
    $eventCode = if ($Message.Contains('eventCode')) { [string]$Message['eventCode'] } else { $script:PoolAlertEventCode }
    $subject = [string]$Message['subject']
    $body    = [string]$Message['body']
    $eventData = @{}
    foreach ($k in @('pool', 'event', 'healthyFraction', 'healthyThreshold', 'membersHealthy', 'membersTotal', 'id')) {
        if ($Message.Contains($k)) { $eventData[$k] = $Message[$k] }
    }
    $before = 0
    if (Test-Path -LiteralPath $Ledger) { $before = @(Get-Content -LiteralPath $Ledger -ErrorAction SilentlyContinue).Count }
    $saved = $global:__YurunaCycleFolder
    $global:__YurunaCycleFolder = $WorkDir
    try {
        Send-YurunaNotification -EventCode $eventCode -EventMessage $subject -EventNote $body -EventData $eventData -Synchronous -ErrorAction SilentlyContinue | Out-Null
    } catch {
        Write-Verbose "Send-PoolAlertViaExtension: $($_.Exception.Message)"
    } finally {
        $global:__YurunaCycleFolder = $saved
    }
    # Confirmation is from the dispatcher's delivery ledger (the channel built for exactly
    # this question). The ledger write is best-effort: if the email sent but the ledger
    # append failed, this returns $false and the message is retried -> a duplicate alert.
    # That is the spool's accepted at-least-once contract (favor a rare duplicate over a
    # silently dropped degraded alert).
    if (-not (Test-Path -LiteralPath $Ledger)) { return $false }
    $lines = @(Get-Content -LiteralPath $Ledger -ErrorAction SilentlyContinue)
    if ($lines.Count -le $before) { return $false }
    $okCount = 0
    foreach ($ln in $lines[$before..($lines.Count - 1)]) {
        try {
            $rec = $ln | ConvertFrom-Json -ErrorAction Stop
            if ($rec.status -eq 'fail') { return $false }
            if ($rec.status -eq 'ok') { $okCount++ }
        } catch { $null = $_ }
    }
    return ($okCount -ge 1)
}

function Invoke-PoolNotifierDelivery {
    <#
    .SYNOPSIS
        Drain outgoing/: claim each message (atomic rename to sending/), deliver + confirm,
        then move to delivered/ -- or back to outgoing/ (retry next cycle), then failed/
        after MaxAttempts. Bounded by MaxMessages per call. Returns @{delivered;failed;retried}.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Best-effort spool drain; each filesystem move is guarded + never throws back into the cycle-end hook.')]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$SpoolRoot,
        [Parameter(Mandatory)][string]$WorkDir,
        [Parameter()][int]$MaxMessages = 25,
        [Parameter()][int]$MaxAttempts = 5,
        [Parameter()][int]$ReclaimGraceSeconds = 600
    )
    $result = @{ delivered = 0; failed = 0; retried = 0 }
    $outDir  = Join-Path $SpoolRoot 'outgoing'
    $sendDir = Join-Path $SpoolRoot 'sending'
    $doneDir = Join-Path $SpoolRoot 'delivered'
    $failDir = Join-Path $SpoolRoot 'failed'
    if (-not (Test-Path -LiteralPath $outDir)) { return $result }
    foreach ($d in @($sendDir, $doneDir, $failDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
    if (-not (Test-Path -LiteralPath $WorkDir)) { New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null }
    # Reclaim orphaned claims: a drain that died (e.g. a watchdog SIGKILL) between the
    # claim-rename and the terminal move strands a message in sending/ -- otherwise lost
    # forever (only outgoing/ is scanned below). Move any sending/ entry whose claim is
    # older than the reclaim grace back to outgoing/ so it is retried. The grace avoids
    # stealing a genuinely in-flight claim from a second notifier (the shared-queue
    # belt-and-suspenders). Age is measured from the claimedUtc the claimer stamps into
    # the message (claim loop below), NOT the file's LastWriteTime: the claim-rename
    # preserves the message's content-write mtime, so a message enqueued long ago and
    # claimed a moment ago would look instantly stale and be reclaimed + double-delivered,
    # and a NAS whose clock differs from this host's could reclaim never or always.
    # claimedUtc shares the same UtcNow clock as the cutoff. A message with no claimedUtc
    # (an older drain, or one that died between the rename and the stamp) falls back to the
    # file mtime in UTC -- coarser, but still bounded.
    $reclaimCutoffUtc = (Get-Date).ToUniversalTime().AddSeconds(-$ReclaimGraceSeconds)
    $utcStyles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    foreach ($stale in @(Get-ChildItem -LiteralPath $sendDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $claimedUtc  = [datetime]::MinValue
        $haveClaimed = $false
        try {
            $sm = Get-Content -Raw -LiteralPath $stale.FullName -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if (($sm -is [System.Collections.IDictionary]) -and $sm.ContainsKey('claimedUtc')) {
                $parsed = [datetime]::MinValue
                if ([datetime]::TryParse([string]$sm['claimedUtc'], [cultureinfo]::InvariantCulture, $utcStyles, [ref]$parsed)) {
                    $claimedUtc = $parsed; $haveClaimed = $true
                }
            }
        } catch { $null = $_ }
        if (-not $haveClaimed) { $claimedUtc = $stale.LastWriteTimeUtc }
        if ($claimedUtc -lt $reclaimCutoffUtc) {
            try { Move-Item -LiteralPath $stale.FullName -Destination (Join-Path $outDir $stale.Name) -Force -ErrorAction Stop } catch { $null = $_ }
        }
    }
    $ledger = Join-Path $WorkDir 'notification.delivery.json'
    $files = @(Get-ChildItem -LiteralPath $outDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First $MaxMessages)
    foreach ($f in $files) {
        $claim = Join-Path $sendDir $f.Name
        # Atomic claim: the single notifier normally wins uncontested; the rename is the
        # belt-and-suspenders guard if two hosts are ever both configured.
        try { Move-Item -LiteralPath $f.FullName -Destination $claim -Force -ErrorAction Stop } catch { Write-Verbose "claim failed for $($f.Name): $($_.Exception.Message)"; continue }
        $msg = $null
        try { $msg = Get-Content -Raw -LiteralPath $claim -ErrorAction Stop | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $null = $_ }
        if (-not ($msg -is [System.Collections.IDictionary])) {
            try { Move-Item -LiteralPath $claim -Destination (Join-Path $failDir $f.Name) -Force -ErrorAction Stop } catch { $null = $_ }
            $result.failed++
            continue
        }
        # Stamp the claim time (UTC) into the message before attempting delivery, so if this
        # drain dies mid-flight the reclaim above measures the grace from when the message was
        # claimed rather than the file's preserved content-write mtime. Best-effort: on a write
        # failure the reclaim falls back to the file mtime.
        $msg['claimedUtc'] = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        try { [System.IO.File]::WriteAllText($claim, ($msg | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false)) } catch { $null = $_ }
        if (Send-PoolAlertViaExtension -Message $msg -WorkDir $WorkDir -Ledger $ledger) {
            try { Move-Item -LiteralPath $claim -Destination (Join-Path $doneDir $f.Name) -Force -ErrorAction Stop } catch { $null = $_ }
            $result.delivered++
            continue
        }
        $attempts = if ($msg.ContainsKey('attempts')) { [int]$msg['attempts'] } else { 0 }
        $attempts++
        $msg['attempts'] = $attempts
        $msg['lastAttemptUtc'] = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        try { [System.IO.File]::WriteAllText($claim, ($msg | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false)) } catch { $null = $_ }
        if ($attempts -ge $MaxAttempts) {
            try { Move-Item -LiteralPath $claim -Destination (Join-Path $failDir $f.Name) -Force -ErrorAction Stop } catch { $null = $_ }
            $result.failed++
        } else {
            try { Move-Item -LiteralPath $claim -Destination (Join-Path $outDir $f.Name) -Force -ErrorAction Stop } catch { $null = $_ }
            $result.retried++
        }
    }
    return $result
}

function Invoke-PoolNotifierCycle {
    <#
    .SYNOPSIS
        One bounded pass of the host-side pool notifier (the cycle-end hook). Self-elects
        via Get-PoolNotifierReadiness; reads the aggregator's latched alert gauge over HTTP;
        enqueues rising edges to the NAS spool; delivers queued messages and moves them to
        delivered/ on confirm. Best-effort + fully bounded; never throws. Returns a summary
        hashtable for logging.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Best-effort cycle-end hook orchestrator; the state-changing writers it calls each gate ShouldProcess (invoked with -Confirm:$false) and it never throws.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
        Justification = 'No global writes here; the cycle-folder redirect is isolated to Send-PoolAlertViaExtension.')]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Config,
        [Parameter()][int]$MetricsPort = 9400,
        [Parameter()][int]$HttpTimeoutSec = 10,
        [Parameter()][int]$MaxMessages = 25
    )
    $summary = @{ ran = $false; ready = $false; enqueued = 0; delivered = 0; failed = 0; retried = 0; reason = '' }
    try {
        if (-not (Get-Command Get-YurunaPoolStorageConfig -ErrorAction SilentlyContinue)) { $summary.reason = 'poolStorage module unavailable'; return $summary }
        $psCfg = Get-YurunaPoolStorageConfig -Config $Config
        $spoolRoot = Get-PoolNotifierSpoolRoot -Config $psCfg
        if (-not $spoolRoot) { $summary.reason = 'poolStorage not configured (no NAS queue)'; return $summary }
        if ((Get-Command Test-YurunaPoolStorageMounted -ErrorAction SilentlyContinue) -and -not (Test-YurunaPoolStorageMounted -Config $psCfg)) {
            $summary.reason = 'NAS not mounted yet (drain mounts it; retry next cycle)'; return $summary
        }
        # Self-elect from transports.yml. 'unconfigured' (absent / no matching subscriber) is
        # the clean gauge/Loki-only no-op. 'unreadable' (present but a transient read/parse
        # failure this cycle) must NOT silently de-elect the host: warn and still drain what it
        # already queued, but skip enqueuing new edges (electing + reading the gauge both want
        # a healthy config).
        $readiness = Get-PoolNotifierReadiness
        if ($readiness.State -eq 'unconfigured') { $summary.reason = $readiness.Reason; return $summary }
        $unreadable = ($readiness.State -eq 'unreadable')
        if ($unreadable) {
            Write-Warning "Invoke-PoolNotifierCycle: $($readiness.Reason); draining already-queued messages without enqueuing new edges."
            $summary.reason = 'transports.yml unreadable this cycle'
        } else {
            $summary.ready = $true
        }

        $runtimeDir = $env:YURUNA_RUNTIME_DIR
        if ([string]::IsNullOrWhiteSpace($runtimeDir)) { $summary.reason = 'YURUNA_RUNTIME_DIR unset'; return $summary }
        $null = Initialize-PoolNotifierSpool -SpoolRoot $spoolRoot -Confirm:$false

        if (-not $unreadable) {
            # Resolve the aggregator's /metrics endpoint on the shared caching-proxy.
            $ip = ''
            if (Get-Command Read-CachingProxyState -ErrorAction SilentlyContinue) {
                try { $st = Read-CachingProxyState; if ($st -and $st.ipAddress) { $ip = [string]$st.ipAddress } } catch { $null = $_ }
            }
            if ([string]::IsNullOrWhiteSpace($ip) -and $env:YURUNA_CACHING_PROXY_IP) { $ip = $env:YURUNA_CACHING_PROXY_IP.Trim() }
            if ([string]::IsNullOrWhiteSpace($ip)) { $summary.reason = 'no caching-proxy IP (cannot reach aggregator)'; return $summary }
            $metricsUrl = "http://${ip}:$MetricsPort/metrics"

            $gauge = Get-PoolAlertGaugeState -MetricsUrl $metricsUrl -TimeoutSec $HttpTimeoutSec
            if ($null -eq $gauge) { $summary.reason = "aggregator metrics unreachable ($metricsUrl)"; return $summary }

            $statePath = Join-Path $runtimeDir 'pool.notifier.state.json'
            $state = Read-PoolNotifierState -StatePath $statePath
            $summary.enqueued = Add-PoolAlertSpoolEntry -GaugeState $gauge -State $state -SpoolRoot $spoolRoot
            $null = Write-PoolNotifierState -StatePath $statePath -State $state -Confirm:$false
        }

        $workDir = Join-Path $runtimeDir 'pool.notifier'
        $deliv = Invoke-PoolNotifierDelivery -SpoolRoot $spoolRoot -WorkDir $workDir -MaxMessages $MaxMessages
        $summary.delivered = $deliv.delivered
        $summary.failed    = $deliv.failed
        $summary.retried   = $deliv.retried
        $summary.ran = $true
    } catch {
        $summary.reason = "error: $($_.Exception.Message)"
        Write-Verbose "Invoke-PoolNotifierCycle: $($_.Exception.Message)"
    }
    return $summary
}

function Write-PoolNotifierSetupNotice {
    <#
    .SYNOPSIS
        Surface, at host setup, whether THIS host still needs the pool-alert notification
        transport configured. Bounded + CI-safe (Write-Output / Write-Warning only -- no
        prompt, never throws). Prints an actionable notice only on a poolStorage-replicating
        host (a pool-services candidate) where the pool.alert transport is NOT yet set up, so
        the operator on the caching-proxy + dashboards host does not silently skip it. No-op
        when poolStorage is unconfigured (not a notifier host) or the transport is ready.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][string]$ConfigPath = '')
    try {
        if (-not (Get-Command Get-YurunaPoolStorageConfig -ErrorAction SilentlyContinue)) { return $false }
        $cfgDoc = $null
        if ($ConfigPath -and (Test-Path -LiteralPath $ConfigPath) -and (Get-Command ConvertFrom-Yaml -ErrorAction SilentlyContinue)) {
            try { $cfgDoc = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Yaml -Ordered } catch { $null = $_ }
        }
        # Replicate-gated (no -IgnoreReplicate): null unless this host replicates to the NAS,
        # so only a pool-services candidate gets the reminder.
        $psCfg = Get-YurunaPoolStorageConfig -Config $cfgDoc
        if (-not $psCfg) { return $false }
        if (Test-PoolNotifierReady) {
            # Write-Information (not Write-Output): a [bool]-contract function must not emit
            # status to the pipeline (it would pollute $x = Func and is swallowed by the
            # caller's $null = assignment); the Information stream survives both.
            Write-Information 'Pool alerting: the pool.alert notification transport is configured; this host will deliver pool degraded alerts.' -InformationAction Continue
            return $true
        }
        Write-Warning @'
Pool alerting is NOT configured on this host.
If this is the host that runs the caching-proxy + dashboards, it self-elects as the pool
alert notifier -- but only once the transport is set up. Add a pool.alert subscriber to
test/status/extension/notification/transports.yml, for example:

  subscribers:
    pool.alert:
      - transport: email
        address: you@example.com

Until then, pool DEGRADED alerts stay visible on the dashboard but are not delivered.
'@
        return $false
    } catch { Write-Verbose "Write-PoolNotifierSetupNotice: $($_.Exception.Message)"; return $false }
}

Export-ModuleMember -Function `
    Get-PoolNotifierSpoolRoot, Initialize-PoolNotifierSpool, ConvertFrom-PrometheusPoolGauge, `
    Get-PoolMetricsCandidateUrl, Get-PoolAlertGaugeState, Get-PoolNotifierReadiness, `
    Test-PoolNotifierReady, New-PoolAlertSpoolMessage, `
    Write-PoolSpoolMessage, Read-PoolNotifierState, Write-PoolNotifierState, `
    Add-PoolAlertSpoolEntry, Send-PoolAlertViaExtension, Invoke-PoolNotifierDelivery, `
    Invoke-PoolNotifierCycle, Write-PoolNotifierSetupNotice
