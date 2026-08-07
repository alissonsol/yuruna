<#PSScriptInfo
.VERSION 2026.08.07
.GUID 42d8b1e5-9c37-4a06-b2f8-5e1d7a4c93b0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool worker standalone conversion pester
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
    Pester coverage for the pure rules in Test.PoolWorker.psm1: which local
    service VMs a standalone-to-worker conversion retires, which hosts-file
    aliases it drops, and whether the end state is actually a worker.
.DESCRIPTION
    Throw-based assertions so the file runs under the OS-bundled Pester 3.4 and
    Pester 5+. Every rule under test takes its facts as parameters, so no
    hypervisor, no reference host, and no lab are required.

    The cases that matter most are the REFUSALS. Each rule here guards a failure
    that produces green cycles against the wrong service or a mount pointed at a
    share only this machine can read, so a rule that is too eager is as bad as
    one that is too shy -- and both directions are pinned below.

    Run: pwsh -NoProfile -File test/modules/Test.PoolWorker.Tests.ps1
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.PoolWorker.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue

# File scope, above the first Describe: a Describe body runs during discovery and
# everything it declares is discarded before the first It.
function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ("$Expected" -ne "$Actual") { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because = '') if ($Condition) { throw "Expected false. $Because" } }

# Pester is not installed on every host that runs this repo's scripts, and the
# assertions above are plain throws, so the harness this file needs is three
# functions. Defined only when the real ones are absent; every fixture is
# computed at file scope, so the immediate-run shim and Pester's
# discovery-then-run split observe the same state. Same shim as
# Test.StorageTransition.Tests.ps1, for the same reason: the rules under test
# guard a conversion an operator runs on a machine that may have nothing else
# installed, and a suite that only runs where Pester happens to be is a suite
# nobody runs there.
if (-not (Get-Command -Name 'Describe' -ErrorAction SilentlyContinue)) {
    function Describe { param([string]$Name, [scriptblock]$Fixture) Write-Output "Describe: $Name"; & $Fixture }
    function It       { param([string]$Name, [scriptblock]$Test)    & $Test; Write-Output "    [pass] $Name" }
}

# Every call below is wrapped in @(). These functions hand a list to the
# pipeline, which unrolls it, so a one-element result arrives as the bare
# element -- and indexing THAT with [0] silently reads the first property of a
# record, or the first character of a server name, instead of failing. The
# wrapper is the same contract production callers keep.

function New-ServiceFact {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: builds an in-memory record and touches nothing.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Key = 'stash-service',
        [string]$VMName = 'yuruna-stash-service',
        [string]$DisplayName = 'stash service',
        [string]$StartScript = 'Start-StashServiceVM.ps1',
        [string]$State = 'running'
    )
    [pscustomobject]@{ Key = $Key; VMName = $VMName; DisplayName = $DisplayName
        StartScript = $StartScript; State = $State }
}

Describe 'Get-PoolWorkerStopScriptName' {
    It 'derives the stop script from the start script' {
        Assert-Equal 'Stop-StashServiceVM.ps1' (Get-PoolWorkerStopScriptName -StartScript 'Start-StashServiceVM.ps1')
        Assert-Equal 'Stop-CachingProxyServiceVM.ps1' (Get-PoolWorkerStopScriptName -StartScript 'Start-CachingProxyServiceVM.ps1')
    }
    It 'returns empty for a name that is not a Start script' {
        # The caller reports a service it cannot retire rather than composing a
        # path that does not exist.
        Assert-Equal '' (Get-PoolWorkerStopScriptName -StartScript 'Invoke-Something.ps1')
        Assert-Equal '' (Get-PoolWorkerStopScriptName -StartScript '')
        Assert-Equal '' (Get-PoolWorkerStopScriptName -StartScript 'Start-.ps1')
    }
}

