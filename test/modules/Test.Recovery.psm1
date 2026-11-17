<#PSScriptInfo
.VERSION 2026.11.16
.GUID 42961225-d68b-4663-995b-dff524fe4af1
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna recovery boot-sweep stale-state
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

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
# Bounded native calls for the evidence a host restart leaves behind.
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking
# The refresh-preservation mode classifies records with the strict identity
# rules; imported here so that mode never runs without them.
Import-Module (Join-Path $PSScriptRoot 'Test.SingleInstance.psm1') -DisableNameChecking


<#
.SYNOPSIS
    Boot-time recovery sweep: detect + archive stale state classes
    that a prior cycle / process crash left behind.

.DESCRIPTION
    Companion mechanisms close individual stale-state slices:

      * `.incomplete` marker lets a consumer detect a crashed cycle
        in O(1) by checking marker presence in the cycle folder.
      * Outer re-entry force-touches runner.stepHeartbeat so the
        watchdog never reads a 7-hour-old mtime.
      * Test.SingleInstance.Get-RunnerInstanceState classifies a stale
        runner.pid (its pid not a live process) as 'Stale' so the
        outer can take over without an operator click.

    This module owns the cross-class SWEEP that runs ONCE at outer
    startup and resolves every stale class together:

      1. Orphan `.incomplete` cycle folders -> rename marker to
         `.aborted.<UTC>.json` with augmented payload (recoveredAtUtc,
         recoveredByPid, whether the host restarted after the cycle's
         last write, and what ended its runner when the previous runner's
         exit record names a signal inside the cycle). The cycle folder
         itself is preserved as forensics; the rename makes future sweeps
         idempotent (already archived markers are not re-archived). A
         cycle the host restarted under also gets the evidence that boot
         left (host-restart.json, host-restart.txt) and a `host_restart`
         event; one whose runner a signal ended on a host that has not
         restarted since gets runner-signal.json, runner-signal.txt and a
         `runner_ended_by_signal` event. The cycle that was running when
         the runtime directory's progress sidecars were last written gets
         a copy of them (runner-state-at-loss.json).
      2. Stale runner.pid / inner.pid (pid not a live process) -> delete.
         runner.pid takes its runner.start sidecar with it so a future
         Write-RunnerPidFile call sees a clean pair, not a half-state.
      3. Stale break-active.json (no live runner to honor the breakpoint)
         -> archive as `break-active.<UTC>.json.aborted` so an operator
         can audit what was paused.

    Every sweep emits a `boot_recovery_completed` NDJSON event with the
    archived / cleared counts so a streaming consumer / dashboard sees
    that the framework recovered from a crash without grep'ing console
    output. The sweep runs before any cycle is open, so its events wait in
    the runtime directory's pending queue (Add-PendingCycleEvent in
    Test.Log) and join the next cycle's stream.

    Policy: this is a READ-ONLY recovery -- nothing is deleted that
    has forensics value (cycle folders, .incomplete payloads, paused
    break-active state). Stale pidfiles are deleted because the pid
    is provably dead and the file content has no forensics value on
    its own.

    Pair with the marker-file write, the atomic-write helpers, and
    the Write-YurunaStateFile primitive: every state class either
    has a marker that this sweep can act on, or is reconstructible
    from the artifacts the cycle folder preserved.

    Refresh preservation is a stricter mode for a runner restarted by a
    host refresh. The operator's controls outlive the repair: pauses, lab
    holds and a pending cycle restart stay until their normal consumer
    handles them. Nothing is deleted on a failed lookup or an unreadable
    record -- inner.pid goes only as the exact generation proven dead,
    runner.pid is left for the resume path's own strict check, and the
    service pidfiles are not touched. break-active.json is archived only
    for a reclaimed inner proven dead with no live inner in its place, and
    an orphaned cycle folder only when the process that wrote its marker is
    proven gone.
#>

# Operator control files a refresh-preservation sweep leaves in place.
$script:RefreshPreservedControlName = @(
    'control.step-pause', 'control.cycle-pause', 'control.pause',
    'control.lab-hold', 'lab-hold.json', 'control.lab-hold-release', 'control.cycle-restart'
)

# See https://yuruna.link/4213a0b3-00d7
$script:CycleFolderPattern           = '^\d{6}\..+\..+\..+$'
$script:CycleFolderIncompletePattern = '^\d{6}\..+\..+\..+\.incomplete$'

# ConvertFrom-Json turns ISO-8601-looking strings into [DateTime] unless told
# not to (-DateKind String, PowerShell 7.5 and later); the archive and the
# host_restart event carry the marker's times as the text it was written with.
$script:RecoveryJsonOption = @{}
if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $script:RecoveryJsonOption.DateKind = 'String' }
# A host in deep diagnostics mode writes one bundle per boot here, early in that
# boot and after systemd-pstore; the runner reads it through systemd-journal.
$script:DeepDiagnosticsDir = '/var/log/yuruna/deep-diagnostics'
# A boot this many seconds before a cycle's last sign of life still counts as
# after it: Linux states its boot time in whole seconds, and no runner opens a
# cycle within seconds of a boot.
$script:HostRestartToleranceSeconds = 5
# Current-boot kernel lines that name a fault the firmware or kernel recorded
# (APEI BERT records, machine checks, EDAC, PCIe AER) or a watchdog that fired.
$script:HostRestartHardwarePattern = 'BERT|Hardware Error|mce|MCE|EDAC|AER|watchdog'
# What journalctl says when the account is in neither systemd-journal nor adm
# and so reads only its own journal, without the kernel or the system.
$script:JournalNotReadableNotice = 'You are currently not seeing messages from other users and the system'
# A cycle's newest file can predate the signal that ended its runner by as
# long as the step then running went without writing into the folder: a wait
# on a command or a screen between captures. A signal up to this many seconds
# after that write is attributed to the cycle.
$script:SignalAfterLastWriteSeconds = 600
# A shutdown signals the runner shortly before the boot that follows it, an
# update installed on the way included. A boot further than this after the
# signal means the runner was gone long before the shutdown.
$script:SignalBeforeBootSeconds = 900
# A runner session record is this process's own when it carries this process's
# pid and a start time within this many seconds of the process's own: the
# record holds the Process.StartTime the runner read when it wrote it, and the
# runner identity checks in Test.SingleInstance allow the same two seconds.
$script:RunnerStartToleranceSeconds = 2
# The System log's account of how a Windows boot ended and the next began, one
# provider-qualified query each: who asked for the restart and why (User32
# 1074, 1076), the event log's own stop and start and an unexpected stop
# (EventLog 6006, 6005, 6008), a power loss and a kernel-initiated shutdown
# (Kernel-Power 41, 109), the kernel's stop and start (Kernel-General 13, 12),
# a bugcheck (1001, the BugCheck source), and Windows Update's installs
# (19 installed, 20 failed, 43 started, 44 downloading).
$script:WindowsEndOfBootQuery = @(
    @{ Provider = 'User32'; Id = @(1074, 1076) }
    @{ Provider = 'EventLog'; Id = @(6005, 6006, 6008) }
    @{ Provider = 'Microsoft-Windows-Kernel-Power'; Id = @(41, 109) }
    @{ Provider = 'Microsoft-Windows-Kernel-General'; Id = @(12, 13) }
    @{ Provider = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = @(1001) }
    @{ Provider = 'Microsoft-Windows-WindowsUpdateClient'; Id = @(19, 20, 43, 44) }
)
# The processes of a macOS GUI session whose unified log says why Terminal and
# UTM went away together: a logout or restart (loginwindow, softwareupdated), a
# window server failure, an app quit or crash, or an Apple Events or privacy
# prompt behind the utmctl calls. UTM runs each VM's emulator as QEMULauncher
# under its QEMUHelper XPC service, and a predicate compares strings
# case-sensitively unless the operator carries [c].
$script:MacSessionLogPredicate = 'process == "loginwindow" OR process == "WindowServer" OR process == "Terminal" OR process == "UTM" OR process BEGINSWITH[c] "qemu" OR process == "softwareupdated" OR process == "appleeventsd" OR process == "launchservicesd" OR process == "tccd"'
# DiagnosticReports names of the same session's apps, and the memory-pressure
# kills a JetsamEvent report lists.
$script:MacSessionReportPattern = '^(Terminal|UTM|qemu|WindowServer|loginwindow|JetsamEvent)'
# The inner runner's progress sidecars: the step it was running (the line the
# status page shows), its last completed work, its process liveness timer, and
# its preamble phase. The next runner's first cycle clears or rewrites them and
# nothing keeps an earlier copy: the status service serves current-action.json
# only as it stands and refuses the other three, so a lost cycle keeps them only
# as the sweep's copy.
$script:RunnerProgressSidecarName = @('current-action.json', 'runner.stepHeartbeat', 'runner.heartbeat', 'runner.phase')
$script:RunnerStateAtLossName = 'runner-state-at-loss.json'

function Get-YurunaHostBootTimeUtc {
    <#
    .SYNOPSIS
        When this host last booted, in UTC, or $null when that cannot be read.
    .DESCRIPTION
        Linux states it as btime in /proc/stat and macOS as sysctl kern.boottime.
        Windows has neither, so the boot is the current time less the
        milliseconds-since-boot counter: it restarts with every boot, counts
        time asleep, and needs no WMI query, which a host just back from a crash
        can be slow to answer.
    .PARAMETER Platform
        linux, macos or windows. Defaults to the current platform.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([ValidateSet('linux', 'macos', 'windows')][string]$Platform = (Get-YurunaPlatformName))
    try {
        switch ($Platform) {
            'linux' {
                foreach ($line in [IO.File]::ReadAllLines('/proc/stat')) {
                    if ($line -match '^btime\s+(\d+)') { return [DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1]).UtcDateTime }
                }
            }
            'macos' {
                $sysctl = Invoke-BoundedNativeCommand -FilePath 'sysctl' -ArgumentList @('-n', 'kern.boottime') -TimeoutSeconds 5
                if ([string]$sysctl.StdOut -match 'sec\s*=\s*(\d+)') { return [DateTimeOffset]::FromUnixTimeSeconds([long]$Matches[1]).UtcDateTime }
            }
            'windows' { return [datetime]::UtcNow.AddMilliseconds(-[double][Environment]::TickCount64) }
        }
    } catch {
        Write-Verbose "Get-YurunaHostBootTimeUtc: the boot time is unreadable: $($_.Exception.Message)"
    }
    return $null
}

function Get-CycleFolderLastWriteUtc {
    <#
    .SYNOPSIS
        The newest write time of any file in a cycle folder, or $null.
    .DESCRIPTION
        A host that froze mid-cycle leaves files whose data never reached the
        disk but whose directory entries did, so the newest write is within
        seconds of the freeze. Hidden files count -- the .incomplete marker is
        one -- and the walk is bounded, so a folder that grew without limit
        cannot stall the sweep.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory)][string]$Path)
    $newest = $null
    Get-ChildItem -LiteralPath $Path -File -Recurse -Force -Depth 4 -ErrorAction SilentlyContinue |
        Select-Object -First 20000 |
        ForEach-Object { if ($null -eq $newest -or $_.LastWriteTimeUtc -gt $newest) { $newest = $_.LastWriteTimeUtc } }
    return $newest
}

function ConvertTo-RecoveryUtcText {
    <#
    .SYNOPSIS
        A marker time as ISO-8601 UTC text: the text itself, or the [datetime] a
        JSON parse without -DateKind String made of it, formatted back.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)
    if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }
    return [string]$Value
}

