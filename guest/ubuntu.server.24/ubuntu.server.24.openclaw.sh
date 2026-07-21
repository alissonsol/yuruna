#!/bin/bash
# Version: 2026.07.21
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

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
echo -e "\e[1;36m==== Git ====\e[0m"
apt_retry sudo apt-get install git -y

echo ""
echo -e "\e[1;36m==== NVM and Node.js ====\e[0m"
bash << 'EOF'
# NVM installer is idempotent — re-running updates an existing install
export NVM_DIR="$HOME/.nvm"
wget_try -qO- "https://raw.githubusercontent.com/nvm-sh/nvm/v${YURUNA_NVM_VERSION}/install.sh${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" | bash
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

# nvm reinstalls Node gracefully if already present
nvm install "${YURUNA_NODE_MAJOR}"

echo ""
echo -e "\e[1;36m==== OpenClaw ====\e[0m"
npm install -g openclaw@latest

openclaw onboard --install-daemon --non-interactive --accept-risk --workspace ~/openclaw

openclaw doctor --non-interactive
EOF

# Make node, npm, and openclaw available to all users by symlinking to /usr/local/bin
NVM_BIN=$(bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; dirname "$(which node)"')
if [ -n "$NVM_BIN" ]; then
    sudo ln -sf "$NVM_BIN/node" /usr/local/bin/node
    sudo ln -sf "$NVM_BIN/npm" /usr/local/bin/npm
    sudo ln -sf "$NVM_BIN/openclaw" /usr/local/bin/openclaw
fi

echo ""
echo "== Installation Summary =="
echo "Git: $(git --version)"
bash -c '
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    echo "Node.js: $(node --version)"
    echo "npm: $(npm --version)"
    echo "OpenClaw: $(openclaw --version)"
'
