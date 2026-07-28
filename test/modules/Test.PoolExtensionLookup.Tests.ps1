<#PSScriptInfo
.VERSION 2026.07.27
.GUID 42cf7f04-54f2-4dab-abff-66b238af7992
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool aggregator extension stash discovery pester
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
    Guard: a host finds the pool's services by asking the pool, and never turns
    a pool that cannot answer into an error.
.DESCRIPTION
    A host that needs the stash service usually does not run it: the service
    lives on another host, often another subnet, at an address DHCP may change.
    The pool already collects that address -- every extension service announces
    itself to the aggregator, which is what fills the dashboard's Extension
    hosts panel -- so the host reads it back, and knowing the caching-proxy
    address is enough to locate everything else. The alternative, a hard-coded
    literal, is correct only until the service moves, and then a cycle spends
    its whole timeout budget on a machine that no longer exists.

    The lookup is behavioural here, against a local listener speaking the
    aggregator's answers: what matters is that each failure shape -- no pool, an
    area nobody serves, a collector too old to know the route, a dead socket --
    collapses to '' (or an empty list) rather than throwing into a cycle. The
    resolver wiring is checked at source level.
    Run: Invoke-Pester -Path test/modules/Test.PoolExtensionLookup.Tests.ps1
#>

$here          = Split-Path -Parent $PSCommandPath
$testRoot      = Split-Path -Parent $here
$aggregatorPsm = Join-Path $testRoot 'extension' -AdditionalChildPath 'pool-aggregator', 'default.psm1'
$stashPsm      = Join-Path $testRoot 'extension' -AdditionalChildPath 'stash-service', 'default.psm1'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }

Import-Module $aggregatorPsm -Force -Global -DisableNameChecking
# The framework-level client entry point. Imported with the aggregator's reader
# already in scope, which is also how a cycle has it -- so the lookup uses that
# reader instead of re-importing the area through the YAML config.
Import-Module (Join-Path $here 'Test.Extension.psm1') -Force -Global -DisableNameChecking

function Get-FunctionAst {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
        Justification = 'Both parameters ARE used -- Path as the parse target, Name inside the FindAll predicate the analyzer does not follow.')]
    param([string]$Path, [string]$Name)
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    return $ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true) | Select-Object -First 1
}

# One-shot HTTP responder on loopback. A raw TcpListener rather than
# HttpListener: HttpListener needs a URL ACL (or Administrator) to bind, which
# an unattended test run cannot assume. The socket is bound by the caller and
# handed to the job already listening, so the request can never arrive before
# there is something to accept it.
function Get-LoopbackHttpListener {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    return @{
        Listener = $listener
        BaseUrl  = "http://127.0.0.1:$(([System.Net.IPEndPoint]$listener.LocalEndpoint).Port)"
    }
}

function Get-HttpResponderJob {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
        Justification = 'All three values arrive through -ArgumentList into the job param() block; the analyzer does not follow that path.')]
    param([System.Net.Sockets.TcpListener]$Listener, [int]$StatusCode, [string]$Body)
    return Start-ThreadJob -ScriptBlock {
        param($Listener, $StatusCode, $Body)
        try {
            $client = $Listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $buffer = [byte[]]::new(4096)
                [void]$stream.Read($buffer, 0, $buffer.Length)   # drain the request line + headers
                $reason  = if ($StatusCode -eq 200) { 'OK' } else { 'Not Found' }
                $payload = [System.Text.Encoding]::UTF8.GetBytes($Body)
                $head    = "HTTP/1.1 $StatusCode $reason`r`nContent-Type: application/json`r`nContent-Length: $($payload.Length)`r`nConnection: close`r`n`r`n"
                $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
                $stream.Write($headBytes, 0, $headBytes.Length)
                $stream.Write($payload, 0, $payload.Length)
                $stream.Flush()
            } finally { $client.Close() }
        } finally { $Listener.Stop() }
    } -ArgumentList $Listener, $StatusCode, $Body
}

