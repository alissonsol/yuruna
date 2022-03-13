$resourceGroup = ${env:RESOURCE_GROUP}
$clusterName = ${env:CLUSTER_NAME}
$destinationContext = ${env:DESTINATION_CONTEXT}
az aks get-credentials --resource-group $resourceGroup --name $clusterName --overwrite-existing
kubectl config rename-context $clusterName $destinationContext
