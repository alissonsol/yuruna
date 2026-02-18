#!/bin/bash
set -euo pipefail

# ===== Request sudo elevation if not already root =====
if [[ $EUID -ne 0 ]]; then
   echo ""
   echo "╔════════════════════════════════════════════════════════════╗"
   echo "║  This script requires elevated privileges (sudo)           ║"
   echo "║  Please enter your password when prompted below            ║"
   echo "║  The script will pause until you provide your password     ║"
   echo "╚════════════════════════════════════════════════════════════╝"
   echo ""
   sudo "$0" "$@"
   exit $?
fi

# Install PostgreSQL 17 server and contrib modules
dnf install -y postgresql17-server postgresql17-contrib

# Initialize the database
/usr/bin/postgresql-setup --initdb

# Enable and start the PostgreSQL service
systemctl enable postgresql
systemctl start postgresql

# Show installed version
echo "PostgreSQL: $(/usr/bin/psql --version)"
