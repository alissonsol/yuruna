<#PSScriptInfo
.VERSION 2026.10.31
.GUID 428a18ad-e004-4555-8e23-53931d6f3ead
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test pool framework canary ring
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

<#
.SYNOPSIS
    The framework canary ring on the host: the pools.yml block, the role a host
    plays, the aggregator lookup, the revision a follower installs, the outer
    update and failure-pause poll, and the admin commands that keep canaries in
    step with members.
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module powershell-yaml -Force
    # Test.FrameworkRing first: the outer loop module then binds to this same
    # instance, so a mock placed in it is the one the outer update reaches.
    Import-Module (Join-Path $here 'Test.FrameworkRing.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.PoolSync.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.PoolAdmin.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.HostGit.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.RunnerOuterLoop.psm1') -Force -DisableNameChecking

    $script:Canary = '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $script:Follower = '42cccccccccccccccccccccccccccccc'
    $script:Other = '42dddddddddddddddddddddddddddddd'

    function Set-RingPoolState {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Writes only a TestDrive fixture.')]
        [CmdletBinding()]
        param([string]$RuntimeDir, [AllowNull()]$Ring, [string]$PoolId = 'lab')
        $null = New-Item -ItemType Directory -Force -Path $RuntimeDir
        $state = [ordered]@{ poolId = $PoolId; poolGuid = '42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'; configuredState = 'run'; configurationOk = $true; gating = $null }
        if ($null -ne $Ring) { $state.frameworkRing = $Ring }
        Set-Content -LiteralPath (Join-Path $RuntimeDir 'pool.state.json') -Value ($state | ConvertTo-Json -Depth 5)
    }

    function Invoke-RingGit {
        param([string]$Directory, [string[]]$Arguments)
        return "$(Invoke-YurunaTestGit -Path $Directory -Argument $Arguments | Select-Object -Last 1)".Trim()
    }

    # An upstream with commits A <- B <- C on main and D on a side branch, and a
    # clone of it checked out at -At, tracking origin/main.
    function New-RingRepository {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates only TestDrive repositories.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([ValidateSet('A', 'B', 'C')][string]$At = 'A')
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $work = New-YurunaTestGitRepository -Path (Join-Path $root 'work')
        $commits = @{}
        foreach ($name in 'A', 'B', 'C') {
            Set-Content -LiteralPath (Join-Path $work 'file.txt') -Value $name
            $null = Invoke-RingGit -Directory $work -Arguments @('add', 'file.txt')
            $null = Invoke-RingGit -Directory $work -Arguments @('commit', '--quiet', '-m', $name)
            $commits[$name] = Invoke-RingGit -Directory $work -Arguments @('rev-parse', 'HEAD')
        }
        $null = Invoke-RingGit -Directory $work -Arguments @('checkout', '--quiet', '-b', 'side', $commits.A)
        Set-Content -LiteralPath (Join-Path $work 'side.txt') -Value 'D'
        $null = Invoke-RingGit -Directory $work -Arguments @('add', 'side.txt')
        $null = Invoke-RingGit -Directory $work -Arguments @('commit', '--quiet', '-m', 'D')
        $commits.D = Invoke-RingGit -Directory $work -Arguments @('rev-parse', 'HEAD')
        $null = Invoke-RingGit -Directory $work -Arguments @('checkout', '--quiet', 'main')
        $bare = Join-Path $root 'upstream.git'
        $null = Invoke-RingGit -Directory $root -Arguments @('clone', '--quiet', '--bare', $work, $bare)
        $clone = Join-Path $root 'clone'
        $null = Invoke-RingGit -Directory $root -Arguments @('clone', '--quiet', $bare, $clone)
        $null = Invoke-RingGit -Directory $clone -Arguments @('reset', '--quiet', '--hard', $commits[$At])
        return @{ Clone = $clone; Commits = $commits }
    }
}

