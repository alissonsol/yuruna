# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.

terraform {
  # Floor mirrors YURUNA_OPENTOFU_VERSION (automation/yuruna-versions.sh); bump both together.
  # No required_providers on purpose: Yuruna.Resource carries .terraform.lock.hcl
  # across runs, and a constraint added later than a host's lock breaks `tofu init`
  # on that host until `-upgrade` runs. The lock file already pins the provider.
  required_version = ">= 1.12.5"
}
