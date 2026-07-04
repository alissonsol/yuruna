<#PSScriptInfo
.VERSION 2026.07.03
.GUID 42e3f4a5-b6c7-4d89-9e01-3f4a5b6c7d8e
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
    the desiredState fail-safe mapping. The git PULL + pool.state.json write are
    integration-verified against a real bare repo.
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.PoolSync.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning 'powershell-yaml unavailable.' }

function Assert-Equal { param($Expected, $Actual, [string]$Because = '') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because = '') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-Null  { param($Actual, [string]$Because = '') if ($null -ne $Actual) { throw "Expected null got [$Actual]. $Because" } }

Describe 'Get-YurunaPoolConfig (feature on/off)' {
    It 'is off when there is no pool block' {
        Assert-Null (Get-YurunaPoolConfig -Config ([ordered]@{ networkStorage = [ordered]@{} })) 'no pool block -> off'
    }
    It 'is off when enabled is false (unless -IgnoreEnabled)' {
        $cfg = [ordered]@{ pool = [ordered]@{ enabled = $false; intentGitUrl = 'http://p/i.git' } }
        Assert-Null (Get-YurunaPoolConfig -Config $cfg) 'enabled:false -> off'
        Assert-Equal -Expected 'http://p/i.git' -Actual (Get-YurunaPoolConfig -Config $cfg -IgnoreEnabled).IntentGitUrl -Because '-IgnoreEnabled returns the object'
    }
    It 'is off (loud) when enabled but intentGitUrl is empty' {
        $cfg = [ordered]@{ pool = [ordered]@{ enabled = $true; intentGitUrl = '' } }
        Assert-Null (Get-YurunaPoolConfig -Config $cfg -WarningAction SilentlyContinue) 'enabled + empty url -> off'
    }
    It 'returns a populated object when enabled + url set' {
        $cfg = [ordered]@{ pool = [ordered]@{ enabled = $true; intentGitUrl = ' http://proxy/pool-intent.git '; pullTimeoutSeconds = 20 } }
        $o = Get-YurunaPoolConfig -Config $cfg
        Assert-True $o.Enabled 'Enabled true'
        Assert-Equal -Expected 'http://proxy/pool-intent.git' -Actual $o.IntentGitUrl -Because 'url trimmed'
        Assert-Equal -Expected 20 -Actual $o.PullTimeoutSec -Because 'pull timeout'
        Assert-True (-not [string]::IsNullOrWhiteSpace($o.LocalClonePath)) 'clone path defaulted'
    }
    It 'carries NO poolId field (membership is pools.yml-only)' {
        $cfg = [ordered]@{ pool = [ordered]@{ enabled = $true; intentGitUrl = 'http://p/i.git' } }
        $o = Get-YurunaPoolConfig -Config $cfg
        Assert-True (-not ($o.PSObject.Properties.Name -contains 'PoolId')) 'no PoolId in the config object'
    }
}

Describe 'Resolve-YurunaPoolForHost (member -> pool)' {
    $intent = [ordered]@{ schemaVersion = 1; pools = @(
        [ordered]@{ poolId = 'lab';  members = @('42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'); desiredState = 'paused' },
        [ordered]@{ poolId = 'prod'; members = @('42cccccccccccccccccccccccccccccc'); desiredState = 'run' }
    ) }
    It 'finds the pool whose members contain the hostId' {
        Assert-Equal -Expected 'lab'  -Actual (Resolve-YurunaPoolForHost -Intent $intent -HostId '42bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb').poolId -Because 'member of lab'
        Assert-Equal -Expected 'prod' -Actual (Resolve-YurunaPoolForHost -Intent $intent -HostId '42cccccccccccccccccccccccccccccc').poolId -Because 'member of prod'
    }
    It 'returns null for a non-member' {
        Assert-Null (Resolve-YurunaPoolForHost -Intent $intent -HostId '42ffffffffffffffffffffffffffffff') 'non-member'
    }
    It 'returns null for empty hostId, null intent, or no pools key' {
        Assert-Null (Resolve-YurunaPoolForHost -Intent $intent -HostId '') 'empty hostId'
        Assert-Null (Resolve-YurunaPoolForHost -Intent $null -HostId '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') 'null intent'
        Assert-Null (Resolve-YurunaPoolForHost -Intent ([ordered]@{ schemaVersion = 1 }) -HostId '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') 'no pools key'
    }
}

