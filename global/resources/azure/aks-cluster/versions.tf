# https://registry.terraform.io/providers/hashicorp/azurerm/latest

terraform {
  required_version = ">= 1.1.5"

  required_providers {
    azurerm = {
      version = "~> 2.95.0"
      source = "hashicorp/azurerm"
    }
    kubernetes = {
      version = "~> 2.8.0"
      source = "hashicorp/kubernetes"
    }
    local = {
      version = "~> 2.1.0"
      source = "hashicorp/local"
    }
    null = {
      version = "~> 3.1.0"
      source = "hashicorp/null"
    }
    random = {
      version = "~> 3.1.0"
      source = "hashicorp/random"
    }
    template = {
      version = "~> 2.2.0"
      source = "hashicorp/template"
    }
  }  
}
