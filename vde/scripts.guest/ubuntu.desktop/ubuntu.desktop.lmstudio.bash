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