function ConvertFrom-RecoveryUtcText {
    <#
    .SYNOPSIS
        A time given as ISO-8601 text or as a [datetime], in UTC, or $null.
        Text without an offset is read as UTC.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([AllowNull()]$Value)
    if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime() }
    $parsed = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if ("$Value" -and [datetime]::TryParse("$Value", [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $parsed }
    return $null
}

function Get-OrphanCycleSpan {
    <#
    .SYNOPSIS
        When an orphaned cycle started and when it last wrote into its folder,
        as @{ StartUtc; LastWriteUtc }, or $null when either is unknown.
    .DESCRIPTION
        The start is the earlier of the marker's cycleStartUtc and startedAtUtc.
        A folder without a marker was closed by Stop-LogFile before its rename
        failed, so no runner died inside it and it has no span.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Marker,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Restart
    )
    $start = @((ConvertFrom-RecoveryUtcText -Value $Marker['cycleStartUtc']), (ConvertFrom-RecoveryUtcText -Value $Marker['startedAtUtc'])) |
        Where-Object { $null -ne $_ } | Sort-Object | Select-Object -First 1
    $lastWrite = ConvertFrom-RecoveryUtcText -Value $Restart['lastWriteUtc']
    if ($null -eq $start -or $null -eq $lastWrite) { return $null }
    return @{ StartUtc = $start; LastWriteUtc = $lastWrite }
}

function Test-OrphanCycleSpan {
    <#
    .SYNOPSIS
        Whether a time falls between an orphaned cycle's start and its newest
        write plus SignalAfterLastWriteSeconds.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][hashtable]$Span, [AllowNull()]$TimeUtc)
    if ($null -eq $Span -or $TimeUtc -isnot [datetime]) { return $false }
    return ($TimeUtc -ge $Span.StartUtc) -and ($TimeUtc -le $Span.LastWriteUtc.AddSeconds($script:SignalAfterLastWriteSeconds))
}

function Get-OrphanRunnerEnd {
    <#
    .SYNOPSIS
        What ended an orphaned cycle's runner, when the previous runner's exit
        record names a signal caught inside the cycle; $null otherwise.
    .DESCRIPTION
        The marker names the inner process that wrote it, not the runner that
        received the signal, so the signal is matched to the cycle by time:
        between the cycle's start and its newest write plus
        SignalAfterLastWriteSeconds.

        endedBy is signal when the host did not restart after the cycle, or
        booted more than SignalBeforeBootSeconds after the signal: the signal,
        not a shutdown, ended the runner. It is host-restart when the boot came
        sooner, because the shutdown sent the signal. silentSeconds, for
        endedBy signal only, runs from the signal to the boot, or to now when
        the host did not restart.
    .OUTPUTS
        [ordered] endedBy, signal, signalAtUtc and, for endedBy signal,
        silentSeconds.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()][hashtable]$Span,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Restart,
        [AllowNull()][System.Collections.IDictionary]$PreviousRunner
    )
    if ($null -eq $PreviousRunner -or -not $PreviousRunner['signal']) { return $null }
    $signalAt = ConvertFrom-RecoveryUtcText -Value $PreviousRunner['signalAtUtc']
    if (-not (Test-OrphanCycleSpan -Span $Span -TimeUtc $signalAt)) { return $null }
    $end = [ordered]@{ endedBy = 'signal'; signal = [string]$PreviousRunner['signal']; signalAtUtc = [string]$PreviousRunner['signalAtUtc'] }
    $boot = if ($Restart['hostRestarted']) { ConvertFrom-RecoveryUtcText -Value $Restart['bootUtc'] } else { $null }
    if ($null -ne $boot -and ($boot - $signalAt).TotalSeconds -le $script:SignalBeforeBootSeconds) {
        $end.endedBy = 'host-restart'
    } else {
        $until = if ($null -ne $boot) { $boot } else { [datetime]::UtcNow }
        $end.silentSeconds = [long][Math]::Max(0, [Math]::Round(($until - $signalAt).TotalSeconds))
    }
    return $end
}

function Read-RunnerProgressSidecar {
    <#
    .SYNOPSIS
        The inner runner's progress sidecars as the runtime directory holds
        them now, or $null when it holds none.
    .DESCRIPTION
        Read-only and bounded: each file's write time and its content, parsed
        when it is JSON, or why it could not be read.
    .OUTPUTS
        [hashtable] NewestWriteUtc, and Document: runner-state-at-loss.json.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $files = [ordered]@{}
    $newest = $null
    foreach ($name in $script:RunnerProgressSidecarName) {
        try {
            $info = [IO.FileInfo]::new((Join-Path $RuntimeDir $name))
            if (-not $info.Exists) { continue }
            $entry = [ordered]@{ lastWriteUtc = $info.LastWriteTimeUtc.ToString('o') }
            if ($null -eq $newest -or $info.LastWriteTimeUtc -gt $newest) { $newest = $info.LastWriteTimeUtc }
            if ($info.Length -gt 65536) {
                $entry.error = 'larger than 64 KiB'
            } else {
                $text = [IO.File]::ReadAllText($info.FullName)
                $entry.content = $text.Trim()
                if ($info.Extension -eq '.json') {
                    $jsonOption = $script:RecoveryJsonOption
                    try { $entry.content = $text | ConvertFrom-Json -AsHashtable @jsonOption -ErrorAction Stop }
                    catch { $entry.parseError = $_.Exception.Message }
                }
            }
            $files[$name] = $entry
        } catch { $files[$name] = [ordered]@{ error = $_.Exception.Message } }
    }
    if ($files.Count -eq 0) { return $null }
    return @{
        NewestWriteUtc = $newest
        Document       = [ordered]@{ schemaVersion = 1; readAtUtc = [datetime]::UtcNow.ToString('o'); files = $files }
    }
}

function Test-RunnerSessionOwnRecord {
    <#
    .SYNOPSIS
        Whether a runner's session report is this process's own: this
        process's pid and its start time, within RunnerStartToleranceSeconds.
    .DESCRIPTION
        A pid alone can belong to a previous runner whose pid the OS gave to
        this one, after a reboot or a pid wrap. A record this process wrote
        itself, in an earlier Start-TestRunner.ps1 run in the same interactive
        pwsh, carries its start time. A start time that is missing or cannot
        be read, on either side, proves nothing, so the record counts as a
        previous runner's.
    .PARAMETER Report
        The session report (Get-YurunaRunnerExitReport).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Report)
    if ([int]$Report['pid'] -ne $PID) { return $false }
    $recorded = ConvertFrom-RecoveryUtcText -Value $Report['startedUtc']
    if ($null -eq $recorded) { return $false }
    try { $own = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToUniversalTime() }
    catch {
        Write-Verbose "Test-RunnerSessionOwnRecord: this process's start time is unreadable: $($_.Exception.Message)"
        return $false
    }
    return ([Math]::Abs(($own - $recorded).TotalSeconds) -le $script:RunnerStartToleranceSeconds)
}

function Get-YurunaWindowsOsBuild {
    <#
    .SYNOPSIS
        This Windows host's build with its update revision (CurrentBuild.UBR)
        and its DisplayVersion, from the registry, or $null.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()
    try {
        $version = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if (-not $version.CurrentBuild) { return $null }
        $build = if ($null -ne $version.UBR) { "$($version.CurrentBuild).$($version.UBR)" } else { [string]$version.CurrentBuild }
        return [ordered]@{ build = $build; displayVersion = [string]$version.DisplayVersion }
    } catch {
        Write-Verbose "Get-YurunaWindowsOsBuild: the build is unreadable: $($_.Exception.Message)"
        return $null
    }
}

function Get-CycleRecordedWindowsBuild {
    <#
    .SYNOPSIS
        The Windows build (CurrentBuild.UBR) a cycle recorded while it ran, or ''.
    .DESCRIPTION
        From the cycle-start host diagnostic's JSON sidecar (its windowsOs
        object), else from the newest host sample metadata the cycle copied
        (its WindowsRevision). An update that restarts the host raises the
        revision at that boot, so this is the build before it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$CycleFolder)
    $jsonOption = $script:RecoveryJsonOption
    try {
        $sidecar = Join-Path $CycleFolder 'host.diagnostic.txt.json'
        if ([IO.File]::Exists($sidecar)) {
            $doc = [IO.File]::ReadAllText($sidecar) | ConvertFrom-Json -AsHashtable @jsonOption -ErrorAction Stop
            if ($doc -is [System.Collections.IDictionary] -and $doc['windowsOs'] -is [System.Collections.IDictionary] -and $doc['windowsOs']['build']) {
                return [string]$doc['windowsOs']['build']
            }
        }
    } catch { Write-Verbose "Get-CycleRecordedWindowsBuild: the host diagnostic sidecar is unreadable: $($_.Exception.Message)" }
    $samples = @(Get-ChildItem -LiteralPath $CycleFolder -Filter 'metadata.json' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue |
        Where-Object { $_.Directory.Name -like 'host-samples-*' } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    foreach ($sample in $samples) {
        try {
            $doc = [IO.File]::ReadAllText($sample.FullName) | ConvertFrom-Json -AsHashtable @jsonOption -ErrorAction Stop
            $revision = if ($doc -is [System.Collections.IDictionary]) { $doc['WindowsRevision'] } else { $null }
            if ($revision -is [System.Collections.IDictionary] -and $revision['CurrentBuild'] -and $null -ne $revision['UBR']) {
                return "$($revision['CurrentBuild']).$($revision['UBR'])"
            }
        } catch { Write-Verbose "Get-CycleRecordedWindowsBuild: $($sample.FullName) is unreadable: $($_.Exception.Message)" }
    }
    return ''
}

