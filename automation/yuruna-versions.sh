#!/bin/bash
# Version: 2026.10.22
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# Dependency pins for guest provisioning; service-VM seeds carry their own pins.
# Keep each export unquoted and without spaces for Check-DependencyVersion.ps1 parsing.
# --- REGION: https://yuruna.link/4220a755-0008
# Select one stable Kubernetes minor; its package repository supplies
# patch updates without moving the cluster to another minor.
export YURUNA_K8S_MINOR=1.37
# Verify the exact stable release after standalone installation and before
# reusing an installed binary.
export YURUNA_OPENTOFU_VERSION=1.13.1
# An exact Helm release keeps guest provisioning on a repeatable version.
export YURUNA_HELM_VERSION=4.3.1
# A fixed nvm installer keeps installation behavior independent of
# updates within the chosen Node major.
export YURUNA_NVM_VERSION=0.40.8
# Pin an LTS major; installers take updates within that line without
# changing the runtime major used by OpenClaw and n8n.
export YURUNA_NODE_MAJOR=24
