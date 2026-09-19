<#PSScriptInfo
.VERSION 2026.09.18
.GUID 4237f41c-bd9e-434d-92a3-7825043e8c54
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
    Provides the shared Ubuntu cloud image for the caching-proxy-service VM
    on macOS UTM.
.DESCRIPTION
    Uses the shared extension image pipeline. New-VM.ps1 grows the VM's
    private disk copy to the capacity its service needs.
    See https://yuruna.link/42e220c4-0003.
#>

# --- REGION: Log level from environment
# Reuse the caller's log module so an in-process fetch preserves its state.
Import-Module (Join-Path $PSScriptRoot '../../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }

# --- REGION: Platform guard
if (-not $IsMacOS) {
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_1e2a4e011d506e01')
    exit 1
}

# --- REGION: Import host modules
# The host wrapper supplies cache discovery to the shared image pipeline.
Import-Module -Name (Join-Path (Split-Path -Parent $PSScriptRoot) 'modules/Yuruna.Host.psm1') -Force
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'modules/Yuruna.Image.psm1') -Force

# --- REGION: Resolve and fetch the base image
# See https://yuruna.link/42e220c4-0003
try {
    $image = Get-UbuntuExtensionImageInfo -HostType 'macos.utm'
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
