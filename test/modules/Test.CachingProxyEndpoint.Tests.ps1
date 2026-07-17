<#PSScriptInfo
.VERSION 2026.07.15
.GUID 42b7d3e5-a1c2-4f89-9d34-6e5f7a8b9c01
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test cachingproxy endpoint precedence pester
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
    Pins the operator-source precedence of Resolve-CachingProxyEndpoint:
    vmStart.cachingProxyIP (config) is probed FIRST and wins when its
    HTTP proxy port answers; $env:YURUNA_CACHING_PROXY_IP is probed only
    when the config candidate is absent, invalid, or unreachable; when
    no candidate answers the effective IP clears to '' (probe and
    clear); when neither source is set the resolver is a no-op.
.DESCRIPTION
    Invoke-CachingProxyProbe is mocked in module scope (each It embeds
    its own reachability rule), because real TCP probes cannot be made
    fast here: dead-address SYNs are silently dropped on a
    stealth-firewall host, so every unreachable candidate would burn the
    probe's full 3-attempt x 3 s budget. Which candidate was probed --
    and in what order -- is asserted through the resolver's OWN
    diagnostic Lines (the "(source: ...)" probe headers it emits before
    each probe call), not through mock bookkeeping, so the assertions
    hold against the production code path. Candidate IPs are TEST-NET
    (192.0.2.x); the mock intercepts before any packet would be sent.

    The throw-based Assert-* helpers live at script scope and are
    referenced from It blocks, so this runs under Pester 4.10.1.

    Run: pwsh -NoProfile -File test/modules/Test.CachingProxyEndpoint.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
$vmUtilityModule    = Join-Path $here 'Test.VMUtility.psm1'
$cachingProxyModule = Join-Path $here 'Test.CachingProxy.psm1'

function Assert-True { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because = '') if ($Condition) { throw "Expected false. $Because" } }
function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected '$Expected' but got '$Actual'. $Because" } }

function Get-SourceProbeIndex {
<#
.SYNOPSIS
    Index of the "== Probing caching proxy at ... (source: <tag>) =="
    header in the resolver's Lines output, or -1 when that candidate was
    never probed. Probe order = header order, so comparing two indexes
    asserts which source the resolver tried first.
#>
    [OutputType([int])]
    param(
        [string[]]$Lines,
        [string]$SourceTag
    )
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -like "== Probing caching proxy at*source: $SourceTag*") { return $i }
    }
    return -1
}

$configTag = 'vmStart.cachingProxyIP'
$envTag    = '$env:YURUNA_CACHING_PROXY_IP'

# Fresh -Force import ONCE per suite run (guards against a stale module a
# prior suite loaded into this process) -- NOT per-It in BeforeEach. A
# -Force re-import between Its replaces the module instance, but Pester 4
# caches the Mock -ModuleName injection target per Context: the second It
# in a Context then mocks the EVICTED instance while the resolver runs in
# the new one, silently disabling the mock. The suite's dead-address
# candidates then really get probed (3 attempts x 3 s per candidate on a
# stealth-firewall host) and any It whose expected outcome depends on the
# mock's reachability rule fails.
Import-Module $vmUtilityModule -Global -Force -DisableNameChecking
Import-Module $cachingProxyModule -Force -DisableNameChecking

