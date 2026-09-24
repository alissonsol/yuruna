<#PSScriptInfo
.VERSION 2026.09.24
.GUID 429cf70d-40bb-4de7-a305-1a10d263253b
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test dhcp capture dnsmasq libvirt kvm pester
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
# Pester supplies Describe/It/Should here. Without it every one of those calls
# raises CommandNotFoundException, the engine keeps going, and the file reaches
# its end and exits 0 -- so a harness that shells this out records a PASS for a
# suite that executed no assertion at all.
if (-not (Get-Command -Name Describe -ErrorAction SilentlyContinue)) {
    Write-Error ("Pester is not available, so this suite cannot run. Install it with " +
                 "'Install-Module Pester -Scope CurrentUser', then re-run with " +
                 "Invoke-Pester -Path '$PSCommandPath'.")
    exit 1
}

<#
.SYNOPSIS
    A guest whose lease never came leaves the server's side of the story in its
    failure folder, and the capture that records it can never become a fault of
    its own.
.DESCRIPTION
    WHY THIS EXISTS. The guest-side diagnostic bottoms out at "no lease". It
    cannot see whether the DISCOVER was ever sent, and the two answers indict
    different machines. Here libvirt runs the dnsmasq that answers, so the
    server's half is already in the journal -- what decides whether it is
    READABLE afterwards is a set of properties that each fail silently:

      * The window opens at the start, and at an instant. A guest's first
        DISCOVER lands seconds after firmware, so a window opened by any later
        hook misses the first ask; and a window expressed as a duration drifts
        with how long the failing step took, so it either misses that ask or
        drags in the previous guest's.
      * Nothing elevates to capture. A root packet capture started by the
        runner could not be stopped by it afterwards, and a passwordless grant
        for a program that writes files and runs commands as root buys evidence
        at a price the evidence is not worth.
      * Collected where the failure diagnostics are, by feature detection, and
        discarded with the guest -- ownership-scoped, because the cycle-start
        sweep removes leftover VMs by prefix and an unowned discard there would
        throw away the window of the guest actually under test.

    Mostly static assertions over the driver, because the thing under test is
    what a FAILING cycle is built to leave behind and there is no failing cycle
    to run. The behavioral cases drive the module with libvirt output fed
    through mocks, so they need no VM, no libvirt and no root.
    Run: Invoke-Pester -Path test/modules/Test.KvmDhcpCapture.Tests.ps1
#>

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))
    $script:DriverPath = Join-Path $script:RepoRoot 'host/ubuntu.kvm/modules/Yuruna.Host.psm1'
    $script:RunnerPath = Join-Path $script:RepoRoot 'test/modules/Test.RunnerInnerLoop.psm1'
    $script:DriverText = Get-Content -Raw -LiteralPath $script:DriverPath
    $script:RunnerText = Get-Content -Raw -LiteralPath $script:RunnerPath

    # Function bodies close at column 0 in this module, so the first column-0
    # brace after the header is the function's end.
    function Get-PsFunctionText {
        param([string]$Source, [string]$Name)
        $m = [regex]::Match($Source, "(?ms)^function $([regex]::Escape($Name)) \{.*?^\}")
        if (-not $m.Success) { throw "function $Name not found" }
        return $m.Value
    }

    # macos.utm, ubuntu.kvm and windows.hyper-v each publish a module named
    # 'Yuruna.Host'. The suite shares one runspace, so a driver left resident by
    # another file makes `Get-Module Yuruna.Host` return an array -- which binds
    # to nothing and leaves Pester's -ModuleName ambiguous.
    Get-Module -Name 'Yuruna.Host' -All | Remove-Module -Force -ErrorAction SilentlyContinue
    Import-Module $script:DriverPath -Force -DisableNameChecking -Global
    $script:Driver = Get-Module Yuruna.Host
}

