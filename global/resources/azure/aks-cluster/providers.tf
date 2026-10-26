# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42440a16-02d2-4bee-b748-d3727fee62ea
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
