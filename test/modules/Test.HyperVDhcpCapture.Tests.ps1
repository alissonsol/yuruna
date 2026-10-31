<#PSScriptInfo
.VERSION 2026.10.31
.GUID 4211664b-fb87-4dab-a225-c1006746d404
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test dhcp capture pktmon hyper-v pester
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
if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error ("Pester is not available, so this suite cannot run. Install it with " +
                 "'Install-Module Pester -Scope CurrentUser', then re-run with " +
                 "Invoke-Pester -Path '$PSCommandPath'.")
    exit 1
}

<#
.SYNOPSIS
    A guest whose lease never came leaves the wire's side of the story in its
    failure folder, and the capture that records it can never become a fault
    of its own.
.DESCRIPTION
    WHY THIS EXISTS. The guest-side network diagnostic bottoms out at "no
    IPv4 lease" -- it cannot see whether its DISCOVER ever left the vSwitch,
    died at the uplink, or went out and was ignored, and each of those shapes
    indicts a DIFFERENT machine. The host-side pktmon capture is the only
    artifact that answers it, and it only answers if four properties hold,
    each of which fails silently when it does not:

      * Armed at Start-VM: the first DISCOVER lands seconds after firmware,
        before any sequence step runs, so a capture armed anywhere later
        records the retries and misses the first ask.
      * Bounded: pktmon allows one session per system and nothing stops a
        session whose flow never removes its VM, so an unbounded capture
        grows with host uptime.
      * Collected where the failure diagnostics are collected, and only by
        feature detection: most host drivers do not implement it, and the
        collection block must not turn a failed step into a failed cycle.
      * Ownership-scoped teardown: the cycle-start sweep removes leftover
        VMs by prefix, and a discard there that did not check ownership
        would kill the capture just armed for the guest actually under test.

    Static assertions over the sources, because the thing under test is what
    a failing cycle is BUILT to leave behind; there is no failing cycle to run.
    Run: Invoke-Pester -Path test/modules/Test.HyperVDhcpCapture.Tests.ps1
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Test.CatalogSource.psm1') -DisableNameChecking
    Import-Module (Join-Path $PSScriptRoot 'Test.DriverSource.psm1') -DisableNameChecking
    # test/modules/<this file> -> test/modules -> test -> repo root.
    $script:RepoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:DriverPath = Join-Path $script:RepoRoot 'host/windows.hyper-v/modules/Yuruna.Host.psm1'
    $script:RunnerPath = Join-Path $script:RepoRoot 'test/modules/Test.RunnerInnerLoop.psm1'
    $script:DriverText = Get-YurunaSourceText -Path $script:DriverPath
    $script:RunnerText = Get-Content -Raw -LiteralPath $script:RunnerPath

    # Function bodies close at column 0 in this module, so the first
    # column-0 brace after the header is the function's end.
    function Get-PsFunctionText {
        param([string]$Source, [string]$Name)
        $m = [regex]::Match($Source, "(?ms)^function $([regex]::Escape($Name)) \{.*?^\}")
        if (-not $m.Success) { throw "function $Name not found" }
        return $m.Value
    }
}

Describe 'hyper-v DHCP capture: armed at the only moment that sees the first DISCOVER' {

    It 'arms inside Start-VM, gated on the start actually succeeding' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Start-VM'
        $fn | Should -Match 'Start-VMDhcpCapture' -Because 'no later hook runs before the guest first asks for a lease'
        $armAt   = $fn.IndexOf('Start-VMDhcpCapture')
        $startAt = $fn.IndexOf('Start-HyperVVM')
        ($startAt -ge 0 -and $armAt -gt $startAt) | Should -BeTrue -Because 'a capture for a VM that failed to start records nothing and still claims the one pktmon session'
        $fn | Should -Match '\.success' -Because 'the arm must read the start result, not assume it'
    }

    It 'clears whatever session preceded it, because pktmon allows exactly one' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Start-VMDhcpCapture'
        $stopAt  = $fn.IndexOf('pktmon stop')
        $startAt = $fn.IndexOf('pktmon start')
        ($stopAt -ge 0 -and $startAt -gt $stopAt) | Should -BeTrue -Because 'a leftover session makes every later arm fail silently, forever'
    }

    It 'stays bounded even when nothing ever stops it' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Start-VMDhcpCapture'
        $fn | Should -Match '--log-mode circular' -Because 'a flow that starts a VM and never removes it must not grow a capture with host uptime'
        $fn | Should -Match '--file-size' -Because 'circular mode without a size cap is not bounded'
    }

    It 'keeps both DHCP ports and adds the guest''s own ARP and ICMP, scoped to its MAC' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Start-VMDhcpCapture'
        $fn | Should -Match 'pktmon filter add YurunaDhcpSrv -p 67'
        $fn | Should -Match 'pktmon filter add YurunaDhcpCli -p 68'
        $fn | Should -Match 'pktmon filter add \S+ -m \$pktmonMac -d ARP' -Because 'ARP is what a guest with no address still sends'
        $fn | Should -Match 'pktmon filter add \S+ -m \$pktmonMac -t ICMP'
        $fn | Should -Match '(?s)if \(\$guestMac\) \{[^}]*-d ARP' -Because 'an unknown MAC must not widen the capture to every ARP on the LAN'
        $fn | Should -Match 'Get-VMMac -VMName \$VMName'
        $fn.IndexOf('-d ARP') | Should -BeLessThan $fn.IndexOf('pktmon start') -Because 'filters apply to the session started after them'
    }
}

