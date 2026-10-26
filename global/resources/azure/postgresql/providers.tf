# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42bdf6c1-6ec4-4aef-bc5f-29b246bf06fc
provider "azurerm" {

  features {}

  # Authentication methods supported by the AzureRM provider:
  # https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs

  # The provider requires a subscription ID: set subscription_id below
  # or export the ARM_SUBSCRIPTION_ID environment variable.
  # subscription_id = "..."
  # client_id       = "..."
  # client_secret   = "..."
  # tenant_id       = "..."
}
