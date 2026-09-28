<#PSScriptInfo
.VERSION 2026.09.27
.GUID 42b38dde-c314-4ae2-9367-ad94b050447f
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

$ErrorActionPreference = 'Stop'
$resourceRegion = ${env:RESOURCE_REGION}
$clusterName = ${env:CLUSTER_NAME}
$destinationContext = ${env:DESTINATION_CONTEXT}
foreach ($required in @('RESOURCE_REGION', 'CLUSTER_NAME', 'DESTINATION_CONTEXT')) {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($required))) {
        throw "$required env var required"
    }
}
aws eks --region $resourceRegion update-kubeconfig --name $clusterName --alias $destinationContext
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
