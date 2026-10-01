<#PSScriptInfo
.VERSION 2026.09.30
.GUID 4269e850-8f14-4f24-8d83-52240f2bc8e0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna pool-control service extension service
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
    Stop the Pool control service and clear its marker.
.DESCRIPTION
    Symmetric with Start-PoolControlServiceVM. Removes runtime/pool-control-service.json (so
    Test.Capability drops the pool-control-service area) and refreshes the registration
    record so the host clears from the dashboard's Extension hosts table. Then
    tears down the pool-control-service VM and every file it owns -- the registry/domain
    entry, the copied disk image, the cloud-init seed, and (UTM) the .utm bundle --
    so the next Start rebuilds from a clean slate. The durable pool state lives on
    the pool NAS, not on the disposable VM disk. When the service was instead run
    with -HostSideProof, the marker carries the host-side pid and that process is
    stopped too. The Go service posts an active:false beacon goodbye on
    SIGTERM/exit, so the aggregator's Extension-hosts row clears from both paths.
.PARAMETER VMName
    Name of the pool-control-service VM. Default: yuruna-pool-control-service.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$VMName = 'yuruna-pool-control-service'
)

if (-not $PSCmdlet.ShouldProcess($VMName, 'Stop and remove the service VM and withdraw its advertisement')) { return }
& (Join-Path $PSScriptRoot 'Stop-ExtensionService.ps1') -VMName $VMName -ServiceKey 'pool-control' -Area 'pool-control-service' -ServiceName 'PoolControl' -CallerScript $PSCommandPath -Confirm:$false
exit $LASTEXITCODE
