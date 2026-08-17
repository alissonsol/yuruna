#!/bin/bash
# Version: 2026.08.16
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

# Workload-phase update script for a macOS 26 guest. Mirrors the role of
# ubuntu.server.24.update.sh / amazon.linux.2023.update.sh in the workload step
# that follows a successful guest start. Not called by New-VM.ps1 (the host-side
# restore script): macOS 26 ships its kernel + system in the IPSW restore that
# New-VM.ps1 already performs, so an apt-/yum-style "update right after install"
# is redundant on first boot. This script exists for the eventual sequence that
# runs against a Setup-Assistant-completed guest.

# --- REGION: Detect architecture
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
# --- REGION: https://yuruna.link/memory#why-ubuntu-guest-update-scripts-install-powershell-first
# macOS pwsh ships as a .pkg from the PowerShell releases. The version is
# discovered at install time by resolving the GitHub /releases/latest redirect,
# the same mechanism the Linux guests use, so both stay in step. curl and
# installer are in base macOS; this step does not need the Command Line
# Developer Tools first.
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
# --- REGION: https://yuruna.link/memory#why-ubuntu--al2023-guest-update-scripts-wrap-install-module-powershell-yaml-with-pwsh_retry
# macOS has no pwsh_retry library, so the PSGallery-flap ride-out is
# inlined as the same 3-attempt / 60s loop this script uses for git
# clone; the trailing Import-Module check is the real fail-fast gate
# (Install-Module can report success with the module unloadable).
echo ""
echo -e "\e[1;36m==== Install powershell-yaml module ====\e[0m"
for attempt in 1 2 3; do
  sudo pwsh -NoProfile -Command "Install-Module -Name powershell-yaml -Scope AllUsers -Force" && break
  echo "powershell-yaml install attempt $attempt failed"
  [ $attempt -lt 3 ] && sleep 60
done
sudo pwsh -NoProfile -Command "Import-Module powershell-yaml; ConvertFrom-Yaml 'k: v' | Out-Null"

# --- REGION: Early yuruna framework extraction
# --- REGION: https://yuruna.link/memory#why-ubuntu-guest-update-scripts-pre-extract-the-yuruna-tarball
# Tarball-only here (curl, since macOS base does not ship wget); the
# git-clone fallback lives in the late Materialize section below, which
# needs `git` from the Command Line Developer Tools install that runs
# before it.
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
    # Bounded, unlike the livecheck it follows. The probe proves the host was
    # answering a moment ago; it says nothing about where the host will be
    # partway through a multi-megabyte transfer, and curl left to its defaults
    # sits on a stalled one indefinitely -- long past the step's own patience,
    # so the failure arrives as an unexplained step timeout instead of a fetch
    # that said what went wrong. The bound is on the transfer stalling (under
    # 1 KB/s for 60s), not on its total duration: a large archive on a
    # slow-but-moving link must still be allowed to finish.
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
# Mirrors the host-side Set-MacHostConditionSet contract for the guest.
# pmset on a VZ guest behaves the same as on a Mac mini; sudo is
# required. The test extension `authentication` rotates the guest
# password at first login, so sudo works without an interactive prompt
# inside the test sequence.
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
# Provides /usr/bin/git, /usr/bin/swift, and the rest of the developer
# toolchain that subsequent yuruna workload scripts depend on. macOS
# ships git via the Command Line Developer Tools, not as a standalone
# package, so the on-demand install path is the canonical install.
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
# --- REGION: https://yuruna.link/definition#defining-the-two-source-scheme-for-framework-and-project-urls
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
# --- REGION: https://yuruna.link/network#why-git-never-prompts-here
# Belt to the seed's braces. These guests are driven by OCR of a console, so a
# git credential prompt is a HANG rather than an error: the step spends its whole
# timeout before anyone learns the clone could not authenticate. Set here as well
# as in the image because this script runs under sudo and through non-login
# shells, either of which drops an ambient export -- and because a guest built
# from an older seed has no such export to drop.
export GIT_TERMINAL_PROMPT=0
if [ -x /usr/local/lib/yuruna/git-askpass.sh ]; then
    export GIT_ASKPASS=/usr/local/lib/yuruna/git-askpass.sh
fi

# --- REGION: Materialize the yuruna framework and project repos
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
    # git ships no stall detection (http.lowSpeedLimit/Time unset), so a clone
    # stalled mid-transfer would hang forever and the retry ladder below would
    # never fire (the stalled-transfer trap class); the low-speed pair aborts a
    # <1 KB/s-for-60s transfer into the retry path instead.
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
    # Bound the connect and the stall, never the total: --max-time would abort
    # any archive that simply takes longer than the cap to arrive and push the
    # run onto the git-clone path, which on a private projectUrl is the slow,
    # prompt-prone leg -- the opposite of what a fast-fail here is for.
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
# The completion marker belongs to fetch-and-execute.sh alone: it is chosen by
# the inner script's exit code, and a second copy printed here says "success"
# regardless of that code, so the host's OCR matcher can settle on the payload's
# copy and pass a failed run. What the payload owes the harness instead is a
# definite end-of-script line, so the real marker lands adjacent to live output
# rather than after a silent gap a headless capture surface would freeze on.
# See feedback_frozen_capture_feed_idle_tail.
echo -e "\e[1;32m==== Update complete. ====\e[0m"