Describe 'Get-PoolWorkerServiceTeardownPlan' {
    It 'retires every service that is present, the caching proxy included' {
        $plan = @(Get-PoolWorkerServiceTeardownPlan -Service @(
            (New-ServiceFact -Key 'caching-proxy' -VMName 'yuruna-caching-proxy-service' -StartScript 'Start-CachingProxyServiceVM.ps1' -State 'running')
            (New-ServiceFact -State 'stopped')))
        Assert-Equal 2 $plan.Count
        Assert-Equal 'retire' $plan[0].Action
        Assert-Equal 'retire' $plan[1].Action
    }
    It 'retires a stopped VM rather than leaving it, because the cycle sweep restarts it' {
        $plan = @(Get-PoolWorkerServiceTeardownPlan -Service @((New-ServiceFact -State 'stopped')))
        Assert-Equal 'retire' $plan[0].Action
    }
    It 'reports absent as the converged state, not a failure' {
        $plan = @(Get-PoolWorkerServiceTeardownPlan -Service @((New-ServiceFact -State 'absent')))
        Assert-Equal 'absent' $plan[0].Action
    }
    It 'treats an unreadable state as PRESENT' {
        # Assuming absence here would skip the teardown of a running VM, and a
        # live local service silently wins every extension lookup. A stop script
        # run against a genuinely absent VM is a cheap no-op; the reverse is not.
        $plan = @(Get-PoolWorkerServiceTeardownPlan -Service @((New-ServiceFact -State 'unknown')))
        Assert-Equal 'retire' $plan[0].Action
    }
    It 'flags a present VM it has no stop script for' {
        $plan = @(Get-PoolWorkerServiceTeardownPlan -Service @((New-ServiceFact -StartScript 'Build-Thing.ps1' -State 'running')))
        Assert-Equal 'unretirable' $plan[0].Action
    }
    It 'does not flag an ABSENT VM it has no stop script for' {
        $plan = @(Get-PoolWorkerServiceTeardownPlan -Service @((New-ServiceFact -StartScript 'Build-Thing.ps1' -State 'absent')))
        Assert-Equal 'absent' $plan[0].Action
    }
    It 'accepts an empty roster' {
        Assert-Equal 0 (@(Get-PoolWorkerServiceTeardownPlan -Service @())).Count
    }
}

Describe 'Get-PoolWorkerAdvertisementPlan' {
    It 'withdraws every advertisement this host still carries' {
        $plan = @(Get-PoolWorkerAdvertisementPlan -AdvertisedArea @('stash-service', 'download-agent-service') -ExemptArea @())
        Assert-Equal 2 $plan.Count
        Assert-Equal 'clear' $plan[0].Action
        Assert-Equal 'clear' $plan[1].Action
    }
    It 'withdraws a claim whose VM is already gone' {
        # The case no stop script can reach, and the one that survives every
        # re-run: the marker outlives the VM, so a host whose services were
        # removed by other means advertises them forever.
        $plan = @(Get-PoolWorkerAdvertisementPlan -AdvertisedArea @('stash-service') -ExemptArea @())
        Assert-Equal 'clear' $plan[0].Action
    }
    It 'keeps the areas the caller is still running' {
        $plan = @(Get-PoolWorkerAdvertisementPlan -AdvertisedArea @('pool-aggregator-service') `
            -ExemptArea @('pool-aggregator-service'))
        Assert-Equal 'kept' $plan[0].Action
    }
    It 'matches the exemption case-insensitively' {
        $plan = @(Get-PoolWorkerAdvertisementPlan -AdvertisedArea @('Pool-Aggregator-Service') `
            -ExemptArea @('pool-aggregator-service'))
        Assert-Equal 'kept' $plan[0].Action
    }
    It 'de-duplicates and ignores blanks' {
        $plan = @(Get-PoolWorkerAdvertisementPlan -AdvertisedArea @('stash-service', 'stash-service', '', '  ') -ExemptArea @())
        Assert-Equal 1 $plan.Count
    }
    It 'has nothing to do on a host that advertises nothing' {
        Assert-Equal 0 (@(Get-PoolWorkerAdvertisementPlan -AdvertisedArea @() -ExemptArea @())).Count
        Assert-Equal 0 (@(Get-PoolWorkerAdvertisementPlan -AdvertisedArea $null -ExemptArea $null)).Count
    }
}

Describe 'Get-PoolWorkerCachingProxyArea' {
    It 'covers the aggregator, which has no VM of its own to keep it alive' {
        # It is hosted INSIDE the caching-proxy VM, so no service-roster entry
        # covers it and -KeepCachingProxy would otherwise withdraw a claim that
        # is still true.
        Assert-True (@(Get-PoolWorkerCachingProxyArea) -contains 'pool-aggregator-service')
    }
}

