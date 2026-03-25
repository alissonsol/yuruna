terraform {
  required_version = ">= 1.1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 3.74.1"
    }

    random = {
      source  = "hashicorp/random"
      version = "3.1.0"
    }

    local = {
      source  = "hashicorp/local"
      version = "2.1.0"
    }

    null = {
      source  = "hashicorp/null"
      version = "3.1.0"
    }

    kubernetes = {
      version = ">= 2.8.0"
      source  = "hashicorp/kubernetes"
    }
  }
}

