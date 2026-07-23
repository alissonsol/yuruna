<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42e6f7a8-b9c0-4d12-9345-6e7f8a9b0c1d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool planner pester
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
    Pester coverage for test-set execution: the pool planner's pure
    compat/selection logic, HostId-scoped VM naming, the per-guest keystroke
    merge, manifest I/O, and the end-to-end test-set / pool plan resolution
    (incl. Resolve-CyclePlan parity) against a minimal sequence fixture.
#>

$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.HostDetection.psm1')   -Force -DisableNameChecking -ErrorAction SilentlyContinue
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning 'powershell-yaml unavailable.' }
Import-Module (Join-Path $here 'Test.SequenceResolve.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Invoke-Sequence.psm1')      -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.Capability.psm1')      -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.StateFile.psm1')       -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.SequencePlanner.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.PoolSync.psm1')        -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.PoolPlanner.psm1')     -Force -DisableNameChecking -ErrorAction SilentlyContinue

function Assert-Equal { param($Expected, $Actual, [string]$Because='') if ($Expected -ne $Actual) { throw "Expected [$Expected] got [$Actual]. $Because" } }
function Assert-True  { param($Condition, [string]$Because='') if (-not $Condition) { throw "Expected true. $Because" } }
function Assert-False { param($Condition, [string]$Because='') if ($Condition) { throw "Expected false. $Because" } }
function Assert-Null  { param($Actual, [string]$Because='') if ($null -ne $Actual) { throw "Expected null got [$Actual]. $Because" } }

function New-TempDir {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test temp dir.')]
    [CmdletBinding()] [OutputType([string])] param()
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ("yrn-poolplan-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $d
    return $d
}

# Everything an It block reads must be declared unqualified and above the first
# Describe. A Describe body runs during the discovery pass and its declarations are
# discarded before any It executes; a $script:-qualified name binds to the test
# framework's own script scope rather than this file's, so both forms read back as
# $null from inside an assertion. That also fixes the region of the file a fixture may
# live in: below the first Describe is already too late.
$Compat = [ordered]@{ schemaVersion = 1; rules = @(
    [ordered]@{ guestKey = 'guest.windows.11';       hypervisors = @('hyper-v') },
    [ordered]@{ guestKey = 'guest.ubuntu.server.24'; hypervisors = @('hyper-v', 'kvm', 'utm') }
) }

$RunnableCandidates = @('guest.windows.11', 'guest.ubuntu.server.24', 'guest.amazon.linux.2023')

# --- REGION: Sequence-fixture integration: Resolve-TestSetCyclePlan + parity + Resolve-PoolCyclePlan
function New-PlannerFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test fixture tree.')]
    [CmdletBinding()] [OutputType([hashtable])] param()
    $root = New-TempDir
    $seqDir = Join-Path $root 'sequences'
    $null = New-Item -ItemType Directory -Force -Path $seqDir
    @"
description: test install
keystrokeMechanism: gui
resource:
  ubuntu.server.24: []
  windows.11: []
variables:
  username: baseuser
  hostname: basehost
  region: us
workload: []
"@ | Set-Content (Join-Path $seqDir 'install.yml')
    $projTest = Join-Path $root 'project/test'
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $projTest 'test-sets')
    "sequences:`n  - install`n" | Set-Content (Join-Path $projTest 'test.runner.yml')
    @"
schemaVersion: 1
name: smoke
sequences:
  - install
requiredGuests:
  - guest.ubuntu.server.24
perGuestOverrides:
  guest.ubuntu.server.24:
    keystrokeMechanism: SSH
    username: webuser
    variables:
      region: eu
"@ | Set-Content (Join-Path $projTest 'test-sets/smoke.yml')
    ($Compat | ConvertTo-Yaml) | Set-Content (Join-Path $projTest 'guests.compatibility.yml')
    # Guest folder so Test-GuestFolder passes for ubuntu on a kvm host.
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $root (Join-Path (Get-HostFolder 'host.ubuntu.kvm') 'guest.ubuntu.server.24'))
    return @{ Root = $root; SequencesDir = (Join-Path $root 'sequences') }
}

