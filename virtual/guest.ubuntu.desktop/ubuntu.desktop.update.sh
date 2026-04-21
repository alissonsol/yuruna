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

# ===== Disable KMS to prevent Hyper-V black-screen-on-reboot =====
# Ubuntu LP #2064815 / #2063143: on Hyper-V Gen 2, the simpledrm (UEFI
# framebuffer) -> hyperv_drm handoff race intermittently leaves the
# guest with a dead console on a later reboot -- both GUI and tty3 are
# wedged because simpledrm still owns the console when GDM grabs DRM
# master. As of 2026-04 there is no released kernel fix (HWE 6.11 on
# 24.04.3 does NOT resolve it; the bug is Confirmed, unassigned on
# Launchpad). nomodeset skips KMS entirely so hyperv_drm never loads
# and the race can't happen. vmconnect reads via Hyper-V's synthetic
# video channel independently of the guest's KMS driver, so the
# console OCR path the harness relies on still works on efifb.
#
# Supersedes an earlier attempt that only pinned the framebuffer
# resolution via video=hyperv_fb:1920x1080 -- that kept hyperv_drm
# loaded, so the handoff race still triggered. The stale parameter is
# stripped below if still present in an existing /etc/default/grub.
if [ "$ARCH" = "x86_64" ] && [ -f /etc/default/grub ]; then
  echo ""
  echo -e "\e[1;36m>>> Configuring GRUB to prevent Hyper-V black-screen-on-reboot (nomodeset)...\e[0m"
  changed=0
  if grep -q 'video=hyperv_fb' /etc/default/grub; then
    sudo sed -i -E 's| *video=hyperv_fb:[^ "]*||g' /etc/default/grub
    echo "  Removed stale video=hyperv_fb parameter from the prior fix attempt."
    changed=1
  fi
  if ! grep -q 'nomodeset' /etc/default/grub; then
    sudo sed -i -E 's|^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"|GRUB_CMDLINE_LINUX_DEFAULT="\1 nomodeset"|; s|="  *|="|' /etc/default/grub
    echo "  Added nomodeset to GRUB_CMDLINE_LINUX_DEFAULT."
    changed=1
  fi
  if [ $changed -eq 1 ]; then
    sudo update-grub
    echo -e "\e[1;32m<<< GRUB updated. Next reboot will not load hyperv_drm.\e[0m"
  else
    echo "GRUB already configured; skipping."
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