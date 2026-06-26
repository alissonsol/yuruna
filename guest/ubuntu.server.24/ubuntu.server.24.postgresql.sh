#!/bin/bash
# Version: 2026.06.26
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

# Non-interactive mode for all installations
export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

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

# --- See https://yuruna.link/network#defining-yuruna-retry-lib
. /usr/local/lib/yuruna/yuruna-retry.sh

echo ""
echo -e "\e[1;36m==== PostgreSQL ====\e[0m"
# PostgreSQL APT repository handles architecture automatically
apt_retry sudo apt-get install -y postgresql-common

sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y

apt_retry sudo apt-get update -y

apt_retry sudo apt-get install -y postgresql-18 postgresql-contrib-18

# Stop PostgreSQL if running and wait for full shutdown before re-creating cluster
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

echo ""
echo "PostgreSQL: $(psql --version)"