# Fixture with BOTH an orchestration sequence (InvokeTestSequence steps, no
# resource:/baseline) and a guest sequence, so the runner's orchestration
# detection (Get-CycleOrchestrationList) and the guest planner (Resolve-CyclePlan)
# can each be exercised, plus the mixed/guest-only/orch-only test.runner.yml cases.
# The caller writes project/test/test.runner.yml per case.
function New-OrchestrationFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions','',Justification='Test fixture tree.')]
    [CmdletBinding()] [OutputType([hashtable])] param()
    $root = New-TempDir
    $seqDir = Join-Path $root 'sequences'
    $null = New-Item -ItemType Directory -Force -Path $seqDir
    @"
name: demo.end-to-end
description: orchestration playbook
steps:
  - action: InvokeTestSequence
    sequence: install
    description: inner
"@ | Set-Content (Join-Path $seqDir 'demo.end-to-end.yml')
    @"
description: guest workload
keystrokeMechanism: gui
resource:
  ubuntu.server.24: []
workload: []
"@ | Set-Content (Join-Path $seqDir 'install.yml')
    $projTest = Join-Path $root 'project/test'
    $null = New-Item -ItemType Directory -Force -Path $projTest
    return @{ Root = $root; SequencesDir = $seqDir; RunnerYml = (Join-Path $projTest 'test.runner.yml') }
}

Describe 'Get-PoolHostHypervisor + Get-CompatibleHypervisorList' {
    It 'derives the hypervisor token from the host type' {
        Assert-Equal -Expected 'hyper-v' -Actual (Get-PoolHostHypervisor -HostType 'host.windows.hyper-v') -Because 'hyper-v'
        Assert-Equal -Expected 'kvm'     -Actual (Get-PoolHostHypervisor -HostType 'host.ubuntu.kvm') -Because 'kvm'
        Assert-Equal -Expected 'utm'     -Actual (Get-PoolHostHypervisor -HostType 'host.macos.utm') -Because 'utm'
    }
    It 'returns the rule list, or $null when no rule / no file' {
        Assert-Equal -Expected 'hyper-v' -Actual (Get-CompatibleHypervisorList -Compatibility $Compat -GuestKey 'guest.windows.11')[0] -Because 'win11 rule'
        Assert-Null (Get-CompatibleHypervisorList -Compatibility $Compat -GuestKey 'guest.unknown') 'no rule -> null'
        Assert-Null (Get-CompatibleHypervisorList -Compatibility $null -GuestKey 'guest.windows.11') 'no file -> null'
    }
}

Describe 'Test-GuestCompatibleWithHost (permit when no rule)' {
    It 'matches the host hypervisor against the rule' {
        Assert-True  (Test-GuestCompatibleWithHost -Compatibility $Compat -GuestKey 'guest.windows.11' -HostType 'host.windows.hyper-v') 'win11 on hyper-v'
        Assert-False (Test-GuestCompatibleWithHost -Compatibility $Compat -GuestKey 'guest.windows.11' -HostType 'host.ubuntu.kvm') 'win11 on kvm'
        Assert-True  (Test-GuestCompatibleWithHost -Compatibility $Compat -GuestKey 'guest.ubuntu.server.24' -HostType 'host.ubuntu.kvm') 'ubuntu on kvm'
    }
    It 'permits a guest with no rule (advisory) and when no compat file' {
        Assert-True (Test-GuestCompatibleWithHost -Compatibility $Compat -GuestKey 'guest.no.rule' -HostType 'host.ubuntu.kvm') 'no rule -> permit'
        Assert-True (Test-GuestCompatibleWithHost -Compatibility $null -GuestKey 'guest.windows.11' -HostType 'host.ubuntu.kvm') 'no file -> permit'
    }
}

