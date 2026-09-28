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
  description = "Number of schedulable x86-64 worker nodes."
  type        = number

  validation {
    condition     = var.nodeCount >= 1 && floor(var.nodeCount) == var.nodeCount
    error_message = "nodeCount must be a positive whole number."
  }
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
  description = "REQUIRED. Comma-separated CIDR allow-list for the Kubernetes API server PUBLIC endpoint. MUST include the Yuruna host's public egress IP as a /32 (e.g. \"203.0.113.5/32\") or the workload pipeline's first kubectl/helm call is locked out; add admin/VPN ranges as needed. No default on purpose: a deploy that omits it fails at plan time instead of silently exposing the control plane to 0.0.0.0/0. Set it in resources.yml globalVariables."
  type        = string

  validation {
    condition = (
      length([for c in split(",", var.apiServerAuthorizedCidrs) : trimspace(c) if trimspace(c) != ""]) > 0 &&
      alltrue([for c in split(",", var.apiServerAuthorizedCidrs) : can(cidrhost(trimspace(c), 0)) if trimspace(c) != ""])
    )
    error_message = "apiServerAuthorizedCidrs must contain at least one valid CIDR; an empty allow-list would expose the public API server."
  }
}
