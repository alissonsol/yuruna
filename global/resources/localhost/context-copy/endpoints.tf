# Copyright (c) 2019-2026 by Alisson Sol et al.
# Reference: https://registry.terraform.io/providers/hashicorp/external/latest/docs/data-sources/data_source
data "external" "originalIp" {
  program = [
    "pwsh",
    "./localhost-ip.ps1",
    "placeholder",
  ]

  query = {
    placeholder = "placeholder" 
  }
}

data "external" "hostname" {
  program = [
    "pwsh",
    "./localhost-name.ps1",
    "placeholder",
  ]

  query = {
    placeholder = "placeholder" 
  }
}

output "frontendIp" {
  value = data.external.originalIp.result.ip_address 
}

output "clusterIp" {
  value = data.external.originalIp.result.ip_address
}

output "hostname" {
  value = data.external.hostname.result.hostname
}