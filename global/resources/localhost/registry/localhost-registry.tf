# Copyright (c) 2019-2026 by Alisson Sol et al.
resource "null_resource" "registry" {
  provisioner "local-exec" {
    command = "./localhost-registry.ps1"
    interpreter = ["pwsh", "-Command"]

    environment = {
    }
  }
}

data "external" "registryLocation" {
  program = [
    "pwsh",
    "./registry-location.ps1",
    "placeholder",
  ]

  query = {
    placeholder = "placeholder" 
  }
}

output "registryLocation" {
  value = data.external.registryLocation.result.registryLocation
}