Describe 'hyper-v DHCP capture: collected with the failure, discarded with the guest' {

    It 'lands beside the failure diagnostics, by feature detection' {
        $script:RunnerText | Should -Match 'Get-Command Save-VMDhcpCapture' -Because 'most host drivers do not implement the capture; a bare call fails the collection on all of them'
        $script:RunnerText | Should -Match 'Save-VMDhcpCapture -VMName \$VMName -OutputDirectory \$destSeqDir' -Because 'the wire evidence must sit next to the diagnostics that point at it'
        ((Get-CatalogSourceMessage -Source $script:RunnerText) -join "`n") | Should -Match 'DHCP capture collection skipped' -Because 'the collection must soft-fail like its neighbors, never the step'
    }

    It 'discards at Remove-VM only a capture the removed VM owns' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Remove-VM'
        $fn | Should -Match 'Stop-VMDhcpCapture' -Because 'the no-failure teardown must not leak a running session'
        $fn | Should -Match '\.VMName -eq \$VMName' -Because 'the cycle-start sweep removes leftover VMs; an unowned discard there kills the capture of the guest under test'
    }

    It 'never lets a capture failure escape into the step' {
        foreach ($name in 'Start-VMDhcpCapture', 'Stop-VMDhcpCapture', 'Save-VMDhcpCapture') {
            $fn = Get-PsFunctionText -Source $script:DriverText -Name $name
            $fn | Should -Match '(?ms)\}\s*catch\s*\{' -Because "$name is a diagnostic; a throw here fails the cycle it exists to explain"
        }
    }

    It 'exports all three verbs so the feature detection can find them' {
        foreach ($name in 'Start-VMDhcpCapture', 'Save-VMDhcpCapture', 'Stop-VMDhcpCapture') {
            $script:DriverText | Should -Match "Export-ModuleMember[\s\S]*$name" -Because "an unexported $name reads as `"driver does not implement it`" and the capture silently never lands"
        }
    }
}

Describe 'hyper-v DHCP capture: one line says whether the guest ever asked' {
    BeforeAll {
        $ast = [Management.Automation.Language.Parser]::ParseInput($script:DriverText, [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-DhcpCaptureSummary' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        # pktmon etl2txt shape: a header naming the component, then the frame,
        # once per component the packet crossed, in UTF-16 with a BOM.
        function Get-PktmonLine {
            param([string]$Time, [string]$Source, [string]$Destination, [int]$Component, [switch]$Drop,
                [string]$Payload = 'ethertype IPv4 (0x0800), length 335: 0.0.0.0.68 > 255.255.255.255.67: UDP, length 293')
            $prefix = if ($Drop) { 'Drop: ' } else { '' }
            "[00]0000.0000::2026-10-06 $Time [Microsoft-Windows-PktMon] ${prefix}PktGroupId 8855$Component, PktNumber 1, Appearance 0, Direction Rx , Type Ethernet , Component $Component, Edge 1, Filter 1, OriginalSize 335, LoggedSize 335"
            "`t$prefix$Source > $Destination, $Payload"
        }
        # What the widened filter adds: the guest's ARP for the cache host, seen
        # at two components, then an ICMP echo to it and the echo reply back.
        # Frames a guest emits with or without a valid lease, so they must stay
        # out of every DHCP count and still move the last-heard stamp.
        $script:ArpPayload = 'ethertype ARP (0x0806), length 42: Request who-has 192.168.7.42 tell 192.168.7.129'
        $script:IcmpRequestPayload = 'ethertype IPv4 (0x0800), length 98: 192.168.7.129 > 192.168.7.42: ICMP echo request, id 1, seq 1, length 64'
        $script:IcmpReplyPayload = 'ethertype IPv4 (0x0800), length 98: 192.168.7.42 > 192.168.7.129: ICMP echo reply, id 1, seq 1, length 64'
        $lines = @(
            Get-PktmonLine -Time '13:08:48.465603600' -Source '42-54-43-AE-01-19' -Destination 'FF-FF-FF-FF-FF-FF' -Component 8
            Get-PktmonLine -Time '13:08:48.465614700' -Source '42-54-43-AE-01-19' -Destination 'FF-FF-FF-FF-FF-FF' -Component 31
            Get-PktmonLine -Time '13:08:48.465657800' -Source '42-54-43-AE-01-19' -Destination 'FF-FF-FF-FF-FF-FF' -Component 597 -Drop
            Get-PktmonLine -Time '13:08:52.100000000' -Source '42-54-43-AE-01-19' -Destination 'FF-FF-FF-FF-FF-FF' -Component 8
            Get-PktmonLine -Time '13:08:52.300000000' -Source '00-15-5D-01-02-03' -Destination '42-54-43-AE-01-19' -Component 8
            Get-PktmonLine -Time '13:09:10.000000000' -Source '38-05-25-3A-94-BA' -Destination 'FF-FF-FF-FF-FF-FF' -Component 8
            Get-PktmonLine -Time '13:09:10.000010000' -Source '38-05-25-3A-94-BA' -Destination 'FF-FF-FF-FF-FF-FF' -Component 31
            Get-PktmonLine -Time '13:12:01.500000000' -Source '42-54-43-AE-01-19' -Destination 'FF-FF-FF-FF-FF-FF' -Component 8 -Payload $script:ArpPayload
            Get-PktmonLine -Time '13:12:01.500020000' -Source '42-54-43-AE-01-19' -Destination 'FF-FF-FF-FF-FF-FF' -Component 31 -Payload $script:ArpPayload
            Get-PktmonLine -Time '13:12:03.000000000' -Source '42-54-43-AE-01-19' -Destination '00-15-5D-01-02-03' -Component 8 -Payload $script:IcmpRequestPayload
            Get-PktmonLine -Time '13:12:03.000500000' -Source '00-15-5D-01-02-03' -Destination '42-54-43-AE-01-19' -Component 8 -Payload $script:IcmpReplyPayload
        )
        $script:PktmonPath = Join-Path $TestDrive 'dhcp.capture.txt'
        [IO.File]::WriteAllLines($script:PktmonPath, [string[]]$lines, [Text.UnicodeEncoding]::new($false, $true))
    }

    It 'counts packets, not the lines pktmon writes for every component they cross' {
        $summary = Get-DhcpCaptureSummary -Path $script:PktmonPath -GuestMac '42:54:43:AE:01:19'
        $summary.sentByGuest | Should -Be 2 -Because 'one DISCOVER seen at three components, then a retransmit seconds later; the guest''s ARP and ICMP are not DHCP'
        $summary.unicastToGuest | Should -Be 1 -Because 'the ICMP echo reply to the guest is not a DHCP reply'
        $summary.fromOtherClients | Should -Be 1
        $summary.otherClients | Should -Be 1
    }

    It 'counts the guest''s ARP and ICMP apart from DHCP and keeps the moment it was last heard' {
        $summary = Get-DhcpCaptureSummary -Path $script:PktmonPath -GuestMac '42:54:43:AE:01:19'
        $summary.guestArp | Should -Be 1 -Because 'one ARP request seen at two components is one frame'
        $summary.guestIcmp | Should -Be 1
        $summary.lastGuestFrameAt | Should -Be '2026-10-06 13:12:03.000000000' -Because 'the newest frame from the guest MAC, in the capture''s own local-time form'
    }

    It 'reads a guest that never transmitted as zero beside a live capture' {
        $summary = Get-DhcpCaptureSummary -Path $script:PktmonPath -GuestMac '42-54-43-00-00-01'
        $summary.sentByGuest | Should -Be 0
        $summary.guestArp | Should -Be 0
        $summary.guestIcmp | Should -Be 0
        $summary.lastGuestFrameAt | Should -BeNullOrEmpty -Because 'a guest never heard has no last-heard moment'
        $summary.fromOtherClients | Should -BeGreaterThan 0 -Because 'zero from the guest means something only beside traffic that proves the capture was live'
    }

    It 'lands the summary beside the capture and prints it with the failure evidence' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Save-VMDhcpCapture'
        $fn | Should -Match 'Get-DhcpCaptureSummary' -Because 'the five-megabyte text is the evidence; the one line is what a reader looks at first'
        $fn | Should -Match 'dhcp\.capture\.summary\.json'
        foreach ($field in 'guestArp', 'guestIcmp', 'lastGuestFrameAt') {
            $fn | Should -Match $field -Because "dhcp.capture.info.txt must mention $field so the reader knows the summary carries it"
        }
        $script:RunnerText | Should -Match 'dhcp\.capture\.summary\.json' -Because 'the runner states the result in the cycle log'
    }
}

