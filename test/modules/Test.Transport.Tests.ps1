<#PSScriptInfo
.VERSION 2026.10.30
.GUID 42869a92-a8d2-410d-9364-cdfba1a4ed8e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test transport vnc pester
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
    Pester coverage for Read-VncBuffer in Test.Transport.psm1: the fixed-size
    RFB read honors an optional wall-clock deadline that bounds the whole
    multi-read handshake, independent of the per-read socket ReceiveTimeout.
.DESCRIPTION
    Read-VncBuffer is pure over a System.IO.Stream, so a MemoryStream drives it
    with no socket. Throw-based assertions, with the Assert-* helpers in the
    file's BeforeAll so they are visible to the It blocks under Pester 5.
#>

BeforeAll {
$here       = Split-Path -Parent $PSCommandPath
$modulePath = Join-Path $here 'Test.Transport.psm1'
Import-Module $modulePath -Force -DisableNameChecking -ErrorAction SilentlyContinue

Import-Module (Join-Path (Split-Path -Parent $PSCommandPath) 'Test.Assert.psm1') -Force -Global -DisableNameChecking


function Get-TransportAst {
    $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$null, [ref]$errs)
    if ($errs) { throw "Parse errors in $($modulePath): $($errs[0].Message)" }
    return $ast
}
function Get-TransportFunctionText {
    param([string]$Name)
    $fn = @((Get-TransportAst).FindAll({ param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name
    }, $true))
    if ($fn.Count -eq 0) { throw "Function '$Name' not found in Test.Transport.psm1" }
    return $fn[0].Extent.Text
}

function Invoke-BashRoundTrip {
    param([string]$Source)
    $start = [Diagnostics.ProcessStartInfo]::new($script:BashPath)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    # The Cygwin runtime behind Windows bash re-parses the command line and strips single
    # quotes, so the source travels on stdin there and on the command line elsewhere.
    if ($IsWindows) { $start.RedirectStandardInput = $true; $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false); $start.ArgumentList.Add('-s') }
    else { $start.ArgumentList.Add('-c'); $start.ArgumentList.Add($Source) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        if ($IsWindows) {
            $process.StandardInput.Write($Source + [char]10)
            $process.StandardInput.Close()
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { $process.Kill($true); throw 'Bash round-trip timed out.' }
        if ($process.ExitCode -ne 0) { throw $stderr.GetAwaiter().GetResult() }
        return $stdout.GetAwaiter().GetResult()
    } finally { $process.Dispose() }
}
$script:BashPath = if ($IsWindows) {
    $gitBash = Join-Path $env:ProgramFiles 'Git/bin/bash.exe'
    if (Test-Path -LiteralPath $gitBash) { $gitBash }
} else { (Get-Command bash -ErrorAction SilentlyContinue).Source }

# --- REGION: Held-key release on an interrupted VNC send
# Shadows the module-internal transport primitives inside Test.Transport's own
# session state, so the press/release stream is observable with no socket. This
# has to sit in the same scope as the Import-Module above: the shadowing runs
# against the imported module object, which no other scope can resolve.
$script:TransportModule = Get-Module Test.Transport
& $script:TransportModule {
    function script:Connect-VNC {
        # The unused parameters are the point: the code under test binds these
        # by name, so the stub has to accept the same signature as the real
        # primitive. It hands back a sentinel instead of opening a socket.
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Shadow stub; the signature must match the real Connect-VNC for the caller to bind, and there is nothing to connect to.')]
        param($VMName, $Port)
        [pscustomobject]@{ Fake = $true }
    }
    function script:Disconnect-VNC { $script:disconnected = $true }
    function script:Send-VncKeyEvent {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
            Justification = 'Shadow stub; $Client is the connection handle the real primitive writes to, and this one records the press/release stream instead.')]
        param($Client, $KeySym, $Down)
        $script:n++
        if ($script:failAt -gt 0 -and $script:n -eq $script:failAt) {
            throw [System.IO.IOException]::new('injected mid-send failure')
        }
        [void]$script:rec.Add([pscustomobject]@{ Sym = [int]$KeySym; Down = [bool]$Down })
    }
    # One write carries both halves, and a write that dies part-way can still
    # have delivered the press: record it as the two events it puts on the wire.
    function script:Send-VncKeyTap {
        param($Client, $KeySym)
        Send-VncKeyEvent -Client $Client -KeySym $KeySym -Down $true
        Send-VncKeyEvent -Client $Client -KeySym $KeySym -Down $false
    }
}
function Reset-KeyRecording {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Clears three in-memory recording variables inside the test module scope; nothing outside this file is touched and -WhatIf on a fixture reset is meaningless.')]
    param([int]$FailAt = 0)
    & $script:TransportModule { param($f)
        $script:rec = [System.Collections.ArrayList]::new()
        $script:n = 0; $script:failAt = $f; $script:disconnected = $false } $FailAt
}
# Any keysym with more presses than releases is a key still down in the guest,
# which the guest kernel auto-repeats at the console default until the VM dies.
function Get-HeldKeySym {
    $rec = & $script:TransportModule { , $script:rec.ToArray() }
    $tally = @{}
    foreach ($e in $rec) { $tally[$e.Sym] = ($tally[$e.Sym] ?? 0) + ($e.Down ? 1 : -1) }
    return @($tally.GetEnumerator() | Where-Object { $_.Value -ne 0 } | ForEach-Object { $_.Key })
}
}

