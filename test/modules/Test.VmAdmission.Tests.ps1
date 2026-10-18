<#PSScriptInfo
.VERSION 2026.10.18.1
.GUID 421ee60b-7cf9-4ac6-8c6b-77960d28d454
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test vm admission cycle-start pester
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
    Pins the cycle-start VM admission: a cycle starts only on a host that was
    positively found free of other guests, and a host that cannot say is refused
    rather than waved through.
.DESCRIPTION
    Treating a missing driver or a failed inventory as "nothing is running", or
    discarding the check's result at the entry point, lets two cycles enter with an
    unknown VM state. These cases drive Get-VmAdmission and
    Invoke-HostVmAdmission against stand-in host-contract commands (which the
    facade resolves from the global command table at call time, the same way it
    finds a real driver) and check the outer runner's reading of the record the
    refusal leaves behind.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '',
    Justification = 'The facade resolves Get-VMName, Get-VMState and Stop-VMForce from the global command table at call time, as it does for a real host driver, so the stand-ins and the state they read straddle that scope.')]
param()

BeforeAll {
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
Import-Module (Join-Path $here 'Test.HostContract.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $here 'Test.RecoveryContract.psm1') -Force -Global -DisableNameChecking

function Install-HostStub {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: installs stand-in host-contract commands in the global scope and removes them in AfterEach.')]
    param()
    $global:__vmHost = @{ Names = @(); States = @{}; ListFailures = 0; ListCalls = 0; Stopped = [System.Collections.Generic.List[string]]::new(); StopWorks = $true }
    function global:Get-VMName {
        $global:__vmHost.ListCalls++
        if ($global:__vmHost.ListFailures -gt 0) { $global:__vmHost.ListFailures--; throw 'utmctl did not answer' }
        return @($global:__vmHost.Names)
    }
    function global:Get-VMState {
        param([string]$VMName)
        if ($global:__vmHost.States.ContainsKey($VMName)) { return [string]$global:__vmHost.States[$VMName] }
        return 'absent'
    }
    function global:Stop-VMForce {
        [CmdletBinding(SupportsShouldProcess)]
        param([string]$VMName)
        if ($PSCmdlet.ShouldProcess($VMName, 'stop')) {
            $global:__vmHost.Stopped.Add($VMName)
            if ($global:__vmHost.StopWorks) { $global:__vmHost.States[$VMName] = 'stopped' }
        }
    }
}

function Remove-HostStub {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test fixture: removes the stand-in commands Install-HostStub installed.')]
    param()
    # Path form with the drive prefix: the scope-qualified spelling
    # (function:global:Name) is accepted and silently removes nothing.
    Remove-Item -Path Function:\Get-VMName, Function:\Get-VMState, Function:\Stop-VMForce -ErrorAction SilentlyContinue
    Remove-Variable __vmHost -Scope Global -ErrorAction SilentlyContinue
}
}

Describe 'Get-VmAdmission' {
    BeforeEach { Install-HostStub }
    AfterEach { Remove-HostStub }

    It 'is clear when every VM is stopped or absent' {
        $global:__vmHost.Names = @('test-guest-a', 'test-guest-b')
        $global:__vmHost.States = @{ 'test-guest-a' = 'stopped'; 'test-guest-b' = 'absent' }
        $a = Get-VmAdmission -ProbeDelaySeconds 0
        $a.State | Should -Be 'clear'
        $a.Reason | Should -Be 'ok'
        $a.Probes | Should -Be 1
        @($a.Occupants).Count | Should -Be 0
    }
    It 'is clear on a host with no VMs at all' {
        (Get-VmAdmission -ProbeDelaySeconds 0).State | Should -Be 'clear'
    }
    It 'names the VMs that are running' {
        $global:__vmHost.Names = @('test-guest-a', 'test-guest-b')
        $global:__vmHost.States = @{ 'test-guest-a' = 'running'; 'test-guest-b' = 'stopped' }
        $a = Get-VmAdmission -ProbeDelaySeconds 0
        $a.State | Should -Be 'occupied'
        $a.Reason | Should -Be 'running-vm'
        @($a.Occupants) | Should -Be @('test-guest-a')
    }
    It 'lets a running service VM keep running' {
        $service = @(Get-YurunaServiceVmName)[0]
        $global:__vmHost.Names = @($service)
        $global:__vmHost.States = @{ $service = 'running' }
        (Get-VmAdmission -ProbeDelaySeconds 0).State | Should -Be 'clear'
    }
    It 'leaves the named dev-loop VM out of the question' {
        $global:__vmHost.Names = @('target-vm')
        $global:__vmHost.States = @{ 'target-vm' = 'running' }
        (Get-VmAdmission -ExceptVmName 'target-vm' -ProbeDelaySeconds 0).State | Should -Be 'clear'
        (Get-VmAdmission -ProbeDelaySeconds 0).State | Should -Be 'occupied'
    }
    It 'is unknown, not clear, when the inventory fails on every read' {
        $global:__vmHost.ListFailures = 99
        $a = Get-VmAdmission -MaxProbes 3 -ProbeDelaySeconds 0
        $a.State | Should -Be 'unknown'
        $a.Reason | Should -Be 'inventory-failed'
        $a.Probes | Should -Be 3 -Because 'the re-reads are bounded'
        $global:__vmHost.ListCalls | Should -Be 3
        $a.Detail | Should -Match 'utmctl did not answer'
    }
    It 'recovers when a later read succeeds' {
        $global:__vmHost.ListFailures = 1
        $a = Get-VmAdmission -MaxProbes 3 -ProbeDelaySeconds 0
        $a.State | Should -Be 'clear'
        $a.Probes | Should -Be 2
    }
    It 'is unknown when a VM''s state cannot be determined' {
        $global:__vmHost.Names = @('test-guest-a')
        $global:__vmHost.States = @{ 'test-guest-a' = 'unknown' }
        $a = Get-VmAdmission -MaxProbes 2 -ProbeDelaySeconds 0
        $a.State | Should -Be 'unknown'
        $a.Reason | Should -Be 'state-unverified'
        $a.Detail | Should -Match 'test-guest-a'
    }
    It 'treats a VM seen running as decisive, whatever else could not be read' {
        $global:__vmHost.Names = @('test-guest-a', 'test-guest-b')
        $global:__vmHost.States = @{ 'test-guest-a' = 'unknown'; 'test-guest-b' = 'running' }
        $a = Get-VmAdmission -ProbeDelaySeconds 0
        $a.State | Should -Be 'occupied'
        @($a.Occupants) | Should -Be @('test-guest-b')
        $a.Probes | Should -Be 1
    }
    It 'is unknown, not clear, when no host driver is loaded' {
        Remove-HostStub
        $a = Get-VmAdmission -ProbeDelaySeconds 0
        $a.State | Should -Be 'unknown'
        $a.Reason | Should -Be 'no-host-driver'
        $a.Probes | Should -Be 0
    }
}

Describe 'Stop-ConcurrentVM does not claim a clean host it never saw' {
    BeforeEach { Install-HostStub; Mock -ModuleName Test.HostContract Write-Warning { } }
    AfterEach { Remove-HostStub }

    It 'returns false when the inventory fails' {
        $global:__vmHost.ListFailures = 1
        Stop-ConcurrentVM -Confirm:$false 6>$null | Should -BeFalse
    }
    It 'returns false when no driver is loaded' {
        Remove-HostStub
        Stop-ConcurrentVM -Confirm:$false 6>$null | Should -BeFalse
    }
    It 'returns true when it read the host and nothing disallowed remains' {
        $global:__vmHost.Names = @('test-guest-a')
        $global:__vmHost.States = @{ 'test-guest-a' = 'running' }
        Stop-ConcurrentVM -Confirm:$false 6>$null | Should -BeTrue
        @($global:__vmHost.Stopped) | Should -Be @('test-guest-a')
    }
}

Describe 'Invoke-HostVmAdmission' {
    BeforeEach {
        Install-HostStub
        $script:Runtime = Join-Path ([System.IO.Path]::GetTempPath()) ('vmadm-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Runtime -Force | Out-Null
        Mock -ModuleName Test.HostContract Write-Warning { }
        $script:Record = Join-Path $script:Runtime 'vm-admission.json'
    }
    AfterEach {
        Remove-HostStub
        Remove-Item -LiteralPath $script:Runtime -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'lets a clean host through and records that it did' {
        $a = Invoke-HostVmAdmission -HostType 'host.ubuntu.kvm' -ProbeDelaySeconds 0 -RuntimeDir $script:Runtime 6>$null
        $a.State | Should -Be 'clear'
        (Get-Content -LiteralPath $script:Record -Raw | ConvertFrom-Json).state | Should -Be 'clear'
    }
    It 'stops a leftover guest and then lets the host through' {
        $global:__vmHost.Names = @('test-guest-a')
        $global:__vmHost.States = @{ 'test-guest-a' = 'running' }
        $a = Invoke-HostVmAdmission -HostType 'host.windows.hyper-v' -ProbeDelaySeconds 0 -RuntimeDir $script:Runtime 6>$null
        $a.State | Should -Be 'clear' -Because 'the common case is a guest a dead cycle left behind'
        @($global:__vmHost.Stopped) | Should -Be @('test-guest-a')
    }
    It 'refuses when a guest will not stop, and names it' {
        $global:__vmHost.Names = @('stubborn')
        $global:__vmHost.States = @{ 'stubborn' = 'running' }
        $global:__vmHost.StopWorks = $false
        $a = Invoke-HostVmAdmission -HostType 'host.windows.hyper-v' -ProbeDelaySeconds 0 -RuntimeDir $script:Runtime 6>$null
        $a.State | Should -Be 'occupied'
        @($a.Occupants) | Should -Be @('stubborn')
        $doc = Get-Content -LiteralPath $script:Record -Raw | ConvertFrom-Json
        $doc.state | Should -Be 'occupied'
        @($doc.occupants) | Should -Be @('stubborn')
        Should -Invoke -CommandName Write-Warning -ModuleName Test.HostContract -Scope It
    }
    It 'refuses a host that cannot say what is running, instead of proceeding' {
        $global:__vmHost.ListFailures = 99
        $a = Invoke-HostVmAdmission -HostType 'host.macos.utm' -ProbeDelaySeconds 0 -RuntimeDir $script:Runtime 6>$null
        $a.State | Should -Be 'unknown'
        @($global:__vmHost.Stopped).Count | Should -Be 0 -Because 'nothing is stopped on a guess'
        $doc = Get-Content -LiteralPath $script:Record -Raw | ConvertFrom-Json
        $doc.state | Should -Be 'unknown'
        $doc.reason | Should -Be 'inventory-failed'
        $doc.probes | Should -Be 3
    }
    It 'replaces an earlier refusal when the host is clear again' {
        $global:__vmHost.ListFailures = 99
        $null = Invoke-HostVmAdmission -HostType 'host.ubuntu.kvm' -ProbeDelaySeconds 0 -RuntimeDir $script:Runtime 6>$null
        $global:__vmHost.ListFailures = 0
        $null = Invoke-HostVmAdmission -HostType 'host.ubuntu.kvm' -ProbeDelaySeconds 0 -RuntimeDir $script:Runtime 6>$null
        (Get-Content -LiteralPath $script:Record -Raw | ConvertFrom-Json).state | Should -Be 'clear'
    }
    It 'still returns a verdict when there is nowhere to record it' {
        $a = Invoke-HostVmAdmission -HostType 'host.ubuntu.kvm' -ProbeDelaySeconds 0 -RuntimeDir (Join-Path $script:Runtime 'missing') 6>$null
        $a.State | Should -Be 'clear'
    }
}

Describe 'Read-VmAdmissionRecord' {
    BeforeEach {
        $script:Dir = Join-Path ([System.IO.Path]::GetTempPath()) ('vmrec-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Dir -Force | Out-Null
        $script:File = Join-Path $script:Dir 'vm-admission.json'
        $script:Spawned = [datetime]::UtcNow.AddMinutes(-5)
    }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'reports a refusal recorded after the cycle was spawned' {
        $stamp = [datetime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        Set-Content -LiteralPath $script:File -Value (@{ state = 'unknown'; reason = 'inventory-failed'; detail = 'utmctl did not answer'; occupants = @(); observedUtc = $stamp } | ConvertTo-Json) -Encoding utf8
        $r = Read-VmAdmissionRecord -RuntimeDir $script:Dir -NotBeforeUtc $script:Spawned
        $r.State | Should -Be 'unknown'
        $r.Reason | Should -Be 'inventory-failed'
    }
    It 'ignores a refusal from an earlier cycle' {
        $stamp = [datetime]::UtcNow.AddHours(-3).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        Set-Content -LiteralPath $script:File -Value (@{ state = 'occupied'; reason = 'running-vm'; occupants = @('x'); observedUtc = $stamp } | ConvertTo-Json) -Encoding utf8
        Read-VmAdmissionRecord -RuntimeDir $script:Dir -NotBeforeUtc $script:Spawned | Should -BeNullOrEmpty
    }
    It 'ignores a clear verdict, a missing file, unreadable text and a missing directory' {
        $stamp = [datetime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        Set-Content -LiteralPath $script:File -Value (@{ state = 'clear'; reason = 'ok'; observedUtc = $stamp } | ConvertTo-Json) -Encoding utf8
        Read-VmAdmissionRecord -RuntimeDir $script:Dir -NotBeforeUtc $script:Spawned | Should -BeNullOrEmpty
        Remove-Item -LiteralPath $script:File -Force
        Read-VmAdmissionRecord -RuntimeDir $script:Dir -NotBeforeUtc $script:Spawned | Should -BeNullOrEmpty
        Set-Content -LiteralPath $script:File -Value '{not json' -Encoding utf8
        Read-VmAdmissionRecord -RuntimeDir $script:Dir -NotBeforeUtc $script:Spawned | Should -BeNullOrEmpty
        Read-VmAdmissionRecord -RuntimeDir '' -NotBeforeUtc $script:Spawned | Should -BeNullOrEmpty
    }
}