Describe 'Resolve-CachingProxyEndpoint source precedence' {
    BeforeEach {
        $env:YURUNA_CACHING_PROXY_IP = ''
    }
    AfterEach {
        $env:YURUNA_CACHING_PROXY_IP = ''
    }

    Context 'config candidate is probed first' {
        It 'accepts a reachable config IP without ever probing the env candidate' {
            Mock Invoke-CachingProxyProbe -ModuleName Test.CachingProxy {
                @{ Success = $true; HttpProxyReachable = ($CacheIp -eq '192.0.2.10'); PassCount = 4; WarnCount = 0; FailCount = 0; HttpPort = 3128; HttpsPort = 3129; Lines = @("  [mock] probed $CacheIp") }
            }
            $r = Resolve-CachingProxyEndpoint -EnvIp '192.0.2.20' -ConfigIp '192.0.2.10'
            Assert-Equal -Expected '192.0.2.10' -Actual $r.EffectiveIp -Because 'reachable config candidate wins'
            Assert-True $r.Probed 'a candidate was probed'
            Assert-True ((Get-SourceProbeIndex -Lines $r.Lines -SourceTag $configTag) -ge 0) 'config candidate probed'
            Assert-Equal -Expected (-1) -Actual (Get-SourceProbeIndex -Lines $r.Lines -SourceTag $envTag) -Because 'env candidate must not be probed when the config candidate wins'
        }
        It 'probes config before env when both are dead' {
            Mock Invoke-CachingProxyProbe -ModuleName Test.CachingProxy {
                @{ Success = $false; HttpProxyReachable = $false; PassCount = 0; WarnCount = 1; FailCount = 3; HttpPort = 3128; HttpsPort = 3129; Lines = @("  [mock] probed $CacheIp") }
            }
            $r = Resolve-CachingProxyEndpoint -EnvIp '192.0.2.20' -ConfigIp '192.0.2.10'
            $configIdx = Get-SourceProbeIndex -Lines $r.Lines -SourceTag $configTag
            $envIdx    = Get-SourceProbeIndex -Lines $r.Lines -SourceTag $envTag
            Assert-True ($configIdx -ge 0) 'config candidate probed'
            Assert-True ($envIdx -ge 0) 'env candidate probed after config failure'
            Assert-True ($configIdx -lt $envIdx) 'config candidate must be probed before the env candidate'
        }
    }

    Context 'env candidate is the fallback' {
        It 'falls back to the env IP when the config probe fails' {
            Mock Invoke-CachingProxyProbe -ModuleName Test.CachingProxy {
                @{ Success = $false; HttpProxyReachable = ($CacheIp -eq '192.0.2.20'); PassCount = 1; WarnCount = 1; FailCount = 2; HttpPort = 3128; HttpsPort = 3129; Lines = @("  [mock] probed $CacheIp") }
            }
            $r = Resolve-CachingProxyEndpoint -EnvIp '192.0.2.20' -ConfigIp '192.0.2.10'
            Assert-Equal -Expected '192.0.2.20' -Actual $r.EffectiveIp -Because 'env candidate wins only after the config candidate failed'
            $configIdx = Get-SourceProbeIndex -Lines $r.Lines -SourceTag $configTag
            $envIdx    = Get-SourceProbeIndex -Lines $r.Lines -SourceTag $envTag
            Assert-True ($configIdx -ge 0 -and $envIdx -gt $configIdx) 'config probed first, env probed second'
        }
        It 'falls back to the env IP when the config value is not an IP address' {
            Mock Invoke-CachingProxyProbe -ModuleName Test.CachingProxy {
                @{ Success = $true; HttpProxyReachable = $true; PassCount = 4; WarnCount = 0; FailCount = 0; HttpPort = 3128; HttpsPort = 3129; Lines = @("  [mock] probed $CacheIp") }
            }
            $r = Resolve-CachingProxyEndpoint -EnvIp '192.0.2.20' -ConfigIp 'not-an-ip'
            Assert-Equal -Expected '192.0.2.20' -Actual $r.EffectiveIp -Because 'invalid config candidate is rejected without a probe'
            $rejected = $false
            foreach ($line in $r.Lines) {
                if ($line -like "*'not-an-ip'*not a valid IPv4 or IPv6 address*") { $rejected = $true }
            }
            Assert-True $rejected 'invalid config candidate reported as rejected'
            Assert-Equal -Expected (-1) -Actual (Get-SourceProbeIndex -Lines $r.Lines -SourceTag $configTag) -Because 'format-invalid candidate must be rejected before any probe'
        }
    }

    Context 'probe and clear' {
        It 'clears to empty when no candidate has a reachable HTTP proxy port' {
            Mock Invoke-CachingProxyProbe -ModuleName Test.CachingProxy {
                @{ Success = $false; HttpProxyReachable = $false; PassCount = 0; WarnCount = 1; FailCount = 3; HttpPort = 3128; HttpsPort = 3129; Lines = @("  [mock] probed $CacheIp") }
            }
            $r = Resolve-CachingProxyEndpoint -EnvIp '192.0.2.20' -ConfigIp '192.0.2.10'
            Assert-Equal -Expected '' -Actual $r.EffectiveIp -Because 'no reachable candidate clears the choice'
            Assert-True $r.Probed 'candidates were probed'
        }
        It 'is a no-op when neither source is set' {
            $r = Resolve-CachingProxyEndpoint -EnvIp '' -ConfigIp ''
            Assert-False $r.Probed 'nothing to probe'
            Assert-Equal -Expected '' -Actual $r.EffectiveIp -Because 'nothing resolved'
            Assert-Equal -Expected 0 -Actual (@($r.Lines).Count) -Because 'no diagnostic output for the silent no-op'
        }
    }
}

