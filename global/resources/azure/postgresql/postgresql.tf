resource "azurerm_postgresql_server" "db" {
  name                     = var.uniqueName
  resource_group_name      = var.resourceGroup
  location                 = var.resourceRegion

  administrator_login          = var.adminUsername
  administrator_login_password = var.adminPassword

  sku_name   = "GP_Gen5_4"
  version    = var.dbVersion
  storage_mb                   = 8192

  auto_grow_enabled                 = true
  backup_retention_days             = 7
  geo_redundant_backup_enabled      = false
  infrastructure_encryption_enabled = false
  public_network_access_enabled     = true
  ssl_enforcement_enabled           = true
  ssl_minimal_tls_version_enforced  = "TLS1_2"
}

data "azurerm_postgresql_server" "db" {
  name                     = azurerm_postgresql_server.db.name
  resource_group_name      = var.resourceGroup
}

output "fqdn" {
  value = data.azurerm_postgresql_server.db.fqdn
}
