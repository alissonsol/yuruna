#!/bin/bash
# Version: 2026.07.22
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

# Workload-phase update script for a macOS 26 guest. Mirrors the role
# of ubuntu.server.24.update.sh / amazon.linux.2023.update.sh in the workload
# step that follows a successful guest start. Not called by New-VM.ps1
# (the host-side restore script): macOS 26 ships its kernel + system
# in the IPSW restore that New-VM.ps1 already performs, so an apt-/yum-
# style "update right after install" is redundant on first boot. This
# script exists for the eventual sequence that runs against a
# Setup-Assistant-completed guest.

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

# --- REGION: https://yuruna.link/memory#why-ubuntu-guest-update-scripts-install-powershell-first
# macOS pwsh ships as a .pkg from the PowerShell releases. Version is
# discovered at install time by resolving the GitHub /releases/latest
# redirect, so this stays current with what the Linux guests install
# (which use the same discovery mechanism).
# curl and installer are in base macOS; this step does not depend on
# Command Line Developer Tools being installed first.
echo ""
echo -e "\e[1;36m==== PowerShell ====\e[0m"
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

# --- REGION: https://yuruna.link/memory#why-ubuntu--al2023-guest-update-scripts-wrap-install-module-powershell-yaml-with-pwsh_retry
# macOS has no pwsh_retry library, so the PSGallery-flap ride-out is
# inlined as the same 3-attempt / 60s loop this script uses for git
# clone; the trailing Import-Module check is the real fail-fast gate
# (Install-Module can report success with the module unloadable).
echo ""
echo -e "\e[1;36m==== powershell-yaml ====\e[0m"
for attempt in 1 2 3; do
  sudo pwsh -NoProfile -Command "Install-Module -Name powershell-yaml -Scope AllUsers -Force" && break
  echo "powershell-yaml install attempt $attempt failed"
  [ $attempt -lt 3 ] && sleep 60
done
sudo pwsh -NoProfile -Command "Import-Module powershell-yaml; ConvertFrom-Yaml 'k: v' | Out-Null"

# --- REGION: https://yuruna.link/memory#why-ubuntu-guest-update-scripts-pre-extract-the-yuruna-tarball
# Tarball-only here (curl, since macOS base does not ship wget); the
# git-clone fallback lives in the late Materialize section below, which
# needs `git` from the Command Line Developer Tools install that runs
# before it.
echo ""
echo -e "\e[1;36m==== yuruna framework tarball ====\e[0m"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(dscl . -read "/Users/$REAL_USER" NFSHomeDirectory | awk '/^NFSHomeDirectory:/ {print $2}')
if [ -r /etc/yuruna/host.env ]; then
  # shellcheck disable=SC1091
  . /etc/yuruna/host.env
fi
if [ -n "${YURUNA_HOST_IP:-}" ] && [ -n "${YURUNA_HOST_PORT:-}" ] && [ ! -d "$REAL_HOME/yuruna" ]; then
  LIVECHECK_URL="http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/livecheck"
  TARBALL_URL="http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/yuruna-archive.tar.gz"
  if curl -fsS --max-time 2 -o /dev/null "$LIVECHECK_URL" 2>/dev/null; then
    mkdir -p "$REAL_HOME/yuruna"
    if curl -fsSL "$TARBALL_URL" | tar -xz -C "$REAL_HOME/yuruna"; then
      sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/yuruna" 2>/dev/null || true
      echo -e "\e[1;32m---- Yuruna framework available at $REAL_HOME/yuruna (early extract). ----\e[0m"
    else
      rm -rf "$REAL_HOME/yuruna"
      echo "yuruna: early tarball fetch failed."
    fi
  else
    echo "yuruna: host status server livecheck failed -- skipping early extract."
  fi
fi

# Mirrors the host-side Set-MacHostConditionSet contract for the guest.
# pmset on a VZ guest behaves the same as on a Mac mini; sudo is
# required. The test extension `authentication` rotates the guest
# password at first login, so sudo works without an interactive prompt
# inside the test sequence.
echo "TESTHACK: Disabling services that may suspend the machine."
sudo pmset -a displaysleep 0 sleep 0 disksleep 0 || true

# `softwareupdate -l` lists available updates; `-i -a` installs every
# pending one and reboots when needed. `--agree-to-license` keeps the
# step non-interactive for sequences that drive the workload.
echo ""
echo -e "\e[1;36m==== macOS update list ====\e[0m"
sudo softwareupdate -l || true

echo ""
echo -e "\e[1;36m==== macOS updates ====\e[0m"
sudo softwareupdate -i -a --agree-to-license || true

# Provides /usr/bin/git, /usr/bin/swift, and the rest of the developer
# toolchain that subsequent yuruna workload scripts depend on. macOS
# ships git via the Command Line Developer Tools, not as a standalone
# package, so the on-demand install path is the canonical install.
echo ""
echo -e "\e[1;36m==== Developer Tools CLI ====\e[0m"
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

# --- REGION: https://yuruna.link/definition#defining-the-two-source-scheme-for-framework-and-project-urls
echo -e "\e[1;32m==== yuruna framework and project repos ====\e[0m"
FRAMEWORK_URL=""
PROJECT_URL=""
if [ -n "${YURUNA_HOST_IP:-}" ] && [ -n "${YURUNA_HOST_PORT:-}" ]; then
  CFG_URL="http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/control/test-config"
  if cfg_body=$(curl -fsS --max-time 5 "$CFG_URL" 2>/dev/null); then
    FRAMEWORK_URL=$(printf '%s' "$cfg_body" | python3 -c $'import json,sys\ntry: print((json.load(sys.stdin).get("repositories") or {}).get("frameworkUrl",""))\nexcept Exception: print("")' 2>/dev/null || true)
    PROJECT_URL=$(printf '%s' "$cfg_body" | python3 -c $'import json,sys\ntry: print((json.load(sys.stdin).get("repositories") or {}).get("projectUrl",""))\nexcept Exception: print("")' 2>/dev/null || true)
  fi
fi

if [ ! -d "$REAL_HOME/yuruna" ]; then
  HOST_OK=false
  if [ -n "${YURUNA_HOST_IP:-}" ] && [ -n "${YURUNA_HOST_PORT:-}" ]; then
    LIVECHECK_URL="http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/livecheck"
    TARBALL_URL="http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/yuruna-archive.tar.gz"
    if curl -fsS --max-time 2 -o /dev/null "$LIVECHECK_URL" 2>/dev/null; then
      echo "yuruna: fetching committed tarball from $TARBALL_URL"
      mkdir -p "$REAL_HOME/yuruna"
      if curl -fsSL "$TARBALL_URL" | tar -xz -C "$REAL_HOME/yuruna"; then
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
    # git ships no stall detection (http.lowSpeedLimit/Time unset), so a
    # clone stalled mid-transfer would hang this attempt forever and the
    # retry ladder below it would never fire (the stalled-transfer trap
    # class); the low-speed pair aborts a <1 KB/s-for-60s transfer into
    # the retry path instead.
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
  if [ -n "${YURUNA_HOST_IP:-}" ] && [ -n "${YURUNA_HOST_PORT:-}" ]; then
    PROJECT_TARBALL_URL="http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/yuruna-project-archive.tar.gz"
    echo "yuruna: trying project tarball at $PROJECT_TARBALL_URL"
    mkdir -p "$REAL_HOME/yuruna/project"
    if curl -fsSL --max-time 5 "$PROJECT_TARBALL_URL" 2>/dev/null \
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
echo "FETCHED AND EXECUTED: macos.26.update.sh"
