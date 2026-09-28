<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42e8abe9-fab4-421a-90ab-caa2e130911b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test critical-record durability host-refresh
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
Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Common.psm1') -DisableNameChecking

# Checksummed, generation-numbered private records with a retained previous
# generation, for state that authorizes a mutation: a request journal, a
# recovery record, a runner gate, a budget reservation. Best-effort progress
# files (Test.StateFile) may lose a write and only degrade reporting; losing
# or tearing one of these must instead refuse the mutation it guarded, so the
# contract is stricter:
#
#   * A write goes to a new temporary file, is flushed and read back before
#     it replaces the record, and the replaced generation is kept as
#     <Path>.prev. A crash at any point leaves either the old generation or
#     the new one readable, never a torn mix.
#   * Every record carries its kind, a generation number and a SHA-256 of its
#     payload, so a truncated or bit-flipped file is detected and the reader
#     falls back to the previous generation instead of trusting it.
#   * A writer states the generation it read (compare-and-set); a stale
#     writer is refused rather than silently overwriting a newer decision.
#   * A newer format version or another record's kind is never replaced by an
#     older generation: that is a refusal, not a fallback.
#
# Atomic replacement protects against a process crash. Surviving a power cut
# also needs the data and the directory entry flushed to stable storage; the
# flushes are issued (fsync on Linux, F_FULLFSYNC on macOS, write-through
# rename on Windows) and reported through FlushesConfirmed, but no platform
# claims power-loss durability until a power-cut test has shown it holds, so
# Get-YurunaCriticalRecordDurability declares process-crash everywhere.
#
# Every blocking file operation runs on a compiled helper's task and is waited
# on with a bounded Task.Wait, so a wedged file system turns into io-timeout
# instead of a hang. A timed-out task keeps its pool thread (a blocked kernel
# call cannot be canceled); the per-step caps keep that count small.

$script:CriticalRecordIoTypeName = 'Yuruna.CriticalRecordIoV2'
$script:CriticalRecordIoUnavailable = $false
$script:CriticalRecordFormat = 'yuruna.critical-record'
$script:CriticalRecordVersion = 1
$script:CriticalRecordKindPattern = '^[a-z][a-z0-9.-]{0,63}$'
# Longest header line accepted, excluding its LF.
$script:CriticalRecordHeaderMaxBytes = 4096
# ConvertFrom-Json turns ISO-8601-looking strings into [DateTime] unless told
# not to (-DateKind String, PowerShell 7.5 and later); a record must hand back
# the strings it was given.
$script:CriticalRecordJsonOption = @{}
if ((Get-Command -Name ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $script:CriticalRecordJsonOption.DateKind = 'String' }
# Reasons a current file can fail that are corruption of its bytes, where the
# previous generation is a trustworthy substitute.
$script:CriticalRecordIntegrityReason = @('too-large', 'malformed-header', 'truncated', 'checksum-mismatch', 'malformed-payload')
# One entry per platform: flipping a platform to power-loss durability is a
# single edit here, after a power-cut test on that platform.
$script:CriticalRecordDurability = @{
    linux   = @{ DataFlush = 'fsync'; DirectoryCommit = 'fsync-directory'; PowerLossQualified = $false }
    macos   = @{ DataFlush = 'full-fsync'; DirectoryCommit = 'full-fsync-directory'; PowerLossQualified = $false }
    windows = @{ DataFlush = 'flush-file-buffers'; DirectoryCommit = 'write-through-rename'; PowerLossQualified = $false }
}

# A loaded type cannot be replaced inside a process, so a changed definition
# must also change the type name (and $script:CriticalRecordIoTypeName).
# F_FULLFSYNC and open() are declared with two fixed arguments: their third,
# variadic argument is unused for these calls, and declaring it fixed would
# pass it in the wrong place under the Apple arm64 variadic convention.
$script:CriticalRecordIoSource = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace Yuruna
{
    public static class CriticalRecordIoV2
    {
        [DllImport("libc", SetLastError = true, EntryPoint = "open")]
        private static extern int PosixOpen(string path, int flags);

        [DllImport("libc", SetLastError = true, EntryPoint = "fsync")]
        private static extern int PosixFsync(int descriptor);

        [DllImport("libc", SetLastError = true, EntryPoint = "fcntl")]
        private static extern int PosixFcntl(int descriptor, int command);

        [DllImport("libc", SetLastError = true, EntryPoint = "close")]
        private static extern int PosixClose(int descriptor);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "MoveFileExW")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);

        private const int OpenReadOnly = 0;
        private const int FullFsyncCommand = 51;
        private const int MoveReplaceExisting = 1;
        private const int MoveWriteThrough = 8;

        public static Task WriteNewFileAsync(string path, byte[] content)
        {
            return Task.Run(() =>
            {
                using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    stream.Write(content, 0, content.Length);
                    stream.Flush(false);
                }
            });
        }

        public static Task<int> FlushPathAsync(string path, bool isDirectory)
        {
            return Task.Run(() => FlushPath(path, isDirectory));
        }

        private static int FlushPath(string path, bool isDirectory)
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
            {
                if (isDirectory)
                {
                    return -2;
                }
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                {
                    stream.Flush(true);
                }
                return 0;
            }
            int descriptor = PosixOpen(path, OpenReadOnly);
            if (descriptor < 0)
            {
                return Math.Max(1, Marshal.GetLastWin32Error());
            }
            try
            {
                if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX) && PosixFcntl(descriptor, FullFsyncCommand) == 0)
                {
                    return 0;
                }
                if (PosixFsync(descriptor) == 0)
                {
                    return 0;
                }
                return Math.Max(1, Marshal.GetLastWin32Error());
            }
            finally
            {
                PosixClose(descriptor);
            }
        }

        public static Task<byte[]> ReadFileAsync(string path, int maxBytes)
        {
            return Task.Run(() =>
            {
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (stream.Length > maxBytes)
                    {
                        throw new InvalidDataException("too-large");
                    }
                    var buffer = new byte[stream.Length];
                    int total = 0;
                    while (total < buffer.Length)
                    {
                        int read = stream.Read(buffer, total, buffer.Length - total);
                        if (read <= 0)
                        {
                            break;
                        }
                        total += read;
                    }
                    if (total != buffer.Length)
                    {
                        Array.Resize(ref buffer, total);
                    }
                    return buffer;
                }
            });
        }

        public static Task<byte[]> ReadPrefixAsync(string path, int count)
        {
            return Task.Run(() =>
            {
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    var buffer = new byte[(int)Math.Min((long)count, stream.Length)];
                    int total = 0;
                    while (total < buffer.Length)
                    {
                        int read = stream.Read(buffer, total, buffer.Length - total);
                        if (read <= 0)
                        {
                            break;
                        }
                        total += read;
                    }
                    if (total != buffer.Length)
                    {
                        Array.Resize(ref buffer, total);
                    }
                    return buffer;
                }
            });
        }

        public static Task CopyFileAsync(string source, string destination)
        {
            return Task.Run(() => File.Copy(source, destination, false));
        }

        public static Task ReplaceFileAsync(string source, string destination)
        {
            return Task.Run(() =>
            {
                if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
                {
                    if (!MoveFileEx(source, destination, MoveReplaceExisting | MoveWriteThrough))
                    {
                        throw new IOException(destination, Marshal.GetHRForLastWin32Error());
                    }
                    return;
                }
                File.Move(source, destination, true);
            });
        }

        public static Task DeleteFileAsync(string path)
        {
            return Task.Run(() =>
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
            });
        }

        public static Task<int> RemoveOrphanTempFilesAsync(string directory, string leaf)
        {
            return Task.Run(() =>
            {
                var pattern = new Regex("^" + Regex.Escape(leaf) + @"(\.prev)?\.[0-9]+-[0-9a-f]{32}\.tmp$", RegexOptions.CultureInvariant);
                int removed = 0;
                foreach (var candidate in Directory.EnumerateFiles(directory))
                {
                    if (!pattern.IsMatch(Path.GetFileName(candidate)))
                    {
                        continue;
                    }
                    try
                    {
                        File.Delete(candidate);
                        removed++;
                    }
                    catch (IOException)
                    {
                    }
                    catch (UnauthorizedAccessException)
                    {
                    }
                }
                return removed;
            });
        }
    }
}
'@