Describe 'Get-PoolWorkerLocalShareName' {
    It 'reads the tier share out of a NAS-shaped path' {
        Assert-Equal 'yuruna.pool' (Get-PoolWorkerLocalShareName -NetworkPath '//ypool-nas/work/yuruna.pool')
    }
    It 'reads the same name out of the shape a local bring-up publishes' {
        # The whole point: the two layouts differ in everything but this, so one
        # name answers "does this machine still publish the tier?" either way.
        Assert-Equal 'yuruna.pool' (Get-PoolWorkerLocalShareName -NetworkPath '//ypool-nas/yuruna.pool')
    }
    It 'accepts the Windows spelling and a trailing separator' {
        Assert-Equal 'yuruna.stash' (Get-PoolWorkerLocalShareName -NetworkPath '\\ystash-nas\work\yuruna.stash')
        Assert-Equal 'yuruna.stash' (Get-PoolWorkerLocalShareName -NetworkPath '//ystash-nas/work/yuruna.stash/')
    }
    It 'reads no share out of a path that names only a server' {
        Assert-Equal '' (Get-PoolWorkerLocalShareName -NetworkPath '//ypool-nas')
        Assert-Equal '' (Get-PoolWorkerLocalShareName -NetworkPath '')
        Assert-Equal '' (Get-PoolWorkerLocalShareName -NetworkPath $null)
    }
}

