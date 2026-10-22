<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42b76467-f8fe-4947-8d67-c0052ebd3b61
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna lab syzygy service vm
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

<#
.SYNOPSIS
    Stop the download agent, pool control, stash, and caching proxy service VMs.
.DESCRIPTION
    Runs the sibling service scripts sequentially in the listed order. Resolves
    their absolute paths from this script's directory, independent of the
    caller's working directory. Each service script owns its confirmation and
    failure behavior; explicit common parameters are forwarded unchanged.
.EXAMPLE
    pwsh test/lab/Stop-Syzygy.ps1
.EXAMPLE
    pwsh test/lab/Stop-Syzygy.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param()

$serviceDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../service'))

& (Join-Path $serviceDirectory 'Stop-DownloadAgentServiceVM.ps1') @PSBoundParameters
& (Join-Path $serviceDirectory 'Stop-PoolControlServiceVM.ps1') @PSBoundParameters
& (Join-Path $serviceDirectory 'Stop-StashServiceVM.ps1') @PSBoundParameters
& (Join-Path $serviceDirectory 'Stop-CachingProxyServiceVM.ps1') @PSBoundParameters
