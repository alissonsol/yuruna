#!/bin/bash
set -euo pipefail

# Non-interactive mode for all installations
export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

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

# Determine the real user (even when running with sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# Install the JDK
sudo apt-get update -y
sudo apt-get install -y default-jdk
java -version
javac -version
export JAVA_HOME=/usr/lib/jvm/default-java
echo 'export JAVA_HOME=/usr/lib/jvm/default-java' | sudo tee -a /etc/bash.bashrc

# Install .NET Core
sudo apt-get install -y dotnet-sdk-10.0
dotnet --version

# Install Git
sudo apt-get install -y git
git --version

# Install Visual Studio Code
# The dotnet-sdk package may have added a Microsoft repo with signed-by=/usr/share/keyrings/microsoft.gpg.
# Use that same key path for the VS Code repo to avoid "Conflicting values set for option Signed-By" errors.
sudo apt-get install -y wget gpg
MSFT_KEY="/usr/share/keyrings/microsoft.gpg"
if [ ! -f "$MSFT_KEY" ]; then
  MSFT_KEY="/etc/apt/keyrings/packages.microsoft.gpg"
  wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
  sudo install -D -o root -g root -m 644 packages.microsoft.gpg "$MSFT_KEY"
  rm -f packages.microsoft.gpg
fi
echo "deb [arch=amd64,arm64,armhf signed-by=${MSFT_KEY}] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
sudo apt-get update -y
sudo apt-get install -y code

# Install PowerShell
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  PS_ARCH="x64" ;;
  aarch64) PS_ARCH="arm64" ;;
  armv7l)  PS_ARCH="arm32" ;;
  *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac
wget -q -O /tmp/powershell.tar.gz \
  "https://github.com/PowerShell/PowerShell/releases/download/v7.5.4/powershell-7.5.4-linux-${PS_ARCH}.tar.gz"
sudo mkdir -p /opt/microsoft/powershell/7
sudo tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7
sudo chmod +x /opt/microsoft/powershell/7/pwsh
sudo ln -s /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh
pwsh --version

# Show installed versions
echo ""
echo "Java: $(javac -version)"
echo "DotNet: $(dotnet --version)"
echo "Git: $(git --version)"
echo "Visual Studio Code: $(code --version 2>/dev/null || echo 'Run as user to verify')"
echo "PowerShell: $(pwsh --version)"
