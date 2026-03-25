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

  role_based_access_control {
    enabled = true
  }

  tags = {
    environment = var.resourceTags
  }

  identity {
    type = "SystemAssigned"
  }

  addon_profile {
    http_application_routing {
      enabled = false
    }
  }  

  # Imports the cluster context to local .kube/config
  provisioner "local-exec" {
    command = "./cluster-import.ps1"
    interpreter = ["pwsh", "-Command"]

    environment = {
      RESOURCE_GROUP = var.resourceGroup
      CLUSTER_NAME = var.clusterName
      DESTINATION_CONTEXT = var.destinationContext
    }
  }
  
}