Describe 'the role a host plays in its pool''s framework ring' {
    It 'is none without a pool state, for an unpooled host, and for a pool without a ring' {
        Assert-Equal 'none' (Get-YurunaFrameworkRingRole -PoolState $null -HostId $script:Canary)
        Assert-Equal 'none' (Get-YurunaFrameworkRingRole -PoolState @{ poolId = $null; frameworkRing = @{ canaryMembers = @(); requiredPasses = 1 } } -HostId $script:Canary)
        Assert-Equal 'none' (Get-YurunaFrameworkRingRole -PoolState @{ poolId = 'lab' } -HostId $script:Canary)
    }

    It 'is canary for a listed member whatever the case, and follower for every other member' {
        $state = @{ poolId = 'lab'; frameworkRing = @{ canaryMembers = @($script:Canary.ToUpperInvariant()); requiredPasses = 2 } }
        Assert-Equal 'canary' (Get-YurunaFrameworkRingRole -PoolState $state -HostId $script:Canary)
        Assert-Equal 'follower' (Get-YurunaFrameworkRingRole -PoolState $state -HostId $script:Follower)
        $frozen = @{ poolId = 'lab'; frameworkRing = @{ canaryMembers = @(); requiredPasses = 1 } }
        Assert-Equal 'follower' (Get-YurunaFrameworkRingRole -PoolState $frozen -HostId $script:Canary) 'an empty canary list makes every member a follower'
    }
}

