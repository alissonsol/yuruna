#!/bin/bash
# Version: 2026.05.15
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

# Workload-phase update script for a macOS 26 guest. Mirrors the role
# of ubuntu.server.update.sh / amazon.linux.update.sh in the workload
# step that follows a successful guest start. Not called by New-VM.ps1
# (the host-side restore script): macOS 26 ships its kernel + system
# in the IPSW restore that New-VM.ps1 already performs, so an apt-/yum-
# style "update right after install" is redundant on first boot. This
# script exists for the eventual sequence that runs against a
# Setup-Assistant-completed guest.

# ===== Detect architecture =====
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
case "$ARCH" in
  arm64)
    echo "Environment: arm64 (Apple Silicon)"
    ;;
  *)
    echo "WARNING: Unsupported architecture for macOS 26 guest: $ARCH"
    echo "macOS 26 only runs on arm64 (Apple Silicon)."
    exit 1
    ;;
esac

# ===== Disable sleep / display sleep for the test run =====
# Mirrors the host-side Set-MacHostConditionSet contract for the guest.
# pmset on a VZ guest behaves the same as on a Mac mini; sudo is
# required. The test extension `authentication` rotates the guest
# password at first login, so sudo works without an interactive prompt
# inside the test sequence.
echo "TESTHACK: Disabling display + system sleep on the guest."
sudo pmset -a displaysleep 0 sleep 0 disksleep 0 || true

# ===== Apply pending macOS updates =====
# `softwareupdate -l` lists available updates; `-i -a` installs every
# pending one and reboots when needed. `--agree-to-license` keeps the
# step non-interactive for sequences that drive the workload.
echo ""
echo -e "\e[1;36m>>> Listing pending macOS updates...\e[0m"
sudo softwareupdate -l || true

echo ""
echo -e "\e[1;36m>>> Applying pending macOS updates...\e[0m"
sudo softwareupdate -i -a --agree-to-license || true
echo -e "\e[1;32m<<< macOS updates complete.\e[0m"

# ===== Ensure command line developer tools are installed =====
# Provides /usr/bin/git, /usr/bin/swift, and the rest of the developer
# toolchain that subsequent yuruna workload scripts depend on.
echo ""
echo -e "\e[1;36m>>> Ensuring Command Line Developer Tools are installed...\e[0m"
if ! xcode-select -p >/dev/null 2>&1; then
  # Trigger the on-demand install path used by every fresh macOS box.
  # `softwareupdate` then picks the published label and installs it
  # non-interactively.
  sudo touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  PROD=$(softwareupdate -l 2>/dev/null \
    | grep -E 'Label: Command Line Tools' \
    | tail -1 \
    | sed -E 's/.*Label: //')
  if [ -n "$PROD" ]; then
    sudo softwareupdate -i "$PROD" --verbose --agree-to-license || true
  fi
  sudo rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
fi
xcode-select -p || true
echo -e "\e[1;32m<<< Command Line Developer Tools ready.\e[0m"

# ===== Ensure PowerShell is installed =====
# macOS pwsh ships as a .pkg from the PowerShell releases; same version
# pin as the Linux guests so the cross-OS surface stays comparable.
PWSH_VERSION="7.5.4"
echo ""
echo -e "\e[1;36m>>> Ensuring PowerShell ${PWSH_VERSION} is installed...\e[0m"
if ! command -v pwsh >/dev/null 2>&1; then
  PKG_URL="https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-osx-arm64.pkg"
  PKG_PATH="/tmp/powershell.pkg"
  curl -fSL --retry 3 -o "$PKG_PATH" \
    "${PKG_URL}${YurunaCacheContent:+?nocache=${YurunaCacheContent}}"
  sudo installer -pkg "$PKG_PATH" -target /
  rm -f "$PKG_PATH"
fi
pwsh --version
echo -e "\e[1;32m<<< PowerShell ready.\e[0m"

# Install powershell-yaml module so the in-guest sequence planner
# (when one exists for macOS 26) can read YAML sequence files. Same
# contract Test.Host.Install-PowerShellYamlIfMissing applies on the
# host side.
echo ""
echo -e "\e[1;36m>>> Installing PowerShell module: powershell-yaml...\e[0m"
sudo pwsh -NoProfile -Command "Install-Module -Name powershell-yaml -Scope AllUsers -Force" \
  || echo "Note: powershell-yaml module installation attempted"
echo -e "\e[1;32m<<< PowerShell module: powershell-yaml installation complete.\e[0m"

echo ""
echo "FETCHED AND EXECUTED: macos.26.update.sh"
