<#PSScriptInfo
.VERSION 2026.08.04
.GUID 42f3d4e5-f6a7-4b89-c012-3d4e5f6a7b8c
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
    Provides the Ubuntu server cloud image (qcow2) that backs the
    caching-proxy service VM on Linux/KVM.

.DESCRIPTION
    Wrapper over the shared extension-service base image
    (Get-UbuntuExtensionImageInfo / Save-UbuntuExtensionImage in
    host/modules/Yuruna.Image.psm1). Every extension service on this host
    boots the same arch-matched cloud image, so one artifact serves all of
    them instead of a byte-identical copy per service; the second and third
    service to ask for it cost a single HEAD request. This per-service entry
    point stays so the caching proxy can move to a different release, arch or
    post-processing step later without disturbing the others.

    The shared image keeps the cloud image's native capacity. New-VM.ps1
    grows its own per-VM copy to the size squid needs.
#>

# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }

if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.caching-proxy-service/Get-Image.ps1 only runs on Linux."
    exit 1
}

# Yuruna.Host.psm1 supplies the cache-injecting Save-CachedHttpUri wrapper and
# (via its global Yuruna.HostDownload import) the sentinel guard the shared
# pipeline resolves by name. This guest IS the cache, so on a first build no
# cache exists and the fetch goes direct; when an older cache VM is still up
# its image refresh can route through it.
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Yuruna.Host.psm1') -Force
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force

try {
    $image = Get-UbuntuExtensionImageInfo -HostType 'ubuntu.kvm'
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
if (-not (Save-UbuntuExtensionImage -Image $image -Verbose:($VerbosePreference -ne 'SilentlyContinue'))) {
    exit 1
}
# Success must be an explicit exit 0. Start-CachingProxyServiceVM.ps1 invokes
# this script in-process (& $GetImageScript) and reads $LASTEXITCODE, and the
# download-agent discovery ladder inside Save-UbuntuExtensionImage probes VMs
# that may legitimately be absent (virsh domifaddr on a missing domain exits
# 1). A cache-hit run ends on cmdlets, which never overwrite $LASTEXITCODE,
# so falling off the end here would report that stale probe failure as this
# script's own exit status.
exit 0
