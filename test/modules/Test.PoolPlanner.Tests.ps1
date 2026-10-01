<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42fa11cf-0b8e-4cd0-886d-508a27923c57
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
    Pester coverage for pooled execution: the pool planner's pure
    compat/selection logic, HostId-scoped VM naming, the per-guest keystroke
    merge, the pool manifest contract (writer, reader, target-pool guard), and
    Resolve-CyclePlan / Get-CycleOrchestrationList against a minimal sequence
    fixture.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.HostDetection.psm1')   -Force -DisableNameChecking -ErrorAction SilentlyContinue
try { Import-Module powershell-yaml -Force -ErrorAction Stop } catch { Write-Warning 'powershell-yaml unavailable.' }
Import-Module (Join-Path $here 'Test.SequenceResolve.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.SequenceEngine.psm1')      -Force -Global -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.Capability.psm1')      -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.StateFile.psm1')       -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.SequencePlanner.psm1') -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.PoolSync.psm1')        -Force -DisableNameChecking -ErrorAction SilentlyContinue
Import-Module (Join-Path $here 'Test.PoolPlanner.psm1')     -Force -DisableNameChecking -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

# Ordinal, so the expected key list does not depend on the test host's culture.
function Get-OrdinalKeyList {
    [CmdletBinding()] [OutputType([string])] param([Parameter(Mandatory)][System.Collections.IDictionary]$Map)
    $keys = [string[]]@($Map.Keys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    return ($keys -join ',')
}

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

$script:RunnableCandidates = @('guest.windows.11', 'guest.ubuntu.server.24', 'guest.amazon.linux.2023')

# --- REGION: Sequence-fixture integration: Resolve-CyclePlan + guests.compatibility.yml
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
    $null = New-Item -ItemType Directory -Force -Path $projTest
    "sequences:`n  - install`n" | Set-Content (Join-Path $projTest 'test.runner.yml')
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
        $r = Select-RunnableGuestList -CandidateGuests $script:RunnableCandidates -FolderPresent $folder -CapabilitySupported $cap -Compatibility $Compat -HostType 'host.ubuntu.kvm'
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

Describe 'Get-TestVMName -HostId (guest key verbatim; HostId-scoped on pool)' {
    It 'carries the guest key through verbatim when HostId is absent/empty' {
        $single = Get-TestVMName -GuestKey 'guest.ubuntu.server.24'
        Assert-Equal -Expected 'test-guest.ubuntu.server.24-01' -Actual $single -Because 'guest key verbatim + ordinal'
        Assert-Equal -Expected $single -Actual (Get-TestVMName -GuestKey 'guest.ubuntu.server.24' -HostId '') -Because 'empty HostId == single-host'
    }
    It 'inserts an 8-char alphanumeric host segment when HostId is set' {
        $n = Get-TestVMName -GuestKey 'guest.ubuntu.server.24' -HostId '42abcdef0123456789abcdef01234567'
        Assert-Equal -Expected 'test-guest.ubuntu.server.24-42abcdef-01' -Actual $n -Because 'HostId-scoped'
        Assert-True ($n -match '^[A-Za-z0-9.\-]+$') 'name is validator-safe (alnum/dot/hyphen)'
    }
    It 'rejects a prefix carrying a shell metacharacter' {
        $threw = $false
        try { $null = Get-TestVMName -GuestKey 'guest.ubuntu.server.24' -Prefix 'test ;rm -rf /' } catch { $threw = $true }
        Assert-True $threw 'a metacharacter prefix never reaches a command string'
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
            '{"poolId":"lab","poolGuid":"42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071","repositories":{"frameworkUrl":"https://x/f","projectUrl":"https://x/p"}}' | Set-Content (Join-Path $d 'pool.manifest.json')
            $m = Read-YurunaPoolManifest -RuntimeDir $d
            Assert-Equal -Expected 'lab' -Actual $m['poolId'] -Because 'poolId read'
            Assert-Equal -Expected 'https://x/p' -Actual $m['repositories']['projectUrl'] -Because 'repositories projectUrl read'
            Assert-Null (Read-YurunaPoolManifest -RuntimeDir (Join-Path $d 'nope')) 'missing dir -> null'
            'not json {' | Set-Content (Join-Path $d 'pool.manifest.json')
            Assert-Null (Read-YurunaPoolManifest -RuntimeDir $d) 'bad json -> null'
        } finally { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'writes a manifest from a pool object and clears it when the pool has no repositories' {
        $d = New-TempDir
        try {
            $env:YURUNA_RUNTIME_DIR = $d
            $pool = [ordered]@{ poolId='lab'; poolGuid='42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'; repositories=[ordered]@{ frameworkUrl='https://x/f'; projectUrl='https://x/p' }; config=[ordered]@{} }
            $null = Write-YurunaPoolManifest -Pool $pool -Confirm:$false
            $path = Join-Path $d 'pool.manifest.json'
            Assert-True (Test-Path $path) 'manifest written'
            $back = Read-YurunaPoolManifest -RuntimeDir $d
            Assert-Equal -Expected 'lab' -Actual $back['poolId'] -Because 'roundtrip poolId'
            Assert-Equal -Expected 'https://x/f' -Actual $back['repositories']['frameworkUrl'] -Because 'roundtrip frameworkUrl'
            Assert-Equal -Expected 'https://x/p' -Actual $back['repositories']['projectUrl'] -Because 'roundtrip projectUrl'
            # A pool with no repositories -> stale manifest removed
            $null = Write-YurunaPoolManifest -Pool ([ordered]@{ poolId='lab'; poolGuid='42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071' }) -Confirm:$false
            Assert-False (Test-Path $path) 'a pool without repositories clears the manifest'
        } finally { $env:YURUNA_RUNTIME_DIR=$null; Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Resolve-CyclePlan (one entry per baseline guest, cascaded variables)' {
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

Describe 'Write-YurunaPoolManifest repositories contract' {
    It 'writes exactly poolId, poolGuid, repositories, config and writtenAtUtc, with trimmed URLs' {
        $d = New-TempDir
        try {
            $env:YURUNA_RUNTIME_DIR = $d
            $pool = [ordered]@{ poolId='lab'; poolGuid='42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'; repositories=[ordered]@{ frameworkUrl=' https://x/f '; projectUrl='https://x/p' } }
            Assert-True (Write-YurunaPoolManifest -Pool $pool -Confirm:$false) 'the writer reports a written manifest'
            $back = Read-YurunaPoolManifest -RuntimeDir $d
            Assert-Equal -Expected 'config,poolGuid,poolId,repositories,writtenAtUtc' -Actual (Get-OrdinalKeyList -Map $back) -Because 'the manifest keys are a contract with the inner runner'
            Assert-Equal -Expected 'frameworkUrl,projectUrl' -Actual (Get-OrdinalKeyList -Map $back['repositories']) -Because 'repositories carries exactly the URL pair'
            Assert-Equal -Expected 'https://x/f' -Actual $back['repositories']['frameworkUrl'] -Because 'surrounding whitespace is trimmed'
        } finally { $env:YURUNA_RUNTIME_DIR=$null; Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'writes no manifest when either URL is missing or blank' {
        $d = New-TempDir
        try {
            $env:YURUNA_RUNTIME_DIR = $d
            $path = Join-Path $d 'pool.manifest.json'
            $incomplete = @(
                [ordered]@{ frameworkUrl = 'https://x/f' },
                [ordered]@{ frameworkUrl = 'https://x/f'; projectUrl = '' },
                [ordered]@{ frameworkUrl = '   '; projectUrl = 'https://x/p' },
                'https://x/p'
            )
            foreach ($repositories in $incomplete) {
                '{"poolId":"lab"}' | Set-Content $path
                $pool = [ordered]@{ poolId='lab'; poolGuid='42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'; repositories=$repositories }
                Assert-False (Write-YurunaPoolManifest -Pool $pool -Confirm:$false) 'no manifest for an incomplete pair'
                Assert-False (Test-Path $path) 'an incomplete pair clears a stale manifest'
            }
        } finally { $env:YURUNA_RUNTIME_DIR=$null; Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'ignores repositories on the auto-enrollment target pool, warns, and removes a stale manifest' {
        $d = New-TempDir
        try {
            $env:YURUNA_RUNTIME_DIR = $d
            $path = Join-Path $d 'pool.manifest.json'
            '{"poolId":"default"}' | Set-Content $path
            $pool = [ordered]@{ poolId='default'; poolGuid='42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'; repositories=[ordered]@{ frameworkUrl='https://x/f'; projectUrl='https://x/p' } }
            $warnings = $null
            $written = Write-YurunaPoolManifest -Pool $pool -AutoEnrollTargetPoolId 'default' -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue
            Assert-False $written 'no manifest is written for the target pool'
            Assert-False (Test-Path $path) 'a stale manifest is removed, so the host keeps its own repositories'
            Assert-Equal -Expected 1 -Actual @($warnings).Count -Because 'the ignored repositories are reported once'
            Assert-True ("$($warnings[0])".Contains('default')) 'the warning names the pool'
            Assert-True (Write-YurunaPoolManifest -Pool $pool -AutoEnrollTargetPoolId 'other' -Confirm:$false) 'the same pool is honored when it is not the target'
        } finally { $env:YURUNA_RUNTIME_DIR=$null; Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'is read under the same key by the inner runner' {
        # A key mismatch between this writer and its only reader does not fail
        # anything: every pooled host silently runs its own project instead.
        $src = [IO.File]::ReadAllText((Join-Path $here 'Test.RunnerInnerLoop.psm1'))
        Assert-True ($src.Contains("`$poolManifestForRepos['repositories']")) 'the pooled repos override reads a different manifest key'
        Assert-True ($src.Contains("`$poolManifest['repositories']")) 'the pooled-cycle flag reads a different manifest key'
    }
}

Describe 'Read-YurunaGuestCompatibility + Select-RunnableGuestList against a project fixture' {
    It 'reads the project rules and returns $null when the file is absent' {
        $fx = New-PlannerFixture
        try {
            $compat = Read-YurunaGuestCompatibility -RepoRoot $fx.Root
            Assert-Equal -Expected 'hyper-v' -Actual (Get-CompatibleHypervisorList -Compatibility $compat -GuestKey 'guest.windows.11')[0] -Because 'the project rule is read'
            Assert-False (Test-GuestCompatibleWithHost -Compatibility $compat -GuestKey 'guest.windows.11' -HostType 'host.ubuntu.kvm') 'win11 is not runnable on kvm per the file'
            Remove-Item -LiteralPath (Join-Path $fx.Root 'project/test/guests.compatibility.yml') -Force
            Assert-Null (Read-YurunaGuestCompatibility -RepoRoot $fx.Root) 'no file -> null (permissive)'
        } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
    It 'keeps only the guests this host can run from a resolved plan' {
        $fx = New-PlannerFixture
        try {
            $plan = Resolve-CyclePlan -RepoRoot $fx.Root -SequencesDir $fx.SequencesDir -HostType 'host.ubuntu.kvm'
            $candidates = Get-CyclePlanGuestList -Plan $plan
            $folder = @{}; $cap = @{}
            foreach ($g in $candidates) {
                $folder[$g] = [bool](Test-GuestFolder -RepoRoot $fx.Root -HostType 'host.ubuntu.kvm' -GuestKey $g)
                $cap[$g] = $true
            }
            $runnable = Select-RunnableGuestList -CandidateGuests $candidates -FolderPresent $folder -CapabilitySupported $cap `
                -Compatibility (Read-YurunaGuestCompatibility -RepoRoot $fx.Root) -HostType 'host.ubuntu.kvm'
            Assert-Equal -Expected 1 -Actual $runnable.Count -Because 'windows.11 is incompatible on kvm; ubuntu has its folder'
            Assert-Equal -Expected 'guest.ubuntu.server.24' -Actual $runnable[0] -Because 'ubuntu kept'
        } finally { Remove-Item -LiteralPath $fx.Root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
