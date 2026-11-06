<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42f8b2a8-0c1c-45bf-b7d3-7239488c88e5
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host macos.utm driver capture serial monitor
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

# --- REGION: Serial console capture
# See https://yuruna.link/42885ada-0014
# The Ubuntu templates give the guest's UART a loopback TCP server that never
# waits for a client (Get-UtmConsolePortFromBundle), and QEMU drops what the
# guest writes while no client is attached. The reader is armed before the VM
# powers on, reconnects across restarts and appends to a log in the VM's
# folder of the cycle log, so a guest that wedged and then passed after a cold
# restart still leaves what it printed before the restart.

# One segment of the live log. A full segment becomes serial-console.1.log,
# replacing the one before it, so the folder keeps the newest one to two.
$script:UtmSerialCaptureSegmentBytes = 4MB
# How much of the live log a control snapshot copies beside itself.
$script:UtmSerialConsoleTailBytes = 256KB

<#
.SYNOPSIS
    The files of a VM's serial capture in the running cycle's evidence folder,
    or $null when no cycle is running.
.DESCRIPTION
    Built from the VM name alone, so the arming, the snapshot and the failure
    collection find the same files after the driver is re-imported.
#>
function Get-VMSerialCapturePath {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$VMName)
    if ($VMName -notmatch '^[A-Za-z0-9._-]+$' -or $VMName -in @('.', '..')) { return $null }
    $root = Get-UtmEvidenceDirectory
    if (-not $root) { return $null }
    $directory = Join-Path $root $VMName
    return [pscustomobject]@{
        Directory = $directory
        Log       = Join-Path $directory 'serial-console.log'
        Previous  = Join-Path $directory 'serial-console.1.log'
        State     = Join-Path $directory 'serial-console.reader.json'
    }
}

# The reader is a job named after the VM. Initialize-YurunaHost re-imports the
# driver with -Force when the sequence engine loads, which drops this module's
# variables but not the session's jobs, so every path finds the reader by name.
function Get-VMSerialCaptureJob {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$VMName)
    $name = "yuruna-serial-$VMName"
    return @(Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $name })
}
function Stop-VMSerialCaptureJob {
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Stops reader jobs of this process; changes no durable system state, and must never prompt inside a runner cycle.')]
    param([Parameter(Mandatory)][string]$VMName)
    foreach ($job in (Get-VMSerialCaptureJob -VMName $VMName)) {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
}
# The reader's own account, from the sidecar it rewrites at each change of
# state; $null when there is none or it cannot be parsed.
function Get-VMSerialCaptureReader {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not [System.IO.File]::Exists($Path)) { return $null }
    try {
        return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop)
    } catch {
        Write-Verbose "Serial console reader state unreadable at $Path`: $($_.Exception.Message)"
        return $null
    }
}

<#
.SYNOPSIS
    The newest bytes a VM's serial capture keeps: serial-console.1.log, then
    serial-console.log, as the guest sent them.
.DESCRIPTION
    Right after a rollover the live log holds almost nothing, and what the
    guest printed before it is in the rolled segment, so the newest bytes are
    taken across both. They are copied, never decoded: firmware output is not
    always valid UTF-8. The live log is opened first, so a rollover between
    the two opens repeats bytes rather than dropping the newest ones.
.OUTPUTS
    [pscustomobject] Bytes (at most -MaxBytes), FromPrevious (how many of
    them came from the rolled segment), LogBytes and PreviousLogBytes (each
    file's length when it was opened) and Truncated (older bytes were left
    out).
