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

# ===== Detect architecture =====
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

echo ""
echo -e "\e[1;36m>>> Installing NVM and Node.js...\e[0m"
# Install NVM, Node.js, and n8n
# NVM and npm handle architecture automatically
bash << 'EOF'
# Install NVM (installer is idempotent — updates existing installation)
export NVM_DIR="$HOME/.nvm"
wget -qO- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

# Install Node.js (nvm reinstalls gracefully if already present)
nvm install 22

echo ""
echo -e "\e[1;36m>>> Installing n8n...\e[0m"
# Install n8n
npm install -g n8n
echo -e "\e[1;32m<<< n8n installation complete.\e[0m"
EOF

# Make node, npm, and n8n available to all users by symlinking to /usr/local/bin
NVM_BIN=$(bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; dirname "$(which node)"')
if [ -n "$NVM_BIN" ]; then
    sudo ln -sf "$NVM_BIN/node" /usr/local/bin/node
    sudo ln -sf "$NVM_BIN/npm" /usr/local/bin/npm
    sudo ln -sf "$NVM_BIN/n8n" /usr/local/bin/n8n
fi
echo -e "\e[1;32m<<< NVM and Node.js installation complete.\e[0m"

# Show installed versions
echo ""
bash -c '
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    echo "Node.js: $(node --version)"
    echo "npm: $(npm --version)"
    echo "n8n: $(n8n --version)"
'
