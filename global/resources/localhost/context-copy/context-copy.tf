# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# --- REGION: https://yuruna.link/42fa6f45-000f
# Copy a kube context bundle from var.sourceContext under var.destinationContext into ~/.kube/config.
data "external" "context_copy" {
  program = ["bash", "./context-copy.sh"]

  query = {
    sourceContext      = var.sourceContext
    destinationContext = var.destinationContext
  }
}