# Structural (AST) guards: the standalone smoke-test script must resolve its
# target through the SAME resolver -- and therefore the same source order --
# as the runner, not through a private env-var-first reimplementation. The
# script builds a VM probe and exits, so it is parsed rather than invoked.
Describe 'Test-CachingProxy.ps1 resolves through the shared runner-order resolver' {
    $testCpPath = Join-Path (Split-Path -Parent $here) 'Test-CachingProxy.ps1'

    It 'calls Resolve-CachingProxyEndpoint with both -ConfigIp and -EnvIp' {
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($testCpPath, [ref]$null, [ref]$errs)
        Assert-True (-not $errs) "no parse errors in $testCpPath"
        $calls = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Resolve-CachingProxyEndpoint'
        }, $true))
        Assert-True ($calls.Count -ge 1) 'the script routes source resolution through Resolve-CachingProxyEndpoint'
        $paramNames = @($calls[0].CommandElements | Where-Object {
            $_ -is [System.Management.Automation.Language.CommandParameterAst]
        } | ForEach-Object { $_.ParameterName })
        Assert-True ($paramNames -contains 'ConfigIp') 'the config source (vmStart.cachingProxyIP) is offered to the resolver'
        Assert-True ($paramNames -contains 'EnvIp') 'the env source (YURUNA_CACHING_PROXY_IP) is offered to the resolver'
    }
    It 'reads vmStart.cachingProxyIP from test.config.yml and keeps the local-discovery fallback' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($testCpPath, [ref]$null, [ref]$null)
        $readsConfig = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Read-TestConfig'
        }, $true))
        Assert-True ($readsConfig.Count -ge 1) 'the script loads test.config.yml (Read-TestConfig)'
        $keyRefs = @($ast.FindAll({ param($n)
            ($n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.Value -eq 'cachingProxyIP') -or
            ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.Member.Extent.Text -eq 'cachingProxyIP')
        }, $true))
        Assert-True ($keyRefs.Count -ge 1) 'the script extracts the vmStart.cachingProxyIP key'
        $localDiscovery = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and
            $n.GetCommandName() -eq 'Test-CachingProxyAvailable'
        }, $true))
        Assert-True ($localDiscovery.Count -ge 1) 'local discovery remains the final fallback'
    }
    It 'never publishes into $env:YURUNA_CACHING_PROXY_IP (read-only diagnostic)' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($testCpPath, [ref]$null, [ref]$null)
        $envWrites = @($ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $n.Left.Extent.Text -match '(?i)^\$env:YURUNA_CACHING_PROXY_IP$'
        }, $true))
        Assert-True ($envWrites.Count -eq 0) 'the runner publishes the winner; the smoke test must not mutate the session'
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