Describe 'hyper-v serial console capture: the guest-side record of a silence' {
    BeforeAll {
        $script:NewVmText = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $script:DriverPath) 'New-UbuntuServerVM.ps1')
        $script:OverlayText = Get-Content -Raw -LiteralPath (Join-Path (Split-Path -Parent $PSCommandPath) '../../host/vmconfig/ubuntu.server.hyperv.overlay.yml')
    }
    It 'gives the guest a COM1 named pipe at creation, without making the pipe a precondition' {
        $script:NewVmText | Should -Match "'Hyper-V\\Set-VMComPort' -Parameter @\{ VMName = \`$VMName; Number = 1; Path ="
        $script:NewVmText | Should -Match 'pipe\\yuruna-serial-\$VMName' -Because 'the reader connects to the pipe by this name'
        $script:NewVmText | Should -Match "'Hyper-V\\Set-VMComPort'[^\r\n]*-Optional" -Because 'a platform without COM ports must still create the VM'
    }
    It 'arms the reader beside the DHCP capture, gated on the start succeeding' {
        $fn = [regex]::Match($script:DriverText, '(?s)function Start-VM \{.*?\n\}').Value
        $fn | Should -Match 'Start-VMSerialCapture'
        $fn | Should -Match '\.success'
    }
    It 'reads the pipe in its own process so a blocked reader can never stall the cycle' {
        $fn = [regex]::Match($script:DriverText, '(?s)function Start-VMSerialCapture \{.*?\n\}').Value
        $fn | Should -Match 'Start-Job'
        $fn | Should -Match 'NamedPipeClientStream'
        $fn | Should -Match '\$using:pipeName'
    }
    It 'saves the log with the failure and says when nothing was received' {
        $fn = [regex]::Match($script:DriverText, '(?s)function Save-VMSerialCapture \{.*?\n\}').Value
        $fn | Should -Match 'serial-console\.log'
        $fn | Should -Match 'serial-console\.info\.txt' -Because 'an empty capture and a capture that never ran must stay distinguishable'
        $script:RunnerText | Should -Match 'Save-VMSerialCapture'
    }
    It 'discards the reader on the clean teardown' {
        $fn = [regex]::Match($script:DriverText, '(?s)function Remove-VM \{.*?\n\}').Value
        $fn | Should -Match 'Stop-VMSerialCapture -VMName \$VMName' -Because 'the record of the reader does not survive a driver re-import; its job name does'
    }
    It 'stops the reader of an earlier driver instance before arming another' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Start-VMSerialCapture'
        $fn | Should -Match 'Stop-VMSerialCapture -VMName \$VMName'
        $fn | Should -Match 'Start-Job -Name \$pipeName' -Because 'the job carries the name every path finds it by'
    }
    It 'has the guest write to the port: journald forwards every level and the kernel adds a serial console' {
        $script:OverlayText | Should -Match '70-yuruna-serial\.conf'
        $script:OverlayText | Should -Match 'ForwardToConsole=yes'
        $script:OverlayText | Should -Match 'TTYPath=/dev/\$tty' -Because 'the device is chosen per architecture inside the installer, not pinned'
        $script:OverlayText | Should -Match 'console=%s,115200n8 console=tty0' -Because 'tty0 must stay last so the framebuffer the OCR reads remains the primary console'
        $script:OverlayText | Should -Not -Match 'console=tty0 console='
    }
    It 'picks the UART the platform has: ttyAMA0 on ARM64, ttyS0 elsewhere' {
        @([regex]::Matches($script:OverlayText, '(?m)^\s*tty=ttyS0; \[ "\$\(uname -m\)" = aarch64 \] && tty=ttyAMA0\s*$')).Count |
            Should -Be 2 -Because 'the journald drop-in and the grub drop-in each name the device'
        $script:OverlayText | Should -Not -Match 'TTYPath=/dev/ttyS0' -Because 'a pinned ttyS0 leaves an ARM64 guest with a host reader at 0 bytes'
        $script:OverlayText | Should -Not -Match 'console=ttyS0'
        $script:OverlayText | Should -Match '(?m)^\s*cat > /target/etc/systemd/journald\.conf\.d/70-yuruna-serial\.conf << EOF\s*$' -Because 'a quoted heredoc delimiter would keep $tty literal'
        $script:OverlayText | Should -Match 'printf ''GRUB_CMDLINE_LINUX_DEFAULT="\$\{GRUB_CMDLINE_LINUX_DEFAULT\} console=%s' -Because 'GRUB expands that variable at boot; the installer shell must leave it alone'
    }
    It 'marks the installer lease critical so the installed netplan keeps the address against the clock' {
        $section = [regex]::Match($script:OverlayText, '(?ms)^# === YURUNA_OVERLAY_NETWORK ===\s*$(.*?)^# === YURUNA_OVERLAY_').Groups[1].Value
        @([regex]::Matches($section, '(?m)^\s*dhcp-identifier: mac\s*\n\s*#[^\n]*KeepConfiguration[^\n]*\n\s*critical: true\s*$')).Count |
            Should -Be 2 -Because 'both interface families carry the pin, each with the one-line why beside it'
    }
}

