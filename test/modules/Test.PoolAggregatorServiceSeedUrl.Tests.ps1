<#PSScriptInfo
.VERSION 2026.08.05
.GUID 42e3a71c-8b95-4d20-a6f4-9c1e5b07d3f8
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool-aggregator service seed url probe pester
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
    Pins the probe-and-discard contract of Get-PoolAggregatorServiceSeedUrl, the
    aggregator address every pool consumer resolves and guest seeds carry.
.DESCRIPTION
    A host can hold three claims about where its caching-proxy service is, and each
    outlives the thing it describes: the stored one keeps its last value on a
    host that stopped running a proxy of its own, and an exported override
    keeps naming a proxy that has since moved. Believing the highest-ranked
    claim unprobed is what turns a moved proxy into a hang -- every consumer
    waiting out a timeout against an address nothing serves, while a live
    proxy sits in the claim right behind it. A guest seeded from that answer
    carries the dead address for the life of the VM, so the regression is not
    self-correcting.

    What the order means is therefore the thing to pin: a PREFERENCE among
    claims that answer, never a reason to skip the ones behind a claim that
    does not. Test-TcpPortReachable and the state reader/writer are mocked in
    module scope, so the whole contract is exercised without a lab and without
    a socket. Addresses are TEST-NET-1 (192.0.2.x, RFC 5737) and each test
    uses its own, so the in-process resolution memo cannot carry one test's
    answer into the next.

    Run: pwsh -NoProfile -File test/modules/Test.PoolAggregatorServiceSeedUrl.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
$cachingProxyModule = Join-Path $here 'Test.CachingProxyService.psm1'

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected '$Expected' but got '$Actual'. $Because" } }

Import-Module $cachingProxyModule -Force -DisableNameChecking

# A config file per address: Read-TestConfig caches on (path, mtime, hash), so
# reusing one path across tests could serve a previous test's parse.
$configDir = Join-Path ([System.IO.Path]::GetTempPath()) 'yuruna-aggregator-url-tests'
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
function Use-ConfigProxyAddress {
    param([string]$Address)
    if (-not $Address) { $env:YURUNA_CONFIG_PATH = (Join-Path $configDir 'absent.yml'); return }
    $path = Join-Path $configDir "config-$Address.yml"
    [System.IO.File]::WriteAllText($path, "vmStart:`n  cachingProxyIp: $Address`n", [System.Text.UTF8Encoding]::new($false))
    $env:YURUNA_CONFIG_PATH = $path
}

