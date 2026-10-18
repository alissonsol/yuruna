# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
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
