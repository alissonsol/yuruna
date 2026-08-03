<#PSScriptInfo
.VERSION 2026.08.03
.GUID 42f1c60d-4b28-4d97-a3e5-90b6d2417fac
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test service vm reboot pester
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
    Pester coverage for Test.ServiceVm.psm1: the roster, the port probe, and the
    restore sweep's behaviour with and without a per-host VM contract loaded.
.DESCRIPTION
    The restore sweep's start path needs a real hypervisor, so what is asserted
    here is everything around it that a wrong answer would break silently: that
    the roster agrees with the Start-*ServiceVM.ps1 scripts it names, that a
    missing host driver degrades to a REPORTED no-op rather than an exception or
    a false clean bill, and that an absent VM is never treated as a failure --
    a standalone host legitimately runs no stash service.
#>

$here = Split-Path -Parent $PSCommandPath
$TestRoot = Split-Path -Parent $here
Import-Module (Join-Path $here 'Test.ServiceVm.psm1') -Force -DisableNameChecking

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because = '') if ($Condition) { throw "Expected false. $Because" } }

Describe 'Get-YurunaServiceVmRoster' {
    It 'lists the three service VMs' {
        $r = @(Get-YurunaServiceVmRoster)
        Assert-Equal 3 $r.Count
        foreach ($key in @('caching-proxy', 'stash', 'pool-control')) {
            Assert-Equal 1 @($r | Where-Object { $_.Key -eq $key }).Count -Because "roster carries '$key'"
        }
    }
    It 'names a start script that exists for every entry' {
        # The roster is only useful if its StartScript is the real escalation
        # path; a typo here would surface as advice pointing at nothing.
        foreach ($svc in @(Get-YurunaServiceVmRoster)) {
            Assert-True (Test-Path -LiteralPath (Join-Path $TestRoot $svc.StartScript)) "$($svc.StartScript) exists"
        }
    }
    It 'agrees with each start script''s own default VM name' {
        # The roster took over from three independent parameter defaults. If they
        # ever drift, the sweep starts a VM nobody else is looking for -- so the
        # agreement is asserted rather than assumed.
        foreach ($svc in @(Get-YurunaServiceVmRoster)) {
            $body = Get-Content -Raw -LiteralPath (Join-Path $TestRoot $svc.StartScript)
            Assert-True ($body -match [regex]::Escape($svc.VMName)) "$($svc.StartScript) references '$($svc.VMName)'"
        }
    }
    It 'carries the port a CONSUMER connects to' {
        $byKey = @{}
        foreach ($svc in @(Get-YurunaServiceVmRoster)) { $byKey[$svc.Key] = $svc }
        Assert-Equal 3128 $byKey['caching-proxy'].HealthPort -Because 'squid, the port guests proxy through'
        Assert-Equal 80   $byKey['stash'].HealthPort         -Because '/healthz, the stash pre-flight gate'
        Assert-Equal 80   $byKey['pool-control'].HealthPort  -Because 'the pool-control UI/API'
    }
    It 'filters by key and tolerates an unknown one' {
        Assert-Equal 1 @(Get-YurunaServiceVmRoster -Key 'stash').Count
        Assert-Equal 2 @(Get-YurunaServiceVmRoster -Key @('stash', 'caching-proxy')).Count
        Assert-Equal 0 @(Get-YurunaServiceVmRoster -Key 'no-such-service').Count
        Assert-Equal 3 @(Get-YurunaServiceVmRoster -Key @()).Count -Because 'an empty filter means everything'
    }
}

Describe 'Test-YurunaServiceVmPort' {
    It 'is false for a blank address rather than throwing' {
        foreach ($bad in @('', '   ', $null)) { Assert-False (Test-YurunaServiceVmPort -Address $bad -Port 3128) }
    }
    It 'is false for a port nothing listens on, within the cap' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Test-YurunaServiceVmPort -Address '127.0.0.1' -Port 59996 -TimeoutMs 1000
        $sw.Stop()
        Assert-False $r 'closed port is not healthy'
        Assert-True ($sw.Elapsed.TotalSeconds -lt 10) "bounded ($([int]$sw.Elapsed.TotalSeconds)s)"
    }
    It 'is true for a port that IS listening' {
        # A real listener, so the success path is exercised rather than assumed
        # from the failure path.
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            Assert-True (Test-YurunaServiceVmPort -Address '127.0.0.1' -Port $port) 'live listener answers'
        } finally { $listener.Stop() }
    }
    It 'is false for an unroutable address rather than hanging' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Test-YurunaServiceVmPort -Address '192.0.2.1' -Port 3128 -TimeoutMs 800   # TEST-NET-1, RFC 5737
        $sw.Stop()
        Assert-False $r
        Assert-True ($sw.Elapsed.TotalSeconds -lt 10) "the cap held ($([int]$sw.Elapsed.TotalSeconds)s)"
    }
}