function Get-YurunaCriticalRecordPlatform {
    <#
    .SYNOPSIS
        linux, macos or windows for the current process.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($IsWindows) { return 'windows' }
    if ($IsMacOS) { return 'macos' }
    return 'linux'
}

function Initialize-YurunaCriticalRecordIo {
    <#
    .SYNOPSIS
        Compile the bounded file-I/O helper once per process.
    .DESCRIPTION
        The compile costs a few hundred milliseconds in a fresh process, so a
        long-lived caller (the status listener) calls this at import to keep
        that cost off its first request. Later calls return at once. A
        failure is remembered for the life of the process, and writers and
        readers then refuse with io-error instead of retrying the compile.
    .OUTPUTS
        [bool] $true when the helper type is available.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($script:CriticalRecordIoTypeName -as [type]) { return $true }
    if ($script:CriticalRecordIoUnavailable) { return $false }
    try {
        Add-Type -TypeDefinition $script:CriticalRecordIoSource -Language CSharp -ErrorAction Stop
    } catch {
        Write-Verbose "Initialize-YurunaCriticalRecordIo: helper compile failed: $($_.Exception.Message)"
    }
    if ($script:CriticalRecordIoTypeName -as [type]) { return $true }
    $script:CriticalRecordIoUnavailable = $true
    return $false
}

