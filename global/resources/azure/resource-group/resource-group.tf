
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
