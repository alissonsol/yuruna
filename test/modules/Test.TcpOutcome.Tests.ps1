<#PSScriptInfo
.VERSION 2026.07.31
.GUID 42c4e820-1b7d-4f36-a95e-70d2c8b41a95
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test tcp probe refused timeout caching-proxy pester
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
    Coverage for telling a refused connection from an unreachable one
    (Test-TcpConnectOutcome / Get-TcpOutcomeExplanation) and for the
    stay-up confirmation a cycle applies before committing to a cache
    (Wait-CachingProxyServiceSettled).
.DESCRIPTION
    A failed TCP connect carries two opposite diagnoses. A peer that sends an
    RST is up, reachable, and running nothing on that port -- a service problem,
    answered in milliseconds. A peer that says nothing until the deadline is a
    path problem. Reporting both as "did not answer within 3s" sends the reader
    into the network for a fault that lives entirely inside the peer, which is
    exactly what happened when a freshly rebuilt cache VM restarted squid
    mid-cycle: three probes were refused in 30-77 ms and the run blamed Wi-Fi.

    The settle cases cover the other half: one accept is not readiness. The gate
    requires consecutive accepts, so a restart in progress -- tens of seconds
    wide -- fails every probe instead of slipping between two, and it never
    fails the caller, because stalling a cycle over its cache is worse than
    running the cycle without one.

    Real sockets on loopback, no mocks: a listener that is bound gives a genuine
    accept, an unbound loopback port a genuine RST. Nothing here touches the LAN
    or needs a VM. The unreachable case uses a TEST-NET-1 address (RFC 5737),
    which is reserved for documentation and routed nowhere.
    Run: pwsh -NoProfile -File test/modules/Test.TcpOutcome.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
$TcpRepoRoot = Split-Path -Parent (Split-Path -Parent $here)

Import-Module (Join-Path $TcpRepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $TcpRepoRoot 'test/modules/Test.CachingProxyService.psm1') -Force -DisableNameChecking -Global

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal {
    param($Expected, $Actual, [string]$Because = '')
    if ("$Expected" -ne "$Actual") { throw "Expected '$Expected' but got '$Actual'. $Because" }
}

# A bound-but-idle listener answers the SYN; closing it leaves the port with
# nothing behind it, which is what produces the RST.
function New-LoopbackListener {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: binds a loopback socket the suite stops itself.')]
    [CmdletBinding()]
    [OutputType([System.Net.Sockets.TcpListener])]
    param()
    $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    return $l
}
function Get-ClosedLoopbackPort {
    [CmdletBinding()]
    [OutputType([int])]
    param()
    $l = New-LoopbackListener
    $port = $l.LocalEndpoint.Port
    $l.Stop()
    return $port
}

Describe 'A refused connection is not an unreachable one' {

    It 'reports a listening port as reachable' {
        $l = New-LoopbackListener
        try {
            $r = Test-TcpConnectOutcome -IpAddress '127.0.0.1' -Port $l.LocalEndpoint.Port -TimeoutMs 3000
            Assert-Equal -Expected 'reachable' -Actual $r.Outcome
            Assert-True $r.Reachable 'the convenience flag agrees with the outcome'
        } finally { $l.Stop() }
    }

    It 'reports a closed port on a live host as refused, not timeout' {
        # The distinction the incident turned on: the cache VM answered, squid
        # did not. Calling that a timeout points at the network instead.
        $r = Test-TcpConnectOutcome -IpAddress '127.0.0.1' -Port (Get-ClosedLoopbackPort) -TimeoutMs 3000
        Assert-Equal -Expected 'refused' -Actual $r.Outcome
        Assert-True (-not $r.Reachable) 'a refusal is still a failure'
    }

    It 'returns a refusal far inside the deadline' {
        # The elapsed time IS the tell. A refusal comes back in milliseconds; if
        # it ever consumed the budget the two failures would be indistinguishable
        # to a reader, which is the state this replaced.
        $r = Test-TcpConnectOutcome -IpAddress '127.0.0.1' -Port (Get-ClosedLoopbackPort) -TimeoutMs 3000
        Assert-True ($r.ElapsedMs -lt 1500) "a refusal returned in $($r.ElapsedMs) ms, well under the 3000 ms budget"
    }

    It 'reports a silent address as a timeout, bounded by the deadline' {
        # TEST-NET-1 (RFC 5737): reserved for documentation, routed nowhere.
        $r = Test-TcpConnectOutcome -IpAddress '192.0.2.1' -Port 3128 -TimeoutMs 1200
        Assert-True ($r.Outcome -in @('timeout', 'unreachable')) "got '$($r.Outcome)', want timeout or unreachable"
        Assert-True (-not $r.Reachable) 'nothing answered'
        Assert-True ($r.ElapsedMs -lt 6000) "the deadline bounded the wait ($($r.ElapsedMs) ms)"
    }

    It 'explains each outcome differently, and points somewhere different' {
        # The two sentences have to send the reader to different places, or the
        # classification buys nothing.
        $refused = Get-TcpOutcomeExplanation -Outcome @{ Outcome = 'refused'; ElapsedMs = 56 } -Endpoint '10.0.0.5:3128'
        $timeout = Get-TcpOutcomeExplanation -Outcome @{ Outcome = 'timeout'; ElapsedMs = 3000 } -Endpoint '10.0.0.5:3128'
        Assert-True ($refused -match 'REFUSED') 'the refusal names itself'
        Assert-True ($refused -match '56 ms') 'and carries the elapsed time'
        Assert-True ($refused -match 'nothing is listening') 'and says the port, not the path, is the problem'
        Assert-True ($timeout -match 'did not answer') 'the timeout names itself'
        Assert-True ($timeout -match 'path is the suspect') 'and sends the reader to the network instead'
        Assert-True ($refused -ne $timeout) 'the two are not the same sentence'
    }
}

