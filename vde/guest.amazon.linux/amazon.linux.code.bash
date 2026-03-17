#!/bin/bash
set -euo pipefail

# ===== Ensure sudo credentials are cached =====
if [[ $EUID -ne 0 ]]; then
   echo ""
   echo "╔════════════════════════════════════════════════════════════╗"
   echo "║  This script requires elevated privileges (sudo)           ║"
   echo "║  Please enter your password when prompted below            ║"
   echo "║  The script will pause until you provide your password     ║"
   echo "╚════════════════════════════════════════════════════════════╝"
   echo ""
   sudo -v || { echo "Failed to obtain sudo privileges."; exit 1; }
   # Keep sudo credentials fresh for long-running installations
   while true; do sudo -n -v 2>/dev/null; sleep 50; done &
   SUDO_KEEPALIVE_PID=$!
   trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT
fi

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

# ===== Install the JDK =====
# Amazon Corretto provides both x86_64 and aarch64 packages
sudo dnf install -y java-21-amazon-corretto-devel
java -version
javac -version
export JAVA_HOME=/etc/alternatives/java_sdk
echo 'export JAVA_HOME=/etc/alternatives/java_sdk' | sudo tee -a /etc/bashrc

# ===== Install .NET SDK =====
# Microsoft RPM repo configuration differs by architecture
case "$ARCH" in
  x86_64)
    # x86_64: Microsoft provides packages via the CentOS 8 repo config
    sudo rpm -Uvh https://packages.microsoft.com/config/centos/8/packages-microsoft-prod.rpm
    sudo dnf -y update
    sudo dnf -y install dotnet-sdk-10.0
    ;;
  aarch64)
    # aarch64: Microsoft provides packages via the CentOS 9 repo config (arm64 support)
    sudo rpm -Uvh https://packages.microsoft.com/config/centos/9/packages-microsoft-prod.rpm
    sudo dnf -y update
    sudo dnf -y install dotnet-sdk-10.0
    ;;
esac
dotnet --version

# ===== Install Git =====
sudo dnf -y install git
git --version

# ===== Install Visual Studio Code =====
# The VS Code yum repo provides both x86_64 and aarch64 packages
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
sudo dnf -y install code

# ===== Show installed versions =====
echo ""
echo "Java: $(javac -version)"
echo "DotNet: $(dotnet --version)"
echo "Git: $(git --version)"
if [ -z "$TMPDIR" ]; then
	TMPDIR=$(mktemp -d)
    export TMPDIR
	echo "TMPDIR not set. Created and set TMPDIR to $TMPDIR"
fi
echo "Visual Studio Code: $(code --version --no-sandbox --user-data-dir "$TMPDIR")"
