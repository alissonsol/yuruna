<#PSScriptInfo
.VERSION 2026.10.31
.GUID 4229269d-af79-433d-acb6-d4997d18a139
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test orchestration warm-resume pester
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
    Pester coverage for warm resume at the orchestration entry boundary: a
    guest entry that failed on a transient class resumes in place from its
    checkpoint, under the same eligibility, rewind and safety rules as the
    guest workload path, before the chain counts it as failed.
.DESCRIPTION
    An orchestration walked its entries once, so one transient failure in a
    late entry ended the chain and the next cycle redid every earlier entry
    from step 1.
    Run: Invoke-Pester -Path test/modules/Test.OrchestratorWarmResume.Tests.ps1
#>

BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    # The commands the orchestrator calls must exist for Pester to mock them.
    Import-Module (Join-Path $here 'Test.Prelude.psm1') -Force -Global -DisableNameChecking
    Initialize-YurunaEntryPointModuleSet -For Inner -ModulesDir $here
    Import-Module (Join-Path $here 'Test.Orchestrator.psm1') -Force -Global -DisableNameChecking -WarningAction SilentlyContinue
    $script:Orchestrator = Get-Module -Name 'Test.Orchestrator'
    $script:Entry = [pscustomobject]@{ index = 2; name = 'inner-a'; path = '/seq/inner-a.yml'; sequence = @{}; kind = 'guest' }
    function script:Invoke-Resume {
        param([hashtable]$Config = @{ testCycle = @{} }, [hashtable]$FailedRun)
        if (-not $FailedRun) { $FailedRun = @{ ok = $false; vmName = 'test-vm'; guestKey = 'guest.ubuntu.server.26'; reason = 'x'; sequences = @('prereq', 'inner-a') } }
        & $script:Orchestrator {
            param($Entry, $Run, $Config)
            Invoke-OrchestratorWarmResume -Entry $Entry -FailedRun $Run -AttemptStartUtc ([DateTime]::UtcNow.AddMinutes(-5)) `
                -RepoRoot '/repo' -SequencesDir '/seq' -HostType 'host.ubuntu.kvm' -Config $Config
        } $script:Entry $FailedRun $Config
    }
}

Describe 'Invoke-OrchestratorWarmResume' {
    BeforeEach {
        $script:SavedLogDir = Save-YurunaTestEnvironment -Name 'YURUNA_LOG_DIR'
        $env:YURUNA_LOG_DIR = $TestDrive
        $script:Checkpoint = @{ FailureClass = 'wait_timeout'; SequenceName = 'inner-a'; ResumeFromStep = 4; StepEffect = 'unknown'; StepEffectSource = '' }
        $script:Replay = [pscustomobject]@{ ResumeFromStep = 3; Rewound = $true; DeclineReason = ''; ReplayClass = 'idempotent'; StepEffectSource = '' }
        $script:RunResults = [System.Collections.Generic.Queue[hashtable]]::new()
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Test.Orchestrator Read-WarmResumeCheckpoint { $script:Checkpoint }
        Mock -ModuleName Test.Orchestrator Resolve-CycleReplayStep { $script:Replay }
        Mock -ModuleName Test.Orchestrator Invoke-OrchestratorGuestRun { if ($script:RunResults.Count) { $script:RunResults.Dequeue() } else { @{ ok = $true; vmName = 'test-vm'; guestKey = 'g'; reason = ''; sequences = @('prereq', 'inner-a') } } }
        Mock -ModuleName Test.Orchestrator Write-OrchestratorLine { $script:Lines.Add([string]$Message) }
        Mock -ModuleName Test.Orchestrator Send-CycleEventSafely { }
    }
    AfterEach { Restore-YurunaTestEnvironment -Saved $script:SavedLogDir }

    It 'resumes a transient failure at the replay plan''s step of the checkpoint''s sequence, and recovers' {
        $result = Invoke-Resume
        Assert-True $result.ok 'the resumed run passed, so the entry passes'
        Should -Invoke -ModuleName Test.Orchestrator Invoke-OrchestratorGuestRun -Times 1 -Exactly -ParameterFilter {
            $ResumeFromSequence -eq 'inner-a' -and $ResumeFromStep -eq 3 -and $Name -eq 'inner-a' }
        Assert-True (@($script:Lines | Where-Object { $_ -match 'WARM-RESUME' }).Count -ge 2) "the resume and the recovery are on the transcript: $($script:Lines -join ' | ')"
        Should -Invoke -ModuleName Test.Orchestrator Send-CycleEventSafely -Times 1 -Exactly
    }

    It 'stops at maxAttempts and returns the last failure' {
        $script:RunResults.Enqueue(@{ ok = $false; vmName = 'test-vm'; guestKey = 'g'; reason = 'again'; sequences = @('prereq', 'inner-a') })
        $script:RunResults.Enqueue(@{ ok = $false; vmName = 'test-vm'; guestKey = 'g'; reason = 'still'; sequences = @('prereq', 'inner-a') })
        $result = Invoke-Resume -Config @{ testCycle = @{ warmResume = @{ enabled = $true; maxAttempts = 2 } } }
        Assert-False $result.ok
        Assert-Equal -Expected 'still' -Actual $result.reason -Because 'the last attempt''s reason stands'
        Should -Invoke -ModuleName Test.Orchestrator Invoke-OrchestratorGuestRun -Times 2 -Exactly
    }

    It 'does not resume when <Case>' -TestCases @(
        @{ Case = 'the class is not transient'; Class = 'plan_invalid'; Sequence = 'inner-a'; Step = 4; Config = @{ testCycle = @{} } }
        @{ Case = 'the checkpoint names a sequence outside the chain'; Class = 'wait_timeout'; Sequence = 'other'; Step = 4; Config = @{ testCycle = @{} } }
        @{ Case = 'no step was recorded'; Class = 'wait_timeout'; Sequence = 'inner-a'; Step = 0; Config = @{ testCycle = @{} } }
        @{ Case = 'warm resume is turned off'; Class = 'wait_timeout'; Sequence = 'inner-a'; Step = 4; Config = @{ testCycle = @{ warmResume = @{ enabled = $false } } } }
    ) {
        param([string]$Case, [string]$Class, [string]$Sequence, [int]$Step, [hashtable]$Config)
        $null = $Case
        $script:Checkpoint = @{ FailureClass = $Class; SequenceName = $Sequence; ResumeFromStep = $Step; StepEffect = 'unknown'; StepEffectSource = '' }
        Assert-Null (Invoke-Resume -Config $Config) 'no resume was attempted'
        Should -Invoke -ModuleName Test.Orchestrator Invoke-OrchestratorGuestRun -Times 0 -Exactly
    }

    It 'lets the original failure stand when a replay cannot be shown safe' {
        $script:Replay = [pscustomobject]@{ ResumeFromStep = 4; Rewound = $false; DeclineReason = 'no-restore-point'; ReplayClass = 'mutating'; StepEffectSource = '' }
        $warnings = @(Invoke-Resume 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        Assert-Equal -Expected 1 -Actual $warnings.Count -Because 'the decline is explained'
        Should -Invoke -ModuleName Test.Orchestrator Invoke-OrchestratorGuestRun -Times 0 -Exactly
        Should -Invoke -ModuleName Test.Orchestrator Send-CycleEventSafely -Times 1 -Exactly -Because 'the declined event is sent'
    }
}

Describe 'Invoke-OrchestratorGuestRun resumes at the chain step of a sequence-local step' {
    BeforeEach {
        $script:Chain = @(
            [pscustomobject]@{ name = 'prereq'; path = '/seq/prereq.yml'; sequence = @{}; stepCount = 5; globalStart = 1 }
            [pscustomobject]@{ name = 'inner-a'; path = '/seq/inner-a.yml'; sequence = @{}; stepCount = 6; globalStart = 6 }
        )
        Mock -ModuleName Test.Orchestrator Test-GuestFolder { $true }
        Mock -ModuleName Test.Orchestrator Get-TestVMName { 'test-vm' }
        Mock -ModuleName Test.Orchestrator Resolve-TestSequencePlan {
            @{ resolveFailed = $false; chainEntries = $script:Chain; chainPlan = @{}; effectiveUser = ''; effectiveHost = ''; chainTotalSteps = 11; warmPath = $false }
        }
        Mock -ModuleName Test.Orchestrator Get-VMState { 'running' }
        Mock -ModuleName Test.Orchestrator Get-FirstExecutedStepAction { 'waitForText' }
        Mock -ModuleName Test.Orchestrator Write-OrchestratorLine { }
        Mock -ModuleName Test.Orchestrator Invoke-TestSequenceChain { @{ ok = $true; finishedVmName = 'test-vm' } }
        function script:Invoke-GuestRun {
            param([string]$ResumeFromSequence = '', [int]$ResumeFromStep = 0)
            & $script:Orchestrator {
                param($From, $Step)
                Invoke-OrchestratorGuestRun -Sequence @{ baseline = @{ 'ubuntu.server.26' = 'x' } } -SequencePath '/seq/inner-a.yml' -Name 'inner-a' `
                    -RepoRoot '/repo' -SequencesDir '/seq' -HostType 'host.ubuntu.kvm' -Config @{ vmStart = @{} } `
                    -ResumeFromSequence $From -ResumeFromStep $Step
            } $ResumeFromSequence $ResumeFromStep
        }
    }

    It 'starts a full run at chain step 1 and names its chain' {
        $run = Invoke-GuestRun
        Assert-True $run.ok
        Assert-Equal -Expected 'prereq,inner-a' -Actual (@($run.sequences) -join ',')
        Should -Invoke -ModuleName Test.Orchestrator Invoke-TestSequenceChain -Times 1 -Exactly -ParameterFilter { $StartStep -eq 1 }
    }

    It 'maps step 3 of the second chain sequence to chain step 8' {
        $null = Invoke-GuestRun -ResumeFromSequence 'inner-a' -ResumeFromStep 3
        Should -Invoke -ModuleName Test.Orchestrator Invoke-TestSequenceChain -Times 1 -Exactly -ParameterFilter { $StartStep -eq 8 }
        Should -Invoke -ModuleName Test.Orchestrator Get-FirstExecutedStepAction -Times 1 -Exactly -ParameterFilter { $StartStep -eq 8 }
    }

    It 'refuses a step its chain does not have, without running anything' {
        $run = Invoke-GuestRun -ResumeFromSequence 'inner-a' -ResumeFromStep 9
        Assert-False $run.ok
        Should -Invoke -ModuleName Test.Orchestrator Invoke-TestSequenceChain -Times 0 -Exactly
    }
}

Describe 'the orchestration consults warm resume for a failed guest entry' {
    It 'calls Invoke-OrchestratorWarmResume when the guest run failed, before scoring the entry' {
        $fn = Get-YurunaTestFunctionAst -Path (Join-Path $here 'Test.Orchestrator.psm1') -Name 'Invoke-OrchestrationSequence'
        $branch = $fn.Body.Find({ param($n)
            $n -is [System.Management.Automation.Language.IfStatementAst] -and $n.Clauses[0].Item1.Extent.Text -eq '-not $run.ok' }, $true)
        Assert-NotNull $branch 'the failed-run branch'
        Assert-True ((Get-YurunaTestCommandCallCount -Ast $branch -CommandName 'Invoke-OrchestratorWarmResume') -eq 1) 'it asks for a warm resume'
        $text = $fn.Body.Extent.Text
        Assert-True ($text.IndexOf('Invoke-OrchestratorWarmResume') -lt $text.IndexOf('$ok = [bool]$run.ok')) 'before the entry is scored'
    }
}
