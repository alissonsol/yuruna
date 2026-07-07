<#PSScriptInfo
.VERSION 2026.07.07
.GUID 42a1b2c3-d4e5-4f67-8901-bc012345672c
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

# Host I/O wiring for host.macos.utm.
#
# QEMU VMs running under UTM expose a built-in VNC server, so Send-Key /
# Send-Text try the VNC backend first and fall back to AppleScript/CGEvent
# only when VNC is unavailable. AXUIElementPostKeyboardEvent was tested
# but UTM's SwiftUI VM display does not route Accessibility keyboard
# events into the guest -- it reports success but the keys never reach
# the VM.
#
# Send-Click goes straight to the AppleScript/CGEvent backend (no VNC
# pointer path here; UTM's QEMU does not expose mouse-state changes on
# its VNC channel reliably enough).
#
# The Send-KeyUTM / Send-KeyVNC / Send-TextUTM / Send-TextVNC / Send-ClickUtm
# function bodies live in Test.Transport.psm1; the registry primitives
# (Register-HostIOProvider, Invoke-HostIOAction) live in Test.HostIO.psm1.

Import-Module (Join-Path $PSScriptRoot 'Test.HostIO.psm1')   -Force -DisableNameChecking -Global
Import-Module (Join-Path $PSScriptRoot 'Test.Transport.psm1') -Force -DisableNameChecking -Global

Register-HostIOProvider -HostType 'host.macos.utm' -Action 'Send-Key' -Implementation {
    param([hashtable]$a)
    $vncOk = Send-KeyVNC -VMName $a.VMName -KeyName $a.KeyName
    if ($vncOk) { return $true }
    Write-Debug "      VNC unavailable for key, falling back to AppleScript"
    return (Send-KeyUTM -VMName $a.VMName -KeyName $a.KeyName)
}
Register-HostIOProvider -HostType 'host.macos.utm' -Action 'Send-Text' -Implementation {
    param([hashtable]$a)
    $vncOk = Send-TextVNC -VMName $a.VMName -Text $a.Text -CharDelayMs $a.CharDelayMs
    if ($vncOk) { return $true }
    Write-Debug "      VNC unavailable for text, falling back to JXA/CGEvent"
    return (Send-TextUTM -VMName $a.VMName -Text $a.Text -CharDelayMs $a.CharDelayMs -ShellEscape:([bool]$a.ShellEscape))
}
Register-HostIOProvider -HostType 'host.macos.utm' -Action 'Send-Click' -Implementation {
    param([hashtable]$a)
    return (Send-ClickUtm -X $a.X -Y $a.Y -Capture $a.Capture)
}
