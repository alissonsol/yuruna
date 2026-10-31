<#PSScriptInfo
.VERSION 2026.10.31
.GUID 4259cf8a-3a2a-4cee-b176-bd4cd6e611ba
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host windows.hyper-v driver capture dhcp serial
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

# --- REGION: DHCP evidence capture
# See https://yuruna.link/42e5cdfd-002d

# The one live capture, if any: @{ VMName; EtlPath }. Session state, not
# durable state -- pktmon itself is the source of truth for whether a capture
# is running; this only remembers which VM the current one belongs to so an
# unrelated Remove-VM (the cycle-start sweep) cannot discard a capture it
# does not own.
$script:YurunaDhcpCapture = $null

# --- REGION: Serial console capture
# See https://yuruna.link/42dc5bb9-0004
# The COM1 pipe is the one guest-side record that survives a guest whose VMBus
# devices stop answering. Armed when the VM starts, saved on failure beside the
# DHCP capture, discarded on a clean teardown.
function Get-VMSerialPipeName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VMName)
    return "yuruna-serial-$VMName"
}
# The reader is a job named like the pipe, and its record lives in this module
# instance. Initialize-YurunaHost re-imports the driver with -Force when the
# sequence engine loads, between the runner's Start-VM phase and a sequence's
# own startVm, so a reader armed in the first outlives the record of its
# start: it keeps the pipe and the log, and a reader armed after it never
# connects. The name survives the re-import, so every path finds the reader
# by it and a record is rebuilt from the name when the module's is gone.
function Get-VMSerialCaptureJob {
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][string]$VMName)
    $name = Get-VMSerialPipeName -VMName $VMName
    return @(Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $name })
}
function Get-VMSerialCaptureRecord {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$VMName)
    $record = $script:YurunaSerialCapture
    if ($record -and $record.VMName -eq $VMName) { return $record }
    $jobs = Get-VMSerialCaptureJob -VMName $VMName
    if ($jobs.Count -eq 0) { return $null }
    return @{
        VMName = $VMName; Job = $jobs[0]
        LogPath = Join-Path $env:TEMP "yuruna-serial-$VMName.log"
        StatePath = Join-Path $env:TEMP "yuruna-serial-$VMName.state.json"
        PipeName = Get-VMSerialPipeName -VMName $VMName
    }
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
<#
.SYNOPSIS
    Arm a reader on the VM's COM1 named pipe and keep what the guest writes there.
.OUTPUTS
    [bool] $true when a reader was started.
