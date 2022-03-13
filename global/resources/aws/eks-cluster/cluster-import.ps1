$resourceRegion= ${env:RESOURCE_REGION}
$clusterName = ${env:CLUSTER_NAME}
$destinationContext = ${env:DESTINATION_CONTEXT}
aws eks --region $resourceRegion update-kubeconfig --name $clusterName
kubectl config rename-context $clusterName $destinationContext
