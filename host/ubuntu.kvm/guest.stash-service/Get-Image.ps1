<#PSScriptInfo
.VERSION 2026.09.13
.GUID 4228e179-6886-4d3c-8614-e1ebc0e0d358
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
    Provides the shared Ubuntu cloud image for the stash-service VM
    on Ubuntu KVM.
.DESCRIPTION
    Uses the shared extension image pipeline. New-VM.ps1 grows the VM's
    private disk copy to the capacity its service needs.
    See https://yuruna.link/42e220c4-0003.
#>

# --- REGION: Log level from environment
# Reuse the caller's log module so an in-process fetch preserves its state.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

# --- REGION: Platform guard
if (-not $IsLinux) {
    Write-Error "host/ubuntu.kvm/guest.stash-service/Get-Image.ps1 only runs on Ubuntu KVM."
    exit 1
}

# --- REGION: Import host modules
# The host wrapper supplies cache discovery to the shared image pipeline.
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Yuruna.Host.psm1') -Force
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force

# --- REGION: Resolve and fetch the base image
# See https://yuruna.link/42e220c4-0003
try {
    $image = Get-UbuntuExtensionImageInfo -HostType 'ubuntu.kvm'
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
if (-not (Save-UbuntuExtensionImage -Image $image -Verbose:($VerbosePreference -ne 'SilentlyContinue'))) {
    exit 1
}

# --- REGION: Completion
# Clear a native discovery probe's stale exit code, including on cache hits.
exit 0
