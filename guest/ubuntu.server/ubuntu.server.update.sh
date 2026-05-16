#!/bin/bash
# Version: 2026.05.15
# Copyright (c) 2019-2026 by Alisson Sol et al.
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

echo "TESTHACK: Disabling services that may suspend the machine."
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

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

# Determine the real user (even when running with sudo)
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# ===== Ensure Git is installed =====
echo ""
echo -e "\e[1;36m>>> Ensuring Git is installed...\e[0m"
if ! command -v git >/dev/null 2>&1; then
  sudo apt-get install -y git
fi
git --version
echo -e "\e[1;32m<<< Git ready.\e[0m"

# ===== Ensure PowerShell is installed =====
echo ""
echo -e "\e[1;36m>>> Ensuring PowerShell is installed...\e[0m"
if ! command -v pwsh >/dev/null 2>&1; then
  case "$ARCH" in
    x86_64)  PS_ARCH="x64" ;;
    aarch64) PS_ARCH="arm64" ;;
  esac
  wget -q -O /tmp/powershell.tar.gz \
    "https://github.com/PowerShell/PowerShell/releases/download/v7.5.4/powershell-7.5.4-linux-${PS_ARCH}.tar.gz${YurunaCacheContent:+?nocache=${YurunaCacheContent}}"
  sudo mkdir -p /opt/microsoft/powershell/7
  sudo tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7
  sudo chmod +x /opt/microsoft/powershell/7/pwsh
  sudo ln -sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh
fi
pwsh --version
echo -e "\e[1;32m<<< PowerShell ready.\e[0m"

# Install powershell-yaml module for all users
echo ""
echo -e "\e[1;36m>>> Installing PowerShell module: powershell-yaml...\e[0m"
sudo pwsh -NoProfile -Command "Install-Module -Name powershell-yaml -Scope AllUsers -Force" || echo "Note: powershell-yaml module installation attempted"
echo -e "\e[1;32m<<< PowerShell module: powershell-yaml installation complete.\e[0m"

# ===== Materialize the yuruna framework and project repos =====
# --- See https://yuruna.link/definition#defining-the-two-source-scheme-for-framework-and-project-urls
FRAMEWORK_URL=""
PROJECT_URL=""
if [ -r /etc/yuruna/host.env ]; then
  # shellcheck disable=SC1091
  . /etc/yuruna/host.env
fi
if [ -n "${YURUNA_HOST_IP:-}" ] && [ -n "${YURUNA_HOST_PORT:-}" ]; then
  CFG_URL="http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/control/test-config"
  if cfg_body=$(wget --no-proxy --no-cache --timeout=5 -qO- "$CFG_URL" 2>/dev/null); then
    FRAMEWORK_URL=$(printf '%s' "$cfg_body" | python3 -c $'import json,sys\ntry: print((json.load(sys.stdin).get("repositories") or {}).get("frameworkUrl",""))\nexcept Exception: print("")' 2>/dev/null || true)
    PROJECT_URL=$(printf '%s' "$cfg_body" | python3 -c $'import json,sys\ntry: print((json.load(sys.stdin).get("repositories") or {}).get("projectUrl",""))\nexcept Exception: print("")' 2>/dev/null || true)
  fi
fi

if [ ! -d "$REAL_HOME/yuruna" ]; then
  HOST_OK=false
  if [ -n "${YURUNA_HOST_IP:-}" ] && [ -n "${YURUNA_HOST_PORT:-}" ]; then
    LIVECHECK_URL="http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/livecheck"
    TARBALL_URL="http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/yuruna-archive.tar.gz"
    if wget --no-proxy --timeout=2 -qO /dev/null "$LIVECHECK_URL" 2>/dev/null; then
      echo "yuruna: fetching committed tarball from $TARBALL_URL"
      mkdir -p "$REAL_HOME/yuruna"
      if wget --no-proxy -qO- "$TARBALL_URL" | tar -xz -C "$REAL_HOME/yuruna"; then
        HOST_OK=true
      else
        echo "yuruna: tarball fetch/extract failed - falling back to git clone"
        rm -rf "$REAL_HOME/yuruna"
      fi
    fi
  fi
  if [ "$HOST_OK" = "false" ]; then
    if [ -z "$FRAMEWORK_URL" ]; then
      echo "yuruna: repositories.frameworkUrl missing from test.config.yml - cannot clone framework" >&2
      exit 1
    fi
    for attempt in 1 2 3; do
      git clone "$FRAMEWORK_URL" "$REAL_HOME/yuruna" && break
      echo "git clone attempt $attempt failed"
      rm -rf "$REAL_HOME/yuruna"
      [ $attempt -lt 3 ] && sleep 60
    done
    if [ ! -d "$REAL_HOME/yuruna" ]; then
      echo "git clone failed after 3 attempts" >&2
      exit 1
    fi
  fi
fi

if [ ! -d "$REAL_HOME/yuruna/project" ]; then
  PROJECT_HOST_OK=false
  if [ -n "${YURUNA_HOST_IP:-}" ] && [ -n "${YURUNA_HOST_PORT:-}" ]; then
    PROJECT_TARBALL_URL="http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/yuruna-project-archive.tar.gz"
    # On 404 ("project repo not present on host") wget exits non-zero
    # and writes nothing (-q); pipefail propagates that to the if-test
    # so the git-clone fallback runs. The trailing ls -A guards against
    # the rare case of a successful but empty tarball.
    echo "yuruna: trying project tarball at $PROJECT_TARBALL_URL"
    mkdir -p "$REAL_HOME/yuruna/project"
    if wget --no-proxy --timeout=5 -qO- "$PROJECT_TARBALL_URL" \
         | tar -xz -C "$REAL_HOME/yuruna/project" 2>/dev/null \
         && [ -n "$(ls -A "$REAL_HOME/yuruna/project" 2>/dev/null)" ]; then
      PROJECT_HOST_OK=true
    else
      echo "yuruna: project tarball not served (or empty) - falling back to git clone"
      rm -rf "$REAL_HOME/yuruna/project"
    fi
  fi
  if [ "$PROJECT_HOST_OK" = "false" ] && [ -n "$PROJECT_URL" ]; then
    for attempt in 1 2 3; do
      git clone "$PROJECT_URL" "$REAL_HOME/yuruna/project" && break
      echo "project git clone attempt $attempt failed"
      rm -rf "$REAL_HOME/yuruna/project"
      [ $attempt -lt 3 ] && sleep 60
    done
    if [ ! -d "$REAL_HOME/yuruna/project" ]; then
      echo "project git clone failed after 3 attempts" >&2
      exit 1
    fi
  fi
fi

# Tarball extraction and any sudo'd cleanup may have left root-owned files.
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/yuruna" 2>/dev/null || true