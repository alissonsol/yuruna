<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42f1809a-b8c8-4dd4-ba80-fcc20a881d12
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test macos utm serial console qemu monitor pester
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
    The UTM Ubuntu guests' serial console and QEMU monitor: the template's
    devices, the ports that follow the VNC display, the runner-side serial
    reader, and the monitor capture the wedge snapshot takes.
.DESCRIPTION
    Behavior, not source text: the reader and the monitor capture run against
    loopback listeners that play the guest's UART and QEMU's human monitor,
    and the driver's native calls go to the stand-in macOS host from
    Test.MacUtmFakeHost. The runner's own kernel reading of a saved log runs
    in a child process. The templates are parsed as property lists and held
    to the keys and values UTM's configuration decoder reads. The cases that
    need the stand-in tools run on any POSIX host; Windows skips them, because
    the stand-ins are /bin/sh scripts, and says so.
#>

BeforeAll {
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:DriverPath = Join-Path $script:RepoRoot 'host/macos.utm/modules/Yuruna.Host.psm1'
    $script:BuilderPath = Join-Path $script:RepoRoot 'host/macos.utm/modules/New-UbuntuServerVM.ps1'
    Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.Globalization.psm1') -Global -DisableNameChecking
    Get-Module -Name 'Yuruna.Host', 'default' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -Global -DisableNameChecking
    Import-Module $script:DriverPath -Force -DisableNameChecking -Global -WarningAction SilentlyContinue
    Import-Module (Join-Path $PSScriptRoot 'Test.MacUtmFakeHost.psm1') -Force -Global -DisableNameChecking
    $script:Driver = Get-MacUtmFakeDriver
    $script:CanShim = -not $IsWindows
    $script:Skip = 'the stand-in tools are POSIX shell scripts'
    if ($script:CanShim) {
        $script:FakeRoot = New-YurunaTestTempDir -Prefix 'yrn-utmserial'
        $script:Fake = New-MacUtmFakeHost -Root $script:FakeRoot
    }

    # UTM's serial configuration, as Configuration/UTMQemuConfigurationSerial.swift
    # (CodingKeys) and Configuration/QEMUConstant.swift (QEMUSerialMode,
    # QEMUSerialTarget raw values) in github.com/utmapp/UTM decode it.
    $script:UtmSerialKey = @('Mode', 'Target', 'Terminal', 'Hardware', 'TcpHostAddress', 'TcpPort', 'WaitForConnection', 'RemoteConnectionAllowed')
    $script:UtmSerialMode = @('Terminal', 'TcpClient', 'TcpServer', 'Ptty')
    $script:UtmSerialTarget = @('Auto', 'Manual', 'GDB', 'Monitor')

    function Invoke-InDriver {
        param([scriptblock]$Body, [object[]]$Argument = @())
        return (& $script:Driver $Body @Argument)
    }
    function Get-Call { param([string]$Tool) return @(Get-MacUtmFakeCall -FakeHost $script:Fake -Tool $Tool) }

    # A plist element as PowerShell values: dict -> ordered dictionary, array
    # -> object[], string, integer -> [long], true/false -> [bool]. A dict entry
    # that is not a <key> followed by a value, or an integer that does not
    # parse, throws.
    function ConvertFrom-PlistNode {
        param([System.Xml.XmlNode]$Node)
        $children = @($Node.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })
        switch ($Node.LocalName) {
            'dict' {
                $map = [ordered]@{}
                for ($i = 0; $i -lt $children.Count; $i += 2) {
                    if ($children[$i].LocalName -ne 'key' -or $i + 1 -ge $children.Count) { throw "dict entry $i is not a key and a value" }
                    $map[$children[$i].InnerText] = ConvertFrom-PlistNode -Node $children[$i + 1]
                }
                return $map
            }
            'array' { return , @($children | ForEach-Object { ConvertFrom-PlistNode -Node $_ }) }
            'string' { return [string]$Node.InnerText }
            'integer' { return [long]::Parse($Node.InnerText, [System.Globalization.CultureInfo]::InvariantCulture) }
            'true' { return $true }
            'false' { return $false }
            default { throw "unexpected plist element <$($Node.LocalName)>" }
        }
    }

    # The keys of the replacement table the shared Ubuntu builder hands to the
    # template, read from its source.
    function Get-BuilderPlistKey {
        $ast = Get-YurunaTestFileAst -Path $script:BuilderPath
        $assignment = $ast.Find({ param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$plistValues' }, $true)
        return @($assignment.Right.Expression.KeyValuePairs | ForEach-Object { [string]$_.Item1.Value })
    }

    # A bundle the fake plutil answers for, with TCP serial devices on the
    # given ports (0 leaves that device out) and, with -Builtin, a built-in
    # terminal device first.
    function Set-ConsoleBundle {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Test fixture: writes only into the fake host home.')]
        [CmdletBinding()]
        param([string]$Name, [int]$SerialPort = 0, [int]$MonitorPort = 0, [int]$Display = 47, [switch]$Builtin, [switch]$NoSerial)
        $bundle = Join-Path $script:Fake.Home "yuruna/guest.nosync/$Name.utm"
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $bundle 'Data')
        $plist = Join-Path $bundle 'config.plist'
        [System.IO.File]::WriteAllText($plist, "<plist/>`n")
        $serial = [System.Collections.Generic.List[object]]::new()
        if ($Builtin) { $serial.Add([ordered]@{ Mode = 'Terminal'; Target = 'Auto' }) }
        if ($SerialPort -gt 0) { $serial.Add([ordered]@{ Mode = 'TcpServer'; Target = 'Auto'; TcpPort = $SerialPort; WaitForConnection = $false; RemoteConnectionAllowed = $false }) }
        if ($MonitorPort -gt 0) { $serial.Add([ordered]@{ Mode = 'TcpServer'; Target = 'Monitor'; TcpPort = $MonitorPort; WaitForConnection = $false; RemoteConnectionAllowed = $false }) }
        $json = [ordered]@{
            Information = [ordered]@{ Name = $Name; UUID = '6B9A5B8F-0000-4000-8000-000000000001' }
            Network     = @([ordered]@{ Mode = 'Shared'; MacAddress = '52:54:00:AA:BB:CC' })
            QEMU        = [ordered]@{ AdditionalArguments = @('-vnc', "127.0.0.1:$Display,share=force-shared") }
        }
        if (-not $NoSerial) { $json['Serial'] = @($serial) }
        [System.IO.File]::WriteAllText("$plist.json", ($json | ConvertTo-Json -Depth 6))
    }

    function Wait-Until {
        param([scriptblock]$Condition, [int]$TimeoutSeconds = 30, [string]$Because = '')
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            if (& $Condition) { return }
            Start-Sleep -Milliseconds 50
        }
        throw "Timed out after $TimeoutSeconds s waiting until $Because"
    }

    # The guest's side of the serial console: accept the reader's connection.
    function Wait-GuestConnection {
        param([System.Net.Sockets.TcpListener]$Listener, [int]$TimeoutSeconds = 30)
        Wait-Until { $Listener.Pending() } -TimeoutSeconds $TimeoutSeconds -Because 'the reader connects'
        return $Listener.AcceptTcpClient()
    }
    function Send-GuestByte {
        param([System.Net.Sockets.TcpClient]$Guest, [string]$Text)
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($Text)
        $Guest.GetStream().Write($bytes, 0, $bytes.Length)
        $Guest.GetStream().Flush()
    }
    function Get-CaptureFile {
        param([string]$VMName)
        $directory = Join-Path $script:Cycle $VMName
        return [pscustomobject]@{
            Directory = $directory
            Log       = Join-Path $directory 'serial-console.log'
            Previous  = Join-Path $directory 'serial-console.1.log'
            State     = Join-Path $directory 'serial-console.reader.json'
        }
    }
    function Read-SharedText {
        param([string]$Path)
        if (-not [System.IO.File]::Exists($Path)) { return '' }
        $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            $reader = [System.IO.StreamReader]::new($stream)
            return $reader.ReadToEnd()
        } finally { $stream.Dispose() }
    }
    function Read-ReaderState {
        param([string]$Path)
        try { return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json) } catch { return $null }
    }
    function Join-ByteArray {
        param([object[]]$Part)
        $joined = [System.IO.MemoryStream]::new()
        foreach ($bytes in $Part) { $joined.Write([byte[]]$bytes, 0, $bytes.Length) }
        return , $joined.ToArray()
    }

    # The runner's failure step reads a saved serial log for the guest kernel's
    # reports (Save-SerialConsoleKernelFault in Test.RunnerInnerLoop.psm1). It
    # runs in a child process, bounded, so the runner's modules stay out of
    # this suite's session; the reading is $null when it wrote nothing.
    $script:KernelReaderDir = New-YurunaTestTempDir -Prefix 'yrn-utmkernel'
    $script:KernelReader = Join-Path $script:KernelReaderDir 'Read-SavedSerialKernelFault.ps1'
    [System.IO.File]::WriteAllText($script:KernelReader, @'
param([Parameter(Mandatory)][string]$Repo, [Parameter(Mandatory)][string]$Folder)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Repo 'test/modules/Test.Diagnostic.psm1') -DisableNameChecking
Import-Module (Join-Path $Repo 'test/modules/Test.StateFile.psm1') -DisableNameChecking
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repo 'test/modules/Test.RunnerInnerLoop.psm1'), [ref]$null, [ref]$null)
$definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-SerialConsoleKernelFault' }, $true)
. ([scriptblock]::Create($definition.Extent.Text))
Save-SerialConsoleKernelFault -OutputDirectory $Folder
'@)
    function Invoke-RunnerKernelReading {
        param([string]$Folder)
        $pwsh = Join-Path $PSHOME ($IsWindows ? 'pwsh.exe' : 'pwsh')
        $run = Invoke-BoundedNativeCommand -FilePath $pwsh -TimeoutSeconds 120 -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-File', $script:KernelReader, '-Repo', $script:RepoRoot, '-Folder', $Folder)
        if ($run.TimedOut -or $run.ExitCode -ne 0) { throw "the runner's kernel reading did not finish (exit $($run.ExitCode)): $($run.StdErr)" }
        $path = Join-Path $Folder 'serial-console.kernel.json'
        if (-not [System.IO.File]::Exists($path)) { return $null }
        return ([System.IO.File]::ReadAllText($path) | ConvertFrom-Json)
    }

    # QEMU's human monitor on a loopback port, for one connection: the banner
    # and a '(qemu) ' prompt, an echo of every byte the way its line editor
    # redraws the line, and canned answers. 'silent' accepts and never speaks;
    # 'stall-registers' never answers info registers. Received commands land
    # in Commands.
    function Start-FakeQemuMonitor {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Starts a loopback responder for one test case, which the caller stops.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '',
            Justification = 'Every value reaches the job through -ArgumentList into its param() block.')]
        [CmdletBinding()]
        param([ValidateSet('answer', 'silent', 'stall-registers')][string]$Behavior = 'answer')
        $listener = New-YurunaTestTcpListener
        $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
        $release = [System.Threading.ManualResetEventSlim]::new($false)
        $received = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
        $job = Start-ThreadJob -ArgumentList $listener, $Behavior, $release, $received -ScriptBlock {
            param($Listener, $Behavior, $Release, $Received)
            $replies = @{
                'info status'       = 'VM status: running'
                'info cpus'         = "* CPU #0: thread_id=4101`r`n  CPU #1: thread_id=4102"
                'info registers -a' = "`r`nCPU#0`r`n PC=ffff800080123456 X00=0000000000000001 X01=0000000000000000`r`nCPU#1`r`n PC=ffff800080654321 X00=0000000000000002"
            }
            try {
                $waited = [System.Diagnostics.Stopwatch]::StartNew()
                while (-not $Listener.Pending()) {
                    if ($waited.Elapsed.TotalSeconds -gt 20 -or $Release.IsSet) { return }
                    Start-Sleep -Milliseconds 20
                }
                $client = $Listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $send = {
                        param([string]$Text)
                        $bytes = [System.Text.Encoding]::ASCII.GetBytes($Text)
                        $stream.Write($bytes, 0, $bytes.Length)
                        $stream.Flush()
                    }
                    if ($Behavior -eq 'silent') { [void]$Release.Wait(20000); return }
                    & $send "QEMU 9.2.0 monitor - type 'help' for more information`r`n(qemu) "
                    $line = [System.Text.StringBuilder]::new()
                    $one = [byte[]]::new(1)
                    while ($stream.Read($one, 0, 1) -gt 0) {
                        $ch = [char]$one[0]
                        if ($ch -eq "`n" -or $ch -eq "`r") {
                            $command = $line.ToString()
                            [void]$line.Clear()
                            $Received.Enqueue($command)
                            & $send "`r`n"
                            if ($Behavior -eq 'stall-registers' -and $command -eq 'info registers -a') { [void]$Release.Wait(20000); return }
                            & $send "$($replies[$command])`r`n(qemu) "
                            continue
                        }
                        & $send (("`e[D" * $line.Length) + $line.ToString() + $ch + "`e[K")
                        [void]$line.Append($ch)
                    }
                } finally { $client.Dispose() }
            } finally { $Listener.Stop() }
        }
        return [pscustomobject]@{ Listener = $listener; Port = $port; Job = $job; Release = $release; Commands = $received }
    }
    function Stop-FakeQemuMonitor {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Stops the loopback responder this suite started for one test case.')]
        [CmdletBinding()]
        param($Monitor)
        if ($null -eq $Monitor) { return }
        $Monitor.Release.Set()
        $Monitor.Listener.Stop()
        $null = $Monitor.Job | Wait-Job -Timeout 10
        $Monitor.Job | Remove-Job -Force -ErrorAction SilentlyContinue
        $Monitor.Release.Dispose()
    }

    function Enter-CycleFolder {
        $script:Cycle = Join-Path $script:Fake.Root ('cycle-' + [guid]::NewGuid().ToString('N') + '.incomplete')
        $null = New-Item -ItemType Directory -Force -Path $script:Cycle
        $env:YURUNA_CYCLE_CONTEXT = (@{ rootCycleFolder = $script:Cycle } | ConvertTo-Json -Compress)
    }
    function Stop-AllReader {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
            Justification = 'Stops the reader jobs the cases of this suite started.')]
        [CmdletBinding()]
        param()
        Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'yuruna-serial-*' } | ForEach-Object {
            Stop-Job -Job $_ -ErrorAction SilentlyContinue
            Remove-Job -Job $_ -Force -ErrorAction SilentlyContinue
        }
    }
}

