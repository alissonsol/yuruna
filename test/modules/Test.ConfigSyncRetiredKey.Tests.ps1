<#PSScriptInfo
.VERSION 2026.09.18
.GUID 42a6d0b4-8e17-4c92-b5a3-6f019d3ce7a2
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test config sync retired keys networkStorage pester
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
    A reference host one rename behind still hands over its networkStorage --
    paths, users and the credentials that follow them -- for every host type.
.DESCRIPTION
    The config sync reads current key names only. A value parked under a retired
    spelling therefore looks exactly like a value that is not there, and for
    networkStorage "not there" is not inert: the converter reads a missing
    poolStorageNetworkPath as "the reference has no pool storage configured" and
    CLEARS the tier. That takes the user names with it, so the credential sync
    that runs next iterates an empty list and no password is fetched either. A
    reference host erased the section it was fetched to supply, and the only
    signal was a warning that said the tier was being cleared.

    The freshness gate already NAMED all six retired networkStorage keys; what
    was missing was anything that acted on them. These cases pin the migration
    that closes it, and pin it per host type, because the converter's output is
    platform-shaped (drive letters, /mnt, ~/Shares) and a rename that only
    survives on one of them is not a fix.

    The case-only renames are the trap worth its own case: PowerShell
    dictionaries compare keys case-insensitively, so a migration written the
    obvious way "finds" vmStart.cachingProxyIP in a config that spells it the
    current way, and removes the current key on its way to rewriting it.

    Throw-based assertions (no Should), so the file runs standalone.
    Run: pwsh -NoProfile -File test/modules/Test.ConfigSyncRetiredKey.Tests.ps1
#>

BeforeAll {
    $here     = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)

    Import-Module (Join-Path $here 'Test.Assert.psm1')            -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.PoolStorage.psm1')       -Force -DisableNameChecking -ErrorAction SilentlyContinue
    Import-Module (Join-Path $here 'Test.ConfigServiceSync.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.CatalogSource.psm1') -Force -DisableNameChecking
    # After ConfigServiceSync: it imports both of these itself with -Force, which
    # evicts an earlier global import into its own module scope.
    Import-Module (Join-Path $here 'Test.ConfigSync.psm1')        -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.ConfigNaming.psm1')      -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostIdentity.psm1')      -Force -Global -DisableNameChecking

    $script:RepoRootPath = $repoRoot

    # A reference host that predates the storage rename, spelled exactly as
    # Get-RetiredConfigKeyMap lists it.
    $script:RetiredJson = @'
{
  "networkStorage": {
    "poolLocalPath": "/mnt/ypool-nas",
    "poolNetworkPath": "//ypool-nas/work/yuruna.pool",
    "poolNetworkUser": "yuruna-pool",
    "moveLogsToPoolStorage": true,
    "stashLocalPath": "/mnt/ystash-nas",
    "stashNetworkPath": "//ystash-nas/work/yuruna.stash",
    "stashNetworkUser": "yuruna-stash"
  },
  "testCycle": { "stepTimeoutMinutes": 45 },
  "vmStart": { "cachingProxyIP": "192.168.7.9" }
}
'@

    function Get-RetiredReference { $script:RetiredJson | ConvertFrom-Json -AsHashtable }
}

