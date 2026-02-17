#!/bin/bash
set -euo pipefail

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

# Show installed version
echo "PostgreSQL: $(psql --version)"
