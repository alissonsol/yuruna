<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42fba86f-4ea4-4dbf-82c2-0ea57b04218c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner heartbeat pester
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
    Pester coverage for Test.RunnerHeartbeat.psm1 (the threadpool runner.heartbeat
    timer). Verifies the file is seeded and advanced while running, that Stop
    halts it, and that the error counter starts clean.
.DESCRIPTION
    Uses a short timer period so the test runs in well under a second. Throw-based
    assertions for Pester 5+.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.RunnerHeartbeat.psm1') -Force -DisableNameChecking

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking

}

Describe 'Start/Stop-RunnerHeartbeat' {
    It 'seeds the file, advances it while running, then freezes on Stop' {
        $dir = New-YurunaTestTempDir -Prefix 'yrn-beat-file'
        $f = Join-Path $dir 'runner.stepHeartbeat'
        [System.IO.File]::WriteAllText($f, '')
        try {
            Start-RunnerHeartbeat -Path $f -DueMs 40 -PeriodMs 40
            Start-Sleep -Milliseconds 250
            Assert-True (Test-Path $f) 'heartbeat file exists'
            $mtA = (Get-Item $f).LastWriteTimeUtc
            Start-Sleep -Milliseconds 200
            $mtB = (Get-Item $f).LastWriteTimeUtc
            Assert-True ($mtB -gt $mtA) 'timer advances the mtime while running'

            Stop-RunnerHeartbeat
            Start-Sleep -Milliseconds 120
            $mtC = (Get-Item $f).LastWriteTimeUtc
            Start-Sleep -Milliseconds 200
            $mtD = (Get-Item $f).LastWriteTimeUtc
            Assert-Equal -Expected $mtC -Actual $mtD -Because 'mtime frozen after Stop'
        } finally {
            Stop-RunnerHeartbeat
            Remove-YurunaTestTempDir $dir
        }
    }
    It 'stops the static timer after a forced module reload' {
        $path = Join-Path $TestDrive 'reload.heartbeat'
        try {
            Start-RunnerHeartbeat -Path $path -DueMs 20 -PeriodMs 20
            Start-Sleep -Milliseconds 100
            Import-Module (Join-Path $here 'Test.RunnerHeartbeat.psm1') -Force -DisableNameChecking
            Stop-RunnerHeartbeat
            Start-Sleep -Milliseconds 80
            $stopped = (Get-Item -LiteralPath $path).LastWriteTimeUtc
            Start-Sleep -Milliseconds 120
            (Get-Item -LiteralPath $path).LastWriteTimeUtc | Should -Be $stopped
        } finally { Stop-RunnerHeartbeat }
    }

    It 'Stop is idempotent (safe to call when not started / twice)' {
        Stop-RunnerHeartbeat
        Stop-RunnerHeartbeat   # must not throw
        Assert-True $true 'no throw on repeated Stop'
    }
    It 'Get-RunnerHeartbeatError returns a clean count on a healthy run' {
        $dir = New-YurunaTestTempDir -Prefix 'yrn-beat-file'
        $f = Join-Path $dir 'runner.stepHeartbeat'
        [System.IO.File]::WriteAllText($f, '')
        try {
            Start-RunnerHeartbeat -Path $f -DueMs 40 -PeriodMs 40
            Start-Sleep -Milliseconds 200
            Assert-Equal -Expected 0 -Actual (Get-RunnerHeartbeatError) -Because 'no write errors on a writable path'
        } finally {
            Stop-RunnerHeartbeat
            Remove-YurunaTestTempDir $dir
        }
    }
}


