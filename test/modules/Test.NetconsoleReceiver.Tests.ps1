<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42efe80f-2ccd-4c3a-890a-629945247656
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test lab netconsole receiver udp pester
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
    test/lab/Receive-Netconsole.ps1 keeps every kernel line a host sends, with
    the time it arrived, in one log per sender and UTC day.
.DESCRIPTION
    The receiver runs as the real script in a child pwsh, listening on a free
    loopback port, and this suite sends it datagrams the way netconsole does.
    A line is read back while the receiver is still running, which is what
    shows it was flushed rather than buffered: the host it watches can freeze
    at any moment, and only what reached this side counts. The decoder and the
    receive-buffer request are lifted from the script for the header shapes and
    the system limits a loopback run does not need to cover.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    $script:Receiver = Join-Path $script:RepoRoot 'test/lab/Receive-Netconsole.ps1'
    $script:Stamp = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z '

    $ast = Get-YurunaTestFileAst -Path $script:Receiver
    $lifted = foreach ($name in @('$script:ExtendedHeader', '$script:ReceiveBufferBytes')) {
        $ast.Find({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $name }, $true).Extent.Text
    }
    $lifted += foreach ($name in @('ConvertFrom-NetconsoleDatagram', 'Request-NetconsoleReceiveBuffer')) { (Get-YurunaTestFunctionAst -Ast $ast -Name $name).Extent.Text }
    . ([scriptblock]::Create($lifted -join "`n"))

    # The lifted functions render their messages through this, so a case
    # asserts the key and values rather than the catalog text.
    function Format-YurunaOperatorMessage {
        param([string]$Key, [hashtable]$Arguments = @{})
        return ((@($Key) + @($Arguments.Keys | Sort-Object | ForEach-Object { "$_=$($Arguments[$_])" })) -join '|')
    }

    function Get-FreeUdpPort {
        $probe = [Net.Sockets.UdpClient]::new(0)
        try { return $probe.Client.LocalEndPoint.Port } finally { $probe.Dispose() }
    }

    function Start-Receiver {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: starts the receiver this case stops.')]
        param([int]$Port, [string]$Directory, [int]$DurationSeconds = 20, [long]$MaxFileBytes = 0)
        $info = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $script:Receiver, '-Port', "$Port", '-OutputDirectory', $Directory,
            '-DurationSeconds', "$DurationSeconds", '-Quiet')
        if ($MaxFileBytes) { $arguments += @('-MaxFileBytes', "$MaxFileBytes") }
        foreach ($argument in $arguments) { $info.ArgumentList.Add($argument) }
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.Environment['NO_COLOR'] = '1'
        $process = [Diagnostics.Process]::Start($info)
        return [pscustomobject]@{ Process = $process; Out = $process.StandardOutput.ReadToEndAsync(); Err = $process.StandardError.ReadToEndAsync() }
    }

    function Stop-Receiver {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: stops the receiver this case started.')]
        param($Receiver)
        if (-not $Receiver) { return }
        if (-not $Receiver.Process.HasExited) { $Receiver.Process.Kill($true) }
        [void]$Receiver.Process.WaitForExit(10000)
        $Receiver.Process.Dispose()
    }

    function Send-Datagram {
        param([int]$Port, [string[]]$Text)
        $client = [Net.Sockets.UdpClient]::new()
        try {
            foreach ($item in $Text) {
                $bytes = [Text.Encoding]::UTF8.GetBytes($item)
                [void]$client.Send($bytes, $bytes.Length, '127.0.0.1', $Port)
            }
        } finally { $client.Dispose() }
    }

    function Read-SharedText {
        # The receiver keeps its log open for writing; read beside it.
        param([string]$Path)
        $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try { return [IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
    }

    function Get-ReceiverLog {
        param([string]$Directory)
        return @(Get-ChildItem -LiteralPath $Directory -Filter 'netconsole-127.0.0.1-*.log' -File -ErrorAction SilentlyContinue)
    }

    function Wait-ReceiverReady {
        # Datagrams sent before the receiver binds are lost, so probe until
        # one comes back in a log.
        param($Receiver, [int]$Port, [string]$Directory)
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while ([DateTime]::UtcNow -lt $deadline -and -not $Receiver.Process.HasExited) {
            Send-Datagram -Port $Port -Text @('ready probe')
            if (@(Get-ReceiverLog -Directory $Directory).Count -gt 0) { return }
            Start-Sleep -Milliseconds 200
        }
        throw "the receiver did not start: $($Receiver.Err.Result)"
    }

    function Wait-LogText {
        param([string]$Path, [string]$Pattern, [int]$TimeoutSeconds = 15)
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ((Test-Path -LiteralPath $Path) -and ((Read-SharedText -Path $Path) -match $Pattern)) { return $true }
            Start-Sleep -Milliseconds 100
        }
        return $false
    }
}

