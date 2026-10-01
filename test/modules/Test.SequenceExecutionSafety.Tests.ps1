<#PSScriptInfo
.VERSION 2026.09.30
.GUID 42e6d9c8-1705-43a2-89f3-6013cc25bb54
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test sequence safety pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
#>
#requires -version 7

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.Log.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.SequenceEngine.psm1') -Force -Global -DisableNameChecking
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
        Register-SequenceAction -Name safetyFixture -CapturesOwnFailureScreenshot $true -Handler {
            param($context)
            $state = Get-SequenceFailureState
            $rows.Add(@{ Number=$context.StepNum; StepCount=$context.StepCount; RunLost=$state.StepGuestRunLost; Tail=$state.WaitForTextOcrTail })
            if ($context.Step.seedOldCause) { $state.StepGuestRunLost=$true; $state.WaitForTextOcrTail='old OCR text' }
            if ($context.Step.children) {
                return (& $context.InvokeStepBlock -Steps $context.Step.children -ParentOrdinal $context.StepNum -ParentAction safetyFixture -ParentAttempt 1)
            }
            return -not [bool]$context.Step.fail
        }.GetNewClosure()
        $script:SequenceFile = Join-Path $TestDrive 'fixture.yml'
        Set-Content $script:SequenceFile 'fixture: mocked parser'
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
                'WaitForTextMatchedFailurePattern','WaitForTextClosestOnScreen','WaitForTextConsoleFlood')) { $state[$name] = 'stale' }
        $script:FixtureSequence = @{steps=@(@{action='safetyFixture';fail=$true})}
        Invoke-Sequence -HostType host.ubuntu.kvm -GuestKey guest.fixture -VMName never-a-real-vm -SequencePath $script:SequenceFile | Should -BeFalse
        foreach ($name in @('StepGuestAddressUnresolved','StepGuestTransportLost','StepGuestRunLost','StepGuestPayloadUnavailable',
                'WaitForTextMatchedFailurePattern','WaitForTextClosestOnScreen','WaitForTextConsoleFlood')) { $state[$name] | Should -BeNullOrEmpty }
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