Describe 'Read-VncBuffer wall-clock deadline' {

    It 'reads exactly Count bytes (no deadline supplied = backward compatible)' {
        $s = [System.IO.MemoryStream]::new([byte[]](1..12))
        $buf = Read-VncBuffer -Stream $s -Count 12
        Assert-True ($buf.Length -eq 12) 'returns the requested count'
        Assert-True ($buf[0] -eq 1 -and $buf[11] -eq 12) 'returns the actual bytes'
    }

    It 'returns the bytes when the deadline is in the future' {
        $s = [System.IO.MemoryStream]::new([byte[]](1..4))
        $buf = Read-VncBuffer -Stream $s -Count 4 -Deadline ([DateTime]::UtcNow.AddSeconds(30))
        Assert-True ($buf.Length -eq 4) 'a comfortable deadline does not interfere'
    }

    It 'throws once the wall-clock deadline has passed' {
        $s = [System.IO.MemoryStream]::new([byte[]](1..12))
        Assert-Throw { Read-VncBuffer -Stream $s -Count 12 -Deadline ([DateTime]::UtcNow.AddSeconds(-1)) } 'deadline' -Because 'a past deadline must throw before/at the first read'
    }

    It 'throws when the stream closes before Count bytes arrive' {
        $s = [System.IO.MemoryStream]::new([byte[]](1..5))
        Assert-Throw { Read-VncBuffer -Stream $s -Count 12 -Deadline ([DateTime]::UtcNow.AddSeconds(30)) } 'closed' -Because 'a short stream (EOF) must throw the connection-closed error'
    }
}

Describe 'UTM shell text round trips' {
    It 'preserves quoted text and shell syntax without shifted keystrokes' {
        if (-not $script:BashPath) { Set-ItResult -Skipped -Because 'Bash is unavailable for shell round trips.'; return }
        $unicode = [string][char]0x4F60 + [char]0x597D + [char]0x05E9
        foreach ($command in @(
            'printf ''%s\n'' ''literal\x41'''
            'printf ''%s\n'' ''path\folder'''
            'printf ''%s'' ''  A   B  '''
            'printf ''%s'' ''A_B !@#$%^&(){}|:"<>?~'''
            'printf ''%s\n'' ''$(never-run) `never-run` * ? [abc]'''
            "printf '%s' 'first`nsecond`tend'"
            ("printf '%s' '" + $unicode + "'")
            'printf ''%s'' ''one''; printf ''%s'' ''two'''
        )) {
            $encoded = ConvertTo-ShellEscapedText -Text $command
            Assert-False (Test-HardCharsInText -Text $encoded) 'the wrapper must use only unshifted keys'
            $actual = Invoke-BashRoundTrip -Source $encoded
            $expected = Invoke-BashRoundTrip -Source $command
            Assert-True ([string]::Equals($actual, $expected, [StringComparison]::Ordinal)) "shell encoding changed: $command"
        }
    }
}

Describe 'transport configuration character delay' {
    It 'accepts an explicit zero from refreshed configuration' {
        $before = & $script:TransportModule { $script:DefaultCharDelayMs }
        Mock Read-TestConfig -ModuleName Test.Transport { @{ vmCommunication = @{ charDelayMs = 0 } } }
        try {
            Update-TransportDefault -Force
            Assert-Equal -Expected 0 -Actual (& $script:TransportModule { $script:DefaultCharDelayMs }) -Because 'zero disables per-character pacing'
        } finally { & $script:TransportModule { param($value) $script:DefaultCharDelayMs = $value } $before }
    }
}

# --- REGION: Control-chord plumbing
# The chord path cannot be exercised against a real guest here (it needs a VM,
# a VNC server or a raised UTM window), so these guard the two failure modes
# that are silent at runtime: a chord name falling through to the "unknown
# key" branch, and a multi-key chord being flattened into a single keypress.
# A flattened Ctrl-U types a bare 'u' into the guest instead of killing the
# line, which looks like success at every layer.


