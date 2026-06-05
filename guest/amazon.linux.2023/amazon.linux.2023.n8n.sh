#!/bin/bash
# Version: 2026.06.05
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
case "$ARCH" in
  x86_64)
    echo "Environment: x86_64 (Hyper-V)"
    ;;
  aarch64)
    echo "Environment: aarch64/arm64 (UTM on Apple Silicon)"
    ;;
  *)
    echo "WARNING: Unsupported architecture: $ARCH"
    echo "This script supports x86_64 (Hyper-V) and aarch64 (UTM on Apple Silicon)."
    exit 1
    ;;
esac

# --- See https://yuruna.link/network#defining-yuruna-retry-lib
. /usr/local/lib/yuruna/yuruna-retry.sh

echo ""
echo -e "\e[1;36m==== Node.js ====\e[0m"
# Install Node.js 22+ (required for n8n)
# NodeSource setup script auto-detects architecture
wget -qO- "https://rpm.nodesource.com/setup_22.x${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" | sudo bash -
dnf_retry sudo dnf -y install nodejs

echo ""
echo -e "\e[1;36m==== n8n ====\e[0m"
sudo npm install -g n8n

echo ""
echo "== Installation Summary =="
echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"
echo "n8n: $(n8n --version)"
