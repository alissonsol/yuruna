<#PSScriptInfo
.VERSION 2026.10.22
.GUID 42ca1491-7225-47ce-8075-fbf605f70a50
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
    Start the caching proxy, stash, pool control, and download agent service VMs.
.DESCRIPTION
    Runs the sibling service scripts sequentially in the listed order. Resolves
    their absolute paths from this script's directory, independent of the
    caller's working directory. Each service script owns its confirmation and
    failure behavior; explicit common parameters are forwarded unchanged.
.EXAMPLE
    pwsh test/lab/Start-Syzygy.ps1
.EXAMPLE
    pwsh test/lab/Start-Syzygy.ps1 -WhatIf
#>

[CmdletBinding(SupportsShouldProcess)]
param()

$serviceDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../service'))

& (Join-Path $serviceDirectory 'Start-CachingProxyServiceVM.ps1') -MacAddress 42:42:42:42:42:42 -AllowPseudoLocale @PSBoundParameters
& (Join-Path $serviceDirectory 'Start-StashServiceVM.ps1') -AllowPseudoLocale @PSBoundParameters
& (Join-Path $serviceDirectory 'Start-PoolControlServiceVM.ps1') -AllowPseudoLocale @PSBoundParameters
& (Join-Path $serviceDirectory 'Start-DownloadAgentServiceVM.ps1') -AllowPseudoLocale @PSBoundParameters