function Get-CycleHostRestart {
    <#
    .SYNOPSIS
        Whether the host booted after a crashed cycle's last sign of life, and
        how many seconds passed from the cycle's last write to that boot.
    .DESCRIPTION
        The last sign of life is the later of the folder's newest file write and
        the start its marker recorded. A boot after that, within a few seconds'
        tolerance, means the host restarted under the cycle. A runner killed and
        restarted without a reboot finds a boot from before the cycle started,
        so it never counts. downSeconds runs from the newest write to the boot;
        it is $null when the host did not restart or no write could be read. It
        is not how long the host was down: a runner that died long before the
        host restarted leaves a gap the host spent up.
    .PARAMETER CycleFolder
        The cycle folder, read before anything writes into it.
    .PARAMETER StartedAtUtc
        The marker's startedAtUtc, as text or as a [datetime].
    .OUTPUTS
        [ordered] lastWriteUtc and bootUtc (ISO-8601 text, '' when unknown),
        hostRestarted, downSeconds.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$CycleFolder,
        [AllowNull()]$StartedAtUtc
    )
    $lastWrite = Get-CycleFolderLastWriteUtc -Path $CycleFolder
    $boot = Get-YurunaHostBootTimeUtc
    $started = $null
    $startedText = ConvertTo-RecoveryUtcText -Value $StartedAtUtc
    $parsed = [datetime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal
    if ($startedText -and [datetime]::TryParse($startedText, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { $started = $parsed }
    $alive = @($lastWrite, $started) | Where-Object { $null -ne $_ } | Sort-Object -Descending | Select-Object -First 1
    $restarted = ($null -ne $boot) -and ($null -ne $alive) -and ($boot -ge $alive.AddSeconds(-$script:HostRestartToleranceSeconds))
    return [ordered]@{
        lastWriteUtc  = if ($null -ne $lastWrite) { $lastWrite.ToString('o') } else { '' }
        bootUtc       = if ($null -ne $boot) { ([datetime]$boot).ToString('o') } else { '' }
        hostRestarted = [bool]$restarted
        downSeconds   = if ($restarted -and $null -ne $lastWrite) { [long][Math]::Max(0, [Math]::Round(($boot - $lastWrite).TotalSeconds)) } else { $null }
    }
}

function Save-HostRestartEvidence {
    <#
    .SYNOPSIS
        Write into an aborted cycle folder the evidence its end left on this
        host: host-restart.json and host-restart.txt when the host restarted
        under the cycle, runner-signal.json and runner-signal.txt when a signal
        ended its runner and the host has not restarted since.
    .DESCRIPTION
        Linux, after a restart: the boot list, the previous boot's journal tail
        and kernel warnings, the current boot's kernel lines that name a
        hardware error or a watchdog, the head of last -x, and whether the
        system journal was readable at all. The deep diagnostics bundles written
        since the cycle's last write are copied in as
        host-restart.deep-diagnostics.<name>, or why they could not be is
        recorded. Without a restart, the head of last -x. When a signal ended
        the runner (endedBy signal, with or without a later restart), also the
        journal from three minutes before the signal to one minute after it.

        Windows: the System log's records from half an hour before the window
        center to ten minutes after the boot, or after the center when the
        host did not restart, one provider-qualified query per source, each
        keeping its newest 50 records: User32 1074 and 1076, EventLog 6005,
        6006 and 6008, Kernel-Power 41 and 109, Kernel-General 12 and 13,
        BugCheck 1001, and Windows Update's 19, 20, 43 and 44. After
        a restart also the minidumps written since the last write, and the
        build with its update revision now (osBuildAfter) and as the cycle
        recorded it (osBuildBefore).

        macOS: the head of last -30, the unified log of the GUI session's
        processes from three minutes before the window center to one minute
        after it, the head of softwareupdate --history, and the Terminal, UTM,
        QEMU, WindowServer, loginwindow and JetsamEvent reports in the user's
        and the system's DiagnosticReports written within ten minutes of the
        center. The unified log is cut at its start when it fills the capture,
        so a capture that filled it reads the last half minute before the
        center and the minute after it again on its own. After a restart also
        the head of last reboot and the panic reports written since the last
        write.

        The window centers on the signal when one ended the runner, else on the
        cycle's newest write. Every command is bounded and every failure is
        recorded, never thrown: this runs in the startup sweep of a host that
        has just come back. The .txt holds the command output and the reports;
        the .json the outcome of each command and what was found.
    .PARAMETER CycleFolder
        The aborted cycle folder.
    .PARAMETER Restart
        The Get-CycleHostRestart result for that folder.
    .PARAMETER RunnerEnd
        The Get-OrphanRunnerEnd result for that folder, when a signal ended
        its runner.
    .PARAMETER Platform
        linux, macos or windows. Defaults to the current platform.
    .PARAMETER DeepDiagnosticsDir
        Where a host in deep diagnostics mode keeps its boot bundles.
    .PARAMETER CrashReportDir
        The minidump (Windows) or diagnostic report (macOS) folders; the
        platform's own when omitted.
    .OUTPUTS
        [hashtable] evidenceFiles (names written into the folder),
        deepDiagnosticsBundles (bundles copied), osBuildBefore and
        osBuildAfter ('' when unknown).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$CycleFolder,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Restart,
        [AllowNull()][System.Collections.IDictionary]$RunnerEnd,
        [ValidateSet('linux', 'macos', 'windows')][string]$Platform = (Get-YurunaPlatformName),
        [string]$DeepDiagnosticsDir = $script:DeepDiagnosticsDir,
        [string[]]$CrashReportDir = @()
    )
    $restarted = [bool]$Restart['hostRestarted']
    $baseName = if ($restarted) { 'host-restart' } else { 'runner-signal' }
    $result = @{ evidenceFiles = @(); deepDiagnosticsBundles = 0; osBuildBefore = ''; osBuildAfter = '' }
    $since = [datetime]::MinValue
    if ($Restart['lastWriteUtc']) {
        $since = [datetime]::Parse([string]$Restart['lastWriteUtc'], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }
    $signalAt = if ($RunnerEnd) { ConvertFrom-RecoveryUtcText -Value $RunnerEnd['signalAtUtc'] } else { $null }
    $center = if ($null -ne $signalAt) { $signalAt } elseif ($since -ne [datetime]::MinValue) { $since } else { [datetime]::UtcNow }
    $signalEnded = ($null -ne $RunnerEnd) -and ($RunnerEnd['endedBy'] -eq 'signal')
    $specs = switch ($Platform) {
        'linux' {
            if ($restarted) {
                @{ FilePath = 'journalctl'; ArgumentList = @('--list-boots', '--no-pager') }
                @{ FilePath = 'journalctl'; ArgumentList = @('-b', '-1', '-n', '300', '-o', 'short-iso-precise', '--no-pager') }
                @{ FilePath = 'journalctl'; ArgumentList = @('-k', '-b', '-1', '-p', 'warning', '-n', '300', '-o', 'short-iso-precise', '--no-pager') }
                # The whole current boot is read and only the matching lines kept,
                # so this does not depend on a journalctl built with --grep.
                @{ FilePath = 'journalctl'; ArgumentList = @('-k', '-b', '0', '-o', 'short-iso-precise', '--no-pager'); Filter = $script:HostRestartHardwarePattern; MaxCapturedChars = 4194304 }
            }
            @{ FilePath = 'last'; ArgumentList = @('-x', '-F'); Head = 40 }
            if ($signalEnded) {
                # -n keeps the newest lines of the window, the ones nearest the signal.
                @{ FilePath = 'journalctl'; MaxCapturedChars = 1048576; ArgumentList = @(
                    '--since', $center.AddSeconds(-180).ToString("yyyy-MM-dd HH:mm:ss 'UTC'", [Globalization.CultureInfo]::InvariantCulture),
                    '--until', $center.AddSeconds(60).ToString("yyyy-MM-dd HH:mm:ss 'UTC'", [Globalization.CultureInfo]::InvariantCulture),
                    '-o', 'short-iso-precise', '--no-pager', '-n', '2000') }
            }
        }
        'windows' {
            # Each query keeps only its newest 50 records, so a window left open
            # until the sweep, which can come days later, would let the update
            # records logged meanwhile push out the ones around the restart or
            # the signal.
            $boot = if ($restarted) { ConvertFrom-RecoveryUtcText -Value $Restart['bootUtc'] } else { $null }
            $windowEndAt = if ($null -ne $boot -and $boot -gt $center) { $boot } else { $center }
            $windowStart = $center.AddMinutes(-30).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
            $windowEnd = $windowEndAt.AddMinutes(10).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
            foreach ($query in $script:WindowsEndOfBootQuery) {
                $ids = (@($query.Id) | ForEach-Object { "EventID=$_" }) -join ' or '
                @{ FilePath = 'wevtutil'; ArgumentList = @('qe', 'System',
                    "/q:*[System[Provider[@Name='$($query.Provider)'] and ($ids) and TimeCreated[@SystemTime>='$windowStart' and @SystemTime<='$windowEnd']]]",
                    '/f:text', '/rd:true', '/c:50') }
            }
        }
        'macos' {
            if ($restarted) { @{ FilePath = 'last'; ArgumentList = @('reboot'); Head = 20 } }
            @{ FilePath = 'last'; ArgumentList = @('-30'); Head = 40 }
            $logStart = $center.AddSeconds(-180).ToString("yyyy-MM-dd HH:mm:ss'+0000'", [Globalization.CultureInfo]::InvariantCulture)
            $logTailStart = $center.AddSeconds(-30).ToString("yyyy-MM-dd HH:mm:ss'+0000'", [Globalization.CultureInfo]::InvariantCulture)
            $logEnd = $center.AddSeconds(60).ToString("yyyy-MM-dd HH:mm:ss'+0000'", [Globalization.CultureInfo]::InvariantCulture)
            @{ FilePath = 'log'; TimeoutSeconds = 90; MaxCapturedChars = 4194304
                ArgumentList = @('show', '--style', 'compact', '--start', $logStart, '--end', $logEnd, '--predicate', $script:MacSessionLogPredicate)
                TailArgumentList = @('show', '--style', 'compact', '--start', $logTailStart, '--end', $logEnd, '--predicate', $script:MacSessionLogPredicate) }
            @{ FilePath = 'softwareupdate'; ArgumentList = @('--history'); Head = 15 }
        }
    }
    $runSpec = {
        param([hashtable]$Spec, [string[]]$ArgumentList)
        $max = if ($Spec.MaxCapturedChars) { [int]$Spec.MaxCapturedChars } else { 262144 }
        $timeout = if ($Spec.TimeoutSeconds) { [int]$Spec.TimeoutSeconds } else { 20 }
        $run = Invoke-BoundedNativeCommand -FilePath $Spec.FilePath -ArgumentList $ArgumentList -TimeoutSeconds $timeout -MaxCapturedChars $max
        $lines = @(([string]$run.StdOut) -split "`r?`n" | Where-Object { $_ -ne '' })
        if ($Spec.Filter) { $lines = @($lines | Where-Object { $_ -cmatch $Spec.Filter } | Select-Object -First 500) }
        if ($Spec.Head) { $lines = @($lines | Select-Object -First $Spec.Head) }
        [ordered]@{
            command   = (@($Spec.FilePath) + @($ArgumentList)) -join ' '
            started   = [bool]$run.Started
            exitCode  = [int]$run.ExitCode
            complete  = [bool](Test-BoundedNativeResultComplete -Result $run)
            truncated = [bool]$run.OutputTruncated
            lines     = $lines
            stderr    = ([string]$run.StdErr).Trim()
            filtered  = [bool]$Spec.Filter
        }
    }
    $commands = @(foreach ($spec in @($specs)) {
        $entry = & $runSpec $spec $spec.ArgumentList
        $entry
        if ($entry.truncated -and $spec.TailArgumentList) { & $runSpec $spec $spec.TailArgumentList }
    })
    $journal = @($commands | Where-Object { $_.started -and $_.command -like 'journalctl *' })
    $journalReadable = $null
    if ($journal.Count -gt 0) {
        $journalReadable = -not @($journal | Where-Object { $_.stderr.Contains($script:JournalNotReadableNotice) }).Count
    }

    $reportDirs = if ($CrashReportDir) { @($CrashReportDir) }
                  elseif ($Platform -eq 'windows') { @(Join-Path ([string]$env:SystemRoot) 'Minidump') }
                  elseif ($Platform -eq 'macos') { @(if ($HOME) { Join-Path $HOME 'Library/Logs/DiagnosticReports' }) + '/Library/Logs/DiagnosticReports' }
                  else { @() }
    $reportFiles = @()
    $unreadable = @()
    foreach ($dir in $reportDirs) {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        try { $reportFiles += @([IO.DirectoryInfo]::new($dir).GetFiles()) }
        catch { $unreadable += "unreadable: $($_.Exception.Message)" }
    }
    $crashReportReason = $unreadable -join '; '
    $crashReports = @()
    if ($restarted) {
        $crashReports = @($reportFiles |
            Where-Object { $_.LastWriteTimeUtc -gt $since -and ($Platform -ne 'macos' -or $_.Extension -eq '.panic' -or ($_.Extension -eq '.ips' -and $_.Name -match 'panic')) } |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 10)
    }
    $appReports = @()
    if ($Platform -eq 'macos') {
        $from = $center.AddMinutes(-10)
        $to = $center.AddMinutes(10)
        $appReports = @($reportFiles |
            Where-Object { $_.Name -match $script:MacSessionReportPattern -and $_.LastWriteTimeUtc -ge $from -and $_.LastWriteTimeUtc -le $to } |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 10)
    }

    $osDisplayVersion = ''
    if ($Platform -eq 'windows' -and $restarted) {
        $now = Get-YurunaWindowsOsBuild
        if ($now) { $result.osBuildAfter = [string]$now.build; $osDisplayVersion = [string]$now.displayVersion }
        $result.osBuildBefore = Get-CycleRecordedWindowsBuild -CycleFolder $CycleFolder
    }

    $deep = $null
    if ($Platform -eq 'linux' -and $restarted) {
        $deep = [ordered]@{ directory = $DeepDiagnosticsDir; copied = @(); notCopied = @(); reason = '' }
        if (-not (Test-Path -LiteralPath $DeepDiagnosticsDir -PathType Container)) {
            $deep.reason = 'absent'
        } else {
            $bundles = @()
            try {
                $bundles = @([IO.DirectoryInfo]::new($DeepDiagnosticsDir).GetFiles('boot-*.txt') |
                    Where-Object { $_.LastWriteTimeUtc -gt $since } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 4)
                if ($bundles.Count -eq 0) { $deep.reason = 'none written since the last write' }
            } catch { $deep.reason = "unreadable: $($_.Exception.Message)" }
            foreach ($bundle in $bundles) {
                $name = 'host-restart.deep-diagnostics.' + $bundle.Name
                if ($bundle.Length -gt 16MB) { $deep.notCopied += [ordered]@{ name = $bundle.Name; reason = 'larger than 16 MiB' }; continue }
                try {
                    [IO.File]::Copy($bundle.FullName, (Join-Path $CycleFolder $name), $true)
                    $deep.copied += $name
                } catch { $deep.notCopied += [ordered]@{ name = $bundle.Name; reason = $_.Exception.Message } }
            }
        }
        $result.deepDiagnosticsBundles = @($deep.copied).Count
    }

    $text = [Text.StringBuilder]::new()
    foreach ($field in @('lastWriteUtc', 'bootUtc', 'downSeconds')) { [void]$text.AppendLine("${field}: $($Restart[$field])") }
    if ($RunnerEnd) { foreach ($field in $RunnerEnd.Keys) { [void]$text.AppendLine("${field}: $($RunnerEnd[$field])") } }
    if ($result.osBuildBefore -or $result.osBuildAfter) {
        [void]$text.AppendLine("osBuildBefore: $($result.osBuildBefore)")
        [void]$text.AppendLine("osBuildAfter: $($result.osBuildAfter) $osDisplayVersion".TrimEnd())
    }
    [void]$text.AppendLine("systemJournalReadable: $journalReadable")
    foreach ($entry in $commands) {
        [void]$text.AppendLine()
        [void]$text.AppendLine("== $($entry.command) (exit $($entry.exitCode)$(if ($entry.filtered) { ", lines matching $($script:HostRestartHardwarePattern)" })$(if ($entry.truncated) { ', cut at the capture limit' })) ==")
        foreach ($line in $entry.lines) { [void]$text.AppendLine($line) }
        if ($entry.stderr) { [void]$text.AppendLine('-- stderr --'); [void]$text.AppendLine($entry.stderr) }
    }
    $reportText = @()
    if ($Platform -eq 'macos') { $reportText = @(@($crashReports | Select-Object -First 2) + $appReports) }
    foreach ($report in $reportText) {
        [void]$text.AppendLine()
        [void]$text.AppendLine("== $($report.FullName) (first 16384 characters) ==")
        try {
            $reader = [IO.StreamReader]::new($report.FullName)
            try { $buffer = [char[]]::new(16384); [void]$text.AppendLine([string]::new($buffer, 0, $reader.ReadBlock($buffer, 0, $buffer.Length))) }
            finally { $reader.Dispose() }
        } catch { [void]$text.AppendLine("unreadable: $($_.Exception.Message)") }
    }

    $describeFile = { param($File) [ordered]@{ path = $File.FullName; lastWriteUtc = $File.LastWriteTimeUtc.ToString('o'); length = [long]$File.Length } }
    $document = [ordered]@{
        schemaVersion         = 1
        collectedAtUtc        = (Get-Date).ToUniversalTime().ToString('o')
        cycleFolder           = Split-Path -Leaf $CycleFolder
        platform              = $Platform
        lastWriteUtc          = [string]$Restart['lastWriteUtc']
        bootUtc               = [string]$Restart['bootUtc']
        downSeconds           = $Restart['downSeconds']
        windowCenterUtc       = $center.ToString('o')
        systemJournalReadable = $journalReadable
        commands              = @($commands | ForEach-Object {
            [ordered]@{ command = $_.command; started = $_.started; exitCode = $_.exitCode; complete = $_.complete; truncated = $_.truncated; lineCount = @($_.lines).Count; stderr = $_.stderr }
        })
        hardwareErrorLines    = @($commands | Where-Object { $_.filtered } | ForEach-Object { $_.lines })
        crashReports          = @($crashReports | ForEach-Object { & $describeFile $_ })
        crashReportReason     = $crashReportReason
    }
    if ($RunnerEnd) { foreach ($key in $RunnerEnd.Keys) { $document[$key] = $RunnerEnd[$key] } }
    if ($Platform -eq 'macos') { $document.appReports = @($appReports | ForEach-Object { & $describeFile $_ }) }
    if ($Platform -eq 'windows' -and $restarted) {
        $document.osBuildBefore = $result.osBuildBefore
        $document.osBuildAfter = $result.osBuildAfter
        $document.osDisplayVersion = $osDisplayVersion
    }
    if ($deep) { $document.deepDiagnostics = $deep }
    $encoding = [Text.UTF8Encoding]::new($false)
    foreach ($file in @(@{ Name = "$baseName.json"; Content = ($document | ConvertTo-Json -Depth 8) }, @{ Name = "$baseName.txt"; Content = $text.ToString() })) {
        try {
            [IO.File]::WriteAllText((Join-Path $CycleFolder $file.Name), $file.Content, $encoding)
            $result.evidenceFiles += $file.Name
        } catch { Write-Verbose "Save-HostRestartEvidence: $($file.Name) not written in ${CycleFolder}: $($_.Exception.Message)" }
    }
    if ($deep) { $result.evidenceFiles += @($deep.copied) }
    return $result
}

function Send-BootRecoveryEvent {
    <#
    .SYNOPSIS
        Queue a boot-recovery event for the next cycle's stream.
    .DESCRIPTION
        The sweep runs before any cycle is open, so an event sent the ordinary
        way falls back to the log root, where nothing collects it. It waits in
        the runtime directory's pending queue (Add-PendingCycleEvent in
        Test.Log) instead, and goes to the log root only when it cannot be
        queued. A process without the cycle-event writer emits nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$EventRecord,
        [AllowEmptyString()][string]$RuntimeDir
    )
    if ((Get-Command Add-PendingCycleEvent -ErrorAction SilentlyContinue) -and
        (Add-PendingCycleEvent -EventRecord $EventRecord -RuntimeDir $RuntimeDir)) { return }
    if (Get-Command Send-CycleEventSafely -ErrorAction SilentlyContinue) { Send-CycleEventSafely -EventRecord $EventRecord }
}

