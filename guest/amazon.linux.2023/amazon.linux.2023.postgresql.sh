#!/bin/bash
# Version: 2026.07.14
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

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
# Baked retry libs may default dnf attempts to a wall-clock bound -- the
# wrapped-apt teardown-hang trap class (the package manager blocks at
# end-of-transaction under a timeout(1) parent). Force unbounded regardless
# of the image's lib vintage; remove once no image predates the lib's
# unbounded default.
export YURUNA_DNF_STALL_TIMEOUT=0

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

# PostgreSQL packages are available for both x86_64 and aarch64 via dnf.
# AL2023's native repos cap at PostgreSQL 17 (the Ubuntu guests get 18 via
# the PGDG apt repo, which does not support Amazon Linux).
dnf_retry sudo dnf install -y postgresql17-server postgresql17-contrib

# Clear data directory to allow re-initialization
sudo rm -rf /var/lib/pgsql/data/ 2>/dev/null || true
sudo /usr/bin/postgresql-setup --initdb

sudo systemctl enable postgresql
sudo systemctl start postgresql

echo ""
echo "== Installation Summary =="
echo "PostgreSQL: $(/usr/bin/psql --version)"
