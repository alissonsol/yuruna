# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
terraform {
  required_version = ">= 1.12.3"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.54"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.3"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.3"
    }

    kubernetes = {
      version = "~> 3.2"
      source  = "hashicorp/kubernetes"
    }
  }
}
