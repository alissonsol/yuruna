#!/bin/bash
# Version: 2026.09.18
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

# --- REGION: Detect architecture
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
# Architecture does not imply host platform: this lab runs aarch64 guests on
# Hyper-V and UTM. Report virtualization detected inside the guest instead of
# inferring the host from uname.
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

# --- REGION: Install PostgreSQL
# See https://yuruna.link/42e220c4-0005
echo ""
echo -e "\e[1;36m==== PostgreSQL ====\e[0m"
# The RPM does not start a cluster, so stop any prior service before initialization.
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

# --- REGION: Installation summary
echo ""
echo "== Installation Summary =="
echo "PostgreSQL: $(/usr/bin/psql --version)"
