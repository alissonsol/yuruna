<#PSScriptInfo
.VERSION 2026.11.05
.GUID 428e1743-73e0-45a5-8145-fdbc9c985582
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test telemetry pending events pester
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
    Pins the pending cycle-event queue in Test.Log.psm1: an event raised while no
    cycle is open waits in the runtime directory and reaches the next cycle's
    stream with its own timestamp, bounded, in order and never lost to a failed
    write or a second writer.
.DESCRIPTION
    The outer runner's boot recovery and its runner faults happen between
    cycles, where an ordinary emit falls back to a log-root file nothing
    collects. These cases drive Add-PendingCycleEvent and Send-PendingCycleEvent
    against real temp directories, open a real cycle through Start-LogFile to
    pin where the queued events land, and run two writer processes at once
    against one queue.
#>

BeforeAll {
    $ErrorActionPreference = 'Stop'
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $here)
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    # Imported before Test.Log so its lazy load resolves this same instance, whose
    # held-lock list a case below shares with the queue writer.
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.EventSchema.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.Log.psm1') -Force -DisableNameChecking
    $script:HadLogProxy = [bool](Get-Module Yuruna.Log)
    if (-not $script:HadLogProxy) {
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Log.psm1') -Global -DisableNameChecking
    }
    $script:JsonOption = @{}
    if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $script:JsonOption.DateKind = 'String' }
    # Pester 6 fails a call no -ParameterFilter matches instead of passing it
    # through, so a filtered mock gets an unfiltered one that calls the original.
    $script:RealWriter = & (Get-Module Test.Log) { Get-Command Write-CycleNdjsonEvent }

    function Read-QueueFile {
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([Parameter(Mandatory)][string]$RuntimeDir)
        $jsonOption = $script:JsonOption
        return ([IO.File]::ReadAllText((Join-Path $RuntimeDir 'cycle-events.pending.json')) | ConvertFrom-Json -AsHashtable @jsonOption)
    }

    function Read-StreamEvent {
        [CmdletBinding()]
        [OutputType([object[]])]
        param([Parameter(Mandatory)][string]$Folder)
        $path = Join-Path $Folder 'cycle.events.ndjson'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
        $jsonOption = $script:JsonOption
        return @(Get-Content -LiteralPath $path | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable @jsonOption })
    }

    function Get-OpenedCycleFolder {
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][string]$TestRoot)
        $opened = @(Get-ChildItem -LiteralPath (Join-Path $TestRoot 'status/log') -Directory -Filter '*.incomplete')
        $opened.Count | Should -Be 1 -Because 'Start-LogFile opens exactly one cycle folder'
        return $opened[0].FullName
    }

    function Set-QueueBound {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: sets the module-scope bounds a case narrows and restores.')]
        param([int]$Count, [long]$Bytes)
        InModuleScope Test.Log -Parameters @{ Count = $Count; Bytes = $Bytes } {
            param($Count, $Bytes)
            $script:PendingCycleEventMaxCount = $Count
            $script:PendingCycleEventMaxBytes = $Bytes
        }
    }

    function Reset-DeliveryLedger {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: reseeds the module-scope ledger a new cycle would start empty.')]
        param()
        InModuleScope Test.Log {
            $script:CycleEventDelivery = [ordered]@{ attempted = 0; delivered = 0; dropped = 0; lastDroppedEvent = ''; lastDropReason = ''; lastDropAtUtc = '' }
            $script:CycleEventDropWarned = $false
        }
    }
}

AfterAll {
    if (-not $script:HadLogProxy) { Remove-Module -Name Yuruna.Log -Force -ErrorAction SilentlyContinue }
}