AfterAll {
    if ($script:Fake) { Remove-MacUtmFakeHost -FakeHost $script:Fake }
    if ($script:KernelReaderDir) { Remove-YurunaTestTempDir $script:KernelReaderDir }
}

Describe 'UTM Ubuntu templates carry a serial console and a QEMU monitor' {
    It 'declares both on loopback, never waiting, in the keys and values UTM decodes: ubuntu.server.<Release>' -ForEach @(
        @{ Release = '24' }, @{ Release = '26' }
    ) {
        $template = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot "host/macos.utm/guest.ubuntu.server.$Release/config.plist.template"))
        $display = Invoke-InDriver { Get-VncDisplayForVm -VMName 'test-guest.ubuntu.server.26-01' }
        $console = Invoke-InDriver { param($d) Get-UtmConsolePortForDisplay -Display $d } @($display)
        # Every key the builder supplies, with values of the kind it supplies.
        $rendered = $template
        foreach ($key in (Get-BuilderPlistKey)) {
            $value = switch ($key) {
                '__VNC_DISPLAY__' { "$display" }
                '__SERIAL_PORT__' { "$($console.Serial)" }
                '__MONITOR_PORT__' { "$($console.Monitor)" }
                '__CPU_COUNT__' { '4' }
                '__MEMORY_SIZE__' { '12288' }
                default { 'value' }
            }
            $rendered = $rendered.Replace($key, [System.Security.SecurityElement]::Escape($value))
        }
        Assert-NoFinding @([regex]::Matches($rendered, '__[A-Z0-9_]+__') | ForEach-Object { $_.Value }) 'the builder supplies every placeholder of the template'
        $document = [xml]$rendered
        $plist = ConvertFrom-PlistNode -Node $document.plist.dict
        $devices = @($plist['Serial'])
        Assert-Equal 2 $devices.Count -Because 'one serial console and one monitor'
        foreach ($device in $devices) {
            Assert-NoFinding @($device.Keys | Where-Object { $_ -cnotin $script:UtmSerialKey }) 'UTM decodes only its own keys'
            Assert-True ($device['Mode'] -cin $script:UtmSerialMode) "Mode '$($device['Mode'])' is one UTM reads"
            Assert-True ($device['Target'] -cin $script:UtmSerialTarget) "Target '$($device['Target'])' is one UTM reads"
            Assert-StringEqual 'TcpServer' $device['Mode']
            Assert-True ($device['TcpPort'] -is [long]) 'TcpPort is an integer, as UTM decodes it'
            Assert-Equal $false $device['WaitForConnection'] -Because 'QEMU must never hold the VM for a client'
            Assert-Equal $false $device['RemoteConnectionAllowed'] -Because 'only the loopback address may listen'
        }
        $serial = @($devices | Where-Object { $_['Target'] -ceq 'Auto' })
        $monitor = @($devices | Where-Object { $_['Target'] -ceq 'Monitor' })
        Assert-Equal 1 $serial.Count
        Assert-Equal 1 $monitor.Count
        Assert-Equal ([long]$console.Serial) $serial[0]['TcpPort'] -Because 'the serial console follows the VNC display'
        Assert-Equal ([long]$console.Monitor) $monitor[0]['TcpPort'] -Because 'the monitor follows the VNC display'
    }

    It 'leaves every other UTM template without serial devices' {
        $others = @(Get-ChildItem -Path (Join-Path $script:RepoRoot 'host/macos.utm') -Filter 'config.plist.template' -Recurse -File |
            Where-Object { $_.Directory.Name -notin @('guest.ubuntu.server.24', 'guest.ubuntu.server.26') })
        Assert-True ($others.Count -ge 5) 'the other templates are found'
        foreach ($file in $others) {
            $document = [xml][System.IO.File]::ReadAllText($file.FullName)
            $value = $document.SelectSingleNode("/plist/dict/key[.='Serial']/following-sibling::*[1]")
            Assert-StringEqual 'array' $value.LocalName "$($file.Directory.Name) keeps a Serial array"
            Assert-Equal 0 @($value.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element }).Count -Because "$($file.Directory.Name) gets no device"
        }
    }
}

