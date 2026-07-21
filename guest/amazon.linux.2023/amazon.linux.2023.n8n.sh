#!/bin/bash
# Version: 2026.07.21
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
case "$ARCH" in
  x86_64)
    echo "Environment: x86_64/amd64 (Hyper-V)"
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

# --- REGION: https://yuruna.link/network#defining-yuruna-retry-lib
. /usr/local/lib/yuruna/yuruna-retry.sh
# Baked retry libs may default dnf attempts to a wall-clock bound -- the
# wrapped-apt teardown-hang trap class (the package manager blocks at
# end-of-transaction under a timeout(1) parent). Force unbounded regardless
# of the image's lib vintage; remove once no image predates the lib's
# unbounded default.
export YURUNA_DNF_STALL_TIMEOUT=0

echo ""
echo -e "\e[1;36m==== Node.js ====\e[0m"
# Install the manifest-pinned Node.js major (YURUNA_NODE_MAJOR); n8n needs a current LTS
# NodeSource setup script auto-detects architecture
wget_try -qO- "https://rpm.nodesource.com/setup_${YURUNA_NODE_MAJOR}.x${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" | sudo bash -
dnf_retry sudo dnf -y install nodejs

echo ""
echo -e "\e[1;36m==== n8n ====\e[0m"
sudo npm install -g n8n

echo ""
echo "== Installation Summary =="
echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"
echo "n8n: $(n8n --version)"