Describe 'The pending cycle-event queue' {
    BeforeEach {
        $script:Root = New-YurunaTestTempDir -Prefix 'yrn-pending'
        $script:Runtime = Join-Path $script:Root 'runtime'
        $script:Cycle = Join-Path $script:Root '000042.2026-11-02.12-00-00.fixturehost.incomplete'
        $null = New-Item -ItemType Directory -Path $script:Runtime, $script:Cycle -Force
        $script:SavedGlobals = Save-YurunaTestGlobal -Name '__YurunaCycleFolder', '__YurunaLogFile', '__YurunaCycleIdentity', '__YurunaCycleStartUtc'
        $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR'
        Remove-Item Env:YURUNA_LOG_DIR -ErrorAction SilentlyContinue
        $env:YURUNA_RUNTIME_DIR = $script:Runtime
        Set-YurunaTestGlobal -Value @{
            __YurunaCycleFolder = $script:Cycle
            __YurunaCycleIdentity = '000042.2026-11-02.12-00-00.fixturehost'
            __YurunaCycleStartUtc = '2026-11-02T12:00:00Z'
        }
        Mock -ModuleName Test.Log Write-Warning { }
        Reset-DeliveryLedger
        Set-QueueBound -Count 200 -Bytes 524288
    }
    AfterEach {
        Set-QueueBound -Count 200 -Bytes 524288
        Restore-YurunaTestGlobal -Saved $script:SavedGlobals
        Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
        Remove-YurunaTestTempDir $script:Root
    }

    It 'queues an event with its own timestamp and an eventId, leaving the caller''s record as it was' {
        $record = @{ timestamp = '2026-11-01T08:00:00Z'; event = 'boot_recovery_completed'; archivedCycleCount = 1 }
        Add-PendingCycleEvent -EventRecord $record -RuntimeDir $script:Runtime | Should -BeTrue
        $queue = Read-QueueFile -RuntimeDir $script:Runtime
        @($queue.events).Count | Should -Be 1
        $queue.events[0].timestamp | Should -Be '2026-11-01T08:00:00Z'
        $queue.events[0].eventId | Should -Match '^[0-9a-f-]{36}$'
        $record.ContainsKey('eventId') | Should -BeFalse -Because 'the caller''s hashtable is not changed'
        $queue.droppedCount | Should -Be 0
    }

    It 'stamps a queued event that has no timestamp with the time it was queued' {
        $before = [datetime]::UtcNow.AddSeconds(-1)
        Add-PendingCycleEvent -EventRecord @{ event = 'host_restart' } -RuntimeDir $script:Runtime | Should -BeTrue
        $stamp = [datetime]::Parse((Read-QueueFile -RuntimeDir $script:Runtime).events[0].timestamp, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal)
        $stamp | Should -BeGreaterOrEqual $before.AddSeconds(-1)
    }

    It 'refuses to queue without a runtime directory' {
        Add-PendingCycleEvent -EventRecord @{ event = 'x'; timestamp = '2026-11-01T08:00:00Z' } -RuntimeDir (Join-Path $script:Root 'absent') | Should -BeFalse
        Add-PendingCycleEvent -EventRecord @{ event = 'x'; timestamp = '2026-11-01T08:00:00Z' } -RuntimeDir '' | Should -BeFalse
    }

    It 'drops the oldest events past the count bound and counts what it dropped' {
        Set-QueueBound -Count 3 -Bytes 524288
        foreach ($n in 1..5) {
            Add-PendingCycleEvent -EventRecord @{ timestamp = "2026-11-01T08:00:0${n}Z"; event = "e$n" } -RuntimeDir $script:Runtime | Should -BeTrue
        }
        $queue = Read-QueueFile -RuntimeDir $script:Runtime
        @($queue.events | ForEach-Object { $_.event }) | Should -Be @('e3', 'e4', 'e5')
        $queue.droppedCount | Should -Be 2
        $queue.lastDroppedEvent | Should -Be 'e2'
        $queue.lastDroppedTimestamp | Should -Be '2026-11-01T08:00:02Z'
    }

    It 'drops the oldest events past the size bound' {
        $padding = 'x' * 300
        $one = [Text.Encoding]::UTF8.GetByteCount((@{ timestamp = '2026-11-01T08:00:01Z'; event = 'e1'; detail = $padding; eventId = [guid]::NewGuid().ToString() } | ConvertTo-Json -Compress))
        Set-QueueBound -Count 200 -Bytes ([long]($one * 2 + 10))
        foreach ($n in 1..4) {
            Add-PendingCycleEvent -EventRecord @{ timestamp = "2026-11-01T08:00:0${n}Z"; event = "e$n"; detail = $padding } -RuntimeDir $script:Runtime | Should -BeTrue
        }
        $queue = Read-QueueFile -RuntimeDir $script:Runtime
        @($queue.events | ForEach-Object { $_.event }) | Should -Be @('e3', 'e4')
        $queue.droppedCount | Should -Be 2
    }

    It 'reports an event larger than the whole size bound as not queued, and counts it as dropped' {
        Set-QueueBound -Count 200 -Bytes 100
        Add-PendingCycleEvent -EventRecord @{ timestamp = '2026-11-01T08:00:00Z'; event = 'huge'; detail = ('x' * 500) } -RuntimeDir $script:Runtime | Should -BeFalse
        $queue = Read-QueueFile -RuntimeDir $script:Runtime
        @($queue.events).Count | Should -Be 0
        $queue.droppedCount | Should -Be 1
        $queue.lastDroppedEvent | Should -Be 'huge'
        $queue.lastDroppedTimestamp | Should -Be '2026-11-01T08:00:00Z' -Because 'with nothing else queued, the loss is dated by the event dropped'
    }

    It 'keeps the events already queued when an event larger than the whole size bound is dropped' {
        Set-QueueBound -Count 200 -Bytes 1000
        foreach ($n in 1..3) {
            Add-PendingCycleEvent -EventRecord @{ timestamp = "2026-11-01T0${n}:00:00Z"; event = "e$n" } -RuntimeDir $script:Runtime | Should -BeTrue
        }
        Add-PendingCycleEvent -EventRecord @{ timestamp = '2026-11-01T07:00:00Z'; event = 'huge'; detail = ('x' * 2000) } -RuntimeDir $script:Runtime | Should -BeFalse
        $queue = Read-QueueFile -RuntimeDir $script:Runtime
        @($queue.events | ForEach-Object { $_.event }) | Should -Be @('e1', 'e2', 'e3')
        $queue.droppedCount | Should -Be 1
        $queue.lastDroppedEvent | Should -Be 'huge'
        $null = Send-PendingCycleEvent -RuntimeDir $script:Runtime
        $stream = @(Read-StreamEvent -Folder $script:Cycle)
        @($stream | ForEach-Object { $_.event }) | Should -Be @('pending_cycle_events_dropped', 'e1', 'e2', 'e3')
        $stream[0].timestamp | Should -Be '2026-11-01T01:00:00Z' -Because 'the loss report goes ahead of the events that survived it, so it is not dated after them'
    }

    It 'replaces a queue file holding <Name> rather than refusing every later event' -TestCases @(
        @{ Name = 'text that does not parse'; Content = '{partial' }
        @{ Name = 'nothing'; Content = '' }
        @{ Name = 'null'; Content = 'null' }
        @{ Name = 'an array'; Content = '[]' }
    ) {
        param($Content)
        [IO.File]::WriteAllText((Join-Path $script:Runtime 'cycle-events.pending.json'), $Content)
        Add-PendingCycleEvent -EventRecord @{ timestamp = '2026-11-01T08:00:00Z'; event = 'e1' } -RuntimeDir $script:Runtime | Should -BeTrue
        Add-PendingCycleEvent -EventRecord @{ timestamp = '2026-11-01T09:00:00Z'; event = 'e2' } -RuntimeDir $script:Runtime | Should -BeTrue
        @((Read-QueueFile -RuntimeDir $script:Runtime).events | ForEach-Object { $_.event }) | Should -Be @('e1', 'e2')
    }

    It 'refuses rather than races when another holder keeps the queue lock' {
        $lock = Enter-YurunaSingleFlightLock -Path (Join-Path $script:Runtime 'cycle-events.pending.json.lock')
        try {
            $lock.Held | Should -BeTrue
            Add-PendingCycleEvent -EventRecord @{ timestamp = '2026-11-01T08:00:00Z'; event = 'e1' } -RuntimeDir $script:Runtime | Should -BeFalse
        } finally { Exit-YurunaSingleFlightLock -Lock $lock }
        Test-Path -LiteralPath (Join-Path $script:Runtime 'cycle-events.pending.json') | Should -BeFalse
    }

    It 'writes the queue into the open stream oldest first, each event with its own timestamp, then empties it' {
        foreach ($n in 1..3) {
            Add-PendingCycleEvent -EventRecord @{ timestamp = "2026-11-01T0${n}:00:00Z"; event = "e$n" } -RuntimeDir $script:Runtime | Should -BeTrue
        }
        $queuedIds = @((Read-QueueFile -RuntimeDir $script:Runtime).events | ForEach-Object { $_.eventId })
        $sent = Send-PendingCycleEvent -RuntimeDir $script:Runtime
        $sent.Delivered | Should -Be 3
        $sent.Remaining | Should -Be 0
        $stream = @(Read-StreamEvent -Folder $script:Cycle)
        @($stream | ForEach-Object { $_.event }) | Should -Be @('e1', 'e2', 'e3')
        @($stream | ForEach-Object { $_.timestamp }) | Should -Be @('2026-11-01T01:00:00Z', '2026-11-01T02:00:00Z', '2026-11-01T03:00:00Z')
        @($stream | ForEach-Object { $_.eventId }) | Should -Be $queuedIds
        foreach ($line in $stream) {
            $line.cycleFolder | Should -Be '000042.2026-11-02.12-00-00.fixturehost' -Because 'a delivered event joins the cycle that carries it'
            $line.cycleStartUtc | Should -Be '2026-11-02T12:00:00Z'
        }
        Test-Path -LiteralPath (Join-Path $script:Runtime 'cycle-events.pending.json') | Should -BeFalse
    }

    It 'reports a loss ahead of the events that survived it, dated by the newest event dropped' {
        Set-QueueBound -Count 2 -Bytes 524288
        foreach ($n in 1..4) {
            Add-PendingCycleEvent -EventRecord @{ timestamp = "2026-11-01T0${n}:00:00Z"; event = "e$n" } -RuntimeDir $script:Runtime | Should -BeTrue
        }
        $sent = Send-PendingCycleEvent -RuntimeDir $script:Runtime
        $sent.Dropped | Should -Be 2
        $stream = @(Read-StreamEvent -Folder $script:Cycle)
        @($stream | ForEach-Object { $_.event }) | Should -Be @('pending_cycle_events_dropped', 'e3', 'e4')
        $stream[0].droppedCount | Should -Be 2
        $stream[0].lastDroppedEvent | Should -Be 'e2'
        $stream[0].timestamp | Should -Be '2026-11-01T02:00:00Z'
        Test-Path -LiteralPath (Join-Path $script:Runtime 'cycle-events.pending.json') | Should -BeFalse
    }

    It 'loses nothing when the stream cannot be written, and delivers it all to a later cycle' {
        foreach ($n in 1..2) {
            Add-PendingCycleEvent -EventRecord @{ timestamp = "2026-11-01T0${n}:00:00Z"; event = "e$n" } -RuntimeDir $script:Runtime | Should -BeTrue
        }
        $before = [IO.File]::ReadAllText((Join-Path $script:Runtime 'cycle-events.pending.json'))
        # A directory where the stream file belongs makes every append fail.
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Cycle 'cycle.events.ndjson') -Force
        $sent = Send-PendingCycleEvent -RuntimeDir $script:Runtime
        $sent.Delivered | Should -Be 0
        [IO.File]::ReadAllText((Join-Path $script:Runtime 'cycle-events.pending.json')) | Should -BeExactly $before

        $next = Join-Path $script:Root '000043.2026-11-02.13-00-00.fixturehost.incomplete'
        $null = New-Item -ItemType Directory -Path $next -Force
        Set-YurunaTestGlobal -Value @{ __YurunaCycleFolder = $next; __YurunaCycleIdentity = '000043.2026-11-02.13-00-00.fixturehost'; __YurunaCycleStartUtc = '2026-11-02T13:00:00Z' }
        Reset-DeliveryLedger
        (Send-PendingCycleEvent -RuntimeDir $script:Runtime).Delivered | Should -Be 2
        $stream = @(Read-StreamEvent -Folder $next)
        @($stream | ForEach-Object { $_.event }) | Should -Be @('e1', 'e2')
        @($stream | ForEach-Object { $_.cycleFolder } | Select-Object -Unique) | Should -Be @('000043.2026-11-02.13-00-00.fixturehost') -Because 'an event left queued is stamped by the cycle that finally carries it'
    }

    It 'keeps the failed event and every later one queued, in order, when a write fails part way' {
        foreach ($name in 'first', 'second', 'third') {
            Add-PendingCycleEvent -EventRecord @{ timestamp = '2026-11-01T08:00:00Z'; event = $name } -RuntimeDir $script:Runtime | Should -BeTrue
        }
        Mock -ModuleName Test.Log Write-CycleNdjsonEvent -MockWith { & $script:RealWriter @PesterBoundParameters }
        Mock -ModuleName Test.Log Write-CycleNdjsonEvent -ParameterFilter { $EventRecord['event'] -eq 'second' } -MockWith { throw 'disk full' }
        $sent = Send-PendingCycleEvent -RuntimeDir $script:Runtime
        $sent.Delivered | Should -Be 1
        $sent.Remaining | Should -Be 2
        @(Read-StreamEvent -Folder $script:Cycle | ForEach-Object { $_.event }) | Should -Be @('first')
        @((Read-QueueFile -RuntimeDir $script:Runtime).events | ForEach-Object { $_.event }) | Should -Be @('second', 'third')
    }

    It 'leaves the queue alone while no cycle is open' {
        Add-PendingCycleEvent -EventRecord @{ timestamp = '2026-11-01T08:00:00Z'; event = 'e1' } -RuntimeDir $script:Runtime | Should -BeTrue
        Set-YurunaTestGlobal -Value @{ __YurunaCycleFolder = $null }
        (Send-PendingCycleEvent -RuntimeDir $script:Runtime).Delivered | Should -Be 0
        @((Read-QueueFile -RuntimeDir $script:Runtime).events).Count | Should -Be 1
    }
}