Describe 'hyper-v serial console capture: the reader records its own state' {
    BeforeAll {
        $ast = [Management.Automation.Language.Parser]::ParseInput($script:DriverText, [ref]$null, [ref]$null)
        $start = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Start-VMSerialCapture' }, $true)
        $script:SerialJobText = $start.Find({ param($node) $node -is [Management.Automation.Language.ScriptBlockExpressionAst] -and
                $node.Parent -is [Management.Automation.Language.CommandAst] -and $node.Parent.GetCommandName() -eq 'Start-Job' }, $true).Extent.Text
    }
    It 'keeps a connection-state sidecar the job rewrites at each change of state' {
        foreach ($field in 'connectAttempts', 'connectedCount', 'lastConnectUtc', 'lastError', 'bytesRead', 'earlierBytes') {
            $script:SerialJobText | Should -Match $field -Because 'serial-console.info.txt reports it'
        }
        # The one moment the earlier reader's share is exact: the log is open and
        # this reader's own count is current.
        $script:SerialJobText | Should -Match '\$state\.earlierBytes = \[math\]::Max\(0L, \$file\.Length - \$state\.bytesRead\)'
        $script:SerialJobText | Should -Match '\$using:statePath'
        $script:SerialJobText | Should -Match 'ConvertTo-Json'
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Start-VMSerialCapture'
        $fn | Should -Match 'StatePath = \$statePath' -Because 'the saver finds the sidecar through the capture record'
    }
    It 'keeps the job free of module calls' {
        foreach ($token in 'Yuruna', 'Format-', 'Get-VM', 'Write-Verbose', 'Import-Module', 'Test.Ssh') {
            $script:SerialJobText | Should -Not -Match ([regex]::Escape($token)) -Because 'the job outlives module reloads and runs with nothing but .NET and the shell'
        }
    }
    It 'tells a reader that never connected from a guest that wrote nothing' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Save-VMSerialCapture'
        $fn | Should -Match '"connects: \$connects"'
        $fn | Should -Match '"attempts: \$attempts"'
        $fn | Should -Match '"lastError: \$lastError"'
        $fn | Should -Match 'never connected points at the pipe'
        $fn | Should -Match 'console= setting'
        $fn | Should -Match 'serial-console\.reader\.json' -Because 'the raw sidecar travels with the summary'
        $fn | Should -Match 'serial-console\.info\.txt'
    }
    It 'discards the sidecar with the log on the clean teardown' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Stop-VMSerialCapture'
        $fn | Should -Match 'StatePath'
    }
}