function Find-OrphanIncompleteCycle {
    <#
    .SYNOPSIS
        Return cycle folders under $LogDir that crashed mid-cycle.
    .DESCRIPTION
        Two crash signatures:

          a) Folder name has the `.incomplete` SUFFIX. The
             Stop-LogFile rename did not run -- the cycle either
             crashed mid-execution or after manifest write but
             before the folder rename. Either way the marker file
             inside may or may not still be present.
          b) Bare-named folder contains a `.incomplete` marker FILE
             (older shape, kept for backward compatibility with
             cycles written before the folder-suffix lifecycle).

        Returns one FileInfo per detected marker. When the folder
        has the suffix but no marker file inside (rename-failure
        case), returns a synthetic FileInfo for the folder itself
        (Resolve-OrphanIncompleteCycle handles both cases).
    .PARAMETER LogDir
        Path to test/status/log/. Defaults to $env:YURUNA_LOG_DIR.
    .OUTPUTS
        [System.IO.FileSystemInfo[]] one entry per orphan signal.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileSystemInfo[]], [object[]])]
    param([string]$LogDir = $env:YURUNA_LOG_DIR)
    if (-not $LogDir -or -not (Test-Path -LiteralPath $LogDir)) { return @() }
    $orphans = @()
    foreach ($cycleFolder in (Get-ChildItem -LiteralPath $LogDir -Directory -ErrorAction SilentlyContinue |
                              Where-Object { $_.Name -match $script:CycleFolderPattern -or
                                             $_.Name -match $script:CycleFolderIncompletePattern })) {
        $marker = Join-Path $cycleFolder.FullName '.incomplete'
        if (Test-Path -LiteralPath $marker) {
            # -Force is load-bearing: the FileSystem provider treats a
            # dot-prefixed name as HIDDEN on macOS/Linux, and the marker is
            # `.incomplete`. Without it Test-Path still says the file is there
            # but Get-Item fails with "Could not find item ...", so every
            # crashed cycle is detected and then dropped -- the folder keeps
            # its .incomplete suffix, is never archived, and the same error
            # prints again on the next boot.
            $orphans += (Get-Item -LiteralPath $marker -Force)
        } elseif ($cycleFolder.Name -match $script:CycleFolderIncompletePattern) {
            # Suffix says incomplete but no marker file. Rename failure
            # after Stop-LogFile removed the marker but before the
            # folder-level Move-Item; treat the folder itself as the
            # orphan signal so Resolve-OrphanIncompleteCycle can still
            # rename it to .aborted.<UTC>/.
            $orphans += $cycleFolder
        }
    }
    return $orphans
}

