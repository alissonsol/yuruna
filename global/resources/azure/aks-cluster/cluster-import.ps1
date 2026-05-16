<#PSScriptInfo
.VERSION 2026.05.15
.GUID 42ee5f60-7182-4390-9123-4f506789012a
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.com
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

$resourceGroup = ${env:RESOURCE_GROUP}
$clusterName = ${env:CLUSTER_NAME}
$destinationContext = ${env:DESTINATION_CONTEXT}
az aks get-credentials --resource-group $resourceGroup --name $clusterName --overwrite-existing
kubectl config rename-context $clusterName $destinationContext