Describe 'Get-PoolWorkerAliasPlan' {
    It 'drops the dashboard alias, which named a service VM this host no longer runs' {
        $plan = @(Get-PoolWorkerAliasPlan -CandidateName @('yuruna-dash') -ConfiguredServer @() `
            -Resolution @{ 'yuruna-dash' = '192.168.7.20' })
        Assert-Equal 'drop' $plan[0].Action
    }
    It 'KEEPS a storage alias the synced configuration still names' {
        # The decisive case. 'ypool-nas' means this machine on a host that served
        # its own shares and the lab's NAS on one that does not, and the config
        # names it either way -- dropping it here would undo the repoint the sync
        # just made and leave the mount with a name nothing resolves.
        $plan = @(Get-PoolWorkerAliasPlan -CandidateName @('ypool-nas') -ConfiguredServer @('ypool-nas') `
            -Resolution @{ 'ypool-nas' = '127.0.0.1' })
        Assert-Equal 'keep' $plan[0].Action
    }
    It 'drops a loopback storage alias the configuration no longer names' {
        $plan = @(Get-PoolWorkerAliasPlan -CandidateName @('ystash-nas') -ConfiguredServer @('lab-nas') `
            -Resolution @{ 'ystash-nas' = '127.0.0.1' })
        Assert-Equal 'drop' $plan[0].Action
    }
    It 'keeps an unconfigured alias that resolves off this machine' {
        # Someone else's, or an earlier lab's. Not this conversion's to remove.
        $plan = @(Get-PoolWorkerAliasPlan -CandidateName @('ypool-nas') -ConfiguredServer @() `
            -Resolution @{ 'ypool-nas' = '192.168.7.99' })
        Assert-Equal 'keep' $plan[0].Action
    }
    It 'keeps a name that does not resolve, because there is no entry to drop' {
        $plan = @(Get-PoolWorkerAliasPlan -CandidateName @('ypool-nas') -ConfiguredServer @() -Resolution @{})
        Assert-Equal 'keep' $plan[0].Action
    }
    It 'matches the configured server case-insensitively' {
        $plan = @(Get-PoolWorkerAliasPlan -CandidateName @('YPOOL-NAS') -ConfiguredServer @('ypool-nas') `
            -Resolution @{ 'YPOOL-NAS' = '127.0.0.1' })
        Assert-Equal 'keep' $plan[0].Action
    }
    It 'de-duplicates repeated candidates' {
        $plan = @(Get-PoolWorkerAliasPlan -CandidateName @('yuruna-dash', 'yuruna-dash') -ConfiguredServer @() `
            -Resolution @{ 'yuruna-dash' = '10.0.0.5' })
        Assert-Equal 1 $plan.Count
    }
    It 'keeps the dashboard alias when the configuration somehow names it as a storage server' {
        # Contrived, but the configured-server check runs FIRST on purpose: a name
        # the mount depends on is never dropped, whatever else is true of it.
        $plan = @(Get-PoolWorkerAliasPlan -CandidateName @('yuruna-dash') -ConfiguredServer @('yuruna-dash') `
            -Resolution @{ 'yuruna-dash' = '10.0.0.5' })
        Assert-Equal 'keep' $plan[0].Action
    }
}

Describe 'Get-PoolWorkerConfiguredServer' {
    It 'reads both tiers out of a config document' {
        $config = @{ networkStorage = @{
            poolStorageNetworkPath  = '//lab-nas/yuruna.pool'
            stashStorageNetworkPath = '//lab-nas/yuruna.stash' } }
        $servers = @(Get-PoolWorkerConfiguredServer -Config $config)
        Assert-Equal 1 $servers.Count
        Assert-Equal 'lab-nas' $servers[0]
    }
    It 'skips an unconfigured tier' {
        $config = @{ networkStorage = @{
            poolStorageNetworkPath  = '\\ypool-nas\yuruna.pool'
            stashStorageNetworkPath = '' } }
        $servers = @(Get-PoolWorkerConfiguredServer -Config $config)
        Assert-Equal 1 $servers.Count
        Assert-Equal 'ypool-nas' $servers[0]
    }
    It 'returns nothing for a config with no networkStorage node' {
        Assert-Equal 0 (@(Get-PoolWorkerConfiguredServer -Config @{})).Count
        Assert-Equal 0 (@(Get-PoolWorkerConfiguredServer -Config $null)).Count
    }
}

Describe 'Get-PoolWorkerReadinessVerdict' {
    It 'is ready when every service is gone and the rest checks out' {
        $v = Get-PoolWorkerReadinessVerdict -Service @((New-ServiceFact -State 'absent')) `
            -ActiveExtension @() -StorageIsLocal $false -UnconvergedVaultUser @() `
            -CachingProxyIp '192.168.7.229' -CachingProxyIsLocal $false
        Assert-True $v.Ready $($v.Problem -join '; ')
        Assert-True ($v.Checked.Count -ge 5) 'every dimension is reported as checked'
    }
    It 'refuses a host that still has a local service VM' {
        # The failure this whole conversion exists for: the cycles PASS, against
        # this host's own stash instead of the lab's.
        $v = Get-PoolWorkerReadinessVerdict -Service @((New-ServiceFact -State 'running')) `
            -ActiveExtension @() -StorageIsLocal $false -UnconvergedVaultUser @() `
            -CachingProxyIp '192.168.7.229' -CachingProxyIsLocal $false
        Assert-False $v.Ready
        Assert-True (($v.Problem -join ' ') -match 'wins the address lookup') 'the reason names the lookup precedence'
    }
    It 'refuses a host whose service state could not be read' {
        $v = Get-PoolWorkerReadinessVerdict -Service @((New-ServiceFact -State 'unknown')) `
            -ActiveExtension @() -StorageIsLocal $false -UnconvergedVaultUser @() `
            -CachingProxyIp '192.168.7.229' -CachingProxyIsLocal $false
        Assert-False $v.Ready
        Assert-True (($v.Problem -join ' ') -match 'could not be read') 'the reason distinguishes unreadable from present'
    }
    It 'refuses a host still advertising an extension service to the aggregator' {
        $v = Get-PoolWorkerReadinessVerdict -Service @() -ActiveExtension @('stash-service') `
            -StorageIsLocal $false -UnconvergedVaultUser @() `
            -CachingProxyIp '192.168.7.229' -CachingProxyIsLocal $false
        Assert-False $v.Ready
    }
    It 'refuses a host whose storage still resolves to itself' {
        $v = Get-PoolWorkerReadinessVerdict -Service @() -ActiveExtension @() `
            -StorageIsLocal $true -UnconvergedVaultUser @() `
            -CachingProxyIp '192.168.7.229' -CachingProxyIsLocal $false
        Assert-False $v.Ready
    }
    It 'refuses a host still publishing the share its configuration mounts from the lab' {
        # Two copies of the tier reachable under one name, and the live SMB
        # session decides which one a mount of that name actually lands on.
        $v = Get-PoolWorkerReadinessVerdict -Service @() -ActiveExtension @() `
            -StorageIsLocal $false -ServedShare @('yuruna.pool') -UnconvergedVaultUser @() `
            -CachingProxyIp '192.168.7.229' -CachingProxyIsLocal $false
        Assert-False $v.Ready
        Assert-True (($v.Problem -join ' ') -match 'yuruna.pool') 'the reason names the share'
    }
    It 'refuses a host whose configured tier is not mounted' {
        $v = Get-PoolWorkerReadinessVerdict -Service @() -ActiveExtension @() `
            -StorageIsLocal $false -UnmountedTier @('stash') -UnconvergedVaultUser @() `
            -CachingProxyIp '192.168.7.229' -CachingProxyIsLocal $false
        Assert-False $v.Ready
        Assert-True (($v.Problem -join ' ') -match 'buffer locally') 'the reason names what is lost'
    }
    It 'refuses a host holding a credential the reference never supplied' {
        $v = Get-PoolWorkerReadinessVerdict -Service @() -ActiveExtension @() `
            -StorageIsLocal $false -UnconvergedVaultUser @('yuruna-pool') `
            -CachingProxyIp '192.168.7.229' -CachingProxyIsLocal $false
        Assert-False $v.Ready
        Assert-True (($v.Problem -join ' ') -match 'yuruna-pool') 'the reason names the user'
    }
    It 'refuses a host still pointed at its own caching proxy' {
        $v = Get-PoolWorkerReadinessVerdict -Service @() -ActiveExtension @() `
            -StorageIsLocal $false -UnconvergedVaultUser @() `
            -CachingProxyIp '192.168.7.20' -CachingProxyIsLocal $true
        Assert-False $v.Ready
    }
    It 'refuses a host with no caching proxy at all' {
        $v = Get-PoolWorkerReadinessVerdict -Service @() -ActiveExtension @() `
            -StorageIsLocal $false -UnconvergedVaultUser @() `
            -CachingProxyIp '' -CachingProxyIsLocal $false
        Assert-False $v.Ready
    }
    It 'reports every problem at once rather than stopping at the first' {
        # An operator re-running after each single fix pays a full conversion per
        # problem; the list is what makes one more run enough.
        $v = Get-PoolWorkerReadinessVerdict -Service @((New-ServiceFact -State 'running')) `
            -ActiveExtension @('stash-service') -StorageIsLocal $true `
            -UnconvergedVaultUser @('yuruna-pool') -CachingProxyIp '' -CachingProxyIsLocal $false
        Assert-True ($v.Problem.Count -ge 5) "expected every problem, got $($v.Problem.Count)"
    }
    It 'does not fail a service the caller deliberately kept' {
        # -KeepCachingProxy must not make the conversion refuse its own outcome.
        $v = Get-PoolWorkerReadinessVerdict `
            -Service @((New-ServiceFact -Key 'caching-proxy' -DisplayName 'caching-proxy service' -State 'running')) `
            -ActiveExtension @() -StorageIsLocal $false -UnconvergedVaultUser @() `
            -CachingProxyIp '192.168.7.229' -CachingProxyIsLocal $false `
            -ExemptServiceKey @('caching-proxy')
        Assert-True $v.Ready $($v.Problem -join '; ')
    }
    It 'still fails a DIFFERENT service when one is exempted' {
        $v = Get-PoolWorkerReadinessVerdict -Service @(
                (New-ServiceFact -Key 'caching-proxy' -State 'running')
                (New-ServiceFact -Key 'stash-service' -State 'running')) `
            -ActiveExtension @() -StorageIsLocal $false -UnconvergedVaultUser @() `
            -CachingProxyIp '192.168.7.229' -CachingProxyIsLocal $false `
            -ExemptServiceKey @('caching-proxy')
        Assert-False $v.Ready
        Assert-Equal 1 $v.Problem.Count
    }
    It 'ignores blank entries in the advertised and unconverged lists' {
        $v = Get-PoolWorkerReadinessVerdict -Service @() -ActiveExtension @('', '  ') `
            -StorageIsLocal $false -ServedShare @('', '  ') -UnmountedTier @('', '  ') `
            -UnconvergedVaultUser @('', '  ') `
            -CachingProxyIp '192.168.7.229' -CachingProxyIsLocal $false
        Assert-True $v.Ready $($v.Problem -join '; ')
    }
    It 'is ready on a host with no storage configured at all' {
        # A worker joining a lab that names no networkStorage: no tier is
        # unmounted because no tier exists, and the absence must not read as a
        # failed mount.
        $v = Get-PoolWorkerReadinessVerdict -Service @() -ActiveExtension @() `
            -StorageIsLocal $false -ServedShare @() -UnmountedTier @() -UnconvergedVaultUser @() `
            -CachingProxyIp '192.168.7.229' -CachingProxyIsLocal $false
        Assert-True $v.Ready $($v.Problem -join '; ')
    }
}

Describe 'Test-PoolWorkerAddressIsThisHost' {
    It 'recognizes loopback' {
        Assert-True (Test-PoolWorkerAddressIsThisHost -Address '127.0.0.1')
        Assert-True (Test-PoolWorkerAddressIsThisHost -Address '::1')
    }
    It 'does not claim an unrelated address' {
        # TEST-NET-3 (RFC 5737): reserved for documentation, so it can never be a
        # real interface on the machine running this suite.
        Assert-False (Test-PoolWorkerAddressIsThisHost -Address '203.0.113.7')
    }
    It 'treats an empty address as not this host' {
        Assert-False (Test-PoolWorkerAddressIsThisHost -Address '')
        Assert-False (Test-PoolWorkerAddressIsThisHost -Address $null)
    }
    It 'resolves a name before answering' {
        Assert-True (Test-PoolWorkerAddressIsThisHost -Address 'localhost')
    }
    It 'does not throw on a name that does not resolve' {
        Assert-False (Test-PoolWorkerAddressIsThisHost -Address 'no-such-host.invalid')
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
