# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Copy a kube context bundle (cluster + user + context) from
# var.sourceContext under var.destinationContext into ~/.kube/config.
# Uses a data "external" + bash script rather than a null_resource +
# provisioner "local-exec" {interpreter = pwsh} (same rationale as
# localhost-registry.tf) -- pwsh 7.6.x / .NET 10 spawn is a recurring
# FileLoadException flake on System.Collections.Specialized with a
# truncated PublicKeyToken. Set-Resource's planfile-pinned apply means
# this runs at plan time only -- never re-invoked at apply.
data "external" "context_copy" {
  program = ["bash", "./context-copy.sh"]

  query = {
    sourceContext      = var.sourceContext
    destinationContext = var.destinationContext
  }
}