# The watchdog judges the inner by runner.stepHeartbeat, and its writers
# swallowed a failed write on Verbose: a full disk or a write lock then read as
# a wedged runspace, and the error reporting guarded a file nothing reads.
Describe 'Write-RunnerStepHeartbeat reports a heartbeat it cannot write' {
    BeforeEach {
        $script:BeatDir = New-YurunaTestTempDir -Prefix 'yrn-beat'
        & (Get-Module Test.RunnerHeartbeat) { $script:StepHeartbeatConsecutiveErrors = 0; $script:StepHeartbeatLastReportUtc = [DateTime]::MinValue }
    }
    AfterEach { Remove-YurunaTestTempDir $script:BeatDir }

    It 'counts failures, warns once a minute with an error log line, and resets on the next good write' {
        # A directory where the file belongs: every write fails the way a lock does.
        $blocked = Join-Path $script:BeatDir 'runner.stepHeartbeat'
        $null = New-Item -ItemType Directory -Path $blocked -Force
        $warnings = @()
        Write-RunnerStepHeartbeat -Path $blocked -WarningVariable +warnings -WarningAction SilentlyContinue
        Write-RunnerStepHeartbeat -Path $blocked -WarningVariable +warnings -WarningAction SilentlyContinue
        Assert-Equal -Expected 2 -Actual (Get-RunnerHeartbeatError) -Because 'every failed write is counted'
        Assert-Equal -Expected 1 -Actual @($warnings).Count -Because 'a failing writer is reported once a minute, not once per poll'
        Assert-Match -Pattern ([regex]::Escape($blocked)) -Actual ([string]$warnings[0]) -Because 'the warning names the file'
        $log = Get-Content -Raw -LiteralPath "$blocked.errors.log"
        Assert-Match -Pattern 'consecutive=1 ' -Actual $log -Because 'the error log keeps the error class for a later reader'
        Remove-Item -LiteralPath $blocked -Recurse -Force
        Write-RunnerStepHeartbeat -RuntimeDir $script:BeatDir
        Assert-Equal -Expected 0 -Actual (Get-RunnerHeartbeatError) -Because 'a good write ends the streak'
        Assert-True (Test-Path -LiteralPath $blocked -PathType Leaf) 'the heartbeat is written under the runtime directory'
    }
    It 'is the only writer of runner.stepHeartbeat in the inner runner' {
        $root = Split-Path -Parent $here
        foreach ($relative in 'modules/Test.RunnerHeartbeat.psm1', 'modules/Test.RunnerInnerLoop.psm1', 'modules/Invoke-TestRunnerInnerLoop.ps1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $relative), [ref]$null, [ref]$null)
            $direct = @($ast.FindAll({ param($n)
                $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and [string]$n.Member -eq 'WriteAllText' -and
                $n.Extent.Text -match 'stepHeartbeat|StepHeartbeatFile|\$target' }, $true) | Where-Object {
                    $fn = $_; while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
                    -not ($fn -and $fn.Name -eq 'Write-RunnerStepHeartbeat') })
            Assert-Equal -Expected 0 -Actual $direct.Count -Because "$relative writes the heartbeat through Write-RunnerStepHeartbeat"
        }
    }
}

Describe 'Runner phase evidence' {
    It 'retains earlier attempt phases after the live marker is replaced and cleared' {
        $savedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        $savedGeneration = Save-YurunaTestEnvironment -Name 'YURUNA_CYCLE_GENERATION'
        try {
            $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive 'phase-history'
            $null = New-Item -ItemType Directory -Path $env:YURUNA_RUNTIME_DIR
            $env:YURUNA_CYCLE_GENERATION = 'attempt-one'
            Write-RunnerPhase -Phase 'host-registration'
            $env:YURUNA_CYCLE_GENERATION = 'attempt-two'
            Write-RunnerPhase -Phase 'host-conditions'
            (Get-Content -Raw (Join-Path $env:YURUNA_RUNTIME_DIR 'runner.phase')) | Should -BeExactly 'host-conditions'
            Clear-RunnerPhase
            Test-Path (Join-Path $env:YURUNA_RUNTIME_DIR 'runner.phase') | Should -BeFalse
            $lines = @(Get-Content (Join-Path $env:YURUNA_RUNTIME_DIR 'outer.log'))
            $lines.Count | Should -Be 2
            $lines[0] | Should -Match "pid=$PID generation=attempt-one phase=host-registration"
            $lines[1] | Should -Match "pid=$PID generation=attempt-two phase=host-conditions"
            [datetime]::Parse(($lines[0] -split ' ')[0]).ToUniversalTime() | Should -BeLessOrEqual ([datetime]::UtcNow)
        } finally {
            Restore-YurunaTestEnvironment -Saved $savedRuntime
            Restore-YurunaTestEnvironment -Saved $savedGeneration
        }
    }

    It 'still publishes the live phase when the persistent timeline cannot be written' {
        $savedRuntime = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR'
        try {
            $env:YURUNA_RUNTIME_DIR = Join-Path $TestDrive 'phase-no-log'
            $null = New-Item -ItemType Directory -Path (Join-Path $env:YURUNA_RUNTIME_DIR 'outer.log') -Force
            Write-RunnerPhase -Phase 'host-driver'
            (Get-Content -Raw (Join-Path $env:YURUNA_RUNTIME_DIR 'runner.phase')) | Should -BeExactly 'host-driver'
            Test-Path (Join-Path $env:YURUNA_RUNTIME_DIR 'runner.stepHeartbeat') | Should -BeTrue
        } finally { Restore-YurunaTestEnvironment -Saved $savedRuntime }
    }
}

