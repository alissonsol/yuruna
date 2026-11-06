<#PSScriptInfo
.VERSION 2026.11.05
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
    $script:Leaf = '000249.2026-11-01.02-10-00.4287d16ff2c346a98ea90fd3a0c307da'
    $script:JsonOption = @{}
    if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $script:JsonOption.DateKind = 'String' }

    function New-RestartFixture {
        <#
        .SYNOPSIS
            A crashed cycle under a fresh log directory, every file last written at
            LastWriteUtc, and an empty runtime directory for the pending queue.
        #>
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: builds throwaway log and runtime directories the case removes.')]
        [CmdletBinding()]
        [OutputType([hashtable])]
        param([Parameter(Mandatory)][datetime]$LastWriteUtc, [Parameter(Mandatory)][datetime]$StartedAtUtc, [switch]$WithoutMarker)
        $root = New-YurunaTestTempDir -Prefix 'yrn-host-restart'
        $log = Join-Path $root 'log'
        $runtime = Join-Path $root 'runtime'
        $folder = Join-Path $log ($script:Leaf + '.incomplete')
        $null = New-Item -ItemType Directory -Path $runtime, (Join-Path $folder 'guest') -Force
        [IO.File]::WriteAllText((Join-Path $folder ($script:Leaf + '.html')), '<html>')
        # A freeze leaves entries whose data never reached the disk.
        [IO.File]::WriteAllText((Join-Path $folder 'guest/raw_0042.png'), '')
        if (-not $WithoutMarker) {
            $marker = [ordered]@{ cycleStartUtc = '2026-11-01T02:10:00Z'; cycleNumber = 249; cycleFolder = $script:Leaf
                startedAtUtc = $StartedAtUtc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"); pid = 4242; hostname = 'fixture.local' }
            [IO.File]::WriteAllText((Join-Path $folder '.incomplete'), ($marker | ConvertTo-Json -Compress))
        }
        foreach ($file in Get-ChildItem -LiteralPath $folder -File -Recurse -Force) { $file.LastWriteTimeUtc = $LastWriteUtc }
        return @{ Root = $root; Log = $log; Runtime = $runtime; Folder = $folder }
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
        param([string]$StdOut = '', [string]$StdErr = '', [int]$ExitCode = 0, [switch]$NotStarted, [switch]$TimedOut)
        return @{
            Started = -not $NotStarted; ExitCode = $(if ($NotStarted) { -1 } elseif ($TimedOut) { 124 } else { $ExitCode })
            StdOut = $StdOut; StdErr = $StdErr; TimedOut = [bool]$TimedOut; DrainTimedOut = $false
            KillFailed = $false; OutputTruncated = $false; DeadlineExhausted = $false
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

    It 'queues the refresh-preservation summary the same way' {
        $root = New-YurunaTestTempDir -Prefix 'yrn-host-restart-refresh'
        try {
            $runtime = Join-Path $root 'runtime'
            $log = Join-Path $root 'log'
            $null = New-Item -ItemType Directory -Path $runtime, $log -Force
            Set-Content -LiteralPath (Join-Path $runtime 'control.pause') -Value 'x'
            $env:YURUNA_LOG_DIR = $log
            $null = Invoke-YurunaBootRecovery -RuntimeDir $runtime -LogDir $log -RefreshPreservation -Confirm:$false
            $queued = @(Read-QueuedEvent -RuntimeDir $runtime)
            $queued.Count | Should -Be 1
            $queued[0].event | Should -Be 'boot_recovery_completed'
            $queued[0].mode | Should -Be 'refresh-preservation'
            Test-Path -LiteralPath (Join-Path $log 'cycle.events.ndjson') | Should -BeFalse -Because 'the log-root fallback is a file nothing collects'
        } finally { Remove-YurunaTestTempDir $root }
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

    It 'queries the System log since the last write and lists the newer minidumps on Windows' {
        $script:Query = $null
        Mock -ModuleName Test.Recovery Invoke-BoundedNativeCommand {
            $script:Query = @($ArgumentList)
            New-NativeResult -StdOut "Event[0]:`n  Log Name: System`n  Source: Microsoft-Windows-Kernel-Power`n  Event ID: 41"
        }
        $dumps = Join-Path $script:Deep 'Minidump'
        $null = New-Item -ItemType Directory -Path $dumps -Force
        foreach ($name in 'old.dmp', 'new.dmp') { [IO.File]::WriteAllText((Join-Path $dumps $name), 'MDMP') }
        (Get-Item -LiteralPath (Join-Path $dumps 'old.dmp')).LastWriteTimeUtc = $script:LastWrite.AddHours(-1)
        (Get-Item -LiteralPath (Join-Path $dumps 'new.dmp')).LastWriteTimeUtc = $script:Now.AddMinutes(-3)
        $null = InModuleScope Test.Recovery -Parameters @{ Folder = $script:Folder; Restart = $script:Restart; Dumps = $dumps } {
            param($Folder, $Restart, $Dumps)
            Save-HostRestartEvidence -CycleFolder $Folder -Restart $Restart -Platform windows -CrashReportDir $Dumps
        }
        $script:Query[0..1] | Should -Be @('qe', 'System')
        $script:Query[2] | Should -Match 'EventID=41 or EventID=6008 or EventID=1001'
        $script:Query[2] | Should -Match ([regex]::Escape($script:LastWrite.ToString("yyyy-MM-dd'T'HH:mm:ss")))
        $json = Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.json') -Raw | ConvertFrom-Json -AsHashtable @script:JsonOption
        @($json.crashReports | ForEach-Object { Split-Path -Leaf $_.path }) | Should -Be @('new.dmp')
        $json.ContainsKey('deepDiagnostics') | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.txt') -Raw | Should -Match 'Kernel-Power'
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
        $text = Get-Content -LiteralPath (Join-Path $script:Folder 'host-restart.txt') -Raw
        $text | Should -Match 'panicString'
        $text | Should -Not -Match 'Safari'
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