Describe 'hyper-v serial console capture: the live log is read without disturbing its reader' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'Test.Assert.psm1') -Force -DisableNameChecking
        $ast = [Management.Automation.Language.Parser]::ParseInput($script:DriverText, [ref]$null, [ref]$null)
        foreach ($name in 'Read-VMSerialCapture', 'Save-VMSerialCapture', 'Stop-VMSerialCapture', 'Get-VMSerialPipeName',
            'Get-VMSerialCaptureJob', 'Get-VMSerialCaptureRecord', 'Stop-VMSerialCaptureJob') {
            $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        $script:PriorTemp = Save-YurunaTestEnvironment -Name 'TEMP'
        $env:TEMP = Join-Path $TestDrive 'temp'
        $null = New-Item -ItemType Directory -Path $env:TEMP -Force
        $script:LivePath = Join-Path $env:TEMP 'yuruna-serial-vm-live.log'
    }
    AfterAll {
        Restore-YurunaTestEnvironment -Saved $script:PriorTemp
    }
    It 'is exported beside the other capture verbs, so the engine finds it by feature detection' {
        $script:DriverText | Should -Match 'Export-ModuleMember[\s\S]*Read-VMSerialCapture'
    }
    It 'reads what a writer still holding the file appended after an offset, and only the length when asked' {
        $writer = [IO.FileStream]::new($script:LivePath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes("[    1.000000] first`n[    2.000000] second`n")
            $writer.Write($bytes, 0, $bytes.Length)
            $writer.Flush()
            $mark = Read-VMSerialCapture -VMName 'vm-live' -MaxBytes 0
            $mark.Length | Should -Be $bytes.Length
            $mark.Text | Should -Be ''
            $more = [Text.Encoding]::UTF8.GetBytes("[    3.000000] third`n")
            $writer.Write($more, 0, $more.Length)
            $writer.Flush()
            $read = Read-VMSerialCapture -VMName 'vm-live' -FromOffset $mark.Length
            $read.Text | Should -Be "[    3.000000] third`n"
            $read.Offset | Should -Be $mark.Length
            $read.Truncated | Should -BeFalse
        } finally { $writer.Dispose() }
    }
    It 'keeps the newest bytes when more arrived than it may read' {
        Set-Content -LiteralPath (Join-Path $env:TEMP 'yuruna-serial-vm-big.log') -Value ('a' * 100 + 'NEWEST') -NoNewline
        $read = Read-VMSerialCapture -VMName 'vm-big' -FromOffset 0 -MaxBytes 6
        $read.Text | Should -Be 'NEWEST'
        $read.Truncated | Should -BeTrue
    }
    It 'reads a file replaced after the offset was taken from its start and says so, and answers $null without one' {
        Set-Content -LiteralPath (Join-Path $env:TEMP 'yuruna-serial-vm-new.log') -Value 'fresh' -NoNewline
        $read = Read-VMSerialCapture -VMName 'vm-new' -FromOffset 5000
        $read.Text | Should -Be 'fresh'
        $read.Replaced | Should -BeTrue
        (Read-VMSerialCapture -VMName 'vm-new' -FromOffset 2).Replaced | Should -BeFalse
        Read-VMSerialCapture -VMName 'vm-absent' | Should -BeNullOrEmpty
    }
    It 'marks a capture whose reader has not created the file yet at zero' {
        $mark = Read-VMSerialCapture -VMName 'vm-not-yet' -MaxBytes 0
        $mark.Length | Should -Be 0 -Because 'everything the file will hold is written after the mark'
        Read-VMSerialCapture -VMName 'vm-not-yet' -FromOffset 0 | Should -BeNullOrEmpty
    }
    It 'says when an earlier reader wrote the bytes this reader never read' {
        $log = Join-Path $env:TEMP 'yuruna-serial-vm-orphan.log'
        $state = Join-Path $env:TEMP 'yuruna-serial-vm-orphan.state.json'
        Set-Content -LiteralPath $log -Value ('x' * 5000) -NoNewline
        Set-Content -LiteralPath $state -Value '{"connectAttempts":986,"connectedCount":0,"bytesRead":0,"lastError":"TimeoutException: The operation has timed out."}'
        $script:YurunaSerialCapture = @{ VMName = 'vm-orphan'; Job = $null; LogPath = $log; StatePath = $state; PipeName = 'yuruna-serial-vm-orphan' }
        $out = Join-Path $TestDrive 'orphan-out'
        Save-VMSerialCapture -VMName 'vm-orphan' -OutputDirectory $out | Should -BeTrue
        $info = Get-Content -Raw -LiteralPath (Join-Path $out 'serial-console.info.txt')
        $info | Should -Match '(?m)^earlier:  5000 of the 5000 bytes were appended by a reader armed before this one;'
        $info | Should -Match 'console log level' -Because 'the console carries kernel messages at its level only'
        $info | Should -Not -Match 'kernel messages at every level'
    }
    It 'reads the earlier reader''s share from a sidecar shaped like the job''s: <Case>' -ForEach @(
        # Still connected: the job last saved bytesRead after its first chunk.
        @{ Case = 'this reader holds the pipe'; Sidecar = '{"connectAttempts":1,"connectedCount":1,"bytesRead":95,"earlierBytes":0,"lastConnectUtc":"2026-10-28T03:49:15Z","lastDisconnectUtc":null}'; Expected = $null }
        @{ Case = 'an earlier reader wrote before this one connected'; Sidecar = '{"connectAttempts":956,"connectedCount":1,"bytesRead":0,"earlierBytes":4905,"lastConnectUtc":"2026-10-28T04:38:57Z","lastDisconnectUtc":null}'; Expected = 4905 }
        # Disconnected: the disconnect save made bytesRead exact.
        @{ Case = 'this reader lost the pipe to an earlier one'; Sidecar = '{"connectAttempts":40,"connectedCount":1,"bytesRead":3000,"earlierBytes":0,"lastConnectUtc":"2026-10-28T03:49:15Z","lastDisconnectUtc":"2026-10-28T04:01:00Z"}'; Expected = 2000 }
    ) {
        $name = 'vm-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $log = Join-Path $env:TEMP "yuruna-serial-$name.log"
        $state = Join-Path $env:TEMP "yuruna-serial-$name.state.json"
        Set-Content -LiteralPath $log -Value ('y' * 5000) -NoNewline
        Set-Content -LiteralPath $state -Value $Sidecar
        $script:YurunaSerialCapture = @{ VMName = $name; Job = $null; LogPath = $log; StatePath = $state; PipeName = "yuruna-serial-$name" }
        $out = Join-Path $TestDrive "$name-out"
        Save-VMSerialCapture -VMName $name -OutputDirectory $out | Should -BeTrue
        $info = Get-Content -Raw -LiteralPath (Join-Path $out 'serial-console.info.txt')
        if ($null -eq $Expected) { $info | Should -Not -Match '(?m)^earlier:' }
        else { $info | Should -Match "(?m)^earlier:  $Expected of the 5000 bytes" }
    }
    # The reader is a job named for its VM. Initialize-YurunaHost re-imports the
    # driver with -Force when the sequence engine loads, between the runner's
    # Start-VM phase and a sequence's own startVm, and the module's record of
    # the reader does not survive that. Its job does, holding the pipe and the
    # log, so the <Path> path has to find it by name.
    It 'finds the reader an earlier driver instance armed by its job name: <Path>' -ForEach @(
        @{ Path = 'save' }
        @{ Path = 'stop' }
    ) {
        $name = 'vm-reimport-' + $Path
        $log = Join-Path $env:TEMP "yuruna-serial-$name.log"
        $state = Join-Path $env:TEMP "yuruna-serial-$name.state.json"
        Set-Content -LiteralPath $log -Value ('z' * 300) -NoNewline
        Set-Content -LiteralPath $state -Value '{"connectAttempts":1,"connectedCount":1,"bytesRead":300,"earlierBytes":0,"lastConnectUtc":"2026-10-29T17:25:40Z","lastDisconnectUtc":null}'
        $job = Start-Job -Name "yuruna-serial-$name" -ScriptBlock { Start-Sleep -Seconds 600 }
        try {
            $script:YurunaSerialCapture = $null
            if ($Path -eq 'save') {
                $out = Join-Path $TestDrive "$name-out"
                Save-VMSerialCapture -VMName $name -OutputDirectory $out | Should -BeTrue -Because 'the reader is found by its job name when the record is gone'
                Get-Content -Raw -LiteralPath (Join-Path $out 'serial-console.log') | Should -Be ('z' * 300)
                Get-Content -Raw -LiteralPath (Join-Path $out 'serial-console.info.txt') | Should -Match '(?m)^connects: 1$'
            } else {
                Stop-VMSerialCapture -VMName $name | Should -BeTrue
            }
            @(Get-Job | Where-Object { $_.Name -eq "yuruna-serial-$name" }).Count | Should -Be 0 -Because 'a stopped reader no longer holds the pipe or the log'
            Test-Path -LiteralPath $log | Should -BeFalse
            Test-Path -LiteralPath $state | Should -BeFalse
        } finally {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
    It 'leaves another VM''s recorded reader alone when stopping by name' {
        $script:YurunaSerialCapture = @{ VMName = 'vm-other'; Job = $null; LogPath = (Join-Path $env:TEMP 'yuruna-serial-vm-other.log'); StatePath = $null; PipeName = 'yuruna-serial-vm-other' }
        Stop-VMSerialCapture -VMName 'vm-absent' | Should -BeTrue
        $script:YurunaSerialCapture.VMName | Should -Be 'vm-other'
    }
}

Describe 'hyper-v VM creation time: how long any boot of the VM can have run' {
    BeforeAll {
        $ast = [Management.Automation.Language.Parser]::ParseInput($script:DriverText, [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-VMCreationTime' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        # The driver's presence decision, scripted per example.
        function Resolve-HyperVVM {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Stub: the signature has to match the driver helper so the caller binds.')]
            param([string]$VMName)
            if ($script:ResolvedVM -eq 'throw') { throw 'VMMS unreachable' }
            return $script:ResolvedVM
        }
    }
    It 'is exported beside the capture verbs, so the engine finds it by feature detection' {
        $script:DriverText | Should -Match 'Export-ModuleMember[\s\S]*Get-VMCreationTime'
    }
    It 'answers a present VM''s creation time in UTC' {
        $local = [DateTime]::new(2026, 10, 28, 10, 40, 5, [DateTimeKind]::Local)
        $script:ResolvedVM = [pscustomobject]@{ Presence = 'present'; VM = [pscustomobject]@{ CreationTime = $local }; Cause = 'ok' }
        $created = Get-VMCreationTime -VMName 'vm-01'
        $created.Kind | Should -Be ([DateTimeKind]::Utc)
        $created | Should -Be $local.ToUniversalTime()
    }
    It 'answers $null when it cannot name this VM''s time: <Case>' -ForEach @(
        @{ Case = 'absent'; Resolved = [pscustomobject]@{ Presence = 'absent'; VM = $null; Cause = 'ok' } }
        @{ Case = 'a duplicate name'; Resolved = [pscustomobject]@{ Presence = 'unknown'; VM = $null; Cause = 'ambiguous' } }
        @{ Case = 'no creation time'; Resolved = [pscustomobject]@{ Presence = 'present'; VM = [pscustomobject]@{ CreationTime = $null }; Cause = 'ok' } }
        @{ Case = 'an unset creation time'; Resolved = [pscustomobject]@{ Presence = 'present'; VM = [pscustomobject]@{ CreationTime = [datetime]::MinValue }; Cause = 'ok' } }
        @{ Case = 'an unreadable host'; Resolved = 'throw' }
    ) {
        $script:ResolvedVM = $Resolved
        Get-VMCreationTime -VMName 'vm-01' | Should -BeNullOrEmpty
    }
}

Describe 'hyper-v VM network state: what the host saw lands with the failure' {
    It 'exists, is exported, and lands beside the failure diagnostics by feature detection' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Save-VMNetworkState'
        $fn | Should -Match 'vm-network\.state\.txt'
        $fn | Should -Match 'vm-network\.state\.json'
        $script:DriverText | Should -Match 'Export-ModuleMember[\s\S]*Save-VMNetworkState' -Because 'an unexported verb reads as "driver does not implement it"'
        $script:RunnerText | Should -Match 'Get-Command Save-VMNetworkState' -Because 'most host drivers do not implement it'
        $script:RunnerText | Should -Match 'Save-VMNetworkState -VMName \$VMName -OutputDirectory \$destSeqDir'
    }
    It 'reads the adapter, the integration services, the neighbor cache, TCP 22 and a bounded event tail' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Save-VMNetworkState'
        $fn | Should -Match 'Hyper-V\\Get-VM -Name \$VMName'
        $fn | Should -Match 'Hyper-V\\Get-VMNetworkAdapter'
        $fn | Should -Match 'Hyper-V\\Get-VMIntegrationService'
        $fn | Should -Match 'PrimaryStatusDescription'
        $fn | Should -Match 'Get-NetNeighbor'
        $fn | Should -Match 'LinkLayerAddress'
        $fn | Should -Match 'TcpClient'
        $fn | Should -Match 'WaitOne\(2000\)' -Because 'the probe runs inside the failure path; two seconds per address is the budget'
        $fn | Should -Match "Get-WinEvent -ListLog 'Microsoft-Windows-Hyper-V-\*'"
        $fn | Should -Match 'RecordCount -gt 0'
        $fn | Should -Match '-MaxEvents 40'
        $fn | Should -Match 'AddMinutes\(-20\)'
        $fn | Should -Match 'Substring\(0, 300\)'
    }
    It 'never lets a failure escape, in the driver or in the runner' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Save-VMNetworkState'
        $fn | Should -Match '(?ms)\}\s*catch\s*\{'
        $fn | Should -Match 'return \$false'
        $fn | Should -Not -Match '(?m)^\s*throw\b'
        [regex]::Match($script:RunnerText, '(?s)try \{\s*if \(Get-Command Save-VMNetworkState -ErrorAction SilentlyContinue\) \{.*?\} catch \{\s*Write-Verbose').Success |
            Should -BeTrue -Because 'the collection block must soft-fail like its neighbors, never the step'
    }
    It 'writes the text file even when every Hyper-V reading fails' {
        # Standalone by construction: the function uses only Hyper-V cmdlets,
        # Get-NetNeighbor, Get-WinEvent and .NET, each under its own catch, so it
        # can run here where none of the first three exist and must still land.
        $ast = [Management.Automation.Language.Parser]::ParseInput($script:DriverText, [ref]$null, [ref]$null)
        $definition = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-VMNetworkState' }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
        $out = Join-Path $TestDrive 'vm-network-state'
        Save-VMNetworkState -VMName 'yuruna-nonexistent-vm' -OutputDirectory $out | Should -BeTrue
        Test-Path (Join-Path $out 'vm-network.state.txt') | Should -BeTrue
        Test-Path (Join-Path $out 'vm-network.state.json') | Should -BeTrue
        $text = Get-Content -Raw (Join-Path $out 'vm-network.state.txt')
        $text | Should -Match '(?m)^vmName:\s+yuruna-nonexistent-vm'
        $text | Should -Match '(?m)^reading:'
        (Get-Content -Raw (Join-Path $out 'vm-network.state.json') | ConvertFrom-Json).schema | Should -Be 'yuruna.vm-network-state/v1'
    }
}

