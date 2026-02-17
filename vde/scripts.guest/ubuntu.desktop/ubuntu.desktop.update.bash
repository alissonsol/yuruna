#!/bin/bash
set -euo pipefail

# ===== Request sudo elevation if not already root =====
if [[ $EUID -ne 0 ]]; then
   echo ""
   echo "╔════════════════════════════════════════════════════════════╗"
   echo "║  This script requires elevated privileges (sudo)            ║"
   echo "║  Please enter your password when prompted below            ║"
   echo "║  The script will pause until you provide your password     ║"
   echo "╚════════════════════════════════════════════════════════════╝"
   echo ""
   sudo "$0" "$@"
   exit $?
fi

apt-get update;
apt-get upgrade -y;
apt-get dist-upgrade -y;
apt-get autoclean -y;
apt-get autoremove -y;
apt-get install deborphan -y;
deborphan | xargs apt-get -y remove --purge;
deborphan --guess-data | xargs apt-get -y remove --purge;