Describe 'Select-RunnableGuestList (folder AND capability AND compat, stable order)' {
    It 'keeps only guests passing all three gates, in candidate order' {
        $folder = @{ 'guest.windows.11'=$true; 'guest.ubuntu.server.24'=$true; 'guest.amazon.linux.2023'=$false }
        $cap    = @{ 'guest.windows.11'=$true; 'guest.ubuntu.server.24'=$true; 'guest.amazon.linux.2023'=$true }
        $r = Select-RunnableGuestList -CandidateGuests $RunnableCandidates -FolderPresent $folder -CapabilitySupported $cap -Compatibility $Compat -HostType 'host.ubuntu.kvm'
        Assert-Equal -Expected 1 -Actual $r.Count -Because 'only ubuntu (win11 incompatible on kvm, amazon no folder)'
        Assert-Equal -Expected 'guest.ubuntu.server.24' -Actual $r[0] -Because 'ubuntu kept'
    }
    It 'drops a guest failing the capability gate' {
        $folder = @{ 'guest.ubuntu.server.24'=$true }
        $cap    = @{ 'guest.ubuntu.server.24'=$false }
        $r = Select-RunnableGuestList -CandidateGuests @('guest.ubuntu.server.24') -FolderPresent $folder -CapabilitySupported $cap -Compatibility $Compat -HostType 'host.ubuntu.kvm'
        Assert-Equal -Expected 0 -Actual $r.Count -Because 'capability false -> dropped'
    }
}

Describe 'Get-TestVMName -HostId (legacy byte-identical; HostId-scoped on pool)' {
    It 'is byte-identical to the legacy name when HostId is absent/empty' {
        $legacy = Get-TestVMName -GuestKey 'guest.ubuntu.server.24'
        Assert-Equal -Expected 'test-ubuntu-server-24-01' -Actual $legacy -Because 'legacy stem keeps the version'
        Assert-Equal -Expected $legacy -Actual (Get-TestVMName -GuestKey 'guest.ubuntu.server.24' -HostId '') -Because 'empty HostId == legacy'
    }
    It 'inserts an 8-char alphanumeric host segment when HostId is set' {
        $n = Get-TestVMName -GuestKey 'guest.ubuntu.server.24' -HostId '42abcdef0123456789abcdef01234567'
        Assert-Equal -Expected 'test-ubuntu-server-24-42abcdef-01' -Actual $n -Because 'HostId-scoped'
        Assert-True ($n -match '^[A-Za-z0-9.\-]+$') 'name is validator-safe (alnum/dot/hyphen)'
    }
}

Describe 'Get-CyclePlanSequencesForGuest keystrokeMechanism merge (pure)' {
    It 'returns the first non-null mechanism, or $null when none' {
        $plan = @(
            [pscustomobject]@{ guestKey='guest.a'; fullChain=@('s1'); effectiveVariables=[ordered]@{}; effectiveUsername=''; keystrokeMechanism=$null },
            [pscustomobject]@{ guestKey='guest.a'; fullChain=@('s2'); effectiveVariables=[ordered]@{}; effectiveUsername=''; keystrokeMechanism='SSH' }
        )
        Assert-Equal -Expected 'SSH' -Actual (Get-CyclePlanSequencesForGuest -Plan $plan -GuestKey 'guest.a').keystrokeMechanism -Because 'first non-null wins'
        $legacy = @([pscustomobject]@{ guestKey='guest.b'; fullChain=@('s1'); effectiveVariables=[ordered]@{}; effectiveUsername='' })
        Assert-Null (Get-CyclePlanSequencesForGuest -Plan $legacy -GuestKey 'guest.b').keystrokeMechanism 'absent field -> null'
    }
}

