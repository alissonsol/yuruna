#!/bin/bash
# Version: 2026.09.24
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

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

# The deb post-install starts a cluster, so stop PostgreSQL after installation.
if sudo systemctl is-active postgresql &>/dev/null; then
  sudo systemctl stop postgresql
  while sudo systemctl is-active postgresql &>/dev/null; do
    echo "Waiting for PostgreSQL to stop..."
    sleep 1
  done
fi
if sudo pg_lsclusters -h 2>/dev/null | grep -q '18'; then
  echo "Note: Dropping existing PostgreSQL 18 cluster for re-initialization"
  sudo pg_dropcluster --stop 18 main 2>/dev/null || true
fi
sudo pg_createcluster 18 main --start

sudo systemctl enable postgresql
sudo systemctl start postgresql

# --- REGION: Installation summary
echo ""
echo "== Installation Summary =="
echo "PostgreSQL: $(psql --version)"