function Resolve-OrphanIncompleteCycle {
    <#
    .SYNOPSIS
        Archive a crashed cycle. Two cases:

          a) MarkerPath points at an `.incomplete` marker FILE inside
             a cycle folder -- write `.aborted.<UTC>.json` with
             augmented payload, remove the marker, AND (when the
             parent folder has the `.incomplete` suffix) rename
             the folder to `<base>.aborted.<UTC>/`.

          b) MarkerPath points at a FOLDER with the `.incomplete`
             suffix but no marker file inside (rename-failure during
             Stop-LogFile) -- skip the marker work and rename the
             folder.

        Both cases end with the folder renamed away from the
        `.incomplete` suffix so a second sweep is a no-op.

        Before anything is written into the folder, its newest file write
        is compared with the host's boot time (Get-CycleHostRestart); the
        archive carries lastWriteUtc, bootUtc, hostRestarted and
        downSeconds. When the previous runner's signal falls inside the
        cycle (Get-OrphanRunnerEnd), the archive also carries endedBy,
        signal, signalAtUtc and, for endedBy signal, silentSeconds. When the
        host restarted under the cycle, or a signal ended its runner, the
        evidence is saved in the folder (Save-HostRestartEvidence) and a
        host_restart event, or, when the host has not restarted, a
        runner_ended_by_signal event, is queued for the next cycle's stream.
        Progress sidecars written while the cycle ran are copied in as
        runner-state-at-loss.json.
    .PARAMETER MarkerPath
        Either a `.incomplete` marker file (case a) OR a cycle folder
        with `.incomplete` suffix (case b).
    .PARAMETER RuntimeDir
        The runtime directory whose pending queue takes the host_restart
        event. Defaults to $env:YURUNA_RUNTIME_DIR.
    .PARAMETER PreviousRunner
        The previous runner's exit report (Get-YurunaRunnerExitReport), whose
        signal this cycle may claim.
    .PARAMETER RunnerState
        The progress sidecars the sweep read (Read-RunnerProgressSidecar),
        which this cycle may claim.
    .OUTPUTS
        Hashtable describing what was archived, or $null on failure.
        endedBy is set when the cycle claimed the signal, and
        runnerStateSaved when it claimed the progress sidecars.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$MarkerPath,
        [AllowEmptyString()][string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [AllowNull()][System.Collections.IDictionary]$PreviousRunner,
        [AllowNull()][hashtable]$RunnerState
    )
    if (-not (Test-Path -LiteralPath $MarkerPath)) { return $null }
    if (-not $PSCmdlet.ShouldProcess($MarkerPath, (Format-YurunaOperatorMessage -Key 'runner.operator_d3778fb2e379356a'))) { return $null }

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ssZ', [Globalization.CultureInfo]::InvariantCulture)
    $now   = (Get-Date).ToUniversalTime().ToString('o')

    # Detect shape: file (marker) vs directory (folder-with-suffix). -Force
    # for the same hidden-dotfile reason as the detector: a `.incomplete`
    # marker is hidden to the provider, and a $null from a suppressed lookup
    # would answer "not a directory" without ever having looked.
    $isDir = (Get-Item -LiteralPath $MarkerPath -Force -ErrorAction SilentlyContinue) -is [System.IO.DirectoryInfo]

    if ($isDir) {
        # Case b: bare folder with .incomplete suffix, no marker file.
        $cycleDir = $MarkerPath
        $markerObj = @{}
    } else {
        # Case a: marker file. Parse payload + augment.
        $cycleDir = Split-Path -Parent $MarkerPath
        $markerObj = @{}
        try {
            $raw = Get-Content -Raw -LiteralPath $MarkerPath -ErrorAction Stop
            if ($raw -and $raw.Trim()) {
                $jsonOption = $script:RecoveryJsonOption
                $parsed = $raw | ConvertFrom-Json -AsHashtable @jsonOption -ErrorAction Stop
                if ($parsed -is [System.Collections.IDictionary]) { $markerObj = [hashtable]$parsed }
            }
        } catch {
            Write-Verbose "Resolve-OrphanIncompleteCycle: marker parse failed at $MarkerPath ($($_.Exception.Message)); archiving with minimal payload."
        }
    }
    $markerObj['recoveredAtUtc'] = $now
    $markerObj['recoveredByPid'] = $PID
    $markerObj['recoverySignal'] = if ($isDir) { 'folder_suffix' } else { 'marker_file' }
    # Measured before the archive below adds the newest file to the folder.
    $restart = Get-CycleHostRestart -CycleFolder $cycleDir -StartedAtUtc $markerObj['startedAtUtc']
    foreach ($key in $restart.Keys) { $markerObj[$key] = $restart[$key] }
    $span = Get-OrphanCycleSpan -Marker $markerObj -Restart $restart
    $runnerEnd = Get-OrphanRunnerEnd -Span $span -Restart $restart -PreviousRunner $PreviousRunner
    if ($runnerEnd) { foreach ($key in $runnerEnd.Keys) { $markerObj[$key] = $runnerEnd[$key] } }

    # Decide the post-recovery folder name. If the folder is already
    # `<base>.incomplete/`, rename to `<base>.aborted.<UTC>/`. If the
    # folder is bare, leave the folder name alone and just archive
    # the marker inside.
    $cycleDirLeaf = Split-Path -Leaf $cycleDir
    $hasIncompleteSuffix = $cycleDirLeaf -match '\.incomplete$'
    $finalCycleDir = $cycleDir
    if ($hasIncompleteSuffix) {
        $abortedLeaf = ($cycleDirLeaf -replace '\.incomplete$', '') + ".aborted.$stamp"
        $finalCycleDir = Join-Path (Split-Path -Parent $cycleDir) $abortedLeaf
        try {
            Move-Item -LiteralPath $cycleDir -Destination $finalCycleDir -Force -ErrorAction Stop
        } catch {
            Write-Verbose "Resolve-OrphanIncompleteCycle: folder rename '$cycleDir' -> '$finalCycleDir' failed: $($_.Exception.Message). Leaving folder with .incomplete suffix; marker archive below proceeds in-place."
            $finalCycleDir = $cycleDir
        }
    }

    # Marker-file archive (case a only; case b had no marker to copy).
    $archivedPath = $null
    if (-not $isDir) {
        $archivedPath = Join-Path $finalCycleDir ".aborted.$stamp.json"
        $ok = $false
        if (Get-Command Write-YurunaStateFileJson -ErrorAction SilentlyContinue) {
            $ok = Write-YurunaStateFileJson -Path $archivedPath -InputObject $markerObj -Confirm:$false
        } else {
            # Defensive fallback for callers that loaded Test.Recovery without
            # Test.StateFile in scope (test fixtures, unusual entry points).
            try {
                $json = $markerObj | ConvertTo-Json -Compress
                [System.IO.File]::WriteAllText($archivedPath, $json, [System.Text.UTF8Encoding]::new($false))
                $ok = $true
            } catch {
                Write-Verbose "Resolve-OrphanIncompleteCycle: fallback write failed: $($_.Exception.Message)"
                $ok = $false
            }
        }
        if (-not $ok) { return $null }
        # The original marker is now inside $finalCycleDir (Move-Item
        # carried the folder contents with it when the folder was
        # renamed). Remove it.
        $relocatedMarker = Join-Path $finalCycleDir '.incomplete'
        if (Test-Path -LiteralPath $relocatedMarker) {
            Remove-Item -LiteralPath $relocatedMarker -Force -ErrorAction SilentlyContinue
        }
    }

    $evidence = @{ evidenceFiles = @(); deepDiagnosticsBundles = 0; osBuildBefore = ''; osBuildAfter = '' }
    if ($restart.hostRestarted -or $runnerEnd) {
        try {
            $evidence = Save-HostRestartEvidence -CycleFolder $finalCycleDir -Restart $restart -RunnerEnd $runnerEnd
        } catch {
            Write-Verbose "Resolve-OrphanIncompleteCycle: host restart evidence not saved for ${finalCycleDir}: $($_.Exception.Message)"
        }
    }
    # The sidecars were last written by the cycle that was running then; a
    # cycle that started after that write, or ended long before it, is not it.
    $runnerStateSaved = $false
    if ($RunnerState -and (Test-OrphanCycleSpan -Span $span -TimeUtc $RunnerState.NewestWriteUtc)) {
        try {
            [IO.File]::WriteAllText((Join-Path $finalCycleDir $script:RunnerStateAtLossName), ($RunnerState.Document | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
            $runnerStateSaved = $true
            $evidence.evidenceFiles = @($evidence.evidenceFiles) + $script:RunnerStateAtLossName
        } catch {
            Write-Verbose "Resolve-OrphanIncompleteCycle: $($script:RunnerStateAtLossName) not written in ${finalCycleDir}: $($_.Exception.Message)"
        }
    }
    if ($restart.hostRestarted -or $runnerEnd) {
        # The cycle-identity fields of these events are the cycle that delivers
        # them, so the aborted cycle is named under its own field names.
        $abortedNumber = 0
        if ($markerObj.Contains('cycleNumber')) { $abortedNumber = [int]$markerObj['cycleNumber'] }
        elseif ((Split-Path -Leaf $finalCycleDir) -match '^(\d{6})\.') { $abortedNumber = [int]$Matches[1] }
        $lossEvent = @{
            timestamp            = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
            abortedCycleFolder   = Split-Path -Leaf $finalCycleDir
            abortedCycleStartUtc = ConvertTo-RecoveryUtcText -Value $markerObj['cycleStartUtc']
            abortedCycleNumber   = $abortedNumber
            lastWriteUtc         = [string]$restart.lastWriteUtc
            evidenceFiles        = @($evidence.evidenceFiles)
        }
        if ($restart.hostRestarted) {
            $lossEvent.event                  = 'host_restart'
            $lossEvent.bootUtc                = [string]$restart.bootUtc
            $lossEvent.downSeconds            = $restart.downSeconds
            $lossEvent.deepDiagnosticsBundles = [int]$evidence.deepDiagnosticsBundles
            if ($runnerEnd) { foreach ($key in $runnerEnd.Keys) { $lossEvent[$key] = $runnerEnd[$key] } }
            if ($evidence.osBuildBefore) { $lossEvent.osBuildBefore = [string]$evidence.osBuildBefore }
            if ($evidence.osBuildAfter) { $lossEvent.osBuildAfter = [string]$evidence.osBuildAfter }
        } else {
            $lossEvent.event           = 'runner_ended_by_signal'
            $lossEvent.signal          = [string]$runnerEnd.signal
            $lossEvent.signalAtUtc     = [string]$runnerEnd.signalAtUtc
            $lossEvent.silentSeconds   = [long]$runnerEnd.silentSeconds
            $lossEvent.terminalProgram = [string]$PreviousRunner['terminalProgram']
            $lossEvent.sshSession      = [bool]$PreviousRunner['sshSession']
        }
        Send-BootRecoveryEvent -RuntimeDir $RuntimeDir -EventRecord $lossEvent
    }

    return @{
        cycleFolder        = Split-Path -Leaf $finalCycleDir
        archivedAs         = if ($archivedPath) { Split-Path -Leaf $archivedPath } else { $null }
        signal             = $markerObj['recoverySignal']
        markerCycleStartUtc      = if ($markerObj.Contains('cycleStartUtc'))      { [string]$markerObj['cycleStartUtc'] }      else { $null }
        markerStartedAtUtc = if ($markerObj.Contains('startedAtUtc')) { [string]$markerObj['startedAtUtc'] } else { $null }
        markerPid          = if ($markerObj.Contains('pid'))          { [int]$markerObj['pid'] }            else { 0 }
        hostRestarted      = [bool]$restart.hostRestarted
        lastWriteUtc       = [string]$restart.lastWriteUtc
        bootUtc            = [string]$restart.bootUtc
        downSeconds        = $restart.downSeconds
        evidenceFiles      = @($evidence.evidenceFiles)
        endedBy            = if ($runnerEnd) { [string]$runnerEnd.endedBy } else { $null }
        runnerStateSaved   = $runnerStateSaved
    }
}

function Clear-StalePidFile {
    <#
    .SYNOPSIS
        Delete a pidfile when its pid is not a live process.
    .DESCRIPTION
        Reads the pidfile, looks up the process, and removes the
        pidfile (plus its companion if -CompanionPath is given) when
        the process is gone -- OR when the PID is live but its StartTime
        does not match the recorded companion StartTime, i.e. the OS
        recycled a dead prior occupant's PID onto an unrelated process
        (the failure mode that silently blocks crash takeover on a
        long-uptime host). A self-PID is left alone; so is a live PID
        that cannot be disproven (no companion StartTime recorded, or
        the live StartTime is unreadable), because a false clear would
        drop a genuinely live runner's pidfile -- worse than a missed
        reclaim. Identity precedence mirrors Get-RunnerInstanceState.
        Returns the pid that was cleared, or $null when no clear happened.
    .PARAMETER PidFile
        Absolute path to the pidfile (runner.pid, inner.pid, etc.).
    .PARAMETER CompanionPath
        Optional companion file to delete alongside the pidfile (e.g.
        runner.start for runner.pid). Removed only when the pidfile
        itself is cleared.
    .OUTPUTS
        [hashtable] describing what was cleared, or $null when no-op.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$PidFile,
        [string]$CompanionPath,
        # Service pidfiles (server.pid / config-server.pid) have no .start
        # companion; opt into using the pidfile's own mtime as the launch
        # reference so a live PID recycled onto an unrelated process is still
        # cleared (a genuine owner started at/before the mtime it then wrote).
        [switch]$MtimeIdentity
    )
    if (-not (Test-Path -LiteralPath $PidFile)) { return $null }
    if (-not $PSCmdlet.ShouldProcess($PidFile, (Format-YurunaOperatorMessage -Key 'runner.operator_1826536dca2a0287'))) { return $null }
    $filePid = 0
    try { $filePid = [int]((Get-Content -LiteralPath $PidFile -Raw -ErrorAction Stop).Trim()) }
    catch { $filePid = 0 }
    if ($filePid -le 0) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        # Take the companion with it: an orphan runner.start left behind
        # feeds the next launch a StartTime for a pid that no longer
        # exists, recreating the half-state the pairing exists to prevent.
        if ($CompanionPath -and (Test-Path -LiteralPath $CompanionPath)) {
            Remove-Item -LiteralPath $CompanionPath -Force -ErrorAction SilentlyContinue
        }
        return @{ pidFile = (Split-Path -Leaf $PidFile); stalePid = 0; reason = 'unparseable' }
    }
    if ($filePid -eq $PID) { return $null }
    $proc = Get-Process -Id $filePid -ErrorAction SilentlyContinue
    $recycled = $false
    if ($proc) {
        # See https://yuruna.link/4213a0b3-00d8
        $recordedStart = $null
        if ($CompanionPath -and (Test-Path -LiteralPath $CompanionPath)) {
            try {
                $rawStart = (Get-Content -LiteralPath $CompanionPath -Raw -ErrorAction Stop).Trim()
                if ($rawStart) { $recordedStart = [DateTimeOffset]::Parse($rawStart).UtcDateTime }
            } catch {
                Write-Verbose "Clear-StalePidFile: companion StartTime parse failed at $CompanionPath ($($_.Exception.Message))."
            }
        }
        $liveStart = $null
        try { $liveStart = $proc.StartTime.ToUniversalTime() }
        catch { Write-Verbose "Clear-StalePidFile: live StartTime unreadable for pid $filePid ($($_.Exception.Message))." }
        if ($null -ne $recordedStart) {
            # Companion StartTime recorded: it is the exact launch time, so a
            # match within 2s is the genuine owner; a mismatch is a recycle.
            if ($null -eq $liveStart) { return $null }
            if ([Math]::Abs(($recordedStart - $liveStart).TotalSeconds) -le 2) { return $null }
            $recycled = $true
        } elseif ($MtimeIdentity) {
            # No companion, but the caller opted into pidfile-mtime identity: a
            # genuine owner started at/before the mtime it then wrote; a PID that
            # started later is a recycle. Keep on start<=mtime, clear otherwise.
            if ($null -eq $liveStart) { return $null }
            $mtimeUtc = $null
            try { $mtimeUtc = (Get-Item -LiteralPath $PidFile -ErrorAction Stop).LastWriteTime.ToUniversalTime() }
            catch { return $null }
            if ($liveStart -le $mtimeUtc.AddSeconds(2)) { return $null }
            $recycled = $true
        } else {
            # Live PID that cannot be disproven (no companion, no mtime opt-in)
            # -> stay conservative and treat it as live.
            return $null
        }
    }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    if ($CompanionPath -and (Test-Path -LiteralPath $CompanionPath)) {
        Remove-Item -LiteralPath $CompanionPath -Force -ErrorAction SilentlyContinue
    }
    return @{
        pidFile  = (Split-Path -Leaf $PidFile)
        stalePid = $filePid
        reason   = if ($recycled) { 'pid_recycled' } else { 'process_not_running' }
    }
}

