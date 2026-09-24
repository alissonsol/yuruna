<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42e401e1-b46e-4123-be6e-fddcaac3185f
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
Register-HostIOProvider -HostType 'host.ubuntu.kvm' -Action 'Send-Key' -Implementation {
    param([hashtable]$a)
    return (Send-KeyKvm -VMName $a.VMName -KeyName $a.KeyName)
}
# --- REGION: Register Send-Text
Register-HostIOProvider -HostType 'host.ubuntu.kvm' -Action 'Send-Text' -Implementation {
    param([hashtable]$a)
    return (Send-TextKvm -VMName $a.VMName -Text $a.Text -CharDelayMs $a.CharDelayMs)
}
