#!/bin/bash
# Version: 2026.07.10
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
echo -e "\e[1;36m==== JDK (Amazon Corretto) ====\e[0m"
# Amazon Corretto provides both x86_64 and aarch64 packages
dnf_retry sudo dnf install -y java-21-amazon-corretto-devel
java -version
javac -version
export JAVA_HOME=/etc/alternatives/java_sdk
if ! grep -q 'export JAVA_HOME=/etc/alternatives/java_sdk' /etc/bashrc 2>/dev/null; then
  echo 'export JAVA_HOME=/etc/alternatives/java_sdk' | sudo tee -a /etc/bashrc
fi

echo ""
echo -e "\e[1;36m==== .NET SDK ====\e[0m"
# Use Microsoft's official dotnet-install.sh script instead of RPM repos.
# The CentOS 8/9 repo configs are incompatible with Amazon Linux 2023 (Fedora-based).
# dotnet-install.sh auto-detects architecture (x86_64/aarch64) and works reliably.
# Install libicu dependency required by .NET for globalization support.
dnf_retry sudo dnf install -y libicu
sudo mkdir -p /usr/local/dotnet
curl_retry -sSL "https://dot.net/v1/dotnet-install.sh${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o /tmp/dotnet-install.sh
chmod +x /tmp/dotnet-install.sh
sudo bash /tmp/dotnet-install.sh --channel LTS --install-dir /usr/local/dotnet
rm -f /tmp/dotnet-install.sh

# Make dotnet available system-wide
sudo ln -sf /usr/local/dotnet/dotnet /usr/local/bin/dotnet
if ! grep -q 'export DOTNET_ROOT=/usr/local/dotnet' /etc/bashrc 2>/dev/null; then
  echo 'export DOTNET_ROOT=/usr/local/dotnet' | sudo tee -a /etc/bashrc
fi
dotnet --version || echo "dotnet: version probe failed (non-fatal)"

echo ""
echo -e "\e[1;36m==== VS Code ====\e[0m"
# The VS Code yum repo provides both x86_64 and aarch64 packages
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc 2>/dev/null || true
sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
dnf_retry sudo dnf -y install code

echo ""
echo "== Installation Summary =="
# A benign non-zero from a version probe must never fail provisioning (the script runs under
# set -e); capture stderr too so the summary shows the real version line.
echo "DotNet: $(dotnet --version 2>&1 || echo 'version probe failed')"
echo "Git: $(git --version 2>&1 || echo 'version probe failed')"
echo "Java: $(javac -version 2>&1 || echo 'version probe failed')"
echo "PowerShell: $(pwsh --version 2>&1 || echo 'version probe failed')"
if [ -z "${TMPDIR:-}" ]; then
	TMPDIR=$(mktemp -d)
    export TMPDIR
	echo "TMPDIR not set. Created and set TMPDIR to $TMPDIR"
fi
echo "Visual Studio Code: $(code --version --no-sandbox --user-data-dir "$TMPDIR" 2>&1 || echo 'installed, version probe failed')"
