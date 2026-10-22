<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42d51fa5-ad15-451c-8e70-d870a6c34b99
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool sync pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES powershell-yaml
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Pester coverage for the pure (no-I/O) parts of Test.PoolSync.psm1: the pool
    config accessor (off/on cases), this-host pool resolution from members[], and
    the configuredState fail-safe mapping. The git PULL + pool.state.json write are
    integration-verified against a real bare repo.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.PoolSync.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning 'powershell-yaml unavailable.' }

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# Pure value fixtures belong at file scope, above the first Describe: a Describe body
# is executed during the discovery pass and everything it declares is torn down before
# the first It runs, so a doc built inside one reaches the assertion as $null.
$script:MemberConfiguration = [ordered]@{ schemaVersion = 1; pools = @(
    [ordered]@{ poolId = 'lab';  members = @('42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'); configuredState = 'paused' },
    [ordered]@{ poolId = 'prod'; members = @('42cccccccccccccccccccccccccccccc'); configuredState = 'run' }
) }

}

Describe 'Get-YurunaPoolConfig (feature on/off)' {
    It 'is off when there is no pool block' {
        Assert-Null (Get-YurunaPoolConfig -Config ([ordered]@{ networkStorage = [ordered]@{} })) 'no pool block -> off'
    }
    It 'is off when enabled is false (unless -IgnoreEnabled)' {
        $cfg = [ordered]@{ pool = [ordered]@{ enabled = $false; configurationGitUrl = 'http://p/i.git' } }
        Assert-Null (Get-YurunaPoolConfig -Config $cfg) 'enabled:false -> off'
        Assert-Equal -Expected 'http://p/i.git' -Actual (Get-YurunaPoolConfig -Config $cfg -IgnoreEnabled).ConfigurationGitUrl -Because '-IgnoreEnabled returns the object'
    }
    It 'is off (loud) when enabled but configurationGitUrl is empty' {
        $cfg = [ordered]@{ pool = [ordered]@{ enabled = $true; configurationGitUrl = '' } }
        Assert-Null (Get-YurunaPoolConfig -Config $cfg -WarningAction SilentlyContinue) 'enabled + empty url -> off'
    }
    It 'returns a populated object when enabled + url set' {
        $cfg = [ordered]@{ pool = [ordered]@{ enabled = $true; configurationGitUrl = ' http://proxy/pool-configuration.git '; pullTimeoutSeconds = 20 } }
        $o = Get-YurunaPoolConfig -Config $cfg
        Assert-True $o.Enabled 'Enabled true'
        Assert-Equal -Expected 'http://proxy/pool-configuration.git' -Actual $o.ConfigurationGitUrl -Because 'url trimmed'
        Assert-Equal -Expected 20 -Actual $o.PullTimeoutSeconds -Because 'pull timeout'
        Assert-True (-not [string]::IsNullOrWhiteSpace($o.LocalClonePath)) 'clone path defaulted'
    }
    It 'carries NO poolId field (membership is pools.yml-only)' {
        $cfg = [ordered]@{ pool = [ordered]@{ enabled = $true; configurationGitUrl = 'http://p/i.git' } }
        $o = Get-YurunaPoolConfig -Config $cfg
        Assert-True (-not ($o.PSObject.Properties.Name -contains 'PoolId')) 'no PoolId in the config object'
    }
}

Describe 'Resolve-YurunaPoolForHost (member -> pool)' {
    It 'finds the pool whose members contain the hostId' {
        Assert-Equal -Expected 'lab'  -Actual (Resolve-YurunaPoolForHost -Configuration $script:MemberConfiguration -HostId '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb').poolId -Because 'member of lab'
        Assert-Equal -Expected 'prod' -Actual (Resolve-YurunaPoolForHost -Configuration $script:MemberConfiguration -HostId '42cccccccccccccccccccccccccccccc').poolId -Because 'member of prod'
    }
    It 'returns null for a non-member' {
        Assert-Null (Resolve-YurunaPoolForHost -Configuration $script:MemberConfiguration -HostId '42ffffffffffffffffffffffffffffff') 'non-member'
    }
    It 'returns null for empty hostId, null configuration, or no pools key' {
        Assert-Null (Resolve-YurunaPoolForHost -Configuration $script:MemberConfiguration -HostId '') 'empty hostId'
        Assert-Null (Resolve-YurunaPoolForHost -Configuration $null -HostId '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') 'null configuration'
        Assert-Null (Resolve-YurunaPoolForHost -Configuration ([ordered]@{ schemaVersion = 1 }) -HostId '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') 'no pools key'
    }
}

