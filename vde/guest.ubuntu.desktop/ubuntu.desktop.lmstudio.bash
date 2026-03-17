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

cd ~/Downloads
sudo bash /ubuntu.desktop.update.bash
sudo apt install -y curl fuse libfuse2 npm zlib1g-dev
case "$(uname -m)" in
    aarch64) ARCH="arm64" ;;
    x86_64)  ARCH="x64"   ;;
    i386|i686) ARCH="x86" ;;
    *)
        echo "Unsupported architecture: $(uname -m)"
        exit 1
        ;;
esac
echo "Target architecture: $ARCH"
wget -O LM-Studio.AppImage "https://lmstudio.ai/download/latest/linux/$ARCH"
chmod a+x LM-Studio.AppImage
sudo bash /ubuntu.desktop.update.bash
./LM-Studio.AppImage --no-sandbox
