#!/bin/bash
set -euo pipefail

# Non-interactive mode for all installations
export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1


# ===== Detect architecture =====
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
case "$ARCH" in
  x86_64)
    echo "Environment: x86_64/amd64 (Hyper-V)"
    LM_ARCH="x64"
    ;;
  aarch64)
    echo "Environment: aarch64/arm64 (UTM on Apple Silicon)"
    LM_ARCH="arm64"
    ;;
  *)
    echo "WARNING: Unsupported architecture: $ARCH"
    echo "This script supports x86_64 (Hyper-V) and aarch64 (UTM on Apple Silicon)."
    exit 1
    ;;
esac

cd ~/Downloads

echo ""
echo -e "\e[1;36m>>> Updating system packages...\e[0m"
sudo bash /ubuntu.desktop.update.sh
echo -e "\e[1;32m<<< System packages update complete.\e[0m"

echo ""
echo -e "\e[1;36m>>> Installing LM Studio dependencies...\e[0m"
sudo apt install -y curl fuse libfuse2 npm zlib1g-dev
echo -e "\e[1;32m<<< LM Studio dependencies installation complete.\e[0m"

echo ""
echo -e "\e[1;36m>>> Installing LM Studio...\e[0m"
# LM Studio AppImage download differs by architecture
wget -O LM-Studio.AppImage "https://lmstudio.ai/download/latest/linux/$LM_ARCH${YurunaCacheContent:+?nocache=${YurunaCacheContent}}"
chmod a+x LM-Studio.AppImage

echo -e "\e[1;32m<<< LM Studio installation complete.\e[0m"
./LM-Studio.AppImage --no-sandbox
