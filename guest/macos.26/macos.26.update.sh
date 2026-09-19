#!/bin/bash
# Version: 2026.09.18
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

# --- REGION: Detect architecture
# See https://yuruna.link/42e220c4-0005
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

# --- REGION: Ensure PowerShell is installed
# See https://yuruna.link/42d69dfa-0036
# Base macOS has curl and installer, so the release .pkg can precede developer tools.
echo ""
echo -e "\e[1;36m==== Ensure PowerShell is installed ====\e[0m"
if ! command -v pwsh >/dev/null 2>&1; then
  # Resolve the latest-stable release tag via HEAD-follow of /releases/latest.
  # Avoids the 60/hr unauthenticated GitHub API rate limit.
  PS_TAG=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/PowerShell/PowerShell/releases/latest")
  PS_TAG="${PS_TAG##*/}"
  if [[ ! "$PS_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "PowerShell version discovery failed (got: '$PS_TAG')" >&2
    exit 1
  fi
  PWSH_VERSION="${PS_TAG#v}"
  PKG_URL="https://github.com/PowerShell/PowerShell/releases/download/${PS_TAG}/powershell-${PWSH_VERSION}-osx-arm64.pkg"
  PKG_PATH="/tmp/powershell.pkg"
  echo "Installing PowerShell ${PWSH_VERSION} (osx-arm64) from ${PKG_URL}"
  curl -fSL --retry 3 -o "$PKG_PATH" \
    "${PKG_URL}${YurunaCacheContent:+?nocache=${YurunaCacheContent}}"
  sudo installer -pkg "$PKG_PATH" -target /
  rm -f "$PKG_PATH"
fi
pwsh --version

# --- REGION: Install powershell-yaml module
# See https://yuruna.link/42d69dfa-0038
# macOS lacks pwsh_retry; use an inline retry and verify the import.
echo ""
echo -e "\e[1;36m==== Install powershell-yaml module ====\e[0m"
for attempt in 1 2 3; do
  sudo pwsh -NoProfile -Command "Install-Module -Name powershell-yaml -Scope AllUsers -Force" && break
  echo "powershell-yaml install attempt $attempt failed"
  [ $attempt -lt 3 ] && sleep 60
done
sudo pwsh -NoProfile -Command "Import-Module powershell-yaml; ConvertFrom-Yaml 'k: v' | Out-Null"

# --- REGION: Early yuruna framework extraction
# See https://yuruna.link/42d69dfa-0037
# Use curl here; the Git fallback follows the developer-tools install.
echo ""
echo -e "\e[1;36m==== Early yuruna framework extraction ====\e[0m"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory | awk '/^NFSHomeDirectory:/ {print $2}')
if [ -r /etc/yuruna/host.env ]; then
  # shellcheck disable=SC1091
  . /etc/yuruna/host.env
fi
if [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ] && [ ! -d "$REAL_HOME/yuruna" ]; then
  LIVECHECK_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/livecheck"
  TARBALL_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-archive.tar.gz"
  if curl -fsS --max-time 2 -o /dev/null "$LIVECHECK_URL" 2>/dev/null; then
    mkdir -p "$REAL_HOME/yuruna"
    # --- REGION: https://yuruna.link/42e220c4-0005
    if curl -fsSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
         "$TARBALL_URL" | tar -xz -C "$REAL_HOME/yuruna"; then
      sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/yuruna" 2>/dev/null || true
      echo -e "\e[1;32m---- Yuruna framework available at $REAL_HOME/yuruna (early extract). ----\e[0m"
    else
      rm -rf "$REAL_HOME/yuruna"
      echo "yuruna: early tarball fetch failed."
    fi
  else
    echo "yuruna: host status service livecheck failed -- skipping early extract."
  fi
fi

# --- REGION: Disable services that may suspend the machine
# Match the host no-sleep contract; password rotation makes sudo noninteractive.
echo "TESTHACK: Disabling services that may suspend the machine."
sudo pmset -a displaysleep 0 sleep 0 disksleep 0 || true

# --- REGION: Update system packages
# `softwareupdate -l` lists available updates; `-i -a` installs every
# pending one and reboots when needed. `--agree-to-license` keeps the
# step non-interactive for sequences that drive the workload.
echo ""
echo -e "\e[1;36m==== macOS update list ====\e[0m"
sudo softwareupdate -l || true

echo ""
echo -e "\e[1;36m==== Update system packages ====\e[0m"
sudo softwareupdate -i -a --agree-to-license || true

# --- REGION: Ensure Git is installed (Command Line Developer Tools)
# macOS supplies Git and Swift through Command Line Developer Tools.
echo ""
echo -e "\e[1;36m==== Ensure Git is installed (Command Line Developer Tools) ====\e[0m"
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

# --- REGION: Resolve framework and project URLs
# See https://yuruna.link/42fa6f45-000c
echo -e "\e[1;32m==== Resolve framework and project URLs ====\e[0m"
FRAMEWORK_URL=""
PROJECT_URL=""
if [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ]; then
  CFG_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/control/test-config"
  if cfg_body=$(curl -fsS --max-time 5 "$CFG_URL" 2>/dev/null); then
    FRAMEWORK_URL=$(printf '%s' "$cfg_body" | python3 -c $'import json,sys\ntry: print((json.load(sys.stdin).get("repositories") or {}).get("frameworkUrl",""))\nexcept Exception: print("")' 2>/dev/null || true)
    PROJECT_URL=$(printf '%s' "$cfg_body" | python3 -c $'import json,sys\ntry: print((json.load(sys.stdin).get("repositories") or {}).get("projectUrl",""))\nexcept Exception: print("")' 2>/dev/null || true)
  fi
fi

# --- REGION: Keep git non-interactive
# See https://yuruna.link/4220a755-004f
export GIT_TERMINAL_PROMPT=0
if [ -x /usr/local/lib/yuruna/git-askpass.sh ]; then
    export GIT_ASKPASS=/usr/local/lib/yuruna/git-askpass.sh
fi

# --- REGION: Materialize the yuruna framework and project repos
# See https://yuruna.link/42e220c4-000e
if [ ! -d "$REAL_HOME/yuruna" ]; then
  HOST_OK=false
  if [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ]; then
    LIVECHECK_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/livecheck"
    TARBALL_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-archive.tar.gz"
    if curl -fsS --max-time 2 -o /dev/null "$LIVECHECK_URL" 2>/dev/null; then
      echo "yuruna: fetching committed tarball from $TARBALL_URL"
      mkdir -p "$REAL_HOME/yuruna"
      if curl -fsSL --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
           "$TARBALL_URL" | tar -xz -C "$REAL_HOME/yuruna"; then
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
      git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 clone "$FRAMEWORK_URL" "$REAL_HOME/yuruna" && break
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
  if [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ]; then
    PROJECT_TARBALL_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-project-archive.tar.gz"
    echo "yuruna: trying project tarball at $PROJECT_TARBALL_URL"
    mkdir -p "$REAL_HOME/yuruna/project"
    if curl -fsSL --connect-timeout 5 --speed-limit 1024 --speed-time 5 \
         "$PROJECT_TARBALL_URL" 2>/dev/null \
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
      git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 clone "$PROJECT_URL" "$REAL_HOME/yuruna/project" && break
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

echo ""
# --- REGION: https://yuruna.link/42e220c4-0005
echo -e "\e[1;32m==== Update complete. ====\e[0m"