Describe 'Update-RetiredConfigKey' {
    It 'moves every retired networkStorage spelling onto its current path' {
        $cfg = Get-RetiredReference
        $done = @(Update-RetiredConfigKey -Config $cfg -Confirm:$false)
        $ns = $cfg['networkStorage']
        foreach ($k in 'poolStorageLocalPath', 'poolStorageNetworkPath', 'poolStorageNetworkUser',
                       'stashStorageLocalPath', 'stashStorageNetworkPath', 'stashStorageNetworkUser') {
            Assert-True ([bool]"$($ns[$k])".Trim()) "the reference value never reached $k"
        }
        foreach ($k in 'poolNetworkPath', 'stashNetworkUser') {
            Assert-False ($ns.Contains($k)) "the retired key $k survived the migration"
        }
        Assert-True ($done.Count -ge 6) "expected at least the six storage renames, got $($done.Count)"
    }

    It 'applies the unit factor on a duration rename' {
        # A pure key move would land 45 SECONDS where 45 minutes was meant, which
        # is a worse outcome than dropping it: the step timeout silently becomes
        # 60x too short and every long step starts failing.
        $cfg = Get-RetiredReference
        [void](Update-RetiredConfigKey -Config $cfg -Confirm:$false)
        Assert-Equal 2700 $cfg['testCycle']['stepTimeoutSeconds'] '45 minutes must arrive as 2700 seconds'
        Assert-False ($cfg['testCycle'].Contains('stepTimeoutMinutes')) 'the retired duration key survived'
    }

    It 'leaves a config that is already current completely alone' {
        # The case-only rename trap. A dictionary lookup for 'cachingProxyIP'
        # succeeds on a config holding 'cachingProxyIp', so a migration that
        # trusted it would rewrite -- and briefly remove -- a correct key on
        # every single sync from a healthy reference host.
        $clean = '{ "vmStart": { "cachingProxyIp": "192.168.7.9" }, "networkStorage": { "poolStorageNetworkPath": "//a/b" } }' |
            ConvertFrom-Json -AsHashtable
        $done = @(Update-RetiredConfigKey -Config $clean -Confirm:$false)
        Assert-Equal 0 $done.Count "a current config was migrated: $(($done | ForEach-Object { $_.Old }) -join ', ')"
        Assert-StringEqual '192.168.7.9' $clean['vmStart']['cachingProxyIp'] 'the current value was disturbed'
        Assert-StringEqual 'cachingProxyIp' (@($clean['vmStart'].Keys) -join ',') 'the stored key name changed spelling'
    }

    It 'migrates a case-only rename when the config really does use the old spelling' {
        $cfg = Get-RetiredReference
        [void](Update-RetiredConfigKey -Config $cfg -Confirm:$false)
        Assert-StringEqual '192.168.7.9' $cfg['vmStart']['cachingProxyIp'] 'the value did not arrive under the current name'
        Assert-StringEqual 'cachingProxyIp' (@($cfg['vmStart'].Keys) -join ',') 'the key kept its retired spelling'
    }

    It 'keeps the current value when a config carries both spellings' {
        # The new name is what the host has been maintaining; the retired one is
        # what it stopped reading. Preferring the stale copy would move a host
        # BACKWARDS on every sync.
        $both = '{ "networkStorage": { "poolNetworkUser": "old-account", "poolStorageNetworkUser": "yuruna-pool" } }' |
            ConvertFrom-Json -AsHashtable
        $done = @(Update-RetiredConfigKey -Config $both -Confirm:$false)
        Assert-StringEqual 'yuruna-pool' $both['networkStorage']['poolStorageNetworkUser'] 'the retired value overwrote the current one'
        Assert-False ($both['networkStorage'].Contains('poolNetworkUser')) 'the retired key was left behind'
        Assert-StringEqual 'superseded' (@($done | Where-Object { $_.Old -eq 'networkStorage.poolNetworkUser' })[0].Action) `
            'a dropped duplicate has to be reported as superseded, not as a migration'
    }

    It 'is a no-op on a non-map and on a config with none of the retired keys' {
        Assert-Equal 0 @(Update-RetiredConfigKey -Config 'not a config' -Confirm:$false).Count 'a scalar must not throw or invent migrations'
        $empty = @{}
        Assert-Equal 0 @(Update-RetiredConfigKey -Config $empty -Confirm:$false).Count 'an empty config must not be migrated'
    }
}

Describe 'the reference-to-host conversion, after migration' {
    It 'delivers both storage tiers and both users to every host type' {
        # Per host type, because the converter's output is platform-shaped. A
        # rename that only survives into one idiom is not a fix for a lab that
        # mixes Windows, macOS and Ubuntu hosts.
        $expect = @{
            'host.windows.hyper-v' = @{ Pool = 'y:';                 Stash = 'z:';                 Sep = '\\' }
            'host.macos.utm'       = @{ Pool = '~/Shares/ypool-nas'; Stash = '~/Shares/ystash-nas'; Sep = '//' }
            'host.ubuntu.kvm'      = @{ Pool = '/mnt/ypool-nas';     Stash = '/mnt/ystash-nas';     Sep = '//' }
        }
        foreach ($hostType in $expect.Keys) {
            $cfg = Get-RetiredReference
            [void](Update-RetiredConfigKey -Config $cfg -Confirm:$false)
            $merge = Merge-ConfigSyncReferenceConfig -Reference $cfg -Local $null -HostType $hostType
            $ns = $merge.Config['networkStorage']

            Assert-StringEqual $expect[$hostType].Pool  $ns['poolStorageLocalPath']  "$hostType got the wrong pool mount point"
            Assert-StringEqual $expect[$hostType].Stash $ns['stashStorageLocalPath'] "$hostType got the wrong stash mount point"
            Assert-Match ([regex]::Escape($expect[$hostType].Sep)) $ns['poolStorageNetworkPath'] "$hostType got the wrong share-path slash style"
            Assert-StringEqual 'yuruna-pool'  $ns['poolStorageNetworkUser']  "$hostType lost the pool user"
            Assert-StringEqual 'yuruna-stash' $ns['stashStorageNetworkUser'] "$hostType lost the stash user"
            Assert-True ([bool]$ns['moveLogsToPoolStorage']) "$hostType lost the archive mode that travels with the pool tier"

            # The users ARE the credential sync's work list: an empty list is why
            # no password ever followed the config across.
            $users = @('poolStorageNetworkUser', 'stashStorageNetworkUser' |
                ForEach-Object { "$($ns[$_])".Trim() } | Where-Object { $_ })
            Assert-Equal 2 $users.Count "$hostType would sync credentials for $($users.Count) user(s), not 2"
        }
    }

    It 'still clears a tier the reference genuinely does not configure' {
        # The clearing branch is correct behavior -- the reference is the source
        # of truth. What was wrong was reaching it because of a spelling.
        $cfg = '{ "networkStorage": { "poolNetworkPath": "//p/q", "poolNetworkUser": "u", "poolLocalPath": "/mnt/p" } }' |
            ConvertFrom-Json -AsHashtable
        [void](Update-RetiredConfigKey -Config $cfg -Confirm:$false)
        $merge = Merge-ConfigSyncReferenceConfig -Reference $cfg -Local $null -HostType 'host.ubuntu.kvm'
        $ns = $merge.Config['networkStorage']
        Assert-StringEqual '' $ns['stashStorageNetworkPath'] 'a tier the reference does not configure must still be cleared'
        Assert-StringEqual '//p/q' $ns['poolStorageNetworkPath'] 'the configured tier must survive'
    }
}

Describe 'the sync entry point' {
    It 'migrates before it judges freshness' {
        # Order is the difference between a reference that syncs unattended and
        # one that cannot: the freshness gate is a hard failure under
        # -NonInteractive, so judging first would fail a reference whose only
        # drift is a spelling this code can fix in flight.
        $fn = Get-YurunaTestFunctionAst -Path (Join-Path $script:RepoRootPath 'test/modules/Test.ConfigServiceSync.psm1') -Name 'Sync-HostConfiguration'
        Assert-NotNull $fn 'Sync-HostConfiguration went missing'
        $body = $fn.Extent.Text
        $migrateAt = $body.IndexOf('Update-RetiredConfigKey')
        $freshAt   = $body.IndexOf('Test-ConfigSyncReferenceFreshness')
        Assert-True ($migrateAt -ge 0) 'the sync no longer migrates retired key names'
        Assert-True ($freshAt -ge 0)   'the freshness gate went missing'
        Assert-True ($migrateAt -lt $freshAt) 'the migration has to run before the freshness gate'
        Assert-Match 'Update-TestConfigNaming' ((Get-CatalogSourceMessage -Source $body) -join "`n") `
            'the operator still has to be told to fix the reference at the source; an in-flight translation only helps this one sync'
    }
}

