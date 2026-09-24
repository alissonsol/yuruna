#!/bin/bash
# Version: 2026.09.24
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# --- REGION: Detect architecture
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
# Architecture does not imply host platform: this lab runs aarch64 guests on
# Hyper-V and UTM. Report virtualization detected inside the guest instead of
# inferring the host from uname.
echo "Detected virtualization: $(systemd-detect-virt 2>/dev/null || echo unknown)"
case "$ARCH" in
  x86_64)
    echo "Environment: x86_64/amd64"
    ;;
  aarch64)
    echo "Environment: aarch64/arm64"
    ;;
  *)
    echo "WARNING: Unsupported architecture: $ARCH"
    echo "This script supports x86_64/amd64 and aarch64/arm64."
    exit 1
    ;;
esac

# --- REGION: Load retry helpers
# See https://yuruna.link/4220a755-0003
. /usr/local/lib/yuruna/yuruna-retry.sh
# --- REGION: https://yuruna.link/4220a755-0005
export YURUNA_APT_STALL_TIMEOUT_SECONDS=0

# --- REGION: Bound package index fetches
# See https://yuruna.link/4220a755-0006
# Written per cycle rather than trusted from the autoinstall seed: 99- sorts
# after curtin's own drop-ins and none of these keys overlap its proxy one.
sudo tee /etc/apt/apt.conf.d/99yuruna-acquire >/dev/null <<'EOF'
Acquire::Retries "2";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
Acquire::Languages "none";
EOF

# --- REGION: Re-read host coordinates per use
# See https://yuruna.link/4220a755-004d
yuruna_host_env() {
    [ -r /etc/yuruna/host.env ] || return 1
    # shellcheck disable=SC1091
    . /etc/yuruna/host.env
    [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ]
}

# Force one refresh after a failed fetch instead of retrying stale coordinates.
yuruna_host_relocate() {
    [ -x /usr/local/lib/yuruna/yuruna-host-locate.sh ] || return 1
    # --- REGION: https://yuruna.link/42e220c4-0005
    /usr/local/lib/yuruna/yuruna-host-locate.sh >/dev/null || return 1
    yuruna_host_env
}

# --- REGION: Recover the caching-proxy CA
# See https://yuruna.link/4220a755-0015
yuruna_ca_selfheal || true

# --- REGION: Ensure PowerShell is installed
# See https://yuruna.link/42d69dfa-0036
echo ""
echo -e "\e[1;36m==== Ensure PowerShell is installed ====\e[0m"
if ! command -v pwsh >/dev/null 2>&1; then
  case "$ARCH" in
    x86_64)  PS_ARCH="x64" ;;
    aarch64) PS_ARCH="arm64" ;;
  esac
  apt_retry sudo apt-get install -y curl tar gzip

  # Follow the latest-release redirect without consuming GitHub API quota.
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
  # --- REGION: https://yuruna.link/429f3d06-008b
  PS_PKG="powershell-${PS_VER}-linux-${PS_ARCH}.tar.gz"
  if curl_retry -fsSL -o /tmp/pwsh-hashes.sha256 \
       "https://github.com/PowerShell/PowerShell/releases/download/${PS_TAG}/hashes.sha256"; then
    PS_B2=$(od -An -tx1 -N2 /tmp/pwsh-hashes.sha256 2>/dev/null | tr -d ' \n' || true)
    if [ "$PS_B2" = "fffe" ] || [ "$PS_B2" = "feff" ]; then
      iconv -f UTF-16 -t UTF-8 /tmp/pwsh-hashes.sha256 2>/dev/null | tr -d '\r' > /tmp/pwsh-hashes.norm || true
    else
      tr -d '\r' < /tmp/pwsh-hashes.sha256 > /tmp/pwsh-hashes.norm || true
    fi
    PS_WANT=$(LC_ALL=C awk -v p="$PS_PKG" 'index($0,p){print $1; exit}' /tmp/pwsh-hashes.norm 2>/dev/null || true)
    PS_GOT=$(sha256sum /tmp/powershell.tar.gz 2>/dev/null | awk '{print $1}' || true)
    if [ -z "$PS_WANT" ]; then
      echo "PowerShell ${PS_VER}: no checksum line for ${PS_PKG} in hashes.sha256; proceeding unverified." >&2
    elif [ -z "$PS_GOT" ]; then
      echo "PowerShell ${PS_VER}: could not compute local SHA-256; proceeding unverified." >&2
    elif [ "$PS_WANT" = "$PS_GOT" ]; then
      echo "PowerShell ${PS_VER}: tarball SHA-256 verified."
    else
      echo "PowerShell ${PS_VER}: tarball SHA-256 MISMATCH (want ${PS_WANT}, got ${PS_GOT}); possible tamper/corruption -- aborting." >&2
      exit 1
    fi
    rm -f /tmp/pwsh-hashes.sha256 /tmp/pwsh-hashes.norm
  else
    echo "PowerShell ${PS_VER}: could not fetch hashes.sha256 after retries; proceeding unverified." >&2
  fi
  sudo mkdir -p /opt/microsoft/powershell/7
  sudo tar zxf /tmp/powershell.tar.gz -C /opt/microsoft/powershell/7
  sudo chmod +x /opt/microsoft/powershell/7/pwsh
  sudo ln -sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh
  rm -f /tmp/powershell.tar.gz
