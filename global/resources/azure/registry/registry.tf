resource "azurerm_container_registry" "acr" {
  name                     = var.uniqueName
  resource_group_name      = var.resourceGroup
  location                 = var.resourceRegion
  sku                      = "Standard"
  admin_enabled            = true
}

data "azurerm_container_registry" "acr" {
  name                     = azurerm_container_registry.acr.name
  resource_group_name      = var.resourceGroup
}

output "registryLocation" {
  value = data.azurerm_container_registry.acr.login_server
}
