<#PSScriptInfo
.VERSION 2026.11.23
.GUID 42454869-be98-4903-a538-5a115b82367a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test recovery boot host-restart pester
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
    Pins how the boot-recovery sweep in Test.Recovery.psm1 tells a host that
    restarted under a cycle from a runner that was only killed, what it records
    in the aborted cycle, and how its events reach the next cycle's stream.
.DESCRIPTION
    A host that froze at the OS level comes back hours later, and the sweep that
    archives the crashed cycle is the first code to see it. These cases build
    crashed-cycle folders whose file times are set explicitly, fix the boot time
    the sweep reads, and stub the bounded native command layer, so the restart
    decision, the archived payload and the evidence files are checked against
    known inputs on any platform.
#>

BeforeAll {
    $ErrorActionPreference = 'Stop'
    $here = Split-Path -Parent $PSCommandPath
    Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.SingleFlightLock.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.StateFile.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.Log.psm1') -Force -Global -DisableNameChecking
    Import-Module (Join-Path $here 'Test.Recovery.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $here 'Test.EventSchema.psm1') -Force -DisableNameChecking
    $script:Leaf = '000249.2026-11-01.02-10-00.4287d16ff2c346a98ea90fd3a0c307da'
    $script:JsonOption = @{}
    if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $script:JsonOption.DateKind = 'String' }

    function New-RestartFixture {
        <#
        .SYNOPSIS
            A crashed cycle under a fresh log directory, every file last written at
            LastWriteUtc, and an empty runtime directory for the pending queue.
            -Into adds the cycle to an earlier fixture's log directory instead.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds throwaway log and runtime directories the case removes.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([Parameter(Mandatory)][datetime]$LastWriteUtc, [Parameter(Mandatory)][datetime]$StartedAtUtc, [switch]$WithoutMarker,
            [string]$CycleStartUtc = '2026-11-01T02:10:00Z', [string]$Leaf = $script:Leaf, [int]$CycleNumber = 249, [hashtable]$Into)
        if ($Into) {
            $root = $Into.Root; $log = $Into.Log; $runtime = $Into.Runtime
        } else {
            $root = New-YurunaTestTempDir -Prefix 'yrn-host-restart'
            $log = Join-Path $root 'log'
            $runtime = Join-Path $root 'runtime'
        }
        $folder = Join-Path $log ($Leaf + '.incomplete')
        $null = New-Item -ItemType Directory -Path $runtime, (Join-Path $folder 'guest') -Force
        [IO.File]::WriteAllText((Join-Path $folder ($Leaf + '.html')), '<html>')
        # A freeze leaves entries whose data never reached the disk.
        [IO.File]::WriteAllText((Join-Path $folder 'guest/raw_0042.png'), '')
        if (-not $WithoutMarker) {
            $marker = [ordered]@{ cycleStartUtc = $CycleStartUtc; cycleNumber = $CycleNumber; cycleFolder = $Leaf
                startedAtUtc = $StartedAtUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"); pid = 4242; hostname = 'fixture.local' }
            [IO.File]::WriteAllText((Join-Path $folder '.incomplete'), ($marker | ConvertTo-Json -Compress))
        }
        foreach ($file in Get-ChildItem -LiteralPath $folder -File -Recurse -Force) { $file.LastWriteTimeUtc = $LastWriteUtc }
        return @{ Root = $root; Log = $log; Runtime = $runtime; Folder = $folder }
    }

    function New-PreviousRunner {
        <#
        .SYNOPSIS
            The exit report of a runner started by hand in a terminal and ended
            by a signal, as Get-YurunaRunnerExitReport returns it.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: returns an in-memory record; changes nothing.')]
        [CmdletBinding()]
        [OutputType([System.Collections.Specialized.OrderedDictionary])]
        param([Parameter(Mandatory)][datetime]$SignalAtUtc, [string]$Signal = 'SIGHUP')
        return [ordered]@{
            pid = 4321; startedUtc = $SignalAtUtc.AddDays(-2).ToString('o'); recordedUtc = $SignalAtUtc.AddDays(-2).AddSeconds(1).ToString('o')
            sshSession = $false; terminalProgram = 'Apple_Terminal'; multiplexer = $null; parents = @('zsh[2101]')
            hostBootUtc = $SignalAtUtc.AddDays(-9).ToString('o'); signal = $Signal; signalAtUtc = $SignalAtUtc.ToString('o'); hostRestarted = $false
        }
    }

    function Format-Leaf {
        [CmdletBinding()]
        [OutputType([string])]
        param([Parameter(Mandatory)][int]$CycleNumber, [Parameter(Mandatory)][datetime]$StartUtc)
        return ('{0:D6}.{1}.4287d16ff2c346a98ea90fd3a0c307da' -f $CycleNumber, $StartUtc.ToString('yyyy-MM-dd.HH-mm-ss', [Globalization.CultureInfo]::InvariantCulture))
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

    function Read-ArchivedPayload {
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([Parameter(Mandatory)][string]$LogDir)
        $archive = Get-ChildItem -LiteralPath $LogDir -Directory | Get-ChildItem -Force -File -Filter '.aborted.*.json'
        @($archive).Count | Should -Be 1
        $jsonOption = $script:JsonOption
        return ([IO.File]::ReadAllText(@($archive)[0].FullName) | ConvertFrom-Json -AsHashtable @jsonOption)
    }

    function New-NativeResult {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds the in-memory result a stubbed bounded native call returns.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([string]$StdOut = '', [string]$StdErr = '', [int]$ExitCode = 0, [switch]$NotStarted, [switch]$TimedOut, [switch]$Truncated)
        return @{
            Started = -not $NotStarted; ExitCode = $(if ($NotStarted) { -1 } elseif ($TimedOut) { 124 } else { $ExitCode })
            StdOut = $StdOut; StdErr = $StdErr; TimedOut = [bool]$TimedOut; DrainTimedOut = $false
            KillFailed = $false; OutputTruncated = [bool]$Truncated; DeadlineExhausted = $false
        }
    }

    function Set-DeepDiagnosticsDir {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: points the module at a fixture folder instead of the host''s own.')]
        param([string]$Path)
        InModuleScope Test.Recovery -Parameters @{ Path = $Path } { param($Path) $script:DeepDiagnosticsDir = $Path }
    }
}

Describe 'A host restart is told apart from a runner restart' {
    BeforeEach {
        $script:Now = [datetime]::UtcNow
        $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR'
        $script:Deep = New-YurunaTestTempDir -Prefix 'yrn-deep-diag'
        Set-DeepDiagnosticsDir -Path $script:Deep
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand { New-NativeResult -StdOut 'stub output' }
        Mock -ModuleName Test.Recovery Write-Information { }
    }
    AfterEach {
        Set-DeepDiagnosticsDir -Path '/var/log/yuruna/deep-diagnostics'
        Remove-YurunaTestTempDir $script:Deep
        Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
    }

    It 'records a boot after the cycle''s last write as a host restart in the archive' {
        $lastWrite = $script:Now.AddHours(-15)
        $fx = New-RestartFixture -LastWriteUtc $lastWrite -StartedAtUtc $lastWrite.AddMinutes(-40)
        $script:BootUtc = $script:Now.AddMinutes(-5)
        Mock -ModuleName Test.Recovery Get-YurunaHostBootTimeUtc { $script:BootUtc }
        try {
            $marker = @(Find-OrphanIncompleteCycle -LogDir $fx.Log)[0]
            $result = Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -RuntimeDir $fx.Runtime -Confirm:$false
            $result.hostRestarted | Should -BeTrue
            $payload = Read-ArchivedPayload -LogDir $fx.Log
            $payload.hostRestarted | Should -BeTrue
            $payload.lastWriteUtc | Should -Be $lastWrite.ToString('o')
            $payload.bootUtc | Should -Be $script:BootUtc.ToString('o')
            $payload.downSeconds | Should -Be ([long][Math]::Round(($script:BootUtc - $lastWrite).TotalSeconds))
            $payload.cycleStartUtc | Should -Be '2026-11-01T02:10:00Z' -Because 'the marker''s own fields survive beside the new ones'
            $payload.recoverySignal | Should -Be 'marker_file'
            $final = Join-Path $fx.Log $result.cycleFolder
            Test-Path -LiteralPath (Join-Path $final 'host-restart.json') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $final 'host-restart.txt') | Should -BeTrue
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }

    It 'does not count a runner killed and restarted without a reboot' {
        $lastWrite = $script:Now.AddMinutes(-3)
        $fx = New-RestartFixture -LastWriteUtc $lastWrite -StartedAtUtc $lastWrite.AddMinutes(-20)
        $script:BootUtc = $script:Now.AddDays(-3)
        Mock -ModuleName Test.Recovery Get-YurunaHostBootTimeUtc { $script:BootUtc }
        try {
            $marker = @(Find-OrphanIncompleteCycle -LogDir $fx.Log)[0]
            $result = Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -RuntimeDir $fx.Runtime -Confirm:$false
            $result.hostRestarted | Should -BeFalse
            $payload = Read-ArchivedPayload -LogDir $fx.Log
            $payload.hostRestarted | Should -BeFalse
            $payload.downSeconds | Should -BeNullOrEmpty
            $payload.lastWriteUtc | Should -Be $lastWrite.ToString('o')
            $payload.bootUtc | Should -Be $script:BootUtc.ToString('o')
            Test-Path -LiteralPath (Join-Path (Join-Path $fx.Log $result.cycleFolder) 'host-restart.json') | Should -BeFalse
            @(Read-QueuedEvent -RuntimeDir $fx.Runtime | Where-Object { $_.event -eq 'host_restart' }).Count | Should -Be 0
            Should -Invoke -ModuleName Test.Recovery Invoke-BoundedNativeCommand -Times 0 -Exactly -Because 'no evidence is gathered for a plain runner restart'
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }

    It 'takes the marker''s start as the cycle''s last sign of life when its files carry older times' {
        # Copies keep the time of their source, so every file can predate the
        # cycle; a boot between those times and the cycle's start is no restart.
        $fx = New-RestartFixture -LastWriteUtc $script:Now.AddHours(-5) -StartedAtUtc $script:Now.AddHours(-1)
        $script:BootUtc = $script:Now.AddHours(-3)
        Mock -ModuleName Test.Recovery Get-YurunaHostBootTimeUtc { $script:BootUtc }
        try {
            $marker = @(Find-OrphanIncompleteCycle -LogDir $fx.Log)[0]
            (Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -RuntimeDir $fx.Runtime -Confirm:$false).hostRestarted | Should -BeFalse
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }

    It 'counts a boot <Offset> seconds from the last write as <Expected> (whole-second boot clock)' -TestCases @(
        @{ Offset = -2; Expected = $true }
        @{ Offset = -30; Expected = $false }
        @{ Offset = 60; Expected = $true }
    ) {
        param($Offset, $Expected)
        $lastWrite = $script:Now.AddHours(-2)
        $fx = New-RestartFixture -LastWriteUtc $lastWrite -StartedAtUtc $lastWrite.AddMinutes(-30)
        $script:BootUtc = $lastWrite.AddSeconds($Offset)
        Mock -ModuleName Test.Recovery Get-YurunaHostBootTimeUtc { $script:BootUtc }
        try {
            $marker = @(Find-OrphanIncompleteCycle -LogDir $fx.Log)[0]
            (Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -RuntimeDir $fx.Runtime -Confirm:$false).hostRestarted | Should -Be $Expected
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }

    It 'decides nothing without a boot time' {
        $fx = New-RestartFixture -LastWriteUtc $script:Now.AddHours(-2) -StartedAtUtc $script:Now.AddHours(-3)
        Mock -ModuleName Test.Recovery Get-YurunaHostBootTimeUtc { $null }
        try {
            $marker = @(Find-OrphanIncompleteCycle -LogDir $fx.Log)[0]
            $result = Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -RuntimeDir $fx.Runtime -Confirm:$false
            $result.hostRestarted | Should -BeFalse
            (Read-ArchivedPayload -LogDir $fx.Log).bootUtc | Should -Be ''
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }

    It 'assesses a crashed cycle that lost its marker by its files alone' {
        $lastWrite = $script:Now.AddHours(-4)
        $fx = New-RestartFixture -LastWriteUtc $lastWrite -StartedAtUtc $lastWrite -WithoutMarker
        $script:BootUtc = $script:Now.AddMinutes(-1)
        Mock -ModuleName Test.Recovery Get-YurunaHostBootTimeUtc { $script:BootUtc }
        try {
            $marker = @(Find-OrphanIncompleteCycle -LogDir $fx.Log)[0]
            $result = Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -RuntimeDir $fx.Runtime -Confirm:$false
            $result.hostRestarted | Should -BeTrue
            $restart = @(Read-QueuedEvent -RuntimeDir $fx.Runtime | Where-Object { $_.event -eq 'host_restart' })
            $restart.Count | Should -Be 1
            $restart[0].abortedCycleNumber | Should -Be 249 -Because 'the folder name carries the cycle number when no marker does'
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }
}

Describe 'The host_restart event and the boot-recovery event wait for the next cycle' {
    # Only the restart case reaches the boot time and the evidence commands, so
    # only it stubs them: the boot_recovery_completed cases run the sweep as is.
    BeforeEach {
        $script:Now = [datetime]::UtcNow
        $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR'
        $script:Deep = New-YurunaTestTempDir -Prefix 'yrn-deep-diag'
        Set-DeepDiagnosticsDir -Path $script:Deep
        Mock -ModuleName Test.Recovery Write-Information { }
    }
    AfterEach {
        Set-DeepDiagnosticsDir -Path '/var/log/yuruna/deep-diagnostics'
        Remove-YurunaTestTempDir $script:Deep
        Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
    }

    It 'queues host_restart, then boot_recovery_completed, and writes nothing to the log root' {
        $lastWrite = $script:Now.AddHours(-15)
        $fx = New-RestartFixture -LastWriteUtc $lastWrite -StartedAtUtc $lastWrite.AddMinutes(-40)
        $script:BootUtc = $script:Now.AddMinutes(-5)
        Mock -ModuleName Test.Recovery Get-YurunaHostBootTimeUtc { $script:BootUtc }
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand { New-NativeResult -StdOut 'stub output' }
        $env:YURUNA_LOG_DIR = $fx.Log
        try {
            $summary = Invoke-YurunaBootRecovery -RuntimeDir $fx.Runtime -LogDir $fx.Log -Confirm:$false
            $summary.ArchivedCycles.Count | Should -Be 1
            $queued = @(Read-QueuedEvent -RuntimeDir $fx.Runtime)
            @($queued | ForEach-Object { $_.event }) | Should -Be @('host_restart', 'boot_recovery_completed')
            Test-Path -LiteralPath (Join-Path $fx.Log 'cycle.events.ndjson') | Should -BeFalse -Because 'the log-root fallback is a file nothing collects'
            $restart = $queued[0]
            $restart.abortedCycleFolder | Should -Be $summary.ArchivedCycles[0].cycleFolder
            $restart.abortedCycleFolder | Should -Match '\.aborted\.'
            $restart.abortedCycleStartUtc | Should -Be '2026-11-01T02:10:00Z'
            $restart.abortedCycleNumber | Should -Be 249
            $restart.lastWriteUtc | Should -Be $lastWrite.ToString('o')
            $restart.bootUtc | Should -Be $script:BootUtc.ToString('o')
            $restart.downSeconds | Should -Be ([long][Math]::Round(($script:BootUtc - $lastWrite).TotalSeconds))
            @($restart.evidenceFiles) | Should -Be @('host-restart.json', 'host-restart.txt')
            $restart.deepDiagnosticsBundles | Should -Be 0
            $restart.eventId | Should -Not -BeNullOrEmpty
            $restart.ContainsKey('cycleStartUtc') | Should -BeFalse -Because 'the cycle that delivers the event stamps its own identity'
            $restart.ContainsKey('cycleNumber') | Should -BeFalse
            $queued[1].archivedCycleCount | Should -Be 1
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }

    It 'queues the summary of a sweep that archived no cycle, and writes nothing to the log root' {
        $root = New-YurunaTestTempDir -Prefix 'yrn-host-restart-pidfile'
        try {
            $runtime = Join-Path $root 'runtime'
            $log = Join-Path $root 'log'
            $null = New-Item -ItemType Directory -Path $runtime, $log -Force
            Set-Content -LiteralPath (Join-Path $runtime 'inner.pid') -Value 'not-a-pid'
            $env:YURUNA_LOG_DIR = $log
            $summary = Invoke-YurunaBootRecovery -RuntimeDir $runtime -LogDir $log -Confirm:$false
            $summary.ClearedPidFiles.Count | Should -Be 1
            $queued = @(Read-QueuedEvent -RuntimeDir $runtime)
            @($queued | ForEach-Object { $_.event }) | Should -Be @('boot_recovery_completed')
            $queued[0].clearedPidFileCount | Should -Be 1
            Test-Path -LiteralPath (Join-Path $log 'cycle.events.ndjson') | Should -BeFalse -Because 'the log-root fallback is a file nothing collects'
        } finally { Remove-YurunaTestTempDir $root }
    }

    It 'carries what ended the previous runner, read before its runner.pid is cleared' {
        $root = New-YurunaTestTempDir -Prefix 'yrn-host-restart-session'
        try {
            $runtime = Join-Path $root 'runtime'
            $log = Join-Path $root 'log'
            $null = New-Item -ItemType Directory -Path $runtime, $log -Force
            $gone = 999999
            while (Get-Process -Id $gone -ErrorAction SilentlyContinue) { $gone-- }
            Set-Content -LiteralPath (Join-Path $runtime 'runner.pid') -Value "$gone"
            $script:BootUtc = [datetime]::new(2026, 11, 7, 6, 0, 0, [DateTimeKind]::Utc)
            Mock -ModuleName Test.Recovery Get-YurunaHostBootTimeUtc { $script:BootUtc }
            [IO.File]::WriteAllText((Join-Path $runtime 'runner.session.json'), (@{ schemaVersion = 1; pid = $gone
                startedUtc = '2026-11-07T08:00:00.0000000Z'; recordedUtc = '2026-11-07T08:00:01.0000000Z'
                hostBootUtc = $script:BootUtc.ToString('o'); sshSession = $true; terminalProgram = $null; multiplexer = $null
                parents = @('zsh[100]', 'sshd[90]') } | ConvertTo-Json -Compress))
            [IO.File]::WriteAllText((Join-Path $runtime 'runner.exit.json'), "{`"signal`":`"SIGHUP`",`"atUtc`":`"2026-11-07T15:35:02.0000000Z`",`"pid`":$gone}")
            $env:YURUNA_LOG_DIR = $log
            $summary = Invoke-YurunaBootRecovery -RuntimeDir $runtime -LogDir $log -Confirm:$false
            $summary.ClearedPidFiles.Count | Should -Be 1
            $queued = @(Read-QueuedEvent -RuntimeDir $runtime)
            $queued[-1].event | Should -Be 'boot_recovery_completed'
            $previous = $queued[-1].previousRunner
            $previous.pid | Should -Be $gone
            $previous.signal | Should -Be 'SIGHUP'
            $previous.signalAtUtc | Should -Be '2026-11-07T15:35:02.0000000Z'
            $previous.sshSession | Should -BeTrue
            $previous.hostRestarted | Should -BeFalse
            @($previous.parents) | Should -Be @('zsh[100]', 'sshd[90]')
        } finally { Remove-YurunaTestTempDir $root }
    }

    It 'does not report this runner''s own records as a previous runner''s (recorded start <Case>)' -TestCases @(
        @{ Case = 'as this process reads it'; OffsetMs = 0 }
        @{ Case = 'within the start tolerance'; OffsetMs = 1500 }
    ) {
        param($Case, $OffsetMs)
        $null = $Case
        $root = New-YurunaTestTempDir -Prefix 'yrn-host-restart-self'
        try {
            $runtime = Join-Path $root 'runtime'
            $log = Join-Path $root 'log'
            $null = New-Item -ItemType Directory -Path $runtime, $log -Force
            Set-Content -LiteralPath (Join-Path $runtime 'inner.pid') -Value 'not-a-pid'
            # The start time Register-YurunaRunnerExitRecord writes beside the pid.
            $started = (Get-Process -Id $PID).StartTime.ToUniversalTime().AddMilliseconds($OffsetMs).ToString('o')
            [IO.File]::WriteAllText((Join-Path $runtime 'runner.session.json'), (@{ schemaVersion = 1; pid = $PID; startedUtc = $started; parents = @() } | ConvertTo-Json -Compress))
            $env:YURUNA_LOG_DIR = $log
            $summary = Invoke-YurunaBootRecovery -RuntimeDir $runtime -LogDir $log -Confirm:$false
            $summary.PreviousRunner | Should -BeNullOrEmpty
            $queued = @(Read-QueuedEvent -RuntimeDir $runtime)
            $queued[-1].ContainsKey('previousRunner') | Should -BeFalse
            $queued[-1].previousRunnerAbsent | Should -Be 'same-process'
        } finally { Remove-YurunaTestTempDir $root }
    }

    It 'reports a previous runner whose pid this runner was given, and files the cycle its signal ended (recorded start <Case>)' -TestCases @(
        @{ Case = 'two days before this process started'; OffsetMs = -172800000 }
        @{ Case = 'just outside the start tolerance'; OffsetMs = 3000 }
    ) {
        # After a reboot or a pid wrap the OS can give the next runner the pid
        # the previous one had; only the start time tells the records apart.
        param($Case, $OffsetMs)
        $null = $Case
        $lastWrite = $script:Now.AddHours(-1)
        $fx = New-RestartFixture -LastWriteUtc $lastWrite -StartedAtUtc $lastWrite.AddMinutes(-15)
        $script:BootUtc = $script:Now.AddDays(-12)
        Mock -ModuleName Test.Recovery Get-YurunaHostBootTimeUtc { $script:BootUtc }
        Mock -ModuleName Test.Recovery Get-YurunaPlatformName { 'linux' }
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand { New-NativeResult -StdOut 'stub output' }
        try {
            $started = (Get-Process -Id $PID).StartTime.ToUniversalTime().AddMilliseconds($OffsetMs).ToString('o')
            [IO.File]::WriteAllText((Join-Path $fx.Runtime 'runner.session.json'), (@{ schemaVersion = 1; pid = $PID
                startedUtc = $started; recordedUtc = $started; hostBootUtc = $script:BootUtc.ToString('o'); sshSession = $false
                terminalProgram = 'Apple_Terminal'; multiplexer = $null; parents = @('zsh[2101]') } | ConvertTo-Json -Compress))
            [IO.File]::WriteAllText((Join-Path $fx.Runtime 'runner.exit.json'), "{`"signal`":`"SIGHUP`",`"atUtc`":`"$($lastWrite.AddSeconds(13).ToString('o'))`",`"pid`":$PID}")
            $env:YURUNA_LOG_DIR = $fx.Log
            $summary = Invoke-YurunaBootRecovery -RuntimeDir $fx.Runtime -LogDir $fx.Log -Confirm:$false
            $summary.PreviousRunner.pid | Should -Be $PID
            $summary.PreviousRunnerAbsent | Should -BeNullOrEmpty
            $summary.ArchivedCycles[0].endedBy | Should -Be 'signal'
            $queued = @(Read-QueuedEvent -RuntimeDir $fx.Runtime)
            @($queued | ForEach-Object { $_.event }) | Should -Be @('runner_ended_by_signal', 'boot_recovery_completed')
            $queued[0].signal | Should -Be 'SIGHUP'
            $queued[1].previousRunner.signal | Should -Be 'SIGHUP'
            $queued[1].ContainsKey('previousRunnerAbsent') | Should -BeFalse
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }

    It 'says why it carries no previous runner: <Reason>' -TestCases @(
        @{ Reason = 'no-session-record'; Session = $null }
        @{ Reason = 'unreadable'; Session = '{"pid":' }
        @{ Reason = 'unreadable'; Session = '{"schemaVersion":1}' }
    ) {
        param($Reason, $Session)
        $root = New-YurunaTestTempDir -Prefix 'yrn-host-restart-absent'
        try {
            $runtime = Join-Path $root 'runtime'
            $log = Join-Path $root 'log'
            $null = New-Item -ItemType Directory -Path $runtime, $log -Force
            Set-Content -LiteralPath (Join-Path $runtime 'inner.pid') -Value 'not-a-pid'
            if ($null -ne $Session) { [IO.File]::WriteAllText((Join-Path $runtime 'runner.session.json'), $Session) }
            $env:YURUNA_LOG_DIR = $log
            $summary = Invoke-YurunaBootRecovery -RuntimeDir $runtime -LogDir $log -Confirm:$false
            $summary.PreviousRunnerAbsent | Should -Be $Reason
            $queued = @(Read-QueuedEvent -RuntimeDir $runtime)
            $queued.Count | Should -Be 1 -Because 'the reason rides on the event the sweep already sends; it sends no other'
            $queued[0].previousRunnerAbsent | Should -Be $Reason
            $queued[0].ContainsKey('previousRunner') | Should -BeFalse
        } finally { Remove-YurunaTestTempDir $root }
    }

    It 'still sends nothing for a clean sweep that has no previous runner to report' {
        $root = New-YurunaTestTempDir -Prefix 'yrn-host-restart-clean'
        try {
            $runtime = Join-Path $root 'runtime'
            $log = Join-Path $root 'log'
            $null = New-Item -ItemType Directory -Path $runtime, $log -Force
            $env:YURUNA_LOG_DIR = $log
            $summary = Invoke-YurunaBootRecovery -RuntimeDir $runtime -LogDir $log -Confirm:$false
            $summary.PreviousRunnerAbsent | Should -Be 'no-session-record'
            @(Read-QueuedEvent -RuntimeDir $runtime).Count | Should -Be 0
        } finally { Remove-YurunaTestTempDir $root }
    }

    It 'queues the handoff-preservation summary the same way' {
        $root = New-YurunaTestTempDir -Prefix 'yrn-host-restart-handoff'
        try {
            $runtime = Join-Path $root 'runtime'
            $log = Join-Path $root 'log'
            $null = New-Item -ItemType Directory -Path $runtime, $log -Force
            Set-Content -LiteralPath (Join-Path $runtime 'control.pause') -Value 'x'
            $env:YURUNA_LOG_DIR = $log
            $null = Invoke-YurunaBootRecovery -RuntimeDir $runtime -LogDir $log -HandoffPreservation -Confirm:$false
            $queued = @(Read-QueuedEvent -RuntimeDir $runtime)
            $queued.Count | Should -Be 1
            $queued[0].event | Should -Be 'boot_recovery_completed'
            $queued[0].mode | Should -Be 'handoff-preservation'
            Test-Path -LiteralPath (Join-Path $log 'cycle.events.ndjson') | Should -BeFalse -Because 'the log-root fallback is a file nothing collects'
        } finally { Remove-YurunaTestTempDir $root }
    }
}

Describe 'A signal the previous runner recorded ends the cycle it fell in' {
    # A runner started in a terminal dies with the terminal's session, and on a
    # host nothing restarts it, the next runner can start hours later, after an
    # unrelated reboot. These cases fix the boot time and the signal and check
    # what the sweep files the cycle as.
    BeforeEach {
        $script:Now = [datetime]::UtcNow
        $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_RUNTIME_DIR', 'YURUNA_LOG_DIR'
        $script:Deep = New-YurunaTestTempDir -Prefix 'yrn-deep-diag'
        Set-DeepDiagnosticsDir -Path $script:Deep
        $script:Commands = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand {
            $script:Commands.Add(((@($FilePath) + @($ArgumentList)) -join ' '))
            New-NativeResult -StdOut 'stub output'
        }
        Mock -ModuleName Test.Recovery Write-Information { }
        Mock -ModuleName Test.Recovery Get-YurunaHostBootTimeUtc { $script:BootUtc }
        # The sweep saves the evidence for the platform it runs on, and these
        # cases check the Linux commands; each platform's own list is checked
        # under 'Host restart evidence'.
        Mock -ModuleName Test.Recovery Get-YurunaPlatformName { 'linux' }
    }
    AfterEach {
        Set-DeepDiagnosticsDir -Path '/var/log/yuruna/deep-diagnostics'
        Remove-YurunaTestTempDir $script:Deep
        Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
    }

    It 'files a runner a signal ended on a host that has not rebooted since, with evidence and a runner_ended_by_signal event' {
        $lastWrite = $script:Now.AddHours(-17)
        $fx = New-RestartFixture -LastWriteUtc $lastWrite -StartedAtUtc $lastWrite.AddMinutes(-3)
        $script:BootUtc = $script:Now.AddDays(-16)
        $signalAt = $lastWrite.AddSeconds(13)
        $previous = New-PreviousRunner -SignalAtUtc $signalAt
        try {
            $marker = @(Find-OrphanIncompleteCycle -LogDir $fx.Log)[0]
            $result = Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -RuntimeDir $fx.Runtime -PreviousRunner $previous -Confirm:$false
            $result.hostRestarted | Should -BeFalse
            $result.endedBy | Should -Be 'signal'
            $silent = [long][Math]::Round(($script:Now - $signalAt).TotalSeconds)
            $payload = Read-ArchivedPayload -LogDir $fx.Log
            $payload.endedBy | Should -Be 'signal'
            $payload.signal | Should -Be 'SIGHUP'
            $payload.signalAtUtc | Should -Be $previous.signalAtUtc
            [long]$payload.silentSeconds | Should -BeGreaterOrEqual $silent -Because 'the host has run without a runner from the signal until now'
            [long]$payload.silentSeconds | Should -BeLessThan ($silent + 120)
            $payload.downSeconds | Should -BeNullOrEmpty
            $final = Join-Path $fx.Log $result.cycleFolder
            foreach ($name in 'runner-signal.json', 'runner-signal.txt') { Test-Path -LiteralPath (Join-Path $final $name) | Should -BeTrue }
            Test-Path -LiteralPath (Join-Path $final 'host-restart.json') | Should -BeFalse -Because 'the host did not restart'
            $evidence = Get-Content -LiteralPath (Join-Path $final 'runner-signal.json') -Raw | ConvertFrom-Json -AsHashtable @script:JsonOption
            $evidence.endedBy | Should -Be 'signal'
            $evidence.windowCenterUtc | Should -Be ([datetime]::Parse($previous.signalAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().ToString('o'))
            $queued = @(Read-QueuedEvent -RuntimeDir $fx.Runtime)
            @($queued | ForEach-Object { $_.event }) | Should -Be @('runner_ended_by_signal')
            $ended = $queued[0]
            $ended.abortedCycleFolder | Should -Be $result.cycleFolder
            $ended.abortedCycleStartUtc | Should -Be '2026-11-01T02:10:00Z'
            $ended.abortedCycleNumber | Should -Be 249
            $ended.signal | Should -Be 'SIGHUP'
            $ended.signalAtUtc | Should -Be $previous.signalAtUtc
            $ended.silentSeconds | Should -Be $payload.silentSeconds
            $ended.terminalProgram | Should -Be 'Apple_Terminal'
            $ended.sshSession | Should -BeFalse
            @($ended.evidenceFiles) | Should -Be @('runner-signal.json', 'runner-signal.txt')
            $ended.ContainsKey('cycleNumber') | Should -BeFalse -Because 'the cycle that delivers the event stamps its own identity'
            $ended.ContainsKey('endedBy') | Should -BeFalse -Because 'a signal is always this event''s cause; endedBy rides on host_restart and the archive'
            # Without a restart the previous boot is not the one that ran the cycle.
            $script:Commands | Should -Contain 'last -x -F'
            @($script:Commands | Where-Object { $_ -match '^journalctl (-b|-k|--list-boots)' }).Count | Should -Be 0
            $format = "yyyy-MM-dd HH:mm:ss 'UTC'"
            $invariant = [Globalization.CultureInfo]::InvariantCulture
            $script:Commands | Should -Contain ('journalctl --since {0} --until {1} -o short-iso-precise --no-pager -n 2000' -f
                $signalAt.AddSeconds(-180).ToString($format, $invariant), $signalAt.AddSeconds(60).ToString($format, $invariant))
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }

    It 'files a reboot hours after the signal as a host restart the signal ended, silent until the boot' {
        $lastWrite = $script:Now.AddHours(-31)
        $fx = New-RestartFixture -LastWriteUtc $lastWrite -StartedAtUtc $lastWrite.AddMinutes(-3)
        $signalAt = $lastWrite.AddSeconds(13)
        $script:BootUtc = $signalAt.AddHours(17)
        $previous = New-PreviousRunner -SignalAtUtc $signalAt
        try {
            $marker = @(Find-OrphanIncompleteCycle -LogDir $fx.Log)[0]
            $result = Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -RuntimeDir $fx.Runtime -PreviousRunner $previous -Confirm:$false
            $result.hostRestarted | Should -BeTrue
            $result.endedBy | Should -Be 'signal'
            $payload = Read-ArchivedPayload -LogDir $fx.Log
            $payload.endedBy | Should -Be 'signal'
            $payload.silentSeconds | Should -Be 61200
            $payload.downSeconds | Should -Be ([long][Math]::Round(($script:BootUtc - $lastWrite).TotalSeconds)) -Because 'downSeconds keeps measuring from the last write to the boot'
            $queued = @(Read-QueuedEvent -RuntimeDir $fx.Runtime)
            @($queued | ForEach-Object { $_.event }) | Should -Be @('host_restart')
            $restart = $queued[0]
            $restart.endedBy | Should -Be 'signal'
            $restart.signal | Should -Be 'SIGHUP'
            $restart.signalAtUtc | Should -Be $previous.signalAtUtc
            $restart.silentSeconds | Should -Be 61200
            @($restart.evidenceFiles) | Should -Be @('host-restart.json', 'host-restart.txt')
            # The restart's own evidence, and the journal around the signal 17 hours before it.
            $script:Commands | Should -Contain 'journalctl -b -1 -n 300 -o short-iso-precise --no-pager'
            @($script:Commands | Where-Object { $_ -like 'journalctl --since *' }).Count | Should -Be 1
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }

    It 'keeps a signal sent just before the boot as a host restart, with the signal on record' {
        $lastWrite = $script:Now.AddHours(-2)
        $fx = New-RestartFixture -LastWriteUtc $lastWrite -StartedAtUtc $lastWrite.AddMinutes(-20)
        $signalAt = $lastWrite.AddSeconds(30)
        $script:BootUtc = $signalAt.AddSeconds(60)
        $previous = New-PreviousRunner -SignalAtUtc $signalAt -Signal 'SIGTERM'
        try {
            $marker = @(Find-OrphanIncompleteCycle -LogDir $fx.Log)[0]
            $result = Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -RuntimeDir $fx.Runtime -PreviousRunner $previous -Confirm:$false
            $result.endedBy | Should -Be 'host-restart'
            $payload = Read-ArchivedPayload -LogDir $fx.Log
            $payload.endedBy | Should -Be 'host-restart'
            $payload.signal | Should -Be 'SIGTERM'
            $payload.signalAtUtc | Should -Be $previous.signalAtUtc
            $payload.ContainsKey('silentSeconds') | Should -BeFalse -Because 'the shutdown sent the signal; the host was not left up'
            $restart = @(Read-QueuedEvent -RuntimeDir $fx.Runtime)[0]
            $restart.event | Should -Be 'host_restart'
            $restart.endedBy | Should -Be 'host-restart'
            $restart.signal | Should -Be 'SIGTERM'
            $restart.ContainsKey('silentSeconds') | Should -BeFalse
            @($script:Commands | Where-Object { $_ -like 'journalctl --since *' }).Count | Should -Be 0 -Because 'the previous boot''s tail already ends at the signal'
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }

    It 'changes nothing when the previous runner recorded no signal (<Case>)' -TestCases @(
        @{ Case = 'host restarted'; Restarted = $true }
        @{ Case = 'host did not restart'; Restarted = $false }
    ) {
        param($Case, $Restarted)
        $null = $Case
        $lastWrite = $script:Now.AddHours(-3)
        $fx = New-RestartFixture -LastWriteUtc $lastWrite -StartedAtUtc $lastWrite.AddMinutes(-20)
        $script:BootUtc = if ($Restarted) { $script:Now.AddMinutes(-5) } else { $script:Now.AddDays(-4) }
        $previous = New-PreviousRunner -SignalAtUtc $lastWrite.AddSeconds(5)
        $previous.signal = $null
        $previous.signalAtUtc = $null
        try {
            $marker = @(Find-OrphanIncompleteCycle -LogDir $fx.Log)[0]
            $result = Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -RuntimeDir $fx.Runtime -PreviousRunner $previous -Confirm:$false
            $result.endedBy | Should -BeNullOrEmpty
            $payload = Read-ArchivedPayload -LogDir $fx.Log
            foreach ($key in 'endedBy', 'signal', 'signalAtUtc', 'silentSeconds') { $payload.ContainsKey($key) | Should -BeFalse }
            $queued = @(Read-QueuedEvent -RuntimeDir $fx.Runtime)
            if ($Restarted) {
                @($queued | ForEach-Object { $_.event }) | Should -Be @('host_restart')
                foreach ($key in 'endedBy', 'signal', 'signalAtUtc', 'silentSeconds') { $queued[0].ContainsKey($key) | Should -BeFalse }
                @($queued[0].evidenceFiles) | Should -Be @('host-restart.json', 'host-restart.txt')
            } else {
                $queued.Count | Should -Be 0
                Should -Invoke -ModuleName Test.Recovery Invoke-BoundedNativeCommand -Times 0 -Exactly -Because 'no evidence is gathered for a plain runner restart'
            }
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }

    It 'does not take a signal from outside the cycle: <Case>' -TestCases @(
        @{ Case = 'before it started'; SignalOffsetSeconds = -3600 }
        @{ Case = 'more than ten minutes after its last write'; SignalOffsetSeconds = 1800 }
    ) {
        param($Case, $SignalOffsetSeconds)
        $null = $Case
        $lastWrite = $script:Now.AddHours(-5)
        $start = $lastWrite.AddMinutes(-10)
        $fx = New-RestartFixture -LastWriteUtc $lastWrite -StartedAtUtc $start -CycleStartUtc $start.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $script:BootUtc = $script:Now.AddDays(-4)
        $anchor = if ($SignalOffsetSeconds -lt 0) { $start } else { $lastWrite }
        $previous = New-PreviousRunner -SignalAtUtc $anchor.AddSeconds($SignalOffsetSeconds)
        try {
            $marker = @(Find-OrphanIncompleteCycle -LogDir $fx.Log)[0]
            $result = Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -RuntimeDir $fx.Runtime -PreviousRunner $previous -Confirm:$false
            $result.endedBy | Should -BeNullOrEmpty
            (Read-ArchivedPayload -LogDir $fx.Log).ContainsKey('endedBy') | Should -BeFalse
            @(Read-QueuedEvent -RuntimeDir $fx.Runtime).Count | Should -Be 0
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }

    It 'gives the signal and the progress sidecars to the newest cycle they fall in, once' {
        # Two orphans: an older cycle the watchdog ended, and the next one, whose
        # runner a SIGHUP ended minutes later. The signal and the sidecars fall in
        # both cycles' windows; only the newer one ran when they were written.
        $olderStart = $script:Now.AddHours(-6)
        $olderWrite = $olderStart.AddMinutes(20)
        $newerStart = $olderWrite.AddSeconds(60)
        $newerWrite = $newerStart.AddSeconds(120)
        $signalAt = $newerWrite.AddSeconds(13)
        $script:BootUtc = $script:Now.AddDays(-12)
        $fx = New-RestartFixture -LastWriteUtc $olderWrite -StartedAtUtc $olderStart -CycleNumber 248 `
            -Leaf (Format-Leaf -CycleNumber 248 -StartUtc $olderStart) -CycleStartUtc $olderStart.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $null = New-RestartFixture -LastWriteUtc $newerWrite -StartedAtUtc $newerStart -CycleNumber 249 -Into $fx `
            -Leaf (Format-Leaf -CycleNumber 249 -StartUtc $newerStart) -CycleStartUtc $newerStart.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        try {
            $gone = 999999
            while (Get-Process -Id $gone -ErrorAction SilentlyContinue) { $gone-- }
            Set-Content -LiteralPath (Join-Path $fx.Runtime 'runner.pid') -Value "$gone"
            [IO.File]::WriteAllText((Join-Path $fx.Runtime 'runner.session.json'), (@{ schemaVersion = 1; pid = $gone
                startedUtc = $olderStart.AddDays(-1).ToString('o'); recordedUtc = $olderStart.AddDays(-1).ToString('o')
                hostBootUtc = $script:BootUtc.ToString('o'); sshSession = $false; terminalProgram = 'Apple_Terminal'; multiplexer = $null
                parents = @('zsh[2101]') } | ConvertTo-Json -Compress))
            [IO.File]::WriteAllText((Join-Path $fx.Runtime 'runner.exit.json'), "{`"signal`":`"SIGHUP`",`"atUtc`":`"$($signalAt.ToString('o'))`",`"pid`":$gone}")
            $sidecars = [ordered]@{
                'current-action.json'  = @('{"guestKey":"guest.ubuntu.server.26","vmName":"test-vm-01","line":"[2/21] startVm","code":"","label":"[2/21]","arguments":{},"updatedAt":"x"}', $newerStart.AddSeconds(40))
                'runner.stepHeartbeat' = @($signalAt.AddSeconds(-2).ToString('o'), $signalAt.AddSeconds(-2))
                'runner.heartbeat'     = @($signalAt.AddSeconds(-5).ToString('o'), $signalAt.AddSeconds(-5))
            }
            foreach ($name in $sidecars.Keys) {
                $path = Join-Path $fx.Runtime $name
                [IO.File]::WriteAllText($path, $sidecars[$name][0])
                (Get-Item -LiteralPath $path).LastWriteTimeUtc = $sidecars[$name][1]
            }
            $env:YURUNA_LOG_DIR = $fx.Log
            $summary = Invoke-YurunaBootRecovery -RuntimeDir $fx.Runtime -LogDir $fx.Log -Confirm:$false
            $summary.ArchivedCycles.Count | Should -Be 2
            $newer = @($summary.ArchivedCycles | Where-Object { $_.cycleFolder -like '000249.*' })[0]
            $older = @($summary.ArchivedCycles | Where-Object { $_.cycleFolder -like '000248.*' })[0]
            $newer.endedBy | Should -Be 'signal'
            $older.endedBy | Should -BeNullOrEmpty
            $newer.runnerStateSaved | Should -BeTrue
            $older.runnerStateSaved | Should -BeFalse
            $newerFolder = Join-Path $fx.Log $newer.cycleFolder
            $olderFolder = Join-Path $fx.Log $older.cycleFolder
            Test-Path -LiteralPath (Join-Path $olderFolder 'runner-state-at-loss.json') | Should -BeFalse
            $state = Get-Content -LiteralPath (Join-Path $newerFolder 'runner-state-at-loss.json') -Raw | ConvertFrom-Json -AsHashtable @script:JsonOption
            $state.files['current-action.json'].content.line | Should -Be '[2/21] startVm'
            $state.files['current-action.json'].lastWriteUtc | Should -Be $newerStart.AddSeconds(40).ToString('o')
            $state.files['runner.stepHeartbeat'].content | Should -Be $signalAt.AddSeconds(-2).ToString('o')
            $state.files['runner.heartbeat'].lastWriteUtc | Should -Be $signalAt.AddSeconds(-5).ToString('o')
            $state.files.Contains('runner.phase') | Should -BeFalse -Because 'only the sidecars present are copied'
            $queued = @(Read-QueuedEvent -RuntimeDir $fx.Runtime)
            @($queued | ForEach-Object { $_.event }) | Should -Be @('runner_ended_by_signal', 'boot_recovery_completed')
            $queued[0].abortedCycleFolder | Should -Be $newer.cycleFolder
            @($queued[0].evidenceFiles) | Should -Be @('runner-signal.json', 'runner-signal.txt', 'runner-state-at-loss.json')
            $queued[1].previousRunner.signal | Should -Be 'SIGHUP'
            $queued[1].ContainsKey('previousRunnerAbsent') | Should -BeFalse
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }

    It 'leaves out progress sidecars written before the cycle started' {
        $lastWrite = $script:Now.AddHours(-1)
        $start = $lastWrite.AddMinutes(-15)
        $fx = New-RestartFixture -LastWriteUtc $lastWrite -StartedAtUtc $start -CycleStartUtc $start.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
        $script:BootUtc = $script:Now.AddDays(-2)
        try {
            $heartbeat = Join-Path $fx.Runtime 'runner.stepHeartbeat'
            [IO.File]::WriteAllText($heartbeat, 'x')
            (Get-Item -LiteralPath $heartbeat).LastWriteTimeUtc = $start.AddHours(-3)
            $env:YURUNA_LOG_DIR = $fx.Log
            $summary = Invoke-YurunaBootRecovery -RuntimeDir $fx.Runtime -LogDir $fx.Log -Confirm:$false
            $summary.ArchivedCycles[0].runnerStateSaved | Should -BeFalse
            Test-Path -LiteralPath (Join-Path (Join-Path $fx.Log $summary.ArchivedCycles[0].cycleFolder) 'runner-state-at-loss.json') | Should -BeFalse
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }

    It 'queues events the event schema accepts, and types their new fields' {
        $lastWrite = $script:Now.AddHours(-31)
        $fx = New-RestartFixture -LastWriteUtc $lastWrite -StartedAtUtc $lastWrite.AddMinutes(-3)
        $signalAt = $lastWrite.AddSeconds(13)
        $script:BootUtc = $signalAt.AddHours(17)
        try {
            $marker = @(Find-OrphanIncompleteCycle -LogDir $fx.Log)[0]
            $null = Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -RuntimeDir $fx.Runtime -PreviousRunner (New-PreviousRunner -SignalAtUtc $signalAt) -Confirm:$false
            $script:BootUtc = $script:Now.AddDays(-30)
            $second = New-RestartFixture -LastWriteUtc $script:Now.AddHours(-2) -StartedAtUtc $script:Now.AddHours(-3) -Into $fx `
                -Leaf (Format-Leaf -CycleNumber 250 -StartUtc $script:Now.AddHours(-3)) -CycleNumber 250
            $marker = @(Find-OrphanIncompleteCycle -LogDir $fx.Log)[0]
            $null = Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -RuntimeDir $fx.Runtime -PreviousRunner (New-PreviousRunner -SignalAtUtc $script:Now.AddHours(-2).AddSeconds(4)) -Confirm:$false
            $queued = @(Read-QueuedEvent -RuntimeDir $second.Runtime)
            @($queued | ForEach-Object { $_.event }) | Should -Be @('host_restart', 'runner_ended_by_signal')
            foreach ($queuedEvent in $queued) {
                @(Test-CycleEventSchema -Record ([hashtable]$queuedEvent)) | Should -BeNullOrEmpty -Because "$($queuedEvent.event) must pass the validator"
            }
            $typed = (Get-CycleEventSchemaDescriptor).TypedField
            foreach ($field in 'endedBy', 'signal', 'signalAtUtc', 'terminalProgram', 'osBuildBefore', 'osBuildAfter', 'previousRunnerAbsent') { $typed[$field] | Should -Be 'string' }
            $typed['silentSeconds'] | Should -Be 'int'
            $typed['sshSession'] | Should -Be 'bool'
            $violations = @(Test-CycleEventSchema -Record @{ timestamp = 't'; event = 'runner_ended_by_signal'; silentSeconds = '61200' })
            $violations.Count | Should -Be 1
            $violations[0] | Should -Match 'silentSeconds'
        } finally { Remove-YurunaTestTempDir $fx.Root }
    }
}

Describe 'Host restart evidence' {
    BeforeEach {
        $script:Now = [datetime]::UtcNow
        $script:Folder = New-YurunaTestTempDir -Prefix 'yrn-restart-evidence'
        $script:Deep = New-YurunaTestTempDir -Prefix 'yrn-deep-diag'
        $script:LastWrite = $script:Now.AddHours(-10)
        $script:Restart = [ordered]@{ lastWriteUtc = $script:LastWrite.ToString('o'); bootUtc = $script:Now.AddMinutes(-5).ToString('o'); hostRestarted = $true; downSeconds = 35700 }
    }
    AfterEach {
        foreach ($dir in $script:Folder, $script:Deep) {
            if (-not $IsWindows -and (Test-Path -LiteralPath $dir)) { [IO.File]::SetUnixFileMode($dir, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
            Remove-YurunaTestTempDir $dir
        }
    }

    It 'saves the journal, the hardware-error lines and the reboot history on Linux, with whether the system journal was readable' {
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand {
            switch -Regex ($ArgumentList -join ' ') {
                '^--list-boots' { return New-NativeResult -StdOut "IDX BOOT ID FIRST ENTRY LAST ENTRY`n -1 aaaa Sat 2026-11-01 02:00:00 UTC Sat 2026-11-01 02:55:03 UTC`n  0 bbbb Sat 2026-11-01 18:00:00 UTC Sat 2026-11-01 18:05:00 UTC" }
                '^-b -1 -n 300' { return New-NativeResult -StdOut "2026-11-01T02:55:02.123456+00:00 host kernel: kvm: last line before the freeze" }
                '^-k -b -1 -p warning' { return New-NativeResult -StdOut '2026-11-01T02:54:59.000000+00:00 host kernel: watchdog: BUG: soft lockup - CPU#3 stuck for 22s!' }
                '^-k -b 0' {
                    return New-NativeResult -StdOut ("2026-11-01T18:00:01+00:00 host kernel: Linux version 6.12`n" +
                        "2026-11-01T18:00:02+00:00 host kernel: BERT: Error records from previous boot:`n" +
                        "2026-11-01T18:00:02+00:00 host kernel: mce: [Hardware Error]: Machine check events logged`n" +
                        "2026-11-01T18:00:03+00:00 host kernel: usb 1-1: new device")
                }
                '^-x -F' { return New-NativeResult -StdOut ((1..60 | ForEach-Object { "reboot   system boot  6.12 line $_" }) -join "`n") }
            }
            return New-NativeResult -NotStarted
        }
        $evidence = InModuleScope Test.Recovery -Parameters @{ Folder = $script:Folder; Restart = $script:Restart; Deep = $script:Deep } {
            param($Folder, $Restart, $Deep)
            Save-HostRestartEvidence -CycleFolder $Folder -Restart $Restart -Platform linux -DeepDiagnosticsDir $Deep
        }
        @($evidence.evidenceFiles) | Should -Be @('host-restart.json', 'host-restart.txt')
        $json = Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.json') -Raw | ConvertFrom-Json -AsHashtable @script:JsonOption
        $json.platform | Should -Be 'linux'
        $json.systemJournalReadable | Should -BeTrue
        @($json.commands).Count | Should -Be 5
        $json.commands[1].command | Should -Be 'journalctl -b -1 -n 300 -o short-iso-precise --no-pager'
        @($json.hardwareErrorLines).Count | Should -Be 2
        $json.hardwareErrorLines[0] | Should -Match 'BERT: Error records'
        $json.hardwareErrorLines[1] | Should -Match 'mce: \[Hardware Error\]'
        $json.deepDiagnostics.reason | Should -Be 'none written since the last write'
        $text = Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.txt') -Raw
        $text | Should -Match 'kvm: last line before the freeze'
        $text | Should -Match 'soft lockup'
        $text | Should -Not -Match 'usb 1-1: new device' -Because 'only the current boot''s hardware-error lines are kept'
        $text | Should -Match 'line 40'
        $text | Should -Not -Match 'line 41' -Because 'last -x is kept to its head'
    }

    It 'records an unreadable system journal and a command that could not run, without failing' {
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand {
            if ($FilePath -eq 'last') { return New-NativeResult -NotStarted }
            if (($ArgumentList -join ' ') -match '^-b -1') { return New-NativeResult -TimedOut }
            return New-NativeResult -StdErr 'Hint: You are currently not seeing messages from other users and the system. Users in groups ''adm'', ''systemd-journal'' can see all messages.'
        }
        $null = InModuleScope Test.Recovery -Parameters @{ Folder = $script:Folder; Restart = $script:Restart; Deep = $script:Deep } {
            param($Folder, $Restart, $Deep)
            Save-HostRestartEvidence -CycleFolder $Folder -Restart $Restart -Platform linux -DeepDiagnosticsDir $Deep
        }
        $json = Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.json') -Raw | ConvertFrom-Json -AsHashtable @script:JsonOption
        $json.systemJournalReadable | Should -BeFalse
        $tail = @($json.commands | Where-Object { $_.command -like 'journalctl -b -1 *' })[0]
        $tail.complete | Should -BeFalse
        $tail.exitCode | Should -Be 124
        $last = @($json.commands | Where-Object { $_.command -like 'last *' })[0]
        $last.started | Should -BeFalse
    }

    It 'copies the deep diagnostics bundles written since the last write, and only those' {
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand { New-NativeResult }
        $old = Join-Path $script:Deep 'boot-20261031T120000Z-11111111.txt'
        $new = Join-Path $script:Deep 'boot-20261101T180005Z-22222222.txt'
        [IO.File]::WriteAllText($old, 'old boot')
        [IO.File]::WriteAllText($new, "pstore: kernel panic - not syncing")
        (Get-Item -LiteralPath $old).LastWriteTimeUtc = $script:LastWrite.AddDays(-1)
        (Get-Item -LiteralPath $new).LastWriteTimeUtc = $script:Now.AddMinutes(-4)
        $evidence = InModuleScope Test.Recovery -Parameters @{ Folder = $script:Folder; Restart = $script:Restart; Deep = $script:Deep } {
            param($Folder, $Restart, $Deep)
            Save-HostRestartEvidence -CycleFolder $Folder -Restart $Restart -Platform linux -DeepDiagnosticsDir $Deep
        }
        $evidence.deepDiagnosticsBundles | Should -Be 1
        @($evidence.evidenceFiles) | Should -Contain 'host-restart.deep-diagnostics.boot-20261101T180005Z-22222222.txt'
        Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.deep-diagnostics.boot-20261101T180005Z-22222222.txt') -Raw | Should -Match 'kernel panic'
        Test-Path -LiteralPath (Join-Path $script:Folder 'host-restart.deep-diagnostics.boot-20261031T120000Z-11111111.txt') | Should -BeFalse
        $json = Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.json') -Raw | ConvertFrom-Json -AsHashtable @script:JsonOption
        @($json.deepDiagnostics.copied) | Should -Be @('host-restart.deep-diagnostics.boot-20261101T180005Z-22222222.txt')
    }

    It 'records why the deep diagnostics bundles could not be read' -Skip:$IsWindows {
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand { New-NativeResult }
        [IO.File]::WriteAllText((Join-Path $script:Deep 'boot-20261101T180005Z-22222222.txt'), 'bundle')
        [IO.File]::SetUnixFileMode($script:Deep, [IO.UnixFileMode]'None')
        try {
            $probe = $null
            try { $probe = [IO.Directory]::GetFiles($script:Deep) } catch { $probe = $null }
            if ($null -ne $probe) {
                Set-ItResult -Skipped -Because 'this account reads a directory with no permissions (superuser)'
                return
            }
            $evidence = InModuleScope Test.Recovery -Parameters @{ Folder = $script:Folder; Restart = $script:Restart; Deep = $script:Deep } {
                param($Folder, $Restart, $Deep)
                Save-HostRestartEvidence -CycleFolder $Folder -Restart $Restart -Platform linux -DeepDiagnosticsDir $Deep
            }
            $evidence.deepDiagnosticsBundles | Should -Be 0
            $json = Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.json') -Raw | ConvertFrom-Json -AsHashtable @script:JsonOption
            $json.deepDiagnostics.reason | Should -Match '^unreadable: '
        } finally { [IO.File]::SetUnixFileMode($script:Deep, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
    }

    It 'says the deep diagnostics folder is absent on a host not in that mode' {
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand { New-NativeResult }
        $absent = Join-Path $script:Deep 'not-there'
        $null = InModuleScope Test.Recovery -Parameters @{ Folder = $script:Folder; Restart = $script:Restart; Deep = $absent } {
            param($Folder, $Restart, $Deep)
            Save-HostRestartEvidence -CycleFolder $Folder -Restart $Restart -Platform linux -DeepDiagnosticsDir $Deep
        }
        $json = Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.json') -Raw | ConvertFrom-Json -AsHashtable @script:JsonOption
        $json.deepDiagnostics.reason | Should -Be 'absent'
    }

    It 'queries the System log source by source from half an hour before the last write to ten minutes after the boot, and keeps the build on each side of the restart on Windows' {
        $script:Queries = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand {
            $script:Queries.Add(@(@($FilePath) + @($ArgumentList)))
            New-NativeResult -StdOut "Event[0]:`n  Log Name: System`n  Source: Microsoft-Windows-Kernel-Power`n  Event ID: 41"
        }
        Mock -ModuleName Test.Recovery Get-ItemProperty { [pscustomobject]@{ CurrentBuild = '26300'; UBR = 9974; DisplayVersion = '26H2' } }
        # The cycle-start host diagnostic's sidecar, as Get-SystemDiagnostic writes it on Windows.
        [IO.File]::WriteAllText((Join-Path $script:Folder 'host.diagnostic.txt.json'), '{"schema":"yuruna.diagnostic.problems/v1","count":0,"byClass":{},"problems":[],"windowsOs":{"build":"26300.9711","displayVersion":"26H2","restartPending":true,"restartPendingSources":["WindowsUpdate\\Auto Update\\RebootRequired"]}}')
        $dumps = Join-Path $script:Deep 'Minidump'
        $null = New-Item -ItemType Directory -Path $dumps -Force
        foreach ($name in 'old.dmp', 'new.dmp') { [IO.File]::WriteAllText((Join-Path $dumps $name), 'MDMP') }
        (Get-Item -LiteralPath (Join-Path $dumps 'old.dmp')).LastWriteTimeUtc = $script:LastWrite.AddHours(-1)
        (Get-Item -LiteralPath (Join-Path $dumps 'new.dmp')).LastWriteTimeUtc = $script:Now.AddMinutes(-3)
        $evidence = InModuleScope Test.Recovery -Parameters @{ Folder = $script:Folder; Restart = $script:Restart; Dumps = $dumps } {
            param($Folder, $Restart, $Dumps)
            Save-HostRestartEvidence -CycleFolder $Folder -Restart $Restart -Platform windows -CrashReportDir $Dumps
        }
        $since = $script:LastWrite.AddMinutes(-30).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        # Bounded at the boot: each query keeps only its newest 50 records, which
        # the update records of the hours up to the sweep would otherwise fill.
        $boot = [datetime]::Parse($script:Restart.bootUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        $until = $boot.AddMinutes(10).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        $window = "TimeCreated[@SystemTime>='$since' and @SystemTime<='$until']"
        $expected = @(
            "/q:*[System[Provider[@Name='User32'] and (EventID=1074 or EventID=1076) and $window]]"
            "/q:*[System[Provider[@Name='EventLog'] and (EventID=6005 or EventID=6006 or EventID=6008) and $window]]"
            "/q:*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=41 or EventID=109) and $window]]"
            "/q:*[System[Provider[@Name='Microsoft-Windows-Kernel-General'] and (EventID=12 or EventID=13) and $window]]"
            "/q:*[System[Provider[@Name='Microsoft-Windows-WER-SystemErrorReporting'] and (EventID=1001) and $window]]"
            "/q:*[System[Provider[@Name='Microsoft-Windows-WindowsUpdateClient'] and (EventID=19 or EventID=20 or EventID=43 or EventID=44) and $window]]"
        )
        $script:Queries.Count | Should -Be $expected.Count
        for ($i = 0; $i -lt $expected.Count; $i++) {
            $script:Queries[$i] | Should -Be @('wevtutil', 'qe', 'System', $expected[$i], '/f:text', '/rd:true', '/c:50')
        }
        $evidence.osBuildBefore | Should -Be '26300.9711'
        $evidence.osBuildAfter | Should -Be '26300.9974'
        $json = Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.json') -Raw | ConvertFrom-Json -AsHashtable @script:JsonOption
        @($json.crashReports | ForEach-Object { Split-Path -Leaf $_.path }) | Should -Be @('new.dmp')
        $json.osBuildBefore | Should -Be '26300.9711'
        $json.osBuildAfter | Should -Be '26300.9974'
        $json.osDisplayVersion | Should -Be '26H2'
        @($json.commands).Count | Should -Be 6
        $json.ContainsKey('deepDiagnostics') | Should -BeFalse
        $text = Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.txt') -Raw
        $text | Should -Match 'Kernel-Power'
        $text | Should -Match 'osBuildBefore: 26300\.9711'
        $text | Should -Match 'osBuildAfter: 26300\.9974 26H2'
    }

    It 'takes the build before a Windows restart from the host samples when the cycle kept no host diagnostic sidecar' {
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand { New-NativeResult }
        Mock -ModuleName Test.Recovery Get-ItemProperty { throw 'the registry is not readable here' }
        $samples = Join-Path $script:Folder 'guest/host-samples-20261110T195600Z'
        $null = New-Item -ItemType Directory -Path $samples -Force
        [IO.File]::WriteAllText((Join-Path $samples 'metadata.json'), '{"Kind":"metadata","WindowsRevision":{"CurrentBuild":"26300","UBR":9711,"DisplayVersion":"26H2"}}')
        $evidence = InModuleScope Test.Recovery -Parameters @{ Folder = $script:Folder; Restart = $script:Restart; Deep = $script:Deep } {
            param($Folder, $Restart, $Deep)
            Save-HostRestartEvidence -CycleFolder $Folder -Restart $Restart -Platform windows -CrashReportDir (Join-Path $Deep 'none')
        }
        $evidence.osBuildBefore | Should -Be '26300.9711'
        $evidence.osBuildAfter | Should -Be '' -Because 'an unreadable registry leaves the build after unknown, and the evidence is still written'
        @($evidence.evidenceFiles) | Should -Be @('host-restart.json', 'host-restart.txt')
    }

    It 'bounds the System log queries on Windows from half an hour before the signal to ten minutes after <Until>' -TestCases @(
        @{ Until = 'the signal, on a host that has not rebooted since'; RebootAfterHours = 0 }
        @{ Until = 'the boot that came hours after it'; RebootAfterHours = 17 }
    ) {
        param($Until, $RebootAfterHours)
        $null = $Until
        $script:Queries = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand {
            $script:Queries.Add(@(@($FilePath) + @($ArgumentList)))
            New-NativeResult
        }
        Mock -ModuleName Test.Recovery Get-ItemProperty { [pscustomobject]@{ CurrentBuild = '26300'; UBR = 9974; DisplayVersion = '26H2' } }
        $lastWrite = $script:Now.AddHours(-31)
        $signalAt = $lastWrite.AddSeconds(13)
        $restarted = $RebootAfterHours -gt 0
        $bootAt = if ($restarted) { $signalAt.AddHours($RebootAfterHours) } else { $script:Now.AddDays(-9) }
        $silentUntil = if ($restarted) { $bootAt } else { $script:Now }
        $restart = [ordered]@{ lastWriteUtc = $lastWrite.ToString('o'); bootUtc = $bootAt.ToString('o'); hostRestarted = $restarted
            downSeconds = if ($restarted) { [long][Math]::Round(($bootAt - $lastWrite).TotalSeconds) } else { $null } }
        $end = [ordered]@{ endedBy = 'signal'; signal = 'SIGHUP'; signalAtUtc = $signalAt.ToString('o'); silentSeconds = [long][Math]::Round(($silentUntil - $signalAt).TotalSeconds) }
        $evidence = InModuleScope Test.Recovery -Parameters @{ Folder = $script:Folder; Restart = $restart; End = $end; Deep = $script:Deep } {
            param($Folder, $Restart, $End, $Deep)
            Save-HostRestartEvidence -CycleFolder $Folder -Restart $Restart -RunnerEnd $End -Platform windows -CrashReportDir (Join-Path $Deep 'none')
        }
        $since = $signalAt.AddMinutes(-30).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        $untilAt = if ($restarted) { $bootAt } else { $signalAt }
        $untilText = $untilAt.AddMinutes(10).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        $script:Queries.Count | Should -Be 6
        foreach ($query in $script:Queries) {
            $query[3] | Should -Match ([regex]::Escape(" and TimeCreated[@SystemTime>='$since' and @SystemTime<='$untilText']]]") + '$') -Because 'the window ends ten minutes after the boot, or after the signal without one'
            @($query | Select-Object -Last 3) | Should -Be @('/f:text', '/rd:true', '/c:50')
        }
        $baseName = if ($restarted) { 'host-restart' } else { 'runner-signal' }
        @($evidence.evidenceFiles) | Should -Be @("$baseName.json", "$baseName.txt")
    }

    It 'keeps the newer panic reports and the reboot history on macOS' {
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand { New-NativeResult -StdOut "reboot    time                                Sat Nov  1 18:00`nwtmp begins" }
        $reports = Join-Path $script:Deep 'DiagnosticReports'
        $null = New-Item -ItemType Directory -Path $reports -Force
        $files = @{
            'panic-full-2026-11-01-180000.0002.ips' = $script:Now.AddMinutes(-3)
            'Kernel-2026-11-01-175900.panic'        = $script:Now.AddMinutes(-4)
            'Safari-2026-11-01-170000.ips'          = $script:Now.AddMinutes(-5)
            'panic-full-2026-10-30-100000.0001.ips' = $script:LastWrite.AddDays(-1)
        }
        foreach ($name in $files.Keys) {
            [IO.File]::WriteAllText((Join-Path $reports $name), "{""panicString"":""$name""}")
            (Get-Item -LiteralPath (Join-Path $reports $name)).LastWriteTimeUtc = $files[$name]
        }
        $null = InModuleScope Test.Recovery -Parameters @{ Folder = $script:Folder; Restart = $script:Restart; Reports = $reports } {
            param($Folder, $Restart, $Reports)
            Save-HostRestartEvidence -CycleFolder $Folder -Restart $Restart -Platform macos -CrashReportDir $Reports
        }
        $json = Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.json') -Raw | ConvertFrom-Json -AsHashtable @script:JsonOption
        @($json.crashReports | ForEach-Object { Split-Path -Leaf $_.path }) | Should -Be @('panic-full-2026-11-01-180000.0002.ips', 'Kernel-2026-11-01-175900.panic')
        $json.commands[0].command | Should -Be 'last reboot'
        # Centered on the newest write, as no signal is known.
        $format = "yyyy-MM-dd HH:mm:ss'+0000'"
        $invariant = [Globalization.CultureInfo]::InvariantCulture
        $predicate = 'process == "loginwindow" OR process == "WindowServer" OR process == "Terminal" OR process == "UTM" OR process BEGINSWITH[c] "qemu" OR process == "softwareupdated" OR process == "appleeventsd" OR process == "launchservicesd" OR process == "tccd"'
        @($json.commands | ForEach-Object { $_.command }) | Should -Be @(
            'last reboot', 'last -30'
            ('log show --style compact --start {0} --end {1} --predicate {2}' -f $script:LastWrite.AddSeconds(-180).ToString($format, $invariant), $script:LastWrite.AddSeconds(60).ToString($format, $invariant), $predicate)
            'softwareupdate --history')
        @($json.appReports).Count | Should -Be 0 -Because 'no session app report was written within ten minutes of the last write'
        $text = Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.txt') -Raw
        $text | Should -Match 'panicString'
        $text | Should -Not -Match 'Safari'
    }

    It 'keeps the session app reports of both report folders written within ten minutes of the signal on macOS' {
        $script:Commands = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand {
            $script:Commands.Add(((@($FilePath) + @($ArgumentList)) -join ' '))
            New-NativeResult -StdOut 'stub output'
        }
        $signalAt = $script:LastWrite.AddSeconds(13)
        $end = [ordered]@{ endedBy = 'signal'; signal = 'SIGHUP'; signalAtUtc = $signalAt.ToString('o'); silentSeconds = 61200 }
        $restart = [ordered]@{ lastWriteUtc = $script:LastWrite.ToString('o'); bootUtc = $script:Now.AddDays(-9).ToString('o'); hostRestarted = $false; downSeconds = $null }
        $user = Join-Path $script:Deep 'user/DiagnosticReports'
        $system = Join-Path $script:Deep 'system/DiagnosticReports'
        $null = New-Item -ItemType Directory -Path $user, $system -Force
        $files = @(
            @{ Dir = $user; Name = 'Terminal-2026-01-15-101850.ips'; At = $signalAt.AddSeconds(4); Body = ('T' * 20000) }
            @{ Dir = $user; Name = 'UTM-2026-01-15-101851.ips'; At = $signalAt.AddSeconds(5); Body = 'utm report' }
            @{ Dir = $user; Name = 'qemu-system-aarch64-2026-01-15-101900.ips'; At = $signalAt.AddSeconds(14); Body = 'qemu report' }
            @{ Dir = $user; Name = 'Safari-2026-01-15-101850.ips'; At = $signalAt.AddSeconds(4); Body = 'not a session app' }
            @{ Dir = $user; Name = 'WindowServer-2026-01-15-103500.ips'; At = $signalAt.AddMinutes(16); Body = 'too late' }
            @{ Dir = $system; Name = 'JetsamEvent-2026-01-15-101700.ips'; At = $signalAt.AddSeconds(-106); Body = 'jetsam report' }
            @{ Dir = $system; Name = 'loginwindow-2026-01-15-100900.ips'; At = $signalAt.AddSeconds(-590); Body = 'loginwindow report' }
            @{ Dir = $system; Name = 'QEMULauncher-2026-01-15-101855.ips'; At = $signalAt.AddSeconds(9); Body = 'launcher report' }
            @{ Dir = $system; Name = 'panic-full-2026-01-15-101846.ips'; At = $signalAt; Body = 'a panic without a restart is not this one' }
        )
        foreach ($file in $files) {
            $path = Join-Path $file.Dir $file.Name
            [IO.File]::WriteAllText($path, $file.Body)
            (Get-Item -LiteralPath $path).LastWriteTimeUtc = $file.At
        }
        $evidence = InModuleScope Test.Recovery -Parameters @{ Folder = $script:Folder; Restart = $restart; End = $end; Dirs = @($user, $system) } {
            param($Folder, $Restart, $End, $Dirs)
            Save-HostRestartEvidence -CycleFolder $Folder -Restart $Restart -RunnerEnd $End -Platform macos -CrashReportDir $Dirs
        }
        @($evidence.evidenceFiles) | Should -Be @('runner-signal.json', 'runner-signal.txt')
        $json = Get-Content -LiteralPath (Join-Path $script:Folder 'runner-signal.json') -Raw | ConvertFrom-Json -AsHashtable @script:JsonOption
        @($json.appReports | ForEach-Object { Split-Path -Leaf $_.path }) | Should -Be @(
            'qemu-system-aarch64-2026-01-15-101900.ips', 'QEMULauncher-2026-01-15-101855.ips', 'UTM-2026-01-15-101851.ips',
            'Terminal-2026-01-15-101850.ips', 'JetsamEvent-2026-01-15-101700.ips', 'loginwindow-2026-01-15-100900.ips')
        @($json.crashReports).Count | Should -Be 0 -Because 'panic reports belong to a restart'
        $json.endedBy | Should -Be 'signal'
        $format = "yyyy-MM-dd HH:mm:ss'+0000'"
        $invariant = [Globalization.CultureInfo]::InvariantCulture
        @($script:Commands | Where-Object { $_ -like 'last *' }) | Should -Be @('last -30') -Because 'without a restart there is no reboot to list'
        @($script:Commands | Where-Object { $_ -like 'log show *' }).Count | Should -Be 1
        @($script:Commands | Where-Object { $_ -like 'log show *' })[0] | Should -BeLike ('log show --style compact --start {0} --end {1} --predicate *' -f
            $signalAt.AddSeconds(-180).ToString($format, $invariant), $signalAt.AddSeconds(60).ToString($format, $invariant))
        @($script:Commands | Where-Object { $_ -like 'log show *' })[0] | Should -Match 'process BEGINSWITH\[c\] "qemu"' -Because 'UTM runs its VMs as QEMULauncher under QEMUHelper; a case-sensitive "qemu" prefix matches neither'
        $text = Get-Content -LiteralPath (Join-Path $script:Folder 'runner-signal.txt') -Raw
        $text | Should -Match 'jetsam report'
        $text | Should -Match ('T' * 16384)
        $text | Should -Not -Match ('T' * 16385) -Because 'each report is kept to its first 16 KiB'
        $text | Should -Not -Match 'not a session app'
        $text | Should -Not -Match 'too late'
    }

    It 'keeps at most the ten newest session app reports on macOS' {
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand { New-NativeResult }
        $reports = Join-Path $script:Deep 'DiagnosticReports'
        $null = New-Item -ItemType Directory -Path $reports -Force
        foreach ($n in 1..12) {
            $path = Join-Path $reports ('UTM-2026-01-15-10{0:D4}.ips' -f $n)
            [IO.File]::WriteAllText($path, "report $n")
            (Get-Item -LiteralPath $path).LastWriteTimeUtc = $script:LastWrite.AddSeconds($n * 10)
        }
        $null = InModuleScope Test.Recovery -Parameters @{ Folder = $script:Folder; Restart = $script:Restart; Reports = $reports } {
            param($Folder, $Restart, $Reports)
            Save-HostRestartEvidence -CycleFolder $Folder -Restart $Restart -Platform macos -CrashReportDir $Reports
        }
        $json = Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.json') -Raw | ConvertFrom-Json -AsHashtable @script:JsonOption
        @($json.appReports | ForEach-Object { Split-Path -Leaf $_.path }) | Should -Be @(12..3 | ForEach-Object { 'UTM-2026-01-15-10{0:D4}.ips' -f $_ })
    }

    It 'reads the minute around the window center again when the unified log filled its capture on macOS' {
        $script:LogStarts = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand {
            if ($FilePath -ne 'log') { return New-NativeResult -StdOut 'stub output' }
            $script:LogStarts.Add($ArgumentList[4])
            if ($script:LogStarts.Count -eq 1) { return New-NativeResult -StdOut 'early lines only' -Truncated }
            return New-NativeResult -StdOut 'the lines nearest the signal'
        }
        $null = InModuleScope Test.Recovery -Parameters @{ Folder = $script:Folder; Restart = $script:Restart } {
            param($Folder, $Restart)
            Save-HostRestartEvidence -CycleFolder $Folder -Restart $Restart -Platform macos -CrashReportDir (Join-Path $Folder 'none')
        }
        $format = "yyyy-MM-dd HH:mm:ss'+0000'"
        $invariant = [Globalization.CultureInfo]::InvariantCulture
        @($script:LogStarts) | Should -Be @($script:LastWrite.AddSeconds(-180).ToString($format, $invariant), $script:LastWrite.AddSeconds(-30).ToString($format, $invariant))
        $json = Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.json') -Raw | ConvertFrom-Json -AsHashtable @script:JsonOption
        $logs = @($json.commands | Where-Object { $_.command -like 'log show *' })
        $logs.Count | Should -Be 2
        $logs[0].truncated | Should -BeTrue
        $logs[1].truncated | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.txt') -Raw | Should -Match 'the lines nearest the signal'
    }
}

Describe 'The host boot time' {
    It 'reads the Linux boot time from the kernel, in the past' -Skip:(-not $IsLinux) {
        $boot = InModuleScope Test.Recovery { Get-YurunaHostBootTimeUtc -Platform linux }
        $boot | Should -BeOfType [datetime]
        $boot.Kind | Should -Be ([DateTimeKind]::Utc)
        $boot | Should -BeLessThan ([datetime]::UtcNow)
    }

    It 'parses the macOS kern.boottime answer' {
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand { New-NativeResult -StdOut '{ sec = 1700000000, usec = 123456 } Tue Nov 14 22:13:20 2023' }
        $boot = InModuleScope Test.Recovery { Get-YurunaHostBootTimeUtc -Platform macos }
        $boot | Should -Be ([datetime]::new(2023, 11, 14, 22, 13, 20, [DateTimeKind]::Utc))
    }

    It 'answers $null when macOS gives no answer' {
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand { New-NativeResult -TimedOut }
        InModuleScope Test.Recovery { Get-YurunaHostBootTimeUtc -Platform macos } | Should -BeNullOrEmpty
    }

    It 'derives the Windows boot time from the time since boot' {
        $boot = InModuleScope Test.Recovery { Get-YurunaHostBootTimeUtc -Platform windows }
        $expected = [datetime]::UtcNow.AddMilliseconds(-[double][Environment]::TickCount64)
        [Math]::Abs(($boot - $expected).TotalSeconds) | Should -BeLessThan 5
    }
}
