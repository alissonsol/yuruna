<#PSScriptInfo
.VERSION 2026.07.07
.GUID 422d8f14-9a73-4e52-8c61-2d9b3a7e1f04
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool notifier pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Pester coverage for the pure + filesystem parts of Test.PoolNotifier.psm1: the
    Prometheus gauge parser, the spool message builder, the rising-edge detector +
    cooldown, and the transport-readiness gate. The HTTP fetch + the live
    Send-Notification delivery are integration-verified separately.
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.PoolNotifier.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning 'powershell-yaml unavailable.' }

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because = '') if ($Condition) { throw "Expected false. $Because" } }
function Assert-Null  { param($Actual, [string]$Because = '') if ($null -ne $Actual) { throw "Expected null got [$Actual]. $Because" } }

function New-TempDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: creates a throwaway temp directory, removed in finally; not user-facing state.')]
    [CmdletBinding()]
    param()
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("pn-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

Describe 'ConvertFrom-PrometheusPoolGauge (parse the gating gauges)' {
    $text = @'
# HELP yuruna_pool_alert_active ...
# TYPE yuruna_pool_alert_active gauge
yuruna_pool_alert_active{pool="lab"} 1
yuruna_pool_degraded{pool="lab"} 1
yuruna_pool_healthy_fraction{pool="lab"} 0.25
yuruna_pool_healthy_threshold{pool="lab"} 0.5
yuruna_pool_members_healthy{pool="lab"} 1
yuruna_pool_members_total{pool="lab"} 4
yuruna_pool_degraded{pool="wild"} 1
yuruna_pool_healthy_fraction{pool="wild"} 0
yuruna_pool_host_status{pool="lab",hostId="42aa"} 3
'@
    $pools = ConvertFrom-PrometheusPoolGauge -MetricsText $text
    It 'parses an authored, firing pool' {
        Assert-True  $pools['lab'].alertActive 'lab alertActive'
        Assert-True  $pools['lab'].degraded 'lab degraded'
        Assert-Equal -Expected 0.25 -Actual $pools['lab'].healthyFraction -Because 'lab fraction'
        Assert-Equal -Expected 0.5  -Actual $pools['lab'].healthyThreshold -Because 'lab threshold'
        Assert-Equal -Expected 1 -Actual $pools['lab'].membersHealthy -Because 'lab healthy'
        Assert-Equal -Expected 4 -Actual $pools['lab'].membersTotal -Because 'lab total'
    }
    It 'treats a pool with no alert_active series as not alerting (un-authored)' {
        Assert-True  $pools['wild'].degraded 'wild degraded gauge present'
        Assert-False $pools['wild'].alertActive 'wild never alerts (no alert_active line)'
    }
    It 'ignores unrelated/labelled series and an empty body' {
        Assert-True (-not $pools.ContainsKey('')) 'no empty pool key from host_status'
        Assert-Equal -Expected 0 -Actual (ConvertFrom-PrometheusPoolGauge -MetricsText '').Count -Because 'empty -> no pools'
    }
}

Describe 'New-PoolAlertSpoolMessage (message shape)' {
    $g = @{ pool = 'lab'; alertActive = $true; healthyFraction = 0.25; healthyThreshold = 0.5; membersHealthy = 1; membersTotal = 4 }
    $m = New-PoolAlertSpoolMessage -Pool 'lab' -GaugePool $g -UnixSeconds 1700000000 -NowUtc '2026-01-01T00:00:00Z'
    It 'builds a stable id + the pool.alert event code + structured fields' {
        Assert-Equal -Expected 'pool-lab-1700000000' -Actual $m['id'] -Because 'id'
        Assert-Equal -Expected 'pool.alert' -Actual $m['eventCode'] -Because 'eventCode'
        Assert-Equal -Expected 'pool_alert_fired' -Actual $m['event'] -Because 'event'
        Assert-Equal -Expected 1 -Actual $m['membersHealthy'] -Because 'membersHealthy'
        Assert-Equal -Expected 4 -Actual $m['membersTotal'] -Because 'membersTotal'
        Assert-Equal -Expected 0 -Actual $m['attempts'] -Because 'attempts starts at 0'
        Assert-True ($m['subject'] -like "*DEGRADED*1/4*") 'subject carries the fraction'
    }
}

Describe 'Add-PoolAlertSpoolEntry (rising-edge detection + cooldown)' {
    It 'enqueues on a 0->1 edge, not while it stays 1, and clears on 1->0' {
        $root = New-TempDir
        try {
            $state = @{ pools = @{} }
            $gaugeOn  = @{ lab = @{ pool = 'lab'; alertActive = $true;  healthyFraction = 0.2; healthyThreshold = 0.5; membersHealthy = 1; membersTotal = 5 } }
            $gaugeOff = @{ lab = @{ pool = 'lab'; alertActive = $false; healthyFraction = 0.9; healthyThreshold = 0.5; membersHealthy = 5; membersTotal = 5 } }

            $n1 = Add-PoolAlertSpoolEntry -GaugeState $gaugeOn -State $state -SpoolRoot $root
            Assert-Equal -Expected 1 -Actual $n1 -Because 'rising edge enqueues one'
            Assert-True $state['pools']['lab']['lastActive'] 'lastActive latched true'
            Assert-Equal -Expected 1 -Actual (@(Get-ChildItem -LiteralPath (Join-Path $root 'outgoing') -Filter '*.json' -File).Count) -Because 'one outgoing file'

            $n2 = Add-PoolAlertSpoolEntry -GaugeState $gaugeOn -State $state -SpoolRoot $root
            Assert-Equal -Expected 0 -Actual $n2 -Because 'still-active does not re-enqueue'

            $n3 = Add-PoolAlertSpoolEntry -GaugeState $gaugeOff -State $state -SpoolRoot $root
            Assert-Equal -Expected 0 -Actual $n3 -Because 'falling edge does not enqueue'
            Assert-False $state['pools']['lab']['lastActive'] 'lastActive cleared'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'suppresses a re-fire within the cooldown but allows it once the cooldown elapses' {
        $root = New-TempDir
        try {
            $state = @{ pools = @{} }
            $on  = @{ lab = @{ pool = 'lab'; alertActive = $true;  healthyFraction = 0.2; healthyThreshold = 0.5; membersHealthy = 1; membersTotal = 5 } }
            $off = @{ lab = @{ pool = 'lab'; alertActive = $false; healthyFraction = 0.9; healthyThreshold = 0.5; membersHealthy = 5; membersTotal = 5 } }

            Assert-Equal -Expected 1 -Actual (Add-PoolAlertSpoolEntry -GaugeState $on -State $state -SpoolRoot $root) -Because 'first fire'
            $null = Add-PoolAlertSpoolEntry -GaugeState $off -State $state -SpoolRoot $root  # clear
            # Re-rise immediately: default 900s cooldown suppresses it (absorbs aggregator restart flap).
            Assert-Equal -Expected 0 -Actual (Add-PoolAlertSpoolEntry -GaugeState $on -State $state -SpoolRoot $root) -Because 're-fire suppressed by cooldown'

            # With cooldown 0 the re-rise fires (proves it is the cooldown, not the edge logic).
            $null = Add-PoolAlertSpoolEntry -GaugeState $off -State $state -SpoolRoot $root  # clear again
            Assert-Equal -Expected 1 -Actual (Add-PoolAlertSpoolEntry -GaugeState $on -State $state -SpoolRoot $root -RearmCooldownSeconds 0) -Because 're-fire allowed when cooldown elapsed'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Test-PoolNotifierReady (self-election gate)' {
    $dir = New-TempDir
    try {
        $configured = Join-Path $dir 'configured.yml'
        $empty      = Join-Path $dir 'empty.yml'
        Set-Content -LiteralPath $configured -Value "subscribers:`n  pool.alert:`n    - transport: email`n      address: ops@example.com`n" -Encoding utf8
        Set-Content -LiteralPath $empty      -Value "subscribers:`n  pool.alert: []`n  cycle.failure:`n    - transport: email`n      address: ops@example.com`n" -Encoding utf8
        It 'is true when a pool.alert subscriber has a non-empty address' {
            Assert-True (Test-PoolNotifierReady -TransportsPath $configured) 'configured -> ready'
        }
        It 'is false when pool.alert is empty (even if other events are configured)' {
            Assert-False (Test-PoolNotifierReady -TransportsPath $empty) 'no pool.alert subscriber -> not ready'
        }
        It 'is false for a non-email transport (extension cannot deliver -> would false-ok)' {
            $webhook = Join-Path $dir 'webhook.yml'
            Set-Content -LiteralPath $webhook -Value "subscribers:`n  pool.alert:`n    - transport: webhook`n      address: https://hooks.example.com/x`n" -Encoding utf8
            Assert-False (Test-PoolNotifierReady -TransportsPath $webhook) 'unsupported transport -> not ready'
        }
        It 'is false when the transports file is absent' {
            Assert-False (Test-PoolNotifierReady -TransportsPath (Join-Path $dir 'nope.yml')) 'missing -> not ready'
        }
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-PoolMetricsCandidateUrl (TLS rollout tolerance)' {
    It 'tries HTTPS first then HTTP for an http(s) URL' {
        $u = Get-PoolMetricsCandidateUrl -MetricsUrl 'http://10.0.0.5:9400/metrics'
        Assert-Equal -Expected 'https://10.0.0.5:9400/metrics' -Actual $u[0] -Because 'https first'
        Assert-Equal -Expected 'http://10.0.0.5:9400/metrics'  -Actual $u[1] -Because 'http fallback'
        $h = Get-PoolMetricsCandidateUrl -MetricsUrl 'https://10.0.0.5:9400/metrics'
        Assert-Equal -Expected 'https://10.0.0.5:9400/metrics' -Actual $h[0] -Because 'https stays https first'
        Assert-Equal -Expected 'http://10.0.0.5:9400/metrics'  -Actual $h[1] -Because 'plus http fallback'
    }
}

Describe 'Get-PoolNotifierSpoolRoot' {
    It 'is null without a pool storage config and joins notifications onto LocalPath otherwise' {
        Assert-Null (Get-PoolNotifierSpoolRoot -Config $null) 'null config -> null'
        $root = Get-PoolNotifierSpoolRoot -Config ([pscustomobject]@{ LocalPath = '/mnt/ypool-nas' })
        Assert-Equal -Expected (Join-Path '/mnt/ypool-nas' 'notifications') -Actual $root -Because 'LocalPath/notifications'
    }
}

Describe 'Invoke-PoolNotifierDelivery: claim stamps claimedUtc and reclaim measures grace from it' {
    It 'stamps claimedUtc into a claimed message before delivery' {
        $root = New-TempDir
        try {
            $out = Join-Path $root 'outgoing'; New-Item -ItemType Directory -Force -Path $out | Out-Null
            $msgPath = Join-Path $out 'pool-lab-1.json'
            Set-Content -LiteralPath $msgPath -Value '{"id":"pool-lab-1","eventCode":"pool.alert"}' -Encoding utf8
            Mock -ModuleName Test.PoolNotifier Send-PoolAlertViaExtension { $false }
            $null = Invoke-PoolNotifierDelivery -SpoolRoot $root -WorkDir (Join-Path $root 'work')
            # Delivery failed (mock) so the message retried back to outgoing/ -- read it and
            # confirm the claim loop stamped claimedUtc en route.
            $retried = Get-Content -Raw -LiteralPath $msgPath | ConvertFrom-Json -AsHashtable
            Assert-True ($retried.ContainsKey('claimedUtc')) 'claim stamps claimedUtc'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'does NOT reclaim a freshly-claimed message even when its file mtime is old' {
        $root = New-TempDir
        try {
            $null = Join-Path $root 'outgoing' | ForEach-Object { New-Item -ItemType Directory -Force -Path $_ }
            $send = Join-Path $root 'sending'; New-Item -ItemType Directory -Force -Path $send | Out-Null
            $claim = Join-Path $send 'pool-lab-2.json'
            $nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            Set-Content -LiteralPath $claim -Value ('{"id":"pool-lab-2","claimedUtc":"' + $nowUtc + '"}') -Encoding utf8
            (Get-Item -LiteralPath $claim).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-1)  # old mtime
            Mock -ModuleName Test.PoolNotifier Send-PoolAlertViaExtension { $false }
            $r = Invoke-PoolNotifierDelivery -SpoolRoot $root -WorkDir (Join-Path $root 'work')
            # Fresh claimedUtc within the 600s grace -> not reclaimed; outgoing/ stays empty so
            # nothing drains. (mtime-based reclaim WOULD have reclaimed + retried it.)
            Assert-Equal -Expected 0 -Actual $r.retried -Because 'fresh claim not reclaimed'
            Assert-True (Test-Path -LiteralPath $claim) 'message stays in sending/'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'reclaims an orphaned claim by an old claimedUtc even when its file mtime is fresh' {
        $root = New-TempDir
        try {
            $null = Join-Path $root 'outgoing' | ForEach-Object { New-Item -ItemType Directory -Force -Path $_ }
            $send = Join-Path $root 'sending'; New-Item -ItemType Directory -Force -Path $send | Out-Null
            $claim = Join-Path $send 'pool-lab-3.json'
            $oldUtc = (Get-Date).ToUniversalTime().AddHours(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            Set-Content -LiteralPath $claim -Value ('{"id":"pool-lab-3","claimedUtc":"' + $oldUtc + '"}') -Encoding utf8
            (Get-Item -LiteralPath $claim).LastWriteTimeUtc = (Get-Date).ToUniversalTime()  # fresh mtime
            Mock -ModuleName Test.PoolNotifier Send-PoolAlertViaExtension { $false }
            $r = Invoke-PoolNotifierDelivery -SpoolRoot $root -WorkDir (Join-Path $root 'work')
            # Old claimedUtc past the grace -> reclaimed to outgoing/, then drained (delivery
            # mocked false) -> retried. (mtime-based reclaim would have SKIPPED it -> retried 0.)
            Assert-Equal -Expected 1 -Actual $r.retried -Because 'old claim reclaimed then drained'
            Assert-False (Test-Path -LiteralPath $claim) 'reclaimed out of sending/ (directly observable)'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'falls back to the file mtime when a claim carries no claimedUtc stamp' {
        $root = New-TempDir
        try {
            $null = Join-Path $root 'outgoing' | ForEach-Object { New-Item -ItemType Directory -Force -Path $_ }
            $send = Join-Path $root 'sending'; New-Item -ItemType Directory -Force -Path $send | Out-Null
            $claim = Join-Path $send 'pool-lab-4.json'
            Set-Content -LiteralPath $claim -Value '{"id":"pool-lab-4"}' -Encoding utf8   # no claimedUtc
            (Get-Item -LiteralPath $claim).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddHours(-1)  # old mtime
            Mock -ModuleName Test.PoolNotifier Send-PoolAlertViaExtension { $false }
            $r = Invoke-PoolNotifierDelivery -SpoolRoot $root -WorkDir (Join-Path $root 'work')
            Assert-Equal -Expected 1 -Actual $r.retried -Because 'unstamped + old mtime -> reclaimed via mtime fallback'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-PoolNotifierReadiness distinguishes ready / unconfigured / unreadable' {
    $dir = New-TempDir
    try {
        $configured = Join-Path $dir 'configured.yml'
        Set-Content -LiteralPath $configured -Value "subscribers:`n  pool.alert:`n    - transport: email`n      address: ops@example.com`n" -Encoding utf8
        It 'reports ready for a configured pool.alert email subscriber' {
            $r = Get-PoolNotifierReadiness -TransportsPath $configured
            Assert-Equal -Expected 'ready' -Actual $r.State -Because 'configured -> ready'
            Assert-True $r.Ready 'Ready flag true'
        }
        It 'reports unconfigured for an absent transports file' {
            $r = Get-PoolNotifierReadiness -TransportsPath (Join-Path $dir 'nope.yml')
            Assert-Equal -Expected 'unconfigured' -Actual $r.State -Because 'absent -> unconfigured'
            Assert-False $r.Ready 'not ready'
        }
        It 'reports unconfigured for a present file with no pool.alert subscriber' {
            $empty = Join-Path $dir 'empty.yml'
            Set-Content -LiteralPath $empty -Value "subscribers:`n  pool.alert: []`n" -Encoding utf8
            $r = Get-PoolNotifierReadiness -TransportsPath $empty
            Assert-Equal -Expected 'unconfigured' -Actual $r.State -Because 'no subscriber -> unconfigured'
        }
        It 'reports unreadable (distinct from unconfigured) for a present file whose parse throws' {
            $bad = Join-Path $dir 'bad.yml'
            Set-Content -LiteralPath $bad -Value 'subscribers: {oops' -Encoding utf8
            Mock -ModuleName Test.PoolNotifier ConvertFrom-Yaml { throw 'parse boom' }
            $r = Get-PoolNotifierReadiness -TransportsPath $bad
            Assert-Equal -Expected 'unreadable' -Actual $r.State -Because 'present but parse-throws -> unreadable'
            Assert-False $r.Ready 'unreadable is not ready'
        }
    } finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Invoke-PoolNotifierCycle keeps draining on an unreadable transport but no-ops when unconfigured' {
    BeforeAll {
        # Shim the poolStorage cmdlets the cycle self-guards on when that module is not loaded
        # (the isolated Invoke-Pester case), so the Mocks below have a target. The Mocks then
        # force the values regardless of whether the real module leaked into the session.
        if (-not (Get-Command Get-YurunaPoolStorageConfig -ErrorAction SilentlyContinue)) {
            function global:Get-YurunaPoolStorageConfig { param($Config) $null = $Config }
            $script:pnStorageShim = $true
        }
        if (-not (Get-Command Test-YurunaPoolStorageMounted -ErrorAction SilentlyContinue)) {
            function global:Test-YurunaPoolStorageMounted { param($Config) $null = $Config; $true }
            $script:pnMountShim = $true
        }
    }
    AfterAll {
        if ($script:pnStorageShim) { Remove-Item Function:\Get-YurunaPoolStorageConfig -Force -ErrorAction SilentlyContinue }
        if ($script:pnMountShim)   { Remove-Item Function:\Test-YurunaPoolStorageMounted -Force -ErrorAction SilentlyContinue }
    }
    It 'warns + drains already-queued messages when readiness is unreadable' {
        $saved = $env:YURUNA_RUNTIME_DIR
        try {
            $env:YURUNA_RUNTIME_DIR = 'pn-rt'
            Mock -ModuleName Test.PoolNotifier Get-YurunaPoolStorageConfig { @{ LocalPath = 'x' } }
            Mock -ModuleName Test.PoolNotifier Test-YurunaPoolStorageMounted { $true }
            Mock -ModuleName Test.PoolNotifier Get-PoolNotifierSpoolRoot { 'pn-spool' }
            Mock -ModuleName Test.PoolNotifier Get-PoolNotifierReadiness { @{ Ready = $false; State = 'unreadable'; Reason = 'transports.yml unreadable this cycle: boom' } }
            Mock -ModuleName Test.PoolNotifier Initialize-PoolNotifierSpool { }
            Mock -ModuleName Test.PoolNotifier Invoke-PoolNotifierDelivery { @{ delivered = 2; failed = 0; retried = 0 } }
            $s = Invoke-PoolNotifierCycle -WarningAction SilentlyContinue
            Assert-True  $s.ran 'ran despite the unreadable transport'
            Assert-False $s.ready 'not elected-ready on unreadable'
            Assert-Equal -Expected 'transports.yml unreadable this cycle' -Actual $s.reason -Because 'distinct reason'
            Assert-Equal -Expected 2 -Actual $s.delivered -Because 'already-queued messages drained'
            Assert-MockCalled -ModuleName Test.PoolNotifier Invoke-PoolNotifierDelivery -Times 1 -Exactly -Scope It
        } finally { $env:YURUNA_RUNTIME_DIR = $saved }
    }
    It 'does NOT drain when readiness is unconfigured (clean no-op)' {
        $saved = $env:YURUNA_RUNTIME_DIR
        try {
            $env:YURUNA_RUNTIME_DIR = 'pn-rt'
            Mock -ModuleName Test.PoolNotifier Get-YurunaPoolStorageConfig { @{ LocalPath = 'x' } }
            Mock -ModuleName Test.PoolNotifier Test-YurunaPoolStorageMounted { $true }
            Mock -ModuleName Test.PoolNotifier Get-PoolNotifierSpoolRoot { 'pn-spool' }
            Mock -ModuleName Test.PoolNotifier Get-PoolNotifierReadiness { @{ Ready = $false; State = 'unconfigured'; Reason = 'pool.alert transport not configured on this host' } }
            Mock -ModuleName Test.PoolNotifier Initialize-PoolNotifierSpool { }
            Mock -ModuleName Test.PoolNotifier Invoke-PoolNotifierDelivery { @{ delivered = 9; failed = 0; retried = 0 } }
            $s = Invoke-PoolNotifierCycle
            Assert-False $s.ran 'unconfigured -> clean no-op, did not run'
            Assert-Equal -Expected 'pool.alert transport not configured on this host' -Actual $s.reason -Because 'unconfigured reason'
            Assert-MockCalled -ModuleName Test.PoolNotifier Invoke-PoolNotifierDelivery -Times 0 -Exactly -Scope It
        } finally { $env:YURUNA_RUNTIME_DIR = $saved }
    }
}