#>
function Get-VMSerialCaptureTail {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][pscustomobject]$Paths,
        [Parameter(Mandatory)][ValidateRange(0, 67108864)][long]$MaxBytes
    )
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    $log = $null
    $previous = $null
    try {
        if ([System.IO.File]::Exists($Paths.Log)) { $log = [System.IO.FileStream]::new($Paths.Log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share) }
        if ([System.IO.File]::Exists($Paths.Previous)) { $previous = [System.IO.FileStream]::new($Paths.Previous, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share) }
        $logBytes = if ($log) { $log.Length } else { 0L }
        $previousBytes = if ($previous) { $previous.Length } else { 0L }
        $fromLog = [Math]::Min($logBytes, $MaxBytes)
        $tail = [System.IO.MemoryStream]::new()
        $buffer = [byte[]]::new(65536)
        # The last $Take bytes before $Length, the length taken at the open:
        # the reader may append meanwhile.
        $copyTail = {
            param($Stream, [long]$Length, [long]$Take)
            if ($Take -le 0) { return }
            $null = $Stream.Seek($Length - $Take, [System.IO.SeekOrigin]::Begin)
            while ($Take -gt 0) {
                $read = $Stream.Read($buffer, 0, [int][Math]::Min($buffer.Length, $Take))
                if ($read -le 0) { break }
                $tail.Write($buffer, 0, $read)
                $Take -= $read
            }
        }
        & $copyTail $previous $previousBytes ([Math]::Min($previousBytes, $MaxBytes - $fromLog))
        $fromPrevious = $tail.Length
        & $copyTail $log $logBytes $fromLog
        return [pscustomobject]@{
            Bytes = $tail.ToArray(); FromPrevious = [long]$fromPrevious; LogBytes = [long]$logBytes; PreviousLogBytes = [long]$previousBytes
            Truncated = ($logBytes + $previousBytes) -gt $tail.Length
        }
    } finally {
        if ($log) { $log.Dispose() }
        if ($previous) { $previous.Dispose() }
    }
}

<#
.SYNOPSIS
    Arm a reader on the VM's serial console port that appends what the guest
    writes to serial-console.log in the VM's evidence folder.
.DESCRIPTION
    A reader already running for the same port and log is kept: it reconnects
    by itself when the VM restarts, and replacing it would open a gap in which
    QEMU drops the guest's output. A reader for another port -- a start that
    moved the VNC display moved the console ports with it -- is replaced, and
    the new one appends to the same log.

    The job calls no module function and holds only a client socket and the
    log. It keeps reading for as long as it is connected, past a full segment
    included: QEMU's UART model can block on a write to a connected client
    that stops draining, which would hold the guest's console. It ends when
    stopped by name, or when the evidence folder is gone because the cycle is
    over.
.OUTPUTS
    [bool] $true when a reader is running for the VM's serial console.
