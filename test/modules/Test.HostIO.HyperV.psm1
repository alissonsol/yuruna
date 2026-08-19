<#PSScriptInfo
.VERSION 2026.08.19
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

# Host I/O wiring for host.windows.hyper-v.
#
# This module is *only* the registry-wiring layer that exposes the
# Send-Key / Send-Text / Send-Click dispatch contract for this host.
#
# The Send-KeyHyperV / Send-TextHyperV / Send-ClickHyperV function bodies
# live in Test.Transport.psm1; the registry primitives
# (Register-HostIOProvider, Invoke-HostIOAction) live in Test.HostIO.psm1.
# See docs/host-io.md.

Import-Module (Join-Path $PSScriptRoot 'Test.HostIO.psm1')   -Force -DisableNameChecking -Global
Import-Module (Join-Path $PSScriptRoot 'Test.Transport.psm1') -Force -DisableNameChecking -Global

Register-HostIOProvider -HostType 'host.windows.hyper-v' -Action 'Send-Key' -Implementation {
    param([hashtable]$a)
    return (Send-KeyHyperV -VMName $a.VMName -KeyName $a.KeyName)
}
Register-HostIOProvider -HostType 'host.windows.hyper-v' -Action 'Send-Text' -Implementation {
    param([hashtable]$a)
    return (Send-TextHyperV -VMName $a.VMName -Text $a.Text -CharDelayMs $a.CharDelayMs)
}
Register-HostIOProvider -HostType 'host.windows.hyper-v' -Action 'Send-Click' -Implementation {
    param([hashtable]$a)
    return (Send-ClickHyperV -VMName $a.VMName -X $a.X -Y $a.Y)
}