function Wait-YurunaCriticalIoTask {
    <#
    .SYNOPSIS
        Wait a bounded time for one helper I/O task.
    .DESCRIPTION
        Never reads a result before the task is confirmed complete, so the
        wait cannot outlast its timeout. A task that times out keeps running
        on its pool thread; its eventual outcome is ignored.
    .PARAMETER Task
        The task a helper method returned.
    .PARAMETER TimeoutMilliseconds
        Longest wait.
    .PARAMETER Operation
        Which step the task belongs to, for diagnostics.
    .OUTPUTS
        [pscustomobject] @{ Completed; TimedOut; Result; Exception }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Threading.Tasks.Task]$Task,
        [Parameter(Mandatory)][ValidateRange(0, 3600000)][int]$TimeoutMilliseconds,
        [Parameter(Mandatory)][ValidateSet('write-temp', 'flush-temp', 'verify-temp', 'copy-previous', 'flush-previous',
            'verify-previous', 'replace-previous', 'replace-current', 'flush-directory', 'read', 'delete', 'sweep')]
        [string]$Operation
    )
    try { $null = $Task.Wait($TimeoutMilliseconds) } catch { $null = $_ }
    if (-not $Task.IsCompleted) {
        Write-Verbose "Wait-YurunaCriticalIoTask: '$Operation' did not finish within $TimeoutMilliseconds ms."
        return [pscustomobject]@{ Completed = $false; TimedOut = $true; Result = $null; Exception = $null }
    }
    if ($Task.IsFaulted -or $Task.IsCanceled) {
        $failure = if ($Task.Exception) { $Task.Exception.GetBaseException() } else { [System.OperationCanceledException]::new() }
        return [pscustomobject]@{ Completed = $true; TimedOut = $false; Result = $null; Exception = $failure }
    }
    $value = $null
    $property = $Task.GetType().GetProperty('Result')
    if ($null -ne $property -and $property.PropertyType.Name -ne 'VoidTaskResult') { $value = $property.GetValue($Task) }
    return [pscustomobject]@{ Completed = $true; TimedOut = $false; Result = $value; Exception = $null }
}

function Get-YurunaCriticalRecordDurability {
    <#
    .SYNOPSIS
        What a critical-record write does to reach stable storage on a
        platform, and which crash it is declared to survive.
    .DESCRIPTION
        A process crash is survived everywhere: the replace is atomic and the
        previous generation is retained. Power-loss durability is declared
        per platform only after a power-cut test shows the flushes below
        really reach the medium; atomic visibility to readers is not that
        evidence. No platform is declared today.
    .PARAMETER Platform
        linux, macos or windows; defaults to the current OS.
    .OUTPUTS
        [pscustomobject] @{ Platform; DataFlush; DirectoryCommit; PowerLossQualified; Claim process-crash|power-loss }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([ValidateSet('linux', 'macos', 'windows')][string]$Platform)
    if (-not $Platform) { $Platform = Get-YurunaCriticalRecordPlatform }
    $entry = $script:CriticalRecordDurability[$Platform]
    return [pscustomobject]@{
        Platform           = $Platform
        DataFlush          = $entry.DataFlush
        DirectoryCommit    = $entry.DirectoryCommit
        PowerLossQualified = [bool]$entry.PowerLossQualified
        Claim              = if ($entry.PowerLossQualified) { 'power-loss' } else { 'process-crash' }
    }
}

function ConvertTo-YurunaCriticalRecordByte {
    <#
    .SYNOPSIS
        Serialize one record: a compact ASCII JSON header line, LF, then the
        payload bytes the header describes.
    .OUTPUTS
        [byte[]]
    #>
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][long]$Generation,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$PayloadBytes
    )
    $digest = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($PayloadBytes)).ToLowerInvariant()
    $header = [ordered]@{
        format        = $script:CriticalRecordFormat
        version       = $script:CriticalRecordVersion
        kind          = $Kind
        generation    = $Generation
        payloadBytes  = $PayloadBytes.Length
        payloadSha256 = $digest
        writtenUtc    = [DateTime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        writerPid     = $PID
    }
    $headerBytes = [System.Text.Encoding]::ASCII.GetBytes((ConvertTo-Json -InputObject $header -Compress))
    $bytes = [byte[]]::new($headerBytes.Length + 1 + $PayloadBytes.Length)
    [Array]::Copy($headerBytes, 0, $bytes, 0, $headerBytes.Length)
    $bytes[$headerBytes.Length] = 10
    [Array]::Copy($PayloadBytes, 0, $bytes, $headerBytes.Length + 1, $PayloadBytes.Length)
    Write-Output -NoEnumerate -InputObject $bytes
}

