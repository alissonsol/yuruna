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

echo "TESTHACK: Disabling services that may suspend the machine."
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

echo "TESTHACK: Disabling update notifier popups that steal focus from the Terminal during tests."
sudo systemctl disable --now packagekit.service packagekit-offline-update.service 2>/dev/null || true
sudo systemctl disable --now dnf-automatic.timer dnf-automatic-notifyonly.timer dnf-automatic-install.timer 2>/dev/null || true
REAL_USER="${SUDO_USER:-$USER}"
sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$REAL_USER")/bus" \
    gsettings set org.gnome.software download-updates false 2>/dev/null || true

echo ""
echo -e "\e[1;36m>>> Updating system packages...\e[0m"
sudo dnf update -y
sudo dnf upgrade -y
sudo dnf autoremove -y
echo -e "\e[1;32m<<< System packages update complete.\e[0m"