Describe 'Control-chord support across the Send-Key backends' {

    It 'rejects a chord name the UTM chord table does not define' {
        # Pure: the lookup fails before any window is raised or osascript runs.
        Assert-True ((Send-ChordUTM -VMName 'nosuchvm' -KeyName 'CtrlNope' -WarningAction SilentlyContinue) -eq $false) `
            'an unknown chord must report failure, not warn-and-return-true'
    }

    It 'routes a chord name out of the AppleScript key path on UTM' {
        # `key code` cannot hold a modifier across the base key, so a chord
        # must leave Send-KeyUTM for the CGEvent path.
        $text = Get-TransportFunctionText -Name 'Send-KeyUTM'
        Assert-True ($text -match 'UtmChords') 'Send-KeyUTM must consult the chord table'
        Assert-True ($text -match 'Send-ChordUTM') 'Send-KeyUTM must delegate chords to Send-ChordUTM'
    }

    It 'consults the chord table before the scalar named table on every backend' {
        # The named maps hold one code per name and do not contain chord
        # names, so a backend that checks only the named map reports
        # "Unknown key 'CtrlU'" and sends nothing.
        foreach ($pair in @(
            @{ fn = 'Send-KeyVNC';    map = 'X11Chords' }
            @{ fn = 'Send-KeyHyperV'; map = 'Ps2Chords' }
        )) {
            $text = Get-TransportFunctionText -Name $pair.fn
            Assert-True ($text -match $pair.map) "$($pair.fn) must consult $($pair.map)"
        }
        $kvm = Get-TransportFunctionText -Name 'Send-KeyKvm'
        Assert-True ($kvm -match "KVM-Chord") 'Send-KeyKvm must consult the KVM-Chord map'
    }

    It 'splats the KVM chord so both keycodes reach virsh' {
        # `virsh send-key <domain> KEY_LEFTCTRL KEY_U` needs two POSITIONAL
        # arguments. Passing the array as one argument sends a single
        # unrecognized token, and passing only its first element sends a
        # lone Ctrl -- both look like a successful call.
        $text = Get-TransportFunctionText -Name 'Send-KeyKvm'
        Assert-True ($text -match '@codes') 'the chord array must be splatted onto virsh send-key'
    }

    It 'releases the modifier after the base key on the Hyper-V chord' {
        # The PS/2 controller tracks "is down" per code, so the modifier's
        # break must come last or Ctrl stays latched into the next keystroke.
        $text = Get-TransportFunctionText -Name 'Send-KeyHyperV'
        Assert-True ($text -match '(?s)\$modMake,\s*\r?\n\s*\$baseMake,\s*\r?\n\s*\[byte\]\(\$baseMake -bor 0x80\),\s*\r?\n\s*\[byte\]\(\$modMake -bor 0x80\)') `
            'chord order must be modifier make, base make, base break, modifier break'
    }

    It 'sets the control flag on the CGEvent chord and clears it on release' {
        # The flagged events are what make the guest see Ctrl held; the
        # release is posted UNFLAGGED so the HID-system source clears the
        # modifier for the next key.
        $text = Get-TransportFunctionText -Name 'Send-ChordUTM'
        Assert-True ($text -match 'CGEventSetFlags\(modDn, modFlag\)') 'the modifier press must carry the flag'
        Assert-True ($text -match 'CGEventSetFlags\(down, modFlag\)')  'the base press must carry the flag'
        Assert-True ($text -match '(?s)var modUp = \$\.CGEventCreateKeyboardEvent\(src, modKeyCode, false\);\s*\r?\n\s*\$\.CGEventPost\(0, modUp\);') `
            'the modifier release must be posted without a flag'
    }
}


Describe 'VNC sends never leave a key held in the guest' {

    It 'pairs every press with a release on a clean text send' {
        Reset-KeyRecording
        Assert-True ((Send-TextVNC -VMName 'vm' -Text 'aB c' -CharDelayMs 0) -eq $true) 'clean send must report success'
        Assert-True ((Get-HeldKeySym).Count -eq 0) "clean send left keys held: $(Get-HeldKeySym)"
    }

    It 'releases the character key when the send dies between its press and release' {
        # 'ab' unshifted emits down(a) up(a) down(b) up(b); failing the 4th
        # write is the exact shape seen in production -- the press landed in
        # the guest, the release never did, and 'b' auto-repeated forever.
        Reset-KeyRecording -FailAt 4
        Assert-True ((Send-TextVNC -VMName 'vm' -Text 'ab' -CharDelayMs 0 3>$null) -eq $false) `
            'an interrupted send must report failure'
        Assert-True ((Get-HeldKeySym).Count -eq 0) "interrupted send left keys held: $(Get-HeldKeySym)"
    }

    It 'releases Shift too when the send dies inside a shifted character' {
        # 'A' emits down(Shift) down(a) up(a) up(Shift); fail the 3rd write.
        Reset-KeyRecording -FailAt 3
        Send-TextVNC -VMName 'vm' -Text 'A' -CharDelayMs 0 3>$null | Out-Null
        Assert-True ((Get-HeldKeySym).Count -eq 0) "shifted interrupt left keys held: $(Get-HeldKeySym)"
    }

    It 'releases the key when a single Send-KeyVNC dies mid-pair' {
        # This is the path that sends Enter after every typed command.
        Reset-KeyRecording -FailAt 2
        Send-KeyVNC -VMName 'vm' -KeyName 'Enter' 3>$null | Out-Null
        Assert-True ((Get-HeldKeySym).Count -eq 0) "interrupted Enter left keys held: $(Get-HeldKeySym)"
    }

    It 'releases both halves when a chord dies between the base press and release' {
        # CtrlU emits down(Ctrl) down(u) up(u) up(Ctrl); fail the 3rd write.
        Reset-KeyRecording -FailAt 3
        Send-KeyVNC -VMName 'vm' -KeyName 'CtrlU' 3>$null | Out-Null
        Assert-True ((Get-HeldKeySym).Count -eq 0) "interrupted chord left keys held: $(Get-HeldKeySym)"
    }
}

