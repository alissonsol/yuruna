<#PSScriptInfo
.VERSION 2026.09.12
.GUID 42805ef5-4d7a-434d-8db7-3469a1f99e07
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
Register-HostIOProvider -HostType 'host.windows.hyper-v' -Action 'Send-Key' -Implementation {
    param([hashtable]$a)
    return (Send-KeyHyperV -VMName $a.VMName -KeyName $a.KeyName)
}
# --- REGION: Register Send-Text
Register-HostIOProvider -HostType 'host.windows.hyper-v' -Action 'Send-Text' -Implementation {
    param([hashtable]$a)
    return (Send-TextHyperV -VMName $a.VMName -Text $a.Text -CharDelayMs $a.CharDelayMs)
}
# --- REGION: Register Send-Click
Register-HostIOProvider -HostType 'host.windows.hyper-v' -Action 'Send-Click' -Implementation {
    param([hashtable]$a)
    return (Send-ClickHyperV -VMName $a.VMName -X $a.X -Y $a.Y)
}