function Test-YurunaCriticalRecordByte {
    <#
    .SYNOPSIS
        Validate one file's bytes as a record of the expected kind.
    .DESCRIPTION
        HeaderGeneration is reported from any header that parses, even when
        the payload fails its checksum, so a writer never reuses a
        generation number a damaged file already carried.
    .OUTPUTS
        [pscustomobject] @{ Valid; Reason; Generation; HeaderGeneration; Payload; WrittenUtc }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$Kind
    )
    $record = [ordered]@{ Valid = $false; Reason = 'malformed-header'; Generation = [long]0; HeaderGeneration = $null; Payload = $null; WrittenUtc = $null }
    $lineEnd = [Array]::IndexOf($Bytes, [byte]10)
    if ($lineEnd -lt 1 -or $lineEnd -gt $script:CriticalRecordHeaderMaxBytes) { return [pscustomobject]$record }
    $header = $null
    try {
        $jsonOption = $script:CriticalRecordJsonOption
        $header = ConvertFrom-Json -InputObject ([System.Text.Encoding]::ASCII.GetString($Bytes, 0, $lineEnd)) -AsHashtable -ErrorAction Stop @jsonOption
    } catch {
        return [pscustomobject]$record
    }
    if ($header -isnot [System.Collections.IDictionary] -or [string]$header['format'] -cne $script:CriticalRecordFormat) {
        return [pscustomobject]$record
    }
    $generation = $header['generation']
    if (($generation -is [long] -or $generation -is [int]) -and $generation -ge 1) { $record.HeaderGeneration = [long]$generation }
    $version = $header['version']
    if (-not ($version -is [long] -or $version -is [int])) { return [pscustomobject]$record }
    if ($version -ne $script:CriticalRecordVersion) { $record.Reason = 'unsupported-version'; return [pscustomobject]$record }
    if ([string]$header['kind'] -cne $Kind) { $record.Reason = 'kind-mismatch'; return [pscustomobject]$record }
    $declaredLength = $header['payloadBytes']
    $declaredDigest = [string]$header['payloadSha256']
    if ($null -eq $record.HeaderGeneration -or -not ($declaredLength -is [long] -or $declaredLength -is [int]) -or
        $declaredLength -lt 0 -or $declaredDigest -cnotmatch '^[0-9a-f]{64}$') {
        return [pscustomobject]$record
    }
    $payloadLength = $Bytes.Length - $lineEnd - 1
    if ($payloadLength -lt $declaredLength) { $record.Reason = 'truncated'; return [pscustomobject]$record }
    if ($payloadLength -gt $declaredLength) { $record.Reason = 'malformed-payload'; return [pscustomobject]$record }
    $payloadBytes = [byte[]]::new($payloadLength)
    [Array]::Copy($Bytes, $lineEnd + 1, $payloadBytes, 0, $payloadLength)
    $digest = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($payloadBytes)).ToLowerInvariant()
    if ($digest -cne $declaredDigest) { $record.Reason = 'checksum-mismatch'; return [pscustomobject]$record }
    $payload = $null
    try {
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($payloadBytes)
        $jsonOption = $script:CriticalRecordJsonOption
        $payload = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 64 -ErrorAction Stop @jsonOption
    } catch {
        $record.Reason = 'malformed-payload'
        return [pscustomobject]$record
    }
    if ($payload -isnot [System.Collections.IDictionary]) { $record.Reason = 'malformed-payload'; return [pscustomobject]$record }
    $record.Valid      = $true
    $record.Reason     = 'ok'
    $record.Generation = $record.HeaderGeneration
    $record.Payload    = $payload
    $written = $header['writtenUtc']
    $record.WrittenUtc = if ($written -is [DateTime]) {
        $written.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    } else { [string]$written }
    return [pscustomobject]$record
}

function Read-YurunaCriticalRecordOversize {
    <#
    .SYNOPSIS
        Classify a record file larger than MaxBytes from its header alone.
    .DESCRIPTION
        An oversized file is never trusted as a record, but its header still
        carries a generation number, and a writer that ignored it would hand
        the same number to the next generation. Only the header line is read.
        A header of a newer format version or of another kind keeps that
        reason, so an oversized file a newer writer produced is refused
        rather than replaced by the previous generation. When the header
        itself cannot be read the file is reported as an I/O failure, because
        its generation is then unknown.
    .OUTPUTS
        [pscustomobject] as Test-YurunaCriticalRecordByte, Valid $false, with
        Reason too-large, unsupported-version, kind-mismatch, missing,
        io-error or io-timeout.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Deadline
    )
    $record = [ordered]@{ Valid = $false; Reason = 'too-large'; Generation = [long]0; HeaderGeneration = $null; Payload = $null; WrittenUtc = $null }
    $remaining = Get-YurunaDeadlineRemainingMs -Deadline $Deadline
    if ($remaining -le 0) { $record.Reason = 'io-timeout'; return [pscustomobject]$record }
    $io = $script:CriticalRecordIoTypeName -as [type]
    $wait = Wait-YurunaCriticalIoTask -Task ($io::ReadPrefixAsync($Path, $script:CriticalRecordHeaderMaxBytes + 1)) -Operation 'read' `
        -TimeoutMilliseconds ([int][Math]::Min([long]5000, $remaining))
    if ($wait.TimedOut) { $record.Reason = 'io-timeout'; return [pscustomobject]$record }
    if ($wait.Exception) {
        if ($wait.Exception -is [System.IO.FileNotFoundException]) { $record.Reason = 'missing' }
        else {
            Write-Verbose "Read-YurunaCriticalRecordOversize: '$Path': $($wait.Exception.Message)"
            $record.Reason = 'io-error'
        }
        return [pscustomobject]$record
    }
    $header = Test-YurunaCriticalRecordByte -Bytes ([byte[]]$wait.Result) -Kind $Kind
    $record.HeaderGeneration = $header.HeaderGeneration
    if ($header.Reason -in @('unsupported-version', 'kind-mismatch')) { $record.Reason = $header.Reason }
    return [pscustomobject]$record
}

function Read-YurunaCriticalRecordFile {
    <#
    .SYNOPSIS
        Read and validate one of a record's two files within the deadline.
    .OUTPUTS
        [pscustomobject] as Test-YurunaCriticalRecordByte, with Reason also
        missing, reparse-point, io-error or io-timeout, and too-large (see
        Read-YurunaCriticalRecordOversize) for a file over MaxBytes.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)]$Deadline,
        [Parameter(Mandatory)][int]$MaxBytes
    )
    $record = [ordered]@{ Valid = $false; Reason = 'missing'; Generation = [long]0; HeaderGeneration = $null; Payload = $null; WrittenUtc = $null }
    if ([System.IO.FileInfo]::new($Path).LinkTarget) { $record.Reason = 'reparse-point'; return [pscustomobject]$record }
    if (-not [System.IO.File]::Exists($Path)) {
        if ([System.IO.Directory]::Exists($Path)) { $record.Reason = 'io-error' }
        return [pscustomobject]$record
    }
    $remaining = Get-YurunaDeadlineRemainingMs -Deadline $Deadline
    if ($remaining -le 0) { $record.Reason = 'io-timeout'; return [pscustomobject]$record }
    $io = $script:CriticalRecordIoTypeName -as [type]
    $wait = Wait-YurunaCriticalIoTask -Task ($io::ReadFileAsync($Path, $MaxBytes)) -Operation 'read' `
        -TimeoutMilliseconds ([int][Math]::Min([long]5000, $remaining))
    if ($wait.TimedOut) { $record.Reason = 'io-timeout'; return [pscustomobject]$record }
    if ($wait.Exception) {
        if ($wait.Exception -is [System.IO.InvalidDataException]) { return (Read-YurunaCriticalRecordOversize -Path $Path -Kind $Kind -Deadline $Deadline) }
        elseif ($wait.Exception -is [System.IO.FileNotFoundException]) { $record.Reason = 'missing' }
        else {
            Write-Verbose "Read-YurunaCriticalRecordFile: '$Path': $($wait.Exception.Message)"
            $record.Reason = 'io-error'
        }
        return [pscustomobject]$record
    }
    return Test-YurunaCriticalRecordByte -Bytes ([byte[]]$wait.Result) -Kind $Kind
}

