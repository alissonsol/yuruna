# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# The workload bash (e.g. ubuntu.server.24.workload.k8s.website.sh)
# starts the registry container with retry + rate-limit diagnostics
# BEFORE invoking Set-Resource. This data source VERIFIES the container
# is up and bubbles a meaningful error otherwise. A null_resource +
# pwsh provisioner is deliberately avoided: spawning pwsh from a
# provisioner is a recurring failure point under pwsh 7.6.1 / .NET 10
# (FileLoadException on System.Collections.Specialized with a
# truncated PublicKeyToken at process startup). The check program is
# POSIX bash + docker inspect, and Set-Resource's planfile-pinned
# apply means it runs at plan time only -- never re-invoked at apply.
data "external" "registry" {
  program = ["bash", "./localhost-registry-check.sh"]
}

locals {
  registryLocation = data.external.registry.result.registryLocation
}

output "registryLocation" {
  value = local.registryLocation
}
