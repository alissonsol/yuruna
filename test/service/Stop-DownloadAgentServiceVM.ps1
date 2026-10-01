<#PSScriptInfo
.VERSION 2026.09.30
.GUID 429cbb3b-d9b5-4a3c-af14-67208c19e773
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
    Stop the Download-agent service and clear its marker.
.DESCRIPTION
    Symmetric with Start-DownloadAgentServiceVM. Removes
    runtime/download-agent-service.json (so Test.Capability drops the
    download-agent-service area) and refreshes the registration record so the
    host clears from the dashboard's Extension hosts table. Then tears down the
    download-agent-service VM and every file it owns -- the registry/domain
    entry, the copied disk image, the cloud-init seed, and (UTM) the .utm bundle
    -- so the next Start rebuilds from a clean slate.

    The image pool itself lives on the pool share, not on the disposable VM
    disk, so nothing downloaded is lost: a rebuilt agent adopts the same pool,
    re-reads its pointers, and serves the existing generations immediately.

    The Go service posts an active:false beacon goodbye on SIGTERM/exit, so the
    aggregator's Extension-hosts row clears from both paths.
.PARAMETER VMName
    Name of the download-agent-service VM. Default:
    yuruna-download-agent-service.
.EXAMPLE
    pwsh test/service/Stop-DownloadAgentServiceVM.ps1
    # Clears the marker, refreshes registration, then removes the VM.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-download-agent-service'
)

if (-not $PSCmdlet.ShouldProcess($VMName, 'Stop and remove the service VM and withdraw its advertisement')) { return }
& (Join-Path $PSScriptRoot 'Stop-ExtensionService.ps1') -VMName $VMName -ServiceKey 'download-agent' -Area 'download-agent-service' -ServiceName 'DownloadAgent' -CallerScript $PSCommandPath -Confirm:$false
exit $LASTEXITCODE