function Read-YurunaCriticalRecord {
    <#
    .SYNOPSIS
        Read the last valid generation of a critical record.
    .DESCRIPTION
        The current file is used when it validates. When it is missing or its
        bytes are damaged (too large, unparseable header, truncated, checksum
        mismatch, unparseable payload) and the previous generation validates,
        the previous one is returned with Degraded set. A current file of a
        newer format version or of another kind never falls back: a newer
        writer's state must not be silently replaced by an older generation.
        Anything else -- both files damaged, a link, an I/O failure -- is a
        status other than ok or missing, on which callers refuse to mutate.
        Neither file present is 'missing': a fresh start.

        HighestGeneration is the largest generation any parseable header of
        either file carries, a damaged or oversized one included, so the
        writer never reuses a number some file already held.

        The payload is parsed into a hashtable; JSON arrays arrive as object
        arrays, and a caller normalizes a field that may hold one element
        with @(...) according to its own schema.
    .PARAMETER Path
        The record file; the previous generation is <Path>.prev.
    .PARAMETER Kind
        The record kind the caller expects, lowercase letters, digits, dots
        and hyphens.
    .PARAMETER Deadline
        A shared deadline; defaults to 15 seconds from the call.
    .PARAMETER MaxBytes
        Largest file accepted.
    .OUTPUTS
        [pscustomobject] @{ Status ok|missing|corrupt|unsupported-version|
        kind-mismatch|reparse-point|io-error|io-timeout; Source current|previous|$null;
        Degraded; Generation; HighestGeneration; Payload; WrittenUtc;
        CurrentReason; PreviousReason }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9.-]{0,63}$', Options = 'None')][string]$Kind,
        [ValidateNotNull()][psobject]$Deadline,
        [ValidateRange(1024, 4194304)][int]$MaxBytes = 1048576
    )
    $record = [ordered]@{
        Status = 'io-error'; Source = $null; Degraded = $false; Generation = [long]0; HighestGeneration = [long]0
        Payload = $null; WrittenUtc = $null; CurrentReason = $null; PreviousReason = $null
    }
    if (-not (Initialize-YurunaCriticalRecordIo)) { return [pscustomobject]$record }
    $deadlineObject = if ($PSBoundParameters.ContainsKey('Deadline')) { $Deadline } else { New-YurunaDeadline -TotalMilliseconds 15000 }
    $current  = Read-YurunaCriticalRecordFile -Path $Path -Kind $Kind -Deadline $deadlineObject -MaxBytes $MaxBytes
    $previous = Read-YurunaCriticalRecordFile -Path "$Path.prev" -Kind $Kind -Deadline $deadlineObject -MaxBytes $MaxBytes
    $record.CurrentReason  = $current.Reason
    $record.PreviousReason = $previous.Reason
    $highest = [long]0
    foreach ($file in @($current, $previous)) {
        if ($null -ne $file.HeaderGeneration -and [long]$file.HeaderGeneration -gt $highest) { $highest = [long]$file.HeaderGeneration }
    }
    $record.HighestGeneration = $highest

    $useSource = {
        param($File, [string]$Source)
        $record.Status     = 'ok'
        $record.Source     = $Source
        $record.Degraded   = ($Source -eq 'previous')
        $record.Generation = [long]$File.Generation
        $record.Payload    = $File.Payload
        $record.WrittenUtc = $File.WrittenUtc
    }
    if ($current.Valid) {
        & $useSource $current 'current'
    } elseif ($current.Reason -in @('unsupported-version', 'kind-mismatch', 'reparse-point', 'io-error', 'io-timeout')) {
        $record.Status = $current.Reason
    } elseif ($current.Reason -eq 'missing' -and $previous.Reason -eq 'missing') {
        $record.Status = 'missing'
    } elseif ($previous.Valid) {
        & $useSource $previous 'previous'
    } elseif ($previous.Reason -in @('unsupported-version', 'kind-mismatch', 'reparse-point', 'io-error', 'io-timeout')) {
        $record.Status = $previous.Reason
    } else {
        $record.Status = 'corrupt'
    }
    return [pscustomobject]$record
}

