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
echo -e "\e[1;36m>>> Installing Git...\e[0m"
# Install Git
sudo apt-get install git -y
echo -e "\e[1;32m<<< Git installation complete.\e[0m"

echo ""
echo -e "\e[1;36m>>> Installing NVM and Node.js...\e[0m"
# Install NVM, Node.js, and OpenClaw
bash << 'EOF'
# Install NVM (installer is idempotent — updates existing installation)
export NVM_DIR="$HOME/.nvm"
wget -qO- "https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh?nocache=$(date +%s)" | bash
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

# Install Node.js (nvm reinstalls gracefully if already present)
nvm install 22

echo ""
echo -e "\e[1;36m>>> Installing OpenClaw...\e[0m"
# Install OpenClaw
npm install -g openclaw@latest

# Run OpenClaw onboarding (installs daemon with defaults, no interactive prompts)
openclaw onboard --install-daemon --non-interactive --accept-risk --workspace ~/openclaw

# Verify OpenClaw installation (non-interactive to skip prompts)
openclaw doctor --non-interactive
echo -e "\e[1;32m<<< OpenClaw installation complete.\e[0m"
EOF

# Make node, npm, and openclaw available to all users by symlinking to /usr/local/bin
NVM_BIN=$(bash -c 'export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"; dirname "$(which node)"')
if [ -n "$NVM_BIN" ]; then
    sudo ln -sf "$NVM_BIN/node" /usr/local/bin/node
    sudo ln -sf "$NVM_BIN/npm" /usr/local/bin/npm
    sudo ln -sf "$NVM_BIN/openclaw" /usr/local/bin/openclaw
fi
echo -e "\e[1;32m<<< NVM and Node.js installation complete.\e[0m"

# Show installed versions
echo ""
echo "Git: $(git --version)"
bash -c '
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
    echo "Node.js: $(node --version)"
    echo "npm: $(npm --version)"
    echo "OpenClaw: $(openclaw --version)"
'
