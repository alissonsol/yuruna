# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 429cbc42-7de8-4629-8064-7d393faaead2
resource "null_resource" "cluster_context" {
  depends_on = [module.eks]

  triggers = {
    cluster_arn         = module.eks.cluster_arn
    cluster_endpoint    = module.eks.cluster_endpoint
    destination_context = var.destinationContext
  }

  provisioner "local-exec" {
    command     = "./cluster-import.sh"
    interpreter = ["bash"]

    environment = {
      RESOURCE_REGION     = var.resourceRegion
      CLUSTER_NAME        = module.eks.cluster_name
      DESTINATION_CONTEXT = var.destinationContext
    }
  }
}
