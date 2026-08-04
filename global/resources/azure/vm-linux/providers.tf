# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
provider "azurerm" {

  features {}

  # Authentication methods supported by the AzureRM provider:
  # https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs

  # azurerm 4.x no longer reads the subscription from the Azure CLI context;
  # supply it explicitly as subscription_id below or via the
  # ARM_SUBSCRIPTION_ID environment variable before running the deployment.

  # subscription_id = "..."
  # client_id       = "..."
  # client_secret   = "..."
  # tenant_id       = "..."
}
