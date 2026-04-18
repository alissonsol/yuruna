#!/bin/bash
set -euo pipefail

# Non-interactive mode for all installations
export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1


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

# ===== Pin the Hyper-V framebuffer resolution =====
# Without an explicit video= parameter, hyperv_drm occasionally fails to
# re-initialize on reboot, leaving the guest with a black screen and a wedged
# console (Ctrl+Alt+F3 also dead). Pinning the framebuffer resolution in the
# kernel cmdline avoids that reboot fragility. Hyper-V only.
if [ "$ARCH" = "x86_64" ] && [ -f /etc/default/grub ]; then
  echo ""
  echo -e "\e[1;36m>>> Pinning Hyper-V framebuffer (video=hyperv_fb:1920x1080)...\e[0m"
  if ! grep -q 'video=hyperv_fb' /etc/default/grub; then
    sudo sed -i -E 's|^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"|GRUB_CMDLINE_LINUX_DEFAULT="\1 video=hyperv_fb:1920x1080"|; s|="  *|="|' /etc/default/grub
    sudo update-grub
    echo -e "\e[1;32m<<< GRUB updated with video=hyperv_fb:1920x1080.\e[0m"
  else
    echo "GRUB already has video=hyperv_fb; skipping."
  fi
fi

# ===== Disable screen lock and idle timeout =====
# Hypervisor-injected keystrokes don't reset the GNOME idle timer,
# so long-running tests can trigger the lock screen.
REAL_USER="${SUDO_USER:-$USER}"
echo "Disabling screen lock and idle timeout for user $REAL_USER..."
sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$REAL_USER")/bus" \
    gsettings set org.gnome.desktop.screensaver lock-enabled false
sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$REAL_USER")/bus" \
    gsettings set org.gnome.desktop.session idle-delay 0
echo "Screen lock disabled, idle timeout set to 0 (never)."

echo "TESTHACK:Disabling services that may suspend the machine."
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

echo "TESTHACK: Disabling update notifier popups that steal focus from the Terminal during tests."
sudo apt-get remove -y update-notifier update-manager || true
sudo rm -f /etc/xdg/autostart/update-notifier.desktop
sudo sed -i 's/^Prompt=.*/Prompt=never/' /etc/update-manager/release-upgrades 2>/dev/null || true
sudo tee /etc/apt/apt.conf.d/10periodic >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

echo ""
echo -e "\e[1;36m>>> Updating system packages...\e[0m"
sudo apt-get update;
sudo apt-get -o APT::Get::Always-Include-Phased-Updates=true upgrade -y;
sudo apt-get dist-upgrade -y;
sudo apt-get autoclean -y;
sudo apt-get autoremove -y;
sudo apt-get install deborphan -y;
sudo deborphan | xargs --no-run-if-empty sudo apt-get -y remove --purge;
sudo deborphan --guess-data | xargs --no-run-if-empty sudo apt-get -y remove --purge;
echo -e "\e[1;32m<<< System packages update complete.\e[0m"