function ConvertTo-YurunaCriticalWriteReason {
    <#
    .SYNOPSIS
        Map an I/O failure kind onto the writer's Reason vocabulary.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Kind)
    switch ($Kind) {
        'access-denied'  { return 'access-denied' }
        'parent-missing' { return 'parent-missing' }
        'not-found'      { return 'parent-missing' }
        'disk-full'      { return 'disk-full' }
        'read-only'      { return 'read-only' }
        default          { return 'io-error' }
    }
}

function Write-YurunaCriticalRecord {
    <#
    .SYNOPSIS
        Replace a critical record with a new generation, compare-and-set on
        the generation the caller read.
    .DESCRIPTION
        Hold the record's lock for the whole read-modify-write. Stages, in
        order: validated (durability requirement, serialization, size, links,
        the existing record, the expected generation); temp-written (a new
        temporary file beside the record); temp-flushed; temp-verified (read
        back byte for byte); previous-preserved (the valid current generation
        copied, flushed and verified into <Path>.prev; skipped when the
        current file is missing or damaged, so a good .prev is never replaced
        by a bad copy); current-replaced (atomic rename over <Path>);
        directory-committed (the directory entry flushed); verified (re-read:
        the new generation must be what a reader now sees). Orphaned
        temporary files of this record from an interrupted write are removed
        after a successful write.

        Committed $false means the intent was not persisted: refuse the
        mutation it guarded. A failure at or after current-replaced can
        leave the new generation visible anyway, so a later reader may see
        it. Existing evidence the reader cannot validate is never overwritten
        (existing-record-invalid), and a stale ExpectedGeneration is refused
        (generation-conflict) with both files unchanged.

        Every step waits at most five seconds (flushes two under
        ProcessCrash) and never past the deadline; with less than a second
        left before the first write nothing is written (deadline-exhausted).
        Under ProcessCrash a flush that fails or times out only clears
        FlushesConfirmed, since the atomic replace already survives a process
        crash; under PowerLoss it refuses (durability-unconfirmed), and a
        platform not declared power-loss qualified refuses before writing
        anything (durability-unavailable).
    .PARAMETER Path
        The record file. Its directory must exist.
    .PARAMETER Kind
        The record kind, stored in the header and checked by every reader.
    .PARAMETER Payload
        A hashtable or object serialized as a JSON object (at most 32 levels
        deep; deeper payloads are refused rather than silently truncated).
    .PARAMETER ExpectedGeneration
        The Generation the caller last read, 0 when the record was missing.
    .PARAMETER Deadline
        A shared deadline; defaults to 15 seconds from the call.
    .PARAMETER RequireDurability
        ProcessCrash (default) or PowerLoss.
    .PARAMETER MaxBytes
        Largest record accepted, header included.
    .PARAMETER StageHook
        Test instrumentation: invoked with each stage name after that stage
        completes.
    .OUTPUTS
        [pscustomobject] @{ Committed; Generation; PreviousGeneration;
        Durability process-crash|power-loss; FlushesConfirmed; Stage; Reason;
        IoKind }. Stage is the stage in progress when the call ended
        ('verified' on success, 'none' for a preview). Reason is one of ok,
        preview, generation-conflict, existing-record-invalid, too-large,
        payload-too-deep, serialize-failed, reparse-point, parent-missing,
        access-denied, disk-full, read-only, io-error, io-timeout,
        verify-failed, durability-unavailable, durability-unconfirmed or
        deadline-exhausted.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9.-]{0,63}$', Options = 'None')][string]$Kind,
        [Parameter(Mandatory)][AllowNull()][object]$Payload,
        [Parameter(Mandatory)][ValidateRange(0, [long]::MaxValue)][long]$ExpectedGeneration,
        [ValidateNotNull()][psobject]$Deadline,
        [ValidateSet('ProcessCrash', 'PowerLoss')][string]$RequireDurability = 'ProcessCrash',
        [ValidateRange(1024, 4194304)][int]$MaxBytes = 1048576,
        [Parameter(DontShow)][scriptblock]$StageHook
    )
    $result = [ordered]@{
        Committed = $false; Generation = [long]0; PreviousGeneration = [long]0; Durability = 'process-crash'
        FlushesConfirmed = $false; Stage = 'none'; Reason = $null; IoKind = $null
    }
    if (-not $PSCmdlet.ShouldProcess($Path, (Format-YurunaOperatorMessage -Key 'runner.critical_record_replace'))) {
        $result.Reason = 'preview'
        return [pscustomobject]$result
    }
    $deadlineObject = if ($PSBoundParameters.ContainsKey('Deadline')) { $Deadline } else { New-YurunaDeadline -TotalMilliseconds 15000 }
    $powerLoss = ($RequireDurability -eq 'PowerLoss')
    $flushCapMs = if ($powerLoss) { 5000 } else { 2000 }
    $declaration = Get-YurunaCriticalRecordDurability
    $io = $null
    $tempPath = $null
    $prevTempPath = $null
    $flushesConfirmed = $true

    $stepMs = {
        param([long]$CapMs)
        [int][Math]::Min($CapMs, [long](Get-YurunaDeadlineRemainingMs -Deadline $deadlineObject))
    }
    $removeTemp = {
        param([string]$TempFile)
        if (-not $TempFile -or $null -eq $io) { return }
        $budget = & $stepMs 1000
        if ($budget -le 0) { return }
        $null = Wait-YurunaCriticalIoTask -Task ($io::DeleteFileAsync($TempFile)) -TimeoutMilliseconds $budget -Operation 'delete'
    }
    $fail = {
        param([string]$Reason, [string]$IoKind)
        $result.Reason = $Reason
        if ($IoKind) { $result.IoKind = $IoKind }
        $result.FlushesConfirmed = $false
        & $removeTemp $tempPath
        & $removeTemp $prevTempPath
        [pscustomobject]$result
    }
    $failTask = {
        param($Wait)
        if ($Wait.TimedOut) { return (& $fail 'io-timeout' $null) }
        $kind = Get-YurunaIoFailureKind -Exception $Wait.Exception
        & $fail (ConvertTo-YurunaCriticalWriteReason -Kind $kind) $kind
    }
    $completeStage = {
        param([string]$Stage)
        if ($StageHook) { $null = & $StageHook $Stage }
    }
    $flushOk = {
        param($Wait)
        (-not $Wait.TimedOut) -and ($null -eq $Wait.Exception) -and ([int]$Wait.Result -eq 0)
    }

    # --- validated
    $result.Stage = 'validated'
    if ($powerLoss -and -not $declaration.PowerLossQualified) { return (& $fail 'durability-unavailable' $null) }
    if (-not ($Payload -is [System.Collections.IDictionary] -or $Payload -is [System.Management.Automation.PSCustomObject])) {
        return (& $fail 'serialize-failed' $null)
    }
    $serializeWarnings = $null
    try {
        $json = ConvertTo-Json -InputObject $Payload -Depth 32 -Compress -WarningVariable serializeWarnings -WarningAction SilentlyContinue -ErrorAction Stop
    } catch {
        Write-Verbose "Write-YurunaCriticalRecord: payload for '$Path' could not be serialized: $($_.Exception.Message)"
        return (& $fail 'serialize-failed' $null)
    }
    if (@($serializeWarnings).Count -gt 0) { return (& $fail 'payload-too-deep' $null) }
    $payloadBytes = [System.Text.UTF8Encoding]::new($false).GetBytes([string]$json)
    if (-not (Initialize-YurunaCriticalRecordIo)) { return (& $fail 'io-error' $null) }
    $io = $script:CriticalRecordIoTypeName -as [type]
    $fullPath  = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    $leaf      = [System.IO.Path]::GetFileName($fullPath)
    if (-not $directory -or -not [System.IO.Directory]::Exists($directory)) { return (& $fail 'parent-missing' 'parent-missing') }
    if ([System.IO.FileInfo]::new($fullPath).LinkTarget -or [System.IO.FileInfo]::new("$fullPath.prev").LinkTarget) {
        return (& $fail 'reparse-point' $null)
    }
    $existing = Read-YurunaCriticalRecord -Path $fullPath -Kind $Kind -Deadline $deadlineObject -MaxBytes $MaxBytes
    switch ($existing.Status) {
        'ok'            { }
        'missing'       { }
        'reparse-point' { return (& $fail 'reparse-point' $null) }
        'io-error'      { return (& $fail 'io-error' $null) }
        'io-timeout'    { return (& $fail 'io-timeout' $null) }
        default         { return (& $fail 'existing-record-invalid' $null) }
    }
    $lastValid = [long]$existing.Generation
    $result.PreviousGeneration = $lastValid
    if ($ExpectedGeneration -ne $lastValid) { return (& $fail 'generation-conflict' $null) }
    $newGeneration = [long]([Math]::Max($lastValid, [long]$existing.HighestGeneration) + 1)
    $recordBytes = ConvertTo-YurunaCriticalRecordByte -Kind $Kind -Generation $newGeneration -PayloadBytes $payloadBytes
    if ($recordBytes.Length -gt $MaxBytes) { return (& $fail 'too-large' $null) }
    if ((Get-YurunaDeadlineRemainingMs -Deadline $deadlineObject) -lt 1000) { return (& $fail 'deadline-exhausted' $null) }
    & $completeStage 'validated'

    # --- temp-written
    $result.Stage = 'temp-written'
    $token = '{0}-{1}' -f $PID, [Guid]::NewGuid().ToString('N')
    $tempPath = Join-Path $directory "$leaf.$token.tmp"
    $wait = Wait-YurunaCriticalIoTask -Task ($io::WriteNewFileAsync($tempPath, $recordBytes)) -TimeoutMilliseconds (& $stepMs 5000) -Operation 'write-temp'
    if ($wait.TimedOut -or $wait.Exception) { return (& $failTask $wait) }
    & $completeStage 'temp-written'

    # --- temp-flushed
    $result.Stage = 'temp-flushed'
    $wait = Wait-YurunaCriticalIoTask -Task ($io::FlushPathAsync($tempPath, $false)) -TimeoutMilliseconds (& $stepMs $flushCapMs) -Operation 'flush-temp'
    if (-not (& $flushOk $wait)) {
        if ($powerLoss) { return (& $fail 'durability-unconfirmed' $null) }
        $flushesConfirmed = $false
    }
    & $completeStage 'temp-flushed'

    # --- temp-verified
    $result.Stage = 'temp-verified'
    $wait = Wait-YurunaCriticalIoTask -Task ($io::ReadFileAsync($tempPath, $MaxBytes)) -TimeoutMilliseconds (& $stepMs 5000) -Operation 'verify-temp'
    if ($wait.TimedOut -or $wait.Exception) { return (& $failTask $wait) }
    $readBack = [byte[]]$wait.Result
    $expectedDigest = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($recordBytes))
    if ($readBack.Length -ne $recordBytes.Length -or
        [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($readBack)) -ne $expectedDigest) {
        return (& $fail 'verify-failed' $null)
    }
    & $completeStage 'temp-verified'

    # --- previous-preserved
    $result.Stage = 'previous-preserved'
    if ($existing.Source -eq 'current') {
        $prevTempPath = Join-Path $directory "$leaf.prev.$token.tmp"
        $wait = Wait-YurunaCriticalIoTask -Task ($io::CopyFileAsync($fullPath, $prevTempPath)) -TimeoutMilliseconds (& $stepMs 5000) -Operation 'copy-previous'
        if ($wait.TimedOut -or $wait.Exception) { return (& $failTask $wait) }
        $wait = Wait-YurunaCriticalIoTask -Task ($io::FlushPathAsync($prevTempPath, $false)) -TimeoutMilliseconds (& $stepMs $flushCapMs) -Operation 'flush-previous'
        if (-not (& $flushOk $wait)) {
            if ($powerLoss) { return (& $fail 'durability-unconfirmed' $null) }
            $flushesConfirmed = $false
        }
        $wait = Wait-YurunaCriticalIoTask -Task ($io::ReadFileAsync($prevTempPath, $MaxBytes)) -TimeoutMilliseconds (& $stepMs 5000) -Operation 'verify-previous'
        if ($wait.TimedOut -or $wait.Exception) { return (& $failTask $wait) }
        $copied = Test-YurunaCriticalRecordByte -Bytes ([byte[]]$wait.Result) -Kind $Kind
        if (-not $copied.Valid) { return (& $fail 'verify-failed' $null) }
        # The record changed between the read and the copy: another writer
        # ignored the lock, and this write must not replace its decision.
        if ([long]$copied.Generation -ne $lastValid) { return (& $fail 'generation-conflict' $null) }
        $wait = Wait-YurunaCriticalIoTask -Task ($io::ReplaceFileAsync($prevTempPath, "$fullPath.prev")) -TimeoutMilliseconds (& $stepMs 5000) -Operation 'replace-previous'
        if ($wait.TimedOut -or $wait.Exception) { return (& $failTask $wait) }
        $prevTempPath = $null
    }
    & $completeStage 'previous-preserved'

    # --- current-replaced
    $result.Stage = 'current-replaced'
    $wait = Wait-YurunaCriticalIoTask -Task ($io::ReplaceFileAsync($tempPath, $fullPath)) -TimeoutMilliseconds (& $stepMs 5000) -Operation 'replace-current'
    if ($wait.TimedOut) {
        # The rename may still land; the temp file is left for the next
        # successful write's sweep rather than deleted under it.
        $tempPath = $null
        return (& $fail 'io-timeout' $null)
    }
    if ($wait.Exception) { return (& $failTask $wait) }
    $tempPath = $null
    & $completeStage 'current-replaced'

    # --- directory-committed
    $result.Stage = 'directory-committed'
    $wait = Wait-YurunaCriticalIoTask -Task ($io::FlushPathAsync($directory, $true)) -TimeoutMilliseconds (& $stepMs $flushCapMs) -Operation 'flush-directory'
    # -2: this platform commits the entry through the write-through rename.
    $directoryCommitted = (& $flushOk $wait) -or ((-not $wait.TimedOut) -and ($null -eq $wait.Exception) -and ([int]$wait.Result -eq -2))
    if (-not $directoryCommitted) {
        if ($powerLoss) { return (& $fail 'durability-unconfirmed' $null) }
        $flushesConfirmed = $false
    }
    & $completeStage 'directory-committed'

    # --- verified
    $result.Stage = 'verified'
    $after = Read-YurunaCriticalRecord -Path $fullPath -Kind $Kind -Deadline $deadlineObject -MaxBytes $MaxBytes
    if ($after.Status -ne 'ok' -or $after.Source -ne 'current' -or [long]$after.Generation -ne $newGeneration) {
        return (& $fail 'verify-failed' $null)
    }
    $sweepMs = & $stepMs 2000
    if ($sweepMs -gt 0) {
        $null = Wait-YurunaCriticalIoTask -Task ($io::RemoveOrphanTempFilesAsync($directory, $leaf)) -TimeoutMilliseconds $sweepMs -Operation 'sweep'
    }
    $result.Committed        = $true
    $result.Generation       = $newGeneration
    $result.FlushesConfirmed = $flushesConfirmed
    $result.Durability       = if ($flushesConfirmed -and $declaration.PowerLossQualified) { 'power-loss' } else { 'process-crash' }
    $result.Reason           = 'ok'
    & $completeStage 'verified'
    return [pscustomobject]$result
}

Export-ModuleMember -Function Write-YurunaCriticalRecord, Read-YurunaCriticalRecord, Get-YurunaCriticalRecordDurability, Initialize-YurunaCriticalRecordIo