fi
pwsh --version

# --- REGION: Install powershell-yaml module
# See https://yuruna.link/42d69dfa-0038
PWSH_YAML_LOG=/var/log/yuruna/pwsh-yaml-install.log
sudo install -d -m 0755 -o "$USER" -g "$USER" /var/log/yuruna
echo ""
echo -e "\e[1;36m==== Install powershell-yaml module ====\e[0m"

# The log directory is owned by the caller; sudo applies only to pwsh.
# shellcheck disable=SC2024
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
# [System.Net.Dns] rather than Resolve-DnsName: that cmdlet lives in the
# Windows-only DnsClient module, so on Linux it can only ever error.
try { "DNS: {0}" -f (([System.Net.Dns]::GetHostAddresses('www.powershellgallery.com') | Select-Object -First 3 | ForEach-Object { $_.IPAddressToString }) -join ' ') } catch { "DNS ERROR: $($_.Exception.Message)" }
# GET, not HEAD: the gallery answers HEAD with 405 Method Not Allowed, so a
# HEAD probe reads as an outage on every healthy run.
try {
    $probe = Invoke-WebRequest -UseBasicParsing -Method Get -Uri 'https://www.powershellgallery.com/api/v2/' -TimeoutSec 10
    "GET api/v2 status: {0}" -f $probe.StatusCode
} catch { "PROBE ERROR: $($_.Exception.Message)" }

"--- Install-Module powershell-yaml (Verbose) ---"
try {
    Install-Module -Name powershell-yaml -Scope AllUsers -Force -Verbose 4>&1
} catch {
    "INSTALL ERROR: $($_.Exception.Message)"
}

"--- Import + ConvertFrom-Yaml smoke ---"
# --- REGION: https://yuruna.link/42e220c4-0005
try {
    Import-Module powershell-yaml -ErrorAction Stop
    $null = ConvertFrom-Yaml 'k: v'
} catch {
    "SMOKE ERROR: $($_.Exception.Message)"
    exit 1
}
if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    "VERIFY ERROR: powershell-yaml not available after install"
    exit 1
}
"OK"
PSEOF

# --- REGION: Early yuruna framework extraction
# See https://yuruna.link/42d69dfa-0037
echo ""
echo -e "\e[1;36m==== Early yuruna framework extraction ====\e[0m"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
if [ -r /etc/yuruna/host.env ]; then
  # shellcheck disable=SC1091
  . /etc/yuruna/host.env
