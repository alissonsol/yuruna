<#PSScriptInfo
.VERSION 0.1
.GUID 42ee5f60-7182-4390-9123-4f506789012a
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2019-2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

$resourceGroup = ${env:RESOURCE_GROUP}
$clusterName = ${env:CLUSTER_NAME}
$destinationContext = ${env:DESTINATION_CONTEXT}
az aks get-credentials --resource-group $resourceGroup --name $clusterName --overwrite-existing
kubectl config rename-context $clusterName $destinationContext