Describe 'Get-PoolAggregatorServiceSeedUrl believes a claim only once it answers' {
    BeforeEach {
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = ''
        Mock Save-CachingProxyServiceState -ModuleName Test.CachingProxyService { 'state-path' }
    }
    AfterEach {
        $env:YURUNA_CACHING_PROXY_SERVICE_IP = ''
        $env:YURUNA_CONFIG_PATH      = ''
    }

    Context 'a claim that does not answer is passed over' {
        It 'takes the live config address over a stored and an exported one that are both dead' {
            Mock Read-CachingProxyServiceState  -ModuleName Test.CachingProxyService { @{ ipAddress = '192.0.2.10' } }
            Mock Test-TcpPortReachable   -ModuleName Test.CachingProxyService { return ($TargetHost -eq '192.0.2.12') }
            $env:YURUNA_CACHING_PROXY_SERVICE_IP = '192.0.2.11'
            Use-ConfigProxyAddress '192.0.2.12'
            Assert-Equal -Expected 'https://192.0.2.12:9400' -Actual (Get-PoolAggregatorServiceSeedUrl) `
                -Because 'a dead claim must not consume the resolution it outranks'
        }
        It 'repairs the stored address it disproved, so the next call pays no probe for it' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { @{ ipAddress = '192.0.2.13' } }
            Mock Test-TcpPortReachable  -ModuleName Test.CachingProxyService { return ($TargetHost -eq '192.0.2.14') }
            Use-ConfigProxyAddress '192.0.2.14'
            [void](Get-PoolAggregatorServiceSeedUrl)
            Assert-MockCalled Save-CachingProxyServiceState -ModuleName Test.CachingProxyService -Scope It -Times 1 -Exactly `
                -ParameterFilter { $IpAddress -eq '192.0.2.14' }
        }
        It 'skips a claim carrying a quote and lets the next one resolve' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { @{ ipAddress = "192.0.2.15'" } }
            Mock Test-TcpPortReachable  -ModuleName Test.CachingProxyService { return ($TargetHost -eq '192.0.2.16') }
            Use-ConfigProxyAddress '192.0.2.16'
            Assert-Equal -Expected 'https://192.0.2.16:9400' -Actual (Get-PoolAggregatorServiceSeedUrl) `
                -Because 'a value that would corrupt the seed line must cost only itself'
        }
    }

    Context 'the order still ranks claims that do answer' {
        It 'keeps the stored address when it answers, even though a config address also does' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { @{ ipAddress = '192.0.2.20' } }
            Mock Test-TcpPortReachable  -ModuleName Test.CachingProxyService { $true }
            Use-ConfigProxyAddress '192.0.2.21'
            Assert-Equal -Expected 'https://192.0.2.20:9400' -Actual (Get-PoolAggregatorServiceSeedUrl) `
                -Because 'a host that runs its own proxy must keep using it'
        }
        It 'writes nothing when the stored address is the one that won' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { @{ ipAddress = '192.0.2.22' } }
            Mock Test-TcpPortReachable  -ModuleName Test.CachingProxyService { $true }
            Use-ConfigProxyAddress '192.0.2.23'
            [void](Get-PoolAggregatorServiceSeedUrl)
            Assert-MockCalled Save-CachingProxyServiceState -ModuleName Test.CachingProxyService -Scope It -Times 0 -Exactly
        }
    }

    Context 'the probe proves the address the answer names' {
        It 'probes the aggregator port rather than the proxy port' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { @{ ipAddress = '' } }
            Mock Test-TcpPortReachable  -ModuleName Test.CachingProxyService { $true }
            Use-ConfigProxyAddress '192.0.2.30'
            [void](Get-PoolAggregatorServiceSeedUrl)
            Assert-MockCalled Test-TcpPortReachable -ModuleName Test.CachingProxyService -Scope It -Times 1 -Exactly `
                -ParameterFilter { $Port -eq 9400 }
        }
    }

    Context 'a host that stores no address of its own' {
        It 'resolves from the config key without starting to claim ownership' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { @{ ipAddress = '' } }
            Mock Test-TcpPortReachable  -ModuleName Test.CachingProxyService { $true }
            Use-ConfigProxyAddress '192.0.2.40'
            Assert-Equal -Expected 'https://192.0.2.40:9400' -Actual (Get-PoolAggregatorServiceSeedUrl)
            # An empty key means "I run no proxy", not "I have not noticed one yet".
            Assert-MockCalled Save-CachingProxyServiceState -ModuleName Test.CachingProxyService -Scope It -Times 0 -Exactly
        }
    }

    Context 'nothing answers' {
        It 'returns empty so the consuming service leaves its features off' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { @{ ipAddress = '192.0.2.50' } }
            Mock Test-TcpPortReachable  -ModuleName Test.CachingProxyService { $false }
            Use-ConfigProxyAddress '192.0.2.51'
            Assert-Equal -Expected '' -Actual (Get-PoolAggregatorServiceSeedUrl)
        }
        It 'leaves the stored address alone when there is nothing verified to replace it with' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { @{ ipAddress = '192.0.2.52' } }
            Mock Test-TcpPortReachable  -ModuleName Test.CachingProxyService { $false }
            Use-ConfigProxyAddress '192.0.2.53'
            [void](Get-PoolAggregatorServiceSeedUrl)
            Assert-MockCalled Save-CachingProxyServiceState -ModuleName Test.CachingProxyService -Scope It -Times 0 -Exactly
        }
        It 'returns empty without probing when no claim exists at all' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { @{ ipAddress = '' } }
            Mock Test-TcpPortReachable  -ModuleName Test.CachingProxyService { $true }
            Use-ConfigProxyAddress ''
            Assert-Equal -Expected '' -Actual (Get-PoolAggregatorServiceSeedUrl)
            Assert-MockCalled Test-TcpPortReachable -ModuleName Test.CachingProxyService -Scope It -Times 0 -Exactly
        }
    }

    Context 'a preview resolves but does not write' {
        It 'still returns the address so the preview can name it' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { @{ ipAddress = '192.0.2.60' } }
            Mock Test-TcpPortReachable  -ModuleName Test.CachingProxyService { return ($TargetHost -eq '192.0.2.61') }
            Use-ConfigProxyAddress '192.0.2.61'
            Assert-Equal -Expected 'https://192.0.2.61:9400' -Actual (Get-PoolAggregatorServiceSeedUrl -WhatIf)
        }
        It 'repairs nothing under -WhatIf' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { @{ ipAddress = '192.0.2.62' } }
            Mock Test-TcpPortReachable  -ModuleName Test.CachingProxyService { return ($TargetHost -eq '192.0.2.63') }
            Use-ConfigProxyAddress '192.0.2.63'
            [void](Get-PoolAggregatorServiceSeedUrl -WhatIf)
            # -WhatIf does not reach a module on its own, so the ShouldProcess
            # gate inside it is the only thing that can honour one.
            Assert-MockCalled Save-CachingProxyServiceState -ModuleName Test.CachingProxyService -Scope It -Times 0 -Exactly
        }
    }

    Context 'the cost is paid once per process' {
        It 'answers a repeat call from the memo instead of re-probing' {
            Mock Read-CachingProxyServiceState -ModuleName Test.CachingProxyService { @{ ipAddress = '' } }
            Mock Test-TcpPortReachable  -ModuleName Test.CachingProxyService { $true }
            Use-ConfigProxyAddress '192.0.2.70'
            $first  = Get-PoolAggregatorServiceSeedUrl
            $second = Get-PoolAggregatorServiceSeedUrl
            Assert-Equal -Expected $first -Actual $second
            # A render that emits several guests must not re-probe for each one.
            Assert-MockCalled Test-TcpPortReachable -ModuleName Test.CachingProxyService -Scope It -Times 1 -Exactly
        }
    }
}