Describe 'the pools.yml frameworkRing block' {
    It 'is normalized for pool.state.json, and a malformed block is ignored' {
        $record = ConvertTo-PoolFrameworkRingRecord -Ring ([ordered]@{ canaryMembers = @($script:Canary.ToUpperInvariant(), $script:Canary, 'not-a-host'); requiredPasses = 3 })
        Assert-Equal 1 @($record.canaryMembers).Count
        Assert-Equal $script:Canary $record.canaryMembers[0]
        Assert-Equal 3 $record.requiredPasses
        Assert-Null (ConvertTo-PoolFrameworkRingRecord -Ring @{ canaryMembers = @($script:Canary) }) 'no pass count'
        Assert-Null (ConvertTo-PoolFrameworkRingRecord -Ring @{ requiredPasses = 1 }) 'no canary list'
        Assert-Null (ConvertTo-PoolFrameworkRingRecord -Ring @{ canaryMembers = @(); requiredPasses = 0 }) 'zero passes'
        Assert-Null (ConvertTo-PoolFrameworkRingRecord -Ring 'text') 'not a block'
    }

    It 'reaches pool.state.json only for a pool that authored one' {
        $runtime = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $runtime
        $savedEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $env:YURUNA_RUNTIME_DIR = $runtime
        try {
            $null = Write-YurunaPoolState -PoolId 'lab' -PoolGuid 'g' -ConfiguredState 'run' -ConfigurationOk $true -Gating $null -Confirm:$false
            $plain = Get-Content -Raw (Join-Path $runtime 'pool.state.json') | ConvertFrom-Json -AsHashtable
            Assert-False ($plain.ContainsKey('frameworkRing')) 'a pool without a ring keeps the state file shape'
            $null = Write-YurunaPoolState -PoolId 'lab' -PoolGuid 'g' -ConfiguredState 'run' -ConfigurationOk $true -Gating $null `
                -FrameworkRing ([ordered]@{ canaryMembers = @($script:Canary); requiredPasses = 2 }) -Confirm:$false
            $ringed = Get-Content -Raw (Join-Path $runtime 'pool.state.json') | ConvertFrom-Json -AsHashtable
            Assert-Equal 2 $ringed.frameworkRing.requiredPasses
            Assert-Equal $script:Canary @($ringed.frameworkRing.canaryMembers)[0]
        } finally { Restore-YurunaTestEnvironment -Saved $savedEnvironment }
    }

    It 'is accepted by the schema when well formed and refused otherwise' {
        $doc = [ordered]@{ schemaVersion = 4; pools = @([ordered]@{ poolId = 'lab'; poolGuid = '42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'; members = @($script:Canary)
                    frameworkRing = [ordered]@{ canaryMembers = @($script:Canary); requiredPasses = 2 } }) }
        Assert-True (Test-YurunaPoolDocValid -Doc $doc -SchemaName 'pools.schema.yml').Ok 'a well-formed ring'
        $doc.pools[0].frameworkRing = [ordered]@{ canaryMembers = @(); requiredPasses = 1 }
        Assert-True (Test-YurunaPoolDocValid -Doc $doc -SchemaName 'pools.schema.yml').Ok 'an empty canary list freezes the followers'
        foreach ($bad in @(
                [ordered]@{ canaryMembers = @($script:Canary); requiredPasses = 0 },
                [ordered]@{ requiredPasses = 1 },
                [ordered]@{ canaryMembers = @('not-a-host'); requiredPasses = 1 },
                [ordered]@{ canaryMembers = @($script:Canary); requiredPasses = 1; extra = 1 })) {
            $doc.pools[0].frameworkRing = $bad
            Assert-False (Test-YurunaPoolDocValid -Doc $doc -SchemaName 'pools.schema.yml').Ok "refused: $($bad | ConvertTo-Json -Compress)"
        }
    }
}

Describe 'the aggregator lookup' {
    It 'asks with this host''s canary list and pass count and returns the qualifying revision' {
        # The aggregator answers a fixed qualifying revision.
        $stub = Start-YurunaTestHttpResponder -Reply (New-YurunaTestHttpReply -ContentType 'application/json' `
                -Body ('{"qualifyingRevision":"' + ('b' * 40) + '","qualifyingPasses":2,"revisions":[]}'))
        try {
            $answer = Get-YurunaFrameworkRingQualification -BaseUrl $stub.BaseUrl -CanaryMembers @($script:Canary.ToUpperInvariant(), $script:Other) -RequiredPasses 2 -TimeoutSeconds 5
        } finally { $requests = @(Stop-YurunaTestHttpResponder $stub) }
        Assert-True $answer.Ok $answer.Detail
        Assert-Equal ('b' * 40) $answer.Revision
        Assert-Equal 2 $answer.Passes
        Assert-Match ([regex]::Escape("GET /api/v1/framework-ring?canary=$($script:Canary)%2C$($script:Other)&passes=2 ")) ($requests -join "`n")
    }

    It 'treats an answer naming no full commit, an HTTP error and a closed port as no answer' {
        Mock -ModuleName Test.FrameworkRing Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = '{"qualifyingRevision":"abc1234","qualifyingPasses":5}' } }
        Assert-False (Get-YurunaFrameworkRingQualification -BaseUrl 'http://192.0.2.1:9400' -RequiredPasses 1).Ok 'an abbreviated revision'
        Mock -ModuleName Test.FrameworkRing Invoke-WebRequest { [pscustomobject]@{ StatusCode = 503; Content = '' } }
        Assert-False (Get-YurunaFrameworkRingQualification -BaseUrl 'http://192.0.2.1:9400' -RequiredPasses 1).Ok 'HTTP 503'
        Mock -ModuleName Test.FrameworkRing Invoke-WebRequest { throw 'connection refused' }
        $answer = Get-YurunaFrameworkRingQualification -BaseUrl 'http://192.0.2.1:9400' -RequiredPasses 1
        Assert-False $answer.Ok 'a closed port'
        Assert-Match 'connection refused' $answer.Detail
    }

    It 'reads an empty qualifying revision as an answer with nothing qualified' {
        Mock -ModuleName Test.FrameworkRing Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = '{"qualifyingRevision":"","qualifyingPasses":0}' } }
        $answer = Get-YurunaFrameworkRingQualification -BaseUrl 'http://192.0.2.1:9400' -RequiredPasses 3
        Assert-True $answer.Ok
        Assert-Equal '' $answer.Revision
    }
}

