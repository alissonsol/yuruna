<#PSScriptInfo
.VERSION 2026.11.05
.GUID 4235af32-2433-4a17-983c-401dd12cfbf9
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test runner fault telemetry pester
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
    Pins the runner_fault event Update-RunnerFaultStatus in
    Test.RunnerOuterLoop.psm1 raises: one per attempt generation, or per fault
    published without one, carrying what status.json publishes as runnerFault,
    accepted by the event schema with the runner's own fault classes, and
    delivered by the next cycle's stream.
.DESCRIPTION
    status.json keeps only the current runner fault, which the next attempt
    overwrites, and the attempt history rotates, so a fault between two passing
    cycles must reach the event stream. These cases drive the fault publisher
    against a real runtime directory and read the pending event queue it fills.
#>

BeforeAll {
    $ErrorActionPreference = 'Stop'
    $here = Split-Path -Parent $PSCommandPath
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $repoRoot 'automation/Yuruna.Common.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.EventSchema.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.Log.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.Status.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.RunnerOuterLoop.psm1') -Force -DisableNameChecking
    $script:JsonOption = @{}
    if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $script:JsonOption.DateKind = 'String' }

    function New-FaultFixture {
        <#
        .SYNOPSIS
            A runtime directory whose status.json holds a completed passing cycle.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds a throwaway runtime directory the case removes.')]
        [CmdletBinding()]
        [OutputType([string])]
        param()
        $dir = New-YurunaTestTempDir -Prefix 'yrn-fault-event'
        $doc = [ordered]@{
            schemaVersion = 1; overallStatus = 'pass'; cycle = 41; cycleStartUtc = '2026-11-02T09:00:00Z'
            cycleGeneration = 'runner:41'; finishedAt = '2026-11-02T09:20:00Z'; guests = @(); gitCommits = @(); history = @(); lastFailure = $null
        }
        [IO.File]::WriteAllText((Join-Path $dir 'status.json'), ($doc | ConvertTo-Json -Depth 8))
        return $dir
    }

    function Read-QueuedEvent {
        [CmdletBinding()]
        [OutputType([object[]])]
        param([Parameter(Mandatory)][string]$RuntimeDir)
        $path = Join-Path $RuntimeDir 'cycle-events.pending.json'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
        $jsonOption = $script:JsonOption
        return @(([IO.File]::ReadAllText($path) | ConvertFrom-Json -AsHashtable @jsonOption).events)
    }

    function Read-RunnerFault {
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([Parameter(Mandatory)][string]$RuntimeDir)
        $jsonOption = $script:JsonOption
        return ([IO.File]::ReadAllText((Join-Path $RuntimeDir 'status.json')) | ConvertFrom-Json -AsHashtable @jsonOption).runnerFault
    }
}

