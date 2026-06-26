<#PSScriptInfo
.VERSION 2026.06.26
.GUID 42a1b2c3-d4e5-4f67-8901-bc012345672b
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
# The actual Send-KeyHyperV / Send-TextHyperV / Send-ClickHyperV function
# bodies live in Test.Transport.psm1 (the cross-platform transport layer);
# this module is *only* the registry-wiring layer that exposes those
# functions through the Send-Key / Send-Text / Send-Click dispatch
# contract. A new host adds a parallel Test.HostIO.<NewHost>.psm1.
#
# The registry primitives (Register-HostIOProvider, Invoke-HostIOAction)
# live in Test.HostIO.psm1.

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