Describe 'the ring decision' {
    BeforeEach {
        $script:Runtime = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    }

    It 'never asks the aggregator for a host of a pool without a ring, or for a canary' {
        Mock -ModuleName Test.FrameworkRing Get-YurunaFrameworkRingQualification { throw 'must not be called' }
        Set-RingPoolState -RuntimeDir $script:Runtime -Ring $null
        Assert-Equal 'none' (Resolve-YurunaFrameworkRingTarget -RuntimeDir $script:Runtime -HostId $script:Follower).Role
        Set-RingPoolState -RuntimeDir $script:Runtime -Ring @{ canaryMembers = @($script:Canary); requiredPasses = 1 }
        Assert-Equal 'canary' (Resolve-YurunaFrameworkRingTarget -RuntimeDir $script:Runtime -HostId $script:Canary).Role
        Should -Invoke -ModuleName Test.FrameworkRing Get-YurunaFrameworkRingQualification -Times 0 -Exactly
    }

    It 'holds a follower whose lookup fails, and one with nothing qualified' {
        Set-RingPoolState -RuntimeDir $script:Runtime -Ring @{ canaryMembers = @($script:Canary); requiredPasses = 2 }
        Mock -ModuleName Test.FrameworkRing Get-YurunaFrameworkRingQualification { throw 'no route to host' }
        $decision = Resolve-YurunaFrameworkRingTarget -RuntimeDir $script:Runtime -HostId $script:Follower
        Assert-Equal 'follower' $decision.Role
        Assert-Equal '' $decision.Revision
        Assert-Equal 'aggregator-unreachable' $decision.Reason
        Assert-Match 'no route to host' $decision.Detail
        Mock -ModuleName Test.FrameworkRing Get-YurunaFrameworkRingQualification { @{ Ok = $true; Revision = ''; Passes = 0; Detail = '' } }
        $decision = Resolve-YurunaFrameworkRingTarget -RuntimeDir $script:Runtime -HostId $script:Follower
        Assert-Equal 'no-qualifying-revision' $decision.Reason
        Assert-Equal 2 $decision.RequiredPasses
    }

    It 'gives a follower the qualifying revision for its own canary list' {
        Set-RingPoolState -RuntimeDir $script:Runtime -Ring @{ canaryMembers = @($script:Canary, $script:Other); requiredPasses = 2 }
        Mock -ModuleName Test.FrameworkRing Get-YurunaFrameworkRingQualification { @{ Ok = $true; Revision = ('e' * 40); Passes = 4; Detail = '' } }
        $decision = Resolve-YurunaFrameworkRingTarget -RuntimeDir $script:Runtime -HostId $script:Follower
        Assert-Equal ('e' * 40) $decision.Revision
        Assert-Equal 4 $decision.Passes
        Should -Invoke -ModuleName Test.FrameworkRing Get-YurunaFrameworkRingQualification -Times 1 -Exactly -ParameterFilter {
            $RequiredPasses -eq 2 -and (@($CanaryMembers) -join ',') -eq "$($script:Canary),$($script:Other)"
        }
    }
}

Describe 'the revision a follower installs' {
    It 'moves forward to a qualifying revision in the fetched history' {
        $repo = New-RingRepository -At A
        $choice = Resolve-GitRingRevision -RepoRoot $repo.Clone -TipRevision $repo.Commits.C -CurrentRevision $repo.Commits.A -RingRevision $repo.Commits.B
        Assert-Equal 'installed' $choice.Outcome
        Assert-Equal $repo.Commits.B $choice.Revision
    }

    It 'never moves back, and leaves a revision outside the fetched history alone' {
        $repo = New-RingRepository -At C
        $back = Resolve-GitRingRevision -RepoRoot $repo.Clone -TipRevision $repo.Commits.C -CurrentRevision $repo.Commits.C -RingRevision $repo.Commits.B
        Assert-Equal 'held-newer' $back.Outcome
        Assert-Equal $repo.Commits.C $back.Revision
        $null = Invoke-RingGit -Directory $repo.Clone -Arguments @('fetch', '--quiet', 'origin', 'side')
        $side = Resolve-GitRingRevision -RepoRoot $repo.Clone -TipRevision $repo.Commits.C -CurrentRevision $repo.Commits.A -RingRevision $repo.Commits.D
        Assert-Equal 'held-not-in-history' $side.Outcome
        Assert-Equal $repo.Commits.A $side.Revision
        $same = Resolve-GitRingRevision -RepoRoot $repo.Clone -TipRevision $repo.Commits.C -CurrentRevision $repo.Commits.B -RingRevision $repo.Commits.B
        Assert-Equal 'current' $same.Outcome
        $short = Resolve-GitRingRevision -RepoRoot $repo.Clone -TipRevision $repo.Commits.C -CurrentRevision $repo.Commits.A -RingRevision $repo.Commits.B.Substring(0, 12)
        Assert-Equal 'held-not-in-history' $short.Outcome
    }

    It 'is installed by the framework update instead of the tip, without retaining the tip''s provenance' {
        $repo = New-RingRepository -At A
        $result = Invoke-GitRepositoryUpdate -RepoRoot $repo.Clone -RingRevision $repo.Commits.B -Confirm:$false
        Assert-True $result.Success $result.ErrorMessage
        Assert-Equal 'installed' $result.RingOutcome
        Assert-Equal $repo.Commits.B (Invoke-RingGit -Directory $repo.Clone -Arguments @('rev-parse', 'HEAD'))
        Assert-Null $result.SourceSelection
        $again = Invoke-GitRepositoryUpdate -RepoRoot $repo.Clone -RingRevision $repo.Commits.A -Confirm:$false
        Assert-Equal 'held-newer' $again.RingOutcome
        Assert-False $again.Changed
        Assert-Equal $repo.Commits.B (Invoke-RingGit -Directory $repo.Clone -Arguments @('rev-parse', 'HEAD'))
    }

    It 'installs the tip as before when no ring revision is given' {
        $repo = New-RingRepository -At A
        $result = Invoke-GitRepositoryUpdate -RepoRoot $repo.Clone -Confirm:$false
        Assert-True $result.Success $result.ErrorMessage
        Assert-Equal '' $result.RingOutcome
        Assert-Equal $repo.Commits.C (Invoke-RingGit -Directory $repo.Clone -Arguments @('rev-parse', 'HEAD'))
    }
}

