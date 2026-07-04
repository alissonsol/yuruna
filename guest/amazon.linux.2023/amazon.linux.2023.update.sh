#!/bin/bash
# Version: 2026.07.03
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

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

# --- See https://yuruna.link/network#defining-yuruna-retry-lib
. /usr/local/lib/yuruna/yuruna-retry.sh

# Installed as early as possible so that even if a later step in this
# script aborts under `set -euo pipefail`, the host-side failure
# diagnostic (which shells back into the guest as `pwsh -NoProfile ...`)
# still has pwsh available to gather state.
# AL2023 has no first-party pwsh package; tarball install matches what
# ubuntu.server.24.code.sh does and works on both x86_64 and aarch64.
# Version is discovered at install time by resolving the GitHub
# /releases/latest redirect, so this stays current without code edits
# when Microsoft ships a new pwsh.
echo ""
echo -e "\e[1;36m==== PowerShell ====\e[0m"
if ! command -v pwsh >/dev/null 2>&1; then
  case "$ARCH" in
    x86_64)  PS_ARCH="x64" ;;
    aarch64) PS_ARCH="arm64" ;;
  esac
  # libicu is the .NET globalization dependency pwsh links against;
  # tar/gzip cover tarball extract. curl is intentionally NOT in this
  # list: AL2023 ships curl-minimal pre-installed, and asking dnf for
  # the full `curl` package conflicts with it ("package curl-minimal-...
  # conflicts with curl provided by curl-..."). curl-minimal already
  # supplies /usr/bin/curl with HTTPS + redirect-follow + header capture,
  # which is everything the discovery and download steps below need.
  dnf_retry sudo dnf -y install libicu tar gzip
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl not on PATH (neither curl nor curl-minimal); cannot fetch PowerShell tarball." >&2
    exit 1
  fi

  # Resolve the latest-stable release tag via HEAD-follow of /releases/latest.
  # Avoids the 60/hr unauthenticated GitHub API rate limit. curl_retry adds
  # --retry-connrefused so transient GitHub edge 502/503/504 + ECONNREFUSED
  # is retried in-process; 4xx (rate-limit, 404) propagates immediately.
  PS_TAG=$(curl_retry -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/PowerShell/PowerShell/releases/latest")
  PS_TAG="${PS_TAG##*/}"
  if [[ ! "$PS_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "PowerShell version discovery failed (got: '$PS_TAG')" >&2
    exit 1
  fi
  PS_VER="${PS_TAG#v}"
  PS_URL="https://github.com/PowerShell/PowerShell/releases/download/${PS_TAG}/powershell-${PS_VER}-linux-${PS_ARCH}.tar.gz${YurunaCacheContent:+?nocache=${YurunaCacheContent}}"
  echo "Installing PowerShell ${PS_VER} (${PS_ARCH}) from ${PS_URL}"

  curl_retry -fsSL -o /tmp/powershell.tar.gz "$PS_URL"
  sudo mkdir -p /opt/microsoft/powershell/7
  sudo tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7
  sudo chmod +x /opt/microsoft/powershell/7/pwsh
  sudo ln -sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh
  rm -f /tmp/powershell.tar.gz
fi
pwsh --version

# --- See https://yuruna.link/memory#why-ubuntu--al2023-guest-update-scripts-wrap-install-module-powershell-yaml-with-pwsh_retry
PWSH_YAML_LOG=/var/log/yuruna/pwsh-yaml-install.log
sudo install -d -m 0755 -o "$USER" -g "$USER" /var/log/yuruna
echo ""
echo -e "\e[1;36m==== powershell-yaml ====\e[0m"

sudo pwsh -NoProfile -Command - <<'PSEOF' >> "$PWSH_YAML_LOG" 2>&1
"===== {0} pre-flight (static) =====" -f ([DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"))
"PowerShell : $($PSVersionTable.PSVersion)"
""
"--- Get-PSRepository ---"
try { Get-PSRepository -ErrorAction Stop | Format-List Name,SourceLocation,InstallationPolicy,Trusted | Out-String } catch { "ERROR: $($_.Exception.Message)" }
"--- Get-PackageProvider -ListAvailable ---"
try { Get-PackageProvider -ListAvailable -ErrorAction Stop | Select-Object Name,Version | Format-Table -AutoSize | Out-String } catch { "ERROR: $($_.Exception.Message)" }
"--- PowerShellGet + PSResourceGet (available) ---"
try { Get-Module PowerShellGet, Microsoft.PowerShell.PSResourceGet -ListAvailable | Select-Object Name,Version | Format-Table -AutoSize | Out-String } catch { "ERROR: $($_.Exception.Message)" }
PSEOF

pwsh_retry "$PWSH_YAML_LOG" <<'PSEOF'
$ErrorActionPreference = 'Stop'
"--- per-attempt probe @ {0} ---" -f ([DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"))
try { Resolve-DnsName www.powershellgallery.com -Type A | Select-Object -First 3 Name,IPAddress | Format-Table -AutoSize | Out-String } catch { "DNS ERROR: $($_.Exception.Message)" }
try {
    $head = Invoke-WebRequest -UseBasicParsing -Method Head -Uri 'https://www.powershellgallery.com/api/v2/' -TimeoutSec 10
    "HEAD api/v2 status: {0}" -f $head.StatusCode
} catch { "HEAD ERROR: $($_.Exception.Message)" }

"--- Install-Module powershell-yaml (Verbose) ---"
Install-Module -Name powershell-yaml -Scope AllUsers -Force -Verbose 4>&1

"--- Import + ConvertFrom-Yaml smoke ---"
Import-Module powershell-yaml
$null = ConvertFrom-Yaml 'k: v'
"OK"
PSEOF

# The host's failure-path diagnostic shells back as
# `pwsh -NoProfile -File $HOME/yuruna/automation/Get-SystemDiagnostic.ps1`.
# If the dnf block below stalls the cycle watchdog fires, the orchestrator
# captures diagnostics, and that script must already be on disk -- else
# pwsh exits 64 and writes its usage banner instead of real guest state.
# Tarball-only here: the git-clone fallback at the original position
# below stays put because it needs `git`, which requires dnf to work,
# which is exactly what may be stuck.
echo ""
echo -e "\e[1;36m==== yuruna framework tarball ====\e[0m"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
if [ -r /etc/yuruna/host.env ]; then
  # shellcheck disable=SC1091
  . /etc/yuruna/host.env
fi
if [ -n "${YURUNA_HOST_IP:-}" ] && [ -n "${YURUNA_HOST_PORT:-}" ] && [ ! -d "$REAL_HOME/yuruna" ]; then
  LIVECHECK_URL="http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/livecheck"
  TARBALL_URL="http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/yuruna-archive.tar.gz"
  if wget --no-proxy --timeout=2 -qO /dev/null "$LIVECHECK_URL" 2>/dev/null; then
    mkdir -p "$REAL_HOME/yuruna"
    if wget --no-proxy -qO- "$TARBALL_URL" | tar -xz -C "$REAL_HOME/yuruna"; then
      sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/yuruna" 2>/dev/null || true
      echo -e "\e[1;32m---- Yuruna framework available at $REAL_HOME/yuruna (early extract). ----\e[0m"
    else
      rm -rf "$REAL_HOME/yuruna"
      echo "yuruna: early tarball fetch failed -- will retry after dnf phase."
    fi
  else
    echo "yuruna: host status server livecheck failed -- skipping early extract."
  fi
fi

echo "TESTHACK: Disabling services that may suspend the machine."
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

echo "TESTHACK: Disabling update notifier popups that steal focus from the Terminal during tests."
sudo systemctl disable --now packagekit.service packagekit-offline-update.service 2>/dev/null || true
sudo systemctl disable --now dnf-automatic.timer dnf-automatic-notifyonly.timer dnf-automatic-install.timer 2>/dev/null || true
sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$REAL_USER")/bus" \
    gsettings set org.gnome.software download-updates false 2>/dev/null || true

echo ""
echo -e "\e[1;36m==== system packages update ====\e[0m"
# dnf update and dnf upgrade are aliases; one call covers both.
dnf_retry sudo dnf upgrade -y
dnf_retry sudo dnf autoremove -y

echo ""
echo -e "\e[1;36m==== Git ====\e[0m"
if ! command -v git >/dev/null 2>&1; then
  dnf_retry sudo dnf -y install git
fi
git --version

# --- See https://yuruna.link/definition#defining-the-two-source-scheme-for-framework-and-project-urls
echo -e "\e[1;32m==== yuruna framework and project repos ====\e[0m"
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

# Wait before signaling "script done": dnf transactions that touch the
# network stack / kernel / systemd can bounce the primary connection at
# the tail of the transaction, briefly dropping the DHCP lease. The
# harness's next sequence step is saveSystemDiagnostic, which opens the
# FIRST host->guest SSH of the run; if it fires during the bounce window
# the host's neighbor entry is stale (the Hyper-V External vSwitch
# ARP-discovery trap; UTM has the vmnet analogue) and SSH times out for
# the full 180 s Wait-SshReady budget. The probe MUST match whichever
# manager actually owns the link: AL2023 defaults to systemd-networkd
# (where nm-online is absent), while some desktop spins use
# NetworkManager. A probe keyed on the wrong manager silently no-ops --
# skipping the settle entirely -- or blocks its full timeout for nothing,
# so branch on the active manager. Cap every branch at 30 s so a broken
# stack cannot hang the cycle, and swallow non-zero so set -e does not
# abort.
echo ""
echo -e "\e[1;36m==== Network convergence ====\e[0m"
if systemctl is-active --quiet NetworkManager && command -v nm-online >/dev/null 2>&1; then
  nm-online -q -t 30 || echo "WARNING: nm-online did not report 'online' within 30s; continuing."
elif systemctl is-active --quiet systemd-networkd; then
  # systemd-networkd-wait-online lives outside PATH; resolve it explicitly.
  # --any: succeed once at least one link is online (single-NIC guests have
  # no second link to wait on).
  networkd_wait=""
  for cand in /usr/lib/systemd/systemd-networkd-wait-online /lib/systemd/systemd-networkd-wait-online; do
    if [ -x "$cand" ]; then
      networkd_wait="$cand"
      break
    fi
  done
  if [ -n "$networkd_wait" ]; then
    "$networkd_wait" --any --timeout=30 || echo "WARNING: systemd-networkd-wait-online did not report 'online' within 30s; continuing."
  else
    echo "WARNING: systemd-networkd active but systemd-networkd-wait-online not found; continuing."
  fi
else
  echo "WARNING: no active NetworkManager/systemd-networkd to wait on; continuing."
fi

# A definite end-of-script line keeps the guest console actively repainting
# right up to the handoff back to fetch-and-execute.sh. The convergence wait
# above can run silently for up to 30s, and on a headless Hyper-V host the
# screen-capture surface stops updating moments after the console goes idle --
# so the FETCHED AND EXECUTED marker that fetch-and-execute.sh prints next must
# land adjacent to real output rather than after a silent gap, or the host's
# waitForText OCRs a stale frame until the step times out.
# See feedback_frozen_capture_feed_idle_tail.
echo -e "\e[1;32m==== Network ready. ====\e[0m"