Describe 'Resolve-YurunaPoolDesiredState (fail-safe)' {
    It 'passes through run / paused / drain' {
        Assert-Equal -Expected 'run'    -Actual (Resolve-YurunaPoolDesiredState -Pool ([ordered]@{ desiredState = 'run' }))    -Because 'run'
        Assert-Equal -Expected 'paused' -Actual (Resolve-YurunaPoolDesiredState -Pool ([ordered]@{ desiredState = 'paused' })) -Because 'paused'
        Assert-Equal -Expected 'drain'  -Actual (Resolve-YurunaPoolDesiredState -Pool ([ordered]@{ desiredState = 'drain' }))  -Because 'drain'
    }
    It 'defaults to run for null, missing field, or an unknown value' {
        Assert-Equal -Expected 'run' -Actual (Resolve-YurunaPoolDesiredState -Pool $null) -Because 'null -> run'
        Assert-Equal -Expected 'run' -Actual (Resolve-YurunaPoolDesiredState -Pool ([ordered]@{ poolId = 'x' })) -Because 'missing -> run'
        Assert-Equal -Expected 'run' -Actual (Resolve-YurunaPoolDesiredState -Pool ([ordered]@{ desiredState = 'banana' })) -Because 'unknown -> run (fail-safe)'
    }
    It 'is case-insensitive' {
        Assert-Equal -Expected 'paused' -Actual (Resolve-YurunaPoolDesiredState -Pool ([ordered]@{ desiredState = 'PAUSED' })) -Because 'PAUSED -> paused'
    }
}

Describe 'ConvertTo-PoolGatingRecord (gating normalization)' {
    It 'returns an empty record for a null or empty gating block (alert-with-defaults signal)' {
        Assert-Equal -Expected 0 -Actual (ConvertTo-PoolGatingRecord -Gating $null).Count -Because 'null -> empty record'
        Assert-Equal -Expected 0 -Actual (ConvertTo-PoolGatingRecord -Gating ([ordered]@{})).Count -Because 'empty -> empty record'
    }
    It 'copies only the known knobs from a full block' {
        $g = [ordered]@{ failuresBeforeAlert = 5; successesBeforeRearm = 4; extra = 'drop'; quorum = [ordered]@{ healthyThreshold = 0.75; degradedAfterMinutes = 10; junk = 1 } }
        $rec = ConvertTo-PoolGatingRecord -Gating $g
        Assert-Equal -Expected 5 -Actual $rec['failuresBeforeAlert'] -Because 'failuresBeforeAlert'
        Assert-Equal -Expected 4 -Actual $rec['successesBeforeRearm'] -Because 'successesBeforeRearm'
        Assert-Equal -Expected 0.75 -Actual $rec['quorum']['healthyThreshold'] -Because 'healthyThreshold'
        Assert-Equal -Expected 10 -Actual $rec['quorum']['degradedAfterMinutes'] -Because 'degradedAfterMinutes'
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
    $runtimeDir = Join-Path ([System.IO.Path]::GetTempPath()) ("yps-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null
    $savedRuntime = $env:YURUNA_RUNTIME_DIR
    $env:YURUNA_RUNTIME_DIR = $runtimeDir
    try {
        It 'writes gating into the state file when present' {
            $gating = [ordered]@{ failuresBeforeAlert = 3; quorum = [ordered]@{ healthyThreshold = 0.5; degradedAfterMinutes = 30 } }
            $null = Write-YurunaPoolState -PoolId 'lab' -DesiredState 'run' -IntentOk:$true -Gating $gating -Confirm:$false
            $state = Get-Content -Raw -LiteralPath (Join-Path $runtimeDir 'pool.state.json') | ConvertFrom-Json
            Assert-Equal -Expected 'lab' -Actual $state.poolId -Because 'poolId'
            Assert-Equal -Expected 3 -Actual $state.gating.failuresBeforeAlert -Because 'gating.failuresBeforeAlert'
            Assert-Equal -Expected 0.5 -Actual $state.gating.quorum.healthyThreshold -Because 'gating.quorum.healthyThreshold'
        }
        It 'writes a null gating when the pool authored none' {
            $null = Write-YurunaPoolState -PoolId 'lab' -DesiredState 'run' -IntentOk:$true -Confirm:$false
            $state = Get-Content -Raw -LiteralPath (Join-Path $runtimeDir 'pool.state.json') | ConvertFrom-Json
            Assert-Null $state.gating 'gating null when not supplied'
        }
    } finally {
        $env:YURUNA_RUNTIME_DIR = $savedRuntime
        Remove-Item -LiteralPath $runtimeDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
