<#PSScriptInfo
.VERSION 2026.09.30
.GUID 4223cd4e-7ab2-4316-8d12-b6869c2182c8
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

<#
.SYNOPSIS
    Downloads the Ubuntu Server 24.04 live-server ISO for autoinstall
    on Ubuntu KVM.
.DESCRIPTION
    Uses the shared server ISO pipeline so each host runs the same
    subiquity installation sequence. See https://yuruna.link/42e220c4-0003.
.PARAMETER daily
    Prefer the rolling daily ISO over the latest stable point release.
    See https://yuruna.link/42e220c4-0003 for release-specific kernel workarounds.
#>

param(
    [switch]$daily
)

# --- REGION: Log level from environment
# Reuse the caller's log module so an in-process fetch preserves its state.
$arguments = @{} + $PSBoundParameters
& (Join-Path $PSScriptRoot '../modules/Get-UbuntuServerImage.ps1') @arguments -Release '24' -GuestScriptRoot $PSScriptRoot -EnvironmentErrorKey 'host.operator_9a367ca9534863eb'
exit $LASTEXITCODE
