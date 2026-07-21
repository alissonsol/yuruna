# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
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

variable "apiServerAuthorizedCidrs" {
  description = "REQUIRED. Comma-separated CIDR allow-list for the Kubernetes API server. MUST include the Yuruna host's public egress IP as a /32 (e.g. \"203.0.113.5/32\") or the workload pipeline's first kubectl/helm call is locked out; add admin/VPN ranges comma-separated. No default on purpose: a deploy that omits it fails at plan time instead of silently leaving the API server unrestricted. Set it in resources.yml globalVariables."
  type        = string
}