Describe 'the outer framework update with a ring' {
    BeforeEach {
        $script:Runtime = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path $script:Runtime
        $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $env:YURUNA_RUNTIME_DIR = $script:Runtime
        $script:SavedGlobals = Save-YurunaTestGlobal -Name '__YurunaHostId'
        Set-YurunaTestGlobal -Value @{ __YurunaHostId = $script:Follower }
        Mock -ModuleName Test.RunnerOuterLoop Get-GitSourceConfiguration { @{ context = @{ mode = 'off' } } }
        Mock -ModuleName Test.RunnerOuterLoop Read-InstalledGitSource { @{} }
        Mock -ModuleName Test.RunnerOuterLoop Get-OuterCommitSha { 'a' * 40 }
        Mock -ModuleName Test.RunnerOuterLoop Invoke-GitRepositoryUpdate { @{ Success = $true; SourceSelection = $null; PreviousRevision = ('a' * 40); RingOutcome = $(if ($RingRevision) { 'installed' } else { '' }) } }
        Mock -ModuleName Test.FrameworkRing Get-YurunaFrameworkRingQualification { throw 'must not be called' }
    }
    AfterEach {
        Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
        Restore-YurunaTestGlobal -Saved $script:SavedGlobals
    }

    It 'calls the update exactly as before for a pool without a ring and for a canary' {
        foreach ($ring in @($null, @{ canaryMembers = @($script:Follower); requiredPasses = 1 })) {
            Set-RingPoolState -RuntimeDir $script:Runtime -Ring $ring
            Assert-True (Invoke-OuterGitPull -RepoRoot $TestDrive -ConfigPath (Join-Path $TestDrive 'test.config.yml'))
        }
        Should -Invoke -ModuleName Test.RunnerOuterLoop Invoke-GitRepositoryUpdate -Times 2 -Exactly -ParameterFilter {
            (@($PesterBoundParameters.Keys | Sort-Object) -join ',') -eq 'Confirm,DeadlineUtc,InstalledProvenance,RepoRoot,SourceContext'
        }
        Should -Invoke -ModuleName Test.FrameworkRing Get-YurunaFrameworkRingQualification -Times 0 -Exactly
        Assert-False (Test-Path (Join-Path $script:Runtime 'framework-ring.json')) 'no ring decision is recorded without a follower role'
    }

    It 'installs the qualifying revision on a follower' {
        Set-RingPoolState -RuntimeDir $script:Runtime -Ring @{ canaryMembers = @($script:Canary); requiredPasses = 1 }
        Mock -ModuleName Test.FrameworkRing Get-YurunaFrameworkRingQualification { @{ Ok = $true; Revision = ('b' * 40); Passes = 1; Detail = '' } }
        Assert-True (Invoke-OuterGitPull -RepoRoot $TestDrive -ConfigPath (Join-Path $TestDrive 'test.config.yml')) -InformationAction SilentlyContinue
        Should -Invoke -ModuleName Test.RunnerOuterLoop Invoke-GitRepositoryUpdate -Times 1 -Exactly -ParameterFilter { $RingRevision -eq ('b' * 40) }
        $record = Read-YurunaFrameworkRingDecision -RuntimeDir $script:Runtime
        Assert-Equal 'installed' $record.outcome
        Assert-Equal ('b' * 40) $record.revision
    }

    It 'keeps a follower where it is, and says why, when the aggregator does not answer or nothing qualifies' {
        Set-RingPoolState -RuntimeDir $script:Runtime -Ring @{ canaryMembers = @($script:Canary); requiredPasses = 2 }
        Mock -ModuleName Test.FrameworkRing Get-YurunaFrameworkRingQualification { @{ Ok = $false; Revision = ''; Passes = 0; Detail = 'no caching-proxy-service address known' } }
        Mock -ModuleName Test.RunnerOuterLoop Format-YurunaOperatorMessage { $Key }
        $warnings = $null
        Assert-True (Invoke-OuterGitPull -RepoRoot $TestDrive -ConfigPath (Join-Path $TestDrive 'test.config.yml') -WarningVariable warnings -WarningAction SilentlyContinue)
        Assert-Equal 'runner.framework_ring_hold_unreachable' ([string]@($warnings)[0])
        Assert-Equal 'held-aggregator-unreachable' (Read-YurunaFrameworkRingDecision -RuntimeDir $script:Runtime).outcome
        Mock -ModuleName Test.FrameworkRing Get-YurunaFrameworkRingQualification { @{ Ok = $true; Revision = ''; Passes = 0; Detail = '' } }
        Assert-True (Invoke-OuterGitPull -RepoRoot $TestDrive -ConfigPath (Join-Path $TestDrive 'test.config.yml') -InformationAction SilentlyContinue)
        Assert-Equal 'held-no-qualifying-revision' (Read-YurunaFrameworkRingDecision -RuntimeDir $script:Runtime).outcome
        Should -Invoke -ModuleName Test.RunnerOuterLoop Invoke-GitRepositoryUpdate -Times 0 -Exactly
        Assert-Null (Get-OuterSourceSelection) 'a hold retains no upstream selection'
    }
}

