# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42a1bbfa-fef8-4ae9-bf8d-1b7d6d598407

resource "azurerm_resource_group" "default" {
  name     = var.resourceGroup
  location = var.resourceRegion

  tags = {
    environment = var.resourceTags
  }
}

output "id" {
  value = azurerm_resource_group.default.id
}