fi
if yuruna_host_env && [ ! -d "$REAL_HOME/yuruna" ]; then
  LIVECHECK_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/livecheck"
  TARBALL_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-archive.tar.gz"
  if wget --no-proxy --timeout=2 -qO /dev/null "$LIVECHECK_URL" 2>/dev/null; then
    mkdir -p "$REAL_HOME/yuruna"
    # --- REGION: https://yuruna.link/42e220c4-000e
    if wget --no-proxy --timeout=30 --tries=2 -qO- "$TARBALL_URL" | tar -xz -C "$REAL_HOME/yuruna"; then
      sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/yuruna" 2>/dev/null || true
      echo -e "\e[1;32m---- Yuruna framework available at $REAL_HOME/yuruna (early extract). ----\e[0m"
    else
      rm -rf "$REAL_HOME/yuruna"
      echo "yuruna: early tarball fetch failed -- will retry after apt phase."
    fi
  else
    echo "yuruna: host status service livecheck failed -- skipping early extract."
  fi
fi

# --- REGION: Disable services that may suspend the machine
echo "TESTHACK: Disabling services that may suspend the machine."
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

# --- REGION: Disable update notifier popups
echo "TESTHACK: Disabling update notifier popups that steal focus from the Terminal during tests."
sudo sed -i 's/^Prompt=.*/Prompt=never/' /etc/update-manager/release-upgrades 2>/dev/null || true
sudo tee /etc/apt/apt.conf.d/10periodic >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

# --- REGION: Update system packages
# See https://yuruna.link/4220a755-0006
echo ""
echo -e "\e[1;36m==== Update system packages ====\e[0m"
# Index fetches can be bounded safely because they do not run dpkg.
export YURUNA_APT_STALL_TIMEOUT_SECONDS="${YURUNA_RETRY_LIB_SAFE_STALL:+300}"
export YURUNA_RETRY_MAX_ATTEMPTS=2
apt_retry sudo apt-get update;
# Back to unbounded, default-ladder for everything below: these run dpkg
# transactions. Unset rather than re-assigning 5, so the lib stays the single
# place the default attempt count is written.
export YURUNA_APT_STALL_TIMEOUT_SECONDS=0
unset YURUNA_RETRY_MAX_ATTEMPTS
# dist-upgrade is a superset of upgrade; running both repeats resolver work.
apt_retry sudo apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y;
apt_retry sudo apt-get autoclean -y;
apt_retry sudo apt-get autoremove -y;
# Resolute has no deborphan candidate; madison distinguishes availability
# because apt-cache show and policy can succeed for un-installable packages.
if [ -n "$(apt-cache madison deborphan 2>/dev/null)" ]; then
  apt_retry sudo apt-get install deborphan -y;
  orphan_output=$(sudo deborphan)
  if [ -n "$orphan_output" ]; then
    mapfile -t orphans <<< "$orphan_output"
    apt_retry sudo apt-get -y remove --purge "${orphans[@]}"
  fi
  orphan_output=$(sudo deborphan --guess-data)
  if [ -n "$orphan_output" ]; then
    mapfile -t orphans <<< "$orphan_output"
    apt_retry sudo apt-get -y remove --purge "${orphans[@]}"
  fi
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

# --- REGION: Ensure Git is installed
echo ""
echo -e "\e[1;36m==== Ensure Git is installed ====\e[0m"
if ! command -v git >/dev/null 2>&1; then
  apt_retry sudo apt-get install -y git
fi
git --version

# --- REGION: Resolve framework and project URLs
# See https://yuruna.link/42fa6f45-000c
echo -e "\e[1;32m==== Resolve framework and project URLs ====\e[0m"
FRAMEWORK_URL=""
PROJECT_URL=""
if [ -r /etc/yuruna/host.env ]; then
  # shellcheck disable=SC1091
  . /etc/yuruna/host.env
fi
if yuruna_host_env; then
  CFG_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/control/test-config"
  if cfg_body=$(wget --no-proxy --no-cache --timeout=5 -qO- "$CFG_URL" 2>/dev/null); then
    FRAMEWORK_URL=$(printf '%s' "$cfg_body" | python3 -c $'import json,sys\ntry: print((json.load(sys.stdin).get("repositories") or {}).get("frameworkUrl",""))\nexcept Exception: print("")' 2>/dev/null || true)
    PROJECT_URL=$(printf '%s' "$cfg_body" | python3 -c $'import json,sys\ntry: print((json.load(sys.stdin).get("repositories") or {}).get("projectUrl",""))\nexcept Exception: print("")' 2>/dev/null || true)
  fi
