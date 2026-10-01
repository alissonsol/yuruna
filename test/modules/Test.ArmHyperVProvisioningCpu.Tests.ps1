<#PSScriptInfo
.VERSION 2026.09.26
.GUID 42ee3a5e-8d68-44a7-b9d5-2584bc194d84
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test hyper-v arm64 cpu provisioning sequence pester
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES Pester
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

<#
.SYNOPSIS
    Pins the two-phase ARM64 Hyper-V processor policy for Ubuntu 26.
.DESCRIPTION
    Provisioning must begin with one vCPU, then a clean offline transition
    restores two before Kubernetes. These source-level guards touch no live VM.
#>

BeforeAll {
$here = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
Import-Module (Join-Path $here 'Test.Assert.psm1') -Force -Global -DisableNameChecking

$script:newVmPath = Join-Path $repoRoot 'host/windows.hyper-v/guest.ubuntu.server.26/New-VM.ps1'
$script:hostPath = Join-Path $repoRoot 'host/windows.hyper-v/modules/Yuruna.Host.psm1'
$script:handlerPath = Join-Path $repoRoot 'test/modules/Test.SequenceHandler.psm1'
$script:sequencePaths = @(
    (Join-Path $repoRoot 'test/sequences/start.guest.ubuntu.server.26.yml'),
    (Join-Path $repoRoot 'test/sequences/start.guest.ubuntu.server.26.ssh.yml')
)
}

Describe 'Ubuntu 26 ARM64 Hyper-V processor phases' {
    It 'caps only the initial Ubuntu 26 provisioning VM at one processor' {
        $src = Get-Content -Raw -LiteralPath $script:newVmPath
        Assert-True ($src -match 'Limit-HyperVLinuxGuestCoreCount\s+-RequestedCores\s+\$vmCores\s+-MaximumCores\s+1') `
            'Ubuntu 26 New-VM must use the one-vCPU provisioning cap'
    }

    It 'powers off cleanly and restores two processors on both console and SSH paths' {
        foreach ($sequencePath in $script:sequencePaths) {
            $src = Get-Content -Raw -LiteralPath $sequencePath
            Assert-True ($src -match 'sudo poweroff') "$sequencePath must reach a clean poweroff"
            Assert-True ($src -match '(?s)action:\s+startVm.*arm64HyperVProcessorCount:\s+2') `
                "$sequencePath must restore the two-vCPU Kubernetes minimum"
            Assert-True ($src -notmatch 'sudo reboot now') `
                "$sequencePath must not race the offline processor update with a guest-owned reboot"
        }

        $consoleSrc = Get-Content -Raw -LiteralPath $script:sequencePaths[0]
        Assert-True ($consoleSrc -match '(?s)arm64HyperVProcessorCount:\s+2.*pattern:\s+"\$\{hostLabel\} login:"') `
            'the console path must wait for login only after the processor transition'

        $sshSrc = Get-Content -Raw -LiteralPath $script:sequencePaths[1]
        Assert-True ($sshSrc -match '(?s)arm64HyperVProcessorCount:\s+2.*action:\s+sshWaitReady') `
            'the SSH path must wait for SSH only after the processor transition'
    }

    It 'changes processors only on ARM64 and only while Hyper-V reports Off' {
        $src = Get-Content -Raw -LiteralPath $script:hostPath
        Assert-True ($src -match 'function Set-HyperVArm64LinuxGuestProcessorCount') 'the host helper must exist'
        Assert-True ($src -match 'OSArchitecture\s+-ne\s+\[System\.Runtime\.InteropServices\.Architecture\]::Arm64') `
            'AMD64 must retain its normal VM sizing'
        Assert-True ($src -match "resolved\.VM\.State\s+-ne\s+'Off'") 'processor changes must require an Off VM'
        Assert-True ($src -match 'Hyper-V\\Set-VMProcessor\s+-VMName\s+\$VMName\s+-Count\s+\$Count') `
            'the requested count must reach Hyper-V'
        Assert-True ($src -match 'Hyper-V\\Get-VMProcessor') 'the postcondition must be read back'
        Assert-True ($src -match 'Limit-HyperVLinuxGuestCoreCount, Set-HyperVArm64LinuxGuestProcessorCount') `
            'the sequence handler must be able to resolve the exported helper'
    }

    It 'waits for stopped state, applies the ARM64 transition, then starts through the host driver' {
        $src = Get-Content -Raw -LiteralPath $script:handlerPath
        $registration = [regex]::Match($src, "(?s)Register-SequenceAction -Name 'startVm'.*?(?=Register-SequenceAction -Name 'break')")
        Assert-True $registration.Success 'startVm action registration must exist'
        $body = $registration.Value
        Assert-True ($body -match 'Get-VMState') 'startVm must observe the shutdown boundary'
        Assert-True ($body -match "HostType\s+-eq\s+'host\.windows\.hyper-v'") 'the resize must stay Hyper-V-specific'
        Assert-True ($body -match 'Set-HyperVArm64LinuxGuestProcessorCount') 'startVm must invoke the ARM64 helper'
        $resizeIndex = $body.IndexOf('Set-HyperVArm64LinuxGuestProcessorCount -VMName')
        $startIndex = $body.IndexOf('$startResult = Start-VM')
        Assert-True ($resizeIndex -ge 0 -and $startIndex -ge 0) 'both ordered call sites must be present'
        Assert-True ($resizeIndex -lt $startIndex) `
            'the offline resize must happen before the VM is started'
        Assert-True ($body -match 'startRecord\.success') 'a start request alone is not proof that the VM started'
    }
}
