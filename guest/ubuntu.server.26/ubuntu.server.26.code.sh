#!/bin/bash
# Version: 2026.07.10
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

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
# Baked retry libs may default apt attempts to a wall-clock bound -- the
# wrapped-apt teardown-hang trap class (apt blocks at end-of-transaction
# under a timeout(1) parent). Force unbounded regardless of the image's
# lib vintage; remove once no image predates the lib's unbounded default.
export YURUNA_APT_STALL_TIMEOUT=0

echo ""
echo -e "\e[1;36m==== JDK ====\e[0m"
# default-jdk-headless tracks the distro's current OpenJDK LTS and provides
# both amd64 and arm64 packages (javac included).
apt_retry sudo apt-get install -y default-jdk-headless
java -version
javac -version
if ! grep -q 'export JAVA_HOME=/usr/lib/jvm/default-java' /etc/bash.bashrc 2>/dev/null; then
  echo 'export JAVA_HOME=/usr/lib/jvm/default-java' | sudo tee -a /etc/bash.bashrc
fi

echo ""
echo -e "\e[1;36m==== .NET SDK ====\e[0m"
# The dotnet-sdk package is available for both amd64 and arm64 via apt
apt_retry sudo apt-get install -y dotnet-sdk-10.0
dotnet --version

echo ""
echo -e "\e[1;36m==== VS Code ====\e[0m"
# The VS Code apt repo provides both amd64 and arm64 packages
curl_retry -fsSL "https://packages.microsoft.com/keys/microsoft.asc${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o /tmp/microsoft.asc
sudo install -d -m 755 /etc/apt/keyrings
gpg --dearmor < /tmp/microsoft.asc | sudo tee /etc/apt/keyrings/packages.microsoft.gpg > /dev/null
rm -f /tmp/microsoft.asc
echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
apt_retry sudo apt-get update
apt_retry sudo apt-get install -y code

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
