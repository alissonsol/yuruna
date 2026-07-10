# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
provider "azurerm" {

  features {}

  # More information on the authentication methods supported by
  # the AzureRM Provider can be found here:
  # https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs

  # azurerm 4.x no longer reads the Azure CLI's active subscription;
  # the subscription ID must be supplied via subscription_id below or
  # the ARM_SUBSCRIPTION_ID environment variable.

  # subscription_id = "..."
  # client_id       = "..."
  # client_secret   = "..."
  # tenant_id       = "..."
}