Describe 'Console ports follow the VNC display' {
    BeforeEach {
        if ($script:CanShim) { Reset-MacUtmFakeHost -FakeHost $script:Fake; Enter-MacUtmFakeHost -FakeHost $script:Fake }
    }
    AfterEach {
        if ($script:CanShim) { Exit-MacUtmFakeHost -FakeHost $script:Fake }
    }

    It 'puts the serial console 1000 and the monitor 2000 above the VNC port, meeting neither VNC nor each other' {
        $seen = [System.Collections.Generic.HashSet[int]]::new()
        for ($display = 10; $display -le 89; $display++) {
            $console = Invoke-InDriver { param($d) Get-UtmConsolePortForDisplay -Display $d } @($display)
            Assert-Equal (5900 + $display + 1000) $console.Serial
            Assert-Equal (5900 + $display + 2000) $console.Monitor
            foreach ($port in @((5900 + $display), $console.Serial, $console.Monitor)) {
                Assert-True ($seen.Add($port)) "port $port belongs to one display and one role"
            }
        }
    }

    It 'reads the ports from the bundle, ignoring other devices, and -1 for one the bundle lacks' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-ConsoleBundle -Name 'both-vm' -SerialPort 6947 -MonitorPort 7947 -Builtin
        Set-ConsoleBundle -Name 'serial-only-vm' -SerialPort 6950
        Set-ConsoleBundle -Name 'plain-vm' -NoSerial
        $both = Invoke-InDriver { Get-UtmConsolePortFromBundle -VMName 'both-vm' }
        Assert-Equal 6947 $both.Serial -Because 'the built-in terminal device is not a port'
        Assert-Equal 7947 $both.Monitor
        $serialOnly = Invoke-InDriver { Get-UtmConsolePortFromBundle -VMName 'serial-only-vm' }
        Assert-Equal 6950 $serialOnly.Serial
        Assert-Equal (-1) $serialOnly.Monitor
        $plain = Invoke-InDriver { Get-UtmConsolePortFromBundle -VMName 'plain-vm' }
        Assert-Equal (-1) $plain.Serial -Because 'a VM built without the devices has no console to read'
        Assert-Equal (-1) $plain.Monitor
        $absent = Invoke-InDriver { Get-UtmConsolePortFromBundle -VMName 'no-such-vm' }
        Assert-Equal (-1) $absent.Serial -Because 'nothing falls back to a port derived from the name'
    }

    It 'moves the console ports with a rewritten display, leaving other devices alone' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        # The fake PlistBuddy records edits without applying them, so the bundle
        # already carries the target display and only the console ports differ.
        Set-ConsoleBundle -Name 'moved-vm' -Display 25 -SerialPort 6947 -MonitorPort 7947 -Builtin
        $ok = Invoke-InDriver { Set-VncDisplayInBundle -VMName 'moved-vm' -Display 25 -Confirm:$false }
        Assert-True $ok 'the display and both console ports were written'
        $edits = @(Get-Call 'PlistBuddy')
        Assert-Equal 1 @($edits | Where-Object { $_ -like '*Set :Serial:1:TcpPort 6925 *' }).Count -Because 'the serial console moves to the new display'
        Assert-Equal 1 @($edits | Where-Object { $_ -like '*Set :Serial:2:TcpPort 7925 *' }).Count -Because 'the monitor moves to the new display'
        Assert-Equal 0 @($edits | Where-Object { $_ -like '*Set :Serial:0:*' }).Count -Because 'the built-in terminal has no port'
    }

    It 'reports a console port it could not write' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-ConsoleBundle -Name 'stuck-vm' -Display 25 -SerialPort 6947 -MonitorPort 7947
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'plistbuddy.fail' -Value 'Serial:1:TcpPort'
        $ok = Invoke-InDriver { Set-VncDisplayInBundle -VMName 'stuck-vm' -Display 25 -Confirm:$false }
        Assert-False $ok 'a monitor left on the old display could meet the next VM there'
    }

    It 'hands out a display only when its console ports bind too' {
        $display = -1
        for ($candidate = 40; $candidate -le 89 -and $display -lt 0; $candidate++) {
            $console = Invoke-InDriver { param($d) Get-UtmConsolePortForDisplay -Display $d } @($candidate)
            $free = Invoke-InDriver { param($d, $c) (Test-VncPortFree -Port (5900 + $d)) -and (Test-VncPortFree -Port $c.Serial) -and (Test-VncPortFree -Port $c.Monitor) } @($candidate, $console)
            if ($free) { $display = $candidate }
        }
        if ($display -lt 0) { Set-ItResult -Skipped -Because 'no display in 40..89 has all three ports free on this host'; return }
        $console = Invoke-InDriver { param($d) Get-UtmConsolePortForDisplay -Display $d } @($display)
        foreach ($held in @($console.Serial, $console.Monitor)) {
            $listener = New-YurunaTestTcpListener -Port $held
            try {
                $chosen = Invoke-InDriver { param($d) Find-FreeVncDisplay -Preferred $d } @($display)
                Assert-NotEqual $display $chosen "port $held is taken, so QEMU could not start on display $display"
                Assert-True ($chosen -ge 10 -and $chosen -le 89) "chosen display $chosen is inside 10..89"
            } finally { $listener.Stop() }
        }
        Assert-Equal $display (Invoke-InDriver { param($d) Find-FreeVncDisplay -Preferred $d } @($display)) -Because 'a display whose three ports bind is honored'
    }
}

Describe 'A start or a rename repairs console ports left on another display' {
    # A rewrite that failed after the -vnc argument leaves the bundle on the
    # display it will be handed again, with console ports another VM can be
    # given next. Display 47 is the free display handed out here.
    BeforeAll {
        # Start-UtmVM past the bundle rewrite: no dialog watchdog, no launch,
        # and a start that succeeds.
        function Set-UtmLaunchStub {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
                Justification = 'Test fixture: replaces driver functions for one case; AfterEach restores them.')]
            [CmdletBinding()]
            param()
            Invoke-InDriver {
                Set-Item -Path 'function:script:Start-UtmDialogWatchdog' -Value { }
                Set-Item -Path 'function:script:Start-UtmDetachedLaunch' -Value { [CmdletBinding(SupportsShouldProcess)] param([string]$Tool, [string[]]$ArgumentList) $null = $Tool, $ArgumentList; $true }
                Set-Item -Path 'function:script:Invoke-UtmVMStartWithRetry' -Value { [CmdletBinding(SupportsShouldProcess)] param([string]$VMName) $null = $VMName; @{ success = $true } }
            }
        }
    }
    BeforeEach {
        if ($script:CanShim) { Reset-MacUtmFakeHost -FakeHost $script:Fake; Enter-MacUtmFakeHost -FakeHost $script:Fake }
        $script:SavedLaunch = Invoke-InDriver {
            return @{
                Find = ${function:Find-FreeVncDisplay}; Watchdog = ${function:Start-UtmDialogWatchdog}
                Launch = ${function:Start-UtmDetachedLaunch}; Start = ${function:Invoke-UtmVMStartWithRetry}
            }
        }
        Invoke-InDriver {
            Set-Item -Path 'function:script:Find-FreeVncDisplay' -Value { param([int]$Preferred, [int[]]$ExcludeDisplays) $null = $Preferred, $ExcludeDisplays; 47 }
        }
    }
    AfterEach {
        Invoke-InDriver {
            param($s)
            Set-Item -Path 'function:script:Find-FreeVncDisplay' -Value $s.Find
            Set-Item -Path 'function:script:Start-UtmDialogWatchdog' -Value $s.Watchdog
            Set-Item -Path 'function:script:Start-UtmDetachedLaunch' -Value $s.Launch
            Set-Item -Path 'function:script:Invoke-UtmVMStartWithRetry' -Value $s.Start
        } @($script:SavedLaunch)
        if ($script:CanShim) { Exit-MacUtmFakeHost -FakeHost $script:Fake }
    }

    It 'Start-UtmVM rewrites the console ports of a bundle already on the display it is handed' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-UtmLaunchStub
        Set-ConsoleBundle -Name 'ported-vm' -Display 47 -SerialPort 6925 -MonitorPort 7925
        $r = Invoke-InDriver { Start-UtmVM -VMName 'ported-vm' -Confirm:$false }
        Assert-True $r.success $r.errorMessage
        $edits = @(Get-Call 'PlistBuddy')
        Assert-Equal 1 @($edits | Where-Object { $_ -like '*Set :Serial:0:TcpPort 6947 *' }).Count -Because "the serial console follows display 47 ($($edits -join '; '))"
        Assert-Equal 1 @($edits | Where-Object { $_ -like '*Set :Serial:1:TcpPort 7947 *' }).Count -Because 'the monitor follows display 47'
    }

    It 'Start-UtmVM leaves a bundle whose display and console ports agree as it is' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-UtmLaunchStub
        Set-ConsoleBundle -Name 'current-vm' -Display 47 -SerialPort 6947 -MonitorPort 7947
        $r = Invoke-InDriver { Start-UtmVM -VMName 'current-vm' -Confirm:$false }
        Assert-True $r.success $r.errorMessage
        Assert-Equal 0 @(Get-Call 'PlistBuddy').Count -Because 'nothing in the bundle needs a rewrite'
    }

    It 'Rename-VM rewrites the console ports of a bundle already on the display it is handed' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeVM -FakeHost $script:Fake -Name 'test-src' -Status 'stopped'
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'rename.from' -Value 'test-src'
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'watchdog.mode' -Value 'live'
        Set-ConsoleBundle -Name 'test-src' -Display 47 -SerialPort 6925 -MonitorPort 7925
        Assert-True (Rename-VM -VMName 'test-src' -NewName 'test-dst' -Confirm:$false -WarningAction SilentlyContinue) 'the rename surfaced'
        $edits = @(Get-Call 'PlistBuddy' | Where-Object { $_ -like '*/test-dst.utm/config.plist' })
        Assert-Equal 1 @($edits | Where-Object { $_ -like '*Set :Serial:0:TcpPort 6947 *' }).Count -Because "the serial console follows display 47 ($($edits -join '; '))"
        Assert-Equal 1 @($edits | Where-Object { $_ -like '*Set :Serial:1:TcpPort 7947 *' }).Count -Because 'the monitor follows display 47'
    }
}

