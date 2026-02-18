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

dnf update -y
dnf upgrade -y
dnf autoremove -y