Describe 'A cycle opened by Start-LogFile carries the queued events' {
    BeforeEach {
        $script:Root = New-YurunaTestTempDir -Prefix 'yrn-pending-start'
        $script:Runtime = Join-Path $script:Root 'runtime'
        $null = New-Item -ItemType Directory -Path $script:Runtime -Force
        $script:SavedGlobals = Save-YurunaTestGlobal -Name '__YurunaCycleFolder', '__YurunaLogFile', '__YurunaCycleIdentity', '__YurunaCycleStartUtc'
        $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR'
        Remove-Item Env:YURUNA_LOG_DIR -ErrorAction SilentlyContinue
        $env:YURUNA_RUNTIME_DIR = $script:Runtime
        Set-YurunaTestGlobal -Value @{ __YurunaCycleFolder = $null; __YurunaLogFile = $null; __YurunaCycleIdentity = $null; __YurunaCycleStartUtc = $null }
    }
    AfterEach {
        Restore-YurunaTestGlobal -Saved $script:SavedGlobals
        Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
        Remove-YurunaTestTempDir $script:Root
    }

    It 'writes them ahead of cycle_start, older than it and joined to the new cycle' {
        # A fault from before a failure pause longer than an hour: ahead of
        # cycle_start, the host's event stream receives the lines in time order.
        Add-PendingCycleEvent -EventRecord @{ timestamp = '2026-11-02T09:00:00Z'; event = 'runner_fault'; failureClass = 'inner_exited'; severity = 'hard' } | Should -BeTrue
        Add-PendingCycleEvent -EventRecord @{ timestamp = '2026-11-02T09:30:00Z'; event = 'boot_recovery_completed'; archivedCycleCount = 1 } | Should -BeTrue
        $null = Start-LogFile -TestRoot $script:Root -CycleStartUtc '2026-11-02T11:00:00Z' -Hostname 'fixture-host' -CycleNumber 9 -Confirm:$false
        $stream = @(Read-StreamEvent -Folder (Get-OpenedCycleFolder -TestRoot $script:Root))
        @($stream | ForEach-Object { $_.event }) | Should -Be @('runner_fault', 'boot_recovery_completed', 'cycle_start')
        $stream[0].timestamp | Should -Be '2026-11-02T09:00:00Z'
        $stream[0].cycleStartUtc | Should -Be '2026-11-02T11:00:00Z'
        $stream[0].cycleFolder | Should -Be $stream[2].cycleFolder
        Test-Path -LiteralPath (Join-Path $script:Runtime 'cycle-events.pending.json') | Should -BeFalse
    }

    It 'opens with cycle_start when nothing is queued' {
        $null = Start-LogFile -TestRoot $script:Root -CycleStartUtc '2026-11-02T11:00:00Z' -Hostname 'fixture-host' -CycleNumber 9 -Confirm:$false
        @(Read-StreamEvent -Folder (Get-OpenedCycleFolder -TestRoot $script:Root))[0].event | Should -Be 'cycle_start'
    }
}

