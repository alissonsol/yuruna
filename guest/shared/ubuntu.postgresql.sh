#!/bin/bash
# Version: 2026.10.22
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

# --- REGION: Install PostgreSQL
# See https://yuruna.link/42e220c4-0005
echo ""
echo -e "\e[1;36m==== PostgreSQL ====\e[0m"
# PostgreSQL APT repository handles architecture automatically
apt_retry sudo apt-get install -y postgresql-common

sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y

apt_retry sudo apt-get update -y

# PostgreSQL major is pinned deliberately: a major upgrade needs a dump/restore
# migration, so never float this to a newer major via an unattended apt-get.
apt_retry sudo apt-get install -y postgresql-18 postgresql-contrib-18

# --- REGION: Ensure PostgreSQL cluster
# Package installation normally creates the cluster. Preserve its data on retries;
# stopping the aggregate unit does not make a subsequent drop/recreate atomic.
clusters=$(sudo pg_lsclusters --no-header)
if ! awk '$1 == "18" && $2 == "main" { found = 1 } END { exit !found }' <<< "$clusters"; then
  sudo pg_createcluster 18 main
fi

# The aggregate service can be active while its cluster is stopped or failed.
sudo systemctl enable postgresql
sudo systemctl start postgresql@18-main

# --- REGION: Installation summary
echo ""
echo "== Installation Summary =="
echo "PostgreSQL: $(psql --version)"
