<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 42f816f3-f8fb-4c0a-84b9-8070c8990937
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner outcome record pester
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
    Pins the rule that a cycle is scored a pass only from an outcome record the
    cycle process left behind and that names the cycle's own generation.
.DESCRIPTION
    The cycle runs in a child process and reports through runner.cycle.outcome.json.
    Reading a missing file as a clean completion, or accepting a clean exit code
    in place of a record, turns every failure to record into a green host: the
    cycle may have been killed, may have run a different generation, or may have
    failed to say anything at all. These cases cover the reader that validates the
    record, the dispatcher that scores a cycle from it, the publisher the cycle
    process uses to write it, and the loop's refusal to treat an unrecorded
    outcome as anything but a fault.
#>

BeforeAll {
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here '../../automation/Yuruna.Common.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.RecoveryContract.psm1') -Force -Global -DisableNameChecking
Import-Module (Join-Path $here 'Test.RunnerOuterLoop.psm1') -Force -DisableNameChecking

$script:Generation = ('c' * 32) + ':4'

function Write-OutcomeFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: writes a throwaway file under a temp directory.')]
    param([string]$Path, [string]$Text)
    Set-Content -LiteralPath $Path -Value $Text -Encoding utf8 -NoNewline
}
}

Describe 'Read-CycleOutcomeRecord' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('outrec-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:File = Join-Path $script:Dir 'runner.cycle.outcome.json'
    }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'accepts a record that names its outcome, exit code and the issued generation' {
        Write-OutcomeFixture $script:File ('{"outcome":"completed","exitCode":0,"cycleGeneration":"' + $script:Generation + '"}')
        $r = Read-CycleOutcomeRecord -Path $script:File -ExpectedGeneration $script:Generation
        $r.Valid | Should -BeTrue
        $r.Reason | Should -Be 'ok'
        $r.Outcome | Should -Be 'completed'
        $r.ExitCode | Should -Be 0
        $r.CycleGeneration | Should -Be $script:Generation
    }
    It 'accepts every outcome name the runner emits, and a negative exit code' -TestCases @(
        @{ Name = 'completed' }, @{ Name = 'refresh-gated' }, @{ Name = 'refresh-preflight' }, @{ Name = 'pull-error' }
        @{ Name = 'paused' }, @{ Name = 'drain' }, @{ Name = 'storage-full' }, @{ Name = 'spawn-failed' }
        @{ Name = 'cycle-aborted' }, @{ Name = 'shutdown' }, @{ Name = 'no-cycle-result' }
    ) {
        param($Name)
        Write-OutcomeFixture $script:File ('{"outcome":"' + $Name + '","exitCode":-1,"cycleGeneration":null}')
        $r = Read-CycleOutcomeRecord -Path $script:File -ExpectedGeneration ''
        $r.Valid | Should -BeTrue -Because $Name
        $r.ExitCode | Should -Be -1
    }
    It 'does not compare a generation the caller never issued' {
        Write-OutcomeFixture $script:File '{"outcome":"completed","exitCode":0,"cycleGeneration":null}'
        (Read-CycleOutcomeRecord -Path $script:File -ExpectedGeneration '').Valid | Should -BeTrue
        (Read-CycleOutcomeRecord -Path $script:File).Valid | Should -BeTrue
    }
    It 'rejects a missing file as missing' {
        $r = Read-CycleOutcomeRecord -Path $script:File -ExpectedGeneration $script:Generation
        $r.Valid | Should -BeFalse
        $r.Reason | Should -Be 'missing'
    }
    It 'rejects <Why> as malformed' -TestCases @(
        @{ Why = 'text that is not JSON'; Text = 'completed' }
        @{ Why = 'a truncated document'; Text = '{"outcome":"completed","exitCo' }
        @{ Why = 'an empty file'; Text = '' }
        @{ Why = 'a JSON array'; Text = '[{"outcome":"completed","exitCode":0}]' }
        @{ Why = 'a JSON string'; Text = '"completed"' }
        @{ Why = 'a record with no outcome'; Text = '{"exitCode":0}' }
        @{ Why = 'an empty outcome'; Text = '{"outcome":"","exitCode":0}' }
        @{ Why = 'a numeric outcome'; Text = '{"outcome":5,"exitCode":0}' }
        @{ Why = 'an outcome that is not a name'; Text = '{"outcome":"Completed OK","exitCode":0}' }
        @{ Why = 'a record with no exit code'; Text = '{"outcome":"completed"}' }
        @{ Why = 'a string exit code'; Text = '{"outcome":"completed","exitCode":"0"}' }
        @{ Why = 'a fractional exit code'; Text = '{"outcome":"completed","exitCode":0.5}' }
        @{ Why = 'a boolean exit code'; Text = '{"outcome":"completed","exitCode":true}' }
        @{ Why = 'an exit code beyond 32 bits'; Text = '{"outcome":"completed","exitCode":99999999999}' }
    ) {
        param($Why, $Text)
        Write-OutcomeFixture $script:File $Text
        $r = Read-CycleOutcomeRecord -Path $script:File -ExpectedGeneration ''
        $r.Valid | Should -BeFalse -Because $Why
        $r.Reason | Should -Be 'malformed' -Because $Why
        $r.Detail | Should -Not -BeNullOrEmpty
    }
    It 'rejects a record stamped with another cycle''s generation as stale' {
        $other = ('d' * 32) + ':3'
        Write-OutcomeFixture $script:File ('{"outcome":"completed","exitCode":0,"cycleGeneration":"' + $other + '"}')
        $r = Read-CycleOutcomeRecord -Path $script:File -ExpectedGeneration $script:Generation
        $r.Valid | Should -BeFalse
        $r.Reason | Should -Be 'stale-generation'
        $r.Detail | Should -Match ([regex]::Escape($other))
        $r.Detail | Should -Match ([regex]::Escape($script:Generation))
    }
    It 'rejects an unstamped record when a generation was issued' {
        Write-OutcomeFixture $script:File '{"outcome":"completed","exitCode":0,"cycleGeneration":null}'
        $r = Read-CycleOutcomeRecord -Path $script:File -ExpectedGeneration $script:Generation
        $r.Valid | Should -BeFalse
        $r.Reason | Should -Be 'stale-generation'
    }
    It 'compares the generation exactly, not case-insensitively' {
        Write-OutcomeFixture $script:File ('{"outcome":"completed","exitCode":0,"cycleGeneration":"' + $script:Generation.ToUpperInvariant() + '"}')
        (Read-CycleOutcomeRecord -Path $script:File -ExpectedGeneration $script:Generation).Valid | Should -BeFalse
    }
}

