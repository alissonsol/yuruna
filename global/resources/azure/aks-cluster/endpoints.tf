resource "azurerm_public_ip" "frontendIp" {
  name                = format("%s.frontendIp", var.resourceGroup) 
  resource_group_name = azurerm_kubernetes_cluster.default.node_resource_group
  location            = azurerm_kubernetes_cluster.default.location
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = var.clusterName
}

data "azurerm_public_ip" "frontendIp" {
  name                     = azurerm_public_ip.frontendIp.name
  resource_group_name      = azurerm_public_ip.frontendIp.resource_group_name
}

# Reference: https://registry.terraform.io/providers/hashicorp/external/latest/docs/data-sources/data_source
data "external" "originalIp" {
  program = [
    "pwsh",
    "./public-ip.ps1",
    azurerm_kubernetes_cluster.default.node_resource_group,
  ]

  query = {
    placeholder = data.azurerm_public_ip.frontendIp.ip_address   
  }
}

output "frontendIp" {
  value = data.azurerm_public_ip.frontendIp.ip_address
}

output "clusterIp" {
  value = data.external.originalIp.result.ip_address
}

output "hostname" {
  value = data.azurerm_public_ip.frontendIp.fqdn
}
