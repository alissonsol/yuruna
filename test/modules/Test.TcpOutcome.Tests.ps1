<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 425dfdd4-fd92-4c1a-9012-e60152b4c11b
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
    wide -- fails every probe instead of slipping between two. Cache use stays
    optional for ordinary sequences; Kubernetes sequences also require the
    registry HTTP API because their container runtime is pinned to that mirror.

    Real sockets on loopback, no mocks: a listener that is bound gives a genuine
    accept, an unbound loopback port a genuine RST. Nothing here touches the LAN
    or needs a VM. The unreachable case uses a TEST-NET-1 address (RFC 5737),
    which is reserved for documentation and routed nowhere.
    Run: pwsh -NoProfile -File test/modules/Test.TcpOutcome.Tests.ps1
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
$TcpRepoRoot = Split-Path -Parent (Split-Path -Parent $here)

Import-Module (Join-Path $TcpRepoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking -Global
Import-Module (Join-Path $TcpRepoRoot 'test/modules/Test.CachingProxyService.psm1') -Force -DisableNameChecking -Global

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

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

}

Describe 'A refused connection is not an unreachable one' {

    It 'reports a listening port as reachable' {
        $l = New-LoopbackListener
        try {
            $r = Test-TcpConnectOutcome -IpAddress '127.0.0.1' -Port $l.LocalEndpoint.Port -TimeoutMs 3000
            Assert-StringEqual -Expected 'reachable' -Actual $r.Outcome
            Assert-True $r.Reachable 'the convenience flag agrees with the outcome'
        } finally { $l.Stop() }
    }

    It 'reports a closed port on a live host as refused, not timeout' {
        # The distinction the incident turned on: the cache VM answered, squid
        # did not. Calling that a timeout points at the network instead.
        $r = Test-TcpConnectOutcome -IpAddress '127.0.0.1' -Port (Get-ClosedLoopbackPort) -TimeoutMs 3000
        Assert-StringEqual -Expected 'refused' -Actual $r.Outcome
        Assert-True (-not $r.Reachable) 'a refusal is still a failure'
    }

    It 'returns a refusal far inside the deadline' {
        # The elapsed time IS the tell. A refusal comes back in milliseconds; if
        # it ever consumed the budget the two failures would be indistinguishable
        # to a reader, which is the state this replaced.
        $r = Test-TcpConnectOutcome -IpAddress '127.0.0.1' -Port (Get-ClosedLoopbackPort) -TimeoutMs 3000
        # The Windows stack retransmits the SYN to a closed loopback port before it
        # reports the refusal, so the answer arrives after about two seconds there.
        $ceiling = if ($IsWindows) { 2600 } else { 1500 }
        Assert-True ($r.ElapsedMs -lt $ceiling) "a refusal returned in $($r.ElapsedMs) ms, well under the 3000 ms budget"
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
            Assert-StringEqual -Expected 3 -Actual $r.Consecutive -Because 'it took the required run of accepts'
        } finally { $l.Stop() }
    }

    It 'stays silent when the cache was healthy all along' {
        # This runs at the top of every cycle. A gate that narrates itself when
        # nothing is wrong trains the operator to skip the output.
        $l = New-LoopbackListener
        try {
            $r = Wait-CachingProxyServiceSettled -CacheIp '127.0.0.1' -Port $l.LocalEndpoint.Port `
                    -RequiredConsecutive 2 -IntervalSeconds 0 -TimeoutSeconds 20
            Assert-StringEqual -Expected 0 -Actual $r.Lines.Count -Because 'a settled cache prints nothing'
        } finally { $l.Stop() }
    }

    It 'does not accept a port that refuses, and says why it waited' {
        $r = Wait-CachingProxyServiceSettled -CacheIp '127.0.0.1' -Port (Get-ClosedLoopbackPort) `
                -RequiredConsecutive 3 -IntervalSeconds 0 -TimeoutSeconds 2
        Assert-True (-not $r.Settled) 'a refusing port never settles'
        Assert-True (($r.Lines -join ' ') -match 'not settled yet') 'the wait is announced once'
        Assert-True (($r.Lines -join ' ') -match 'refused') 'and names the refusal rather than a generic miss'
    }

    It 'gives up inside its budget and lets a non-Kubernetes cycle proceed' {
        # A sequence that does not depend on the registry can still decide that
        # running without the optional cache is preferable to stopping.
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
        # The run logic lives in the shared port waiter, which both the proxy and the registry legs call.
        $fn = [regex]::Match($body, '(?ms)^function Wait-PortConsecutiveSuccess\b.*?\n\}').Value
        Assert-True ($fn -match '\$consecutive\s*=\s*0') 'a miss resets the run'
        Assert-True ($fn -match '\$consecutive\s*-ge\s*\$Required') 'and the verdict is the run length'
        $caller = [regex]::Match($body, '(?ms)^function Wait-CachingProxyServiceSettled\b.*?\n\}').Value
        Assert-True ($caller -match 'Wait-PortConsecutiveSuccess') 'the settle wait uses the shared consecutive waiter'
        Assert-True ($caller -match '\$consecutive\s*=\s*\$result\.Consecutive') 'and reports the run length it observed'
    }
}