Describe 'Resolve-YurunaPoolConfiguredState (fail-safe)' {
    It 'passes through run / paused / drain' {
        Assert-Equal -Expected 'run'    -Actual (Resolve-YurunaPoolConfiguredState -Pool ([ordered]@{ configuredState = 'run' }))    -Because 'run'
        Assert-Equal -Expected 'paused' -Actual (Resolve-YurunaPoolConfiguredState -Pool ([ordered]@{ configuredState = 'paused' })) -Because 'paused'
        Assert-Equal -Expected 'drain'  -Actual (Resolve-YurunaPoolConfiguredState -Pool ([ordered]@{ configuredState = 'drain' }))  -Because 'drain'
    }
    It 'defaults to run for null, missing field, or an unknown value' {
        Assert-Equal -Expected 'run' -Actual (Resolve-YurunaPoolConfiguredState -Pool $null) -Because 'null -> run'
        Assert-Equal -Expected 'run' -Actual (Resolve-YurunaPoolConfiguredState -Pool ([ordered]@{ poolId = 'x' })) -Because 'missing -> run'
        Assert-Equal -Expected 'run' -Actual (Resolve-YurunaPoolConfiguredState -Pool ([ordered]@{ configuredState = 'banana' })) -Because 'unknown -> run (fail-safe)'
    }
    It 'is case-insensitive' {
        Assert-Equal -Expected 'paused' -Actual (Resolve-YurunaPoolConfiguredState -Pool ([ordered]@{ configuredState = 'PAUSED' })) -Because 'PAUSED -> paused'
    }
}

Describe 'ConvertTo-PoolGatingRecord (gating normalization)' {
    It 'returns an empty record for a null or empty gating block (alert-with-defaults signal)' {
        $empty = ConvertTo-PoolGatingRecord -Gating $null
        Assert-NotNull $empty 'null input must produce a record'
        Assert-True ($empty -is [Collections.IDictionary]) 'empty result must remain a dictionary'
        Assert-Equal -Expected 0 -Actual $empty.Count -Because 'null -> empty record'
        Assert-Equal -Expected 0 -Actual (ConvertTo-PoolGatingRecord -Gating ([ordered]@{})).Count -Because 'empty -> empty record'
    }
    It 'copies only the known knobs from a full block' {
        $g = [ordered]@{ failuresBeforeAlert = 5; successesBeforeRearm = 4; extra = 'drop'; quorum = [ordered]@{ healthyThreshold = 0.75; degradedAfterSeconds = 10; junk = 1 } }
        $rec = ConvertTo-PoolGatingRecord -Gating $g
        Assert-Equal -Expected 5 -Actual $rec['failuresBeforeAlert'] -Because 'failuresBeforeAlert'
        Assert-Equal -Expected 4 -Actual $rec['successesBeforeRearm'] -Because 'successesBeforeRearm'
        Assert-Equal -Expected 0.75 -Actual $rec['quorum']['healthyThreshold'] -Because 'healthyThreshold'
        Assert-Equal -Expected 10 -Actual $rec['quorum']['degradedAfterSeconds'] -Because 'degradedAfterSeconds'
        Assert-True (-not $rec.Contains('extra')) 'extra key dropped'
        Assert-True (-not $rec['quorum'].Contains('junk')) 'junk quorum key dropped'
    }
    It 'omits the quorum sub-object when the block has only top-level knobs' {
        $rec = ConvertTo-PoolGatingRecord -Gating ([ordered]@{ failuresBeforeAlert = 2 })
        Assert-Equal -Expected 2 -Actual $rec['failuresBeforeAlert'] -Because 'failuresBeforeAlert kept'
        Assert-True (-not $rec.Contains('quorum')) 'no quorum sub-object'
    }
}

