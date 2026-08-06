#!/bin/bash
# Version: 2026.08.06
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# --- REGION: https://yuruna.link/network#defining-yuruna-versions-pins
# Source of truth for the dependency versions the guest provisioning scripts
# under guest/ install; they reference these variables, never the numbers.
# The service-VM cloud-init seeds (host/vmconfig/*-service.base.user-data)
# are not handed this file and pin their own dependencies inline. Keep it
# POSIX-simple -- one `export KEY=value` per line, unquoted, no spaces --
# so Check-DependencyVersion.ps1 can parse it with a line regex instead of
# sourcing a shell. The linked section explains each pin and how to bump it.

export YURUNA_K8S_MINOR=1.36
export YURUNA_OPENTOFU_VERSION=1.12.5
export YURUNA_HELM_VERSION=4.2.3
export YURUNA_NVM_VERSION=0.40.6
export YURUNA_NODE_MAJOR=24
