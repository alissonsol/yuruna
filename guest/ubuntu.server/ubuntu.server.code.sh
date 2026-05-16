#!/bin/bash
# Version: 2026.05.15
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

# ===== Install .NET SDK =====
echo ""
echo -e "\e[1;36m>>> Installing .NET SDK...\e[0m"
# The dotnet-sdk package is available for both amd64 and arm64 via apt
sudo apt-get install -y dotnet-sdk-10.0
dotnet --version
echo -e "\e[1;32m<<< .NET SDK installation complete.\e[0m"

# ===== Show installed versions =====
echo ""
echo "Java: $(javac -version)"
echo "DotNet: $(dotnet --version)"
echo "Git: $(git --version)"
echo "PowerShell: $(pwsh --version)"
