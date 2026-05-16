# Copyright (c) 2019-2026 by Alisson Sol et al.
resource "null_resource" "context" {
  provisioner "local-exec" {
    command = "./context-copy.ps1"
    interpreter = ["pwsh", "-Command"]

    environment = {
      SOURCE_CONTEXT = var.sourceContext
      DESTINATION_CONTEXT = var.destinationContext
    }
  }
}
