# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42d8ccee-fb9d-4910-b591-3207e7268557
output "clusterName" {
  value = module.eks.cluster_name
}

output "clusterEndpoint" {
  description = "Kubernetes control-plane API endpoint; not a workload ingress address."
  value       = module.eks.cluster_endpoint
}

output "destinationContext" {
  value      = var.destinationContext
  depends_on = [null_resource.cluster_context]
}
