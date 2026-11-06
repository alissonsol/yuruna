<#PSScriptInfo
.VERSION 2026.11.05
.GUID 4253d862-e3c2-431e-ad10-71ce27db3462
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lab netconsole receiver udp deep-diagnostics
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
    Receives netconsole kernel messages over UDP and keeps one log per sending
    host per UTC day.
.DESCRIPTION
    The receiving half of deep diagnostics mode
    (host/ubuntu.kvm/Enable-DeepDiagnostics.ps1 -NetconsoleTarget). A host
    that freezes loses the last seconds of what it was writing to its own
    disk, while every kernel line it sent here before the freeze is already on
    this machine. Run it on an always-on machine other than the one being
    watched; it uses .NET only, on Linux, macOS and Windows alike.

    Every line is written with the UTC time it arrived and flushed at once.
    The receive buffer it asks for holds the burst a panicking host sends
    while the lines are written out; a warning at start says when the system
    granted less (on Linux, net.core.rmem_max sets the limit).
    Netconsole's extended format (log level, sequence number and time since
    boot) is decoded when a host sends it; the parts of a record too long for
    one datagram are written as they arrive, each marked with its offset. A
    log that reaches -MaxFileBytes moves to <name>.1, replacing the one before,
    so the newest lines are always kept and a host's log for a day never takes
    more than twice the limit.

    Runs in the foreground until Ctrl+C or -DurationSeconds; the
    host/ubuntu.kvm README shows how to keep it running.

.PARAMETER Port
    UDP port to listen on, on every IPv4 address of this machine. Allow it in
    this machine's firewall.

.PARAMETER OutputDirectory
    Where the logs go: netconsole-<sender address>-<yyyyMMdd>.log. Default:
    yuruna/netconsole under the home directory.

.PARAMETER MaxFileBytes
    Size at which a log moves to <name>.1.

.PARAMETER DurationSeconds
    Stop after this many seconds; 0 runs until Ctrl+C.

.PARAMETER Quiet
    Write the logs only, without echoing each line here.

.EXAMPLE
    pwsh test/lab/Receive-Netconsole.ps1
.EXAMPLE
    pwsh test/lab/Receive-Netconsole.ps1 -Port 6666 -OutputDirectory /srv/netconsole -Quiet
#>

[CmdletBinding()]
param(
    [ValidateRange(1, 65535)][int]$Port = 6666,
    [string]$OutputDirectory = '',
    [ValidateRange(4096, [long]::MaxValue)][long]$MaxFileBytes = 64MB,
    [ValidateRange(0, [int]::MaxValue)][int]$DurationSeconds = 0,
    [switch]$Quiet
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$ErrorActionPreference = 'Stop'

if (-not $OutputDirectory) { $OutputDirectory = Join-Path $HOME 'yuruna/netconsole' }
[void][IO.Directory]::CreateDirectory($OutputDirectory)

# --- REGION: ConvertFrom-NetconsoleDatagram
# Extended netconsole puts "<prefix>,<sequence>,<microseconds since boot>,<flag>"
# before ';' (the same header as /dev/kmsg), optionally led by the kernel
# release and followed by ",ncfrag=<offset>/<total>" when a record is split.
# The prefix is facility*8+level, so a line a host wrote to /dev/kmsg itself
# still reads as its level.
$script:ExtendedHeader = [regex]'^(?:(?<release>[^,;]+),)?(?<prefix>\d+),(?<sequence>\d+),(?<microseconds>\d+),(?<flag>[^,;]*)(?:,ncfrag=(?<offset>\d+)/(?<total>\d+))?;(?<message>.*)$'

function ConvertFrom-NetconsoleDatagram {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $lines = @($Text.Replace("`r", '') -split "`n" | Where-Object { $_ -ne '' })
    if ($lines.Count -eq 0) { return @() }
    $header = $script:ExtendedHeader.Match($lines[0])
    if (-not $header.Success) { return $lines }
    $seconds = [decimal]$header.Groups['microseconds'].Value / 1000000
    $part = if ($header.Groups['offset'].Success) { " part=$($header.Groups['offset'].Value)/$($header.Groups['total'].Value)" } else { '' }
    $first = '[{0,13}] <{1}> seq={2}{3} {4}' -f $seconds.ToString('0.000000', [Globalization.CultureInfo]::InvariantCulture),
        ([int]$header.Groups['prefix'].Value % 8), $header.Groups['sequence'].Value, $part, $header.Groups['message'].Value
    # Lines after the first are the record's dictionary (" KEY=value") and
    # any user data, kept as sent.
    return @($first) + @($lines | Select-Object -Skip 1)
}

# --- REGION: Write-NetconsoleLine
$script:Writer = @{}

function Close-NetconsoleWriter {
    # Closes every open log, or with -KeepDay every log of another day.
    [CmdletBinding()]
    param([string]$KeepDay = '')
    foreach ($path in @($script:Writer.Keys)) {
        if ($KeepDay -and $path.EndsWith("-$KeepDay.log", [StringComparison]::Ordinal)) { continue }
        $script:Writer[$path].Dispose()
        $script:Writer.Remove($path)
    }
}

function Write-NetconsoleLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][datetime]$Received,
        [Parameter(Mandatory)][string[]]$Line,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][long]$MaxBytes,
        [switch]$Echo
    )
    $day = $Received.ToString('yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)
    $path = Join-Path $Directory "netconsole-$Source-$day.log"
    $stamp = $Received.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [Globalization.CultureInfo]::InvariantCulture)
    foreach ($text in $Line) {
        $record = "$stamp $text"
        $bytes = [Text.Encoding]::UTF8.GetByteCount($record) + 1
        $writer = $script:Writer[$path]
        if ($writer -and $writer.BaseStream.Length + $bytes -gt $MaxBytes) {
            $writer.Dispose()
            $script:Writer.Remove($path)
            $writer = $null
            Move-Item -LiteralPath $path -Destination "$path.1" -Force
            Write-Verbose "$path reached $MaxBytes bytes; its earlier lines are in $path.1"
        }
        if (-not $writer) {
            # A new day starts a new file; the writers of earlier days close
            # rather than stay open for the life of the receiver.
            Close-NetconsoleWriter -KeepDay $day
            $stream = [IO.FileStream]::new($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
            $writer.AutoFlush = $true
            $script:Writer[$path] = $writer
        }
        $writer.WriteLine($record)
        if ($Echo) { Write-Output "$Source $record" }
    }
}

