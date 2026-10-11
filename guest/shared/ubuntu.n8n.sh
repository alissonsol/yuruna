#!/bin/bash
# Version: 2026.10.11
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# --- REGION: Initialize environment
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# --- REGION: Detect architecture
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
# See https://yuruna.link/42e220c4-0005
# Detect virtualization independently from CPU architecture.
echo "Detected virtualization: $(systemd-detect-virt 2>/dev/null || echo unknown)"
case "$ARCH" in
  x86_64)
    echo "Environment: x86_64/amd64"
    ;;
  aarch64)
    echo "Environment: aarch64/arm64"
    ;;
  *)
    echo "WARNING: Unsupported architecture: $ARCH"
    echo "This script supports x86_64/amd64 and aarch64/arm64."
    exit 1
    ;;
esac

# --- REGION: Load retry helpers
# See https://yuruna.link/4220a755-0003
. /usr/local/lib/yuruna/yuruna-retry.sh
# --- REGION: https://yuruna.link/4220a755-0005
# Re-asserted here because a baked retry lib may still carry a wall-clock bound.
export YURUNA_APT_STALL_TIMEOUT_SECONDS=0

# --- REGION: Install Node.js
echo ""
echo -e "\e[1;36m==== Node.js ====\e[0m"
# Installed via nvm; nvm and npm handle architecture automatically
bash << 'EOF'
set -eo pipefail
# NVM installer is idempotent -- re-running updates an existing install
export NVM_DIR="$HOME/.nvm"
wget_try -qO- "https://raw.githubusercontent.com/nvm-sh/nvm/v${YURUNA_NVM_VERSION}/install.sh${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" | bash
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" --no-use
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

# nvm reinstalls Node gracefully if already present
nvm install "${YURUNA_NODE_MAJOR}"
# Future workload shells must select the same major when NVM initializes.
nvm alias default "${YURUNA_NODE_MAJOR}"

# --- REGION: Install n8n
echo ""
echo -e "\e[1;36m==== n8n ====\e[0m"
npm install -g n8n
EOF

# --- REGION: Expose installed commands
# See https://yuruna.link/42e220c4-000e
# Select the installed major explicitly; NVM's saved default may name another version.
NVM_BIN=$(bash -eo pipefail -c '
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] || { echo "NVM initialization file is missing" >&2; exit 1; }
    . "$NVM_DIR/nvm.sh" --no-use
    NODE_PATH=$(nvm which "${YURUNA_NODE_MAJOR}")
    [ -x "$NODE_PATH" ] || { echo "Selected Node.js executable is missing: $NODE_PATH" >&2; exit 1; }
    dirname "$NODE_PATH"
')
for executable in node npm n8n; do
    [ -x "$NVM_BIN/$executable" ] || { echo "Installed executable is missing: $NVM_BIN/$executable" >&2; exit 1; }
done
sudo ln -sf "$NVM_BIN/node" /usr/local/bin/node
sudo ln -sf "$NVM_BIN/npm" /usr/local/bin/npm
sudo ln -sf "$NVM_BIN/n8n" /usr/local/bin/n8n

# --- REGION: Installation summary
echo ""
echo "== Installation Summary =="
bash -eo pipefail -c '
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" --no-use
    nvm use --silent "${YURUNA_NODE_MAJOR}"
    echo "Node.js: $(node --version)"
    echo "npm: $(npm --version)"
    echo "n8n: $(n8n --version)"
'
