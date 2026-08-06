<#PSScriptInfo
.VERSION 2026.08.06
.GUID 42f0a1b2-c3d4-4e56-f789-0a1b2c3d4e57
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
    the caching-proxy service VM on Hyper-V.

.DESCRIPTION
    Wrapper over the shared extension-service base image
    (Get-UbuntuExtensionImageInfo / Save-UbuntuExtensionImage in
    host/modules/Yuruna.Image.psm1). Every extension service on this host
    boots the same cloud image, so one artifact serves all of them instead
    of a byte-identical copy per service -- which on Hyper-V also collapses
    three qcow2-to-VHDX conversions into one. This per-service entry point
    stays so the caching proxy can move to a different release, arch or
    post-processing step later without disturbing the others.

    The shared VHDX keeps the cloud image's native capacity. New-VM.ps1
    grows its own per-VM copy to the size squid needs.
#>

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
# Load only when absent, never -Force. Start-CachingProxyServiceVM.ps1 runs this
# script IN-PROCESS, so a forced re-import from here tears down and rebuilds the
# module instance its caller is already using, taking whatever that instance keeps
# in module scope with it and narrating a dozen import lines into the run's
# transcript at Verbose (feedback_module_force_import_evicts_global). Tradeoff: an
# edit to the module mid-session is not picked up here, which is acceptable for a
# leaf script that only reads the level.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

Write-Output "This script requires elevation (Run as Administrator)."
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output "Please run this script as Administrator."
    Write-Output "Be careful."
    exit 1
}

# Yuruna.Host.psm1 supplies the cache-injecting Save-CachedHttpUri wrapper and
# (via its global Yuruna.HostDownload import) the sentinel guard the shared
# pipeline resolves by name. This guest IS the cache, so on a first-run host
# no cache exists yet and the fetch falls through to a direct download.
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
# Success must be an explicit exit 0. Start-CachingProxyServiceVM.ps1 invokes
# this script in-process (& $GetImageScript) and reads $LASTEXITCODE; any
# native command a helper ran along the way (qemu-img, discovery probes for
# VMs that may legitimately be absent) leaves its exit code behind, and a
# cache-hit run ends on cmdlets that never overwrite it. Falling off the end
# here would report that stale code as this script's own exit status.
exit 0