#>
function Start-VMSerialCapture {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic capture: reads a serial pipe into a temp file, changes no durable system state, and must never prompt inside a runner cycle.')]
    param([Parameter(Mandatory)][string]$VMName)
    try {
        $port = Hyper-V\Get-VMComPort -VMName $VMName -Number 1 -ErrorAction Stop
        if (-not $port -or -not $port.Path) {
            Write-Verbose "Serial console capture: '$VMName' has no COM1 pipe; nothing to read."
            return $false
        }
        [void](Stop-VMSerialCapture -VMName $VMName)
        $logPath = Join-Path $env:TEMP "yuruna-serial-$VMName.log"
        $statePath = Join-Path $env:TEMP "yuruna-serial-$VMName.state.json"
        Remove-Item -LiteralPath $logPath, $statePath -Force -ErrorAction SilentlyContinue
        $pipeName = Get-VMSerialPipeName -VMName $VMName
        # See https://yuruna.link/42f52e37-001e
        # A job reads the pipe, reconnects across VM restarts, records its connection
        # history in the sidecar and calls no module function.
        $job = Start-Job -Name $pipeName -ScriptBlock {
            $PipeName = $using:pipeName
            $LogPath = $using:logPath
            $StatePath = $using:statePath
            $buffer = [byte[]]::new(4096)
            $state = [ordered]@{
                pipe = $PipeName; connectAttempts = 0; connectedCount = 0; lastConnectUtc = $null
                lastDisconnectUtc = $null; lastError = $null; bytesRead = 0L; earlierBytes = 0L; updatedUtc = $null
            }
            $save = {
                $state.updatedUtc = [DateTime]::UtcNow.ToString('o')
                try { [IO.File]::WriteAllText($StatePath, ($state | ConvertTo-Json -Compress)) } catch { $null = $_ }
            }
            & $save
            while ($true) {
                $client = $null
                try {
                    $state.connectAttempts++
                    $client = [System.IO.Pipes.NamedPipeClientStream]::new('.', $PipeName, [System.IO.Pipes.PipeDirection]::In)
                    $client.Connect(2000)
                    $file = [System.IO.FileStream]::new($LogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                    $state.connectedCount++
                    $state.lastConnectUtc = [DateTime]::UtcNow.ToString('o')
                    # Exact only here: bytesRead is saved again only after the
                    # first chunk and at a disconnect, and while this reader
                    # holds the pipe nothing else can append, so what the log
                    # holds beyond its own bytes now came from an earlier reader.
                    $state.earlierBytes = [math]::Max(0L, $file.Length - $state.bytesRead)
                    & $save
                    try {
                        while ($client.IsConnected) {
                            $read = $client.Read($buffer, 0, $buffer.Length)
                            if ($read -le 0) { break }
                            $file.Write($buffer, 0, $read)
                            $file.Flush()
                            $firstBytes = ($state.bytesRead -eq 0)
                            $state.bytesRead += $read
                            if ($firstBytes) { & $save }
                        }
                    } finally { $file.Dispose() }
                    $state.lastDisconnectUtc = [DateTime]::UtcNow.ToString('o')
                    & $save
                } catch {
                    # .NET failures arrive wrapped in a MethodInvocationException; the
                    # inner one (TimeoutException, IOException) is the reading.
                    $failure = if ($_.Exception.InnerException) { $_.Exception.InnerException } else { $_.Exception }
                    $state.lastError = "$($failure.GetType().Name): $($failure.Message)"
                    & $save
                    Start-Sleep -Seconds 1
                } finally {
                    if ($client) { $client.Dispose() }
                }
            }
        }
        $script:YurunaSerialCapture = @{ VMName = $VMName; Job = $job; LogPath = $logPath; StatePath = $statePath; PipeName = $pipeName }
        Write-Verbose "Serial console capture armed for '$VMName' -> $logPath"
        return $true
    } catch {
        Write-Verbose "Start-VMSerialCapture failed: $($_.Exception.Message)"
        return $false
    }
}
<#
.SYNOPSIS
    Stop the live serial reader and discard its file (the no-failure path).
.DESCRIPTION
    With -VMName, stops that VM's reader whether or not this module instance
    holds the record of it (see Get-VMSerialCaptureJob); a record of another
    VM is left alone. Without it, stops the recorded reader.
.OUTPUTS
    [bool] $true when nothing is left running or on disk.
#>
function Stop-VMSerialCapture {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic teardown: stops a reader job and deletes its temp file; must never prompt inside a runner cycle.')]
    param([string]$VMName)
    try {
        $capture = if ($VMName) { Get-VMSerialCaptureRecord -VMName $VMName } else { $script:YurunaSerialCapture }
        if (-not $capture) { return $true }
        if ($script:YurunaSerialCapture -and $script:YurunaSerialCapture.VMName -eq $capture.VMName) {
            $script:YurunaSerialCapture = $null
        }
        Stop-VMSerialCaptureJob -VMName $capture.VMName
        if ($capture.LogPath) { Remove-Item -LiteralPath $capture.LogPath -Force -ErrorAction SilentlyContinue }
        if ($capture.StatePath) { Remove-Item -LiteralPath $capture.StatePath -Force -ErrorAction SilentlyContinue }
        return $true
    } catch {
        Write-Verbose "Stop-VMSerialCapture failed: $($_.Exception.Message)"
        return $false
    }
}
<#
.SYNOPSIS
    Stop the serial reader and keep what it read as serial-console.log in the
    failure folder (the failure path).
.DESCRIPTION
    An empty capture is reported in serial-console.info.txt rather than as an
    empty log, so "the guest wrote nothing to its serial port" and "the capture
    never ran" stay distinguishable.
.OUTPUTS
    [bool] $true when a log with content was saved.
#>
function Save-VMSerialCapture {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic collection: copies a capture into the failure folder and removes its temp file; must never prompt inside a runner cycle.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    # Set once this call owns the capture, so the finally below removes its
    # temp files on every path out -- a throw while copying included -- and
    # never touches a capture that belongs to another VM.
    $claimed = $null
    try {
        $capture = Get-VMSerialCaptureRecord -VMName $VMName
        if (-not $capture) { return $false }
        if ($script:YurunaSerialCapture -and $script:YurunaSerialCapture.VMName -eq $VMName) {
            $script:YurunaSerialCapture = $null
        }
        $claimed = $capture
        Stop-VMSerialCaptureJob -VMName $VMName
        if (-not (Test-Path -LiteralPath $OutputDirectory)) {
            New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
        }
        $bytes = 0L
        if (Test-Path -LiteralPath $capture.LogPath) { $bytes = (Get-Item -LiteralPath $capture.LogPath).Length }
        if ($bytes -gt 0) {
            Copy-Item -LiteralPath $capture.LogPath -Destination (Join-Path $OutputDirectory 'serial-console.log') -Force
        }
        # The reader's own account: the sidecar the job rewrites at each change
        # of state. Without it, 0 bytes reads the same whether the reader never
        # reached the pipe or reached it and heard nothing.
        $reader = $null
        if ($capture.StatePath -and (Test-Path -LiteralPath $capture.StatePath)) {
            try { $reader = Get-Content -LiteralPath $capture.StatePath -Raw | ConvertFrom-Json } catch { $reader = $null }
            Copy-Item -LiteralPath $capture.StatePath -Destination (Join-Path $OutputDirectory 'serial-console.reader.json') -Force -ErrorAction SilentlyContinue
        }
        $connects = if ($reader) { [int]$reader.connectedCount } else { 0 }
        $attempts = if ($reader) { [int]$reader.connectAttempts } else { 0 }
        $lastError = if ($reader -and $reader.lastError) { [string]$reader.lastError } else { '(none)' }
        $readerLine = if (-not $reader) { 'reader:   no state recorded: the reader job never ran far enough to write one' }
            elseif ($connects -eq 0) { 'reader:   never connected to the pipe' }
            else { "reader:   connected $connects time(s), last at $($reader.lastConnectUtc)" }
        $info = [System.Collections.Generic.List[string]]::new()
        $info.AddRange([string[]]@(
            "vmName:   $VMName"
            "pipe:     \\.\pipe\$($capture.PipeName)"
            "bytes:    $bytes"
            "savedUtc: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture))"
            "connects: $connects"
            "attempts: $attempts"
            "lastError: $lastError"
            $readerLine
        ))
        # A reader armed for this VM earlier keeps the pipe and appends to the
        # same file when its stop never takes effect, and the reader armed after
        # it then never connects. The bytes it wrote are still the guest's. The sidecar's
        # bytesRead is current only at a disconnect, so a reader that holds the
        # pipe is judged by the count it recorded when it connected.
        $earlierBytes = 0L
        if (-not $reader -or $connects -eq 0) { $earlierBytes = $bytes }
        elseif ($reader.lastDisconnectUtc -and $reader.lastConnectUtc -and [datetime]$reader.lastDisconnectUtc -gt [datetime]$reader.lastConnectUtc) {
            $earlierBytes = [math]::Max(0L, $bytes - [long]$reader.bytesRead)
        } elseif ($null -ne $reader.earlierBytes) { $earlierBytes = [math]::Min($bytes, [long]$reader.earlierBytes) }
        if ($earlierBytes -gt 0) {
            $info.Add("earlier:  $earlierBytes of the $bytes bytes were appended by a reader armed before this one;")
            $info.Add('          it kept the pipe, so this reader''s connects and attempts do not describe them.')
        }
        $info.AddRange([string[]]@(
            'reading:  serial-console.log holds everything the guest wrote to COM1 while a reader'
            '          was connected: the journal lines journald forwards there and the kernel'
            '          messages at or above the guest''s console log level, which the stock Ubuntu'
            '          settings put at errors -- warnings and stack traces stay in the journal. A'
            '          kernel whose CPUs are wedged can hold console output and flush it much later,'
            '          so the newest line does not date when the guest stopped. 0 bytes with a'
            '          configured pipe means the guest never opened its serial port (no console='
            '          argument, or the port is absent on this platform), not that it was silent.'
            'verdict:  a reader that never connected points at the pipe: the VM worker creates'
            '          the server end only while the VM is on, under the name Set-VMComPort was'
            '          given, and nothing the guest does changes that. A reader that connected'
            '          and still saved 0 bytes points at the guest''s console= setting: the'
            '          kernel cmdline names a UART this platform does not have (ttyS0 on ARM64,'
            '          where the port is ttyAMA0) or carries no console= argument at all.'
        ))
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'serial-console.info.txt') -Encoding utf8NoBOM -Value $info.ToArray()
        return ($bytes -gt 0)
    } catch {
        Write-Verbose "Save-VMSerialCapture failed: $($_.Exception.Message)"
        return $false
    } finally {
        if ($claimed) {
            Remove-Item -LiteralPath $claimed.LogPath -Force -ErrorAction SilentlyContinue
            if ($claimed.StatePath) { Remove-Item -LiteralPath $claimed.StatePath -Force -ErrorAction SilentlyContinue }
        }
    }
}
<#
.SYNOPSIS
    Read the live serial capture of a VM without disturbing its reader.
