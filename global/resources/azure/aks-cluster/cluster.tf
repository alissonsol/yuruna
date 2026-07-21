# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
locals {
  # Parse the comma-separated CIDR allow-list (a single tfvars string, since
  # the pipeline emits every variable as a quoted string) into the list azurerm
  # wants. trimspace + drop-empties tolerates trailing commas/spaces.
  authorized_cidrs = [for c in split(",", var.apiServerAuthorizedCidrs) : trimspace(c) if trimspace(c) != ""]
}

resource "azurerm_kubernetes_cluster" "default" {
  name                = var.clusterName
  location            = var.resourceRegion
  resource_group_name = var.resourceGroup
  dns_prefix          = var.clusterDnsPrefix
  kubernetes_version  = var.clusterVersion
  node_resource_group = var.nodeResourceGroup

  default_node_pool {
    name            = "default"
    node_count      = var.nodeCount
    vm_size         = var.nodeType
    os_disk_size_gb = 30
  }

  role_based_access_control_enabled = true

  # Restrict the public API server to the pinned admin CIDRs. Without an
  # api_server_access_profile the API server is reachable from the whole
  # internet. MUST include the Yuruna host's egress /32 or the deploy's kubectl
  # is locked out.
  api_server_access_profile {
    authorized_ip_ranges = local.authorized_cidrs
  }

  tags = {
    environment = var.resourceTags
  }

  identity {
    type = "SystemAssigned"
  }

  http_application_routing_enabled = false

  # Imports the cluster context to local .kube/config. Bash + az/kubectl
  # instead of pwsh; matches the localhost-registry-check.sh pattern that
  # avoids the FileLoadException trap class
  # (feedback_pwsh_provisioner_assemblyname_flake.md).
  provisioner "local-exec" {
    command = "./cluster-import.sh"
    interpreter = ["bash"]

    environment = {
      RESOURCE_GROUP = var.resourceGroup
      CLUSTER_NAME = var.clusterName
      DESTINATION_CONTEXT = var.destinationContext
    }
  }

}