Describe 'the failure-pause poll on a follower' {
    BeforeEach {
        $script:Runtime = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Force -Path $script:Runtime
        $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $env:YURUNA_RUNTIME_DIR = $script:Runtime
        $script:Repo = New-RingRepository -At B
        Mock -ModuleName Test.RunnerOuterLoop Get-GitRepositoryUpdateTarget { throw 'a follower must not compare the tip' }
    }
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment }

    It 'wakes only for a qualifying revision the checkout does not contain and has not held' {
        $commits = $script:Repo.Commits
        foreach ($case in @(
                @{ Revision = ''; Want = $false; Why = 'nothing qualified' },
                @{ Revision = $commits.B; Want = $false; Why = 'already installed' },
                @{ Revision = $commits.A; Want = $false; Why = 'an ancestor of the installed revision' },
                @{ Revision = $commits.C; Want = $true; Why = 'a newer revision' })) {
            $decision = @{ Role = 'follower'; Revision = $case.Revision; Passes = 1; RequiredPasses = 1; Reason = ''; Detail = '' }
            Mock -ModuleName Test.RunnerOuterLoop Resolve-YurunaFrameworkRingTarget { $decision }.GetNewClosure()
            Assert-Equal $case.Want (Test-OuterNewCommitsAvailable -RepoRoot $script:Repo.Clone -BaselineSha ('f' * 40) -ConfigPath (Join-Path $TestDrive 'test.config.yml')) $case.Why
        }
        $null = Write-YurunaFrameworkRingDecision -Role follower -Revision $commits.C -Outcome 'held-not-in-history' -RuntimeDir $script:Runtime -Confirm:$false
        Assert-False (Test-OuterNewCommitsAvailable -RepoRoot $script:Repo.Clone -BaselineSha ('f' * 40) -ConfigPath (Join-Path $TestDrive 'test.config.yml')) 'a revision already held'
    }

    It 'keeps comparing the tip for a host with no ring' {
        Mock -ModuleName Test.RunnerOuterLoop Resolve-YurunaFrameworkRingTarget { @{ Role = 'none' } }
        Mock -ModuleName Test.RunnerOuterLoop Get-GitSourceConfiguration { @{ context = @{ mode = 'off' } } }
        Mock -ModuleName Test.RunnerOuterLoop Get-GitRepositoryUpdateTarget { @{ Success = $true; Skipped = $false; Revision = ('9' * 40) } }
        Assert-True (Test-OuterNewCommitsAvailable -RepoRoot $script:Repo.Clone -BaselineSha ('f' * 40) -ConfigPath (Join-Path $TestDrive 'test.config.yml'))
        Should -Invoke -ModuleName Test.RunnerOuterLoop Get-GitRepositoryUpdateTarget -Times 1 -Exactly
    }
}

