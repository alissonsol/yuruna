<#PSScriptInfo
.VERSION 2026.10.31
.GUID 42f17d0e-cf42-4655-b11b-a34a4a0b449c
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna download agent service extension service
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
    Bring up the Download-agent service on THIS host by building + launching it
    on its OWN VM, and publish its marker.
.DESCRIPTION
    Like Start-StashServiceVM / Start-PoolControlServiceVM, this brings the
    service up on a dedicated VM (guest.download-agent-service): it runs the
    pool-storage pre-flight, then delegates to the per-host New-VM.ps1, whose
    cloud-init fetches the framework and runs the bring-up script that builds
    the Go daemon, CIFS-mounts the pool share at /mnt/yuruna-pool for the image
    pool, and launches the daemon under systemd (UI + API on :80) INSIDE the
    guest -- no Go toolchain is needed on the host.

    Writes runtime/download-agent-service.json (the marker Test.Capability folds
    into host.registration.json so the service shows up in the Extension hosts
    table) and refreshes the registration record so the host appears within one
    aggregator poll. The Go service also self-announces to the aggregator via
    its beacon, so the Extension-hosts row appears by marker AND by beacon
    independently.
.PARAMETER VMName
    Name of the download-agent-service VM. Default:
    yuruna-download-agent-service.
.PARAMETER AllowMirrorSource
    Build the daemon from the public github mirror instead of this enlistment.
    Without it, a bring-up whose guest could not fetch this host's framework --
    or one whose daemon turns out to have been built from another snapshot -- is
    refused rather than deploying code older than the operator is working in.
    Legitimate off-LAN, where the mirror is the only source there is.
.PARAMETER AllowPseudoLocale
    Enable developer pseudo locales for the rebuilt service VM. Disabled by default.
.PARAMETER ForceRebuild
    Rebuild the VM even when the running one serves the current build or is
    still building it. Without it a re-run keeps such a VM (adopts it).
.EXAMPLE
    pwsh test/service/Start-DownloadAgentServiceVM.ps1
    # Builds + starts the VM, waits for :80, and publishes the marker.
.EXAMPLE
    $env:YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS = '120'
    pwsh test/service/Start-DownloadAgentServiceVM.ps1
    # Short readiness budget for a quick re-check of a VM that is already up.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-download-agent-service',
    [switch]$AllowMirrorSource,
    [switch]$AllowPseudoLocale,
    [switch]$ForceRebuild
)

if (-not $PSCmdlet.ShouldProcess($VMName, 'Start or rebuild the service VM and configure host services')) { return }
& (Join-Path $PSScriptRoot 'Start-ExtensionService.ps1') -VMName $VMName -ServiceKey 'download-agent' -Area 'download-agent-service' -CallerScript $PSCommandPath `
    -AllowMirrorSource:$AllowMirrorSource -AllowPseudoLocale:$AllowPseudoLocale -ForceRebuild:$ForceRebuild -Confirm:$false
exit $LASTEXITCODE
