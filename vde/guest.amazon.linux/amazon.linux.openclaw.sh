#!/bin/bash
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

echo ""
echo -e "\e[1;36m>>> Installing Desktop GUI...\e[0m"
# Install the GUI
sudo dnf update -y
sudo dnf upgrade -y
sudo dnf groupinstall -y "Desktop"
echo -e "\e[1;32m<<< Desktop GUI installation complete.\e[0m"

echo ""
echo -e "\e[1;36m>>> Installing Git...\e[0m"
# Install Git
sudo dnf -y install git
echo -e "\e[1;32m<<< Git installation complete.\e[0m"

echo ""
echo -e "\e[1;36m>>> Installing Node.js...\e[0m"
# Install Node.js 22+ (required for OpenClaw)
wget -qO- "https://rpm.nodesource.com/setup_22.x?nocache=$(date +%s)" | sudo bash -
sudo dnf -y install nodejs
echo -e "\e[1;32m<<< Node.js installation complete.\e[0m"

echo ""
echo -e "\e[1;36m>>> Installing OpenClaw...\e[0m"
# Install OpenClaw
sudo npm install -g openclaw@latest

# Run OpenClaw onboarding (installs daemon with defaults, no interactive prompts)
openclaw onboard --install-daemon --non-interactive --accept-risk --workspace ~/openclaw

# Verify OpenClaw installation (non-interactive to skip prompts)
openclaw doctor --non-interactive
echo -e "\e[1;32m<<< OpenClaw installation complete.\e[0m"

# Show installed versions
echo ""
echo "Git: $(git --version)"
echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"
echo "OpenClaw: $(openclaw --version)"