Describe 'Write-YurunaPoolState (gating round-trips through pool.state.json)' {
    # Side-effecting fixtures belong in BeforeAll rather than at file scope. A Describe
    # body runs at discovery, so a try/finally wrapped around the It blocks would create
    # AND delete the runtime dir before any test executed. File scope is no refuge either:
    # when this file is invoked directly the body is evaluated once per phase, so a fresh
    # temp dir is minted twice while $env:YURUNA_RUNTIME_DIR -- process-global, last write
    # wins -- ends up naming the OTHER directory than the one the It blocks captured, and
    # the state file lands where nothing reads it. BeforeAll/AfterAll run in the run phase,
    # which keeps the dir the module writes and the dir the assertions read identical.
    BeforeAll {
        $script:StateRuntimeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("yps-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:StateRuntimeDir | Out-Null
        $script:SavedRuntimeDir = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = $script:StateRuntimeDir
    }
    AfterAll {
        $env:YURUNA_RUNTIME_DIR = $script:SavedRuntimeDir
        Remove-Item -LiteralPath $script:StateRuntimeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'writes gating into the state file when present' {
        $gating = [ordered]@{ failuresBeforeAlert = 3; quorum = [ordered]@{ healthyThreshold = 0.5; degradedAfterSeconds = 1800 } }
        $null = Write-YurunaPoolState -PoolId 'lab' -ConfiguredState 'run' -ConfigurationOk:$true -Gating $gating -Confirm:$false
        $state = Get-Content -Raw -LiteralPath (Join-Path $script:StateRuntimeDir 'pool.state.json') | ConvertFrom-Json
        Assert-Equal -Expected 'lab' -Actual $state.poolId -Because 'poolId'
        Assert-Equal -Expected 3 -Actual $state.gating.failuresBeforeAlert -Because 'gating.failuresBeforeAlert'
        Assert-Equal -Expected 0.5 -Actual $state.gating.quorum.healthyThreshold -Because 'gating.quorum.healthyThreshold'
    }
    It 'writes a null gating when the pool authored none' {
        $null = Write-YurunaPoolState -PoolId 'lab' -ConfiguredState 'run' -ConfigurationOk:$true -Confirm:$false
        $state = Get-Content -Raw -LiteralPath (Join-Path $script:StateRuntimeDir 'pool.state.json') | ConvertFrom-Json
        Assert-Null $state.gating 'gating null when not supplied'
    }
}

Describe 'Sync-YurunaPoolConfiguration reads legacy pool operations' {
    BeforeAll {
        $script:PriorSyncRuntimeDir = $env:YURUNA_RUNTIME_DIR
    }
    BeforeEach {
        $script:SyncFixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:SyncClone = Join-Path $script:SyncFixture 'clone'
        $env:YURUNA_RUNTIME_DIR = Join-Path $script:SyncFixture 'runtime'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $script:SyncClone '.git'), $env:YURUNA_RUNTIME_DIR
        $script:SyncConfig = @{ pool = @{ enabled = $true; configurationGitUrl = 'https://example.invalid/pools.git'; localClonePath = $script:SyncClone } }
        Mock -ModuleName Test.PoolSync Invoke-PoolSyncGit { 0 }
        Mock -ModuleName Test.PoolSync Test-PoolConfigurationCloneOrigin { $true }
    }
    AfterAll {
        $env:YURUNA_RUNTIME_DIR = $script:PriorSyncRuntimeDir
    }
    It 'honors <Operation> from schemaVersion <Version> and publishes canonical state' -ForEach @(
        @{ Version = 2; Operation = 'paused' }
        @{ Version = 2; Operation = 'drain' }
        @{ Version = 3; Operation = 'paused' }
        @{ Version = 3; Operation = 'drain' }
    ) {
        $doc = [ordered]@{ schemaVersion = $Version; pools = @([ordered]@{
            poolId = 'lab'; members = @('42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'); desiredState = $Operation
        }) }
        $poolsPath = Join-Path $script:SyncClone 'pools.yml'
        Set-Content -LiteralPath $poolsPath -Value (ConvertTo-Yaml $doc)
        $before = Get-Content -Raw -LiteralPath $poolsPath
        $pool = Sync-YurunaPoolConfiguration -Config $script:SyncConfig -HostId '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $pool['configuredState'] | Should -BeExactly $Operation
        $pool.Contains('desiredState') | Should -BeFalse
        $state = Get-Content -Raw -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'pool.state.json') | ConvertFrom-Json -AsHashtable
        $state['configuredState'] | Should -BeExactly $Operation
        $state['configurationOk'] | Should -BeTrue
        $state.ContainsKey('desiredState') | Should -BeFalse
        $state.ContainsKey('intentOk') | Should -BeFalse
        Get-Content -Raw -LiteralPath $poolsPath | Should -BeExactly $before -Because 'runner normalization never writes its configuration cache'
    }
    It 'rejects conflicting states and clears stale pool output' {
        $doc = [ordered]@{ schemaVersion = 3; pools = @([ordered]@{
            poolId = 'lab'; members = @('42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'); desiredState = 'paused'; configuredState = 'run'
        }) }
        Set-Content -LiteralPath (Join-Path $script:SyncClone 'pools.yml') -Value (ConvertTo-Yaml $doc)
        $manifest = Join-Path $env:YURUNA_RUNTIME_DIR 'pool.manifest.json'
        Set-Content -LiteralPath $manifest -Value '{}'
        Sync-YurunaPoolConfiguration -Config $script:SyncConfig -HostId '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        $state = Get-Content -Raw -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'pool.state.json') | ConvertFrom-Json -AsHashtable
        $state['configurationOk'] | Should -BeFalse
        $state['poolId'] | Should -BeNullOrEmpty
        Test-Path -LiteralPath $manifest | Should -BeFalse
    }
    It 'rejects schemaVersion <Version> when the converter cannot normalize it' -ForEach @(
        @{ Version = 5 }
        @{ Version = '4' }
    ) {
        $doc = [ordered]@{ schemaVersion = $Version; pools = @([ordered]@{
            poolId = 'lab'; members = @('42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'); configuredState = 'paused'
        }) }
        Set-Content -LiteralPath (Join-Path $script:SyncClone 'pools.yml') -Value (ConvertTo-Yaml $doc)
        Sync-YurunaPoolConfiguration -Config $script:SyncConfig -HostId '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        $state = Get-Content -Raw -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'pool.state.json') | ConvertFrom-Json -AsHashtable
        $state['configurationOk'] | Should -BeFalse
        $state['poolId'] | Should -BeNullOrEmpty
    }
}
