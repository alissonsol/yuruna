#!/usr/bin/env bash
# Version: 2026.10.30
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 4262556e-d102-4fd8-9486-e85c4bde8f3e
#
# tofu data "external" hook -- emit the original public-IP address for
# the AKS frontend as {"ip_address":"..."}. Bash + az only, no pwsh:
# a pwsh data-external program here can crash at process startup with a
# FileLoadException on System.Collections.Specialized before any line runs.
set -euo pipefail

# Drain stdin: tofu sends a JSON object on stdin even when `query` is
# empty; same protocol as localhost-registry-check.sh.
cat >/dev/null

az network public-ip list -g "$1" --query "{ip_address : [0].ipAddress}" --output json