Describe 'Control pause progress' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
        function Get-PollDelay { param([int]$Attempt) $null = $Attempt; return 1 }
        function Write-OrchestratorLine { param([string]$Line) $null = $Line }
        function Send-CycleEventSafely { param([hashtable]$EventRecord) $null = $EventRecord }
    }
    It 'keeps the runspace heartbeat fresh while <Source> completes pause polls' -TestCases @(
        @{ Source = 'Test.SequenceEngine.psm1'; Variable = '$waitWhilePaused' }
        @{ Source = 'Test.Orchestrator.psm1'; Variable = '$orchWaitWhilePaused' }
    ) {
        param($Source, $Variable)
        $null = $Variable # Captured by the production AST lookup below.
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $Source), [ref]$null, [ref]$null)
        $assignment = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq $Variable
        }, $true)
        $pause = & ([scriptblock]::Create($assignment.Right.Extent.Text))
        $runtimeDir = Join-Path $TestDrive $Source
        New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
        $orchRuntimeDir = $runtimeDir
        $script:pauseFlag = Join-Path $runtimeDir 'control.step-pause'
        $script:pauseHb = Join-Path $runtimeDir 'runner.stepHeartbeat'
        $stepPauseFlagFile = $script:pauseFlag
        $orchStepPauseFlag = $script:pauseFlag
        $SequencePath = 'fixture.yml'; $GuestKey = 'guest.fixture'; $VMName = 'fixture'
        $writeCurrentAction = { param($Line, $Code, $Label, $Arguments) $null = @($Line, $Code, $Label, $Arguments) }
        $null = @($orchRuntimeDir, $stepPauseFlagFile, $orchStepPauseFlag, $SequencePath, $GuestKey, $VMName, $writeCurrentAction)
        $script:Fail = @{}
        Set-Content -LiteralPath $script:pauseFlag -Value ([datetime]::UtcNow.ToString('o'))
        Set-Content -LiteralPath $script:pauseHb -Value 'seed'
        $script:pausePolls = 0
        Mock Get-PollDelay {
            if ($script:pausePolls -gt 0) {
                ([datetime]::UtcNow - (Get-Item $script:pauseHb).LastWriteTimeUtc).TotalSeconds | Should -BeLessThan 5
            }
            [IO.File]::SetLastWriteTimeUtc($script:pauseHb, [datetime]::UtcNow.AddSeconds(-2701))
            $script:pausePolls++
            if ($script:pausePolls -eq 3) { Remove-Item -LiteralPath $script:pauseFlag }
            return 1
        }
        & $pause '[1/1]'
        $script:pausePolls | Should -Be 3
        ([datetime]::UtcNow - (Get-Item $script:pauseHb).LastWriteTimeUtc).TotalSeconds | Should -BeLessThan 5
    }
}
