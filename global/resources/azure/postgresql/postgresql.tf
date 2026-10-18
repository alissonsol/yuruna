# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# TLS is enforced by the service itself (the require_secure_transport
# server parameter defaults to on), so no ssl_* arguments exist here.
resource "azurerm_postgresql_flexible_server" "db" {
  name                = var.uniqueName
  resource_group_name = var.resourceGroup
  location            = var.resourceRegion

  administrator_login    = var.adminUsername
  administrator_password = var.adminPassword

  sku_name   = "GP_Standard_D4s_v3"
  version    = var.dbVersion
  storage_mb = 32768 # smallest size Flexible Server accepts

  auto_grow_enabled             = true
  backup_retention_days         = 7
  geo_redundant_backup_enabled  = false
  public_network_access_enabled = true
}

data "azurerm_postgresql_flexible_server" "db" {
  name                = azurerm_postgresql_flexible_server.db.name
  resource_group_name = var.resourceGroup
}

output "fqdn" {
  value = data.azurerm_postgresql_flexible_server.db.fqdn
}