Describe 'VNC key taps reach the server with their release' {
    # A release that trails its press by more than the guest's autorepeat delay
    # types the key twice. Nagle holds a small second write until the first is
    # acknowledged, and a VNC server that sends nothing back acknowledges late.

    It 'writes the press and the release of a key in one stream write' {
        $tap = [System.Management.Automation.Language.Parser]::ParseInput((Get-TransportFunctionText -Name 'Send-VncKeyTap'), [ref]$null, [ref]$null)
        $writes = @($tap.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Extent.Text -eq 'Write' }, $true))
        Assert-Equal -Expected 1 -Actual $writes.Count -Because 'both KeyEvent messages go out in a single write'
        foreach ($keySender in 'Send-TextVNC', 'Send-KeyVNC') {
            Assert-True ((Get-TransportFunctionText -Name $keySender) -match 'Send-VncKeyTap') "$keySender types each ordinary key as one tap"
        }
    }

    It 'puts a down KeyEvent and then an up KeyEvent for the same keysym on the wire' {
        . ([scriptblock]::Create((Get-TransportFunctionText -Name 'Send-VncKeyTap')))
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $client.Connect([System.Net.IPAddress]::Loopback, ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port)
            $server = $listener.AcceptTcpClient()
            try {
                Send-VncKeyTap -Client $client -KeySym 0x70
                $received = [byte[]]::new(16)
                $stream = $server.GetStream()
                $stream.ReadTimeout = 5000
                $read = 0
                while ($read -lt 16) { $got = $stream.Read($received, $read, 16 - $read); if ($got -le 0) { break }; $read += $got }
                Assert-Equal -Expected '04010000000000700400000000000070' -Actual ([Convert]::ToHexString($received)) -Because 'down(p) then up(p), RFB KeyEvent layout'
            } finally { $server.Dispose(); $client.Dispose() }
        } finally { $listener.Stop() }
    }

    It 'turns off Nagle on the VNC connection' {
        Assert-True ((Get-TransportFunctionText -Name 'Connect-VNC') -match '\$tcp\.NoDelay\s*=\s*\$true') 'Connect-VNC sets TcpClient.NoDelay'
    }
}