#>
function Start-VMSerialCapture {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic capture: reads a loopback socket into the cycle folder, changes no durable system state, and must never prompt inside a runner cycle.')]
    param([Parameter(Mandatory)][string]$VMName)
    try {
        $port = [int](Get-UtmConsolePortFromBundle -VMName $VMName).Serial
        if ($port -le 0) {
            Write-Verbose "Serial console capture: '$VMName' has no serial console port; nothing to read."
            return $false
        }
        $paths = Get-VMSerialCapturePath -VMName $VMName
        if (-not $paths) {
            Write-Verbose "Serial console capture: no cycle folder holds '$VMName' evidence; nothing armed."
            return $false
        }
        foreach ($job in (Get-VMSerialCaptureJob -VMName $VMName)) {
            if ([string]$job.State -notin @('Running', 'NotStarted')) { continue }
            $reader = Get-VMSerialCaptureReader -Path $paths.State
            if ($reader -and [int]$reader.port -eq $port -and [string]$reader.logPath -eq $paths.Log) {
                Write-Verbose "Serial console capture for '$VMName' already reads 127.0.0.1:$port."
                return $true
            }
        }
        Stop-VMSerialCaptureJob -VMName $VMName
        $null = New-Item -ItemType Directory -Force -Path $paths.Directory
        $logPath = $paths.Log
        $previousPath = $paths.Previous
        $statePath = $paths.State
        $segmentBytes = [long]$script:UtmSerialCaptureSegmentBytes
        # Written before the job starts, so an arming moments later already
        # finds which port and log this reader serves.
        $armed = [ordered]@{
            port = $port; logPath = $logPath; armedUtc = [DateTime]::UtcNow.ToString('o'); connectAttempts = 0; connectedCount = 0
            lastConnectUtc = $null; lastDisconnectUtc = $null; lastError = $null; bytesRead = 0L; rotations = 0; updatedUtc = $null
        }
        [System.IO.File]::WriteAllText($statePath, ($armed | ConvertTo-Json -Compress))
        $null = Start-Job -Name "yuruna-serial-$VMName" -ScriptBlock {
            $Port = $using:port
            $LogPath = $using:logPath
            $PreviousPath = $using:previousPath
            $StatePath = $using:statePath
            $SegmentBytes = $using:segmentBytes
            $state = [ordered]@{
                port = $Port; logPath = $LogPath; armedUtc = [DateTime]::UtcNow.ToString('o'); connectAttempts = 0; connectedCount = 0
                lastConnectUtc = $null; lastDisconnectUtc = $null; lastError = $null; bytesRead = 0L; rotations = 0; updatedUtc = $null
            }
            $directory = [System.IO.Path]::GetDirectoryName($LogPath)
            $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $buffer = [byte[]]::new(16384)
            $sinceSave = [System.Diagnostics.Stopwatch]::StartNew()
            $save = {
                $state.updatedUtc = [DateTime]::UtcNow.ToString('o')
                try { [System.IO.File]::WriteAllText($StatePath, ($state | ConvertTo-Json -Compress)) }
                catch { $state.lastError = "state: $($_.Exception.Message)" }
                $sinceSave.Restart()
            }
            & $save
            # No finally block anywhere in this loop: PowerShell drops a Stop-Job
            # that arrives while one runs, and Stop-Job then waits two minutes.
            while ([System.IO.Directory]::Exists($directory)) {
                $client = $null
                $file = $null
                $connected = $false
                $pause = $false
                try {
                    $state.connectAttempts++
                    $client = [System.Net.Sockets.TcpClient]::new([System.Net.Sockets.AddressFamily]::InterNetwork)
                    if (-not $client.ConnectAsync([System.Net.IPAddress]::Loopback, $Port).Wait(2000)) {
                        throw [System.TimeoutException]::new("127.0.0.1:$Port accepted no connection within 2 s")
                    }
                    $stream = $client.GetStream()
                    $file = [System.IO.FileStream]::new($LogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, $share)
                    $connected = $true
                    $state.connectedCount++
                    $state.lastConnectUtc = [DateTime]::UtcNow.ToString('o')
                    & $save
                    while ($true) {
                        # A job parked in a blocking read does not see Stop-Job, which
                        # then waits two minutes, so the wait for data is bounded.
                        if (-not $client.Client.Poll(500000, [System.Net.Sockets.SelectMode]::SelectRead)) { continue }
                        $read = $stream.Read($buffer, 0, $buffer.Length)
                        if ($read -le 0) { break }
                        if ($file.Length -gt 0 -and $file.Length + $read -gt $SegmentBytes) {
                            $file.Dispose()
                            [System.IO.File]::Move($LogPath, $PreviousPath, $true)
                            $file = [System.IO.FileStream]::new($LogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, $share)
                            $state.rotations++
                        }
                        $file.Write($buffer, 0, $read)
                        $file.Flush()
                        $firstBytes = ($state.bytesRead -eq 0)
                        $state.bytesRead += $read
                        if ($firstBytes -or $sinceSave.Elapsed.TotalSeconds -ge 30) { & $save }
                    }
                    $state.lastDisconnectUtc = [DateTime]::UtcNow.ToString('o')
                    & $save
                } catch {
                    # .NET failures arrive wrapped in a MethodInvocationException or
                    # an AggregateException; the innermost one is the reading.
                    $failure = $_.Exception
                    while ($failure.InnerException) { $failure = $failure.InnerException }
                    $text = "$($failure.GetType().Name): $($failure.Message)"
                    if ($connected) { $state.lastDisconnectUtc = [DateTime]::UtcNow.ToString('o') }
                    # A refused connection repeats four times a second while the VM is
                    # down; the sidecar records each new error and a current count.
                    if ($connected -or $text -ne $state.lastError -or $sinceSave.Elapsed.TotalSeconds -ge 30) {
                        $state.lastError = $text
                        & $save
                    }
                    $pause = $true
                }
                if ($file) { $file.Dispose() }
                if ($client) { $client.Dispose() }
                if ($pause) { Start-Sleep -Milliseconds 250 }
            }
        }
        Write-Verbose "Serial console capture armed for '$VMName' on 127.0.0.1:$port -> $logPath"
        return $true
    } catch {
        Write-Verbose "Start-VMSerialCapture failed: $($_.Exception.Message)"
        return $false
    }
}

