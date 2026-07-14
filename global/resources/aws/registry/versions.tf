# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# https://registry.terraform.io/providers/hashicorp/aws/latest

terraform {
  required_version = ">= 1.12.4"

  required_providers {
    aws = {
      version = "~> 6.54"
      source = "hashicorp/aws"
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
