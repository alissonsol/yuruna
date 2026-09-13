<#PSScriptInfo
.VERSION 2026.09.13
.GUID 426707af-05ab-4e6d-8121-412be356d73b
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

# --- REGION: Host I/O provider
# See https://yuruna.link/4222e5f2
# --- REGION: Import the shared transport
Import-Module (Join-Path $PSScriptRoot 'Test.HostIO.psm1')   -Force -DisableNameChecking -Global
Import-Module (Join-Path $PSScriptRoot 'Test.Transport.psm1') -Force -DisableNameChecking -Global

# --- REGION: Register Send-Key
Register-HostIOProvider -HostType 'host.macos.utm' -Action 'Send-Key' -Implementation {
    param([hashtable]$a)
    $vncOk = Send-KeyVNC -VMName $a.VMName -KeyName $a.KeyName
    if ($vncOk) { return $true }
    Write-Debug "      VNC unavailable for key, falling back to AppleScript"
    return (Send-KeyUTM -VMName $a.VMName -KeyName $a.KeyName)
}
# --- REGION: Register Send-Text
Register-HostIOProvider -HostType 'host.macos.utm' -Action 'Send-Text' -Implementation {
    param([hashtable]$a)
    $vncOk = Send-TextVNC -VMName $a.VMName -Text $a.Text -CharDelayMs $a.CharDelayMs
    if ($vncOk) { return $true }
    Write-Debug "      VNC unavailable for text, falling back to JXA/CGEvent"
    return (Send-TextUTM -VMName $a.VMName -Text $a.Text -CharDelayMs $a.CharDelayMs -ShellEscape:([bool]$a.ShellEscape))
}
# --- REGION: Register Send-Click
Register-HostIOProvider -HostType 'host.macos.utm' -Action 'Send-Click' -Implementation {
    param([hashtable]$a)
    return (Send-ClickUtm -X $a.X -Y $a.Y -Capture $a.Capture)
}
