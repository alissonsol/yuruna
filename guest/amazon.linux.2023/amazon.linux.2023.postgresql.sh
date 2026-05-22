#!/bin/bash
# Version: 2026.05.22
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

# ===== Detect architecture =====
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

# --- See https://yuruna.link/network#defining-package-manager-retry
dnf_retry() {
  local max_attempts=5 attempt=1 delay=15 rc=0
  while [ $attempt -le $max_attempts ]; do
    if [ $attempt -gt 1 ]; then
      echo ""
      echo ">> dnf_retry: attempt $attempt/$max_attempts for: $*"
    fi
    rc=0; "$@" || rc=$?
    if [ $rc -eq 0 ]; then return 0; fi
    echo "!! dnf_retry: attempt $attempt/$max_attempts failed (rc=$rc): $*"
    if [ $attempt -lt $max_attempts ]; then
      echo "!! dnf_retry: sleeping ${delay}s before retry"
      sleep $delay
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done
  echo "!! dnf_retry: all $max_attempts attempts exhausted for: $*"
  return $rc
}

echo ""
echo -e "\e[1;36m>>> Installing PostgreSQL...\e[0m"
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

# Enable and start the PostgreSQL service
sudo systemctl enable postgresql
sudo systemctl start postgresql
echo -e "\e[1;32m<<< PostgreSQL installation complete.\e[0m"

echo ""
echo "PostgreSQL: $(/usr/bin/psql --version)"
