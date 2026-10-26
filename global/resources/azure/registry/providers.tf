# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42b3d7b4-aac3-439d-904c-8adf32fe4c4b
provider "azurerm" {

  features {}

  # Authentication methods supported by the AzureRM provider:
  # https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs

  # The provider requires a subscription ID: set ARM_SUBSCRIPTION_ID in
  # the environment (it is no longer inferred from the Azure CLI login).

  # subscription_id = "..."
  # client_id       = "..."
  # client_secret   = "..."
  # tenant_id       = "..."
}
