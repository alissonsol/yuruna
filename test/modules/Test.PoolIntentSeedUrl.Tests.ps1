<#PSScriptInfo
.VERSION 2026.08.04
.GUID 42c8e4f6-b2d3-4a91-9e45-7f6a8b9c0d12
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool intent seed url precedence pester
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
    Pins the resolution order of Get-PoolIntentSeedUrl, the value baked into the
    pool-control-service VM seed as its intent store.
.DESCRIPTION
    The order encodes a writability claim, so a reordering is a real regression
    rather than a cosmetic one:

      explicit config  -- the operator said what they want
      pool NAS path    -- the one location the daemon can PUSH to
      proxy http URL   -- pull-only; the UI reads and every write fails
      ''               -- nothing resolvable; the guest reports why

    Read-CachingProxyServiceState is mocked in module scope so the proxy branch is
    exercised without a provisioned lab. The proxy IP is TEST-NET (192.0.2.x,
    RFC 5737) and is never contacted -- this resolver only formats a URL.

    Run: pwsh -NoProfile -File test/modules/Test.PoolIntentSeedUrl.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
$cachingProxyModule = Join-Path $here 'Test.CachingProxyService.psm1'

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected '$Expected' but got '$Actual'. $Because" } }

Import-Module $cachingProxyModule -Force -DisableNameChecking

$nasConfig = @{
    pool           = @{ intentGitUrl = '' }
    networkStorage = @{ poolStorageNetworkPath = '\\ypool-nas\work\yuruna.pool' }
}

Describe 'Get-PoolIntentSeedUrl resolution order' {
    BeforeEach { $env:YURUNA_CACHING_PROXY_SERVICE_IP = '' }
    AfterEach  { $env:YURUNA_CACHING_PROXY_SERVICE_IP = '' }

    Context 'an explicit intentGitUrl wins' {
        It 'returns the configured value even when pool storage could supply one' {
            $cfg = @{
                pool           = @{ intentGitUrl = 'ssh://git@example/pool-intent.git' }
                networkStorage = @{ poolStorageNetworkPath = '\\ypool-nas\work\yuruna.pool' }
            }
            Assert-Equal -Expected 'ssh://git@example/pool-intent.git' -Actual (Get-PoolIntentSeedUrl -Config $cfg) `
                -Because 'the operator override outranks every derived value'
        }
        It 'trims surrounding whitespace so the seed env line stays parseable' {
            $cfg = @{ pool = @{ intentGitUrl = '  http://proxy/pool-intent.git  ' } }
            Assert-Equal -Expected 'http://proxy/pool-intent.git' -Actual (Get-PoolIntentSeedUrl -Config $cfg)
        }
    }

    Context 'the read-only proxy route yields to the writable pool mount' {
        # Set-LabToken seeds http://<proxy>/pool-intent.git into this same key so
        # RUNNERS can pull. The daemon COMMITS, and apache serves that route
        # through a plain Alias, so honoring it here hands the service a store
        # every push fails against -- and it stays wrong after the proxy's DHCP
        # address moves, because nothing re-resolves a non-empty value.
        It 'prefers the pool mount over a seeded http route' {
            $cfg = @{
                pool           = @{ intentGitUrl = 'http://192.168.64.4/pool-intent.git' }
                networkStorage = @{ poolStorageNetworkPath = '\\ypool-nas\work\yuruna.pool' }
            }
            Assert-Equal -Expected '/mnt/yuruna-pool/pool-intent.git' -Actual (Get-PoolIntentSeedUrl -Config $cfg) `
                -Because 'a read-only route cannot serve a daemon that pushes'
        }
        It 'keeps the http route when there is no pool storage to prefer' {
            $cfg = @{ pool = @{ intentGitUrl = 'http://192.168.64.4/pool-intent.git' } }
            Assert-Equal -Expected 'http://192.168.64.4/pool-intent.git' -Actual (Get-PoolIntentSeedUrl -Config $cfg) `
                -Because 'a read-only store still beats no store at all'
        }
        It 'does not touch an operator url that merely uses http' {
            $cfg = @{
                pool           = @{ intentGitUrl = 'http://git.example.com/team/intent.git' }
                networkStorage = @{ poolStorageNetworkPath = '\\ypool-nas\work\yuruna.pool' }
            }
            Assert-Equal -Expected 'http://git.example.com/team/intent.git' -Actual (Get-PoolIntentSeedUrl -Config $cfg) `
                -Because 'only the exact seeded shape yields'
        }
    }

    Context 'pool storage supplies the WRITABLE store' {
        It 'derives the guest-side NAS path when no explicit url is set' {
            Assert-Equal -Expected '/mnt/yuruna-pool/pool-intent.git' -Actual (Get-PoolIntentSeedUrl -Config $nasConfig) `
                -Because 'the NAS repo is the only location the daemon can push to'
        }
        It 'honors a non-default guest mount without a doubled separator' {
            Assert-Equal -Expected '/mnt/custom/pool-intent.git' `
                -Actual (Get-PoolIntentSeedUrl -Config $nasConfig -GuestPoolMount '/mnt/custom/')
        }
        It 'prefers the NAS over a reachable proxy' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { @{ ipAddress = '192.0.2.10' } }
            Assert-Equal -Expected '/mnt/yuruna-pool/pool-intent.git' -Actual (Get-PoolIntentSeedUrl -Config $nasConfig) `
                -Because 'a pull-only proxy url must never displace a writable store'
        }
    }

    Context 'the proxy url is the last resort' {
        It 'falls back to the read-only http route when no pool storage is configured' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { @{ ipAddress = '192.0.2.10' } }
            Assert-Equal -Expected 'http://192.0.2.10/pool-intent.git' -Actual (Get-PoolIntentSeedUrl -Config @{ pool = @{ intentGitUrl = '' } })
        }
        It 'accepts the environment override when no state file names a proxy' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { $null }
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = '192.0.2.11'
            Assert-Equal -Expected 'http://192.0.2.11/pool-intent.git' -Actual (Get-PoolIntentSeedUrl -Config $null)
        }
        It 'refuses an IP carrying whitespace or a quote rather than corrupting the seed line' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { @{ ipAddress = "192.0.2.10'" } }
            Assert-Equal -Expected '' -Actual (Get-PoolIntentSeedUrl -Config $null) `
                -Because 'the value lands in an unquoted env line the guest sed-extracts'
        }
    }

    Context 'nothing resolvable' {
        It 'returns empty so the guest reports the reason instead of guessing' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { $null }
            Assert-Equal -Expected '' -Actual (Get-PoolIntentSeedUrl -Config $null)
        }
        It 'treats a whitespace-only intentGitUrl as unset' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { $null }
            Assert-Equal -Expected '' -Actual (Get-PoolIntentSeedUrl -Config @{ pool = @{ intentGitUrl = '   ' } })
        }
    }
}