Describe 'hyper-v VM storage state: whether a checkpoint exists lands with the failure' {
    BeforeAll {
        $ast = [Management.Automation.Language.Parser]::ParseInput($script:DriverText, [ref]$null, [ref]$null)
        $script:StorageFn = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Save-VMStorageState' }, $true)
    }
    It 'exists, is exported, and lands beside the failure diagnostics by feature detection' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Save-VMStorageState'
        $fn | Should -Match 'vm-storage\.state\.txt'
        $fn | Should -Match 'vm-storage\.state\.json'
        $script:DriverText | Should -Match 'Export-ModuleMember[\s\S]*Save-VMStorageState' -Because 'an unexported verb reads as "driver does not implement it"'
        $script:RunnerText | Should -Match 'Get-Command Save-VMStorageState' -Because 'most host drivers do not implement it'
        $script:RunnerText | Should -Match 'Save-VMStorageState -VMName \$VMName -OutputDirectory \$destSeqDir'
    }
    It 'reads Hyper-V in two bounded calls: settings and both checkpoint listings, then the disk chain' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Save-VMStorageState'
        @([regex]::Matches($fn, 'Invoke-HyperVBoundedCall -TimeoutSeconds 60')).Count | Should -Be 2 -Because 'a stalled disk read must not discard the checkpoint readings'
        $fn | Should -Match 'Hyper-V\\Get-VMCheckpoint -VMName \$Name'
        $fn | Should -Match "Msvm_VirtualSystemSettingData -Filter \`$filter"
        $fn | Should -Match "VirtualSystemIdentifier='\{0\}' AND VirtualSystemType LIKE 'Microsoft:Hyper-V:Snapshot:%'"
        $fn | Should -Match 'Hyper-V\\Get-VMHardDiskDrive -VMName \$Name'
        $fn | Should -Match 'Hyper-V\\Get-VHD -Path'
        $fn | Should -Match 'CheckpointType'
        $fn | Should -Match 'SnapshotFileLocation'
        $fn | Should -Match "Get-WinEvent -ListLog 'Microsoft-Windows-Hyper-V-\*', 'Microsoft-Windows-VHDMP\*'"
        $fn | Should -Match 'AddMinutes\(-20\)'
        $fn | Should -Match 'AddMinutes\(-30\)'
    }
    It 'never lets a failure escape, in the driver or in the runner' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Save-VMStorageState'
        $fn | Should -Match '(?ms)\}\s*catch\s*\{'
        $fn | Should -Match 'return \$false'
        $fn | Should -Not -Match '(?m)^\s*throw\b'
        [regex]::Match($script:RunnerText, '(?s)try \{\s*if \(Get-Command Save-VMStorageState -ErrorAction SilentlyContinue\) \{.*?\} catch \{\s*Write-Verbose').Success |
            Should -BeTrue -Because 'the collection block must soft-fail like its neighbors, never the step'
    }
    It 'writes the text file and marks every section not read when the Hyper-V reads <Case>' -ForEach @(
        @{ Case = 'fail'; TimedOut = $false; Expect = 'Get-VMHost: Hyper-V is not installed'; Vm = 'not found' }
        @{ Case = 'do not answer'; TimedOut = $true; Expect = 'no answer within 60 s'; Vm = 'not read' }
    ) {
        # The stand-in answers for Hyper-V without running the reads, so the
        # case is the same on a host where the Hyper-V module is present.
        $script:StorageTimedOut = $TimedOut
        function Invoke-HyperVBoundedCall {
            param([scriptblock]$ScriptBlock, [object[]]$ArgumentList, [int]$TimeoutSeconds)
            $null = $ScriptBlock, $ArgumentList, $TimeoutSeconds
            if ($script:StorageTimedOut) { return @{ TimedOut = $true; Error = $null; Output = @() } }
            @{ TimedOut = $false; Error = $null; Output = @([pscustomobject]@{
                        vhdRoot = ''; vm = $null; checkpoints = $null; records = $null
                        errors = @('Get-VMHost: Hyper-V is not installed', 'Get-VM: Hyper-V is not installed') }) }
        }
        . ([scriptblock]::Create($script:StorageFn.Extent.Text))
        $out = Join-Path $TestDrive "vm-storage-state-$TimedOut"
        Save-VMStorageState -VMName 'yuruna-nonexistent-vm' -OutputDirectory $out | Should -BeTrue
        $text = Get-Content -Raw (Join-Path $out 'vm-storage.state.txt')
        $text | Should -Match '(?m)^vmName:\s+yuruna-nonexistent-vm'
        $text | Should -Match "(?m)^vm:\s+\($Vm\)"
        $text | Should -Match '(?m)^checkpoint: \(not read\)'
        $text | Should -Match '(?m)^record:\s+\(not read\)'
        $text | Should -Match '(?m)^disk:\s+\(not read\)'
        $text | Should -Not -Match '(?m)^(checkpoint|record|disk):\s+\(none' -Because 'a reading that did not happen is not an empty one'
        $text | Should -Match ([regex]::Escape($Expect))
        $text | Should -Match '(?m)^reading:'
        $json = Get-Content -Raw (Join-Path $out 'vm-storage.state.json') | ConvertFrom-Json
        $json.schema | Should -Be 'yuruna.vm-storage-state/v1'
        $null -eq $json.records | Should -BeTrue
        $null -eq $json.disks | Should -BeTrue
    }
    It 'records what Hyper-V holds beside what the module lists, the disk chain and the folders that hold it' {
        $script:StorageRoot = Join-Path $TestDrive 'vhd'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $script:StorageRoot 'amisad-build/Virtual Hard Disks')
        Set-Content -LiteralPath (Join-Path $script:StorageRoot 'amisad-build/Virtual Hard Disks/test-guest_6F1C.avhdx') -Value 'diff'
        Set-Content -LiteralPath (Join-Path $script:StorageRoot 'amisad-build/Virtual Hard Disks/test-guest.vhdx') -Value 'base'
        function Invoke-HyperVBoundedCall {
            param([scriptblock]$ScriptBlock, [object[]]$ArgumentList, [int]$TimeoutSeconds)
            $null = $ArgumentList, $TimeoutSeconds
            $disks = Join-Path $script:StorageRoot 'amisad-build/Virtual Hard Disks'
            if ($ScriptBlock.ToString() -match 'Get-VMHardDiskDrive') {
                return @{ TimedOut = $false; Error = $null; Output = @(
                        [ordered]@{ path = (Join-Path $disks 'test-guest_6F1C.avhdx'); parentPath = (Join-Path $disks 'test-guest.vhdx'); type = 'Differencing'; fileSize = 4 }) }
            }
            @{ TimedOut = $false; Error = $null; Output = @([pscustomobject]@{
                        vhdRoot = $script:StorageRoot
                        vm = [ordered]@{ id = '1BE1D34C-5633-449F-AAA9-C4E7190CB91B'; state = 'Off'; checkpointType = 'Production'; parentCheckpointName = 'amisad-build'
                            path = $disks; configurationLocation = $disks; snapshotFileLocation = $disks }
                        checkpoints = @()
                        records = @([ordered]@{ name = 'amisad-build'; type = 'Microsoft:Hyper-V:Snapshot:Realized'; created = '20261027191643.000000-240' })
                        errors = @()
                    }) }
        }
        . ([scriptblock]::Create($script:StorageFn.Extent.Text))
        $out = Join-Path $TestDrive 'vm-storage-state-held'
        Save-VMStorageState -VMName 'amisad-build' -OutputDirectory $out | Should -BeTrue
        $text = Get-Content -Raw (Join-Path $out 'vm-storage.state.txt')
        $text | Should -Match '(?m)^checkpoint: \(none listed by the Hyper-V module\)'
        $text | Should -Match '(?m)^record:\s+amisad-build type=Microsoft:Hyper-V:Snapshot:Realized'
        $text | Should -Match '(?m)^disk:\s+.*test-guest_6F1C\.avhdx type=Differencing parent=.*test-guest\.vhdx'
        $text | Should -Match '(?m)^folder:\s+.*Virtual Hard Disks \(2 file\(s\)\)'
        $text | Should -Match '(?m)^\s+test-guest_6F1C\.avhdx '
        $json = Get-Content -Raw (Join-Path $out 'vm-storage.state.json') | ConvertFrom-Json
        $json.records[0].name | Should -Be 'amisad-build'
        $json.vm.parentCheckpointName | Should -Be 'amisad-build'
        @($json.checkpoints).Count | Should -Be 0
    }
    It 'keeps the checkpoint readings when only the disk-chain read does not answer' {
        function Invoke-HyperVBoundedCall {
            param([scriptblock]$ScriptBlock, [object[]]$ArgumentList, [int]$TimeoutSeconds)
            $null = $ArgumentList, $TimeoutSeconds
            if ($ScriptBlock.ToString() -match 'Get-VMHardDiskDrive') { return @{ TimedOut = $true; Error = $null; Output = @() } }
            @{ TimedOut = $false; Error = $null; Output = @([pscustomobject]@{
                        vhdRoot = ''; vm = [ordered]@{ id = '1BE1D34C-5633-449F-AAA9-C4E7190CB91B'; state = 'Off'; checkpointType = 'Production'; parentCheckpointName = ''
                            path = ''; configurationLocation = ''; snapshotFileLocation = '' }
                        checkpoints = @([ordered]@{ name = 'amisad-build'; id = '6F1C'; type = 'Standard'; created = ''; parent = '' })
                        records = @(); errors = @() }) }
        }
        . ([scriptblock]::Create($script:StorageFn.Extent.Text))
        $out = Join-Path $TestDrive 'vm-storage-state-disks'
        Save-VMStorageState -VMName 'amisad-build' -OutputDirectory $out | Should -BeTrue
        $text = Get-Content -Raw (Join-Path $out 'vm-storage.state.txt')
        $text | Should -Match '(?m)^checkpoint: amisad-build id=6F1C'
        $text | Should -Match '(?m)^disk:\s+\(not read\)'
        $text | Should -Match 'Hyper-V disk chain: no answer within 60 s'
    }
}
