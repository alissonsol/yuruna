#!/bin/bash
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

# Clear data directory to allow re-initialization
sudo rm -rf /var/lib/pgsql/data/ 2>/dev/null || true
sudo /usr/bin/postgresql-setup --initdb

# Enable and start the PostgreSQL service
sudo systemctl enable postgresql
sudo systemctl start postgresql
echo -e "\e[1;32m<<< PostgreSQL installation complete.\e[0m"

# Show installed version
echo ""
echo "PostgreSQL: $(/usr/bin/psql --version)"