Describe 'kvm DHCP evidence: armed at the only moment that sees the first ask' {

    It 'arms inside Start-VM, after the start actually succeeded' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Start-VM'
        $fn | Should -Match 'Start-VMDhcpCapture' -Because 'no later hook runs before the guest first asks for a lease'
        $armAt   = $fn.IndexOf('Start-VMDhcpCapture')
        $startAt = $fn.IndexOf("Invoke-Virsh -VirshArgs @('start'")
        ($startAt -ge 0 -and $armAt -gt $startAt) | Should -BeTrue -Because 'a window for a domain that failed to start describes nothing'
    }

    It 'does not arm on the already-running path' {
        # That transaction is already in the past. A window opened after it
        # shows an empty slice for a guest that did ask, which reads as the
        # opposite of what happened.
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Start-VM'
        $alreadyAt = $fn.IndexOf('alreadyRunning')
        $armAt     = $fn.IndexOf('Start-VMDhcpCapture')
        ($alreadyAt -ge 0 -and $armAt -gt $alreadyAt) | Should -BeTrue -Because 'the early return must not carry an arm with it'
    }

    It 'leaves the imported guest shut off for Start-VM to boot' {
        # The cases above describe a window Start-VM opens on a domain it
        # started itself. A builder that boots the domain sends every cycle
        # through the already-running return instead, and the window it needs
        # is then only as early as New-VM's fallback arm below.
        $builder = Get-Content -Raw -LiteralPath `
            (Join-Path $script:RepoRoot 'host/ubuntu.kvm/guest.amazon.linux.2023/New-VM.ps1')
        $builder | Should -Match "'--import'" -Because 'the cloud image is bootable, so there is no install phase'
        $builder | Should -Match "'--noreboot'" -Because 'virt-install boots an --import domain unless told not to, which puts the first DISCOVER past any window Start-VM could open'
    }

    It 'arms from New-VM for a builder that booted the domain itself' {
        # Not every builder can be made to define without booting: an ISO
        # install boots to run the installer, and --noreboot governs only the
        # reboot AFTER an install phase, so it leaves a --cdrom domain running.
        # Those guests would otherwise reach Start-VM already running and never
        # be armed at all, which surfaces only as a missing artifact on the one
        # failure that needed it.
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'New-VM'
        $fn | Should -Match 'Start-VMDhcpCapture' -Because 'a builder that boots the domain leaves no later hook before the first ask'
        $fn | Should -Match "Get-VirshDomState -VMName \`$VMName\) -eq 'running'" `
            -Because 'a builder that left the domain shut off must be armed by Start-VM instead, which is earlier'
        $createAt = $fn.IndexOf('Invoke-PerGuestNewVm')
        $armAt    = $fn.IndexOf('Start-VMDhcpCapture')
        ($createAt -ge 0 -and $armAt -gt $createAt) | Should -BeTrue -Because 'a window for a domain that was never created describes nothing'
    }

    It 'arms from New-VM only for a domain the builder actually left running' -ForEach @(
        @{ Created = $true;  State = 'running';  Times = 1; Case = 'builder booted it' }
        @{ Created = $true;  State = 'shut off'; Times = 0; Case = 'builder left it defined' }
        @{ Created = $false; State = 'running';  Times = 0; Case = 'create failed' }
    ) {
        # The shape assertions above cannot tell the guard from its inverse, and
        # an inverted guard arms exactly the guests Start-VM already covers while
        # leaving the ones that need it unarmed.
        Mock -ModuleName 'Yuruna.Host' Invoke-PerGuestNewVm { @{ success = $Created; errorMessage = $null } }
        Mock -ModuleName 'Yuruna.Host' Get-VirshDomState { $State }
        Mock -ModuleName 'Yuruna.Host' Start-VMDhcpCapture { $true }
        $r = Yuruna.Host\New-VM -GuestKey 'guest.test' -RepoRoot '/tmp' -VMName 'test-vm-01' -Confirm:$false
        $r.success | Should -Be $Created -Because 'the create result must pass through the arm untouched'
        Should -Invoke -ModuleName 'Yuruna.Host' Start-VMDhcpCapture -Times $Times -Exactly -Because $Case
    }

    It 'opens the window at an instant, not at a duration' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Get-YurunaDnsmasqJournal'
        $fn | Should -Match "'--since', ""@\`$SinceEpochSecond""" -Because 'a relative window drifts with how long the failing step took'
    }

    It 'never elevates to capture packets' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Start-VMDhcpCapture'
        $fn | Should -Not -Match '(?m)sudo' -Because 'a root capture the runner cannot stop outlives the cycle that started it'
        $script:DriverText | Should -Match 'setcap cap_net_raw' -Because 'the reader must be told how to turn the wire capture on'
    }

    It 'bounds the capture without renaming its own output' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Start-VMDhcpCapture'
        $fn | Should -Match "'-c', '500'" -Because 'a capture nothing stops must still be bounded'
        # -cmatch, not Should -Match: the case-insensitive form cannot tell the
        # size-rotation flag from the packet-count one, and they are opposites.
        ($fn -cmatch "'-C'") | Should -BeFalse -Because 'a size-rotated capture appends a suffix, so the path saved afterwards is not the path written'
    }

    It 'drops the previous guest window before opening its own' {
        # A start that inherited a live capture would leave the previous guest's
        # tcpdump running against a bridge nobody collects from.
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Start-VMDhcpCapture'
        $stopAt  = $fn.IndexOf('Stop-VMDhcpCapture')
        $armAt   = $fn.IndexOf('$script:YurunaDhcpCapture = $capture')
        ($stopAt -ge 0 -and $armAt -gt $stopAt) | Should -BeTrue -Because 'only one window may be open at a time'
    }

    It 'reports a capture that never started instead of believing it is running' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Start-VMDhcpCapture'
        $fn | Should -Match 'HasExited' -Because 'tcpdump refuses and exits at once; the arm has to notice'
        $fn | Should -Match 'WireNote' -Because 'the reason has to reach the artifact, not just a verbose stream'
    }
}

