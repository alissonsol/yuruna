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
sudo dnf install -y postgresql17-server postgresql17-contrib

# Clear data directory if non-empty to allow re-initialization
if [ -d /var/lib/pgsql/data ] && [ "$(ls -A /var/lib/pgsql/data 2>/dev/null)" ]; then
  echo "Note: Clearing existing PostgreSQL data directory for re-initialization"
  sudo rm -rf /var/lib/pgsql/data/
fi
sudo /usr/bin/postgresql-setup --initdb

# Enable and start the PostgreSQL service
sudo systemctl enable postgresql
sudo systemctl start postgresql
echo -e "\e[1;32m<<< PostgreSQL installation complete.\e[0m"

# Show installed version
echo ""
echo "PostgreSQL: $(/usr/bin/psql --version)"