Describe 'VNC connection reuse after its server closed it' {
    # QEMU closes every RFB client when its VM stops. The cached connection
    # still reads as connected, a key written to it succeeds locally and is
    # discarded, and only the write after that one fails.

    BeforeAll {
        # The real primitives, outside the module whose copies the file-level
        # BeforeAll shadows, over the one key and no chords.
        $names = 'Read-VncBuffer', 'Add-VncConnectionEvent', 'Get-VncConnectionEvent', 'Test-VncConnectionOpen',
            'Connect-VNC', 'Disconnect-VNC', 'Send-VncKeyEvent', 'Send-VncKeyTap', 'Send-KeyVNC'
        $functions = ($names | ForEach-Object { Get-TransportFunctionText -Name $_ }) -join "`n`n"
        $state = @'
$script:VncConnectionEvents = [System.Collections.Generic.List[object]]::new()
$script:CachedVnc = $null
$script:CachedVncVM = $null
$script:X11KeySyms = @{ Enter = 0xFF0D }
$script:X11Chords = @{}
function Format-YurunaOperatorMessage { param($Key, $Arguments) $null = $Arguments; $Key }
'@
        $script:wireModule = New-Module -ScriptBlock ([scriptblock]::Create($state + "`n" + $functions))
        # Answers each connection's handshake, reads one key tap, then closes
        # its end, the way a stopping VM's QEMU does. A connection that never
        # comes ends it: a blocked accept does not wake when its listener stops.
        $script:FakeRfbServer = {
            param($Listener, $Connections, $Taps)
            # Version, one security type (None), SecurityResult OK, and ServerInit for a 1x1 desktop with no name.
            $greeting = [byte[]](@([Text.Encoding]::ASCII.GetBytes("RFB 003.008`n")) + @(1, 1) + @(0, 0, 0, 0) + @(0, 1, 0, 1) + @(@(0) * 16) + @(0, 0, 0, 0))
            for ($n = 0; $n -lt $Connections; $n++) {
                $accepting = $Listener.AcceptTcpClientAsync()
                if (-not $accepting.Wait(10000)) { break }
                $peer = $accepting.Result
                $tap = ''
                try {
                    $stream = $peer.GetStream()
                    $stream.ReadTimeout = 10000
                    $stream.Write($greeting, 0, $greeting.Length)
                    # The client's version, security choice and ClientInit (14 bytes), then one tap (16).
                    $buffer = [byte[]]::new(30)
                    $read = 0
                    while ($read -lt 30) { $got = $stream.Read($buffer, $read, 30 - $read); if ($got -le 0) { break }; $read += $got }
                    $tap = [Convert]::ToHexString($buffer, 14, [Math]::Max(0, $read - 14))
                } finally { $peer.Dispose() }
                $Taps.Enqueue($tap)
            }
        }
    }

    It 'opens a new connection for the next key instead of writing it into the closed one' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $taps = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $server = [powershell]::Create()
        try {
            [void]$server.AddScript($script:FakeRfbServer).AddArgument($listener).AddArgument(2).AddArgument($taps)
            $serving = $server.BeginInvoke()
            $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
            Assert-True (& $script:wireModule { param($p) Send-KeyVNC -VMName 'vm' -KeyName 'Enter' -Port $p } $port) 'the first key is sent'
            # The scenario starts once the server has closed its end and the
            # close has reached the client.
            $deadline = [DateTime]::UtcNow.AddSeconds(10)
            while ($taps.Count -lt 1 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
            $cached = & $script:wireModule { $script:CachedVnc }
            while (-not $cached.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
            Assert-True $cached.Connected 'the closed connection still reads as connected'
            Assert-True (& $script:wireModule { param($p) Send-KeyVNC -VMName 'vm' -KeyName 'Enter' -Port $p 6>$null } $port) 'the second key is sent'
            Assert-True ($serving.AsyncWaitHandle.WaitOne(20000)) 'the fake server finished'
            Assert-Equal -Expected '040100000000FF0D040000000000FF0D|040100000000FF0D040000000000FF0D' -Actual ($taps.ToArray() -join '|') `
                -Because "the second Enter reaches the server on a new connection; server errors: $($server.Streams.Error -join '; ')"
            $kinds = @(& $script:wireModule { Get-VncConnectionEvent -VMName 'vm' } | ForEach-Object Kind)
            Assert-Equal -Expected 'opened,server-closed,opened' -Actual ($kinds -join ',') -Because 'the closed connection is recorded between the two opens'
        } finally {
            $listener.Stop()
            & $script:wireModule { Disconnect-VNC }
            $server.Dispose()
        }
    }

    It 'tells an open connection from one its server closed, after reading what the server sent unasked' {
        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $client.Connect([System.Net.IPAddress]::Loopback, ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port)
            $peer = $listener.AcceptTcpClient()
            try {
                Assert-True (& $script:wireModule { param($c) Test-VncConnectionOpen -Client $c } $client) 'an idle open connection is open'
                # An RFB Bell message: one byte the server may send at any time.
                $peer.GetStream().WriteByte(2)
                $deadline = [DateTime]::UtcNow.AddSeconds(10)
                while ($client.Available -lt 1 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
                Assert-True (& $script:wireModule { param($c) Test-VncConnectionOpen -Client $c } $client) 'a connection with a message waiting is open'
                Assert-Equal -Expected 0 -Actual $client.Available -Because 'the unasked message is read and dropped'
                $peer.Dispose()
                while (-not $client.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
                Assert-True (-not (& $script:wireModule { param($c) Test-VncConnectionOpen -Client $c } $client)) 'a connection its server closed is not open'
            } finally { $peer.Dispose(); $client.Dispose() }
        } finally { $listener.Stop() }
    }
}

Describe 'Hyper-V keyboard cache invalidation' {
    # See https://yuruna.link/42e220c4-0014
    # Shadow native CIM inside the module and remove the fixture after each case.
    AfterEach {
        InModuleScope 'Test.Transport' {
            Remove-Item -LiteralPath 'function:script:Invoke-CimMethod' -ErrorAction SilentlyContinue
        }
    }

    It 'drops the cached handle when the send throws' {
        $r = InModuleScope 'Test.Transport' {
            $script:CachedKb = [pscustomobject]@{ Name = 'sentinel' }; $script:CachedKbVM = 'test-vm-01'
            Set-Item -Path function:script:Invoke-CimMethod -Value { throw 'stale handle' }
            $threw = $false
            try { Send-ScanCode -Keyboard 'kb' -Codes ([byte[]]@(0x1C)) | Out-Null } catch { $threw = $true }
            @{ Threw = $threw; Cached = $script:CachedKb }
        }
        Assert-True $r.Threw 'a WMI error must still surface to the caller'
        Assert-True ($null -eq $r.Cached) `
            'a throwing send must leave no cached handle for the next attempt to reuse'
    }

    It 'drops the cached handle when the send reports a non-zero ReturnValue' {
        $r = InModuleScope 'Test.Transport' {
            $script:CachedKb = [pscustomobject]@{ Name = 'sentinel' }; $script:CachedKbVM = 'test-vm-01'
            Set-Item -Path function:script:Invoke-CimMethod -Value { @{ ReturnValue = 32768 } }
            $ok = Send-ScanCode -Keyboard 'kb' -Codes ([byte[]]@(0x1C))
            @{ Ok = $ok; Cached = $script:CachedKb }
        }
        Assert-True (-not $r.Ok) 'a non-zero ReturnValue is a failed delivery'
        Assert-True ($null -eq $r.Cached) `
            'a rejected send must invalidate the handle too, not only a throw'
    }

    It 'keeps the cached handle when the send succeeds' {
        # The cache exists to spare a WMI lookup per keystroke; clearing it on
        # the happy path would give that back on every send.
        $r = InModuleScope 'Test.Transport' {
            $script:CachedKb = [pscustomobject]@{ Name = 'sentinel' }; $script:CachedKbVM = 'test-vm-01'
            Set-Item -Path function:script:Invoke-CimMethod -Value { @{ ReturnValue = 0 } }
            $ok = Send-ScanCode -Keyboard 'kb' -Codes ([byte[]]@(0x1C))
            @{ Ok = $ok; Cached = $script:CachedKb }
        }
        Assert-True $r.Ok 'ReturnValue 0 is success'
        Assert-True ($null -ne $r.Cached) `
            'a successful send must not cost the next one a re-resolve'
    }
}

Describe 'Send-ScanCode reports why the synthetic keyboard refused' {

    It 'names the Msvm_Keyboard refusals a Hyper-V host actually hits' {
        # Both codes reach the same $false, and the repairs differ: 32769 is
        # the harness running unelevated, and 32775 is a handle addressing no
        # live keyboard -- which the re-resolve fixes when it is a stale
        # instance and cannot fix when the guest has no VMBus keyboard driver
        # at all. A bare "pressKey returned false" in the transcript cannot
        # tell an operator which one to go fix.
        $text = Get-TransportFunctionText -Name 'Send-ScanCode'
        Assert-True ($text -match '32769') 'the access-denied code must be named'
        Assert-True ($text -match '32775') 'the invalid-state code must be named'
        Assert-True ($text -match 'Write-Warning') 'a non-zero ReturnValue must reach the transcript'
        Assert-True ($text -match '\$r\.ReturnValue -ne 0') 'the warning must be gated on the failure path only'
    }

    It 'warns before it drops the handle, so both repairs stay visible' {
        # The clear is silent on its own. Warning first is what leaves the
        # reason in the cycle log when the re-resolve does not help, which is
        # exactly the guest-has-no-driver case.
        $text = Get-TransportFunctionText -Name 'Send-ScanCode'
        Assert-True ($text -match '(?s)Write-Warning[^\r\n]*\r?\n\s*Clear-HyperVKeyboard') `
            'the warning must precede the cache clear on the rejected-send path'
    }
}


Describe 'Send-TextHyperV honors the batched/per-char text-send shape' {

    BeforeEach {
        & $script:TransportModule {
            $script:scanSends = [System.Collections.ArrayList]::new()
            function script:Get-HyperVKeyboard {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Shadow stub; the caller binds -VMName and there is no WMI keyboard to resolve here.')]
                param($VMName)
                [pscustomobject]@{ Fake = $true }
            }
            function script:Send-ScanCode {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Shadow stub; $Keyboard is the WMI instance the real primitive invokes against, and this one records the codes instead.')]
                param($Keyboard, [byte[]]$Codes)
                [void]$script:scanSends.Add([byte[]]$Codes)
                return $true
            }
        }
    }

    It 'sends one call per character and no reset prefix when batching is off' {
        # An ARM64 Hyper-V guest receives NONE of a batched payload, so the
        # per-char shape is the only one that arrives there -- and the
        # modifier-reset prefix must not lead it, because every character sent
        # after that prefix is swallowed too. Count the calls, not the codes:
        # the character codes are identical either way, and the call boundary
        # is the whole difference.
        & $script:TransportModule { $script:DefaultBatchedTextSend = $false }
        Assert-True ((Send-TextHyperV -VMName 'vm' -Text 'abc' -CharDelayMs 0) -eq $true) 'per-char send must report success'
        $sends = & $script:TransportModule { , $script:scanSends.ToArray() }
        Assert-Equal -Expected 3 -Actual $sends.Count -Because 'one call per character, with no reset prefix ahead of them'
    }

    It 'still leads a batched send with the modifier-reset prefix' {
        # The prefix is what keeps a latched Shift from upshifting a whole
        # batched password, so dropping it everywhere would trade one host's
        # bug for another's.
        & $script:TransportModule { $script:DefaultBatchedTextSend = $true }
        Send-TextHyperV -VMName 'vm' -Text 'abc' -CharDelayMs 0 | Out-Null
        $sends = & $script:TransportModule { , $script:scanSends.ToArray() }
        Assert-Equal -Expected 0xAA -Actual ([int]$sends[0][0]) -Because 'the batched send opens with the LShift break'
    }

    It 'keeps a shifted character and its Shift pair in the same call' {
        # Splitting them would leave Shift held across the pacing sleep and
        # upshift whatever the guest read next.
        & $script:TransportModule { $script:DefaultBatchedTextSend = $false }
        Send-TextHyperV -VMName 'vm' -Text 'A' -CharDelayMs 0 | Out-Null
        $sends = & $script:TransportModule { , $script:scanSends.ToArray() }
        $charCall = $sends[-1]
        Assert-Equal -Expected 0x2A -Actual ([int]$charCall[0]) -Because 'the shift make leads the character call'
        Assert-Equal -Expected 0xAA -Actual ([int]$charCall[-1]) -Because 'the shift break closes the same call'
    }

    It 'still emits the whole payload in one call when batching is on' {
        & $script:TransportModule { $script:DefaultBatchedTextSend = $true }
        Send-TextHyperV -VMName 'vm' -Text 'abc' -CharDelayMs 0 | Out-Null
        $sends = & $script:TransportModule { , $script:scanSends.ToArray() }
        Assert-Equal -Expected 2 -Actual $sends.Count -Because 'reset prefix + one batch'
    }

    It 'defaults to per-char on an ARM64 Windows host and batched elsewhere' {
        # The default is computed at module load from the HOST architecture,
        # not from the guest, because the drop is in the synthetic keyboard.
        $text = Get-Content -Raw $modulePath
        Assert-True ($text -match 'DefaultBatchedTextSend\s*=\s*\r?\n?\s*-not \(\$IsWindows -and') `
            'the default must be negated only for a Windows ARM64 host'
        Assert-True ($text -match '\$comm\.batchedTextSend') 'vmCommunication.batchedTextSend must override the default'
    }
}

Describe 'Text a transport has no key for is refused before anything is typed' {
    # Dropping the character and typing the rest delivers a different string
    # than the step asked for -- a password wrong by one -- and reports success,
    # so the step fails later under a label that names something else.

    It 'types nothing over VNC and records a deterministic fault naming the code point' {
        Reset-KeyRecording
        Clear-HostInputFault
        $ok = Send-TextVNC -VMName 'vm' -Text ('ab' + [char]0xE9) -CharDelayMs 0 3>$null
        Assert-True ($ok -eq $false) 'an unmappable character must fail the send'
        $rec = & $script:TransportModule { , $script:rec.ToArray() }
        Assert-Equal -Expected 0 -Actual $rec.Count -Because 'no key of the text may reach the guest'
        $fault = Get-HostInputFault
        Assert-Equal -Expected 'deterministic' -Actual $fault.kind
        Assert-Equal -Expected 'unmappable-character' -Actual $fault.reason
        Assert-Equal -Expected 'U+00E9 at 2' -Actual $fault.detail -Because 'named by code point and position, never by value'
        Assert-Equal -Expected 0 -Actual $fault.delivered
    }

    It 'warns once for the whole text, not once per character' {
        Reset-KeyRecording
        $warnings = @(Send-TextVNC -VMName 'vm' -Text ([string][char]0xE9 + [char]0x20AC) -CharDelayMs 0 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
        Assert-Equal -Expected 1 -Actual $warnings.Count
        Assert-True ("$($warnings[0])" -match 'U\+00E9 at 0, U\+20AC at 1') "the warning lists both: $($warnings[0])"
    }

    It 'records an unknown key name as deterministic' {
        Clear-HostInputFault
        Assert-True ((Send-KeyVNC -VMName 'vm' -KeyName 'NoSuchKey' 3>$null) -eq $false) 'an unknown key must fail'
        Assert-Equal -Expected 'unknown-key' -Actual (Get-HostInputFault).reason
        Assert-Equal -Expected 'deterministic' -Actual (Get-HostInputFault).kind
    }
}

Describe 'A VNC text send that dies part-way says how much went out' {
    It 'counts the characters whose press and release were both written' {
        # 'abc' writes down(a) up(a) down(b) up(b) down(c) up(c); failing the 5th
        # write leaves a and b in the guest and c released by the finally.
        Reset-KeyRecording -FailAt 5
        Clear-HostInputFault
        Assert-True ((Send-TextVNC -VMName 'vm' -Text 'abc' -CharDelayMs 0 3>$null) -eq $false) 'the send must fail'
        $fault = Get-HostInputFault
        Assert-Equal -Expected 'transient' -Actual $fault.kind -Because 'a refused write may clear on a new connection'
        Assert-Equal -Expected 'write-failed' -Actual $fault.reason
        Assert-Equal -Expected 2 -Actual $fault.delivered
        Assert-Equal -Expected 3 -Actual $fault.total
    }
}

Describe 'Hyper-V and UTM text refuse unmappable characters too' {
    BeforeEach {
        & $script:TransportModule {
            $script:scanSends = [System.Collections.ArrayList]::new()
            $script:osaScripts = [System.Collections.ArrayList]::new()
            function script:Get-HyperVKeyboard {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Shadow stub; the caller binds -VMName and there is no WMI keyboard to resolve here.')]
                param($VMName)
                [pscustomobject]@{ Fake = $true }
            }
            function script:Send-ScanCode {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Shadow stub; $Keyboard is the WMI instance the real primitive invokes against, and this one records the codes instead.')]
                param($Keyboard, [byte[]]$Codes)
                [void]$script:scanSends.Add([byte[]]$Codes)
                return $true
            }
            function script:Invoke-OsaScriptFile {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                    Justification = 'Shadow stub; records the script instead of running osascript.')]
                param($Script, $Language)
                [void]$script:osaScripts.Add([string]$Script)
                return 'ok'
            }
        }
        Clear-HostInputFault
    }

    It 'sends no scan code for text with a character the PS/2 map lacks' {
        Assert-True ((Send-TextHyperV -VMName 'vm' -Text ('a' + [char]0x4F60) -CharDelayMs 0 3>$null) -eq $false) 'the send must fail'
        $sends = & $script:TransportModule { , $script:scanSends.ToArray() }
        Assert-Equal -Expected 0 -Actual $sends.Count -Because 'not even the modifier-reset prefix is sent'
        Assert-Equal -Expected 'unmappable-character' -Actual (Get-HostInputFault).reason
    }

    It 'runs no osascript for text the macOS key map lacks, without the shell escape' {
        Assert-True ((Send-TextUTM -VMName 'vm' -Text ('a' + [char]0x20AC) -CharDelayMs 0 3>$null) -eq $false) 'the send must fail'
        $scripts = & $script:TransportModule { , $script:osaScripts.ToArray() }
        Assert-Equal -Expected 0 -Actual $scripts.Count
        Assert-Equal -Expected 'deterministic' -Actual (Get-HostInputFault).kind
    }

    It 'types the character through the shell escape, which spells every byte with unshifted keys' {
        Assert-True ((Send-TextUTM -VMName 'vm' -Text ('echo ' + [char]0x20AC) -CharDelayMs 0 -ShellEscape 3>$null) -eq $true) 'the escaped send must succeed'
        $scripts = & $script:TransportModule { , $script:osaScripts.ToArray() }
        Assert-Equal -Expected 1 -Actual $scripts.Count
    }

    It 'records an osascript that did not finish as transient' {
        & $script:TransportModule { function script:Invoke-OsaScriptFile { param($Script, $Language) $null = $Script, $Language; 'window_not_found' } }
        Assert-True ((Send-TextUTM -VMName 'vm' -Text 'abc' -CharDelayMs 0) -eq $false) 'the send must fail'
        Assert-Equal -Expected 'transient' -Actual (Get-HostInputFault).kind
        Assert-Equal -Expected 'send-failed' -Actual (Get-HostInputFault).reason
    }
}