Describe 'The serial reader' {
    BeforeEach {
        if ($script:CanShim) {
            Reset-MacUtmFakeHost -FakeHost $script:Fake
            Enter-MacUtmFakeHost -FakeHost $script:Fake
            $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_CYCLE_CONTEXT', 'YURUNA_LOG_DIR'
            $script:SavedGlobal = Save-YurunaTestGlobal -Name '__YurunaCycleFolder'
            $env:YURUNA_LOG_DIR = ''
            Set-YurunaTestGlobal -Value @{ __YurunaCycleFolder = $null }
            Enter-CycleFolder
            $script:SavedSegment = Invoke-InDriver { $script:UtmSerialCaptureSegmentBytes }
        }
    }
    AfterEach {
        if ($script:CanShim) {
            Stop-AllReader
            Invoke-InDriver { param($s) $script:UtmSerialCaptureSegmentBytes = $s } @($script:SavedSegment)
            Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
            Restore-YurunaTestGlobal -Saved $script:SavedGlobal
            Exit-MacUtmFakeHost -FakeHost $script:Fake
        }
    }

    It 'appends what the guest writes, across a restart, to the log in the VM evidence folder' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $port = Get-YurunaTestFreePort
        Set-ConsoleBundle -Name 'reader-vm' -SerialPort $port
        $files = Get-CaptureFile -VMName 'reader-vm'
        # Armed before anything listens, as Start-VM arms it before the VM powers on.
        Assert-True (Invoke-InDriver { Start-VMSerialCapture -VMName 'reader-vm' }) 'armed'
        $listener = New-YurunaTestTcpListener -Port $port
        $guest = $null
        try {
            $guest = Wait-GuestConnection -Listener $listener
            Send-GuestByte -Guest $guest -Text "UEFI firmware for ARM`r`n"
            Wait-Until { (Read-SharedText $files.Log) -match 'UEFI firmware' } -Because 'the first boot reaches the log'
            # The cold restart: QEMU goes away and listens again on the same port.
            $guest.Dispose()
            $listener.Stop()
            Wait-Until { $state = Read-ReaderState $files.State; $state -and $state.lastDisconnectUtc } -Because 'the reader sees the VM go'
            $listener = New-YurunaTestTcpListener -Port $port
            $guest = Wait-GuestConnection -Listener $listener
            Send-GuestByte -Guest $guest -Text "Linux version 7.0.0`r`n"
            Wait-Until { (Read-SharedText $files.Log) -match 'Linux version' } -Because 'the second boot reaches the same log'
            $text = Read-SharedText $files.Log
            Assert-True ($text.IndexOf('UEFI firmware') -lt $text.IndexOf('Linux version')) 'appended in order, the first boot kept'
            $state = Read-ReaderState $files.State
            Assert-True ([int]$state.connectedCount -ge 2) "reconnected ($($state.connectedCount) connects)"
            Assert-Equal $port ([int]$state.port)
            Assert-Equal 1 @(Get-Job | Where-Object { $_.Name -eq 'yuruna-serial-reader-vm' }).Count -Because 'one reader, named after the VM'
        } finally {
            if ($guest) { $guest.Dispose() }
            $listener.Stop()
        }
    }

    It 'keeps the reader that serves the port and replaces one serving another, appending to the same log' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $first = Get-YurunaTestFreePort
        Set-ConsoleBundle -Name 'rearm-vm' -SerialPort $first
        $files = Get-CaptureFile -VMName 'rearm-vm'
        Assert-True (Invoke-InDriver { Start-VMSerialCapture -VMName 'rearm-vm' }) 'armed'
        $job = @(Get-Job | Where-Object { $_.Name -eq 'yuruna-serial-rearm-vm' })[0]
        Assert-True (Invoke-InDriver { Start-VMSerialCapture -VMName 'rearm-vm' }) 'armed again at once'
        $kept = @(Get-Job | Where-Object { $_.Name -eq 'yuruna-serial-rearm-vm' })
        Assert-Equal 1 $kept.Count
        Assert-Equal $job.Id $kept[0].Id -Because 'a reader for the same port and log is kept, so no output is dropped'
        $listener = New-YurunaTestTcpListener -Port $first
        $guest = $null
        try {
            $guest = Wait-GuestConnection -Listener $listener
            Send-GuestByte -Guest $guest -Text "before the move`n"
            Wait-Until { (Read-SharedText $files.Log) -match 'before the move' } -Because 'the first port reaches the log'
        } finally {
            if ($guest) { $guest.Dispose() }
            $listener.Stop()
        }
        $second = Get-YurunaTestFreePort
        Set-ConsoleBundle -Name 'rearm-vm' -SerialPort $second
        Assert-True (Invoke-InDriver { Start-VMSerialCapture -VMName 'rearm-vm' }) 'armed for the moved port'
        $replaced = @(Get-Job | Where-Object { $_.Name -eq 'yuruna-serial-rearm-vm' })
        Assert-Equal 1 $replaced.Count
        Assert-NotEqual $job.Id $replaced[0].Id 'the reader of the old port is gone'
        $listener = New-YurunaTestTcpListener -Port $second
        $guest = $null
        try {
            $guest = Wait-GuestConnection -Listener $listener
            Send-GuestByte -Guest $guest -Text "after the move`n"
            Wait-Until { (Read-SharedText $files.Log) -match 'after the move' } -Because 'the moved port reaches the log'
            Assert-Match '(?s)before the move.*after the move' (Read-SharedText $files.Log) 'the log is appended, not replaced'
            Assert-Equal $second ([int](Read-ReaderState $files.State).port)
        } finally {
            if ($guest) { $guest.Dispose() }
            $listener.Stop()
        }
    }

    It 'keeps reading past full segments, so the guest never waits, and keeps the newest two' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Invoke-InDriver { $script:UtmSerialCaptureSegmentBytes = 64KB }
        $port = Get-YurunaTestFreePort
        Set-ConsoleBundle -Name 'flood-vm' -SerialPort $port
        $files = Get-CaptureFile -VMName 'flood-vm'
        # More than the loopback socket buffers hold, so a reader that stopped
        # reading would leave this send waiting until its timeout.
        $blockBytes = 4096
        $blockCount = 4096
        $stream = [byte[]]::new($blockBytes * $blockCount)
        $template = [byte[]]::new($blockBytes)
        for ($i = 0; $i -lt $blockBytes; $i++) { $template[$i] = [byte][char]'.' }
        $template[$blockBytes - 1] = 10
        for ($block = 0; $block -lt $blockCount; $block++) {
            [Array]::Copy($template, 0, $stream, $block * $blockBytes, $blockBytes)
            $header = [System.Text.Encoding]::ASCII.GetBytes(('B{0:D7}' -f $block))
            [Array]::Copy($header, 0, $stream, $block * $blockBytes, $header.Length)
        }
        Assert-True (Invoke-InDriver { Start-VMSerialCapture -VMName 'flood-vm' }) 'armed'
        $listener = New-YurunaTestTcpListener -Port $port
        $guest = $null
        try {
            $guest = Wait-GuestConnection -Listener $listener
            $guest.SendTimeout = 20000
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            for ($offset = 0; $offset -lt $stream.Length; $offset += 65536) {
                $guest.GetStream().Write($stream, $offset, [Math]::Min(65536, $stream.Length - $offset))
            }
            Assert-True ($clock.Elapsed.TotalSeconds -lt 60) "16 MiB went through in $([int]$clock.Elapsed.TotalSeconds) s"
        } finally {
            if ($guest) { $guest.Dispose() }
            $listener.Stop()
        }
        # The reader meets the end of the stream only after reading all of it.
        Wait-Until { $state = Read-ReaderState $files.State; $state -and $state.lastDisconnectUtc } -TimeoutSeconds 60 -Because 'the reader drains the stream'
        $current = [System.IO.File]::ReadAllBytes($files.Log)
        $previous = [System.IO.File]::ReadAllBytes($files.Previous)
        Assert-True ($current.Length -le 64KB) "the live segment is bounded ($($current.Length) bytes)"
        Assert-True ($previous.Length -le 64KB -and $previous.Length -gt 0) "the rolled segment is bounded ($($previous.Length) bytes)"
        $kept = [byte[]]::new($previous.Length + $current.Length)
        [Array]::Copy($previous, 0, $kept, 0, $previous.Length)
        [Array]::Copy($current, 0, $kept, $previous.Length, $current.Length)
        $suffix = [byte[]]::new($kept.Length)
        [Array]::Copy($stream, $stream.Length - $kept.Length, $suffix, 0, $kept.Length)
        Assert-True ([System.Convert]::ToBase64String($kept) -ceq [System.Convert]::ToBase64String($suffix)) 'the two segments are the newest bytes, contiguous and in order'
        $state = Read-ReaderState $files.State
        Assert-True ([int]$state.rotations -ge 200) "the log rolled over ($($state.rotations) times)"
        Assert-Equal ([long]$stream.Length) ([long]$state.bytesRead) -Because 'every byte was read'
    }

    It 'arms nothing for a VM without a serial device, or without a cycle folder' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-ConsoleBundle -Name 'plain-vm' -NoSerial
        Assert-False (Invoke-InDriver { Start-VMSerialCapture -VMName 'plain-vm' }) 'no device, no reader'
        Assert-False (Test-Path -LiteralPath (Join-Path $script:Cycle 'plain-vm')) 'nothing written for it'
        Set-ConsoleBundle -Name 'orphan-vm' -SerialPort (Get-YurunaTestFreePort)
        $env:YURUNA_CYCLE_CONTEXT = ''
        Assert-False (Invoke-InDriver { Start-VMSerialCapture -VMName 'orphan-vm' }) 'no cycle, no evidence folder to keep a log in'
        Assert-Equal 0 @(Get-Job | Where-Object { $_.Name -like 'yuruna-serial-*' }).Count -Because 'no reader was started'
    }

    It 'saves the log in place in the VM folder, or copies it elsewhere, with the reader''s account' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $port = Get-YurunaTestFreePort
        Set-ConsoleBundle -Name 'saved-vm' -SerialPort $port
        $files = Get-CaptureFile -VMName 'saved-vm'
        Assert-True (Invoke-InDriver { Start-VMSerialCapture -VMName 'saved-vm' }) 'armed'
        $listener = New-YurunaTestTcpListener -Port $port
        $guest = $null
        try {
            $guest = Wait-GuestConnection -Listener $listener
            Send-GuestByte -Guest $guest -Text "watchdog: BUG: soft lockup - CPU#3 stuck for 22s!`n"
            Wait-Until { (Read-SharedText $files.Log) -match 'soft lockup' } -Because 'the report reaches the log'
            # Collected while the wedged guest still holds its console open.
            $elsewhere = Join-Path $script:Cycle 'collected'
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            Assert-True (Invoke-InDriver { param($d) Save-VMSerialCapture -VMName 'saved-vm' -OutputDirectory $d } @($elsewhere)) 'a log with content was kept'
            Assert-True ($clock.Elapsed.TotalSeconds -lt 10) "the failure path is not held by the reader ($([int]$clock.Elapsed.TotalSeconds) s)"
        } finally {
            if ($guest) { $guest.Dispose() }
            $listener.Stop()
        }
        Assert-Equal 0 @(Get-Job | Where-Object { $_.Name -eq 'yuruna-serial-saved-vm' }).Count -Because 'the failure path stops the reader'
        Assert-Match 'soft lockup' ([System.IO.File]::ReadAllText((Join-Path $elsewhere 'serial-console.log'))) 'copied into another folder'
        Assert-True (Test-Path -LiteralPath (Join-Path $elsewhere 'serial-console.reader.json')) 'with the reader sidecar'
        $info = [System.IO.File]::ReadAllText((Join-Path $elsewhere 'serial-console.info.txt'))
        Assert-Match "(?m)^port:\s+127\.0\.0\.1:$port$" $info
        Assert-Match "(?m)^bytes:\s+$([System.IO.FileInfo]::new($files.Log).Length)$" $info
        Assert-Match '(?m)^connects:\s+1$' $info
        Assert-True (Invoke-InDriver { param($d) Save-VMSerialCapture -VMName 'saved-vm' -OutputDirectory $d } @($files.Directory)) 'kept in place'
        Assert-Equal 1 @(Get-ChildItem -LiteralPath $files.Directory -Filter 'serial-console*.log').Count -Because 'the VM folder keeps one log, not a copy of it'
        Assert-True (Test-Path -LiteralPath (Join-Path $files.Directory 'serial-console.info.txt')) 'the account lands beside it'
    }

    It 'says what an armed reader saw when the guest wrote nothing, and saves nothing for a VM never armed' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Set-ConsoleBundle -Name 'quiet-vm' -SerialPort (Get-YurunaTestFreePort)
        $files = Get-CaptureFile -VMName 'quiet-vm'
        Assert-True (Invoke-InDriver { Start-VMSerialCapture -VMName 'quiet-vm' }) 'armed'
        Wait-Until { $state = Read-ReaderState $files.State; $state -and $state.lastError } -Because 'the reader records the refused port'
        Assert-False (Invoke-InDriver { param($d) Save-VMSerialCapture -VMName 'quiet-vm' -OutputDirectory $d } @($files.Directory)) 'no content to keep'
        $info = [System.IO.File]::ReadAllText((Join-Path $files.Directory 'serial-console.info.txt'))
        Assert-Match '(?m)^connects:\s+0$' $info 'the reader never reached the port'
        Assert-Match '(?m)^lastError:\s+\S' $info 'and says why'
        Assert-False (Invoke-InDriver { param($d) Save-VMSerialCapture -VMName 'never-vm' -OutputDirectory $d } @((Join-Path $script:Cycle 'never-vm'))) 'nothing was captured'
        Assert-False (Test-Path -LiteralPath (Join-Path $script:Cycle 'never-vm')) 'and nothing is written'
    }

    It 'joins a report that rolled over into the log the runner reads, without waiting on a guest that holds its console' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Invoke-InDriver { $script:UtmSerialCaptureSegmentBytes = 64KB }
        $port = Get-YurunaTestFreePort
        Set-ConsoleBundle -Name 'lockup-vm' -SerialPort $port
        $files = Get-CaptureFile -VMName 'lockup-vm'
        # A lockup report, then quiet kernel records past one segment: the reader
        # rolls the report over into serial-console.1.log, and the live log keeps
        # only quiet records.
        $text = [System.Text.StringBuilder]::new("[  412.118230] watchdog: BUG: soft lockup - CPU#3 stuck for 22s! [swapper/3:0]`r`n")
        for ($i = 0; $text.Length -lt 70KB; $i++) {
            [void]$text.Append([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "[{0,12:F6}] EXT4-fs (vda2): re-mounted. Quota mode: none.`r`n", 413 + $i * 0.01))
        }
        $stream = [System.Text.Encoding]::ASCII.GetBytes($text.ToString())
        Assert-True (Invoke-InDriver { Start-VMSerialCapture -VMName 'lockup-vm' }) 'armed'
        $listener = New-YurunaTestTcpListener -Port $port
        $guest = $null
        try {
            $guest = Wait-GuestConnection -Listener $listener
            $guest.GetStream().Write($stream, 0, $stream.Length)
            Wait-Until {
                [System.IO.File]::Exists($files.Previous) -and [System.IO.File]::Exists($files.Log) -and
                ([System.IO.FileInfo]::new($files.Previous).Length + [System.IO.FileInfo]::new($files.Log).Length) -eq $stream.Length
            } -Because 'the reader rolls the report over and reads the rest'
            Assert-False ((Read-SharedText $files.Log) -match 'soft lockup') 'the live log alone no longer holds the report'
            # The failure step, while the wedged guest still holds its console open.
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            Assert-True (Invoke-InDriver { param($d) Save-VMSerialCapture -VMName 'lockup-vm' -OutputDirectory $d } @($files.Directory)) 'a log with content was kept'
            $saveSeconds = $clock.Elapsed.TotalSeconds
            $reading = Invoke-RunnerKernelReading -Folder $files.Directory
            $stepSeconds = $clock.Elapsed.TotalSeconds
        } finally {
            if ($guest) { $guest.Dispose() }
            $listener.Stop()
        }
        Assert-True ($saveSeconds -lt 10) "the save is not held by the reader ($([int]$saveSeconds) s)"
        Assert-True ($stepSeconds -lt 30) "the failure step is bounded ($([int]$stepSeconds) s)"
        Assert-NotNull $reading 'the runner read the saved log'
        Assert-True (@($reading.kinds) -contains 'soft-lockup') "the report that rolled over is in the reading (kinds: $(@($reading.kinds) -join ', '))"
        Assert-True ([int]$reading.faultRecords -ge 1) "fault records: $($reading.faultRecords)"
        Assert-False (Test-Path -LiteralPath $files.Previous) 'the rolled segment is joined into the saved log'
        Assert-True ([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($files.Log)) -ceq [System.Convert]::ToBase64String($stream)) 'the saved log is the whole stream, in order'
        $info = [System.IO.File]::ReadAllText((Join-Path $files.Directory 'serial-console.info.txt'))
        Assert-Match "(?m)^bytes:\s+$($stream.Length)$" $info
        Assert-Match '(?m)^previousBytes:\s+[1-9]\d*$' $info 'the account says how much came from the rolled segment'
        Assert-Match '(?m)^lastByte:\s+\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$' $info 'the account dates the newest byte, as the Hyper-V capture does'
    }

    It 'saves a joined copy in another folder for the runner to read and leaves the VM folder''s segments alone' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $files = Get-CaptureFile -VMName 'nested-vm'
        $null = New-Item -ItemType Directory -Force -Path $files.Directory
        $rolled = [System.Text.Encoding]::ASCII.GetBytes("[  412.118230] watchdog: BUG: soft lockup - CPU#3 stuck for 22s! [swapper/3:0]`r`n")
        $live = [System.Text.Encoding]::ASCII.GetBytes("[  460.000001] EXT4-fs (vda2): re-mounted. Quota mode: none.`r`n")
        [System.IO.File]::WriteAllBytes($files.Previous, $rolled)
        [System.IO.File]::WriteAllBytes($files.Log, $live)
        [System.IO.File]::WriteAllText($files.State, '{"port":6947,"connectedCount":1}')
        # A nested run's failure folder for the VM is elsewhere in the cycle folder.
        $elsewhere = Join-Path $script:Cycle 'nested/node/nested-vm'
        Assert-True (Invoke-InDriver { param($d) Save-VMSerialCapture -VMName 'nested-vm' -OutputDirectory $d } @($elsewhere)) 'a log with content was kept'
        $reading = Invoke-RunnerKernelReading -Folder $elsewhere
        Assert-NotNull $reading 'the runner read the copy'
        Assert-True (@($reading.kinds) -contains 'soft-lockup') "the report that rolled over is in the reading (kinds: $(@($reading.kinds) -join ', '))"
        $expected = Join-ByteArray -Part $rolled, $live
        Assert-True ([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes((Join-Path $elsewhere 'serial-console.log'))) -ceq [System.Convert]::ToBase64String($expected)) 'the copy is the rolled segment, then the live one'
        Assert-False (Test-Path -LiteralPath (Join-Path $elsewhere 'serial-console.1.log')) 'one saved log, the one the runner reads'
        Assert-True (Test-Path -LiteralPath (Join-Path $elsewhere 'serial-console.reader.json')) 'with the reader sidecar'
        Assert-StringEqual ([System.Convert]::ToBase64String($rolled)) ([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($files.Previous))) 'the VM folder keeps its rolled segment'
        Assert-StringEqual ([System.Convert]::ToBase64String($live)) ([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($files.Log))) 'and its live log'
    }

    It 'holds a joined log to the newest two segments' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Invoke-InDriver { $script:UtmSerialCaptureSegmentBytes = 1KB }
        $files = Get-CaptureFile -VMName 'twice-vm'
        $null = New-Item -ItemType Directory -Force -Path $files.Directory
        # A log joined at an earlier failure, rolled over whole by the reader armed
        # after it, then a live segment.
        [System.IO.File]::WriteAllBytes($files.Previous, [System.Text.Encoding]::ASCII.GetBytes(('a' * 1KB) + ('b' * 1KB)))
        [System.IO.File]::WriteAllBytes($files.Log, [System.Text.Encoding]::ASCII.GetBytes('c' * 1KB))
        [System.IO.File]::WriteAllText($files.State, '{"port":6947}')
        Assert-True (Invoke-InDriver { param($d) Save-VMSerialCapture -VMName 'twice-vm' -OutputDirectory $d } @($files.Directory)) 'a log with content was kept'
        Assert-StringEqual (('b' * 1KB) + ('c' * 1KB)) ([System.IO.File]::ReadAllText($files.Log)) 'the newest two segments, in order'
        Assert-False (Test-Path -LiteralPath $files.Previous) 'nothing is left beside it'
    }

    It 'stops a reader waiting on a quiet console by name within seconds, and keeps its log' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $port = Get-YurunaTestFreePort
        Set-ConsoleBundle -Name 'stopped-vm' -SerialPort $port
        $files = Get-CaptureFile -VMName 'stopped-vm'
        Assert-True (Invoke-InDriver { Start-VMSerialCapture -VMName 'stopped-vm' }) 'armed'
        $listener = New-YurunaTestTcpListener -Port $port
        $guest = $null
        try {
            $guest = Wait-GuestConnection -Listener $listener
            Send-GuestByte -Guest $guest -Text "login:`n"
            Wait-Until { (Read-SharedText $files.Log) -match 'login:' } -Because 'the console reaches the log'
            # The VM is still up and quiet, so the reader is waiting for its next byte.
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            Assert-True (Invoke-InDriver { Stop-VMSerialCapture -VMName 'stopped-vm' }) 'nothing left running'
            Assert-True ($clock.Elapsed.TotalSeconds -lt 10) "a teardown is not held by the reader ($([int]$clock.Elapsed.TotalSeconds) s)"
        } finally {
            if ($guest) { $guest.Dispose() }
            $listener.Stop()
        }
        Assert-Equal 0 @(Get-Job | Where-Object { $_.Name -eq 'yuruna-serial-stopped-vm' }).Count
        Assert-Match 'login:' (Read-SharedText $files.Log) 'a guest that recovered may still have printed why it needed to'
    }

    It 'stops at once when stopped just as the guest closes its console, every time' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        # The reader tidies up the closed connection in the same instant, which
        # is where a stop request can be dropped and leave Stop-Job waiting.
        for ($round = 1; $round -le 8; $round++) {
            $port = Get-YurunaTestFreePort
            Set-ConsoleBundle -Name 'closing-vm' -SerialPort $port
            Assert-True (Invoke-InDriver { Start-VMSerialCapture -VMName 'closing-vm' }) "armed (round $round)"
            $listener = New-YurunaTestTcpListener -Port $port
            $guest = $null
            try {
                $guest = Wait-GuestConnection -Listener $listener
                Send-GuestByte -Guest $guest -Text "round $round`n"
                Wait-Until { (Read-SharedText (Get-CaptureFile -VMName 'closing-vm').Log) -match "round $round" } -Because "round $round reaches the log"
            } finally {
                if ($guest) { $guest.Dispose() }
                $listener.Stop()
            }
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            Assert-True (Invoke-InDriver { Stop-VMSerialCapture -VMName 'closing-vm' }) "nothing left running (round $round)"
            Assert-True ($clock.Elapsed.TotalSeconds -lt 10) "round $round stopped in $([int]$clock.Elapsed.TotalSeconds) s"
        }
    }

    It 'reads the live log after an offset, a rolled-over log from its start, and nothing without a capture' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $files = Get-CaptureFile -VMName 'read-vm'
        Assert-Null (Invoke-InDriver { Read-VMSerialCapture -VMName 'read-vm' -MaxBytes 0 }) 'no capture, no mark'
        $null = New-Item -ItemType Directory -Force -Path $files.Directory
        [System.IO.File]::WriteAllText($files.State, '{"port":6947}')
        Assert-Equal 0 (Invoke-InDriver { Read-VMSerialCapture -VMName 'read-vm' -MaxBytes 0 }).Length -Because 'an armed reader that has not connected marks 0'
        [System.IO.File]::WriteAllText($files.Log, 'abcdef')
        Assert-Equal 6 (Invoke-InDriver { Read-VMSerialCapture -VMName 'read-vm' -MaxBytes 0 }).Length
        Assert-StringEqual 'cdef' (Invoke-InDriver { Read-VMSerialCapture -VMName 'read-vm' -FromOffset 2 }).Text
        $newest = Invoke-InDriver { Read-VMSerialCapture -VMName 'read-vm' -MaxBytes 3 }
        Assert-StringEqual 'def' $newest.Text
        Assert-True $newest.Truncated 'older bytes were left out'
        $rolled = Invoke-InDriver { Read-VMSerialCapture -VMName 'read-vm' -FromOffset 10 }
        Assert-True $rolled.Replaced 'a log shorter than the mark rolled over'
        Assert-StringEqual 'abcdef' $rolled.Text
        Assert-Null (Get-Command -Name Read-VMSerialCapture -ErrorAction SilentlyContinue) 'not exported, so the sequence engine takes no step marks on this host'
    }
}