<#
.SYNOPSIS
    Stop the VM's serial reader (the no-failure path); its log stays in the
    VM's evidence folder.
.DESCRIPTION
    The log is kept: a guest that recovered, through a cold restart for
    instance, may still have printed why it needed one.
.OUTPUTS
    [bool] $true when no reader is left running for the VM.
#>
function Stop-VMSerialCapture {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic teardown: stops a reader job of this process; must never prompt inside a runner cycle.')]
    param([Parameter(Mandatory)][string]$VMName)
    try {
        Stop-VMSerialCaptureJob -VMName $VMName
        return ((Get-VMSerialCaptureJob -VMName $VMName).Count -eq 0)
    } catch {
        Write-Verbose "Stop-VMSerialCapture failed: $($_.Exception.Message)"
        return $false
    }
}

<#
.SYNOPSIS
    Stop the serial reader and keep its log and its account in the failure
    folder (the failure path).
.DESCRIPTION
    The saved serial-console.log is the whole capture, the rolled segment
    joined in front of the live one, because the runner reads that one file
    for the guest kernel's reports, as it does the Hyper-V capture
    (Save-SerialConsoleKernelFault): a report that rolled over would
    otherwise be missing from a reading that says it covers the log. In the
    VM's evidence folder the two segments become that log; another
    -OutputDirectory gets a joined copy and the evidence folder keeps its
    segments. Either way the log is held to the newest two segments, so a
    VM saved more than once in a cycle cannot grow it.

    serial-console.info.txt carries the reader's account -- port, bytes and
    how many of them came from the rolled segment, connects, attempts, the
    last error -- so a log that is missing or empty still says whether the
    reader ever reached the port.
.OUTPUTS
    [bool] $true when a log with content was kept.