Describe 'Restore-YurunaServiceVM' {
    It 'reports a no-op when the per-host VM contract is not loaded' {
        # This suite runs without Initialize-YurunaHost, which is exactly the
        # state a caller hits when the driver failed to load. The sweep must SAY
        # it could not look -- reporting an empty result would read as "all
        # services healthy" on a host where nothing was checked at all.
        $r = @(Restore-YurunaServiceVM -Confirm:$false)
        Assert-Equal 3 $r.Count -Because 'one record per service even when nothing can be checked'
        foreach ($x in $r) {
            Assert-Equal 'no-host-driver' $x.Outcome
            Assert-False $x.Healthy 'unknown is never reported as healthy'
            Assert-True ([bool]$x.Message) 'carries a reason'
        }
    }
    It 'honours the key filter' {
        $r = @(Restore-YurunaServiceVM -Key 'stash' -Confirm:$false)
        Assert-Equal 1 $r.Count
        Assert-Equal 'stash' $r[0].Key
    }
    It 'never throws, whatever the host looks like' {
        # The sweep runs at every cycle start; an exception here would take down
        # a cycle over a diagnostic.
        $threw = $false
        try { $null = @(Restore-YurunaServiceVM -Confirm:$false) } catch { $threw = $true }
        Assert-False $threw 'the sweep is best-effort by contract'
    }
}

Describe 'Write-YurunaServiceVmRestoreReport' {
    It 'is silent for services that were already running or absent' {
        # Silence on the healthy path is the point: this prints every cycle, and
        # a line per service would bury the cycle where something was restarted.
        $quiet = @(
            [pscustomobject]@{ Key='stash'; VMName='v'; DisplayName='stash service'; StateBefore='running'; Outcome='running'; Healthy=$true; Message='already running' }
            [pscustomobject]@{ Key='pool-control'; VMName='v2'; DisplayName='pool-control service'; StateBefore='absent'; Outcome='absent'; Healthy=$false; Message='not built on this host' }
        )
        $out = Write-YurunaServiceVmRestoreReport -Result $quiet -InformationAction Continue 3>&1 6>&1
        Assert-Equal 0 @($out).Count -Because 'nothing worth an operator''s attention'
    }
    It 'announces a service it actually recovered' {
        $started = @([pscustomobject]@{ Key='caching-proxy'; VMName='v'; DisplayName='caching-proxy service'; StateBefore='stopped'; Outcome='started'; Healthy=$true; Message='started; :3128 answering at 192.168.64.11' })
        $out = Write-YurunaServiceVmRestoreReport -Result $started -InformationAction Continue 6>&1
        Assert-True (@($out).Count -ge 1) 'a recovery is reported'
        Assert-True ("$out" -match 'recovered') 'says it recovered'
    }
    It 'warns about a service that would not start, and names its rebuild script' {
        $failed = @([pscustomobject]@{ Key='stash'; VMName='yuruna-stash-service'; DisplayName='stash service'; StateBefore='stopped'; Outcome='start-failed'; Healthy=$false; Message='boom' })
        $out = Write-YurunaServiceVmRestoreReport -Result $failed 3>&1
        Assert-True (@($out).Count -ge 1) 'a failure is reported'
        Assert-True ("$out" -match 'Start-StashServiceVM\.ps1') 'points at the escalation'
    }
    It 'tolerates an empty or null result set' {
        Assert-Equal 0 @(Write-YurunaServiceVmRestoreReport -Result @() 3>&1 6>&1).Count
        Assert-Equal 0 @(Write-YurunaServiceVmRestoreReport -Result $null 3>&1 6>&1).Count
    }
}
