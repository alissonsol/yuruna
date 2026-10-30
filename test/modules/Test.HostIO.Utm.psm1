<#PSScriptInfo
.VERSION 2026.10.30
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
    # The characters VNC wrote before it failed are already in the guest, and
    # typing them again would double them. The fallback types only the rest.
    $fault = Get-HostInputFault
    $delivered = if ($fault -and [int]$fault.delivered -gt 0) { [int]$fault.delivered } else { 0 }
    if ($delivered -ge $a.Text.Length) { return $true }
    if ($delivered -eq 0) {
        Write-Debug "      VNC unavailable for text, falling back to JXA/CGEvent"
        return (Send-TextUTM -VMName $a.VMName -Text $a.Text -CharDelayMs $a.CharDelayMs -ShellEscape:([bool]$a.ShellEscape))
    }
    Write-Debug "      VNC failed after $delivered of $($a.Text.Length) characters, typing the rest via JXA/CGEvent"
    if (-not $a.ShellEscape) {
        return (Send-TextUTM -VMName $a.VMName -Text $a.Text.Substring($delivered) -CharDelayMs $a.CharDelayMs)
    }
    # The escape wrapper is a command of its own, so it can only start a line:
    # spliced after half a line it would join that half. The partial line is
    # erased with Ctrl-U and the text retyped from its start. VNC has no key
    # for a newline, so nothing it typed was submitted.
    if (-not (Send-KeyUTM -VMName $a.VMName -KeyName 'CtrlU')) { return $false }
    return (Send-TextUTM -VMName $a.VMName -Text $a.Text -CharDelayMs $a.CharDelayMs -ShellEscape)
}
# --- REGION: Register Send-Click
Register-HostIOProvider -HostType 'host.macos.utm' -Action 'Send-Click' -Implementation {
    param([hashtable]$a)
    return (Send-ClickUtm -X $a.X -Y $a.Y -Capture $a.Capture)
}