#>
function Save-VMSerialCapture {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic collection: stops a reader job and copies its files into the failure folder; must never prompt inside a runner cycle.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    try {
        $paths = Get-VMSerialCapturePath -VMName $VMName
        if (-not $paths) { return $false }
        $armed = (Get-VMSerialCaptureJob -VMName $VMName).Count -gt 0
        Stop-VMSerialCaptureJob -VMName $VMName
        if (-not $armed -and -not [System.IO.File]::Exists($paths.State) -and -not [System.IO.File]::Exists($paths.Log) -and
            -not [System.IO.File]::Exists($paths.Previous)) { return $false }
        if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
            $null = New-Item -ItemType Directory -Force -Path $OutputDirectory
        }
        # Read before the join below rewrites the live log.
        $lastByte = '(none)'
        foreach ($segment in @($paths.Log, $paths.Previous)) {
            $segmentFile = [System.IO.FileInfo]::new($segment)
            if ($segmentFile.Exists -and $segmentFile.Length -gt 0) {
                $lastByte = $segmentFile.LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                break
            }
        }
        $comparison = if ($IsLinux) { [System.StringComparison]::Ordinal } else { [System.StringComparison]::OrdinalIgnoreCase }
        $here = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($OutputDirectory))
        $live = [System.IO.Path]::TrimEndingDirectorySeparator([System.IO.Path]::GetFullPath($paths.Directory))
        $inPlace = [string]::Equals($here, $live, $comparison)
        $saved = Join-Path $OutputDirectory 'serial-console.log'
        $previousBytes = 0L
        if (-not $inPlace -or [System.IO.File]::Exists($paths.Previous)) {
            try {
                $capture = Get-VMSerialCaptureTail -Paths $paths -MaxBytes (2 * [long]$script:UtmSerialCaptureSegmentBytes)
                if ($inPlace) {
                    # Written beside the log and moved over it, so a write that
                    # fails leaves both segments as they were.
                    $joining = "$($paths.Log).joining"
                    [System.IO.File]::WriteAllBytes($joining, $capture.Bytes)
                    [System.IO.File]::Move($joining, $paths.Log, $true)
                    $previousBytes = $capture.FromPrevious
                    [System.IO.File]::Delete($paths.Previous)
                } elseif ($capture.Bytes.Length -gt 0) {
                    [System.IO.File]::WriteAllBytes($saved, $capture.Bytes)
                    $previousBytes = $capture.FromPrevious
                }
            } catch {
                Write-Verbose "Save-VMSerialCapture did not join the serial log segments of '$VMName': $($_.Exception.Message)"
            }
            if (-not $inPlace -and [System.IO.File]::Exists($paths.State)) {
                Copy-Item -LiteralPath $paths.State -Destination (Join-Path $OutputDirectory 'serial-console.reader.json') -Force
            }
        }
        $bytes = if ([System.IO.File]::Exists($saved)) { [System.IO.FileInfo]::new($saved).Length } else { 0L }
        $reader = Get-VMSerialCaptureReader -Path $paths.State
        $info = [string[]]@(
            "vmName:            $VMName"
            "port:              127.0.0.1:$(if ($reader) { $reader.port } else { '' })"
            "bytes:             $bytes"
            "lastByte:          $lastByte"
            "previousBytes:     $previousBytes"
            "rotations:         $(if ($reader) { $reader.rotations } else { 0 })"
            "savedUtc:          $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture))"
            "armedUtc:          $(if ($reader) { $reader.armedUtc } else { '' })"
            "connects:          $(if ($reader) { $reader.connectedCount } else { 0 })"
            "attempts:          $(if ($reader) { $reader.connectAttempts } else { 0 })"
            "lastConnectUtc:    $(if ($reader) { $reader.lastConnectUtc } else { '' })"
            "lastDisconnectUtc: $(if ($reader) { $reader.lastDisconnectUtc } else { '' })"
            "lastError:         $(if ($reader) { $reader.lastError } else { '' })"
        )
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'serial-console.info.txt') -Encoding utf8NoBOM -Value $info
        return ($bytes -gt 0)
    } catch {
        Write-Verbose "Save-VMSerialCapture failed: $($_.Exception.Message)"
        return $false
    }
}

<#
.SYNOPSIS
    Read the live serial capture of a VM without disturbing its reader.
.DESCRIPTION
    Opens the file the reader appends to with sharing that lets the reader
    keep writing, and returns the bytes after -FromOffset, at most -MaxBytes
    of the newest. A file shorter than -FromOffset rolled over or was replaced
    after the offset was taken: it is read from its start and marked Replaced,
    because it no longer holds what came before. -MaxBytes 0 returns only the
    length; a capture whose reader has not created the file yet marks 0.

    Not exported: the sequence engine finds this verb by name, would then
    take step marks on this host, and could end a wait on a kernel report
    read from them, which waits on this host have never done.
.OUTPUTS
    [pscustomobject] Length, Offset, Text, Truncated and Replaced; $null when
    no capture exists to read or it cannot be read.
