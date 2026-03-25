resource "azurerm_storage_account" "default" {
  name                     = var.storageAccountName
  resource_group_name      = var.resourceGroup
  location                 = var.resourceRegion
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_share" "default" {
  name                 = var.storageShareName
  storage_account_name = azurerm_storage_account.default.name
  quota                = var.storageQuota
}

data "azurerm_storage_account" "default" {
  name                     = azurerm_storage_account.default.name
  resource_group_name      = var.resourceGroup
}

output "storageAccountName" {
  value = var.storageAccountName
}

output "storageAccountKey" {
  value = data.azurerm_storage_account.default.primary_access_key
  sensitive = true
}
