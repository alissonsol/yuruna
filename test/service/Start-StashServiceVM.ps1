<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42d07272-8c12-4ba7-807e-c0b201076d87
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna stash service extension service
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
    Brings up the Yuruna stash service VM (host.windows.hyper-v,
    host.ubuntu.kvm, host.macos.utm). See
    https://yuruna.link/42f5e921 for the stash user guide.

.PARAMETER VMName
    Name for the stash-service VM. Default: yuruna-stash-service.

.PARAMETER AllowMirrorSource
    Build the daemon from the public github mirror instead of this enlistment.
    Without it, a bring-up whose guest could not fetch this host's framework --
    or one whose daemon turns out to have been built from another snapshot --
    is refused rather than deploying code older than the operator is working in.
    Legitimate off-LAN, where the mirror is the only source there is.
.PARAMETER AllowPseudoLocale
    Enable developer pseudo locales for the rebuilt service VM. Disabled by default.
.PARAMETER ForceRebuild
    Rebuild the VM even when the running one serves the current build or is
    still building it. Without it a re-run keeps such a VM (adopts it).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-stash-service',
    [switch]$AllowMirrorSource,
    [switch]$AllowPseudoLocale,
    [switch]$ForceRebuild
)

if (-not $PSCmdlet.ShouldProcess($VMName, 'Start or rebuild the service VM and configure host services')) { return }
& (Join-Path $PSScriptRoot 'Start-ExtensionService.ps1') -VMName $VMName -ServiceKey 'stash' -Area 'stash-service' -CallerScript $PSCommandPath `
    -AllowMirrorSource:$AllowMirrorSource -AllowPseudoLocale:$AllowPseudoLocale -ForceRebuild:$ForceRebuild -Confirm:$false
exit $LASTEXITCODE