function Resolve-StaleBreakActive {
    <#
    .SYNOPSIS
        Archive a break-active.json left over from a crashed cycle.
    .DESCRIPTION
        A `break` action writes break-active.json while paused; the
        action's resume path deletes it. If the runner crashed while
        paused, the file survives and the next cycle's first step
        sees a parked breakpoint that nobody is waiting on. This
        helper renames the file to `break-active.<UTC>.json.aborted`
        so an operator can still audit what was paused.
    .PARAMETER RuntimeDir
        Path to test/status/runtime/.
    .OUTPUTS
        [hashtable] describing the archived file, or $null on no-op.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$RuntimeDir)
    $path = Join-Path $RuntimeDir 'break-active.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    if (-not $PSCmdlet.ShouldProcess($path, (Format-YurunaOperatorMessage -Key 'runner.operator_6b84ccbde66f6a97'))) { return $null }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH-mm-ssZ', [Globalization.CultureInfo]::InvariantCulture)
    $archived = Join-Path $RuntimeDir "break-active.$stamp.json.aborted"
    try {
        Move-Item -LiteralPath $path -Destination $archived -Force -ErrorAction Stop
    } catch {
        Write-Verbose "Resolve-StaleBreakActive: rename failed: $($_.Exception.Message)"
        return $null
    }
    return @{
        archivedAs = Split-Path -Leaf $archived
    }
}

function Clear-StalePauseFlag {
    <#
    .SYNOPSIS
        Delete leftover control.step-pause / control.cycle-pause /
        control.pause flags, and any parked lab hold, so a fresh runner
        launch never starts paused.
    .DESCRIPTION
        The status UI's pause endpoints write these flags into
        $RuntimeDir; the play endpoint deletes them. If the operator
        paused a prior cycle and then crashed or killed the runner
        before clicking play, the flags persist and the NEXT runner
        launch would start paused -- confusing the operator, who
        never clicked pause on this fresh run. Entry-point scripts
        call this at startup to enforce the policy "a new command
        line never inherits a prior session's pause state".

        The lab hold (control.lab-hold, its lab-hold.json sidecar and
        control.lab-hold-release) is swept on the same policy: a runner
        killed mid-hold would otherwise start the next session already
        parked on a verdict nothing has re-checked. The gate re-probes
        within a step of starting and re-raises the hold if the service
        is still away, so nothing is lost by clearing it.

        lab-health.json is deliberately NOT swept. It is the record of
        what this host has reached, not parked state, and clearing it
        would disarm the gate for a service the lab has been using.
    .PARAMETER RuntimeDir
        test/status/runtime/. Defaults to $env:YURUNA_RUNTIME_DIR.
    .OUTPUTS
        [hashtable] { cleared = string[]; records = hashtable[] } listing
        the basenames that were removed and, for each, when it was set
        (Get-StalePauseFlagRecord), or $null when no flag was present.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR)
    if (-not $RuntimeDir -or -not (Test-Path -LiteralPath $RuntimeDir)) { return $null }
    if (-not $PSCmdlet.ShouldProcess($RuntimeDir, (Format-YurunaOperatorMessage -Key 'runner.operator_358a2fac95f69915'))) { return $null }
    $cleared = @()
    $records = @()
    foreach ($flag in @('control.step-pause', 'control.cycle-pause', 'control.pause',
                        'control.lab-hold', 'lab-hold.json', 'control.lab-hold-release')) {
        $path = Join-Path $RuntimeDir $flag
        if (Test-Path -LiteralPath $path) {
            # Read before the removal destroys it.
            $record = Get-StalePauseFlagRecord -Path $path
            try {
                Remove-Item -LiteralPath $path -Force -ErrorAction Stop
                $cleared += $flag
                $records += $record
            } catch {
                Write-Verbose "Clear-StalePauseFlag: failed to remove $flag : $($_.Exception.Message)"
            }
        }
    }
    if ($cleared.Count -gt 0) { return @{ cleared = $cleared; records = $records } }
    return $null
}

function Get-StalePauseFlagRecord {
    <#
    .SYNOPSIS
        A flag's name and when it was set: the time it records, and its file time.
    .DESCRIPTION
        Without the time, a flag the sweep cleared cannot be told apart: a
        pause left from a maintenance window days ago and one set seconds
        before the runner died read the same. The status service writes the
        request time into the pause and release flags, and the lab gate
        writes when its hold began into lab-hold.json; recordedAtUtc is that
        time, absent when the flag holds none (control.lab-hold holds the
        area list). fileWrittenAtUtc is the file's own last write, kept
        either way. Both are UTC round-trip text. A read that fails only
        leaves the field out.
    .OUTPUTS
        [System.Collections.Specialized.OrderedDictionary] name, and the
        times that could be read.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string]$Path)
    $record = [ordered]@{ name = Split-Path -Leaf $Path }
    $written = $null
    try {
        $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $written = $file.LastWriteTimeUtc.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        if ($file.Length -le 65536) {
            $stamp = [IO.File]::ReadAllText($file.FullName).Trim()
            if ($stamp.StartsWith('{')) {
                $jsonOption = $script:RecoveryJsonOption
                $since = ($stamp | ConvertFrom-Json @jsonOption -ErrorAction Stop).since
                $stamp = if ($since -is [datetime]) { $since.ToUniversalTime().ToString('o') } else { [string]$since }
            }
            $parsed = [DateTimeOffset]::MinValue
            if ($stamp -and [DateTimeOffset]::TryParse($stamp, [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
                $record.recordedAtUtc = $parsed.UtcDateTime.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            }
        }
    } catch {
        Write-Verbose "Get-StalePauseFlagRecord: $Path unreadable: $($_.Exception.Message)"
    }
    if ($written) { $record.fileWrittenAtUtc = $written }
    return $record
}

function Clear-StaleControlState {
    <#
    .SYNOPSIS
        Sweep the stale inter-cycle control-state flags a starting entry
        point must not inherit, for a given lifecycle scope.
    .DESCRIPTION
        The status service writes control flags into $RuntimeDir to steer
        a running cycle: control.cycle-restart (rewind to step 1),
        control.step-pause / control.cycle-pause / control.pause and the
        lab hold (hold),
        and break-active.json (a parked breakpoint). A session killed
        before consuming a flag leaves it behind, and the NEXT session
        would then wake to a request the operator never made for it.

        This is the single place the three flag-classes are swept, keyed
        by -Scope so a caller cannot hand-pick an inconsistent subset:

          Startup  -- a fresh top-level entry point that IS the restart
                      the operator just asked for: consume
                      control.cycle-restart. Interactive parked state
                      (break-active + pause flags) is also cleared unless
                      -SkipInteractiveState is passed.
          PreSpawn -- an entry point about to hand off to a child cycle
                      it spawns: clear the interactive parked state so
                      the child does not inherit it, but leave
                      control.cycle-restart for the child to consume as
                      ITS own restart.

        -SkipInteractiveState narrows Startup to control.cycle-restart
        only. It exists for the spawned inner, whose interactive parked
        state is already swept by its parent (the outer's boot recovery
        or a PreSpawn caller); re-sweeping it would clear a pause the
        operator set on a direct-invoke inner.

        Best-effort: a failed removal is recorded, not thrown, so a
        single locked/permission-denied flag can never block the launch.
    .PARAMETER Scope
        Startup | PreSpawn (see above).
    .PARAMETER SkipInteractiveState
        Startup-only: consume control.cycle-restart but leave break-active
        and pause flags untouched.
    .PARAMETER RuntimeDir
        test/status/runtime/. Defaults to $env:YURUNA_RUNTIME_DIR.
    .PARAMETER RefreshPreservation
        A chain resumed after a host refresh: neither scope consumes
        control.cycle-restart or sweeps interactive state; the controls
        present are reported under preserved and left for their consumers.
    .OUTPUTS
        [hashtable] {
            cycleRestartCleared = [bool]
            cycleRestartAgeSeconds = [int] or $null  (age of the consumed flag)
            breakActive = archive result or $null
            pauseFlags = string[] basenames cleared
            preserved = string[] control basenames left in place (refresh preservation)
            warnings = string[]
        }
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateSet('Startup','PreSpawn')][string]$Scope,
        [switch]$SkipInteractiveState,
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [switch]$RefreshPreservation
    )
    $summary = @{
        cycleRestartCleared    = $false
        cycleRestartAgeSeconds = $null
        breakActive            = $null
        pauseFlags             = @()
        preserved              = @()
        warnings               = @()
    }
    if (-not $RuntimeDir -or -not (Test-Path -LiteralPath $RuntimeDir)) { return $summary }
    if ($RefreshPreservation) {
        $summary.preserved = @($script:RefreshPreservedControlName + @('break-active.json') | Where-Object {
            Test-Path -LiteralPath (Join-Path $RuntimeDir $_)
        })
        return $summary
    }
    if (-not $PSCmdlet.ShouldProcess($RuntimeDir, (Format-YurunaOperatorMessage -Key 'runner.operator_deee2e46013a9e37' -Arguments @{ scope = "$Scope" }))) { return $summary }

    # control.cycle-restart: only a Startup caller IS the restart, so only
    # Startup consumes it. A PreSpawn caller leaves it for the child cycle.
    if ($Scope -eq 'Startup') {
        $restartFlag = Join-Path $RuntimeDir 'control.cycle-restart'
        if (Test-Path -LiteralPath $restartFlag) {
            try {
                $age = (Get-Date) - (Get-Item -LiteralPath $restartFlag).LastWriteTime
                $summary.cycleRestartAgeSeconds = [int]$age.TotalSeconds
            } catch { $summary.cycleRestartAgeSeconds = $null }
            try {
                Remove-Item -LiteralPath $restartFlag -Force -ErrorAction Stop
                $summary.cycleRestartCleared = $true
            } catch {
                $summary.warnings += "control.cycle-restart clear failed: $($_.Exception.Message)"
            }
        }
    }

    # Interactive parked state (break-active + pause flags). Swept for
    # PreSpawn always, and for Startup unless the caller opts out.
    $sweepInteractive = ($Scope -eq 'PreSpawn') -or (-not $SkipInteractiveState)
    if ($sweepInteractive) {
        try {
            $archivedBreak = Resolve-StaleBreakActive -RuntimeDir $RuntimeDir -Confirm:$false
            if ($archivedBreak) { $summary.breakActive = $archivedBreak }
        } catch {
            $summary.warnings += "Resolve-StaleBreakActive failed: $($_.Exception.Message)"
        }
        try {
            $clearedPause = Clear-StalePauseFlag -RuntimeDir $RuntimeDir -Confirm:$false
            if ($clearedPause -and $clearedPause.cleared) { $summary.pauseFlags = @($clearedPause.cleared) }
        } catch {
            $summary.warnings += "Clear-StalePauseFlag failed: $($_.Exception.Message)"
        }
    }

    return $summary
}