Describe 'Kubernetes cache readiness uses the registry HTTP API' {

    It 'recognizes only a dotted k8s sequence-name segment' {
        Assert-True (Test-SequenceRequiresCacheRegistry -SequenceName @(
            'start.guest.ubuntu.server.24',
            'workload.guest.ubuntu.server.24.k8s.website'
        )) 'a Kubernetes workload requires registry readiness'
        Assert-True (-not (Test-SequenceRequiresCacheRegistry -SequenceName @(
            'workload.guest.ubuntu.server.24',
            'workload.guest.ubuntu.server.24.notk8s.website'
        ))) 'an unrelated name containing the letters k8s does not opt in'
    }

    It 'accepts complete warm sets and an actual required manifest' {
        Mock Invoke-WebRequest -ModuleName Test.CachingProxyService {
            if ($Uri -like '*/zot-meta') {
                [pscustomobject]@{ StatusCode = 200; Content = @'
yuruna_prewarm_state_available 1
yuruna_prewarm_images_total{set="k8s"} 7
yuruna_prewarm_images_resident{set="k8s"} 7
yuruna_prewarm_images_total{set="cni"} 2
yuruna_prewarm_images_resident{set="cni"} 2
yuruna_prewarm_manifest_seconds{set="k8s",image="registry.k8s.io/kube-apiserver:v1.37.1",state="resident"} 0.032
'@ }
            } else { [pscustomobject]@{ StatusCode = 200; Content = '' } }
        }
        $r = Test-CachingProxyRegistryReady -CacheIp '2001:db8::42' -Port 5000
        Assert-True $r.Ready 'the warm-set verdict and real manifest are both ready'
        Assert-StringEqual -Expected 'http://[2001:db8::42]:5000/v2/kube-apiserver/manifests/v1.37.1?ns=registry.k8s.io' -Actual $r.Uri -Because 'UriBuilder brackets IPv6 on every host OS'
    }

    It 'rejects a manifest 503 even when the registry root returns 200' {
        Mock Invoke-WebRequest -ModuleName Test.CachingProxyService {
            if ($Uri -like '*/zot-meta') {
                [pscustomobject]@{ StatusCode = 200; Content = @'
yuruna_prewarm_state_available 1
yuruna_prewarm_images_total{set="k8s"} 7
yuruna_prewarm_images_resident{set="k8s"} 7
yuruna_prewarm_images_total{set="cni"} 2
yuruna_prewarm_images_resident{set="cni"} 2
yuruna_prewarm_manifest_seconds{set="k8s",image="registry.k8s.io/kube-apiserver:v1.37.1",state="resident"} 0.032
'@ }
            } elseif ($Uri -like '*/manifests/*') {
                [pscustomobject]@{ StatusCode = 503; Content = '' }
            } else { [pscustomobject]@{ StatusCode = 200; Content = '' } }
        }
        $r = Test-CachingProxyRegistryReady -CacheIp '127.0.0.1' -Port 5000
        Assert-True (-not $r.Ready) 'root liveness cannot hide a required-manifest failure'
        Assert-StringEqual -Expected 'required manifest HTTP 503' -Actual $r.Reason
    }

    It 'rejects an incomplete Kubernetes warm set before probing a manifest' {
        Mock Invoke-WebRequest -ModuleName Test.CachingProxyService {
            if ($Uri -like '*/zot-meta') {
                [pscustomobject]@{ StatusCode = 200; Content = @'
yuruna_prewarm_state_available 1
yuruna_prewarm_images_total{set="k8s"} 7
yuruna_prewarm_images_resident{set="k8s"} 0
yuruna_prewarm_images_total{set="cni"} 2
yuruna_prewarm_images_resident{set="cni"} 2
'@ }
            } else { [pscustomobject]@{ StatusCode = 200; Content = '' } }
        }
        $r = Test-CachingProxyRegistryReady -CacheIp '127.0.0.1' -Port 5000
        Assert-True (-not $r.Ready) 'zero of seven held images is not readiness'
        Assert-StringEqual -Expected 'k8s warm set holds 0 of 7 required images' -Actual $r.Reason
    }

    It 'keeps a non-Kubernetes caller optional and does not probe the registry' {
        Mock Test-CachingProxyRegistryReady -ModuleName Test.CachingProxyService {
            throw 'the optional path must not call the registry probe'
        }
        $l = New-LoopbackListener
        try {
            $r = Wait-CachingProxyServiceSettled -CacheIp '127.0.0.1' -Port $l.LocalEndpoint.Port `
                -RequiredConsecutive 2 -IntervalSeconds 0 -TimeoutSeconds 20
            Assert-True $r.Ready 'the healthy proxy is enough for an ordinary sequence'
            Assert-True ($null -eq $r.RegistrySettled) 'the optional registry was not evaluated'
            Should -Invoke Test-CachingProxyRegistryReady -ModuleName Test.CachingProxyService -Times 0 -Exactly
        } finally { $l.Stop() }
    }

    It 'blocks Kubernetes work when the required manifest keeps returning 503' {
        Mock Test-CachingProxyRegistryReady -ModuleName Test.CachingProxyService {
            @{ Ready = $false; Reason = 'required manifest HTTP 503'; StatusCode = 503; Uri = 'http://127.0.0.1:5000/v2/kube-apiserver/manifests/v1.37.1?ns=registry.k8s.io' }
        }
        $l = New-LoopbackListener
        try {
            $r = Wait-CachingProxyServiceSettled -CacheIp '127.0.0.1' -Port $l.LocalEndpoint.Port `
                -RegistryPort 5000 -RegistryTimeoutSeconds 1 -RequireRegistry `
                -RequiredConsecutive 2 -IntervalSeconds 1 -TimeoutSeconds 20
            Assert-True $r.Settled 'the proxy itself stayed up'
            Assert-True (-not $r.RegistrySettled) 'the HTTP registry did not settle'
            Assert-True (-not $r.Ready) 'the aggregate Kubernetes verdict is not ready'
            Assert-True (($r.Lines -join ' ') -match 'manifest HTTP 503') 'the reason preserves the application-level failure'
            Assert-True (($r.Lines -join ' ') -match 'Kubernetes guest work was not started') 'the result does not claim a direct-download fallback'
        } finally { $l.Stop() }
    }

    It 'fails closed when a required registry has no wait budget' {
        $l = New-LoopbackListener
        try {
            $r = Wait-CachingProxyServiceSettled -CacheIp '127.0.0.1' -Port $l.LocalEndpoint.Port `
                -RequireRegistry -RequiredConsecutive 2 -IntervalSeconds 0 -TimeoutSeconds 20
            Assert-True (-not $r.Ready) 'required readiness cannot silently disable its own probe'
            Assert-True (-not $r.RegistrySettled) 'the missing budget is an explicit failed registry verdict'
        } finally { $l.Stop() }
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

    It 'rechecks inside every orchestrator guest entry immediately before its run' {
        $body = Get-Content -Raw (Join-Path $TcpRepoRoot 'test/modules/Test.Orchestrator.psm1')
        $guestBranchAt = $body.IndexOf("} elseif (`$e.kind -eq 'guest') {")
        $waitAt = $body.IndexOf('Wait-CachingProxyServiceSettled', $guestBranchAt)
        $runAt = $body.IndexOf('$run = Invoke-OrchestratorGuestRun', $guestBranchAt)
        Assert-True ($guestBranchAt -ge 0) 'the guest entry branch exists'
        Assert-True ($waitAt -gt $guestBranchAt -and $waitAt -lt $runAt) 'the registry is rechecked inside the entry before the guest invocation'
        Assert-True ($body.Substring($guestBranchAt, $runAt - $guestBranchAt) -match 'Test-SequenceRequiresCacheRegistry') 'the per-entry check applies only to Kubernetes sequence names'
    }

    It 'rechecks the direct debug path immediately before running the chain' {
        $body = Get-Content -Raw (Join-Path $TcpRepoRoot 'test/Debug-TestSequence.ps1')
        $runAt = $body.IndexOf('$result = Invoke-TestSequenceChain')
        $gateAt = $body.LastIndexOf('if ($requiresCacheRegistry', $runAt)
        $waitAt = $body.LastIndexOf('Wait-CachingProxyServiceSettled', $runAt)
        Assert-True ($gateAt -ge 0 -and $gateAt -lt $waitAt -and $waitAt -lt $runAt) 'the direct path rechecks Kubernetes work after VM preparation and before the sequence chain'
        Assert-True ($body.Substring($waitAt, $runAt - $waitAt) -match '\-RequireRegistry') 'the direct recheck requires the full registry verdict'
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
