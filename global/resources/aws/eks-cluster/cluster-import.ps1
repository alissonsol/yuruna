<#PSScriptInfo
.VERSION 2026.07.21
.GUID 42dd4e5f-6071-4289-8012-3e4f50678901
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

$resourceRegion= ${env:RESOURCE_REGION}
$clusterName = ${env:CLUSTER_NAME}
$destinationContext = ${env:DESTINATION_CONTEXT}
aws eks --region $resourceRegion update-kubeconfig --name $clusterName
kubectl config rename-context $clusterName $destinationContext
