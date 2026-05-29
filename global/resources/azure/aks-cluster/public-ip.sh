#!/usr/bin/env bash
# Version: 2026.05.29
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# tofu data "external" hook -- emit the original public-IP address for
# the AKS frontend as {"ip_address":"..."}. Bash + az only, no pwsh:
# the prior pwsh data-external program was the FileLoadException trap
# class documented in feedback_pwsh_provisioner_assemblyname_flake.md.
set -euo pipefail

# Drain stdin: tofu sends a JSON object on stdin even when `query` is
# empty; same protocol as localhost-registry-check.sh.
cat >/dev/null

az network public-ip list -g "$1" --query "{ip_address : [0].ipAddress}" --output json
