# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# https://registry.terraform.io/providers/hashicorp/azurerm/latest

terraform {
  # Floor mirrors YURUNA_OPENTOFU_VERSION (automation/yuruna-versions.sh); bump both together.
  required_version = ">= 1.12.5"

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