Describe 'pool-extension-lookup' {

    It 'returns the address the pool reports for an area' {
        $bound = Get-LoopbackHttpListener
        $job   = Get-HttpResponderJob -Listener $bound.Listener -StatusCode 200 `
            -Body '{"area":"stash-service","host":"192.168.7.227","target":"http://192.168.7.227","source":"announce"}'
        try {
            $resolved = Get-PoolExtensionHostFrom -BaseUrl $bound.BaseUrl -Area 'stash-service' -TimeoutSeconds 5
            # The bare host, not the URL: callers compose an http probe, an scp
            # target, a guest env value.
            Assert-True ($resolved -eq '192.168.7.227') "expected 192.168.7.227, got '$resolved'"
        } finally { $job | Remove-Job -Force -ErrorAction SilentlyContinue }
    }

    It 'returns nothing when the pool serves no host for the area' {
        $bound = Get-LoopbackHttpListener
        $job   = Get-HttpResponderJob -Listener $bound.Listener -StatusCode 404 -Body 'no live host for that extension area'
        try {
            $resolved = Get-PoolExtensionHostFrom -BaseUrl $bound.BaseUrl -Area 'stash-service' -TimeoutSeconds 5
            Assert-True ($resolved -eq '') "expected '' for a 404, got '$resolved'"
        } finally { $job | Remove-Job -Force -ErrorAction SilentlyContinue }
    }

    It 'returns nothing against a collector too old to know the route' {
        # An aggregator built before this endpoint answers the Go mux's own 404.
        # Same practical outcome as "no live host" -- the caller falls back --
        # so it must not surface as an error either.
        $bound = Get-LoopbackHttpListener
        $job   = Get-HttpResponderJob -Listener $bound.Listener -StatusCode 404 -Body '404 page not found'
        try {
            $resolved = Get-PoolExtensionHostFrom -BaseUrl $bound.BaseUrl -Area 'stash-service' -TimeoutSeconds 5
            Assert-True ($resolved -eq '') "expected '' from an old collector, got '$resolved'"
        } finally { $job | Remove-Job -Force -ErrorAction SilentlyContinue }
    }

    It 'returns nothing, without throwing, when the aggregator is not there' {
        # The pool host is down / unreachable: bind a port only to learn one
        # nothing is listening on, then release it.
        $bound = Get-LoopbackHttpListener
        $dead  = $bound.BaseUrl
        $bound.Listener.Stop()
        $resolved = Get-PoolExtensionHostFrom -BaseUrl $dead -Area 'stash-service' -TimeoutSeconds 3
        Assert-True ($resolved -eq '') "expected '' from a dead aggregator, got '$resolved'"
    }

    It 'treats an answer with no address as no answer' {
        $bound = Get-LoopbackHttpListener
        $job   = Get-HttpResponderJob -Listener $bound.Listener -StatusCode 200 -Body '{"area":"stash-service","host":""}'
        try {
            $resolved = Get-PoolExtensionHostFrom -BaseUrl $bound.BaseUrl -Area 'stash-service' -TimeoutSeconds 5
            Assert-True ($resolved -eq '') "expected '' for an empty host field, got '$resolved'"
        } finally { $job | Remove-Job -Force -ErrorAction SilentlyContinue }
    }

    It 'asks for the area it was given' {
        $fn = Get-FunctionAst -Path $aggregatorPsm -Name 'Get-PoolExtensionHostFrom'
        Assert-True ($fn.Extent.Text -match '/api/v1/extension-hosts\?area=') 'must query the aggregator by area'
        Assert-True ($fn.Extent.Text -match 'EscapeDataString') 'must escape the area into the query string'
    }
}

Describe 'extension-host address list' {

    It 'answers with a list, so the caller can pick' {
        $bound = Get-LoopbackHttpListener
        $job   = Get-HttpResponderJob -Listener $bound.Listener -StatusCode 200 `
            -Body '{"area":"stash-service","host":"192.168.7.227","target":"http://192.168.7.227","source":"announce"}'
        try {
            # -VMName '': no host driver is loaded here, and pinning it off keeps
            # the test about the list rather than about Get-VMIp's absence.
            $addresses = @(Get-ExtensionHostAddress -HostType 'stash-service' -VMName '' `
                -AggregatorBaseUrl $bound.BaseUrl -TimeoutSeconds 5)
            Assert-True ($addresses.Count -eq 1) "expected one address, got $($addresses.Count)"
            Assert-True ($addresses[0] -eq '192.168.7.227') "expected 192.168.7.227, got '$($addresses[0])'"
        } finally { $job | Remove-Job -Force -ErrorAction SilentlyContinue }
    }

    It 'answers with an empty list, not $null, when nothing knows the area' {
        # An empty list is the whole point of the contract: the caller counts it
        # and moves on to its own last resort. A $null here would make .Count
        # throw under Set-StrictMode in exactly the client scripts that call this.
        $bound = Get-LoopbackHttpListener
        $dead  = $bound.BaseUrl
        $bound.Listener.Stop()
        $addresses = @(Get-ExtensionHostAddress -HostType 'stash-service' -VMName '' `
            -AggregatorBaseUrl $dead -TimeoutSeconds 3)
        Assert-True ($null -ne $addresses) 'the lookup must never answer $null'
        Assert-True ($addresses.Count -eq 0) "expected an empty list, got $($addresses.Count) entry/entries"
    }

    It 'puts an operator pin ahead of what it discovers' {
        $bound = Get-LoopbackHttpListener
        $job   = Get-HttpResponderJob -Listener $bound.Listener -StatusCode 200 `
            -Body '{"area":"stash-service","host":"192.168.7.227","source":"announce"}'
        $env:YURUNA_EXTENSION_HOST_STASH_SERVICE = '192.168.7.138'
        try {
            $addresses = @(Get-ExtensionHostAddress -HostType 'stash-service' -VMName '' `
                -AggregatorBaseUrl $bound.BaseUrl -TimeoutSeconds 5)
            Assert-True ($addresses.Count -eq 2) "expected pin + pool, got $($addresses -join ', ')"
            Assert-True ($addresses[0] -eq '192.168.7.138') "the pin must come first, got '$($addresses[0])'"
            Assert-True ($addresses[1] -eq '192.168.7.227') "the pool's answer must follow, got '$($addresses[1])'"
        } finally {
            Remove-Item Env:\YURUNA_EXTENSION_HOST_STASH_SERVICE -ErrorAction SilentlyContinue
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }

    It 'lists one address once, however many sources report it' {
        $bound = Get-LoopbackHttpListener
        $job   = Get-HttpResponderJob -Listener $bound.Listener -StatusCode 200 `
            -Body '{"area":"stash-service","host":"192.168.7.227","source":"announce"}'
        $env:YURUNA_EXTENSION_HOST_STASH_SERVICE = '192.168.7.227'
        try {
            $addresses = @(Get-ExtensionHostAddress -HostType 'stash-service' -VMName '' `
                -AggregatorBaseUrl $bound.BaseUrl -TimeoutSeconds 5)
            # A caller probes every entry it is given; a duplicate spends the
            # probe budget twice on one service.
            Assert-True ($addresses.Count -eq 1) "expected the duplicate collapsed, got $($addresses -join ', ')"
        } finally {
            Remove-Item Env:\YURUNA_EXTENSION_HOST_STASH_SERVICE -ErrorAction SilentlyContinue
            $job | Remove-Job -Force -ErrorAction SilentlyContinue
        }
    }

    It 'drops an address that cannot be composed into a URL or an scp target' {
        $env:YURUNA_EXTENSION_HOST_STASH_SERVICE = "192.168.7.138' rm -rf /"
        try {
            $addresses = @(Get-ExtensionHostAddress -HostType 'stash-service' -VMName '' `
                -AggregatorBaseUrl 'http://127.0.0.1:1' -TimeoutSeconds 2)
            Assert-True ($addresses.Count -eq 0) "expected the quoted value dropped, got $($addresses -join ', ')"
        } finally { Remove-Item Env:\YURUNA_EXTENSION_HOST_STASH_SERVICE -ErrorAction SilentlyContinue }
    }
}

Describe 'pool-extension-lookup wiring' {

    It 'resolves the stash through the pool when the nearer sources are empty' {
        $fn = Get-FunctionAst -Path $stashPsm -Name 'Resolve-Host'
        Assert-True ($null -ne $fn) 'the stash resolver must exist'
        $calls = @($fn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Get-DiscoveredStashHost'
        }, $true))
        Assert-True ($calls.Count -ge 1) 'the resolver must consult the discovered addresses'

        # Order matters: a stash VM on THIS host, and the address this cycle
        # already proved answers /healthz, are both nearer than the pool's view.
        $vmIp = @($fn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Get-VMIp'
        }, $true))
        $published = @($fn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Get-PublishedStashHost'
        }, $true))
        Assert-True ($vmIp.Count -ge 1 -and $published.Count -ge 1) 'the two nearer sources must remain'
        Assert-True ($calls[0].Extent.StartLineNumber -gt $published[0].Extent.StartLineNumber) `
            'the discovery lookup must come after the published address, not replace it'
    }

    It 'never lets a missing pool reach the caller as an error' {
        $fn = Get-FunctionAst -Path $stashPsm -Name 'Get-DiscoveredStashHost'
        Assert-True ($null -ne $fn) 'the wrapper must exist'
        $throws = @($fn.FindAll({
            param($n) $n -is [System.Management.Automation.Language.ThrowStatementAst]
        }, $true))
        Assert-True ($throws.Count -eq 0) 'a pool that cannot answer is not an error'
        Assert-True ($fn.Extent.Text -match 'catch') 'the lookup must be wrapped against a throwing dependency'
        # The stash resolver asked the host contract already; asking again from
        # inside the framework lookup would probe an absent VM a second time.
        Assert-True ($fn.Extent.Text -match "-VMName ''") 'the wrapper must switch off the local VM source'
    }

    It 'resolves the stash by discovery in the pre-flight gate, not from a literal' {
        # The gate runs before any sequence and hard-stops the cycle, so it has
        # to reach the same answer the sequences would. A gate that resolved a
        # stash address the resolver does not agree with fails every pass on a
        # lab whose stash has simply moved.
        $setResource = Join-Path (Split-Path -Parent $testRoot) 'project' -AdditionalChildPath 'test', 'Set-Resource.ps1'
        if (-not (Test-Path -LiteralPath $setResource)) { return }   # the project clone is optional
        $fn = Get-FunctionAst -Path $setResource -Name 'Resolve-StashService'
        Assert-True ($null -ne $fn) 'the pre-flight resolver must exist'
        $calls = @($fn.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Get-DiscoveredStashHost'
        }, $true))
        Assert-True ($calls.Count -ge 1) 'the gate must consult the discovered address'
        $literals = [regex]::Matches((Get-Content -Raw $setResource), '\b\d{1,3}(\.\d{1,3}){3}\b')
        Assert-True ($literals.Count -eq 0) "no hard-coded IPv4 stash address may remain (found: $(($literals | ForEach-Object { $_.Value }) -join ', '))"
    }

    It 'can address the aggregator on a host that only configured a proxy IP' {
        # A host that USES a caching proxy it did not provision has no proxy
        # state file and only carries the env var mid-cycle; without the config
        # key it could never find the aggregator -- and those are exactly the
        # hosts whose services live elsewhere.
        $fn = Get-FunctionAst -Path (Join-Path $here 'Test.CachingProxy.psm1') -Name 'Get-PoolAggregatorSeedUrl'
        Assert-True ($null -ne $fn) 'the aggregator URL resolver must exist'
        Assert-True ($fn.Extent.Text -match 'YURUNA_CACHING_PROXY_IP') 'must still honour the env override'
        Assert-True ($fn.Extent.Text -match 'cachingProxyIP')          'must fall back to the persistent config key'
    }
}
