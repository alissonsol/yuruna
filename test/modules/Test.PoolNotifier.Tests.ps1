<#PSScriptInfo
.VERSION 2026.06.12
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
        Assert-Equal 0.25 $pools['lab'].healthyFraction 'lab fraction'
        Assert-Equal 0.5  $pools['lab'].healthyThreshold 'lab threshold'
        Assert-Equal 1 $pools['lab'].membersHealthy 'lab healthy'
        Assert-Equal 4 $pools['lab'].membersTotal 'lab total'
    }
    It 'treats a pool with no alert_active series as not alerting (un-authored)' {
        Assert-True  $pools['wild'].degraded 'wild degraded gauge present'
        Assert-False $pools['wild'].alertActive 'wild never alerts (no alert_active line)'
    }
    It 'ignores unrelated/labelled series and an empty body' {
        Assert-True (-not $pools.ContainsKey('')) 'no empty pool key from host_status'
        Assert-Equal 0 (ConvertFrom-PrometheusPoolGauge -MetricsText '').Count 'empty -> no pools'
    }
}

Describe 'New-PoolAlertSpoolMessage (message shape)' {
    $g = @{ pool = 'lab'; alertActive = $true; healthyFraction = 0.25; healthyThreshold = 0.5; membersHealthy = 1; membersTotal = 4 }
    $m = New-PoolAlertSpoolMessage -Pool 'lab' -GaugePool $g -UnixSeconds 1700000000 -NowUtc '2026-01-01T00:00:00Z'
    It 'builds a stable id + the pool.alert event code + structured fields' {
        Assert-Equal 'pool-lab-1700000000' $m['id'] 'id'
        Assert-Equal 'pool.alert' $m['eventCode'] 'eventCode'
        Assert-Equal 'pool_alert_fired' $m['event'] 'event'
        Assert-Equal 1 $m['membersHealthy'] 'membersHealthy'
        Assert-Equal 4 $m['membersTotal'] 'membersTotal'
        Assert-Equal 0 $m['attempts'] 'attempts starts at 0'
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
            Assert-Equal 1 $n1 'rising edge enqueues one'
            Assert-True $state['pools']['lab']['lastActive'] 'lastActive latched true'
            Assert-Equal 1 (@(Get-ChildItem -LiteralPath (Join-Path $root 'outgoing') -Filter '*.json' -File).Count) 'one outgoing file'

            $n2 = Add-PoolAlertSpoolEntry -GaugeState $gaugeOn -State $state -SpoolRoot $root
            Assert-Equal 0 $n2 'still-active does not re-enqueue'

            $n3 = Add-PoolAlertSpoolEntry -GaugeState $gaugeOff -State $state -SpoolRoot $root
            Assert-Equal 0 $n3 'falling edge does not enqueue'
            Assert-False $state['pools']['lab']['lastActive'] 'lastActive cleared'
        } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'suppresses a re-fire within the cooldown but allows it once the cooldown elapses' {
        $root = New-TempDir
        try {
            $state = @{ pools = @{} }
            $on  = @{ lab = @{ pool = 'lab'; alertActive = $true;  healthyFraction = 0.2; healthyThreshold = 0.5; membersHealthy = 1; membersTotal = 5 } }
            $off = @{ lab = @{ pool = 'lab'; alertActive = $false; healthyFraction = 0.9; healthyThreshold = 0.5; membersHealthy = 5; membersTotal = 5 } }

            Assert-Equal 1 (Add-PoolAlertSpoolEntry -GaugeState $on -State $state -SpoolRoot $root) 'first fire'
            $null = Add-PoolAlertSpoolEntry -GaugeState $off -State $state -SpoolRoot $root  # clear
            # Re-rise immediately: default 900s cooldown suppresses it (absorbs aggregator restart flap).
            Assert-Equal 0 (Add-PoolAlertSpoolEntry -GaugeState $on -State $state -SpoolRoot $root) 're-fire suppressed by cooldown'

            # With cooldown 0 the re-rise fires (proves it is the cooldown, not the edge logic).
            $null = Add-PoolAlertSpoolEntry -GaugeState $off -State $state -SpoolRoot $root  # clear again
            Assert-Equal 1 (Add-PoolAlertSpoolEntry -GaugeState $on -State $state -SpoolRoot $root -RearmCooldownSeconds 0) 're-fire allowed when cooldown elapsed'
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
        Assert-Equal 'https://10.0.0.5:9400/metrics' $u[0] 'https first'
        Assert-Equal 'http://10.0.0.5:9400/metrics'  $u[1] 'http fallback'
        $h = Get-PoolMetricsCandidateUrl -MetricsUrl 'https://10.0.0.5:9400/metrics'
        Assert-Equal 'https://10.0.0.5:9400/metrics' $h[0] 'https stays https first'
        Assert-Equal 'http://10.0.0.5:9400/metrics'  $h[1] 'plus http fallback'
    }
}

Describe 'Get-PoolNotifierSpoolRoot' {
    It 'is null without a poolStorage config and joins notifications onto LocalPath otherwise' {
        Assert-Null (Get-PoolNotifierSpoolRoot -Config $null) 'null config -> null'
        $root = Get-PoolNotifierSpoolRoot -Config ([pscustomobject]@{ LocalPath = '/mnt/ypsp' })
        Assert-Equal (Join-Path '/mnt/ypsp' 'notifications') $root 'LocalPath/notifications'
    }
}