#>
function Read-VMSerialCapture {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [ValidateRange(0, [long]::MaxValue)][long]$FromOffset = 0,
        [ValidateRange(0, 16777216)][int]$MaxBytes = 4194304
    )
    $paths = Get-VMSerialCapturePath -VMName $VMName
    if (-not $paths) { return $null }
    if (-not [System.IO.File]::Exists($paths.Log)) {
        if ($MaxBytes -eq 0 -and [System.IO.File]::Exists($paths.State)) {
            return [pscustomobject]@{ Length = 0L; Offset = 0L; Text = ''; Truncated = $false; Replaced = $false }
        }
        return $null
    }
    try {
        $stream = [System.IO.FileStream]::new($paths.Log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            $length = $stream.Length
            if ($MaxBytes -eq 0) { return [pscustomobject]@{ Length = $length; Offset = $length; Text = ''; Truncated = $false; Replaced = $false } }
            $replaced = $FromOffset -gt $length
            $start = if ($replaced) { 0L } else { $FromOffset }
            $truncated = ($length - $start) -gt $MaxBytes
            if ($truncated) { $start = $length - $MaxBytes }
            $text = ''
            $count = [int]($length - $start)
            if ($count -gt 0) {
                $bytes = [byte[]]::new($count)
                $null = $stream.Seek($start, [System.IO.SeekOrigin]::Begin)
                $read = 0
                while ($read -lt $count) {
                    $chunk = $stream.Read($bytes, $read, $count - $read)
                    if ($chunk -le 0) { break }
                    $read += $chunk
                }
                $text = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $read)
            }
            return [pscustomobject]@{ Length = $length; Offset = $start; Text = $text; Truncated = $truncated; Replaced = $replaced }
        } finally { $stream.Dispose() }
    } catch {
        Write-Verbose "Read-VMSerialCapture failed: $($_.Exception.Message)"
        return $null
    }
}

<#
.SYNOPSIS
    Copy the newest part of a VM's serial capture beside a control snapshot,
    and say where the live log is and how long it was at that moment.
.DESCRIPTION
    The live log keeps growing after the snapshot, through the cold restart
    that usually follows, and rolls over at its segment size, so the snapshot
    keeps its own copy of what the guest printed up to that moment: the
    newest bytes across the rolled segment and the live log, byte for byte
    (Get-VMSerialCaptureTail). logBytes is where the restart begins in the
    live log; log is the live log's path relative to -OutputDirectory, which
    survives the rename of the cycle folder when the cycle ends.
.OUTPUTS
    [ordered] outcome ('saved' | 'empty' | 'no-capture' | 'failed'), reason,
    log, logBytes, previousLogBytes, path, tailBytes, truncated and reader
    (the reader's own account, or $null).
#>
function Save-UtmSerialConsoleTail {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic collection: writes one evidence file beside a snapshot whose caller owns the confirmation.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9.-]{0,63}$')][string]$Trigger
    )
    $result = [ordered]@{
        outcome = 'no-capture'; reason = ''; log = ''; logBytes = 0L; previousLogBytes = 0L
        path = ''; tailBytes = 0L; truncated = $false; reader = $null
    }
    try {
        $paths = Get-VMSerialCapturePath -VMName $VMName
        if (-not $paths) { return $result }
        $result.reader = Get-VMSerialCaptureReader -Path $paths.State
        if (-not [System.IO.File]::Exists($paths.Log) -and -not [System.IO.File]::Exists($paths.Previous)) { return $result }
        $tail = Get-VMSerialCaptureTail -Paths $paths -MaxBytes $script:UtmSerialConsoleTailBytes
        $result.log = [System.IO.Path]::GetRelativePath($OutputDirectory, $paths.Log)
        $result.logBytes = $tail.LogBytes
        $result.previousLogBytes = $tail.PreviousLogBytes
        $result.truncated = [bool]$tail.Truncated
        if ($tail.Bytes.Length -eq 0) {
            $result.outcome = 'empty'
            return $result
        }
        if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
            $null = New-Item -ItemType Directory -Force -Path $OutputDirectory
        }
        $path = Join-Path $OutputDirectory "serial-console.$Trigger.log"
        [System.IO.File]::WriteAllBytes($path, $tail.Bytes)
        $result.path = $path
        $result.tailBytes = [long]$tail.Bytes.Length
        $result.outcome = 'saved'
    } catch {
        $result.outcome = 'failed'
        $result.reason = $_.Exception.Message
    }
    return $result
}