Describe 'Invoke-OuterCycleDispatch scores a cycle only from a valid outcome record' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('outdisp-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:SavedRuntime = $env:YURUNA_RUNTIME_DIR
        $env:YURUNA_RUNTIME_DIR = $script:Dir
        $script:CycleScript = Join-Path $script:Dir 'cycle.ps1'
        Set-Content -LiteralPath $script:CycleScript -Value '# fixture' -Encoding utf8
        $script:RecordFile = Join-Path $script:Dir 'runner.cycle.outcome.json'
        # The child writes its record while it runs, after the dispatcher has
        # cleared any earlier one, so the stand-in spawn does the same. The
        # fixture text and exit code travel in the environment: a mock body runs
        # in the module's scope, where this test's script variables are not.
        $env:OUTREC_FIXTURE_TEXT = ''
        $env:OUTREC_FIXTURE_EXIT = '0'
        Mock -ModuleName Test.RunnerOuterLoop Start-Process {
            if ($env:OUTREC_FIXTURE_TEXT) {
                Set-Content -LiteralPath (Join-Path $env:YURUNA_RUNTIME_DIR 'runner.cycle.outcome.json') -Value $env:OUTREC_FIXTURE_TEXT -Encoding utf8 -NoNewline
            }
            [pscustomobject]@{ Id = $PID; HasExited = $true; ExitCode = [int]$env:OUTREC_FIXTURE_EXIT }
        }
        Mock -ModuleName Test.RunnerOuterLoop Write-OuterLog { }
        Mock -ModuleName Test.RunnerOuterLoop Write-Warning { }
        $script:State = @{ CycleScript = $script:CycleScript; PwshExe = 'pwsh'; ShutdownState = @{ Requested = $false }; CycleGeneration = $script:Generation }
    }
    AfterEach {
        Remove-Item Env:OUTREC_FIXTURE_TEXT, Env:OUTREC_FIXTURE_EXIT -ErrorAction SilentlyContinue
        if ($null -eq $script:SavedRuntime) { Remove-Item Env:YURUNA_RUNTIME_DIR -ErrorAction SilentlyContinue } else { $env:YURUNA_RUNTIME_DIR = $script:SavedRuntime }
        Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'scores a valid record by what it says, and reports its generation' {
        $env:OUTREC_FIXTURE_TEXT = '{"outcome":"completed","exitCode":0,"cycleGeneration":"' + $script:Generation + '"}'
        $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 4
        $r.Outcome | Should -Be 'completed'
        $r.ExitCode | Should -Be 0
        $r.CycleGeneration | Should -Be $script:Generation
        Test-Path -LiteralPath $script:RecordFile | Should -BeFalse -Because 'the record is consumed'
    }
    It 'passes on the failure class and detail a cycle recorded, for the recovery planner' {
        $env:OUTREC_FIXTURE_TEXT = '{"outcome":"pull-error","exitCode":0,"cycleGeneration":"' + $script:Generation + '","failureClass":"bootstrap_sync","detail":"index.lock exists"}'
        $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 4
        $r.Outcome | Should -Be 'pull-error'
        $r.RecordFailureClass | Should -Be 'bootstrap_sync'
        $r.RecordDetail | Should -Be 'index.lock exists'
    }
    It 'reports no class or detail for a record that carries none' {
        $env:OUTREC_FIXTURE_TEXT = '{"outcome":"completed","exitCode":0,"cycleGeneration":"' + $script:Generation + '"}'
        $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 4
        $r.RecordFailureClass | Should -Be ''
        $r.RecordDetail | Should -Be ''
    }
    It 'lets the record, not the process exit code, carry the verdict' {
        $env:OUTREC_FIXTURE_TEXT = '{"outcome":"completed","exitCode":1,"cycleGeneration":"' + $script:Generation + '"}'
        $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 4
        $r.Outcome | Should -Be 'completed'
        $r.ExitCode | Should -Be 1
    }
    It 'does not score a clean exit with no record as a pass' {
        $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 4
        $r.Outcome | Should -Be 'outcome-unrecorded'
        $r.ExitCode | Should -Not -Be 0
        $r.ExitCode | Should -Be (Get-UnrecordedOutcomeExitCode)
        $r.OutcomeReason | Should -Be 'missing'
        $r.CycleGeneration | Should -Be $script:Generation
        Assert-MockCalled -CommandName Write-Warning -ModuleName Test.RunnerOuterLoop -Scope It
    }
    It 'does not score a clean exit with a malformed record as a pass, and keeps the record' {
        $env:OUTREC_FIXTURE_TEXT = '{"outcome":"completed","exitCo'
        $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 4
        $r.Outcome | Should -Be 'outcome-unrecorded'
        $r.OutcomeReason | Should -Be 'malformed'
        $kept = Join-Path $script:Dir 'runner.cycle.outcome.rejected.json'
        Test-Path -LiteralPath $kept | Should -BeTrue
        (Get-Content -LiteralPath $kept -Raw) | Should -Be '{"outcome":"completed","exitCo'
        Test-Path -LiteralPath $script:RecordFile | Should -BeFalse
    }
    It 'does not accept another cycle''s record' {
        $env:OUTREC_FIXTURE_TEXT = '{"outcome":"completed","exitCode":0,"cycleGeneration":"' + ('d' * 32) + ':3"}'
        $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 4
        $r.Outcome | Should -Be 'outcome-unrecorded'
        $r.OutcomeReason | Should -Be 'stale-generation'
        $r.CycleGeneration | Should -Be $script:Generation -Because 'the generation reported is the one the runner issued, not the stale record''s'
    }
    It 'accepts an unstamped record only when no generation was issued' {
        $env:OUTREC_FIXTURE_TEXT = '{"outcome":"completed","exitCode":0,"cycleGeneration":null}'
        (Invoke-OuterCycleDispatch -State $script:State -Cycle 4).Outcome | Should -Be 'outcome-unrecorded'
        $script:State.Remove('CycleGeneration')
        (Invoke-OuterCycleDispatch -State $script:State -Cycle 4).Outcome | Should -Be 'completed'
    }
    It 'keeps a failing exit code when a long-running cycle left no record' {
        InModuleScope Test.RunnerOuterLoop { $script:CycleAbortSeconds = 0 }
        try {
            $env:OUTREC_FIXTURE_EXIT = '3'
            $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 4
            $r.Outcome | Should -Be 'outcome-unrecorded'
            $r.ExitCode | Should -Be 3 -Because 'the failure was real whether or not it was recorded'
        } finally {
            InModuleScope Test.RunnerOuterLoop { $script:CycleAbortSeconds = 30 }
        }
    }
    It 'still reads a child that died young without a record as an aborted cycle, not an unrecorded one' {
        $env:OUTREC_FIXTURE_EXIT = '3'
        $r = Invoke-OuterCycleDispatch -State $script:State -Cycle 4
        $r.Outcome | Should -Be 'cycle-aborted'
        $r.ExitCode | Should -Be 3
    }
}