Describe 'kvm DHCP evidence: collected with the failure, discarded with the guest' {

    It 'lands beside the failure diagnostics, by feature detection' {
        $script:RunnerText | Should -Match 'Get-Command Save-VMDhcpCapture' -Because 'not every host driver implements the capture'
        $script:RunnerText | Should -Match 'Save-VMDhcpCapture -VMName \$VMName -OutputDirectory \$destSeqDir' -Because 'the server-side evidence must sit next to the diagnostics that point at it'
    }

    It 'writes the file name the runner announces' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Save-VMDhcpCapture'
        $fn | Should -Match "'dhcp\.capture\.txt'" -Because 'the runner prints that path; a different name is a link to nothing'
    }

    It 'discards at Remove-VM only a window the removed VM owns' {
        $fn = Get-PsFunctionText -Source $script:DriverText -Name 'Remove-VM'
        $fn | Should -Match 'Stop-VMDhcpCapture' -Because 'the no-failure teardown must not leak a running capture'
        $fn | Should -Match '\.VMName -eq \$VMName' -Because 'the cycle-start sweep removes leftover VMs; an unowned discard kills the window of the guest under test'
    }

    It 'names which history left the slot empty' -ForEach @(
        @{ Setup = { }
           Expect = 'nothing in this process ever armed one'
           Case   = 'no arm ran at all -- the hole is in the start path' }
        @{ Setup = { Yuruna.Host\Start-VMDhcpCapture -VMName 'test-other-01' | Out-Null
                     Yuruna.Host\Remove-VM -VMName 'test-other-01' -Confirm:$false | Out-Null }
           Expect = "was discarded when 'test-other-01' was removed"
           Case   = 'a teardown took it -- the hole is in the discard guard' }
    ) {
        # An empty slot has one message and three histories behind it, each
        # pointing at a different file. Without the transition recorded, the
        # cycle that most needs the evidence reports only that it is missing,
        # and the next occurrence is as unreadable as this one.
        InModuleScope 'Yuruna.Host' { $script:YurunaDhcpCapture = $null; $script:YurunaDhcpTrail = '' }
        Mock -ModuleName 'Yuruna.Host' Get-YurunaGuestBridge { @{ Bridge = ''; Network = '' } }
        Mock -ModuleName 'Yuruna.Host' Get-VMMac { '52:54:00:aa:bb:cc' }
        Mock -ModuleName 'Yuruna.Host' Invoke-Virsh { @() }
        $warnings = @()
        & $Setup
        Yuruna.Host\Save-VMDhcpCapture -VMName 'test-guest-01' -OutputDirectory $TestDrive `
            -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        ($warnings -join ' ') | Should -Match ([regex]::Escape($Expect)) -Because $Case
    }

    It 'never lets a capture failure escape into the step' {
        foreach ($name in 'Start-VMDhcpCapture', 'Stop-VMDhcpCapture', 'Save-VMDhcpCapture') {
            $fn = Get-PsFunctionText -Source $script:DriverText -Name $name
            $fn | Should -Match '(?ms)\}\s*catch\s*\{' -Because "$name is a diagnostic; a throw here fails the cycle it exists to explain"
        }
    }

    It 'exports all three verbs so the feature detection can find them' {
        foreach ($name in 'Start-VMDhcpCapture', 'Save-VMDhcpCapture', 'Stop-VMDhcpCapture') {
            $script:DriverText | Should -Match "Export-ModuleMember[\s\S]*$name" -Because "an unexported $name reads as `"driver does not implement it`" and the evidence silently never lands"
        }
    }
}