Describe 'the poolStorage setup questionnaire' {
    It 'asks nothing once the config and the credential are both in place' {
        # A sync writes all three values and stores the credential. Re-asking
        # made the operator retype, by hand, what the sync had just fetched --
        # and the questionnaire is the only route to the mount and the identity
        # reclaim, so it could not simply be declined.
        $d = Get-PoolStorageSetupDecision -NetworkPath '//ypool-nas/work' -NetworkUser 'yuruna-pool' `
                -LocalPath '/mnt/ypool-nas' -HasSecret
        Assert-StringEqual 'configured' $d.Action 'a fully configured host must not be questioned'
    }

    It 'treats a missing credential as unfinished, not as configured' {
        $d = Get-PoolStorageSetupDecision -NetworkPath '//ypool-nas/work' -NetworkUser 'yuruna-pool' -LocalPath '/mnt/ypool-nas'
        Assert-StringEqual 'partial' $d.Action 'config without a credential is a mount that cannot authenticate'
        Assert-Match 'credential' $d.Gap 'the gap has to name what is missing'
    }

    It 'separates a never-configured host from a half-configured one' {
        Assert-StringEqual 'absent'  (Get-PoolStorageSetupDecision).Action 'nothing set is not partial'
        Assert-StringEqual 'partial' (Get-PoolStorageSetupDecision -NetworkPath '//a/b').Action 'one value set is not absent'
    }
}
