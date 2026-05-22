#!/bin/bash
# Version: 2026.05.22
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

# Non-interactive mode for all installations
export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# Determine the real user (even when running with sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# ===== Detect architecture =====
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

# --- See https://yuruna.link/network#defining-package-manager-retry
apt_retry() {
    local max_attempts=5 attempt=1 delay=15 rc=0
    while [ $attempt -le $max_attempts ]; do
        if [ $attempt -gt 1 ]; then
            echo ""
            echo ">> apt_retry: attempt $attempt/$max_attempts for: $*"
        fi
        rc=0; "$@" || rc=$?
        if [ $rc -eq 0 ]; then return 0; fi
        echo "!! apt_retry: attempt $attempt/$max_attempts failed (rc=$rc): $*"
        if [ $attempt -lt $max_attempts ]; then
            echo "!! apt_retry: sleeping ${delay}s before retry"
            sleep $delay
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done
    echo "!! apt_retry: all $max_attempts attempts exhausted for: $*"
    return $rc
}

# ===== Install .NET SDK =====
echo ""
echo -e "\e[1;36m>>> Installing .NET SDK...\e[0m"
# The dotnet-sdk package is available for both amd64 and arm64 via apt
apt_retry sudo apt-get install -y dotnet-sdk-10.0
dotnet --version
echo -e "\e[1;32m<<< .NET SDK installation complete.\e[0m"

# ===== Show installed versions =====
echo ""
echo "=== Installation Summary ==="
echo "DotNet: $(dotnet --version)"
echo "Git: $(git --version)"
echo "PowerShell: $(pwsh --version)"