Describe 'Publish-CycleOutcomeRecord' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('outpub-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:File = Join-Path $script:Dir 'runner.cycle.outcome.json'
        Mock -ModuleName Test.RecoveryContract Write-Warning { }
    }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'records the cycle''s own verdict and returns its exit code unchanged' -TestCases @(
        @{ Outcome = 'completed'; Code = 0 }, @{ Outcome = 'completed'; Code = 3 }, @{ Outcome = 'pull-error'; Code = 0 }
    ) {
        param($Outcome, $Code)
        $exit = Publish-CycleOutcomeRecord -Result ([pscustomobject]@{ Outcome = $Outcome; ExitCode = $Code }) -OutcomeFile $script:File -CycleGeneration $script:Generation
        $exit | Should -Be $Code
        $r = Read-CycleOutcomeRecord -Path $script:File -ExpectedGeneration $script:Generation
        $r.Valid | Should -BeTrue
        $r.Outcome | Should -Be $Outcome
        $r.ExitCode | Should -Be $Code
    }
    It 'leaves the generation unstamped when none was issued' {
        $null = Publish-CycleOutcomeRecord -Result ([pscustomobject]@{ Outcome = 'completed'; ExitCode = 0 }) -OutcomeFile $script:File
        (Get-Content -LiteralPath $script:File -Raw | ConvertFrom-Json).cycleGeneration | Should -BeNullOrEmpty
    }
    It 'records a cycle that published no result as a failure, never as a completion' -TestCases @(
        @{ Result = $null }
        @{ Result = [pscustomobject]@{ Outcome = ''; ExitCode = 0 } }
        @{ Result = [pscustomobject]@{ Outcome = 'completed'; ExitCode = $null } }
    ) {
        param($Result)
        $exit = Publish-CycleOutcomeRecord -Result $Result -OutcomeFile $script:File -CycleGeneration $script:Generation
        $exit | Should -Not -Be 0
        $r = Read-CycleOutcomeRecord -Path $script:File -ExpectedGeneration $script:Generation
        $r.Outcome | Should -Be 'no-cycle-result'
        $r.ExitCode | Should -Be $exit
    }
    It 'withholds a clean exit code when the record cannot be written' {
        $unwritable = Join-Path (Join-Path $script:Dir 'no-such-directory') 'runner.cycle.outcome.json'
        $exit = Publish-CycleOutcomeRecord -Result ([pscustomobject]@{ Outcome = 'completed'; ExitCode = 0 }) -OutcomeFile $unwritable -CycleGeneration $script:Generation
        $exit | Should -Be (Get-UnrecordedOutcomeExitCode)
        $exit | Should -Not -Be 0
    }
    It 'keeps a failing exit code when the record cannot be written' {
        $unwritable = Join-Path (Join-Path $script:Dir 'no-such-directory') 'runner.cycle.outcome.json'
        $exit = Publish-CycleOutcomeRecord -Result ([pscustomobject]@{ Outcome = 'completed'; ExitCode = 3 }) -OutcomeFile $unwritable -CycleGeneration $script:Generation
        $exit | Should -Be 3
    }
    It 'withholds a clean exit code when what was written does not read back' {
        Mock -ModuleName Test.RecoveryContract Write-YurunaStateFile { $true }
        $exit = Publish-CycleOutcomeRecord -Result ([pscustomobject]@{ Outcome = 'completed'; ExitCode = 0 }) -OutcomeFile $script:File -CycleGeneration $script:Generation
        $exit | Should -Be (Get-UnrecordedOutcomeExitCode) -Because 'a write that reported success but left nothing is not a record'
    }
    It 'is the path the cycle process takes, and no clean default survives in it' {
        $cycleScript = Join-Path $here 'Invoke-TestCycleRunner.ps1'
        $text = Get-Content -LiteralPath $cycleScript -Raw
        $text | Should -Match 'Publish-CycleOutcomeRecord'
        $text | Should -Not -Match "else \{ 'completed' \}" -Because 'a missing result must not default to a completed cycle'
        $text | Should -Not -Match 'else \{ 0 \}' -Because 'a missing exit code must not default to success'
    }
}
