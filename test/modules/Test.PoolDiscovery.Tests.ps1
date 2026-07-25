<#PSScriptInfo
.VERSION 2026.07.25
.GUID 8d4a1e60-5f92-4c37-b1a8-2e60d97c4f13
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool discovery extension stash pester
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
    Guards Test.PoolDiscovery: resolving the ACTIVE extension service (the stash
    service) from the pool aggregator instead of the local hypervisor.
.DESCRIPTION
    The regression: stash-service.ResolveHost only ever asked the local
    hypervisor for a VM named 'yuruna-stash-service', so a healthy stash service
    running on another pool host reported "no IPv4 ... (is it running?)" and the
    build aborted with "no binaries in the stash". These pin the reduction of the
    aggregator's /api/v1/pool-status into an area -> target map (the same data
    behind the Grafana pool dashboard's "Extension hosts" table), the memo TTL,
    and the URL-vs-host contract the guest-side STASH_HOST depends on.
    Throw-based assertions so the file runs under Pester 4.10.1 and Pester 5+.
    Run: Invoke-Pester -Path test/modules/Test.PoolDiscovery.Tests.ps1
#>

$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.PoolDiscovery.psm1'

function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }

Import-Module $modulePath -Force -DisableNameChecking -Global

# A recorded /api/v1/pool-status body. Shape mirrors the aggregator's
# handlePoolStatus: hosts[] carry registration-advertised extensionTargets, and
# announcedExtensions[] carries the service's own self-announce.
function ConvertTo-StatusDoc {
    param([string]$Json)
    return ($Json | ConvertFrom-Json)
}

$script:TwoHostDoc = @'
{
  "pool": "default",
  "lastPollUtc": "2026-07-25T09:00:00Z",
  "hosts": [
    { "hostId": "aaaa1111", "baseUrl": "http://10.0.0.1:8080", "reachable": true,
      "lastSeenUnixMs": 1000, "activeExtensions": ["pool-control"],
      "extensionTargets": { "pool-control": "http://10.0.0.1:8443" } },
    { "hostId": "bbbb2222", "baseUrl": "http://10.0.0.2:8080", "reachable": true,
      "lastSeenUnixMs": 2000, "activeExtensions": ["stash-service"],
      "extensionTargets": { "stash-service": "http://192.168.7.138" },
      "stashBaseUrl": "http://192.168.7.138" }
  ]
}
'@

