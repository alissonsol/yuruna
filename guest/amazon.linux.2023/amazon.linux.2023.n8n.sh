#!/bin/bash
# Version: 2026.10.22
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# --- REGION: Initialize environment
set -euo pipefail

# --- REGION: Detect architecture
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
# See https://yuruna.link/42e220c4-0005
# Detect virtualization independently from CPU architecture.
echo "Detected virtualization: $(systemd-detect-virt 2>/dev/null || echo unknown)"
case "$ARCH" in
  x86_64)
    echo "Environment: x86_64/amd64"
    ;;
  aarch64)
    echo "Environment: aarch64/arm64"
    ;;
  *)
    echo "WARNING: Unsupported architecture: $ARCH"
    echo "This script supports x86_64/amd64 and aarch64/arm64."
    exit 1
    ;;
esac

# --- REGION: Load retry helpers
# See https://yuruna.link/4220a755-0003
. /usr/local/lib/yuruna/yuruna-retry.sh
# --- REGION: https://yuruna.link/4220a755-0005
# Re-asserted here because a baked retry lib may still carry a wall-clock bound.
export YURUNA_DNF_STALL_TIMEOUT_SECONDS=0

# --- REGION: Install Node.js
echo ""
echo -e "\e[1;36m==== Node.js ====\e[0m"
# Install the manifest-pinned Node.js major (YURUNA_NODE_MAJOR); n8n needs a current LTS
# NodeSource setup script auto-detects architecture
wget_try -qO- "https://rpm.nodesource.com/setup_${YURUNA_NODE_MAJOR}.x${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" | sudo bash -
dnf_retry sudo dnf -y install nodejs

# --- REGION: Install n8n
echo ""
echo -e "\e[1;36m==== n8n ====\e[0m"
sudo npm install -g n8n
# The NodeSource RPM puts node and npm under /usr, so the global n8n link already
# sits on the default PATH and no command-exposure step follows.
# See https://yuruna.link/4213a0b3-0194

# --- REGION: Installation summary
echo ""
echo "== Installation Summary =="
echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"
echo "n8n: $(n8n --version)"
