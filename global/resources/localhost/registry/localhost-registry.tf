# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# --- REGION: https://yuruna.link/definition#defining-the-tofu-external-hook-shell-choice
# The workload bash starts the registry container BEFORE Set-Resource runs; this data source only verifies it.
data "external" "registry" {
  program = ["bash", "./localhost-registry-check.sh"]
}

locals {
  registryLocation = data.external.registry.result.registryLocation
}

output "registryLocation" {
  value = local.registryLocation
}