Describe 'ConvertFrom-PoolStatusExtensionTarget -- reducing pool-status to area -> target' {
    It 'finds the stash service advertised by ANOTHER host' {
        # The whole point: the asking host is not the one running the stash.
        $map = ConvertFrom-PoolStatusExtensionTarget -Document (ConvertTo-StatusDoc $script:TwoHostDoc)
        Assert-True ($map.ContainsKey('stash-service')) 'the stash service must be discovered from the pool view'
        Assert-Equal 'http://192.168.7.138' $map['stash-service'].Target -Because 'the advertised target is the dashboard target field'
        Assert-Equal 'bbbb2222' $map['stash-service'].HostId -Because 'the owning host is reported alongside'
    }
    It 'keeps every advertised area, not just the stash' {
        $map = ConvertFrom-PoolStatusExtensionTarget -Document (ConvertTo-StatusDoc $script:TwoHostDoc)
        Assert-Equal 'http://10.0.0.1:8443' $map['pool-control'].Target -Because 'the reduction is generic over extension areas'
    }
    It 'returns an empty map for a null or extension-less document' {
        Assert-Equal 0 (ConvertFrom-PoolStatusExtensionTarget -Document $null).Count -Because 'an unreachable aggregator must not throw'
        $bare = ConvertTo-StatusDoc '{ "pool": "default", "hosts": [ { "hostId": "cccc", "lastSeenUnixMs": 5 } ] }'
        Assert-Equal 0 (ConvertFrom-PoolStatusExtensionTarget -Document $bare).Count -Because 'a pool with no extension services reports none'
    }
    It 'falls back to a self-announce when no host advertises the area' {
        # This is the observable that survives a service whose OWNING HOST is
        # dark -- the aggregator keeps the announce even with no registration.
        $doc = ConvertTo-StatusDoc @'
{ "pool": "default", "hosts": [],
  "announcedExtensions": [ { "hostId": "dddd4444", "area": "stash-service", "target": "http://10.0.0.7", "lastSeenUnixMs": 900 } ] }
'@
        $map = ConvertFrom-PoolStatusExtensionTarget -Document $doc
        Assert-Equal 'http://10.0.0.7' $map['stash-service'].Target -Because 'a live announce still locates the service'
        Assert-Equal 'announce' $map['stash-service'].Source -Because 'the caller can tell which signal answered'
    }
    It 'prefers the most recently seen advertiser when two claim the same area' {
        # A stash service that MOVED leaves a stale registration behind; the
        # freshest signal must win or every build uploads to the dead host.
        $doc = ConvertTo-StatusDoc @'
{ "pool": "default",
  "hosts": [ { "hostId": "old1", "lastSeenUnixMs": 100, "extensionTargets": { "stash-service": "http://10.0.0.9" } } ],
  "announcedExtensions": [ { "hostId": "new1", "area": "stash-service", "target": "http://10.0.0.11", "lastSeenUnixMs": 999 } ] }
'@
        $map = ConvertFrom-PoolStatusExtensionTarget -Document $doc
        Assert-Equal 'http://10.0.0.11' $map['stash-service'].Target -Because 'the freshest advertiser wins'
    }
    It 'ignores an advertised area with an empty target' {
        $doc = ConvertTo-StatusDoc '{ "pool": "default", "hosts": [ { "hostId": "e1", "lastSeenUnixMs": 3, "extensionTargets": { "stash-service": "" } } ] }'
        Assert-Equal 0 (ConvertFrom-PoolStatusExtensionTarget -Document $doc).Count -Because 'an empty target is not an answer'
    }
}

Describe 'Get-PoolExtensionTarget -- URL vs bare host' {
    # The mock body runs in the MODULE's session state (-ModuleName), where this
    # file's $script: variables do not exist -- so each fixture is inlined rather
    # than referenced. A referenced one resolves to $null and ConvertFrom-Json
    # then fails inside the mock, which reads as a module bug.
    BeforeEach {
        Clear-PoolExtensionTargetCache -Confirm:$false
        Mock -ModuleName Test.PoolDiscovery Get-PoolStatusDocument {
            return ('{ "pool":"default","hosts":[
              { "hostId":"aaaa1111","lastSeenUnixMs":1000,"extensionTargets":{"pool-control":"http://10.0.0.1:8443"} },
              { "hostId":"bbbb2222","lastSeenUnixMs":2000,"extensionTargets":{"stash-service":"http://192.168.7.138"} } ] }' | ConvertFrom-Json)
        }
    }
    AfterEach { Clear-PoolExtensionTargetCache -Confirm:$false }

    It 'returns the full advertised URL by default' {
        Assert-Equal 'http://192.168.7.138' (Get-PoolExtensionTarget -Area 'stash-service') -Because 'the target IS a URL'
    }
    It 'returns a BARE host with -AsHost' {
        # The guest script does `scp ... amisad-poc@${STASH_HOST}:/amisad/...`
        # and `curl http://${STASH_HOST}/healthz` -- a URL there produces
        # 'amisad-poc@http://10.0.0.5:' and fails.
        Assert-Equal '192.168.7.138' (Get-PoolExtensionTarget -Area 'stash-service' -AsHost) -Because 'STASH_HOST must be a bare host'
    }
    It 'returns a port-less host when the target carries a port' {
        Clear-PoolExtensionTargetCache -Confirm:$false
        Mock -ModuleName Test.PoolDiscovery Get-PoolStatusDocument {
            return ('{ "pool":"d", "hosts":[ { "hostId":"h", "lastSeenUnixMs":9, "extensionTargets": { "stash-service": "http://10.0.0.5:8443" } } ] }' | ConvertFrom-Json)
        }
        Assert-Equal '10.0.0.5' (Get-PoolExtensionTarget -Area 'stash-service' -AsHost) -Because 'Uri.Host excludes the port'
    }
    It 'tolerates a bare host advertised where a URL was expected' {
        Clear-PoolExtensionTargetCache -Confirm:$false
        Mock -ModuleName Test.PoolDiscovery Get-PoolStatusDocument {
            return ('{ "pool":"d", "hosts":[ { "hostId":"h", "lastSeenUnixMs":9, "extensionTargets": { "stash-service": "10.0.0.6" } } ] }' | ConvertFrom-Json)
        }
        Assert-Equal '10.0.0.6' (Get-PoolExtensionTarget -Area 'stash-service' -AsHost) -Because 'a non-URL target is passed through, not dropped'
    }
    It 'returns empty for an area nobody advertises' {
        Assert-Equal '' (Get-PoolExtensionTarget -Area 'no-such-area') -Because 'callers degrade on empty rather than on an exception'
    }
}

