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
   sudo -v || { echo "Failed to obtain sudo privileges."; exit 1; }
   # Keep sudo credentials fresh for long-running installations
   while true; do sudo -n -v 2>/dev/null; sleep 50; done &
   SUDO_KEEPALIVE_PID=$!
   trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null' EXIT
fi

# Install prerequisites
sudo apt-get install -y postgresql-common

# Set up the official PostgreSQL APT repository
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y

# Update package lists
sudo apt-get update -y

# Install PostgreSQL 18 server and contrib modules
sudo apt-get install -y postgresql-18 postgresql-contrib-18

# Enable and start the PostgreSQL service
sudo systemctl enable postgresql
sudo systemctl start postgresql
sudo systemctl is-active postgresql > /dev/null 2>&1 || echo "Note: PostgreSQL service status unknown"

# Show installed version
echo "PostgreSQL: $(psql --version)"
