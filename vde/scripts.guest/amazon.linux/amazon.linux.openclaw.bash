#!/bin/bash
set -euo pipefail

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

# Install the GUI
dnf update -y
dnf upgrade -y
dnf groupinstall "Desktop" -y

# Install Git
dnf -y install git

# Install Node.js 22+ (required for OpenClaw)
wget -qO- https://rpm.nodesource.com/setup_22.x | bash -
dnf -y install nodejs

# Install OpenClaw
npm install -g openclaw@latest

# Run OpenClaw onboarding (installs daemon with defaults, no interactive prompts)
openclaw onboard --install-daemon --non-interactive --workspace ~/openclaw

# Verify OpenClaw installation (non-interactive to skip prompts)
openclaw doctor --non-interactive

# Show installed versions
echo "Git: $(git --version)"
echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"
echo "OpenClaw: $(openclaw --version)"