Describe 'Get-PoolExtensionTargetMap -- memoization' {
    BeforeEach { Clear-PoolExtensionTargetCache -Confirm:$false }
    AfterEach  { Clear-PoolExtensionTargetCache -Confirm:$false }

    It 'fetches once and serves the memo on the next call' {
        # Every sequence step expanding ${ext:...} would otherwise re-handshake
        # TLS against the aggregator for an answer that rarely changes.
        Mock -ModuleName Test.PoolDiscovery Get-PoolStatusDocument { return ('{ "pool":"default","hosts":[ { "hostId":"bbbb2222","lastSeenUnixMs":2000,"extensionTargets":{"stash-service":"http://192.168.7.138"} } ] }' | ConvertFrom-Json) }
        $null = Get-PoolExtensionTargetMap
        $null = Get-PoolExtensionTargetMap
        $null = Get-PoolExtensionTargetMap
        Assert-MockCalled -ModuleName Test.PoolDiscovery Get-PoolStatusDocument -Exactly -Times 1 -Scope It
    }
    It 'refetches when -Refresh is passed' {
        Mock -ModuleName Test.PoolDiscovery Get-PoolStatusDocument { return ('{ "pool":"default","hosts":[ { "hostId":"bbbb2222","lastSeenUnixMs":2000,"extensionTargets":{"stash-service":"http://192.168.7.138"} } ] }' | ConvertFrom-Json) }
        $null = Get-PoolExtensionTargetMap
        $null = Get-PoolExtensionTargetMap -Refresh
        Assert-MockCalled -ModuleName Test.PoolDiscovery Get-PoolStatusDocument -Exactly -Times 2 -Scope It
    }
    It 'refetches when the memo is older than the TTL' {
        Mock -ModuleName Test.PoolDiscovery Get-PoolStatusDocument { return ('{ "pool":"default","hosts":[ { "hostId":"bbbb2222","lastSeenUnixMs":2000,"extensionTargets":{"stash-service":"http://192.168.7.138"} } ] }' | ConvertFrom-Json) }
        $null = Get-PoolExtensionTargetMap
        $null = Get-PoolExtensionTargetMap -MaxAgeSeconds 0   # 0 disables the memo
        Assert-MockCalled -ModuleName Test.PoolDiscovery Get-PoolStatusDocument -Exactly -Times 2 -Scope It
    }
    It 'does NOT cache a hard transport failure, so the next lookup retries' {
        # A momentarily unreachable aggregator must not pin an empty answer for
        # the whole TTL -- that would silently break every later step too.
        Mock -ModuleName Test.PoolDiscovery Get-PoolStatusDocument { return $null }
        $null = Get-PoolExtensionTargetMap
        $null = Get-PoolExtensionTargetMap
        Assert-MockCalled -ModuleName Test.PoolDiscovery Get-PoolStatusDocument -Exactly -Times 2 -Scope It
    }
    It 'DOES cache a successful but empty answer' {
        Mock -ModuleName Test.PoolDiscovery Get-PoolStatusDocument { return ('{ "pool":"d", "hosts": [] }' | ConvertFrom-Json) }
        $null = Get-PoolExtensionTargetMap
        $null = Get-PoolExtensionTargetMap
        Assert-MockCalled -ModuleName Test.PoolDiscovery Get-PoolStatusDocument -Exactly -Times 1 -Scope It
    }
}