# --- REGION: Request-NetconsoleReceiveBuffer
# A host that panics sends every CPU's backtrace and then the panic itself as
# one burst, far faster than the loop below writes lines. The socket's receive
# buffer holds the burst until the loop catches up; the default one holds about
# two hundred datagrams, so the end of the burst, the panic among it, would be
# dropped. Linux silently caps the request at net.core.rmem_max and reports
# the size it kept doubled, for its bookkeeping; other systems refuse a request
# above their limit. Either way the size the socket reports is what counts.
$script:ReceiveBufferBytes = 4MB

function Request-NetconsoleReceiveBuffer {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Socket, [Parameter(Mandatory)][int]$Bytes)
    try {
        $Socket.ReceiveBufferSize = $Bytes
    } catch {
        Write-Verbose "a $Bytes-byte receive buffer was refused: $($_.Exception.Message)"
    }
    $granted = $Socket.ReceiveBufferSize
    if ($granted -lt $Bytes) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'runner.netconsole_receiver_small_buffer' -Arguments @{ granted = "$granted"; requested = "$Bytes" })
    }
}

# --- REGION: Receive
try {
    $client = [Net.Sockets.UdpClient]::new([Net.IPEndPoint]::new([Net.IPAddress]::Any, $Port))
} catch {
    Write-Error (Format-YurunaOperatorMessage -Key 'runner.netconsole_receiver_bind_failed' -Arguments @{ port = "$Port"; message = "$($_.Exception.Message)" })
    exit 1
}
# A one-second timeout keeps the loop returning to PowerShell, which is when
# Ctrl+C and -DurationSeconds take effect.
$client.Client.ReceiveTimeout = 1000
Request-NetconsoleReceiveBuffer -Socket $client.Client -Bytes $script:ReceiveBufferBytes
$deadline = if ($DurationSeconds -gt 0) { [DateTime]::UtcNow.AddSeconds($DurationSeconds) } else { [DateTime]::MaxValue }
$count = 0
Write-Information (Format-YurunaOperatorMessage -Key 'runner.netconsole_receiver_listening' -Arguments @{ port = "$Port"; directory = "$OutputDirectory" }) -InformationAction Continue
try {
    while ([DateTime]::UtcNow -lt $deadline) {
        $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
        try {
            $bytes = $client.Receive([ref]$remote)
        } catch [Net.Sockets.SocketException] {
            if ($_.Exception.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) { continue }
            throw
        }
        $received = [DateTime]::UtcNow
        $count++
        $lines = ConvertFrom-NetconsoleDatagram -Text ([Text.Encoding]::UTF8.GetString($bytes))
        if ($lines.Count -eq 0) { continue }
        try {
            Write-NetconsoleLine -Source "$($remote.Address)" -Received $received -Line $lines -Directory $OutputDirectory -MaxBytes $MaxFileBytes -Echo:(-not $Quiet)
        } catch {
            Write-Warning (Format-YurunaOperatorMessage -Key 'runner.netconsole_receiver_write_failed' -Arguments @{ directory = "$OutputDirectory"; message = "$($_.Exception.Message)" })
        }
    }
} finally {
    Close-NetconsoleWriter
    $client.Dispose()
    Write-Information (Format-YurunaOperatorMessage -Key 'runner.netconsole_receiver_stopped' -Arguments @{ count = "$count" }) -InformationAction Continue
}
exit 0