# --- REGION: QEMU monitor capture
function ConvertFrom-UtmMonitorReply {
    <#
    .SYNOPSIS
        The text of one QEMU monitor reply: terminal escapes removed, the
        echoed command dropped, and the closing prompt removed.
    .DESCRIPTION
        The monitor's line editor redraws the line after every byte it
        receives, so the echo of a command arrives as cursor movements around
        each prefix of it, and everything before the first line break is that
        echo. The banner sent on connection has no echo to drop.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Text, [switch]$Banner)
    $clean = [regex]::Replace($Text, '\x1b\[[0-9;?]*[ -/]*[@-~]', '')
    $clean = [regex]::Replace($clean, '\x1b[@-Z\\-_]', '')
    $clean = $clean.Replace("`r", '')
    if (-not $Banner) {
        $lineEnd = $clean.IndexOf("`n")
        $clean = if ($lineEnd -ge 0) { $clean.Substring($lineEnd + 1) } else { '' }
    }
    if ($clean.EndsWith('(qemu) ')) { $clean = $clean.Substring(0, $clean.Length - '(qemu) '.Length) }
    return [regex]::Replace($clean, '[\x00-\x08\x0B-\x1F\x7F]', '')
}

<#
.SYNOPSIS
    Ask the VM's QEMU monitor for its run state, its virtual CPUs and every
    CPU's registers, into qemu-monitor.<trigger>.txt.
.DESCRIPTION
    A guest that burns the host's CPU behind a dark display leaves nothing on
    its console; the registers say where each virtual CPU is executing, and
    only until the VM restarts. The monitor is QEMU's human monitor on the
    loopback port the Ubuntu templates configure: one client at a time, and a
    '(qemu) ' prompt after the banner and after every answer.

    Every step is bounded -- the connection, the banner and each command --
    and the whole call by -TimeoutSeconds and -Deadline, so a QEMU whose main
    loop stopped costs seconds rather than the snapshot. A command that does
    not answer ends the capture, because the commands after it would only
    queue behind it. Nothing is thrown; the outcome is in the result.
.PARAMETER Port
    The monitor port (Get-UtmConsolePortFromBundle); 0 or less means the VM
    has no monitor and nothing is attempted.
.PARAMETER Deadline
    Optional shared deadline (New-YurunaDeadline).
.OUTPUTS
    [ordered] port, outcome ('captured' | 'partial' | 'no-answer' |
    'no-prompt' | 'unreachable' | 'not-configured' | 'deadline-exhausted' |
    'failed'), reason, path, elapsedMs and commands (command, outcome,
    elapsedMs, bytes).