Describe 'Receive-Netconsole.ps1' {
    It 'writes each line a host sends, stamped with its UTC arrival time, while it keeps listening' {
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-netconsole-receiver'
        $receiver = $null
        try {
            $port = Get-FreeUdpPort
            $receiver = Start-Receiver -Port $port -Directory $dir
            Wait-ReceiverReady -Receiver $receiver -Port $port -Directory $dir
            Send-Datagram -Port $port -Text @(
                "6,1234,5678901,-;hello extended`n SUBSYSTEM=net`n",
                "plain line one`nplain line two`n",
                "4,7,10,-,ncfrag=0/2000;first part",
                '13,99,123456789,-;yuruna-vitals: load=1.00,1.00,1.00')
            $log = @(Get-ReceiverLog -Directory $dir)
            Assert-Equal 1 $log.Count 'one log for the one sender and day'
            Assert-Match '^netconsole-127\.0\.0\.1-\d{8}\.log$' $log[0].Name 'named for the sender and the UTC day'
            Assert-True (Wait-LogText -Path $log[0].FullName -Pattern 'yuruna-vitals') 'the last line arrives'
            Assert-False $receiver.Process.HasExited 'the line was readable while the receiver still ran, so it was flushed'
            $lines = @((Read-SharedText -Path $log[0].FullName) -split "`n" | Where-Object { $_ -and $_ -notmatch 'ready probe$' })
            foreach ($line in $lines) { Assert-Match $script:Stamp $line 'every line starts with its UTC arrival time' }
            $text = ($lines | ForEach-Object { $_ -replace $script:Stamp, '' }) -join "`n"
            Assert-Equal (@(
                    '[     5.678901] <6> seq=1234 hello extended'
                    ' SUBSYSTEM=net'
                    'plain line one'
                    'plain line two'
                    '[     0.000010] <4> seq=7 part=0/2000 first part'
                    '[   123.456789] <5> seq=99 yuruna-vitals: load=1.00,1.00,1.00'
                ) -join "`n") $text 'extended records decoded, plain lines kept, the dictionary kept, a fragment marked, a /dev/kmsg line at its own level'
        } finally {
            Stop-Receiver -Receiver $receiver
            Remove-YurunaTestTempDir $dir
        }
    }

    It 'moves a full log to .1 and keeps the newest lines' {
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-netconsole-rotate'
        $receiver = $null
        try {
            $port = Get-FreeUdpPort
            $receiver = Start-Receiver -Port $port -Directory $dir -MaxFileBytes 4096
            Wait-ReceiverReady -Receiver $receiver -Port $port -Directory $dir
            $filler = 'x' * 90
            Send-Datagram -Port $port -Text @(1..60 | ForEach-Object { 'line {0:d2} {1}' -f $_, $filler })
            $log = @(Get-ReceiverLog -Directory $dir)[0].FullName
            Assert-True (Wait-LogText -Path $log -Pattern 'line 60 ') 'the newest line is in the live log'
            Assert-True (Test-Path -LiteralPath "$log.1") 'the full log moved aside'
            Assert-Match 'line 01 ' (Read-SharedText -Path "$log.1") 'the earlier lines are in .1'
            foreach ($path in @($log, "$log.1")) { Assert-True ((Get-Item -LiteralPath $path).Length -le 4096) "$path stays within -MaxFileBytes" }
        } finally {
            Stop-Receiver -Receiver $receiver
            Remove-YurunaTestTempDir $dir
        }
    }

    It 'keeps every line of a burst sent back to back, as a host sends its backtraces before a panic' {
        # The receiver asks for the same buffer; a host that grants less makes
        # it warn instead (next case), and this case cannot hold there.
        $probe = [Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
        try {
            Request-NetconsoleReceiveBuffer -Socket $probe -Bytes $script:ReceiveBufferBytes -WarningVariable short -WarningAction SilentlyContinue
        } finally { $probe.Dispose() }
        if ($short) { Set-ItResult -Skipped -Because "this host grants a smaller UDP receive buffer than the receiver asks for; raise net.core.rmem_max ($short)"; return }
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-netconsole-burst'
        $receiver = $null
        try {
            $port = Get-FreeUdpPort
            $receiver = Start-Receiver -Port $port -Directory $dir -DurationSeconds 60
            Wait-ReceiverReady -Receiver $receiver -Port $port -Directory $dir
            Send-Datagram -Port $port -Text @(1..1000 | ForEach-Object { '4,{0},{1},-;burst {0:d4} NMI backtrace for cpu {2}' -f $_, (5000000 + $_), ($_ % 20) })
            $log = @(Get-ReceiverLog -Directory $dir)[0].FullName
            [void](Wait-LogText -Path $log -Pattern 'burst 1000 ' -TimeoutSeconds 30)
            $kept = @([regex]::Matches((Read-SharedText -Path $log), 'burst (\d{4}) ') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            Assert-Equal 1000 $kept.Count 'every datagram of the burst is in the log, the last ones included'
        } finally {
            Stop-Receiver -Receiver $receiver
            Remove-YurunaTestTempDir $dir
        }
    }

    It 'warns at start when the system grants a smaller receive buffer than it asks for' {
        # Linux caps the request at net.core.rmem_max without an error.
        $capped = [pscustomobject]@{}
        $capped | Add-Member -MemberType ScriptProperty -Name ReceiveBufferSize -Value { 425984 } -SecondValue { param($value) Write-Verbose "capped, not $value" }
        Request-NetconsoleReceiveBuffer -Socket $capped -Bytes 4194304 -WarningVariable cappedWarning -WarningAction SilentlyContinue
        Assert-Equal 'runner.netconsole_receiver_small_buffer|granted=425984|requested=4194304' "$(@($cappedWarning)[0])" 'a capped buffer is reported with both sizes'
        # Other systems refuse a request above their limit.
        $refusing = [pscustomobject]@{}
        $refusing | Add-Member -MemberType ScriptProperty -Name ReceiveBufferSize -Value { 212992 } -SecondValue { throw [Net.Sockets.SocketException]::new(105) }
        Request-NetconsoleReceiveBuffer -Socket $refusing -Bytes 4194304 -WarningVariable refusedWarning -WarningAction SilentlyContinue
        Assert-Equal 'runner.netconsole_receiver_small_buffer|granted=212992|requested=4194304' "$(@($refusedWarning)[0])" 'a refused request is reported with the size left'
        # Linux reports a granted request doubled.
        $granted = [pscustomobject]@{ Size = 0 }
        $granted | Add-Member -MemberType ScriptProperty -Name ReceiveBufferSize -Value { $this.Size } -SecondValue { param($value) $this.Size = 2 * $value }
        Request-NetconsoleReceiveBuffer -Socket $granted -Bytes 4194304 -WarningVariable grantedWarning -WarningAction SilentlyContinue
        Assert-Equal 8388608 $granted.Size 'the request reached the socket'
        Assert-Equal 0 @($grantedWarning).Count 'a granted buffer is silent'
    }

    It 'stops at -DurationSeconds and exits 0' {
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-netconsole-duration'
        $receiver = $null
        try {
            $receiver = Start-Receiver -Port (Get-FreeUdpPort) -Directory $dir -DurationSeconds 2
            Assert-True ($receiver.Process.WaitForExit(30000)) 'the receiver stops by itself'
            Assert-Equal 0 $receiver.Process.ExitCode "a timed run ends cleanly: $($receiver.Err.Result)"
        } finally {
            Stop-Receiver -Receiver $receiver
            Remove-YurunaTestTempDir $dir
        }
    }

    It 'exits 1 when the port is taken' {
        $dir = New-YurunaTestTempDir -Prefix 'yuruna-netconsole-taken'
        $holder = [Net.Sockets.Socket]::new([Net.Sockets.AddressFamily]::InterNetwork, [Net.Sockets.SocketType]::Dgram, [Net.Sockets.ProtocolType]::Udp)
        $receiver = $null
        try {
            if ($IsWindows) { $holder.ExclusiveAddressUse = $true }
            $holder.Bind([Net.IPEndPoint]::new([Net.IPAddress]::Any, 0))
            $receiver = Start-Receiver -Port $holder.LocalEndPoint.Port -Directory $dir -DurationSeconds 5
            Assert-True ($receiver.Process.WaitForExit(30000)) 'the receiver gives up at once'
            Assert-Equal 1 $receiver.Process.ExitCode "a port in use is a refusal: $($receiver.Err.Result)"
        } finally {
            Stop-Receiver -Receiver $receiver
            $holder.Dispose()
            Remove-YurunaTestTempDir $dir
        }
    }

    It 'decodes a release-prefixed header and leaves a line that only looks numeric as plain text' {
        Assert-Equal '[     1.500000] <3> seq=42 disk error' (ConvertFrom-NetconsoleDatagram -Text '6.8.0-31-generic,3,42,1500000,-;disk error') 'the kernel release prefix'
        Assert-Equal '[     0.000001] <7> seq=8 continued' (ConvertFrom-NetconsoleDatagram -Text '7,8,1,c;continued') 'a continuation record'
        Assert-Equal '10,20,30 apples' (ConvertFrom-NetconsoleDatagram -Text '10,20,30 apples') 'no header, no decoding'
        Assert-Equal 0 @(ConvertFrom-NetconsoleDatagram -Text "`n`r`n").Count 'an empty datagram writes nothing'
    }
}
