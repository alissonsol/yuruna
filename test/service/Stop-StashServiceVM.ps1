<#PSScriptInfo
.VERSION 2026.09.30
.GUID 4234ee0c-21ea-43ed-ad32-56a9835e71aa
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
    Stops the Yuruna stash service VM and removes every file it owns --
    the registry/domain entry, the copied disk image, the cloud-init
    seed, and (UTM) the .utm bundle -- so the next Start-StashServiceVM
    builds from a clean slate with no leftover VM files.

    The durable stash data is untouched: received files, the per-artifact
    sidecar records, and the persisted SSH host key live on the NAS stash
    share, not on the disposable VM disk. Start rebuilds the disk from the
    base image.

    In-flight uploads are not drained: a graceful stop runs first so the
    daemon's flush worker can push NAS-offline buffered uploads to the share,
    but deleting the disk then discards anything still buffered locally --
    the same caveat as any reimage. Committed (on-share) artifacts and their
    sidecars are durable. See https://yuruna.link/42f5e921.

.PARAMETER VMName   Name of the stash-service VM. Default: yuruna-stash-service.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$VMName = "yuruna-stash-service"
)

if (-not $PSCmdlet.ShouldProcess($VMName, 'Stop and remove the service VM and withdraw its advertisement')) { return }
& (Join-Path $PSScriptRoot 'Stop-ExtensionService.ps1') -VMName $VMName -ServiceKey 'stash' -Area 'stash-service' -ServiceName 'Stash' -CallerScript $PSCommandPath -Confirm:$false
exit $LASTEXITCODE