.DESCRIPTION
    Opens the file the reader appends to with sharing that lets the reader
    keep writing, and returns the bytes after -FromOffset, at most -MaxBytes
    of the newest. The path is built from the VM name the way
    Start-VMSerialCapture builds it, so a reader that outlived the record of
    its start is read as well. A file shorter than -FromOffset was replaced by
    a new capture after the offset was taken: it is read from its start and
    marked Replaced, because it no longer holds what came before. -MaxBytes 0
    returns only the length, which is how a step marks where its own console
    output begins; a capture whose reader has not created the file yet marks
    0, since everything the file will hold is still to come.
.OUTPUTS
    [pscustomobject] Length (bytes in the file now), Offset (where Text
    starts), Text, Truncated (older bytes after -FromOffset were left out)
    and Replaced; $null when no capture file exists to read or it cannot be
    read.
#>
function Read-VMSerialCapture {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [ValidateRange(0, [long]::MaxValue)][long]$FromOffset = 0,
        [ValidateRange(0, 16777216)][int]$MaxBytes = 4194304
    )
    $logPath = Join-Path $env:TEMP "yuruna-serial-$VMName.log"
    if (-not [System.IO.File]::Exists($logPath)) {
        if ($MaxBytes -eq 0) { return [pscustomobject]@{ Length = 0L; Offset = 0L; Text = ''; Truncated = $false; Replaced = $false } }
        return $null
    }
    try {
        $stream = [System.IO.FileStream]::new($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
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
    Arm a bounded pktmon capture for one guest VM: every DHCP exchange the
    host sees, plus the guest's own ARP and ICMP frames.
.DESCRIPTION
    DHCP alone says whether a lease was asked for and granted. Whether the
    guest still speaks at all after it lost an address is a different
    question, and ARP and ICMP are what a guest with no IPv4 address, or a
    stale one, still emits. Both are scoped to the guest's MAC so the capture
    does not grow with the LAN's chatter; pktmon ANDs the conditions inside
    one filter and ORs across filters. The MAC filters are skipped when the
    MAC is unknown rather than widened to every frame.
.OUTPUTS
    [bool] $true when the capture is running.
#>
function Start-VMDhcpCapture {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic capture: records packets, changes no durable system state, and must never prompt inside a runner cycle.')]
    param([Parameter(Mandatory)][string]$VMName)
    try {
        if (-not (Get-Command pktmon.exe -ErrorAction SilentlyContinue)) {
            Write-Verbose 'pktmon not present; DHCP capture unavailable.'
            return $false
        }
        & pktmon stop 2>$null | Out-Null
        & pktmon filter remove 2>$null | Out-Null
        $etl = Join-Path $env:TEMP "yuruna-dhcp-$VMName.etl"
        Remove-Item -LiteralPath $etl -Force -ErrorAction SilentlyContinue
        & pktmon filter add YurunaDhcpSrv -p 67 2>$null | Out-Null
        & pktmon filter add YurunaDhcpCli -p 68 2>$null | Out-Null
        $guestMac = $null
        try { $guestMac = Get-VMMac -VMName $VMName } catch { $guestMac = $null }
        if ($guestMac) {
            # pktmon takes the Windows dash notation; the harness stores colons.
            $pktmonMac = (($guestMac -replace '[^0-9A-Fa-f]', '') -replace '(..)(?!$)', '$1-').ToUpperInvariant()
            & pktmon filter add YurunaGuestArp -m $pktmonMac -d ARP 2>$null | Out-Null
            & pktmon filter add YurunaGuestIcmp -m $pktmonMac -t ICMP 2>$null | Out-Null
        }
        $startOutput = & pktmon start --capture --pkt-size 0 --log-mode circular --file-size 50 -f $etl 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Verbose "pktmon start failed: $startOutput"
            & pktmon filter remove 2>$null | Out-Null
            return $false
        }
        $script:YurunaDhcpCapture = @{ VMName = $VMName; EtlPath = $etl }
        Write-Verbose "DHCP capture armed for '$VMName' -> $etl"
        return $true
    } catch {
        Write-Verbose "Start-VMDhcpCapture failed: $($_.Exception.Message)"
        return $false
    }
}

<#
.SYNOPSIS
    Stop the live DHCP capture and discard its file (the no-failure path).
.OUTPUTS
    [bool] $true when nothing is left running or on disk.
#>
function Stop-VMDhcpCapture {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic teardown: stops a packet capture and deletes its temp file; must never prompt inside a runner cycle.')]
    param()
    try {
        if (Get-Command pktmon.exe -ErrorAction SilentlyContinue) {
            & pktmon stop 2>$null | Out-Null
            & pktmon filter remove 2>$null | Out-Null
        }
        if ($script:YurunaDhcpCapture -and $script:YurunaDhcpCapture.EtlPath) {
            Remove-Item -LiteralPath $script:YurunaDhcpCapture.EtlPath -Force -ErrorAction SilentlyContinue
        }
        $script:YurunaDhcpCapture = $null
        return $true
    } catch {
        Write-Verbose "Stop-VMDhcpCapture failed: $($_.Exception.Message)"
        return $false
    }
}

<#
.SYNOPSIS
    Count, from pktmon's text rendering, the DHCP packets one guest MAC sent
    and received during a capture, and the ARP and ICMP frames it sent.
.DESCRIPTION
    pktmon logs a packet once per component it crosses, each line with its
    own group id, so a packet is counted once per source, destination and
    length within half a second; DHCP retransmits are seconds apart. A
    broadcast OFFER names its client only inside the payload, so replies are
    counted when unicast to the guest's MAC -- a lower bound the .pcapng can
    settle. Packets from other clients are counted because they show the
    capture itself was live: zero from the guest means something only beside
    a nonzero count there.

    ARP and ICMP frames from the guest are counted apart from DHCP, and kept
    out of every DHCP count: a guest whose kernel dropped its address still
    answers ARP for it or probes its gateway, so a nonzero count there beside
    zero DHCP says the guest was alive on the wire and never asked again.
    lastGuestFrameAt is the capture's own local-time stamp of the newest
    frame from the guest's MAC, whatever its protocol: when the guest was
    last heard on the wire.

    Drops are not counted: pktmon records a drop wherever a broadcast meets
    a component it does not apply to, so nearly every packet carries one,
    and where a guest's packet died is a per-component reading the .txt
    already gives.
.OUTPUTS
    [ordered] guestMac, sentByGuest, unicastToGuest, fromOtherClients,
    otherClients, guestArp, guestIcmp, lastGuestFrameAt.
#>
function Get-DhcpCaptureSummary {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$GuestMac
    )
    $guest = ($GuestMac -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    $header = [regex]'::(?<ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})(?<frac>\.\d+)?.*?PktGroupId\s+\d+'
    $frame = [regex]'^\s*(?:Drop:\s+)?(?<src>[0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5})\s*>\s*(?<dst>[0-9A-Fa-f]{2}(?:-[0-9A-Fa-f]{2}){5}).*?length\s+(?<len>\d+)'
    $lastSeen = @{}
    $previousKey = ''
    $stamp = $null
    $stampText = $null
    $lastGuestStamp = $null
    $lastGuestFrameAt = $null
    $sent = 0; $replies = 0; $others = 0; $arp = 0; $icmp = 0
    $clients = [Collections.Generic.HashSet[string]]::new()
    foreach ($line in [IO.File]::ReadLines($Path)) {
        $h = $header.Match($line)
        if ($h.Success) {
            $fraction = if ($h.Groups['frac'].Success) { $h.Groups['frac'].Value.PadRight(8, '0').Substring(0, 8) } else { '' }
            $parsed = [datetime]::MinValue
            $stamp = if ([datetime]::TryParseExact($h.Groups['ts'].Value + $fraction, [string[]]@('yyyy-MM-dd HH:mm:ss', 'yyyy-MM-dd HH:mm:ss.fffffff'),
                    [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) { $parsed } else { $null }
            $stampText = $h.Groups['ts'].Value + $h.Groups['frac'].Value
            continue
        }
        $f = $frame.Match($line)
        if (-not $f.Success) { continue }
        $src = $f.Groups['src'].Value.Replace('-', '').ToUpperInvariant()
        $dst = $f.Groups['dst'].Value.Replace('-', '').ToUpperInvariant()
        # Every line from the guest moves the last-heard stamp, dedup or not:
        # the question it answers is when the guest was last on the wire.
        if ($src -eq $guest -and $stampText -and ($null -eq $stamp -or $null -eq $lastGuestStamp -or $stamp -ge $lastGuestStamp)) {
            $lastGuestStamp = $stamp
            $lastGuestFrameAt = $stampText
        }
        $key = "$src>$dst/$($f.Groups['len'].Value)"
        $isNew = if ($stamp -and $lastSeen.ContainsKey($key)) { ($stamp - $lastSeen[$key]).TotalSeconds -gt 0.5 }
            elseif ($stamp) { $true } else { $key -ne $previousKey }
        if ($stamp) { $lastSeen[$key] = $stamp }
        $previousKey = $key
        if (-not $isNew) { continue }
        $isArp = $line -match 'ethertype ARP'
        $isIcmp = (-not $isArp) -and ($line -match '\bICMP\b')
        if ($src -eq $guest) {
            if ($isArp) { $arp++ } elseif ($isIcmp) { $icmp++ } else { $sent++ }
        }
        elseif ($isArp -or $isIcmp) { continue }
        elseif ($dst -eq $guest) { $replies++ }
        else { $others++; [void]$clients.Add($src) }
    }
    [ordered]@{
        guestMac = $GuestMac; sentByGuest = $sent; unicastToGuest = $replies
        fromOtherClients = $others; otherClients = $clients.Count
        guestArp = $arp; guestIcmp = $icmp; lastGuestFrameAt = $lastGuestFrameAt
    }
}

<#
.SYNOPSIS
    Stop the live DHCP capture and land its evidence next to the failure
    diagnostics.
.DESCRIPTION
    Written in three forms because each answers a different question: the .etl
    is the lossless original, the .txt carries pktmon's per-component
    traversal (WHERE a packet stopped), and the .pcapng carries payloads
    (WHICH identity asked). The converters are guarded separately -- a build
    that lacks one still lands the others. An info file records the VM's MAC
    so the reader knows what to grep without resolving it from Hyper-V later,
    after the VM is gone.
.OUTPUTS
    [bool] $true when at least the .etl landed in OutputDirectory.
#>
function Save-VMDhcpCapture {
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic collection: stops a packet capture and copies artifacts; must never prompt inside a runner cycle.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    $claimed = $null
    try {
        $capture = $script:YurunaDhcpCapture
        if (-not $capture -or $capture.VMName -ne $VMName) {
            Write-Verbose "no live DHCP capture belongs to '$VMName'; nothing to save."
            return $false
        }
        $guestMac = $null
        try { $guestMac = Get-VMMac -VMName $VMName } catch { $guestMac = $null }
        & pktmon stop 2>$null | Out-Null
        & pktmon filter remove 2>$null | Out-Null
        $script:YurunaDhcpCapture = $null
        $claimed = $capture
        if (-not (Test-Path -LiteralPath $capture.EtlPath)) { return $false }
        if (-not (Test-Path -LiteralPath $OutputDirectory)) {
            New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
        }
        Copy-Item -LiteralPath $capture.EtlPath -Destination (Join-Path $OutputDirectory 'dhcp.capture.etl') -Force
        $textPath = Join-Path $OutputDirectory 'dhcp.capture.txt'
        & pktmon etl2txt $capture.EtlPath -o $textPath 2>$null | Out-Null
        & pktmon etl2pcap $capture.EtlPath -o (Join-Path $OutputDirectory 'dhcp.capture.pcapng') 2>$null | Out-Null
        $summaryLine = @()
        if ($guestMac -and (Test-Path -LiteralPath $textPath)) {
            try {
                $summary = Get-DhcpCaptureSummary -Path $textPath -GuestMac $guestMac
                $summary | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'dhcp.capture.summary.json') -Encoding utf8NoBOM
                $summaryLine = @(
                    "summary:  the guest sent $($summary.sentByGuest) DHCP packet(s); $($summary.unicastToGuest) unicast reply(ies) were"
                    "          seen addressed to its MAC at the captured components; $($summary.fromOtherClients) packet(s)"
                    "          from $($summary.otherClients) other client(s) show whether the capture itself was live."
                    "          Apart from DHCP the guest sent $($summary.guestArp) ARP and $($summary.guestIcmp) ICMP frame(s); its newest"
                    "          frame of any kind was logged at $(if ($summary.lastGuestFrameAt) { "$($summary.lastGuestFrameAt) (capture local time)" } else { 'no time: none seen' })."
                    "caution:  a reply count of 0 is not proof that no lease was granted. The capture"
                    "          runs in the management OS; an OFFER or ACK the virtual switch delivers"
                    "          straight to the VM port can be absent here while the guest holds an"
                    "          address. A later SSH session or guest-side fetch outranks this count."
                    "          Drops of the guest's broadcast DISCOVER by the management stack"
                    "          (transport endpoint not found, port unreachable) are normal: this"
                    "          host is not the DHCP server."
                )
            } catch { Write-Verbose "DHCP capture summary skipped: $($_.Exception.Message)" }
        }
        Set-Content -LiteralPath (Join-Path $OutputDirectory 'dhcp.capture.info.txt') -Encoding utf8NoBOM -Value (@(
            "vmName:   $VMName"
            "guestMac: $(if ($guestMac) { $guestMac } else { '(unresolved)' })"
            "savedUtc: $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture))"
        ) + $summaryLine + @(
            'reading:  dhcp.capture.txt shows each packet at every component it crossed;'
            '          a DISCOVER present on the VM switch port but absent at the NIC'
            '          died on this host, present at the NIC with no OFFER back means'
            '          the wire or the DHCP server, and no DISCOVER at all means the'
            '          guest client never transmitted. dhcp.capture.pcapng carries the'
            '          payloads (client-id, xid) for the same packets. ARP or ICMP from'
            '          the guest after its last DHCP packet (guestArp, guestIcmp and'
            '          lastGuestFrameAt in dhcp.capture.summary.json) means the guest was'
            '          still on the wire without asking for a lease: a client that'
            '          believes it holds an address, or one whose kernel expired it.'
        ))
        return $true
    } catch {
        Write-Verbose "Save-VMDhcpCapture failed: $($_.Exception.Message)"
        return $false
    } finally {
        # The ETL runs to tens of MB; a throw while summarizing it must not
        # strand it in %TEMP%. Only a capture this call stopped is removed.
        if ($claimed) { Remove-Item -LiteralPath $claimed.EtlPath -Force -ErrorAction SilentlyContinue }
    }
}

# --- REGION: VM network state
# See https://yuruna.link/42dc5bb9-0004
# The host's own readings of a guest that dropped off the network separate a
# guest that lost its address from a host that lost the guest.
function Save-VMNetworkState {
    <#
    .SYNOPSIS
        Record the host's view of one VM's network state beside the failure
        diagnostics, as vm-network.state.txt and vm-network.state.json.
    .DESCRIPTION
        Every section is read under its own try/catch with silent errors, so a
        cmdlet missing on this build, a VM already removed or an event log that
        needs elevation costs one section and never the file. The event tail
        is bounded twice (the last 20 minutes, at most 40 events per Hyper-V
        log) because the worker logs are large and the failure is recent.
    .OUTPUTS
        [bool] $true when vm-network.state.txt landed in OutputDirectory.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic collection: reads host state into the failure folder and changes nothing else; must never prompt inside a runner cycle.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    try {
        if (-not (Test-Path -LiteralPath $OutputDirectory)) {
            New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
        }
        $state = [ordered]@{
            schema = 'yuruna.vm-network-state/v1'
            vmName = $VMName
            savedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
            vm = $null
            adapters = @()
            integrationServices = @()
            neighbors = @()
            tcp22 = @()
            events = @()
            errors = @()
        }
        $lines = [Collections.Generic.List[string]]::new()
        $lines.Add("vmName:   $VMName")
        $lines.Add("savedUtc: $($state.savedUtc)")

        try {
            $vm = Hyper-V\Get-VM -Name $VMName -ErrorAction SilentlyContinue
            if ($vm) {
                $state.vm = [ordered]@{ state = [string]$vm.State; uptime = [string]$vm.Uptime; status = [string]$vm.Status; heartbeat = [string]$vm.Heartbeat }
                $lines.Add("vm:       state=$($vm.State) uptime=$($vm.Uptime) status=$($vm.Status) heartbeat=$($vm.Heartbeat)")
            } else {
                $lines.Add('vm:       (not found)')
            }
        } catch { $state.errors += "Get-VM: $($_.Exception.Message)" }

        $macs = @()
        $ipv4 = @()
        try {
            foreach ($adapter in @(Hyper-V\Get-VMNetworkAdapter -VMName $VMName -ErrorAction SilentlyContinue)) {
                $addresses = @($adapter.IPAddresses | ForEach-Object { [string]$_ })
                $state.adapters += [ordered]@{
                    name = [string]$adapter.Name; switchName = [string]$adapter.SwitchName; connected = [bool]$adapter.Connected
                    status = [string](@($adapter.Status) -join ','); macAddress = [string]$adapter.MacAddress; ipAddresses = $addresses
                }
                $lines.Add("adapter:  name=$($adapter.Name) switch=$($adapter.SwitchName) connected=$($adapter.Connected) status=$(@($adapter.Status) -join ',') mac=$($adapter.MacAddress) ip=$(if ($addresses.Count) { $addresses -join ',' } else { '(none)' })")
                if ($adapter.MacAddress) { $macs += [string]$adapter.MacAddress }
                foreach ($address in $addresses) {
                    $parsedAddress = $null
                    if ([System.Net.IPAddress]::TryParse($address, [ref]$parsedAddress) -and $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) { $ipv4 += $address }
                }
            }
            if (-not $state.adapters.Count) { $lines.Add('adapter:  (none)') }
        } catch { $state.errors += "Get-VMNetworkAdapter: $($_.Exception.Message)" }

        try {
            foreach ($service in @(Hyper-V\Get-VMIntegrationService -VMName $VMName -ErrorAction SilentlyContinue)) {
                $state.integrationServices += [ordered]@{ name = [string]$service.Name; enabled = [bool]$service.Enabled; primaryStatusDescription = [string]$service.PrimaryStatusDescription }
                $lines.Add("service:  $($service.Name) enabled=$($service.Enabled) status=$($service.PrimaryStatusDescription)")
            }
        } catch { $state.errors += "Get-VMIntegrationService: $($_.Exception.Message)" }

        # KVP reports the MAC as bare hex; Get-NetNeighbor reports it dashed
        # and upper case, the same conversion Get-VMIp makes.
        try {
            $dashed = @(foreach ($mac in $macs) {
                $bare = $mac -replace '[^0-9A-Fa-f]', ''
                if ($bare.Length -eq 12 -and $bare -ne '000000000000') { (($bare -replace '(..)(?!$)', '$1-')).ToUpperInvariant() }
            })
            if ($dashed.Count) {
                foreach ($neighbor in @(Get-NetNeighbor -ErrorAction SilentlyContinue | Where-Object { $dashed -contains [string]$_.LinkLayerAddress })) {
                    $state.neighbors += [ordered]@{ ipAddress = [string]$neighbor.IPAddress; linkLayerAddress = [string]$neighbor.LinkLayerAddress; state = [string]$neighbor.State; interfaceAlias = [string]$neighbor.InterfaceAlias }
                    $lines.Add("neighbor: $($neighbor.IPAddress) mac=$($neighbor.LinkLayerAddress) state=$($neighbor.State) via=$($neighbor.InterfaceAlias)")
                }
            }
            if (-not $state.neighbors.Count) { $lines.Add("neighbor: (no entry for $(if ($dashed.Count) { $dashed -join ',' } else { 'an unknown MAC' }))") }
        } catch { $state.errors += "Get-NetNeighbor: $($_.Exception.Message)" }

        # Two seconds per address: the probe runs inside the failure path and
        # a guest that lost its address never answers, so the budget is the cost.
        foreach ($address in $ipv4) {
            $probe = [ordered]@{ address = $address; port = 22; open = $false; ms = $null; error = $null }
            $tcp = $null
            $clock = [Diagnostics.Stopwatch]::StartNew()
            try {
                $tcp = [System.Net.Sockets.TcpClient]::new()
                $async = $tcp.BeginConnect($address, 22, $null, $null)
                $probe.open = [bool]($async.AsyncWaitHandle.WaitOne(2000) -and $tcp.Connected)
                if (-not $probe.open) { $probe.error = 'timeout' }
            } catch { $probe.error = $_.Exception.Message } finally { if ($tcp) { $tcp.Close() } }
            $probe.ms = [int]$clock.ElapsedMilliseconds
            $state.tcp22 += $probe
            $lines.Add("tcp22:    $address open=$($probe.open) ms=$($probe.ms)$(if ($probe.error) { " error=$($probe.error)" })")
        }
        if (-not $ipv4.Count) { $lines.Add('tcp22:    (no IPv4 reported by the integration services; nothing to probe)') }

        try {
            $since = [DateTime]::Now.AddMinutes(-20)
            $logs = @(Get-WinEvent -ListLog 'Microsoft-Windows-Hyper-V-*' -ErrorAction SilentlyContinue | Where-Object { $_.RecordCount -gt 0 })
            foreach ($log in $logs) {
                $records = @(Get-WinEvent -FilterHashtable @{ LogName = $log.LogName; StartTime = $since } -MaxEvents 40 -ErrorAction SilentlyContinue)
                foreach ($record in $records) {
                    $message = [string]$record.Message
                    if ($message.Length -gt 300) { $message = $message.Substring(0, 300) }
                    $message = ($message -replace '\s+', ' ').Trim()
                    $state.events += [ordered]@{
                        timeCreated = $record.TimeCreated.ToString('o'); logName = [string]$record.LogName; id = [int]$record.Id
                        level = [string]$record.LevelDisplayName; message = $message
                    }
                    $lines.Add("event:    $($record.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)) $($record.LogName) id=$($record.Id) $($record.LevelDisplayName): $message")
                }
            }
            if (-not $state.events.Count) { $lines.Add("event:    (no Hyper-V events since $($since.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)) local time)") }
        } catch { $state.errors += "Get-WinEvent: $($_.Exception.Message)" }

        foreach ($problem in $state.errors) { $lines.Add("error:    $problem") }
        $lines.Add('reading:  adapter connected=False, or an empty ip= while the VM runs, means the')
        $lines.Add('          host side of the link is gone or KVP stopped reporting; an ip= with no')
        $lines.Add('          neighbor entry and tcp22 open=False means the host cannot reach an')
        $lines.Add('          address the guest still claims; a Reachable neighbor with tcp22 closed')
        $lines.Add('          means the guest answers ARP but sshd does not. The events are the')
        $lines.Add("          Hyper-V worker's own account of the same window.")
        $textPath = Join-Path $OutputDirectory 'vm-network.state.txt'
        Set-Content -LiteralPath $textPath -Encoding utf8NoBOM -Value $lines.ToArray()
        try {
            $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'vm-network.state.json') -Encoding utf8NoBOM
        } catch { Write-Verbose "Save-VMNetworkState: JSON form skipped: $($_.Exception.Message)" }
        return [bool](Test-Path -LiteralPath $textPath)
    } catch {
        Write-Verbose "Save-VMNetworkState failed: $($_.Exception.Message)"
        return $false
    }
}

# --- REGION: VM storage state
# A failed save or restore leaves nothing that says whether a checkpoint exists,
# and the cycle's teardown deletes the VM soon after; this reading is taken while
# it is still registered.
function Save-VMStorageState {
    <#
    .SYNOPSIS
        Record one VM's checkpoints, disk chain and storage folders beside the
        failure diagnostics, as vm-storage.state.txt and vm-storage.state.json.
    .DESCRIPTION
        The Hyper-V reads run in two bounded calls (60 s each), the second for
        the disk chain alone, so a disk read that stalls cannot discard the
        checkpoint readings. The first reads, each on its own, the VM's
        checkpoint settings and storage paths, the checkpoints the Hyper-V
        module lists and the ones Hyper-V itself records for the VM's Id
        (Msvm_VirtualSystemSettingData); the second reads every disk with its
        parent, where an .avhdx proves a checkpoint was taken whatever it is
        named. A section whose read failed or timed out is written as not read,
        never as empty. The folders that hold those disks, the VM's own folder
        under VirtualHardDiskPath and the folders there changed in the last 30
        minutes are listed, and the Hyper-V and VHDMP events of the last 20
        minutes that name the VM or its Id are kept.
    .OUTPUTS
        [bool] $true when vm-storage.state.txt landed in OutputDirectory.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Diagnostic collection: reads host state into the failure folder and changes nothing else; must never prompt inside a runner cycle.')]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$OutputDirectory
    )
    try {
        if (-not (Test-Path -LiteralPath $OutputDirectory)) {
            New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
        }
        $state = [ordered]@{
            schema = 'yuruna.vm-storage-state/v1'
            vmName = $VMName
            savedUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
            vm = $null
            # $null until read: an unread section is not an empty one.
            checkpoints = $null
            records = $null
            disks = $null
            folders = @()
            events = @()
            errors = @()
        }
        $lines = [Collections.Generic.List[string]]::new()
        $lines.Add("vmName:     $VMName")
        $lines.Add("savedUtc:   $($state.savedUtc)")

        $call = Invoke-HyperVBoundedCall -TimeoutSeconds 60 -ArgumentList @($VMName) -ScriptBlock {
            param($Name)
            # A section stays $null until its read succeeds: unread is not empty.
            $out = [ordered]@{ vhdRoot = ''; vm = $null; checkpoints = $null; records = $null; errors = @() }
            try { $out.vhdRoot = [string](Hyper-V\Get-VMHost -ErrorAction Stop).VirtualHardDiskPath } catch { $out.errors += "Get-VMHost: $($_.Exception.Message)" }
            $vm = $null
            try { $vm = @(Hyper-V\Get-VM -Name $Name -ErrorAction Stop) | Select-Object -First 1 } catch { $out.errors += "Get-VM: $($_.Exception.Message)" }
            if ($vm) {
                $out.vm = [ordered]@{
                    id = [string]$vm.Id; state = [string]$vm.State; checkpointType = [string]$vm.CheckpointType
                    parentCheckpointName = [string]$vm.ParentCheckpointName; path = [string]$vm.Path
                    configurationLocation = [string]$vm.ConfigurationLocation; snapshotFileLocation = [string]$vm.SnapshotFileLocation
                }
                try {
                    $out.checkpoints = @(Hyper-V\Get-VMCheckpoint -VMName $Name -ErrorAction Stop | ForEach-Object {
                            [ordered]@{ name = [string]$_.Name; id = [string]$_.Id; type = [string]$_.SnapshotType; created = [string]$_.CreationTime; parent = [string]$_.ParentSnapshotName }
                        })
                } catch { $out.errors += "Get-VMCheckpoint: $($_.Exception.Message)" }
                try {
                    $filter = "VirtualSystemIdentifier='{0}' AND VirtualSystemType LIKE 'Microsoft:Hyper-V:Snapshot:%'" -f ([string]$vm.Id).ToUpperInvariant()
                    $out.records = @(Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_VirtualSystemSettingData -Filter $filter -ErrorAction Stop | ForEach-Object {
                            [ordered]@{ name = [string]$_.ElementName; type = [string]$_.VirtualSystemType; created = [string]$_.CreationTime }
                        })
                } catch { $out.errors += "Msvm_VirtualSystemSettingData: $($_.Exception.Message)" }
            }
            [pscustomobject]$out
        }
        $read = if (-not $call.TimedOut -and -not $call.Error) { @($call.Output) | Select-Object -Last 1 } else { $null }
        if ($call.TimedOut) { $state.errors += 'Hyper-V settings and checkpoints: no answer within 60 s' }
        if ($call.Error) { $state.errors += "Hyper-V settings and checkpoints: $($call.Error.Exception.Message)" }
        $vhdRoot = ''
        if ($read) {
            $vhdRoot = [string]$read.vhdRoot
            $state.vm = $read.vm
            if ($null -ne $read.checkpoints) { $state.checkpoints = @($read.checkpoints) }
            if ($null -ne $read.records) { $state.records = @($read.records) }
            $state.errors += @($read.errors)
        }
        if ($state.vm) {
            $disksCall = Invoke-HyperVBoundedCall -TimeoutSeconds 60 -ArgumentList @($VMName) -ScriptBlock {
                param($Name)
                @(Hyper-V\Get-VMHardDiskDrive -VMName $Name -ErrorAction Stop | ForEach-Object {
                        $disk = [ordered]@{ path = [string]$_.Path; parentPath = ''; type = ''; fileSize = $null }
                        try {
                            $vhd = Hyper-V\Get-VHD -Path $_.Path -ErrorAction Stop
                            $disk.parentPath = [string]$vhd.ParentPath; $disk.type = [string]$vhd.VhdType; $disk.fileSize = [long]$vhd.FileSize
                        } catch { $disk.type = "unreadable: $($_.Exception.Message)" }
                        $disk
                    })
            }
            if ($disksCall.TimedOut) { $state.errors += 'Hyper-V disk chain: no answer within 60 s' }
            elseif ($disksCall.Error) { $state.errors += "Hyper-V disk chain: $($disksCall.Error.Exception.Message)" }
            else { $state.disks = @($disksCall.Output) }
        }
        if ($state.vm) {
            $lines.Add("vm:         id=$($state.vm.id) state=$($state.vm.state) checkpointType=$($state.vm.checkpointType) parentCheckpoint=$($state.vm.parentCheckpointName)")
            $lines.Add("paths:      path=$($state.vm.path) configuration=$($state.vm.configurationLocation) snapshots=$($state.vm.snapshotFileLocation)")
        } elseif ($read) { $lines.Add('vm:         (not found)') } else { $lines.Add('vm:         (not read)') }
        if ($null -eq $state.checkpoints) { $lines.Add('checkpoint: (not read)') }
        elseif (-not $state.checkpoints.Count) { $lines.Add('checkpoint: (none listed by the Hyper-V module)') }
        foreach ($checkpoint in @($state.checkpoints | Where-Object { $null -ne $_ })) { $lines.Add("checkpoint: $($checkpoint.name) id=$($checkpoint.id) type=$($checkpoint.type) created=$($checkpoint.created) parent=$($checkpoint.parent)") }
        if ($null -eq $state.records) { $lines.Add('record:     (not read)') }
        elseif (-not $state.records.Count) { $lines.Add('record:     (none recorded by Hyper-V for this VM)') }
        foreach ($record in @($state.records | Where-Object { $null -ne $_ })) { $lines.Add("record:     $($record.name) type=$($record.type) created=$($record.created)") }
        if ($null -eq $state.disks) { $lines.Add('disk:       (not read)') }
        elseif (-not $state.disks.Count) { $lines.Add('disk:       (none)') }
        foreach ($disk in @($state.disks | Where-Object { $null -ne $_ })) { $lines.Add("disk:       $($disk.path) type=$($disk.type) parent=$(if ($disk.parentPath) { $disk.parentPath } else { '-' })") }

        # Listings are capped: a folder that holds a guest disk holds a few
        # files, so a long one is itself the finding and need not be complete.
        try {
            $folders = [Collections.Generic.List[string]]::new()
            foreach ($disk in @($state.disks | Where-Object { $null -ne $_ })) {
                foreach ($path in @($disk.path, $disk.parentPath)) {
                    if ($path) { $folder = Split-Path -Parent $path; if ($folder -and -not $folders.Contains($folder)) { $folders.Add($folder) } }
                }
            }
            if ($vhdRoot) {
                $own = Join-Path $vhdRoot $VMName
                if ((Test-Path -LiteralPath $own) -and -not $folders.Contains($own)) { $folders.Add($own) }
                $since = [DateTime]::UtcNow.AddMinutes(-30)
                foreach ($changed in @(Get-ChildItem -LiteralPath $vhdRoot -Directory -Force -ErrorAction SilentlyContinue |
                            Where-Object { $_.LastWriteTimeUtc -ge $since } | Select-Object -First 10)) {
                    if (-not $folders.Contains($changed.FullName)) { $folders.Add($changed.FullName) }
                }
            }
            foreach ($folder in $folders) {
                $files = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 200)
                $entries = @($files | ForEach-Object {
                        [ordered]@{ path = [IO.Path]::GetRelativePath($folder, $_.FullName); length = [long]$_.Length; lastWriteUtc = $_.LastWriteTimeUtc.ToString('o') }
                    })
                $state.folders += [ordered]@{ folder = $folder; files = $entries }
                $lines.Add("folder:     $folder ($($entries.Count) file(s))")
                foreach ($entry in $entries) { $lines.Add("            $($entry.path) $($entry.length) $($entry.lastWriteUtc)") }
            }
        } catch { $state.errors += "folders: $($_.Exception.Message)" }

        try {
            $sinceLocal = [DateTime]::Now.AddMinutes(-20)
            $needles = @($VMName) + @(if ($state.vm -and $state.vm.id) { [string]$state.vm.id })
            $logs = @(Get-WinEvent -ListLog 'Microsoft-Windows-Hyper-V-*', 'Microsoft-Windows-VHDMP*' -ErrorAction SilentlyContinue | Where-Object { $_.RecordCount -gt 0 })
            foreach ($log in $logs) {
                foreach ($record in @(Get-WinEvent -FilterHashtable @{ LogName = $log.LogName; StartTime = $sinceLocal } -MaxEvents 200 -ErrorAction SilentlyContinue)) {
                    $message = [string]$record.Message
                    if (-not @($needles | Where-Object { $message.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count) { continue }
                    if ($message.Length -gt 300) { $message = $message.Substring(0, 300) }
                    $message = ($message -replace '\s+', ' ').Trim()
                    $state.events += [ordered]@{ timeCreated = $record.TimeCreated.ToString('o'); logName = [string]$record.LogName; id = [int]$record.Id; message = $message }
                    $lines.Add("event:      $($record.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)) $($record.LogName) id=$($record.Id): $message")
                }
            }
            if (-not $state.events.Count) { $lines.Add("event:      (no Hyper-V or VHDMP event naming the VM since $($sinceLocal.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)) local time)") }
        } catch { $state.errors += "Get-WinEvent: $($_.Exception.Message)" }

        foreach ($problem in $state.errors) { $lines.Add("error:      $problem") }
        $lines.Add('reading:    a record line is a checkpoint Hyper-V holds; a checkpoint line is one')
        $lines.Add('            the Hyper-V module lists. A record with no matching checkpoint line')
        $lines.Add("            means the module's listing does not show what Hyper-V holds; a record")
        $lines.Add('            under another name means the checkpoint was not given the requested')
        $lines.Add('            name; an .avhdx disk proves a checkpoint was taken. Only when all three')
        $lines.Add('            were read (none says not read) does neither, with no .avhdx, mean no')
        $lines.Add('            checkpoint exists for this VM.')
        $textPath = Join-Path $OutputDirectory 'vm-storage.state.txt'
        Set-Content -LiteralPath $textPath -Encoding utf8NoBOM -Value $lines.ToArray()
        try {
            $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'vm-storage.state.json') -Encoding utf8NoBOM
        } catch { Write-Verbose "Save-VMStorageState: JSON form skipped: $($_.Exception.Message)" }
        return [bool](Test-Path -LiteralPath $textPath)
    } catch {
        Write-Verbose "Save-VMStorageState failed: $($_.Exception.Message)"
        return $false
    }
}
