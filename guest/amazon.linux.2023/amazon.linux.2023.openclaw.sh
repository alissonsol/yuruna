#!/bin/bash
# Version: 2026.06.26
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
echo -e "\e[1;36m==== GUI Desktop ====\e[0m"
dnf_retry sudo dnf update -y
dnf_retry sudo dnf upgrade -y
dnf_retry sudo dnf groupinstall -y "Desktop"

echo ""
echo -e "\e[1;36m==== Git ====\e[0m"
dnf_retry sudo dnf -y install git

echo ""
echo -e "\e[1;36m==== Node.js ====\e[0m"
# Install the manifest-pinned Node.js major (YURUNA_NODE_MAJOR); OpenClaw needs a current LTS
wget_try -qO- "https://rpm.nodesource.com/setup_${YURUNA_NODE_MAJOR}.x${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" | sudo bash -
dnf_retry sudo dnf -y install nodejs

echo ""
echo -e "\e[1;36m==== OpenClaw ====\e[0m"
sudo npm install -g openclaw@latest

openclaw onboard --install-daemon --non-interactive --accept-risk --workspace ~/openclaw

openclaw doctor --non-interactive

echo ""
echo "== Installation Summary =="
echo "Git: $(git --version)"
echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"
echo "OpenClaw: $(openclaw --version)"