Describe 'The QEMU monitor capture' {
    BeforeEach {
        $script:MonitorDir = New-YurunaTestTempDir -Prefix 'yrn-qemu-monitor'
    }
    AfterEach {
        Remove-YurunaTestTempDir $script:MonitorDir
    }

    It 'records the three answers without the echo or the terminal escapes' {
        $monitor = Start-FakeQemuMonitor
        try {
            $r = Invoke-InDriver { param($p, $d) Save-UtmQemuMonitorCapture -VMName 'wedged-vm' -Port $p -OutputDirectory $d -Trigger 'startup-timeout' } @($monitor.Port, $script:MonitorDir)
            Assert-StringEqual 'captured' $r.outcome $r.reason
            Assert-StringEqual 'info status|info cpus|info registers -a' (@($monitor.Commands.ToArray()) -join '|') 'the three commands, in order'
            Assert-Equal 3 @($r.commands | Where-Object { $_.outcome -eq 'answered' }).Count
            Assert-StringEqual (Join-Path $script:MonitorDir 'qemu-monitor.startup-timeout.txt') $r.path
            $text = [System.IO.File]::ReadAllText($r.path)
            Assert-Match '(?m)^outcome: captured$' $text
            Assert-Match "(?m)^QEMU 9\.2\.0 monitor - type 'help' for more information$" $text 'the banner names the QEMU build'
            Assert-Match '(?m)^\(qemu\) info status\nVM status: running$' $text
            Assert-Match '(?m)^\* CPU #0: thread_id=4101$' $text
            Assert-Match 'PC=ffff800080123456' $text
            Assert-Match 'PC=ffff800080654321' $text
            Assert-False ($text.Contains([char]27)) 'no terminal escapes'
            Assert-False ($text -match 'iinf|infoinfo') 'no echo of the typed commands'
        } finally { Stop-FakeQemuMonitor $monitor }
    }

    It 'ends at a command that does not answer and keeps what came before, within its bound' {
        $monitor = Start-FakeQemuMonitor -Behavior 'stall-registers'
        try {
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-InDriver { param($p, $d) Save-UtmQemuMonitorCapture -VMName 'wedged-vm' -Port $p -OutputDirectory $d -Trigger 'stall' } @($monitor.Port, $script:MonitorDir)
            Assert-True ($clock.Elapsed.TotalSeconds -lt 9) "bounded ($([int]$clock.Elapsed.TotalSeconds) s)"
            Assert-StringEqual 'partial' $r.outcome
            Assert-StringEqual 'timeout' @($r.commands)[2].outcome
            $text = [System.IO.File]::ReadAllText($r.path)
            Assert-Match 'VM status: running' $text 'the answers before the stall are kept'
            Assert-Match 'thread_id=4102' $text
            Assert-Match '\[timeout after \d+ ms\]' $text
        } finally { Stop-FakeQemuMonitor $monitor }
    }

    It 'says when the monitor never prompts, within its bound, and sends nothing' {
        $monitor = Start-FakeQemuMonitor -Behavior 'silent'
        try {
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-InDriver { param($p, $d) Save-UtmQemuMonitorCapture -VMName 'wedged-vm' -Port $p -OutputDirectory $d -Trigger 'silent' } @($monitor.Port, $script:MonitorDir)
            Assert-True ($clock.Elapsed.TotalSeconds -lt 6) "bounded ($([int]$clock.Elapsed.TotalSeconds) s)"
            Assert-StringEqual 'no-prompt' $r.outcome
            Assert-Equal 3 @($r.commands | Where-Object { $_.outcome -eq 'not-sent' }).Count
            Assert-Equal 0 $monitor.Commands.Count -Because 'a monitor that never prompted is not sent commands'
            Assert-True (Test-Path -LiteralPath $r.path) 'the attempt is still on record'
        } finally { Stop-FakeQemuMonitor $monitor }
    }

    It 'says when nothing listens, without waiting, and writes nothing' {
        $port = Get-YurunaTestFreePort
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-InDriver { param($p, $d) Save-UtmQemuMonitorCapture -VMName 'gone-vm' -Port $p -OutputDirectory $d -Trigger 'gone' } @($port, $script:MonitorDir)
        Assert-True ($clock.Elapsed.TotalSeconds -lt 3) "bounded ($([int]$clock.Elapsed.TotalSeconds) s)"
        Assert-StringEqual 'unreachable' $r.outcome
        Assert-True ($r.reason.Length -gt 0) 'the refusal is recorded'
        Assert-StringEqual '' $r.path
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $script:MonitorDir).Count
    }

    It 'attempts nothing without a monitor port or once the deadline is spent' {
        $none = Invoke-InDriver { param($d) Save-UtmQemuMonitorCapture -VMName 'plain-vm' -Port -1 -OutputDirectory $d -Trigger 'plain' } @($script:MonitorDir)
        Assert-StringEqual 'not-configured' $none.outcome
        $monitor = Start-FakeQemuMonitor
        try {
            $spent = Invoke-InDriver {
                param($p, $d)
                Save-UtmQemuMonitorCapture -VMName 'late-vm' -Port $p -OutputDirectory $d -Trigger 'late' -Deadline (New-YurunaDeadline -TotalMilliseconds 0)
            } @($monitor.Port, $script:MonitorDir)
            Assert-StringEqual 'deadline-exhausted' $spent.outcome
            Start-Sleep -Milliseconds 200
            Assert-False $monitor.Listener.Pending() 'no connection was attempted'
            Assert-Equal 0 @(Get-ChildItem -LiteralPath $script:MonitorDir).Count
        } finally { Stop-FakeQemuMonitor $monitor }
    }
}

