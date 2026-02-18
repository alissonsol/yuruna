#!/bin/bash
set -euo pipefail

# Non-interactive mode for all installations
export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# ===== Request sudo elevation if not already root =====
if [[ $EUID -ne 0 ]]; then
   echo ""
   echo "╔════════════════════════════════════════════════════════════╗"
   echo "║  This script requires elevated privileges (sudo)           ║"
   echo "║  Please enter your password when prompted below            ║"
   echo "║  The script will pause until you provide your password     ║"
   echo "╚════════════════════════════════════════════════════════════╝"
   echo ""
   sudo "$0" "$@"
   exit $?
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
echo 'export JAVA_HOME=/usr/lib/jvm/default-java' | tee -a /etc/bash.bashrc

# Install .NET Core
sudo apt-get install -y dotnet-sdk-10.0
dotnet --version

# Install Git
sudo apt-get install -y git
git --version

# Install Visual Studio Code
sudo apt-get install -y wget gpg
wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > packages.microsoft.gpg
sudo install -D -o root -g root -m 644 packages.microsoft.gpg /etc/apt/keyrings/packages.microsoft.gpg
echo "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | sudo tee /etc/apt/sources.list.d/vscode.list > /dev/null
rm -f packages.microsoft.gpg
sudo apt-get update -y
sudo apt-get install -y code

# Show installed versions
echo "Java: $(javac -version)"
echo "DotNet: $(dotnet --version)"
echo "Git: $(git --version)"
echo "Visual Studio Code: $(code --version 2>/dev/null || echo 'Run as user to verify')"
