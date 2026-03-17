#!/bin/bash
set -euo pipefail

# ===== Ensure sudo credentials are cached =====
if [[ $EUID -ne 0 ]]; then
   echo ""
   echo "╔════════════════════════════════════════════════════════════╗"
   echo "║  This script requires elevated privileges (sudo)           ║"
   echo "║  Please enter your password when prompted below            ║"
   echo "║  The script will pause until you provide your password     ║"
   echo "╚════════════════════════════════════════════════════════════╝"
   echo ""
   sudo -v || { echo "Failed to obtain sudo privileges."; exit 1; }
   # Keep sudo credentials fresh for long-running installations
   while true; do sudo -n -v 2>/dev/null; sleep 50; done &
   SUDO_KEEPALIVE_PID=$!
   trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT
fi

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

echo ""
echo -e "\e[1;36m>>> Installing PostgreSQL...\e[0m"
# Add the official PostgreSQL YUM repository (PGDG) for PostgreSQL 18
# Amazon Linux 2023 is Fedora-based; use the EL-9 repo which is compatible
case "$ARCH" in
  x86_64)
    sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm || true
    ;;
  aarch64)
    sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-aarch64/pgdg-redhat-repo-latest.noarch.rpm || true
    ;;
esac

# Disable the default Amazon Linux PostgreSQL module to avoid conflicts
sudo dnf -qy module disable postgresql 2>/dev/null || true

# Install PostgreSQL 18 server and contrib modules
sudo dnf install -y postgresql18-server postgresql18-contrib

# Stop PostgreSQL if running and wait for full shutdown before cleaning data
if sudo systemctl is-active postgresql-18 &>/dev/null; then
  sudo systemctl stop postgresql-18
  while sudo systemctl is-active postgresql-18 &>/dev/null; do
    echo "Waiting for PostgreSQL to stop..."
    sleep 1
  done
fi
if [ -d /var/lib/pgsql/18/data ] && [ "$(ls -A /var/lib/pgsql/18/data 2>/dev/null)" ]; then
  echo "Note: Clearing existing PostgreSQL data directory for re-initialization"
  sudo rm -rf /var/lib/pgsql/18/data/*
fi
sudo /usr/pgsql-18/bin/postgresql-18-setup initdb

# Enable and start the PostgreSQL service
sudo systemctl enable postgresql-18
sudo systemctl start postgresql-18
echo -e "\e[1;32m<<< PostgreSQL installation complete.\e[0m"

# Show installed version
echo ""
echo "PostgreSQL: $(/usr/pgsql-18/bin/psql --version)"
