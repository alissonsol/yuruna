#!/bin/bash
# Version: 2026.09.18
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

# --- REGION: Detect architecture
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
# Architecture does not imply host platform: this lab runs aarch64 guests on
# Hyper-V and UTM. Report virtualization detected inside the guest instead of
# inferring the host from uname.
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

# --- REGION: Install Git
echo ""
echo -e "\e[1;36m==== Git ====\e[0m"
dnf_retry sudo dnf -y install git

# --- REGION: Install Node.js
echo ""
echo -e "\e[1;36m==== Node.js ====\e[0m"
# Install the manifest-pinned Node.js major (YURUNA_NODE_MAJOR); OpenClaw needs a current LTS
wget_try -qO- "https://rpm.nodesource.com/setup_${YURUNA_NODE_MAJOR}.x${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" | sudo bash -
dnf_retry sudo dnf -y install nodejs

# --- REGION: Install OpenClaw
echo ""
echo -e "\e[1;36m==== OpenClaw ====\e[0m"
sudo npm install -g openclaw@latest

# --- REGION: Configure OpenClaw
openclaw onboard --install-daemon --non-interactive --accept-risk --workspace ~/openclaw

openclaw doctor --non-interactive

# --- REGION: Installation summary
echo ""
echo "== Installation Summary =="
echo "Git: $(git --version)"
echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"
echo "OpenClaw: $(openclaw --version)"