#>
function Save-UtmQemuMonitorCapture {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic collection: reads the monitor and writes one evidence file beside a snapshot whose caller owns the confirmation.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9.-]{0,63}$')][string]$Trigger,
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10,
        $Deadline
    )
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = [ordered]@{ port = $Port; outcome = 'not-configured'; reason = ''; path = ''; elapsedMs = 0L; commands = @() }
    if ($Port -le 0) { return $result }
    $budget = Get-UtmChildDeadline -Milliseconds ([long]$TimeoutSeconds * 1000) -Parent $Deadline
    if ((Get-YurunaDeadlineRemainingMs -Deadline $budget) -lt 500) {
        $result.outcome = 'deadline-exhausted'
        return $result
    }
    # Each step's own bound; the remaining budget caps every one of them.
    $steps = @(
        @{ Command = 'info status'; Milliseconds = 2000 }
        @{ Command = 'info cpus'; Milliseconds = 2000 }
        @{ Command = 'info registers -a'; Milliseconds = 5000 }
    )
    $prompt = [System.Text.Encoding]::ASCII.GetBytes('(qemu) ')
    $buffer = [byte[]]::new(16384)
    $commands = [System.Collections.Generic.List[object]]::new()
    $transcript = [System.Text.StringBuilder]::new()
    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new([System.Net.Sockets.AddressFamily]::InterNetwork)
        $connected = $false
        try {
            $connectMilliseconds = [int][Math]::Min(2000, (Get-YurunaDeadlineRemainingMs -Deadline $budget))
            $connected = $client.ConnectAsync([System.Net.IPAddress]::Loopback, $Port).Wait($connectMilliseconds)
            if (-not $connected) { $result.reason = "TimeoutException: 127.0.0.1:$Port accepted no connection within $connectMilliseconds ms" }
        } catch {
            $failure = $_.Exception
            while ($failure.InnerException) { $failure = $failure.InnerException }
            $result.reason = "$($failure.GetType().Name): $($failure.Message)"
        }
        if (-not $connected) {
            $result.outcome = 'unreachable'
            return $result
        }
        $socket = $client.Client
        $readReply = {
            param([int]$Milliseconds)
            $wait = Get-UtmChildDeadline -Milliseconds $Milliseconds -Parent $budget
            $reply = [System.IO.MemoryStream]::new()
            $state = 'timeout'
            while (-not (Test-YurunaDeadlineExpired -Deadline $wait)) {
                $pollMicroseconds = [int][Math]::Min(200000, [Math]::Max(1000, (Get-YurunaDeadlineRemainingMs -Deadline $wait) * 1000))
                if (-not $socket.Poll($pollMicroseconds, [System.Net.Sockets.SelectMode]::SelectRead)) { continue }
                $count = 0
                try { $count = $socket.Receive($buffer) } catch { $result.reason = "Receive: $($_.Exception.Message)" }
                if ($count -le 0) { $state = 'closed'; break }
                $reply.Write($buffer, 0, $count)
                $bytes = $reply.GetBuffer()
                $end = [int]$reply.Length
                $prompted = $end -ge $prompt.Length
                for ($k = 1; $prompted -and $k -le $prompt.Length; $k++) { $prompted = $bytes[$end - $k] -eq $prompt[$prompt.Length - $k] }
                if ($prompted) { $state = 'answered'; break }
                if ($end -ge 1MB) { $state = 'too-long'; break }
            }
            return [pscustomobject]@{ State = $state; Text = [System.Text.Encoding]::UTF8.GetString($reply.GetBuffer(), 0, [int]$reply.Length) }
        }
        $banner = & $readReply 3000
        [void]$transcript.Append((ConvertFrom-UtmMonitorReply -Text $banner.Text -Banner))
        $answered = 0
        $stopped = $banner.State -ne 'answered'
        foreach ($step in $steps) {
            $entry = [ordered]@{ command = $step.Command; outcome = 'not-sent'; elapsedMs = 0L; bytes = 0L }
            if (-not $stopped -and (Get-YurunaDeadlineRemainingMs -Deadline $budget) -gt 0) {
                $commandClock = [System.Diagnostics.Stopwatch]::StartNew()
                $null = $socket.Send([System.Text.Encoding]::ASCII.GetBytes("$($step.Command)`n"))
                $reply = & $readReply $step.Milliseconds
                $entry.outcome = $reply.State
                $entry.elapsedMs = [long]$commandClock.ElapsedMilliseconds
                $entry.bytes = [long][System.Text.Encoding]::UTF8.GetByteCount($reply.Text)
                [void]$transcript.Append("`n(qemu) $($step.Command)`n").Append((ConvertFrom-UtmMonitorReply -Text $reply.Text))
                if ($reply.State -eq 'answered') { $answered++ }
                else {
                    [void]$transcript.Append("`n[$($reply.State) after $($entry.elapsedMs) ms]`n")
                    $stopped = $true
                }
            } else { $stopped = $true }
            $commands.Add($entry)
        }
        $result.outcome = if ($banner.State -ne 'answered') { 'no-prompt' }
            elseif ($answered -eq $steps.Count) { 'captured' }
            elseif ($answered -gt 0) { 'partial' }
            else { 'no-answer' }
        if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
            $null = New-Item -ItemType Directory -Force -Path $OutputDirectory
        }
        $path = Join-Path $OutputDirectory "qemu-monitor.$Trigger.txt"
        $header = "vmName: $VMName`nport: 127.0.0.1:$Port`nobservedUtc: $([DateTime]::UtcNow.ToString('o'))`noutcome: $($result.outcome)`n`n"
        [System.IO.File]::WriteAllText($path, $header + $transcript.ToString().TrimEnd() + "`n", [System.Text.UTF8Encoding]::new($false))
        $result.path = $path
    } catch {
        $result.outcome = 'failed'
        $result.reason = $_.Exception.Message
    } finally {
        if ($client) { $client.Dispose() }
        $result.commands = @($commands)
        $result.elapsedMs = [long]$stopwatch.ElapsedMilliseconds
    }
    return $result
}
