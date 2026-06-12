#!/bin/bash
# Version: 2026.06.12
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

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

# --- See https://yuruna.link/network#defining-yuruna-retry-lib
. /usr/local/lib/yuruna/yuruna-retry.sh

echo ""
echo -e "\e[1;36m==== PostgreSQL ====\e[0m"
# Stop PostgreSQL if running and wait for full shutdown before re-initializing
if sudo systemctl is-active postgresql &>/dev/null; then
  sudo systemctl stop postgresql
  while sudo systemctl is-active postgresql &>/dev/null; do
    echo "Waiting for PostgreSQL to stop..."
    sleep 1
  done
fi

# Install PostgreSQL 17 server and contrib modules
# PostgreSQL packages are available for both x86_64 and aarch64 via dnf
dnf_retry sudo dnf install -y postgresql17-server postgresql17-contrib

# Clear data directory to allow re-initialization
sudo rm -rf /var/lib/pgsql/data/ 2>/dev/null || true
sudo /usr/bin/postgresql-setup --initdb

sudo systemctl enable postgresql
sudo systemctl start postgresql

echo ""
echo "== Installation Summary =="
echo "PostgreSQL: $(/usr/bin/psql --version)"