fi

# The config endpoint lives ON the host, so a guest that cannot reach the host
# gets nothing from it -- exactly when it most needs a URL to clone from.
# host.env carries the same two URLs, baked at New-VM time, for that case.
: "${FRAMEWORK_URL:=${YURUNA_FRAMEWORK_URL:-}}"
: "${PROJECT_URL:=${YURUNA_PROJECT_URL:-}}"

# --- REGION: Keep git non-interactive
# See https://yuruna.link/4220a755-004f
export GIT_TERMINAL_PROMPT=0
if [ -x /usr/local/lib/yuruna/git-askpass.sh ]; then
    export GIT_ASKPASS=/usr/local/lib/yuruna/git-askpass.sh
fi

# --- REGION: Materialize the yuruna framework and project repos
# See https://yuruna.link/4220a755-004d
# See https://yuruna.link/42e220c4-000e
if [ ! -d "$REAL_HOME/yuruna" ]; then
  HOST_OK=false
  for host_attempt in 1 2; do
    if [ "$host_attempt" -eq 2 ]; then
      if ! yuruna_host_relocate; then
        echo "yuruna: host coordinates could not be refreshed - the pool directory has no live address for this host."
        break
      fi
      echo "yuruna: host coordinates refreshed; retrying the tarball fetch."
    else
      yuruna_host_env || break
    fi
    LIVECHECK_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/livecheck"
    TARBALL_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-archive.tar.gz"
    if wget --no-proxy --timeout=2 -qO /dev/null "$LIVECHECK_URL" 2>/dev/null; then
      echo "yuruna: fetching committed tarball from $TARBALL_URL"
      mkdir -p "$REAL_HOME/yuruna"
      if wget --no-proxy --timeout=30 --tries=2 -qO- "$TARBALL_URL" | tar -xz -C "$REAL_HOME/yuruna"; then
        HOST_OK=true
        break
      else
        echo "yuruna: tarball fetch/extract failed - falling back to git clone"
        rm -rf "$REAL_HOME/yuruna"
      fi
    fi
  done
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
  # --- REGION: https://yuruna.link/42e220c4-0005
  for project_attempt in 1 2; do
    if [ "$project_attempt" -eq 2 ]; then
      if ! yuruna_host_relocate; then
        echo "yuruna: host coordinates could not be refreshed - the pool directory has no live address for this host."
        break
      fi
      echo "yuruna: host coordinates refreshed; retrying the project tarball fetch."
    else
      yuruna_host_env || break
    fi
    PROJECT_LIVECHECK_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/livecheck"
    PROJECT_TARBALL_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-project-archive.tar.gz"
    if ! wget --no-proxy --timeout=2 -qO /dev/null "$PROJECT_LIVECHECK_URL" 2>/dev/null; then
      echo "yuruna: host status service did not answer at ${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}"
      continue
    fi
    echo "yuruna: trying project tarball at $PROJECT_TARBALL_URL"
    mkdir -p "$REAL_HOME/yuruna/project"
    if wget --no-proxy --timeout=30 --tries=2 -qO- "$PROJECT_TARBALL_URL" \
         | tar -xz -C "$REAL_HOME/yuruna/project" 2>/dev/null \
         && [ -n "$(ls -A "$REAL_HOME/yuruna/project" 2>/dev/null)" ]; then
      PROJECT_HOST_OK=true
      break
    else
      echo "yuruna: project tarball not served (or empty) - falling back to git clone"
      rm -rf "$REAL_HOME/yuruna/project"
    fi
  done
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

# --- REGION: Wait for network convergence
# See https://yuruna.link/4220a755-0014
# apt transactions can bounce the DHCP lease at the transaction tail;
# settle the link (max 30 s, never fatal) before the first host->guest SSH.
echo ""
echo -e "\e[1;36m==== Wait for network convergence ====\e[0m"
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

# --- REGION: https://yuruna.link/42e220c4-000e
echo -e "\e[1;32m==== Network ready. ====\e[0m"
