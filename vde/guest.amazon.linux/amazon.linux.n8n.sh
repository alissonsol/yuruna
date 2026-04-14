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
echo -e "\e[1;36m>>> Installing Node.js...\e[0m"
# Install Node.js 22+ (required for n8n)
# NodeSource setup script auto-detects architecture
wget -qO- "https://rpm.nodesource.com/setup_22.x?nocache=$(date +%s)" | sudo bash -
sudo dnf -y install nodejs
echo -e "\e[1;32m<<< Node.js installation complete.\e[0m"

echo ""
echo -e "\e[1;36m>>> Installing n8n...\e[0m"
# Install n8n
sudo npm install -g n8n
echo -e "\e[1;32m<<< n8n installation complete.\e[0m"

# Show installed versions
echo ""
echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"
echo "n8n: $(n8n --version)"