Describe 'canary membership kept in step with members' {
    It 'removes a canary, replaces a re-keyed one, and leaves an empty list rather than deleting the block' {
        $pool = [ordered]@{ poolId = 'lab'; members = @($script:Canary, $script:Follower); frameworkRing = [ordered]@{ canaryMembers = @($script:Canary, $script:Other); requiredPasses = 2 } }
        Assert-True (Update-YurunaPoolRingCanary -Pool $pool -HostId $script:Other)
        Assert-Equal $script:Canary (@($pool.frameworkRing.canaryMembers) -join ',')
        Assert-True (Update-YurunaPoolRingCanary -Pool $pool -HostId $script:Canary -NewHostId $script:Follower)
        Assert-Equal $script:Follower (@($pool.frameworkRing.canaryMembers) -join ',')
        Assert-True (Update-YurunaPoolRingCanary -Pool $pool -HostId $script:Follower)
        Assert-Equal 0 @($pool.frameworkRing.canaryMembers).Count
        Assert-Equal 2 $pool.frameworkRing.requiredPasses
        Assert-False (Update-YurunaPoolRingCanary -Pool $pool -HostId $script:Canary) 'nothing to change'
        Assert-False (Update-YurunaPoolRingCanary -Pool ([ordered]@{ poolId = 'plain' }) -HostId $script:Canary) 'a pool without a ring'
    }

    It 'are applied by <Command>' -ForEach @(
        @{ Command = 'Remove-HostFromPool.ps1'; Arguments = @('-PoolId', 'lab', '-HostId', '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'); Want = '' }
        @{ Command = 'Move-PoolHostIdentity.ps1'; Arguments = @('-OldHostId', '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', '-NewHostId', '42eeeeeeeeeeeeeeeeeeeeeeeeeeeeee'); Want = '42eeeeeeeeeeeeeeeeeeeeeeeeeeeeee' }
    ) {
        $source = Get-Content -Raw (Join-Path $script:RepoRoot "test/pool/$Command")
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
        $helper = @'
$ErrorActionPreference = 'Stop'
Import-Module '__ADMIN__' -Force -DisableNameChecking
Import-Module '__GLOBAL__' -Force -DisableNameChecking
Import-Module powershell-yaml
$ExitOk = 0
$ExitFailure = 1
function Format-YurunaHostId { param($HostId) return $HostId }
function Open-YurunaPoolAdminStore { param($ConfigurationGitUrl, $ConfigurationDir, $Confirm) return @{ Ok = $true; Target = @{ ConfigurationGitUrl = 'fixture'; ConfigurationDir = $ConfigurationDir }; Error = '' } }
function Publish-YurunaPoolDocChange {
    param($ConfigurationDir, $RelPath, $Doc, $SchemaName, $Message, $Confirm)
    $saved = Save-YurunaPoolDoc -ConfigurationDir $ConfigurationDir -RelPath $RelPath -Doc $Doc -SchemaName $SchemaName -Confirm:$false
    if (-not $saved.Ok) { return @{ Ok = $false; Pushed = $false; Error = $saved.Error } }
    return @{ Ok = $true; Pushed = $true; Error = '' }
}
'@
        $helper = $helper.Replace('__ADMIN__', (Join-Path $script:RepoRoot 'test/modules/Test.PoolAdmin.psm1').Replace("'", "''")).Replace('__GLOBAL__', (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1').Replace("'", "''"))
        $child = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $child -Value ($ast.ParamBlock.Extent.Text + "`n" + $helper + "`n" + $source.Substring($source.IndexOf('# --- REGION: Validate the arguments')))
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $dir
        $doc = [ordered]@{ schemaVersion = 4; pools = @([ordered]@{ poolId = 'lab'; poolGuid = '42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'
                    members = @('42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', '42cccccccccccccccccccccccccccccc')
                    frameworkRing = [ordered]@{ canaryMembers = @('42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'); requiredPasses = 3 } }) }
        Set-Content -LiteralPath (Join-Path $dir 'pools.yml') -Value (ConvertTo-Yaml $doc)
        # NO_COLOR: a failure message quoting the child's output must stay valid XML.
        $color = Save-YurunaTestEnvironment -Name 'NO_COLOR'
        $env:NO_COLOR = '1'
        try { $output = & pwsh -NoProfile -NonInteractive -File $child @Arguments -ConfigurationDir $dir 2>&1 }
        finally { Restore-YurunaTestEnvironment -Saved $color }
        Assert-Equal 0 $LASTEXITCODE ($output -join "`n")
        $saved = Get-Content -Raw (Join-Path $dir 'pools.yml') | ConvertFrom-Yaml
        Assert-Equal $Want (@($saved.pools[0].frameworkRing.canaryMembers) -join ',')
        Assert-Equal 3 $saved.pools[0].frameworkRing.requiredPasses 'the operator''s pass count survives the write'
    }

    It 'are checked against members by Test-PoolConfiguration' {
        $source = Get-Content -Raw (Join-Path $script:RepoRoot 'test/pool/Test-PoolConfiguration.ps1')
        $ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$null)
        $helper = @'
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
Import-Module '__ADMIN__' -Force -DisableNameChecking
Import-Module '__GLOBAL__' -Force -DisableNameChecking
Import-Module powershell-yaml
$ExitOk = 0
$ExitFailure = 1
function Open-YurunaPoolAdminStore { param($ConfigurationGitUrl, $ConfigurationDir, $Confirm) return @{ Ok = $true; Target = @{ ConfigurationGitUrl = 'fixture'; ConfigurationDir = $ConfigurationDir }; Error = '' } }
'@
        $helper = $helper.Replace('__ADMIN__', (Join-Path $script:RepoRoot 'test/modules/Test.PoolAdmin.psm1').Replace("'", "''")).Replace('__GLOBAL__', (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1').Replace("'", "''"))
        $child = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $child -Value ($ast.ParamBlock.Extent.Text + "`n" + $helper + "`n" + $source.Substring($source.IndexOf('# --- REGION: Open the configuration store')))
        foreach ($case in @(@{ Canary = '42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; Exit = 0 }, @{ Canary = '42eeeeeeeeeeeeeeeeeeeeeeeeeeeeee'; Exit = 1 })) {
            $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $dir
            $doc = [ordered]@{ schemaVersion = 4; pools = @([ordered]@{ poolId = 'lab'; poolGuid = '42a1b2c3-d4e5-4f60-8a1b-2c3d4e5f6071'
                        members = @('42aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'); frameworkRing = [ordered]@{ canaryMembers = @($case.Canary); requiredPasses = 1 } }) }
            Set-Content -LiteralPath (Join-Path $dir 'pools.yml') -Value (ConvertTo-Yaml $doc)
            $color = Save-YurunaTestEnvironment -Name 'NO_COLOR'
            $env:NO_COLOR = '1'
            try { $output = & pwsh -NoProfile -NonInteractive -File $child -ConfigurationDir $dir 2>&1 }
            finally { Restore-YurunaTestEnvironment -Saved $color }
            Assert-Equal $case.Exit $LASTEXITCODE ($output -join "`n")
            if ($case.Exit -ne 0) { Assert-Match ([regex]::Escape($case.Canary)) ($output -join "`n") }
        }
    }
}