function ConvertTo-YurunaRecoveryIdentity {
    <#
    .SYNOPSIS
        { Pid; StartTimeUnixMs } from a hashtable or object in either key
        spelling, or $null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([AllowNull()]$Identity)
    if ($null -eq $Identity) { return $null }
    $read = {
        param([string[]]$Names)
        foreach ($name in $Names) {
            if ($Identity -is [System.Collections.IDictionary]) {
                if ($Identity.Contains($name)) { return $Identity[$name] }
            } elseif ($Identity.PSObject.Properties[$name]) {
                return $Identity.$name
            }
        }
        return $null
    }
    $idPid = & $read @('Pid', 'pid')
    if ($null -eq $idPid -or [int]$idPid -le 0) { return $null }
    $idStart = & $read @('StartTimeUnixMs', 'startTimeUnixMs')
    return [pscustomobject]@{ Pid = [int]$idPid; StartTimeUnixMs = if ($null -ne $idStart) { [long]$idStart } else { $null } }
}

function Invoke-YurunaRefreshPreservationSweep {
    <#
    .SYNOPSIS
        The refresh-preservation half of Invoke-YurunaBootRecovery.
    .DESCRIPTION
        Every removal needs positive proof, and anything that cannot be
        classified is preserved and reported: the strict classifier and
        removal come from Test.SingleInstance, and without them nothing is
        removed at all.
    .OUTPUTS
        [hashtable] the completed summary.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Summary,
        [AllowEmptyString()][string]$RuntimeDir,
        [AllowEmptyString()][string]$LogDir,
        [AllowNull()][psobject]$ReclaimedInner,
        [AllowNull()][psobject]$ProcessTable
    )
    $Summary.Mode = 'refresh-preservation'
    $strict = @('Get-YurunaProcessTable', 'Get-YurunaRunnerRecordState', 'Remove-YurunaRunnerRecordGeneration', 'Get-YurunaProcessIdentityState')
    $available = @($strict | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue }).Count -eq $strict.Count
    if (-not $available) {
        $Summary.Warnings += 'refresh preservation: strict identity helpers unavailable; nothing removed'
    }
    $table = $null
    if ($available) {
        $table = if ($ProcessTable) { $ProcessTable } else { Get-YurunaProcessTable }
    }
    $innerState = $null
    if ($RuntimeDir -and (Test-Path -LiteralPath $RuntimeDir)) {
        $innerPidFile   = Join-Path $RuntimeDir 'inner.pid'
        $innerStartFile = Join-Path $RuntimeDir 'inner.start'
        if ($available) {
            $innerState = Get-YurunaRunnerRecordState -PidFile $innerPidFile -StartFile $innerStartFile -ProcessTable $table
            if ($innerState.State -eq 'DeadOrRecycled' -and $PSCmdlet.ShouldProcess($innerPidFile, (Format-YurunaOperatorMessage -Key 'runner.operator_1826536dca2a0287'))) {
                $removal = Remove-YurunaRunnerRecordGeneration -PidFile $innerPidFile -StartFile $innerStartFile -Fingerprint ([string]$innerState.Fingerprint) -Confirm:$false
                if ($removal.Removed) {
                    $Summary.ClearedPidFiles += @{ pidFile = 'inner.pid'; stalePid = [int]$innerState.Pid; reason = [string]$innerState.Reason }
                } else {
                    $Summary.PreservedPidFiles += @{ file = 'inner.pid'; state = "removal-$($removal.Reason)" }
                }
            } elseif ($innerState.State -ne 'Missing') {
                $Summary.PreservedPidFiles += @{ file = 'inner.pid'; state = [string]$innerState.State }
            }
        } elseif (Test-Path -LiteralPath $innerPidFile) {
            $Summary.PreservedPidFiles += @{ file = 'inner.pid'; state = 'Unknown' }
        }
        foreach ($entry in @(@{ file = 'runner.pid'; state = 'deferred' }, @{ file = 'server.pid'; state = 'untouched' }, @{ file = 'config-server.pid'; state = 'untouched' })) {
            if (Test-Path -LiteralPath (Join-Path $RuntimeDir $entry.file)) { $Summary.PreservedPidFiles += $entry }
        }
        $reclaimed = ConvertTo-YurunaRecoveryIdentity -Identity $ReclaimedInner
        if ($available -and $reclaimed -and (Test-Path -LiteralPath (Join-Path $RuntimeDir 'break-active.json'))) {
            $identity = @{ ProcessId = $reclaimed.Pid; ProcessTable = $table; SelfPid = -1 }
            if ($null -ne $reclaimed.StartTimeUnixMs) { $identity.RecordedStartTimeUnixMs = $reclaimed.StartTimeUnixMs }
            $reclaimedState = Get-YurunaProcessIdentityState @identity
            if ($reclaimedState.State -eq 'DeadOrRecycled' -and $innerState -and $innerState.State -ne 'AliveOwned') {
                try {
                    $archivedBreak = Resolve-StaleBreakActive -RuntimeDir $RuntimeDir -Confirm:$false
                    if ($archivedBreak) { $Summary.ArchivedBreakActive = $archivedBreak }
                } catch {
                    $Summary.Warnings += "Resolve-StaleBreakActive failed: $($_.Exception.Message)"
                }
            }
        }
        $Summary.PreservedControls = @($script:RefreshPreservedControlName | Where-Object { Test-Path -LiteralPath (Join-Path $RuntimeDir $_) })
    }
    if ($LogDir -and (Test-Path -LiteralPath $LogDir)) {
        foreach ($marker in (Find-OrphanIncompleteCycle -LogDir $LogDir)) {
            $archive = $false
            if ($available -and $marker -is [System.IO.FileInfo]) {
                try {
                    $doc = Get-Content -LiteralPath $marker.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                    $writerPid = 0
                    if ($doc -and [int]::TryParse([string]$doc.pid, [ref]$writerPid) -and $writerPid -gt 0) {
                        $identity = @{ ProcessId = $writerPid; ProcessTable = $table; SelfPid = -1 }
                        $written = [datetime]::MinValue
                        $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
                        if ($doc.startedAtUtc -is [datetime]) {
                            $identity.RecordWrittenUtc = ([datetime]$doc.startedAtUtc).ToUniversalTime()
                        } elseif ([datetime]::TryParse([string]$doc.startedAtUtc, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$written)) {
                            $identity.RecordWrittenUtc = $written
                        }
                        $archive = ((Get-YurunaProcessIdentityState @identity).State -eq 'DeadOrRecycled')
                    }
                } catch {
                    $Summary.Warnings += "orphan marker unreadable ($($marker.FullName)): $($_.Exception.Message)"
                }
            }
            if (-not $archive) {
                $Summary.PreservedOrphans += $marker.FullName
                continue
            }
            try {
                $archived = Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -RuntimeDir $RuntimeDir -Confirm:$false
                if ($archived) { $Summary.ArchivedCycles += $archived }
            } catch {
                $Summary.Warnings += "Resolve-OrphanIncompleteCycle failed for $($marker.FullName): $($_.Exception.Message)"
            }
        }
    }
    $Summary.CompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $touched = ($Summary.ArchivedCycles.Count -gt 0) -or ($Summary.ClearedPidFiles.Count -gt 0) -or
        ($null -ne $Summary.ArchivedBreakActive) -or ($Summary.Warnings.Count -gt 0) -or
        ($Summary.PreservedControls.Count -gt 0) -or ($Summary.PreservedPidFiles.Count -gt 0) -or ($Summary.PreservedOrphans.Count -gt 0)
    if ($touched) {
        Send-BootRecoveryEvent -RuntimeDir $RuntimeDir -EventRecord @{
            timestamp              = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
            event                  = 'boot_recovery_completed'
            mode                   = 'refresh-preservation'
            archivedCycleCount     = [int]$Summary.ArchivedCycles.Count
            clearedPidFileCount    = [int]$Summary.ClearedPidFiles.Count
            archivedBreakActive    = [bool]($null -ne $Summary.ArchivedBreakActive)
            clearedPauseFlagCount  = 0
            preservedControlCount  = [int]$Summary.PreservedControls.Count
            preservedPidFileCount  = [int]$Summary.PreservedPidFiles.Count
            preservedOrphanCount   = [int]$Summary.PreservedOrphans.Count
            warningCount           = [int]$Summary.Warnings.Count
            startedAtUtc           = [string]$Summary.StartedAtUtc
            completedAtUtc         = [string]$Summary.CompletedAtUtc
        }
    }
    if ($Summary.PreservedControls.Count -gt 0 -or $Summary.PreservedPidFiles.Count -gt 0) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.boot_recovery_preserved_controls' -Arguments @{
            count = "$($Summary.PreservedControls.Count)"; pidCount = "$($Summary.PreservedPidFiles.Count)" }) -InformationAction Continue
    }
    return $Summary
}