Describe 'kvm DHCP evidence: the bridge a capture and a journal read need' {

    It 'resolves a NAT guest one step further, through the network to its bridge' {
        Mock -ModuleName 'Yuruna.Host' Invoke-Virsh {
            # The driver reads $LASTEXITCODE right after each virsh call to tell
            # "answered with nothing" from "could not ask". A mock sets no exit
            # code, so without this the fixture inherits whatever native command
            # ran last in this runspace and the lookup declines before parsing.
            $global:LASTEXITCODE = 0
            if ($VirshArgs -contains 'domiflist') {
                return @(' Interface   Type      Source    Model    MAC',
                         '---------------------------------------------------',
                         ' vnet3       network   default   virtio   42:38:f4:32:9f:22')
            }
            return @('Name:           default', 'Active:         yes', 'Bridge:         virbr0')
        }
        $found = & $script:Driver { Get-YurunaGuestBridge -VMName 'test-guest-01' }
        $found.Bridge  | Should -Be 'virbr0' -Because 'only a bridge can be captured on; a network name cannot'
        $found.Network | Should -Be 'default' -Because 'the lease table is keyed by network, not by bridge'
    }

    It 'takes a bridged guest source as the bridge itself' {
        Mock -ModuleName 'Yuruna.Host' Invoke-Virsh {
            $global:LASTEXITCODE = 0
            return @(' Interface   Type     Source       Model    MAC',
                     '------------------------------------------------------',
                     ' vnet7       bridge   yuruna-br0   virtio   42:38:f4:32:98:22')
        }
        $found = & $script:Driver { Get-YurunaGuestBridge -VMName 'test-guest-01' }
        $found.Bridge  | Should -Be 'yuruna-br0'
        $found.Network | Should -BeNullOrEmpty -Because 'a bridged guest has no libvirt-managed lease table to read'
    }
}

Describe 'kvm DHCP evidence: what the failure folder ends up holding' {

    It 'writes the guest identity, the window and the server lines it found' {
        Mock -ModuleName 'Yuruna.Host' Get-YurunaDnsmasqJournal {
            return @('DHCPDISCOVER(virbr0) 42:38:f4:32:9f:22', 'DHCPOFFER(virbr0) 192.168.122.119 42:38:f4:32:9f:22')
        }
        Mock -ModuleName 'Yuruna.Host' Invoke-Virsh { return @(' Expiry Time   MAC address   Protocol   IP address') }
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-dhcp-test-{0}" -f ([guid]::NewGuid().ToString('N')))
        try {
            & $script:Driver {
                $script:YurunaDhcpCapture = @{
                    VMName = 'test-guest-01'; ArmedUtc = 1787242455; Mac = '42:38:F4:32:9F:22'
                    Bridge = 'virbr0'; Network = 'default'; PcapPath = ''; Process = $null
                    WireNote = 'no wire capture: CAP_NET_RAW not granted'
                }
            }
            $saved = Save-VMDhcpCapture -VMName 'test-guest-01' -OutputDirectory $dir
            $saved | Should -BeTrue
            $text = Get-Content -Raw -LiteralPath (Join-Path $dir 'dhcp.capture.txt')
            $text | Should -Match '42:38:F4:32:9F:22' -Because 'the MAC is what the journal below is read through, and it is gone once the domain is undefined'
            $text | Should -Match 'virbr0'
            $text | Should -Match 'DHCPOFFER' -Because 'the server lines are the whole point of the file'
            $text | Should -Match 'no wire capture' -Because 'a capture that did not run must say so, or its absence reads as silence on the wire'
            $text | Should -Match '2026-08-20T' -Because 'the armed instant has to be human-readable in the artifact'
        } finally {
            Remove-Item -Recurse -Force -LiteralPath $dir -ErrorAction SilentlyContinue
        }
    }

    It 'saves nothing for a VM that owns no window' {
        # The sweep removes leftover VMs by prefix and the runner calls this for
        # whichever guest failed. A save that answered for any VM would attach
        # one guest's evidence to another guest's folder.
        & $script:Driver { $script:YurunaDhcpCapture = @{ VMName = 'test-other-01' } }
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("yuruna-dhcp-test-{0}" -f ([guid]::NewGuid().ToString('N')))
        try {
            (Save-VMDhcpCapture -VMName 'test-guest-01' -OutputDirectory $dir) | Should -BeFalse
            (Test-Path -LiteralPath $dir) | Should -BeFalse -Because 'a declined save must not even create the folder'
        } finally {
            Remove-Item -Recurse -Force -LiteralPath $dir -ErrorAction SilentlyContinue
        }
    }

    AfterAll {
        & $script:Driver { $script:YurunaDhcpCapture = $null }
    }
}

# Copyright (c) 2019-2026 by Alisson Sol et al.
