# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42a1e5f5-c259-4de6-b0e5-d1b88cfb1b11
provider "azurerm" {

  features {}

  # Authentication methods supported by the AzureRM provider:
  # https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs

  # azurerm 4.x no longer reads the Azure CLI's active subscription;
  # the subscription ID must be supplied via subscription_id below or
  # the ARM_SUBSCRIPTION_ID environment variable.

  # subscription_id = "..."
  # client_id       = "..."
  # client_secret   = "..."
  # tenant_id       = "..."
}
