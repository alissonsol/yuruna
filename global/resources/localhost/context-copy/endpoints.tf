# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# Reference: https://registry.terraform.io/providers/hashicorp/external/latest/docs/data-sources/data_source
# The external programs derive everything from local DNS APIs; they read
# neither argv nor stdin, so the query is the empty object the provider
# still requires to send on stdin.
data "external" "originalIp" {
  program = [
    "pwsh",
    "./localhost-ip.ps1",
  ]

  query = {}
}

data "external" "hostname" {
  program = [
    "pwsh",
    "./localhost-name.ps1",
  ]

  query = {}
}

locals {
  # frontend and cluster addresses are the same host address on localhost.
  host_ip = data.external.originalIp.result.ip_address
}

output "frontendIp" {
  value = local.host_ip
}

output "clusterIp" {
  value = local.host_ip
}

output "hostname" {
  value = data.external.hostname.result.hostname
}
