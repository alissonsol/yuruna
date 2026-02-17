#!/bin/bash

# Install PostgreSQL 17 server and contrib modules
dnf install -y postgresql17-server postgresql17-contrib

# Initialize the database
/usr/bin/postgresql-setup --initdb

# Enable and start the PostgreSQL service
systemctl enable postgresql
systemctl start postgresql

# Show installed version
echo "PostgreSQL: $(/usr/bin/psql --version)"
