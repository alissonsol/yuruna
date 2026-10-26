# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42d153b3-7923-4e39-9d57-1ec9f89d45ab
# https://registry.terraform.io/providers/hashicorp/azurerm/latest

terraform {
  # Match the portable OpenTofu host floor; standalone guests can use a newer patch.
  required_version = ">= 1.13.1"

  required_providers {
    azurerm = {
      version = "~> 4.80"
      source = "hashicorp/azurerm"
    }
    kubernetes = {
      version = "~> 3.2"
      source = "hashicorp/kubernetes"
    }
    local = {
      version = "~> 2.9"
      source = "hashicorp/local"
    }
    null = {
      version = "~> 3.3"
      source = "hashicorp/null"
    }
    random = {
      version = "~> 3.9"
      source = "hashicorp/random"
    }
  }
}