Describe 'Get-PoolDiscoveryTtlSecond -- the configurable refresh interval' {
    BeforeEach { $script:savedTtl = $env:YURUNA_POOL_DISCOVERY_TTL_SECONDS }
    AfterEach {
        if ($null -eq $script:savedTtl) { Remove-Item Env:YURUNA_POOL_DISCOVERY_TTL_SECONDS -ErrorAction SilentlyContinue }
        else { $env:YURUNA_POOL_DISCOVERY_TTL_SECONDS = $script:savedTtl }
    }
    It 'defaults to 5 minutes' {
        Remove-Item Env:YURUNA_POOL_DISCOVERY_TTL_SECONDS -ErrorAction SilentlyContinue
        Assert-Equal 300 (Get-PoolDiscoveryTtlSecond) -Because '5 minutes is the documented default'
    }
    It 'honors the environment override' {
        $env:YURUNA_POOL_DISCOVERY_TTL_SECONDS = '60'
        Assert-Equal 60 (Get-PoolDiscoveryTtlSecond) -Because 'the interval must be configurable'
    }
    It 'ignores a malformed or negative override instead of throwing' {
        $env:YURUNA_POOL_DISCOVERY_TTL_SECONDS = 'soon'
        Assert-Equal 300 (Get-PoolDiscoveryTtlSecond) -Because 'discovery must never fail on a bad knob'
        $env:YURUNA_POOL_DISCOVERY_TTL_SECONDS = '-5'
        Assert-Equal 300 (Get-PoolDiscoveryTtlSecond) -Because 'a negative TTL is meaningless'
    }
}

Describe 'stash-service.ResolveHost -- pool first, local hypervisor as fallback' {
    $extPath = Join-Path -Path $here -ChildPath '..' -AdditionalChildPath 'extension','stash-service','default.psm1'
    It 'resolves through the pool before touching the local hypervisor' {
        $text = Get-Content -Raw -LiteralPath $extPath
        $poolAt  = $text.IndexOf('Get-PoolExtensionTarget')
        $localAt = $text.IndexOf('Get-VMIp -VMName')
        Assert-True ($poolAt -ge 0)  'the extension must consult pool discovery'
        Assert-True ($localAt -ge 0) 'the local lookup must remain as a fallback for single-host operators'
        Assert-True ($poolAt -lt $localAt) 'the pool is the official path, so it must be tried FIRST'
    }
    It 'asks for a bare host, not a URL' {
        $text = Get-Content -Raw -LiteralPath $extPath
        Assert-True ($text -match "Get-PoolExtensionTarget[^\r\n]*-AsHost") 'STASH_HOST consumers need a bare host'
    }
    It 'imports Test.PoolDiscovery itself rather than assuming an entry point loaded it' {
        # The stash lookup runs under a standalone Test-Sequence.ps1 guest build,
        # not only under the inner runner; those bootstrap different module sets.
        $text = Get-Content -Raw -LiteralPath $extPath
        Assert-True ($text -match 'Test\.PoolDiscovery\.psm1') 'the extension must be self-sufficient'
    }
}


