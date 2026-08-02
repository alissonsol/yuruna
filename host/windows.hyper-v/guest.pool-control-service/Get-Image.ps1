<#PSScriptInfo
.VERSION 2026.08.02
.GUID 42a4c5d6-a7b8-4d90-1234-e5f6a7b8c9d4
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
    Provides the Ubuntu server cloud image (converted to VHDX) that backs
    the pool-control service VM on Hyper-V.

.DESCRIPTION
    Wrapper over the shared extension-service base image
    (Get-UbuntuExtensionImageInfo / Save-UbuntuExtensionImage in
    host/modules/Yuruna.Image.psm1). Every extension service on this host
    boots the same cloud image, so one artifact serves all of them instead
    of a byte-identical copy per service -- which on Hyper-V also collapses
    three qcow2-to-VHDX conversions into one. This per-service entry point
    stays so the pool-control service can move to a different release, arch
    or post-processing step later without disturbing the others.

    The shared VHDX keeps the cloud image's native capacity. New-VM.ps1
    grows its own per-VM copy to the size the pool-control daemon needs.
#>

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    Write-Output "Be careful."
    exit 1
}

# Yuruna.Host.psm1 supplies the cache-injecting Save-CachedHttpUri wrapper and
# (via its global Yuruna.HostDownload import) the sentinel guard the shared
# pipeline resolves by name, so the download routes through the squid cache
# whenever one is reachable.
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) "modules/Yuruna.Host.psm1") -Force
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "modules/Yuruna.Image.psm1") -Force

try {
    $image = Get-UbuntuExtensionImageInfo -HostType 'windows.hyper-v'
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
Write-Output "Hyper-V default VHDX folder: $($image.DownloadDir)"
if (-not (Save-UbuntuExtensionImage -Image $image -Verbose:($VerbosePreference -ne 'SilentlyContinue'))) {
    exit 1
}