Describe 'Two writers at once' {
    It 'keeps every event two processes queue concurrently' {
        $root = New-YurunaTestTempDir -Prefix 'yrn-pending-race'
        try {
            $writer = Join-Path $root 'writer.ps1'
            [IO.File]::WriteAllText($writer, @'
param([string]$Module, [string]$RuntimeDir, [string]$Name, [int]$Count)
$ErrorActionPreference = 'Stop'
Import-Module $Module -DisableNameChecking
$failed = 0
foreach ($n in 1..$Count) {
    if (-not (Add-PendingCycleEvent -EventRecord @{ timestamp = '2026-11-01T08:00:00Z'; event = "$Name-$n" } -RuntimeDir $RuntimeDir)) { $failed++ }
}
exit $failed
'@)
            $module = Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Log.psm1'
            $processes = foreach ($name in 'a', 'b') {
                Start-Process -FilePath ([Environment]::ProcessPath) -PassThru -NoNewWindow `
                    -RedirectStandardOutput (Join-Path $root "$name.out") -RedirectStandardError (Join-Path $root "$name.err") -ArgumentList @(
                    '-NoProfile', '-NonInteractive', '-File', $writer, '-Module', $module, '-RuntimeDir', $root, '-Name', $name, '-Count', '25')
            }
            foreach ($process in $processes) {
                $process.WaitForExit(120000) | Should -BeTrue
                $errors = Get-ChildItem -LiteralPath $root -Filter '*.err' | Get-Content -Raw
                $process.ExitCode | Should -Be 0 -Because "every add got the lock in time ($errors)"
            }
            $jsonOption = $script:JsonOption
            $queue = [IO.File]::ReadAllText((Join-Path $root 'cycle-events.pending.json')) | ConvertFrom-Json -AsHashtable @jsonOption
            @($queue.events).Count | Should -Be 50 -Because 'neither writer replaced the queue with a copy missing the other''s events'
            @($queue.events | ForEach-Object { $_.eventId } | Select-Object -Unique).Count | Should -Be 50
            foreach ($name in 'a', 'b') {
                @($queue.events | Where-Object { $_.event -like "$name-*" } | ForEach-Object { [int]($_.event -replace '^.-', '') }) |
                    Should -Be (1..25) -Because 'each writer''s events stay in the order it queued them'
            }
        } finally { Remove-YurunaTestTempDir $root }
    }
}
