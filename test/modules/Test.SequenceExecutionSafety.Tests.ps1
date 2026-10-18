<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42e6d9c8-1705-43a2-89f3-6013cc25bb54
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence safety pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.Log.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.SequenceEngine.psm1') -Force -Global -DisableNameChecking
    # Captured before any Mock: a filtered mock alone fails the calls its
    # filter does not match, and this suite relies on the real command there.
    $script:RealActionHandler = & (Get-Module Test.SequenceEngine) { Get-Command Invoke-SequenceActionHandler }
    Import-Module (Join-Path $PSScriptRoot 'Test.PerfAggregate.psm1') -Force -Global -DisableNameChecking
    $script:PriorRuntime = $env:YURUNA_RUNTIME_DIR
    $script:PriorLog = $env:YURUNA_LOG_DIR
    $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive 'runtime'
    $env:YURUNA_LOG_DIR = Join-Path $TestDrive 'log'
    $null = New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR, $env:YURUNA_LOG_DIR -Force
}
AfterAll {
    $env:YURUNA_RUNTIME_DIR = $script:PriorRuntime
    $env:YURUNA_LOG_DIR = $script:PriorLog
}

Describe 'real sequence execution preserves source positions and current-step causes' {
    BeforeEach {
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { }
        Mock Restart-VMConsole -ModuleName Test.SequenceEngine { $true }
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { throw 'a fixture must never capture a live VM' }
        Mock Read-SequenceFile -ModuleName Test.SequenceEngine { $script:FixtureSequence }
        $script:FixtureRows = [Collections.Generic.List[object]]::new()
        $rows = $script:FixtureRows
        Register-SequenceAction -Name safetyFixture -ReplaySafety observe -CapturesOwnFailureScreenshot $true -Handler {
            param($context)
            $state = Get-SequenceFailureState
            $rows.Add(@{ Number=$context.StepNum; StepCount=$context.StepCount; RunLost=$state.StepGuestRunLost; Tail=$state.WaitForTextOcrTail; StepInvocationId=$context.StepInvocationId; SequenceInvocationId=$context.SequenceInvocationId })
            if ($context.Step.seedEvidence) {
                $state.WaitForTextOutputStaticSeconds=200
                $context.ExecutionProfile=@{ diagnosticOutcome='unavailable'; reasonCode='profile-ssh-timeout'; timedOut=$true; sshResponsive=$false; recorder=@{heartbeatAgeSeconds=180} }
            }
            if ($context.Step.seedUnreachable) {
                # The client's own connect failure: no harness kill, no log, a dead path.
                $context.ExecutionProfile=@{ diagnosticOutcome='unavailable'; reasonCode='profile-ssh-unreachable'; timedOut=$false; transportFailed=$true; transport='unreachable'; sshResponsive=$false
                    recorder=@{ heartbeatAgeSeconds=256; clockAnalysis=@{ comparison='same-boot'; warnings=@(@{ code='cpu-idle-exceeds-boot-uptime'; cpu='cpu0' }) } } }
            }
            if ($context.Step.seedOldCause) { $state.StepGuestRunLost=$true; $state.WaitForTextOcrTail='old OCR text' }
            if ($context.Step.children) {
                $childResult = & $context.InvokeStepBlock -Steps $context.Step.children -ParentOrdinal $context.StepNum -ParentAction safetyFixture -ParentAttempt 1
                if ($context.Step.throwAfterChildren) { throw 'fixture outer handler crash' }
                return $childResult
            }
            if ($context.Step.failFirstAttempt) { return $rows.Count -gt 1 }
            return -not [bool]$context.Step.fail
        }.GetNewClosure()
        $script:SequenceFile = Join-Path $TestDrive 'fixture.yml'
        Set-Content $script:SequenceFile 'fixture: mocked parser'
    }
    It 'reads a client-side connect failure as an unresponsive transport and lists the recorder clock anomaly' {
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:FixtureSequence = @{ steps=@(@{action='safetyFixture';seedUnreachable=$true;fail=$true}) }
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $record.reason | Should -Be step -Because "the failure path must not crash: $($record.context.crash | ConvertTo-Json -Compress -Depth 4)"
        $advisory = $record.context.causeDetail.progressAdvisory
        $advisory.SshResponsiveness | Should -Be unresponsive
        $advisory.Verdict | Should -Be 'progress-suspect'
        $advisory.Signals | Should -Contain 'guest-clock-anomaly'
        $advisory.ClockWarnings | Should -Contain 'cpu-idle-exceeds-boot-uptime'
        $advisory.AutomaticRecoveryAllowed | Should -BeFalse
    }
    It 'reports resumed steps using their original file positions' {
        $script:FixtureSequence = @{ steps=@(1..5 | ForEach-Object { @{ action='safetyFixture' } }) }
        Invoke-Sequence -HostType 'host.ubuntu.kvm' -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile -StartStep 3 -StopStep 4 | Should -BeTrue
        ($script:FixtureRows.Number -join ',') | Should -Be '3,4'
        (@($script:FixtureRows | ForEach-Object { $_.StepCount }) -join ',') | Should -Be '5,5'
        (Get-SequenceFailureState).LastSucceededStepNumber | Should -Be 4
    }
    It 'drops a previous step cause before a later failing action' {
        $script:FixtureSequence = @{ steps=@(@{action='safetyFixture';seedOldCause=$true},@{action='safetyFixture';fail=$true}) }
        Invoke-Sequence -HostType 'host.ubuntu.kvm' -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $script:FixtureRows.Count | Should -Be 2
        $script:FixtureRows[1].RunLost | Should -BeNullOrEmpty
        $script:FixtureRows[1].Tail | Should -BeNullOrEmpty
        (Get-SequenceFailureState).LastFailedStepNumber | Should -Be 2
        (Get-SequenceFailureState).LastSucceededStepNumber | Should -Be 1
    }
    It 'records a resumed nested failure against the original outer step' {
        $script:FixtureSequence = @{ steps=@(1..5 | ForEach-Object { @{action='safetyFixture'} }) + @(
            @{action='safetyFixture';children=@(@{action='safetyFixture'},@{action='safetyFixture';fail=$true})}
        ) }
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile -StartStep 5 | Should -BeFalse
        ($script:FixtureRows.Number -join ',') | Should -Be '5,6,1,2'
        (@($script:FixtureRows | ForEach-Object { $_.StepCount }) -join ',') | Should -Be '6,6,2,2'
        (Get-SequenceFailureState).LastFailedStepNumber | Should -Be 6
        (Get-SequenceFailureState).LastSucceededStepNumber | Should -Be 5
    }
    It 'clears transport and OCR causes inherited from a previous sequence' {
        $state = Get-SequenceFailureState
        foreach ($name in @('StepGuestAddressUnresolved','StepGuestTransportLost','StepGuestRunLost','StepGuestPayloadUnavailable',
                'StepVmNotStopped','WaitForTextMatchedFailurePattern','WaitForTextClosestOnScreen','WaitForTextConsoleFlood')) { $state[$name] = 'stale' }
        $script:FixtureSequence = @{steps=@(@{action='safetyFixture';fail=$true})}
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        foreach ($name in @('StepGuestAddressUnresolved','StepGuestTransportLost','StepGuestRunLost','StepGuestPayloadUnavailable',
                'StepVmNotStopped','WaitForTextMatchedFailurePattern','WaitForTextClosestOnScreen','WaitForTextConsoleFlood')) { $state[$name] | Should -BeNullOrEmpty }
    }
    It 'preserves capture failures and independent progress observations in step events' {
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:FixtureSequence = @{ steps=@(@{action='safetyFixture';seedEvidence=$true;fail=$true}) }
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        Should -Invoke Send-CycleEventSafely -ModuleName Test.SequenceEngine -Times 1 -Exactly -ParameterFilter {
            $EventRecord.event -eq 'step_end' -and $EventRecord.executionEvidence.reasonCode -eq 'profile-ssh-timeout' -and
            $EventRecord.progressAdvisory.Verdict -eq 'progress-suspect' -and -not $EventRecord.progressAdvisory.AutomaticRecoveryAllowed
        }
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $record.stepInvocationId | Should -Be $script:FixtureRows[0].StepInvocationId
        $record.context.causeDetail.progressAdvisory.SshResponsiveness | Should -Be unresponsive
    }
    It 'does not assign a previous passing step ID to a crash before the next invocation' {
        Mock Resolve-YurunaOperatorProjectLabel -ModuleName Test.SequenceEngine {
            param($Entry)
            if ($Entry.throwBeforeInvocation) { throw 'fixture gate crash' }
            return ''
        }
        $script:FixtureSequence = @{steps=@(@{action='safetyFixture'},@{action='safetyFixture';throwBeforeInvocation=$true})}
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $script:FixtureRows.Count | Should -Be 1
        $record.reason | Should -Be crash
        $record.stepInvocationId | Should -Be ''
        $record.originatingStepInvocationId | Should -Be ''
    }
    It 'keeps a failed fetch capture identity and advisory through nested retry wrappers' {
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:FixtureEvents = [Collections.Generic.List[object]]::new()
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { $script:FixtureEvents.Add($EventRecord) }
        Mock Invoke-SequenceActionHandler -ModuleName Test.SequenceEngine { & $script:RealActionHandler @PesterBoundParameters }
        Mock Invoke-SequenceActionHandler -ModuleName Test.SequenceEngine {
            (Get-SequenceFailureState).WaitForTextOutputStaticSeconds = 200
            $Context.ExecutionProfile = @{ diagnosticOutcome='unavailable'; reasonCode='profile-ssh-timeout'; timedOut=$true; sshResponsive=$false; recorder=@{heartbeatAgeSeconds=180} }
            $script:FixtureRows.Add(@{ StepInvocationId=$Context.StepInvocationId; SequenceInvocationId=$Context.SequenceInvocationId })
            return $false
        } -ParameterFilter { $Name -eq 'sshFetchAndExecute' }
        $script:FixtureSequence = @{steps=@(@{action='retry';maxAttempts=1;steps=@(
            @{action='retry';maxAttempts=1;steps=@(@{action='sshFetchAndExecute';script='fixture-fetch.sh'})}
        )})}
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $wrappers = @($script:FixtureEvents | Where-Object { $_.event -eq 'step_end' -and $_.actionVerb -eq 'retry' })
        $wrappers.Count | Should -Be 2
        $record.stepInvocationId | Should -Be $wrappers[-1].stepInvocationId
        $record.originatingStepInvocationId | Should -Be $script:FixtureRows[0].StepInvocationId
        $record.originatingStepInvocationId | Should -Not -Be $record.stepInvocationId
        $record.originatingSequenceInvocationId | Should -Be $script:FixtureRows[0].SequenceInvocationId
        $record.originatingSequenceInvocationId | Should -Match '^[0-9a-f]{32}$'
        $record.context.causeDetail.progressAdvisory.SshResponsiveness | Should -Be unresponsive
        $record.context.causeDetail.progressAdvisory.HeartbeatAgeSeconds | Should -Be 180
        foreach ($wrapper in $wrappers) {
            $wrapper.originatingStepInvocationId | Should -Be $record.originatingStepInvocationId
            $wrapper.progressAdvisory.Verdict | Should -Be 'progress-suspect'
            $wrapper.progressAdvisory.AutomaticRecoveryAllowed | Should -BeFalse
        }
        $failure = @($script:FixtureEvents | Where-Object event -EQ step_failure)[-1]
        $failure.stepInvocationId | Should -Be $record.stepInvocationId
        $failure.originatingStepInvocationId | Should -Be $record.originatingStepInvocationId
        $failure.progressAdvisory.SshResponsiveness | Should -Be unresponsive
    }
    It 'clears a recovered retry leaf before a later failure and a new sequence' {
        Mock Get-VMScreenshot -ModuleName Test.SequenceEngine { $false }
        $script:FixtureSequence = @{steps=@(
            @{action='retry';maxAttempts=2;steps=@(@{action='safetyFixture';seedEvidence=$true;failFirstAttempt=$true})},
            @{action='safetyFixture';fail=$true}
        )}
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $script:FixtureRows.Count | Should -Be 3
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $record.originatingStepInvocationId | Should -Be $script:FixtureRows[2].StepInvocationId
        $record.context.causeDetail.progressAdvisory.SshResponsiveness | Should -Be unavailable
        $record.context.causeDetail.progressAdvisory.HeartbeatAgeSeconds | Should -BeNullOrEmpty
        $script:FixtureSequence = @{steps=@(@{action='retry';maxAttempts=1;steps=@(@{action='safetyFixture'})})}
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeTrue
        (Get-SequenceFailureState).OriginatingStepInvocationId | Should -Be ''
        (Get-SequenceFailureState).OriginatingSequenceInvocationId | Should -Be ''
        (Get-SequenceFailureState).StepProgressAdvisory | Should -BeNullOrEmpty
    }
    It 'restores the outer invocation after a nested success before an outer crash' {
        $script:FixtureSequence = @{steps=@(@{action='safetyFixture';children=@(@{action='safetyFixture'});throwAfterChildren=$true})}
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $script:FixtureRows.Count | Should -Be 2
        $record.stepInvocationId | Should -Be $script:FixtureRows[0].StepInvocationId
        $record.stepInvocationId | Should -Not -Be $script:FixtureRows[1].StepInvocationId
    }
    It 'attributes a distinct outer crash to its own invocation after a failed child' {
        $script:FixtureEvents = [Collections.Generic.List[object]]::new()
        Mock Send-CycleEventSafely -ModuleName Test.SequenceEngine { $script:FixtureEvents.Add($EventRecord) }
        $script:FixtureSequence = @{steps=@(@{action='safetyFixture';children=@(@{action='safetyFixture';seedEvidence=$true;fail=$true});throwAfterChildren=$true})}
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        $record = Get-Content (Join-Path $env:YURUNA_LOG_DIR 'last_failure.json') -Raw | ConvertFrom-Json
        $record.reason | Should -Be crash
        $record.stepInvocationId | Should -Be $script:FixtureRows[0].StepInvocationId
        $record.originatingStepInvocationId | Should -Be $record.stepInvocationId
        $record.originatingStepInvocationId | Should -Not -Be $script:FixtureRows[1].StepInvocationId
        $failure = @($script:FixtureEvents | Where-Object event -EQ step_failure)[-1]
        $failure.progressAdvisory | Should -BeNullOrEmpty
    }
    It 'publishes the OCR sidecar writer to its handler module' {
        (Get-Command Save-OcrSidecar -ErrorAction Stop).ModuleName | Should -Be 'Test.SequenceEngine'
    }
}

Describe 'checkpoint matching reuses already parsed timestamps' {
    It 'parses a step interval once for any number of typed checkpoint candidates' {
        $step = @{ startedAtUtc='2026-09-27T00:00:00Z'; endedAtUtc='2026-09-27T00:00:10Z' }
        $sidecars = @(1..100 | ForEach-Object { @{ ReceivedAt=[datetime]::new(2026,9,26,0,0,0,[DateTimeKind]::Utc); Consumed=$false } })
        $sidecars += @{ ReceivedAt=[datetime]::new(2026,9,27,0,0,5,[DateTimeKind]::Utc); Consumed=$false; Label='match' }
        Mock ConvertTo-PerfUtc -ModuleName Test.PerfAggregate { param($Value) return [string]$Value }
        (Find-PerfCheckpoint -Step $step -Sidecar $sidecars).Label | Should -Be match
        Should -Invoke ConvertTo-PerfUtc -ModuleName Test.PerfAggregate -Times 2 -Exactly
    }
}
