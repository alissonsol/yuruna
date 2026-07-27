<#PSScriptInfo
.VERSION 2026.07.26
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

# Host I/O wiring for host.macos.utm: Send-Key / Send-Text are VNC-first
# with AppleScript/CGEvent fallback; Send-Click is CGEvent-only. Function
# bodies live in Test.Transport.psm1; the registry primitives
# (Register-HostIOProvider, Invoke-HostIOAction) in Test.HostIO.psm1.
# See docs/host-io.md.

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