Describe 'Get-CyclePlanSequencesForGuest effectiveHostname merge (pure)' {
    It 'returns the first non-empty hostname, or empty when none' {
        $plan = @(
            [pscustomobject]@{ guestKey='guest.a'; fullChain=@('s1'); effectiveVariables=[ordered]@{}; effectiveUsername=''; effectiveHostname='' },
            [pscustomobject]@{ guestKey='guest.a'; fullChain=@('s2'); effectiveVariables=[ordered]@{}; effectiveUsername=''; effectiveHostname='pinned' }
        )
        Assert-Equal -Expected 'pinned' -Actual (Get-CyclePlanSequencesForGuest -Plan $plan -GuestKey 'guest.a').effectiveHostname -Because 'first non-empty wins'
        # A plan entry built before the field existed must not throw here: the
        # guest simply keeps the VM-name default.
        $legacy = @([pscustomobject]@{ guestKey='guest.b'; fullChain=@('s1'); effectiveVariables=[ordered]@{}; effectiveUsername='' })
        Assert-Equal -Expected '' -Actual (Get-CyclePlanSequencesForGuest -Plan $legacy -GuestKey 'guest.b').effectiveHostname -Because 'absent field -> empty'
    }
}

Describe 'Manifest readers + Write-YurunaPoolManifest' {
    It 'reads a valid pool manifest and returns $null on missing/bad' {
        $d = New-TempDir
        try {
            '{"poolId":"lab","poolGuid":"42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071","testSet":{"name":"amisad","frameworkUrl":"https://x/f","projectUrl":"https://x/p"}}' | Set-Content (Join-Path $d 'pool.manifest.json')
            $m = Read-YurunaPoolManifest -RuntimeDir $d
            Assert-Equal -Expected 'lab' -Actual $m['poolId'] -Because 'poolId read'
            Assert-Equal -Expected 'amisad' -Actual $m['testSet']['name'] -Because 'testSet name read'
            Assert-Null (Read-YurunaPoolManifest -RuntimeDir (Join-Path $d 'nope')) 'missing dir -> null'
            'not json {' | Set-Content (Join-Path $d 'pool.manifest.json')
            Assert-Null (Read-YurunaPoolManifest -RuntimeDir $d) 'bad json -> null'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'writes a manifest from a pool object and clears it when the pool has no testSet' {
        $d = New-TempDir
        try {
            $env:YURUNA_RUNTIME_DIR = $d
            $pool = [ordered]@{ poolId='lab'; poolGuid='42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'; testSet=[ordered]@{ name='amisad'; frameworkUrl='https://x/f'; projectUrl='https://x/p' }; config=[ordered]@{} }
            $null = Write-YurunaPoolManifest -Pool $pool -Confirm:$false
            $path = Join-Path $d 'pool.manifest.json'
            Assert-True (Test-Path $path) 'manifest written'
            $back = Read-YurunaPoolManifest -RuntimeDir $d
            Assert-Equal -Expected 'lab' -Actual $back['poolId'] -Because 'roundtrip poolId'
            Assert-Equal -Expected 'https://x/p' -Actual $back['testSet']['projectUrl'] -Because 'roundtrip testSet projectUrl'
            # A pool with no testSet -> stale manifest removed
            $null = Write-YurunaPoolManifest -Pool ([ordered]@{ poolId='lab'; poolGuid='42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071' }) -Confirm:$false
            Assert-False (Test-Path $path) 'no-testSet pool clears the manifest'
        } finally { $env:YURUNA_RUNTIME_DIR=$null; Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Resolve-CyclePlan parity (single-host behavior matches the test-set path)' {
    It 'produces one entry per baseline guest with the cascaded variables and null keystroke' {
        $fx = New-PlannerFixture
        try {
            $plan = (Resolve-CyclePlan -RepoRoot $fx.Root -SequencesDir $fx.SequencesDir -HostType 'host.ubuntu.kvm')
            Assert-Equal -Expected 2 -Actual $plan.Count -Because 'two guests from the baseline'
            $u = $plan | Where-Object { $_.guestKey -eq 'guest.ubuntu.server.24' } | Select-Object -First 1
            Assert-Equal -Expected 'baseuser' -Actual $u.effectiveVariables['username'] -Because 'cascaded username'
            Assert-Equal -Expected 'us' -Actual $u.effectiveVariables['region'] -Because 'cascaded region'
            Assert-Null $u.keystrokeMechanism 'no override -> null keystroke on the legacy path'
        } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Get-CycleOrchestrationList + Resolve-CyclePlan orchestration handling' {
    It 'lists an orchestration entry and emits no guest plan entries for it' {
        $fx = New-OrchestrationFixture
        try {
            "sequences:`n  - demo.end-to-end`n" | Set-Content $fx.RunnerYml
            $orch = @((Get-CycleOrchestrationList -RepoRoot $fx.Root -SequencesDir $fx.SequencesDir -HostType 'host.ubuntu.kvm'))
            Assert-Equal -Expected 1 -Actual $orch.Count -Because 'one orchestration entry'
            Assert-Equal -Expected 'demo.end-to-end' -Actual $orch[0].name -Because 'orchestration name'
            Assert-True (Test-Path $orch[0].path) 'orchestration path resolves'
            $plan = @((Resolve-CyclePlan -RepoRoot $fx.Root -SequencesDir $fx.SequencesDir -HostType 'host.ubuntu.kvm'))
            Assert-Equal -Expected 0 -Actual $plan.Count -Because 'orchestration contributes no per-guest plan entries'
        } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'returns no orchestration entries for a guest-only runner config' {
        $fx = New-OrchestrationFixture
        try {
            "sequences:`n  - install`n" | Set-Content $fx.RunnerYml
            $orch = @((Get-CycleOrchestrationList -RepoRoot $fx.Root -SequencesDir $fx.SequencesDir -HostType 'host.ubuntu.kvm'))
            Assert-Equal -Expected 0 -Actual $orch.Count -Because 'a guest sequence is not an orchestration'
            # Bare assignment is the collection form that preserves the true
            # count: wrapping this ,@()-array return in @(...) would fabricate
            # Count 1 for any real count (0, 1, or many), misclassifying a
            # guest-only config as an orchestration mix. Pin the contract.
            $orchBare = Get-CycleOrchestrationList -RepoRoot $fx.Root -SequencesDir $fx.SequencesDir -HostType 'host.ubuntu.kvm'
            Assert-Equal -Expected 0 -Actual $orchBare.Count -Because 'bare-assignment preserves the true (zero) orchestration count'
            $plan = @((Resolve-CyclePlan -RepoRoot $fx.Root -SequencesDir $fx.SequencesDir -HostType 'host.ubuntu.kvm'))
            Assert-Equal -Expected 1 -Actual $plan.Count -Because 'the guest sequence yields one plan entry'
        } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'reports both lists for a mixed config (the runner rejects the combination)' {
        $fx = New-OrchestrationFixture
        try {
            "sequences:`n  - demo.end-to-end`n  - install`n" | Set-Content $fx.RunnerYml
            $orch = @((Get-CycleOrchestrationList -RepoRoot $fx.Root -SequencesDir $fx.SequencesDir -HostType 'host.ubuntu.kvm'))
            $plan = @((Resolve-CyclePlan -RepoRoot $fx.Root -SequencesDir $fx.SequencesDir -HostType 'host.ubuntu.kvm'))
            Assert-Equal -Expected 1 -Actual $orch.Count -Because 'the orchestration entry is listed'
            Assert-Equal -Expected 1 -Actual $plan.Count -Because 'the guest entry still yields a plan entry'
        } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Resolve-TestSetCyclePlan (perGuestOverrides + RestrictGuests)' {
    It 'layers per-guest overrides on top of the cascade and tags keystrokeMechanism' {
        $fx = New-PlannerFixture
        try {
            $body = Get-Content -Raw (Join-Path $fx.Root 'project/test/test-sets/smoke.yml') | ConvertFrom-Yaml -Ordered
            $plan = (Resolve-TestSetCyclePlan -RepoRoot $fx.Root -SequencesDir $fx.SequencesDir -HostType 'host.ubuntu.kvm' `
                -Sequences ([string[]]@($body['sequences'])) -SetName 'smoke' -PerGuestOverrides $body['perGuestOverrides'])
            $u = $plan | Where-Object { $_.guestKey -eq 'guest.ubuntu.server.24' } | Select-Object -First 1
            Assert-Equal -Expected 'webuser' -Actual $u.effectiveVariables['username'] -Because 'username override wins'
            Assert-Equal -Expected 'eu' -Actual $u.effectiveVariables['region'] -Because 'variables override wins'
            Assert-Equal -Expected 'SSH' -Actual $u.keystrokeMechanism -Because 'keystroke override tagged (upper)'
            Assert-Equal -Expected 'webuser' -Actual $u.effectiveUsername -Because 'effectiveUsername reflects override'
            Assert-Equal -Expected 'basehost' -Actual $u.effectiveHostname -Because 'effectiveHostname promoted from the cascade'
            $w = $plan | Where-Object { $_.guestKey -eq 'guest.windows.11' } | Select-Object -First 1
            Assert-Equal -Expected 'baseuser' -Actual $w.effectiveVariables['username'] -Because 'unoverridden guest keeps cascade'
            Assert-Null $w.keystrokeMechanism 'unoverridden guest -> null keystroke'
        } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'RestrictGuests filters to the runnable subset' {
        $fx = New-PlannerFixture
        try {
            $plan = (Resolve-TestSetCyclePlan -RepoRoot $fx.Root -SequencesDir $fx.SequencesDir -HostType 'host.ubuntu.kvm' `
                -Sequences @('install') -SetName 'smoke' -RestrictGuests @('guest.ubuntu.server.24'))
            Assert-Equal -Expected 1 -Actual $plan.Count -Because 'only the restricted guest'
            Assert-Equal -Expected 'guest.ubuntu.server.24' -Actual $plan[0].guestKey -Because 'ubuntu only'
        } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Resolve-PoolCyclePlan (full filter: drops incompatible guest)' {
    It 'keeps only the runnable guest for the pool''s test-set on a kvm host' {
        $fx = New-PlannerFixture
        try {
            $manifest = [ordered]@{ poolId='lab'; testSets=@([ordered]@{ name='smoke'; order=0; cycleStrategy='all' }) }
            $plan = (Resolve-PoolCyclePlan -RepoRoot $fx.Root -SequencesDir $fx.SequencesDir -HostType 'host.ubuntu.kvm' -Manifest $manifest)
            Assert-Equal -Expected 1 -Actual $plan.Count -Because 'windows.11 filtered (incompatible on kvm); ubuntu kept'
            Assert-Equal -Expected 'guest.ubuntu.server.24' -Actual $plan[0].guestKey -Because 'ubuntu kept'
            Assert-Equal -Expected 'SSH' -Actual $plan[0].keystrokeMechanism -Because 'per-guest override flowed through'
        } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'returns $null when no test-set has a runnable guest (caller falls back to single-host)' {
        $fx = New-PlannerFixture
        try {
            $manifest = [ordered]@{ poolId='lab'; testSets=@([ordered]@{ name='does-not-exist'; order=0; cycleStrategy='all' }) }
            $plan = Resolve-PoolCyclePlan -RepoRoot $fx.Root -SequencesDir $fx.SequencesDir -HostType 'host.ubuntu.kvm' -Manifest $manifest
            Assert-Null $plan 'missing test-set -> null -> single-host fallback'
        } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
