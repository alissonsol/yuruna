#!/bin/bash
set -euo pipefail

# Non-interactive mode for all installations
export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# ===== Ensure sudo credentials are cached =====
if [[ $EUID -ne 0 ]]; then
   echo ""
   echo "╔════════════════════════════════════════════════════════════╗"
   echo "║  This script requires elevated privileges (sudo)           ║"
   echo "║  Please enter your password when prompted below            ║"
   echo "║  The script will pause until you provide your password     ║"
   echo "╚════════════════════════════════════════════════════════════╝"
   echo ""
   sudo -k
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

echo ""
echo -e "\e[1;36m>>> Installing PostgreSQL...\e[0m"
# Install prerequisites
# PostgreSQL APT repository handles architecture automatically
sudo apt-get install -y postgresql-common

# Set up the official PostgreSQL APT repository
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y

# Update package lists
sudo apt-get update -y

# Install PostgreSQL 18 server and contrib modules
sudo apt-get install -y postgresql-18 postgresql-contrib-18

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

# Enable and start the PostgreSQL service
sudo systemctl enable postgresql
sudo systemctl start postgresql
echo -e "\e[1;32m<<< PostgreSQL installation complete.\e[0m"

# Show installed version
echo ""
echo "PostgreSQL: $(psql --version)"
