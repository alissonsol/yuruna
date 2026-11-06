#!/bin/bash
# Version: 2026.11.05
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42a0d078-1f5b-4b77-a34e-8bddc226f8d7
# --- REGION: Initialize environment
set -euo pipefail

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
export YURUNA_DNF_STALL_TIMEOUT_SECONDS=0

# --- REGION: Install Git
echo ""
echo -e "\e[1;36m==== Git ====\e[0m"
dnf_retry sudo dnf -y install git

# --- REGION: Install Node.js
echo ""
echo -e "\e[1;36m==== Node.js ====\e[0m"
# Install the manifest-pinned Node.js major (YURUNA_NODE_MAJOR); OpenClaw needs a current LTS
# NodeSource's repository for that major, written the way its setup script
# writes it, with the signing key checked against its pinned fingerprint
# instead of piping that unverified script to a root shell. dnf then verifies
# every package against the key.
declare -F _yuruna_verify_key_fpr >/dev/null || { echo "ERROR: this guest's /usr/local/lib/yuruna/yuruna-retry.sh predates key fingerprint checks; rebuild the guest." >&2; exit 1; }
command -v gpg >/dev/null 2>&1 || dnf_retry sudo dnf install -y gnupg2
_ns_key="$(mktemp)"
trap 'rm -f -- "${_ns_key:-}"' EXIT
curl_retry -fsSL "https://rpm.nodesource.com/gpgkey/ns-operations-public.key${YurunaCacheContent:+?nocache=${YurunaCacheContent}}" -o "$_ns_key"
_yuruna_verify_key_fpr "$_ns_key" 242B813831AF09562B6C46F76B88DA4E3AF28A14 \
    || { echo "NONZERO SCRIPT EXIT: NodeSource rpm key fingerprint mismatch" >&2; exit 1; }
sudo install -d -m 755 /etc/pki/rpm-gpg
sudo install -m 0644 "$_ns_key" /etc/pki/rpm-gpg/nodesource.asc
rm -f -- "$_ns_key"
sudo rpm --import /etc/pki/rpm-gpg/nodesource.asc
sudo rm -f /etc/yum.repos.d/nodesource*.repo
sudo tee /etc/yum.repos.d/nodesource-nodejs.repo > /dev/null <<EOF
[nodesource-nodejs]
name=Node.js Packages for Linux RPM based distros - ${ARCH}
baseurl=https://rpm.nodesource.com/pub_${YURUNA_NODE_MAJOR}.x/nodistro/nodejs/${ARCH}
priority=9
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/nodesource.asc
module_hotfixes=1
EOF
dnf_retry sudo dnf -y install nodejs

# --- REGION: Install OpenClaw
echo ""
echo -e "\e[1;36m==== OpenClaw ====\e[0m"
sudo npm install -g openclaw@latest

# --- REGION: Configure OpenClaw
openclaw onboard --install-daemon --non-interactive --accept-risk --workspace ~/openclaw

openclaw doctor --non-interactive
# The NodeSource RPM puts node and npm under /usr, so the global openclaw link
# already sits on the default PATH and no command-exposure step follows.
# See https://yuruna.link/4213a0b3-0194

# --- REGION: Installation summary
echo ""
echo "== Installation Summary =="
echo "Git: $(git --version)"
echo "Node.js: $(node --version)"
echo "npm: $(npm --version)"
echo "OpenClaw: $(openclaw --version)"
