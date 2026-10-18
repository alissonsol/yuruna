#!/bin/bash
# Version: 2026.10.14
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
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

# --- REGION: Install PostgreSQL
# See https://yuruna.link/42e220c4-0005
echo ""
echo -e "\e[1;36m==== PostgreSQL ====\e[0m"
# See https://yuruna.link/42e220c4-0005
# AL2023 uses PostgreSQL 17; PGDG does not support Amazon Linux.
dnf_retry sudo dnf install -y postgresql17-server postgresql17-contrib

# --- REGION: Ensure PostgreSQL cluster
# See https://yuruna.link/42e220c4-0005
# The RPM creates no cluster. Preserve initialized data and reject partial or
# incompatible clusters rather than replacing them during a retry.
PG_DATA=/var/lib/pgsql/data
initialize_cluster=true
if sudo test -e "$PG_DATA/PG_VERSION"; then
  installed_major=$(sudo cat "$PG_DATA/PG_VERSION")
  if [ "$installed_major" != 17 ]; then
    echo "PostgreSQL data requires major $installed_major; expected 17. Migrate it explicitly before installation." >&2
    exit 1
  fi
  initialize_cluster=false
elif sudo test -d "$PG_DATA"; then
  existing_entry=$(sudo find "$PG_DATA/." -mindepth 1 -maxdepth 1 -print -quit)
  if [ -n "$existing_entry" ]; then
    echo "PostgreSQL data directory is not empty and has no PG_VERSION; refusing to initialize it." >&2
    exit 1
  fi
fi
if [ "$initialize_cluster" = true ]; then
  sudo /usr/bin/postgresql-setup --initdb
fi

sudo systemctl enable postgresql
sudo systemctl start postgresql

# --- REGION: Installation summary
echo ""
echo "== Installation Summary =="
echo "PostgreSQL: $(/usr/bin/psql --version)"