Describe 'The control snapshot reads the guest before UTM' {
    BeforeEach {
        if ($script:CanShim) {
            Reset-MacUtmFakeHost -FakeHost $script:Fake
            Enter-MacUtmFakeHost -FakeHost $script:Fake
            $script:SavedEnvironment = Save-YurunaTestEnvironment -Name 'YURUNA_CYCLE_CONTEXT', 'YURUNA_LOG_DIR'
            $script:SavedGlobal = Save-YurunaTestGlobal -Name '__YurunaCycleFolder'
            $env:YURUNA_LOG_DIR = ''
            Set-YurunaTestGlobal -Value @{ __YurunaCycleFolder = $null }
            Enter-CycleFolder
        }
    }
    AfterEach {
        if ($script:CanShim) {
            Restore-YurunaTestEnvironment -Saved $script:SavedEnvironment
            Restore-YurunaTestGlobal -Saved $script:SavedGlobal
            Exit-MacUtmFakeHost -FakeHost $script:Fake
        }
    }

    It 'keeps the monitor answers and the serial tail beside the snapshot while a hung listing spends the deadline' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Set-MacUtmFakeState -FakeHost $script:Fake -Key 'list.mode' -Value 'hang'
        $monitor = Start-FakeQemuMonitor
        try {
            Set-ConsoleBundle -Name 'test-guest.ubuntu.server.26-01' -SerialPort (Get-YurunaTestFreePort) -MonitorPort $monitor.Port
            $files = Get-CaptureFile -VMName 'test-guest.ubuntu.server.26-01'
            $null = New-Item -ItemType Directory -Force -Path $files.Directory
            $console = "EFI stub: Booting Linux Kernel...`r`nwatchdog: BUG: soft lockup - CPU#5 stuck for 26s! [swapper/5:0]`r`n"
            [System.IO.File]::WriteAllText($files.Log, $console)
            [System.IO.File]::WriteAllText($files.State, '{"port":6947,"connectedCount":1,"connectAttempts":3,"lastError":null}')
            $failed = Join-Path $files.Directory 'failed_step2-attempt1'
            $null = New-Item -ItemType Directory -Force -Path $failed
            $r = Invoke-InDriver {
                param($d)
                Save-UtmControlSnapshot -OutputDirectory $d -Trigger 'startup-timeout' -VMName 'test-guest.ubuntu.server.26-01' `
                    -LogTimeoutSeconds 1 -Deadline (New-YurunaDeadline -TotalMilliseconds 4000) -SkipScreenshot -Confirm:$false
            } @($failed)
            Assert-True $r.Written $r.Reason
            $record = Get-Content -Raw -LiteralPath $r.Path | ConvertFrom-Json -AsHashtable
            Assert-StringEqual 'captured' $record.qemuMonitor.outcome "the monitor was read before the listing hung: $($record.qemuMonitor.reason)"
            Assert-True (Test-Path -LiteralPath (Join-Path $failed 'qemu-monitor.startup-timeout.txt')) 'the monitor answers sit beside the snapshot'
            Assert-True ($record.listing.timedOut -or -not $record.listing.started) 'the listing hung on what was left of the deadline'
            Assert-StringEqual 'saved' $record.serialConsole.outcome $record.serialConsole.reason
            Assert-StringEqual (Join-Path '..' 'serial-console.log') $record.serialConsole.log 'the live log is linked relative to the snapshot'
            Assert-Equal ([System.Text.Encoding]::UTF8.GetByteCount($console)) $record.serialConsole.logBytes -Because 'where the restart begins in the live log'
            Assert-StringEqual $console ([System.IO.File]::ReadAllText((Join-Path $failed 'serial-console.startup-timeout.log'))) 'the tail is kept beside the snapshot'
            Assert-Equal 1 $record.serialConsole.reader.connectedCount -Because 'the reader account travels with it'
            Assert-Equal 0 @($record.problems | Where-Object { $_ -match 'qemu monitor|serial console' }).Count -Because "$($record.problems -join '; ')"
        } finally { Stop-FakeQemuMonitor $monitor }
    }

    It 'copies the newest bytes across a rollover just before the snapshot, as the guest sent them' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        $files = Get-CaptureFile -VMName 'rolled-vm'
        $null = New-Item -ItemType Directory -Force -Path $files.Directory
        # The reader rolled the log over moments before the wedge: the lockup is
        # in the rolled segment, and the live log holds a few bytes of firmware
        # output that are not valid UTF-8.
        $rolled = [System.Text.Encoding]::ASCII.GetBytes(('.' * 300KB) + "`r`n[  412.118230] watchdog: BUG: soft lockup - CPU#3 stuck for 22s! [swapper/3:0]`r`n")
        $live = [byte[]](0x1B, 0x5B, 0x32, 0x4A, 0xC4, 0xB3, 0xFF, 0x0D, 0x0A)
        [System.IO.File]::WriteAllBytes($files.Previous, $rolled)
        [System.IO.File]::WriteAllBytes($files.Log, $live)
        $failed = Join-Path $files.Directory 'failed_step2-attempt1'
        $r = Invoke-InDriver { param($d) Save-UtmSerialConsoleTail -VMName 'rolled-vm' -OutputDirectory $d -Trigger 'startup-timeout' } @($failed)
        Assert-StringEqual 'saved' $r.outcome $r.reason
        $all = Join-ByteArray -Part $rolled, $live
        $newest = [byte[]]::new(256KB)
        [Array]::Copy($all, $all.Length - $newest.Length, $newest, 0, $newest.Length)
        $copy = [System.IO.File]::ReadAllBytes($r.path)
        Assert-True ([System.Convert]::ToBase64String($copy) -ceq [System.Convert]::ToBase64String($newest)) 'the newest 256 KiB of both segments, byte for byte'
        Assert-Equal ([long]$copy.Length) $r.tailBytes -Because 'tailBytes counts what the copy holds'
        Assert-True $r.truncated 'older bytes were left out'
        Assert-Equal ([long]$live.Length) $r.logBytes -Because 'where the restart begins in the live log'
        Assert-Equal ([long]$rolled.Length) $r.previousLogBytes
    }

    It 'records a VM without the console devices as such, attempting nothing' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Add-MacUtmFakeProcess -FakeHost $script:Fake -ProcessId 600 -Name 'UTM'
        Set-ConsoleBundle -Name 'yuruna-caching-proxy-service' -NoSerial
        $r = Invoke-InDriver {
            param($d)
            Save-UtmControlSnapshot -OutputDirectory $d -Trigger 'start-control-hung' -VMName 'yuruna-caching-proxy-service' -LogTimeoutSeconds 1 -SkipScreenshot -Confirm:$false
        } @($script:Cycle)
        $record = Get-Content -Raw -LiteralPath $r.Path | ConvertFrom-Json -AsHashtable
        Assert-StringEqual 'not-configured' $record.qemuMonitor.outcome
        Assert-StringEqual 'no-capture' $record.serialConsole.outcome
        Assert-Equal 0 @(Get-ChildItem -LiteralPath $script:Cycle -Filter 'qemu-monitor.*').Count
    }
}

Describe 'Start-VM, Remove-VM and Rename-VM manage the reader' {
    BeforeEach {
        $script:Saved = Invoke-InDriver {
            $script:WiringCall = [System.Collections.Generic.List[string]]::new()
            return @{
                StartCapture = ${function:Start-VMSerialCapture}; StopCapture = ${function:Stop-VMSerialCapture}
                StartUtm = ${function:Start-UtmVM}; RemoveUtm = ${function:Remove-UtmTestVM}; State = ${function:Get-VMState}
            }
        }
        Invoke-InDriver {
            Set-Item -Path 'function:script:Start-VMSerialCapture' -Value { param([string]$VMName) $script:WiringCall.Add("capture $VMName"); $true }
            Set-Item -Path 'function:script:Stop-VMSerialCapture' -Value { param([string]$VMName) $script:WiringCall.Add("stop-capture $VMName"); $true }
            Set-Item -Path 'function:script:Remove-UtmTestVM' -Value { [CmdletBinding(SupportsShouldProcess)] param([string]$VMName) $script:WiringCall.Add("remove $VMName"); $true }
            Set-Item -Path 'function:script:Get-VMState' -Value { param([string]$VMName) if ($VMName -eq 'old-vm') { 'stopped' } else { 'absent' } }
        }
    }
    AfterEach {
        Invoke-InDriver {
            param($s)
            Set-Item -Path 'function:script:Start-VMSerialCapture' -Value $s.StartCapture
            Set-Item -Path 'function:script:Stop-VMSerialCapture' -Value $s.StopCapture
            Set-Item -Path 'function:script:Start-UtmVM' -Value $s.StartUtm
            Set-Item -Path 'function:script:Remove-UtmTestVM' -Value $s.RemoveUtm
            Set-Item -Path 'function:script:Get-VMState' -Value $s.State
        } @($script:Saved)
    }

    It 'arms the reader before the start and again after a start that succeeded' {
        Invoke-InDriver {
            Set-Item -Path 'function:script:Start-UtmVM' -Value { [CmdletBinding(SupportsShouldProcess)] param([string]$VMName) $script:WiringCall.Add("start $VMName"); @{ success = $true; errorMessage = $null } }
        }
        $r = Start-VM -VMName 'wired-vm' -Confirm:$false
        Assert-True ($r -is [hashtable] -and $r.success) 'the start record passes through unchanged'
        Assert-Equal 'capture wired-vm|start wired-vm|capture wired-vm' ((Invoke-InDriver { $script:WiringCall }) -join '|')
    }

    It 'does not arm again after a start that failed' {
        Invoke-InDriver {
            Set-Item -Path 'function:script:Start-UtmVM' -Value { [CmdletBinding(SupportsShouldProcess)] param([string]$VMName) $script:WiringCall.Add("start $VMName"); @{ success = $false; errorMessage = 'refused' } }
        }
        $r = Start-VM -VMName 'wired-vm' -Confirm:$false
        Assert-False $r.success
        Assert-StringEqual 'refused' $r.errorMessage
        Assert-Equal 'capture wired-vm|start wired-vm' ((Invoke-InDriver { $script:WiringCall }) -join '|')
    }

    It 'stops the reader before removing the VM' {
        Assert-True (Remove-VM -VMName 'wired-vm' -Confirm:$false)
        Assert-Equal 'stop-capture wired-vm|remove wired-vm' ((Invoke-InDriver { $script:WiringCall }) -join '|')
    }

    It 'stops the old name''s reader once the rename passes its state checks' {
        if (-not $script:CanShim) { Set-ItResult -Skipped -Because $script:Skip; return }
        Reset-MacUtmFakeHost -FakeHost $script:Fake
        Enter-MacUtmFakeHost -FakeHost $script:Fake
        try {
            # No bundle on disk, so the rename stops right after the reader does.
            $null = Rename-VM -VMName 'old-vm' -NewName 'new-vm' -Confirm:$false -WarningAction SilentlyContinue
            Assert-Equal 'stop-capture old-vm' ((Invoke-InDriver { $script:WiringCall }) -join '|')
        } finally { Exit-MacUtmFakeHost -FakeHost $script:Fake }
    }
}

# See https://yuruna.link/42885ada-0014
Describe 'The UTM Ubuntu seed forwards the installed journal to the serial console' {
    BeforeAll {
        Import-Module (Join-Path $script:RepoRoot 'automation/Yuruna.CloudInitTemplate.psm1') -Force -DisableNameChecking
        Import-Module powershell-yaml -ErrorAction Stop
        $seedRoot = Join-Path $script:RepoRoot 'host/vmconfig'
        $script:UtmSeedText = Merge-CloudInitUserData -BasePath (Join-Path $seedRoot 'ubuntu.server.base.user-data') `
            -OverlayPath (Join-Path $seedRoot 'ubuntu.server.utm.overlay.yml')
        # The proxy block is multi-line YAML the builder renders; an empty
        # value keeps the document parseable for the late commands read here.
        $script:UtmLateCommand = @((ConvertFrom-Yaml $script:UtmSeedText.Replace('APT_PROXY_BLOCK_PLACEHOLDER', '')).autoinstall['late-commands'] |
            ForEach-Object { [string]$_ })
        $script:ForwarderCommand = @($script:UtmLateCommand | Where-Object { $_.Contains('/target/etc/systemd/system/yuruna-serial-journal.service') })
    }

    It 'copies every journal level to the PL011 from its own service and adds no kernel console argument' {
        Assert-Equal 1 $script:ForwarderCommand.Count -Because 'one late command installs the journal service'
        Assert-True (-not $script:UtmSeedText.Contains('70-yuruna-serial.conf')) 'no journald drop-in forwards to the tty'
        Assert-NoFinding @($script:UtmLateCommand | Where-Object { $_ -match '(?m)^\s*ForwardToConsole=yes' }) 'journald''s console write is inline: a UART that stops draining would block journald, and sudo and sshd behind it'
        Assert-True ($script:ForwarderCommand[0].Contains('ExecStart=/usr/local/lib/yuruna/serial-journal /dev/ttyAMA0')) "the service names the PL011; it reads: $($script:ForwarderCommand[0])"
        $cmdline = @($script:UtmLateCommand | Where-Object { $_.Contains('GRUB_CMDLINE_LINUX') })
        Assert-True ($cmdline.Count -gt 0) 'the base still writes its console-quiet GRUB drop-in'
        Assert-NoFinding @($cmdline | Where-Object { $_ -match 'console=' }) 'the arm64 kernel already takes the SPCR UART as its console, and a console= argument naming tty0 would put kernel console output on the framebuffer the OCR reads'
        Assert-True (-not $script:UtmSeedText.Contains('98-yuruna-serial.cfg')) 'no GRUB serial drop-in is written on UTM'
    }

    It 'leaves an enabled service whose script copies the journal per line when the late command runs' {
        if ($IsWindows) { Set-ItResult -Skipped -Because 'the late command is a POSIX shell script'; return }
        Assert-Equal 1 $script:ForwarderCommand.Count -Because 'one late command installs the journal service'
        $target = Join-Path $TestDrive 'target'
        $scriptPath = Join-Path $TestDrive 'late-command.sh'
        [IO.File]::WriteAllText($scriptPath, $script:ForwarderCommand[0].Replace('/target/', "$target/").Replace('ln -sf /etc/systemd/system/', "ln -sf $target/etc/systemd/system/"))
        $output = & /bin/sh $scriptPath 2>&1
        Assert-Equal 0 $LASTEXITCODE -Because "a failing late command aborts the whole install: $output"
        $unit = Join-Path $target 'etc/systemd/system/yuruna-serial-journal.service'
        $forwarder = Join-Path $target 'usr/local/lib/yuruna/serial-journal'
        Assert-True (Test-Path -LiteralPath (Join-Path $target 'etc/systemd/system/sysinit.target.wants/yuruna-serial-journal.service')) 'the service is enabled for the installed system''s first boot'
        Assert-Match '(?m)^\[Install\]\r?\nWantedBy=sysinit\.target$' (Get-Content -LiteralPath $unit -Raw)
        Assert-Match '(?m)^StartLimitIntervalSec=0$' (Get-Content -LiteralPath $unit -Raw) 'a missing device must not retire the service for the rest of the boot'
        Assert-Equal ([IO.UnixFileMode]'UserRead, UserWrite, UserExecute, GroupRead, GroupExecute, OtherRead, OtherExecute') ([IO.File]::GetUnixFileMode($forwarder)) -Because 'systemd executes the script directly'

        # journalctl is stood in for by a script that records its arguments and
        # prints lines, so the copy runs without a journal.
        $bin = Join-Path $TestDrive 'bin'
        $null = New-Item -ItemType Directory -Force -Path $bin
        $stub = Join-Path $bin 'journalctl'
        $stubText = @'
#!/bin/sh
printf '%s\n' "$*" > "ARGS_PATH"
printf '%s\n' 'first  \ line' '[    1.5] sudo[1]: second $HOME line'
'@
        [IO.File]::WriteAllText($stub, $stubText.Replace('ARGS_PATH', "$TestDrive/journalctl.args"))
        [IO.File]::SetUnixFileMode($stub, [IO.UnixFileMode]'UserRead, UserWrite, UserExecute')
        $savedPath = Save-YurunaTestEnvironment -Name 'PATH'
        try {
            $env:PATH = "$bin$([IO.Path]::PathSeparator)$env:PATH"
            # The script reopens its target per line, which a regular file would
            # truncate and a tty does not; /dev/stdout reopens like the tty.
            $copied = @(& /bin/sh $forwarder /dev/stdout 2>&1)
            Assert-Equal 0 $LASTEXITCODE -Because "the copy runs to the end of the journal: $copied"
        } finally { Restore-YurunaTestEnvironment -Saved $savedPath }
        Assert-True (($copied -join "`n") -ceq ('first  \ line' + "`n" + '[    1.5] sudo[1]: second $HOME line')) "lines arrive byte for byte, as the host's serial parser expects: $copied"
        $arguments = [IO.File]::ReadAllText("$TestDrive/journalctl.args")
        Assert-Match '--lines=all' $arguments '--follow alone starts at the last 10 lines and would lose the boot'
        Assert-Match '--output=short-monotonic' $arguments 'the serial parser reads printk-style stamps'
        Assert-Match '--no-hostname' $arguments 'the serial parser reads ident[pid]: right after the stamp'
        Assert-True (-not $arguments.Contains('_TRANSPORT=kernel')) 'the kernel writes its own records to the console; a copy here would read as quoted text'
        $source = [IO.File]::ReadAllText($forwarder)
        Assert-Match '> "\$1" \|\| \{ sleep 1; printf' $source 'a line that meets agetty''s hangup is written once more instead of lost'
    }
}
