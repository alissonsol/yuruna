variable "clusterDnsPrefix" {
  description = "Cluster DNS prefix"
}

variable "clusterName" {
  description = "Cluster name"
}

variable "clusterVersion" {
  description = "Cluster Kubernetes version"
}

variable "nodeCount" {
  description = "Node count (initial)"
}

variable "nodeType" {
  description = "Node type (vm size)"
}

variable "nodeResourceGroup" {
  description = "Node resource group"
}

variable "resourceGroup" {
  description = "Resource group"
}

variable "resourceRegion" {
  description = "Resource region"
}

variable "resourceTags" {
  description = "Resource tags (dev, test, prod, etc.)"
}

variable "destinationContext" {
  description = "Destination cluster context"
}
