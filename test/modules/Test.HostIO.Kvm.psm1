<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42a1b2c3-d4e5-4f67-8901-bc012345672e
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
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

# Host I/O wiring for host.ubuntu.kvm.
#
# Send-Click is intentionally absent: KVM/libvirt guests run SSH-driven
# sequences after the GUI bring-up phase, so no mouse-click backend is
# needed. An attempt to call Send-Click on this host surfaces as the
# registry's canonical "not available on host" exception via the
# Send-Click dispatcher's catch.
#
# The Send-KeyKvm / Send-TextKvm function bodies live in Test.Transport.psm1;
# the registry primitives (Register-HostIOProvider, Invoke-HostIOAction)
# live in Test.HostIO.psm1.

Import-Module (Join-Path $PSScriptRoot 'Test.HostIO.psm1')   -Force -DisableNameChecking -Global
Import-Module (Join-Path $PSScriptRoot 'Test.Transport.psm1') -Force -DisableNameChecking -Global

Register-HostIOProvider -HostType 'host.ubuntu.kvm' -Action 'Send-Key' -Implementation {
    param([hashtable]$a)
    return (Send-KeyKvm -VMName $a.VMName -KeyName $a.KeyName)
}
Register-HostIOProvider -HostType 'host.ubuntu.kvm' -Action 'Send-Text' -Implementation {
    param([hashtable]$a)
    return (Send-TextKvm -VMName $a.VMName -Text $a.Text -CharDelayMs $a.CharDelayMs)
}