Describe 'A cache is confirmed to stay up before a cycle commits to it' {

    It 'settles on a port that keeps accepting' {
        $l = New-LoopbackListener
        try {
            $r = Wait-CachingProxyServiceSettled -CacheIp '127.0.0.1' -Port $l.LocalEndpoint.Port `
                    -RequiredConsecutive 3 -IntervalSeconds 0 -TimeoutSeconds 20
            Assert-True $r.Settled 'a healthy cache settles'
            Assert-Equal -Expected 3 -Actual $r.Consecutive -Because 'it took the required run of accepts'
        } finally { $l.Stop() }
    }

    It 'stays silent when the cache was healthy all along' {
        # This runs at the top of every cycle. A gate that narrates itself when
        # nothing is wrong trains the operator to skip the output.
        $l = New-LoopbackListener
        try {
            $r = Wait-CachingProxyServiceSettled -CacheIp '127.0.0.1' -Port $l.LocalEndpoint.Port `
                    -RequiredConsecutive 2 -IntervalSeconds 0 -TimeoutSeconds 20
            Assert-Equal -Expected 0 -Actual $r.Lines.Count -Because 'a settled cache prints nothing'
        } finally { $l.Stop() }
    }

    It 'does not accept a port that refuses, and says why it waited' {
        $r = Wait-CachingProxyServiceSettled -CacheIp '127.0.0.1' -Port (Get-ClosedLoopbackPort) `
                -RequiredConsecutive 3 -IntervalSeconds 0 -TimeoutSeconds 2
        Assert-True (-not $r.Settled) 'a refusing port never settles'
        Assert-True (($r.Lines -join ' ') -match 'not settled yet') 'the wait is announced once'
        Assert-True (($r.Lines -join ' ') -match 'refused') 'and names the refusal rather than a generic miss'
    }

    It 'gives up inside its budget and lets the cycle proceed' {
        # Never fails the caller: guests degrade to direct downloads by
        # themselves, and stalling a cycle over its cache is the worse outcome.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Wait-CachingProxyServiceSettled -CacheIp '127.0.0.1' -Port (Get-ClosedLoopbackPort) `
                -RequiredConsecutive 3 -IntervalSeconds 0 -TimeoutSeconds 2
        $sw.Stop()
        Assert-True (-not $r.Settled) 'it reports the failure'
        Assert-True ($sw.Elapsed.TotalSeconds -lt 30) "it returned in $([int]$sw.Elapsed.TotalSeconds)s rather than hanging the cycle"
        Assert-True (($r.Lines -join ' ') -match 'Proceeding anyway') 'and says the cycle goes ahead regardless'
    }

    It 'requires the accepts to be CONSECUTIVE' {
        # One accept is what the probe suite already proved. If a single success
        # anywhere in the window were enough, a restart that happened to answer
        # once between two failures would pass the gate -- which is the bug.
        $body = (Get-Content -Raw (Join-Path $TcpRepoRoot 'test/modules/Test.CachingProxyService.psm1'))
        $fn = [regex]::Match($body, '(?ms)^function Wait-CachingProxyServiceSettled\b.*?\n\}').Value
        Assert-True ($fn -match '\$consecutive\s*=\s*0') 'a miss resets the run'
        Assert-True ($fn -match '\$consecutive\s*-ge\s*\$RequiredConsecutive') 'and the verdict is the run length'
    }
}

Describe 'The cycle-start commit is gated, the diagnostic is not' {

    It 'the orchestrator waits before pinning the address for the cycle' {
        $body = Get-Content -Raw (Join-Path $TcpRepoRoot 'test/modules/Test.Orchestrator.psm1')
        $waitAt = $body.IndexOf('Wait-CachingProxyServiceSettled')
        $pinAt  = $body.IndexOf('$env:YURUNA_CACHING_PROXY_SERVICE_IP = $endpoint.EffectiveIp')
        Assert-True ($waitAt -ge 0) 'the orchestrator confirms the cache'
        Assert-True ($pinAt -ge 0) 'and pins the resolved address'
        Assert-True ($waitAt -lt $pinAt) 'confirmation happens BEFORE the address is committed'
    }

    It 'the resolver itself does no waiting' {
        # Resolution is probe + precedence, and its tests mock the probe with
        # unroutable addresses. A real wait in there would turn each of those
        # into a multi-minute hang, and it would also charge the wait to callers
        # that only want to report the cache's state.
        $body = Get-Content -Raw (Join-Path $TcpRepoRoot 'test/modules/Test.CachingProxyService.psm1')
        $fn = [regex]::Match($body, '(?ms)^function Resolve-CachingProxyServiceEndpoint\b.*?\n\}').Value
        Assert-True ($fn.Length -gt 0) 'the resolver is defined'
        Assert-True ($fn -notmatch 'Wait-CachingProxyServiceSettled') 'and it does not wait'
    }
}