function Invoke-YurunaBootRecovery {
    <#
    .SYNOPSIS
        Top-level sweep. Called once at outer startup; resolves every
        stale state class found and emits a single
        `boot_recovery_completed` NDJSON event with the summary.
    .DESCRIPTION
        Idempotent and best-effort: any sub-step's failure surfaces as
        a Write-Warning but never aborts the sweep. A future-cycle
        call sees the prior pass's archived markers and skips them
        (already-resolved markers no longer have `.incomplete`).

        Order:
          1. Stale pidfiles (delete; pid is dead, or -- for the service
             pidfiles that carry no .start companion -- a live PID that
             provably recycled onto an unrelated process, judged by the
             pidfile's own mtime)
          2. Stale break-active.json (archive)
          3. Stale pause flags (delete; a fresh launch never inherits
             a prior session's pause request)
          4. Orphan `.incomplete` cycle folders (archive markers)

        Pidfiles go first because a stale runner.pid would otherwise
        confuse downstream callers that read it before the sweep gets
        a chance.
    .PARAMETER RuntimeDir
        test/status/runtime/. Defaults to $env:YURUNA_RUNTIME_DIR.
    .PARAMETER LogDir
        test/status/log/. Defaults to $env:YURUNA_LOG_DIR.
    .PARAMETER RefreshPreservation
        Sweep for a runner restarted by a host refresh: no pause, hold or
        restart sweep; inner.pid removed only as a generation proven dead;
        runner.pid deferred to the resume path; server.pid and
        config-server.pid untouched; break-active.json archived only for a
        dead reclaimed inner; an orphaned cycle archived only when its
        writer is proven gone.
    .PARAMETER ReclaimedInner
        { Pid; StartTimeUnixMs } of the inner the refresh reclaimed.
    .PARAMETER ProcessTable
        A process-table snapshot for the preservation mode's checks; one is
        taken when omitted.
    .OUTPUTS
        Hashtable summary: ArchivedCycles, ClearedPidFiles,
        ArchivedBreakActive, ClearedPauseFlags (basenames) with
        ClearedPauseFlagRecords (when each was set), Warnings,
        StartedAtUtc, CompletedAtUtc, Mode (default|refresh-preservation),
        PreservedControls, PreservedPidFiles ({ file; state }),
        PreservedOrphans, PreviousRunner: what the previous runner's
        session and exit records say (Get-YurunaRunnerExitReport), or $null,
        and PreviousRunnerAbsent: why PreviousRunner is $null
        (no-session-record, unreadable, or same-process when the records
        carry this process's pid and start time, Test-RunnerSessionOwnRecord).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [string]$RuntimeDir = $env:YURUNA_RUNTIME_DIR,
        [string]$LogDir     = $env:YURUNA_LOG_DIR,
        [switch]$RefreshPreservation,
        [psobject]$ReclaimedInner,
        [psobject]$ProcessTable
    )
    $summary = @{
        StartedAtUtc        = (Get-Date).ToUniversalTime().ToString('o')
        ArchivedCycles      = @()
        ClearedPidFiles     = @()
        ArchivedBreakActive = $null
        ClearedPauseFlags   = @()
        ClearedPauseFlagRecords = @()
        Warnings            = @()
        Mode                = 'default'
        PreservedControls   = @()
        PreservedPidFiles   = @()
        PreservedOrphans    = @()
    }
    if (-not $PSCmdlet.ShouldProcess((Format-YurunaOperatorMessage -Key 'runner.operator_d46434d3b554dbcc'), (Format-YurunaOperatorMessage -Key 'runner.operator_8412fad70c1a7049'))) {
        $summary.CompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        return $summary
    }
    if ($RefreshPreservation) {
        return (Invoke-YurunaRefreshPreservationSweep -Summary $summary -RuntimeDir $RuntimeDir -LogDir $LogDir `
            -ReclaimedInner $ReclaimedInner -ProcessTable $ProcessTable)
    }

    # Read before the sweep clears runner.pid and before this runner replaces
    # the records: they say how the previous runner was started and what
    # ended it, which nothing else keeps once it is gone. The progress
    # sidecars are read here too, before this runner's first inner reseeds
    # them: they name the step the previous runner's last cycle was in.
    $summary.PreviousRunner = $null
    $summary.PreviousRunnerAbsent = 'no-session-record'
    $runnerState = $null
    if ($RuntimeDir -and (Test-Path -LiteralPath $RuntimeDir)) {
        try {
            $absence = $null
            $report = Get-YurunaRunnerExitReport -RuntimeDir $RuntimeDir -AbsenceReason ([ref]$absence)
            if (-not $report) {
                $summary.PreviousRunnerAbsent = if ($absence) { $absence } else { 'unreadable' }
            } elseif (Test-RunnerSessionOwnRecord -Report $report) {
                $summary.PreviousRunnerAbsent = 'same-process'
            } else {
                $summary.PreviousRunner = Get-YurunaRunnerExitReport -RuntimeDir $RuntimeDir -HostBootUtc (Get-YurunaHostBootTimeUtc)
                $summary.PreviousRunnerAbsent = if ($summary.PreviousRunner) { $null } else { 'unreadable' }
            }
        } catch {
            $summary.Warnings += "Get-YurunaRunnerExitReport failed: $($_.Exception.Message)"
            $summary.PreviousRunnerAbsent = 'unreadable'
        }
        $runnerState = Read-RunnerProgressSidecar -RuntimeDir $RuntimeDir
    }

    if ($RuntimeDir -and (Test-Path -LiteralPath $RuntimeDir)) {
        # Pidfiles. inner.pid has no companion sidecar; runner.pid pairs
        # with runner.start (StartTime sidecar from Write-RunnerPidFile).
        foreach ($entry in @(
            @{ pid = 'inner.pid';         companion = $null;          mtimeIdentity = $false },
            @{ pid = 'runner.pid';        companion = 'runner.start';  mtimeIdentity = $false },
            # Service pidfiles have no .start sidecar, so use pidfile-mtime
            # identity: a stale server.pid / config-server.pid must not survive a
            # reboot, where the OS can recycle the old PID onto the freshly
            # launched runner and a kill path would otherwise take it down.
            @{ pid = 'server.pid';        companion = $null;          mtimeIdentity = $true },
            @{ pid = 'config-server.pid'; companion = $null;          mtimeIdentity = $true }
        )) {
            try {
                $companion = if ($entry.companion) { Join-Path $RuntimeDir $entry.companion } else { $null }
                $cleared = Clear-StalePidFile -PidFile (Join-Path $RuntimeDir $entry.pid) -CompanionPath $companion -MtimeIdentity:$entry.mtimeIdentity -Confirm:$false
                if ($cleared) { $summary.ClearedPidFiles += $cleared }
            } catch {
                $summary.Warnings += "Clear-StalePidFile failed for $($entry.pid): $($_.Exception.Message)"
            }
        }
        try {
            $archivedBreak = Resolve-StaleBreakActive -RuntimeDir $RuntimeDir -Confirm:$false
            if ($archivedBreak) { $summary.ArchivedBreakActive = $archivedBreak }
        } catch {
            $summary.Warnings += "Resolve-StaleBreakActive failed: $($_.Exception.Message)"
        }
        try {
            $clearedPause = Clear-StalePauseFlag -RuntimeDir $RuntimeDir -Confirm:$false
            if ($clearedPause -and $clearedPause.cleared) {
                $summary.ClearedPauseFlags = @($clearedPause.cleared)
                $summary.ClearedPauseFlagRecords = @($clearedPause.records)
            }
        } catch {
            $summary.Warnings += "Clear-StalePauseFlag failed: $($_.Exception.Message)"
        }
    }

    if ($LogDir -and (Test-Path -LiteralPath $LogDir)) {
        # Newest first, by the start time in the folder name: the signal and
        # the sidecars belong to the latest cycle that was running when they
        # were written, so an older orphan is offered only what no newer one
        # claimed.
        $unclaimedRunner = $summary.PreviousRunner
        $unclaimedState = $runnerState
        $orphans = @(Find-OrphanIncompleteCycle -LogDir $LogDir | Sort-Object -Descending -Property {
            $leaf = if ($_ -is [IO.FileInfo]) { $_.Directory.Name } else { $_.Name }
            $leaf -replace '^\d+\.', '' })
        foreach ($marker in $orphans) {
            try {
                $archived = Resolve-OrphanIncompleteCycle -MarkerPath $marker.FullName -RuntimeDir $RuntimeDir `
                    -PreviousRunner $unclaimedRunner -RunnerState $unclaimedState -Confirm:$false
                if ($archived) {
                    $summary.ArchivedCycles += $archived
                    if ($archived.endedBy) { $unclaimedRunner = $null }
                    if ($archived.runnerStateSaved) { $unclaimedState = $null }
                }
            } catch {
                $summary.Warnings += "Resolve-OrphanIncompleteCycle failed for $($marker.FullName): $($_.Exception.Message)"
            }
        }
    }

    $summary.CompletedAtUtc = (Get-Date).ToUniversalTime().ToString('o')

    # Emit NDJSON breadcrumb iff there's something to report. The clean-
    # boot case (no orphans, no stale pids, no break-active) stays silent
    # so a healthy host doesn't flood cycle.events.ndjson with no-op
    # recovery events.
    $touched = ($summary.ArchivedCycles.Count -gt 0) -or
               ($summary.ClearedPidFiles.Count -gt 0) -or
               ($null -ne $summary.ArchivedBreakActive) -or
               ($summary.ClearedPauseFlags.Count -gt 0) -or
               ($summary.Warnings.Count -gt 0)
    if ($touched) {
        $completed = @{
            timestamp             = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
            event                 = 'boot_recovery_completed'
            archivedCycleCount    = [int]$summary.ArchivedCycles.Count
            clearedPidFileCount   = [int]$summary.ClearedPidFiles.Count
            archivedBreakActive   = [bool]($null -ne $summary.ArchivedBreakActive)
            clearedPauseFlagCount = [int]$summary.ClearedPauseFlags.Count
            # Which flags those were and when each was set: a pause the
            # operator left from a maintenance window reads as a stale
            # session's leftover only by its time.
            clearedPauseFlags     = @($summary.ClearedPauseFlagRecords)
            warningCount          = [int]$summary.Warnings.Count
            startedAtUtc          = [string]$summary.StartedAtUtc
            completedAtUtc        = [string]$summary.CompletedAtUtc
        }
        if ($summary.PreviousRunner) { $completed.previousRunner = $summary.PreviousRunner }
        elseif ($summary.PreviousRunnerAbsent) { $completed.previousRunnerAbsent = [string]$summary.PreviousRunnerAbsent }
        Send-BootRecoveryEvent -RuntimeDir $RuntimeDir -EventRecord $completed
    }
    if ($touched) {
        Write-Information (Format-YurunaOperatorMessage -Key 'runner.operator_052fdf620b9d9d43' -FormatValues ($summary.ArchivedCycles.Count,
            $summary.ClearedPidFiles.Count,
            ($null -ne $summary.ArchivedBreakActive),
            $summary.ClearedPauseFlags.Count,
            $summary.Warnings.Count) -FormatBindings @{ count = '0'; count2 = '1'; archivedBreakActive = '2'; count3 = '3'; count4 = '4' }) -InformationAction Continue
    }
    return $summary
}

Export-ModuleMember -Function Get-YurunaHostBootTimeUtc, Invoke-YurunaBootRecovery, Find-OrphanIncompleteCycle, Resolve-OrphanIncompleteCycle, Clear-StalePidFile, Resolve-StaleBreakActive, Clear-StalePauseFlag, Clear-StaleControlState
