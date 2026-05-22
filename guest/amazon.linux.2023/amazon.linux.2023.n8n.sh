#!/bin/bash
# Version: 2026.05.22
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

# ===== Detect architecture =====
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

# --- See https://yuruna.link/network#defining-package-manager-retry
dnf_retry() {
  local max_attempts=5 attempt=1 delay=15 rc=0
  while [ $attempt -le $max_attempts ]; do
    if [ $attempt -gt 1 ]; then
      echo ""
      echo ">> dnf_retry: attempt $attempt/$max_attempts for: $*"
    fi
    rc=0; "$@" || rc=$?
    if [ $rc -eq 0 ]; then return 0; fi
    echo "!! dnf_retry: attempt $attempt/$max_attempts failed (rc=$rc): $*"
    if [ $attempt -lt $max_attempts ]; then
      echo "!! dnf_retry: sleeping ${delay}s before retry"
      sleep $delay
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done
  echo "!! dnf_retry: all $max_attempts attempts exhausted for: $*"
  return $rc
}

echo ""
echo -e "\e[1;36m>>> Installing Node.js...\e[0m"
# Install Node.js 22+ (required for n8n)
# NodeSource setup script auto-detects architecture
wget -qO- "https://rpm.nodesource.com/setup_22.x${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" | sudo bash -
dnf_retry sudo dnf -y install nodejs
echo -e "\e[1;32m<<< Node.js installation complete.\e[0m"

echo ""
echo -e "\e[1;36m>>> Installing n8n...\e[0m"
# Install n8n
sudo npm install -g n8n
echo -e "\e[1;32m<<< n8n installation complete.\e[0m"

echo ""
echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"
echo "n8n: $(n8n --version)"