Describe 'A runner fault becomes one runner_fault event per attempt' {
    It 'queues the fault status.json publishes, once, though the pause republishes it' {
        $dir = New-FaultFixture
        try {
            $spawned = [datetime]::UtcNow.AddMinutes(-7)
            $evidence = @{ stage = 'CycleSpawn'; description = 'the inner exited 3 before reporting'; frameworkCommitSha = 'abc1234' }
            $fault = $null
            foreach ($state in 'fault', 'paused') {
                Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState $state -Reason 'inner exited 3' -FailureClass 'inner_exited' `
                    -AttemptGeneration 'runner:42' -SpawnedAtUtc $spawned -ExitCode 3 -AttemptEvidence $evidence -Confirm:$false | Should -BeTrue
                if (-not $fault) { $fault = Read-RunnerFault -RuntimeDir $dir }
            }
            $events = @(Read-QueuedEvent -RuntimeDir $dir | Where-Object { $_.event -eq 'runner_fault' })
            $events.Count | Should -Be 1
            foreach ($field in 'failureClass', 'stage', 'severity', 'stepName', 'errorMessage', 'attemptGeneration', 'attemptStartedAtUtc',
                    'attemptElapsedSeconds', 'frameworkCommitSha', 'recordPath', 'transcriptPath', 'recordedAt') {
                $events[0].ContainsKey($field) | Should -BeTrue -Because "the event carries $field"
                $events[0][$field] | Should -Be $fault[$field] -Because "$field matches the published runnerFault"
            }
            $events[0].failureClass | Should -Be 'inner_exited'
            $events[0].stage | Should -Be 'CycleSpawn'
            $events[0].recordPath | Should -Match '^runner-attempts/[0-9a-f]{24}/runner-fault\.json$'
            $events[0].eventId | Should -Not -BeNullOrEmpty
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'republishes the fault with the recordedAt text it was first published with' {
        $dir = New-FaultFixture
        try {
            $spawned = [datetime]::UtcNow.AddMinutes(-3)
            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'fault' -FailureClass 'inner_exited' `
                -AttemptGeneration 'runner:42' -SpawnedAtUtc $spawned -Confirm:$false
            $first = [string](Read-RunnerFault -RuntimeDir $dir).recordedAt
            $first | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$'
            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'paused' -FailureClass 'inner_exited' `
                -AttemptGeneration 'runner:42' -SpawnedAtUtc $spawned -Confirm:$false
            [string](Read-RunnerFault -RuntimeDir $dir).recordedAt | Should -BeExactly $first
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'queues each fault published without an attempt generation as an event of its own' {
        $dir = New-FaultFixture
        try {
            foreach ($message in 'escape 1: config read threw', 'escape 2: state file helper threw') {
                $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'paused' -FailureClass 'script_error' `
                    -Reason $message -SpawnedAtUtc ([datetime]::UtcNow) -Confirm:$false
            }
            @(Read-QueuedEvent -RuntimeDir $dir | Where-Object { $_.event -eq 'runner_fault' } | ForEach-Object { $_.errorMessage }) |
                Should -Be @('escape 1: config read threw', 'escape 2: state file helper threw')
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'queues a new attempt''s fault as an event of its own' {
        $dir = New-FaultFixture
        try {
            foreach ($generation in 'runner:42', 'runner:43') {
                foreach ($state in 'fault', 'paused') {
                    $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState $state -FailureClass 'config_gate_failed' `
                        -AttemptGeneration $generation -SpawnedAtUtc ([datetime]::UtcNow.AddMinutes(-1)) -Confirm:$false
                }
            }
            @(Read-QueuedEvent -RuntimeDir $dir | Where-Object { $_.event -eq 'runner_fault' } | ForEach-Object { $_.attemptGeneration }) |
                Should -Be @('runner:42', 'runner:43')
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'raises no runner_fault for an attempt that completed its cycle' {
        $dir = New-FaultFixture
        try {
            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'paused' -AttemptGeneration 'runner:41' -Confirm:$false
            (Read-RunnerFault -RuntimeDir $dir) | Should -BeNullOrEmpty
            @(Read-QueuedEvent -RuntimeDir $dir).Count | Should -Be 0
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'raises none for a state that publishes no fault' {
        $dir = New-FaultFixture
        try {
            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'cycle-start' -AttemptGeneration 'runner:42' -Confirm:$false
            @(Read-QueuedEvent -RuntimeDir $dir).Count | Should -Be 0
        } finally { Remove-YurunaTestTempDir $dir }
    }

    It 'reaches the next cycle''s stream with no schema violation' {
        $dir = New-FaultFixture
        $cycle = Join-Path $dir '000043.2026-11-02.10-30-00.fixturehost.incomplete'
        $null = New-Item -ItemType Directory -Path $cycle -Force
        $saved = Save-YurunaTestGlobal -Name '__YurunaCycleFolder', '__YurunaCycleIdentity', '__YurunaCycleStartUtc'
        try {
            $null = Update-RunnerFaultStatus -RuntimeDir $dir -RunnerState 'fault' -StalledPhase 'config-gate' -FailureClass 'preamble_stall' `
                -AttemptGeneration 'runner:42' -SpawnedAtUtc ([datetime]::UtcNow.AddMinutes(-11)) -Confirm:$false
            Set-YurunaTestGlobal -Value @{ __YurunaCycleFolder = $cycle; __YurunaCycleIdentity = '000043.2026-11-02.10-30-00.fixturehost'; __YurunaCycleStartUtc = '2026-11-02T10:30:00Z' }
            (Send-PendingCycleEvent -RuntimeDir $dir).Delivered | Should -Be 1
            $jsonOption = $script:JsonOption
            $lines = @(Get-Content -LiteralPath (Join-Path $cycle 'cycle.events.ndjson') | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable @jsonOption })
            @($lines | ForEach-Object { $_.event }) | Should -Be @('runner_fault') -Because 'a schema violation would precede the event as a line of its own'
            $lines[0].failureClass | Should -Be 'preamble_stall'
            $lines[0].stepName | Should -Be 'config-gate'
        } finally {
            Restore-YurunaTestGlobal -Saved $saved
            Remove-YurunaTestTempDir $dir
        }
    }
}

# A runner keeps the modules it started with, so a runner started before it
# queued its faults never does. Every runner records each failed attempt in the
# attempt history, and the cycle process, which loads the current code, reads it.
Describe 'A cycle queues the runner faults its runner did not' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.RunnerAttemptHistory.psm1') -Force -DisableNameChecking

        function Add-GateAttempt {
            <#
            .SYNOPSIS
                Record an attempt by its configuration gate, the way every attempt
                is recorded: passed and finished now unless told otherwise. Every
                attempt that opened a cycle has a passed gate.
            #>
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: writes into a throwaway runtime directory.')]
            [CmdletBinding()]
            param(
                [Parameter(Mandatory)][string]$RuntimeDir, [Parameter(Mandatory)][string]$AttemptGeneration,
                [switch]$Failed, [datetime]$FinishedAtUtc = [DateTime]::UtcNow
            )
            $relative = Initialize-RunnerAttemptDirectory -RuntimeDir $RuntimeDir -AttemptGeneration $AttemptGeneration -Confirm:$false
            $record = [ordered]@{
                schemaVersion = 1; attemptGeneration = $AttemptGeneration
                startedAtUtc = $FinishedAtUtc.AddSeconds(-5).ToString('o'); finishedAtUtc = $FinishedAtUtc.ToString('o')
                frameworkCommitSha = 'abc1234'; passed = -not $Failed; skipped = $false; exitCode = [int][bool]$Failed
                failureClass = if ($Failed) { 'config_gate_failed' } else { '' }; description = if ($Failed) { 'gate failed' } else { '' }
                recordPath = "$relative/config-gate.json"; transcriptPath = "$relative/config-gate.log"
            }
            [IO.File]::WriteAllText((Join-Path $RuntimeDir "$relative/config-gate.json"), ($record | ConvertTo-Json -Depth 4))
            Update-RunnerAttemptHistory -RuntimeDir $RuntimeDir -Confirm:$false
        }

        function Open-EarlierCycle {
            <#
            .SYNOPSIS
                Open a cycle that started at the given time the way a cycle process
                older than the attempt-history producer did: it drains the queue
                into its stream and queues nothing of its own.
            #>
            [CmdletBinding()]
            param([Parameter(Mandatory)][string]$RuntimeDir, [Parameter(Mandatory)][int]$CycleNumber, [Parameter(Mandatory)][datetime]$StartUtc)
            $start = $StartUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture)
            $name = Format-CycleFolderBaseName -CycleNumber $CycleNumber -CycleStartUtc $start -HostId 'fixturehost'
            $folder = Join-Path $RuntimeDir "status/log/$name"
            $null = New-Item -ItemType Directory -Path $folder -Force
            Set-YurunaTestGlobal -Value @{ __YurunaCycleFolder = $folder; __YurunaCycleIdentity = $name; __YurunaCycleStartUtc = $start }
            $null = Send-PendingCycleEvent -RuntimeDir $RuntimeDir
        }

        function Open-FixtureCycle {
            <#
            .SYNOPSIS
                Open a cycle through Start-LogFile and return the events its stream
                holds. It starts now, after every attempt the case records, as a
                cycle starts after its own gate.
            #>
            [CmdletBinding()]
            [OutputType([object[]])]
            param([Parameter(Mandatory)][string]$RuntimeDir, [Parameter(Mandatory)][int]$CycleNumber)
            $start = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture)
            $null = Start-LogFile -TestRoot $RuntimeDir -CycleStartUtc $start -Hostname 'fixture-host' -CycleNumber $CycleNumber -Confirm:$false
            $path = Join-Path (Get-Variable -Name '__YurunaCycleFolder' -Scope Global -ValueOnly) 'cycle.events.ndjson'
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
            $jsonOption = $script:JsonOption
            return @(Get-Content -LiteralPath $path | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable @jsonOption })
        }
    }
    BeforeEach {
        $script:Dir = New-FaultFixture
        $script:SavedGlobals = Save-YurunaTestGlobal -Name '__YurunaCycleFolder', '__YurunaLogFile', '__YurunaCycleIdentity', '__YurunaCycleStartUtc'
        $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR', 'YURUNA_CYCLE_GENERATION'
        Remove-Item Env:YURUNA_LOG_DIR -ErrorAction SilentlyContinue
        $env:YURUNA_RUNTIME_DIR = $script:Dir
        $env:YURUNA_CYCLE_GENERATION = 'runner:50'
        Set-YurunaTestGlobal -Value @{ __YurunaCycleFolder = $null; __YurunaLogFile = $null; __YurunaCycleIdentity = $null; __YurunaCycleStartUtc = $null }
    }
    AfterEach {
        Restore-YurunaTestGlobal -Saved $script:SavedGlobals
        Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
        Remove-YurunaTestTempDir $script:Dir
    }

    It 'carries a fault the runner recorded without queuing it into the next stream, once' {
        # An older runner records the attempt and queues nothing.
        $retained = Write-RunnerAttemptFaultArtifact -RuntimeDir $script:Dir -AttemptGeneration 'runner:42' -FailureClass 'inner_exited' `
            -Description 'inner exited 1' -StartedAtUtc ([datetime]::UtcNow.AddSeconds(-13)) -FrameworkCommitSha 'abc1234' -ExitCode 1 -Confirm:$false
        # The attempt the cycle runs under records its passing gate before the cycle opens.
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:50'
        $stream = @(Open-FixtureCycle -RuntimeDir $script:Dir -CycleNumber 43)
        @($stream | ForEach-Object { $_.event }) | Should -Be @('runner_fault', 'cycle_start') -Because 'the fault joins the stream ahead of cycle_start, and validates'
        $fault = $stream[0]
        $fault.attemptGeneration | Should -BeExactly 'runner:42'
        $fault.failureClass | Should -BeExactly 'inner_exited'
        $fault.errorMessage | Should -BeExactly 'inner exited 1'
        $fault.frameworkCommitSha | Should -BeExactly 'abc1234'
        $fault.recordPath | Should -BeExactly $retained.recordPath
        $fault.recordPath | Should -Match '^runner-attempts/[0-9a-f]{24}/runner-fault\.json$'
        $jsonOption = $script:JsonOption
        $record = [IO.File]::ReadAllText((Join-Path $script:Dir $fault.recordPath)) | ConvertFrom-Json -AsHashtable @jsonOption
        $finished = [datetime]::Parse([string]$record.finishedAtUtc, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $fault.timestamp | Should -BeExactly ($finished.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture)) -Because 'the event is dated when the attempt failed'
        $fault.eventId | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $script:Dir ((Split-Path -Parent $fault.recordPath) + '/runner-fault.queued')) -PathType Leaf | Should -BeTrue
        @(Open-FixtureCycle -RuntimeDir $script:Dir -CycleNumber 44 | ForEach-Object { $_.event }) | Should -Be @('cycle_start') -Because 'a queued fault is not queued again'
    }

    It 'queues the faults of attempts that never opened a cycle, oldest first' {
        $null = Write-RunnerAttemptFaultArtifact -RuntimeDir $script:Dir -AttemptGeneration 'runner:42' -FailureClass 'config_gate_failed' `
            -Description 'gate failed' -StartedAtUtc ([datetime]::UtcNow.AddSeconds(-30)) -Confirm:$false
        $null = Write-RunnerAttemptFaultArtifact -RuntimeDir $script:Dir -AttemptGeneration 'runner:43' -FailureClass 'inner_exited' `
            -Description 'inner exited 3' -StartedAtUtc ([datetime]::UtcNow.AddSeconds(-10)) -ExitCode 3 -Confirm:$false
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:50'
        $stream = @(Open-FixtureCycle -RuntimeDir $script:Dir -CycleNumber 44)
        @($stream | ForEach-Object { $_.event }) | Should -Be @('runner_fault', 'runner_fault', 'cycle_start')
        @($stream | Where-Object { $_.event -eq 'runner_fault' } | ForEach-Object { $_.attemptGeneration }) | Should -Be @('runner:42', 'runner:43')
        @($stream | Where-Object { $_.event -eq 'runner_fault' } | ForEach-Object { $_.eventId } | Select-Object -Unique).Count | Should -Be 2
    }

    It 'places a fault ahead of a newer event already queued, keeping the stream in time order' {
        # A fault an older runner did not queue, an hour-long failure pause, then
        # a restart whose boot recovery queues an event of its own.
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:42' -Failed -FinishedAtUtc ([DateTime]::UtcNow.AddMinutes(-90))
        $recovered = [DateTime]::UtcNow.AddMinutes(-1).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture)
        Add-PendingCycleEvent -RuntimeDir $script:Dir -EventRecord @{ timestamp = $recovered; event = 'boot_recovery_completed'; archivedCycleCount = 0 } | Should -BeTrue
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:50'
        $stream = @(Open-FixtureCycle -RuntimeDir $script:Dir -CycleNumber 43)
        @($stream | ForEach-Object { $_.event }) | Should -Be @('runner_fault', 'boot_recovery_completed', 'cycle_start') -Because 'Loki refuses a line more than an hour behind the newest line of its stream'
        [string[]]$stamps = @($stream | ForEach-Object { [string]$_.timestamp })
        $stamps | Should -Be ([string[]]@($stamps | Sort-Object -CaseSensitive))
    }

    It 'sends a fault the runner already queued only once' {
        foreach ($state in 'fault', 'paused') {
            $null = Update-RunnerFaultStatus -RuntimeDir $script:Dir -RunnerState $state -FailureClass 'inner_exited' `
                -AttemptGeneration 'runner:42' -SpawnedAtUtc ([datetime]::UtcNow.AddMinutes(-2)) -Confirm:$false
        }
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:50'
        @(Open-FixtureCycle -RuntimeDir $script:Dir -CycleNumber 43 | Where-Object { $_.event -eq 'runner_fault' } | ForEach-Object { $_.attemptGeneration }) |
            Should -Be @('runner:42')
        @(Open-FixtureCycle -RuntimeDir $script:Dir -CycleNumber 44 | Where-Object { $_.event -eq 'runner_fault' }).Count | Should -Be 0
    }

    It 'sends no second copy of a fault that an older cycle already carried' {
        # A runner that queues its faults queued attempt 11's; attempt 12 passed
        # its gate, and its cycle, run by code older than the attempt-history
        # producer, carried that fault and marked nothing. The cycle then failed,
        # and the runner recorded and queued attempt 12's fault over its passed
        # gate.
        $null = Update-RunnerFaultStatus -RuntimeDir $script:Dir -RunnerState 'fault' -FailureClass 'config_gate_failed' `
            -AttemptGeneration 'runner:11' -SpawnedAtUtc ([datetime]::UtcNow.AddMinutes(-1)) -Confirm:$false
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:12'
        Open-EarlierCycle -RuntimeDir $script:Dir -CycleNumber 12 -StartUtc ([DateTime]::UtcNow)
        $null = Update-RunnerFaultStatus -RuntimeDir $script:Dir -RunnerState 'fault' -FailureClass 'inner_exited' `
            -AttemptGeneration 'runner:12' -SpawnedAtUtc ([datetime]::UtcNow.AddMinutes(-1)) -Confirm:$false
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:50'
        @(Open-FixtureCycle -RuntimeDir $script:Dir -CycleNumber 50 | Where-Object { $_.event -eq 'runner_fault' } | ForEach-Object { $_.attemptGeneration }) |
            Should -Be @('runner:12') -Because 'attempt 11''s fault is in the stream of the cycle that opened after it'
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('runner:11'))).ToLowerInvariant().Substring(0, 24)
        Test-Path -LiteralPath (Join-Path $script:Dir "runner-attempts/$digest/runner-fault.queued") -PathType Leaf | Should -BeTrue
    }

    It 'queues a fault the cycles opened after it did not carry, though they carried another' {
        # An older runner recorded attempt 11 and queued nothing. The cycle after
        # it carried only a fault of an attempt the history no longer holds.
        $null = Write-RunnerAttemptFaultArtifact -RuntimeDir $script:Dir -AttemptGeneration 'runner:11' -FailureClass 'config_gate_failed' `
            -Description 'gate failed' -StartedAtUtc ([datetime]::UtcNow.AddSeconds(-30)) -Confirm:$false
        Add-PendingCycleEvent -RuntimeDir $script:Dir -EventRecord @{ event = 'runner_fault'; failureClass = 'inner_exited'; attemptGeneration = 'runner:10' } | Should -BeTrue
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:12'
        Open-EarlierCycle -RuntimeDir $script:Dir -CycleNumber 12 -StartUtc ([DateTime]::UtcNow)
        $null = Write-RunnerAttemptFaultArtifact -RuntimeDir $script:Dir -AttemptGeneration 'runner:12' -FailureClass 'inner_exited' `
            -Description 'inner exited 3' -StartedAtUtc ([datetime]::UtcNow.AddSeconds(-10)) -ExitCode 3 -Confirm:$false
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:50'
        @(Open-FixtureCycle -RuntimeDir $script:Dir -CycleNumber 50 | Where-Object { $_.event -eq 'runner_fault' } | ForEach-Object { $_.attemptGeneration }) |
            Should -Be @('runner:11', 'runner:12')
    }

    It 'leaves a failure older than the newest passing attempt to the cycles after it' {
        $retained = Write-RunnerAttemptFaultArtifact -RuntimeDir $script:Dir -AttemptGeneration 'runner:40' -FailureClass 'inner_exited' `
            -Description 'inner exited 1' -StartedAtUtc ([datetime]::UtcNow.AddSeconds(-20)) -Confirm:$false
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:41'
        @(Open-FixtureCycle -RuntimeDir $script:Dir -CycleNumber 43 | ForEach-Object { $_.event }) | Should -Be @('cycle_start')
        Test-Path -LiteralPath (Join-Path $script:Dir ((Split-Path -Parent $retained.recordPath) + '/runner-fault.queued')) | Should -BeFalse
    }

    It 'leaves an older failure to the earlier cycle that opened after it' {
        # A failure, a pass whose cycle opened after it, then failures enough to
        # push that pass out of the window: the history keeps the first failure
        # in olderFailures, and that cycle was the one to carry it.
        $start = [DateTime]::UtcNow.AddHours(-3)
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:fa' -Failed -FinishedAtUtc $start.AddMinutes(-10)
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:41' -FinishedAtUtc $start.AddMinutes(-1)
        Open-EarlierCycle -RuntimeDir $script:Dir -CycleNumber 41 -StartUtc $start
        foreach ($n in 1..19) { Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration "runner:f$n" -Failed -FinishedAtUtc $start.AddMinutes(5 * $n) }
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:50'
        $jsonOption = $script:JsonOption
        $index = [IO.File]::ReadAllText((Join-Path $script:Dir 'runner-attempts/index.json')) | ConvertFrom-Json -AsHashtable @jsonOption
        @($index.olderFailures | ForEach-Object { $_.attemptGeneration }) | Should -Be @('runner:fa')
        @($index.attempts | Where-Object { $_.passed } | ForEach-Object { $_.attemptGeneration }) | Should -Be @('runner:50') -Because 'the pass that carried it left the window'
        @(Open-FixtureCycle -RuntimeDir $script:Dir -CycleNumber 50 | Where-Object { $_.event -eq 'runner_fault' } | ForEach-Object { $_.attemptGeneration }) |
            Should -Be @(1..19 | ForEach-Object { "runner:f$_" })
        Test-Path -LiteralPath (Join-Path $script:Dir ((Split-Path -Parent $index.olderFailures[0].recordPath) + '/runner-fault.queued')) | Should -BeFalse
    }

    It 'leaves an older failure alone when no earlier cycle folder is left to bound it' {
        # The same history with the pass's cycle folder gone, as pool storage
        # move mode leaves the log directory once it archives each cycle.
        $start = [DateTime]::UtcNow.AddHours(-3)
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:fa' -Failed -FinishedAtUtc $start.AddMinutes(-10)
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:41' -FinishedAtUtc $start.AddMinutes(-1)
        foreach ($n in 1..19) { Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration "runner:f$n" -Failed -FinishedAtUtc $start.AddMinutes(5 * $n) }
        Add-GateAttempt -RuntimeDir $script:Dir -AttemptGeneration 'runner:50'
        $jsonOption = $script:JsonOption
        $index = [IO.File]::ReadAllText((Join-Path $script:Dir 'runner-attempts/index.json')) | ConvertFrom-Json -AsHashtable @jsonOption
        @($index.olderFailures | ForEach-Object { $_.attemptGeneration }) | Should -Be @('runner:fa')
        @(Open-FixtureCycle -RuntimeDir $script:Dir -CycleNumber 50 | Where-Object { $_.event -eq 'runner_fault' } | ForEach-Object { $_.attemptGeneration }) |
            Should -Be @(1..19 | ForEach-Object { "runner:f$_" }) -Because 'a failure older than a pass is never back-filled'
    }

    It 'refuses a record path outside the attempt folders' {
        $escape = Join-Path $script:Dir 'escape'
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Dir 'runner-attempts'), $escape -Force
        [IO.File]::WriteAllText((Join-Path $escape 'runner-fault.json'), '{}')
        $index = [ordered]@{ schemaVersion = 1; olderFailures = @(); attempts = @([ordered]@{
            attemptGeneration = 'runner:42'; startedAtUtc = [DateTime]::UtcNow.AddMinutes(-2).ToString('o'); finishedAtUtc = [DateTime]::UtcNow.ToString('o')
            frameworkCommitSha = ''; passed = $false; skipped = $false; exitCode = 1; failureClass = 'inner_exited'; stage = ''; description = 'x'
            recordPath = 'runner-attempts/../escape/runner-fault.json'; transcriptPath = '' }) }
        [IO.File]::WriteAllText((Join-Path $script:Dir 'runner-attempts/index.json'), ($index | ConvertTo-Json -Depth 6))
        @(Open-FixtureCycle -RuntimeDir $script:Dir -CycleNumber 43 | ForEach-Object { $_.event }) | Should -Be @('cycle_start')
        @(Get-ChildItem -LiteralPath $escape -Force | ForEach-Object { $_.Name }) | Should -Be @('runner-fault.json') -Because 'nothing is written outside the attempt folders'
    }
}

Describe 'The event schema knows the runner''s own fault classes on runner_fault alone' {
    It 'accepts a runner fault class as the failureClass of runner_fault' {
        $record = @{ timestamp = '2026-11-02T10:00:00Z'; event = 'runner_fault'; failureClass = 'cycle_spawn_failed'; severity = 'hard'; eventId = [guid]::NewGuid().ToString() }
        @(Test-CycleEventSchema -Record $record).Count | Should -Be 0
    }

    It 'still flags a runner fault class on any other event' {
        $violations = @(Test-CycleEventSchema -Record @{ timestamp = '2026-11-02T10:00:00Z'; event = 'step_failure'; failureClass = 'cycle_spawn_failed' })
        $violations.Count | Should -Be 1
        $violations[0] | Should -Match 'cycle_spawn_failed'
    }

    It 'still flags a class neither list holds on runner_fault' {
        @(Test-CycleEventSchema -Record @{ timestamp = '2026-11-02T10:00:00Z'; event = 'runner_fault'; failureClass = 'not_a_class' }).Count | Should -Be 1
    }

    It 'types eventId as a string' {
        @(Test-CycleEventSchema -Record @{ timestamp = '2026-11-02T10:00:00Z'; event = 'runner_fault'; eventId = 7 }).Count | Should -Be 1
    }

    It 'mirrors the runner fault classes of Test.RecoveryContract' {
        Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.RecoveryContract.psm1') -Force -DisableNameChecking
        @((Get-CycleEventSchemaDescriptor).RunnerFaultClassEnum | Sort-Object) | Should -Be @(Get-RunnerFaultClassEnum | Sort-Object)
    }
}
