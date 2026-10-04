#!/bin/bash
# Version: 2026.10.04
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# --- REGION: Initialize environment
set -euo pipefail

# --- REGION: Detect architecture
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
# See https://yuruna.link/42e220c4-0005
# Detect virtualization independently from CPU architecture.
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
export YURUNA_DNF_STALL_TIMEOUT_SECONDS=0

# --- REGION: Re-read host coordinates per use
# See https://yuruna.link/4220a755-004d
if ! command -v yuruna_host_env >/dev/null 2>&1; then
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
fi

# A guest image can carry a retry lib older than this script. This copy of the
# lib's host probe -- four spaced asks, never one -- stays identical to it.
if ! command -v yuruna_host_livecheck >/dev/null 2>&1; then
yuruna_host_livecheck() {
    local livecheck_url="http://${YURUNA_STATUS_SERVICE_IP:-}:${YURUNA_STATUS_SERVICE_PORT:-}/livecheck"
    local rounds=4 gap=3 round=1
    while [ "$round" -le "$rounds" ]; do
        if wget --no-proxy --tries=1 --timeout=2 -qO /dev/null "$livecheck_url" 2>/dev/null; then
            if [ "$round" -gt 1 ]; then
                echo "yuruna: host status service answered on probe ${round}/${rounds} at ${YURUNA_STATUS_SERVICE_IP:-}:${YURUNA_STATUS_SERVICE_PORT:-}"
            fi
            return 0
        fi
        if [ "$round" -lt "$rounds" ]; then sleep "$gap"; fi
        round=$((round + 1))
    done
    return 1
}
fi

# --- REGION: Point dnf at the caching proxy
# See https://yuruna.link/42f6b05f-000d
# See https://yuruna.link/42e220c4-0005
CACHE_HOST=$(echo "${http_proxy:-}" | sed -E 's|^https?://([^:/]+).*|\1|')
if [ -z "$CACHE_HOST" ] && [ -r /etc/yuruna/host.env ]; then
    CACHE_HOST=$(sed -nE 's/^YURUNA_CACHING_PROXY_SERVICE_IP=([^[:space:]]+).*/\1/p' /etc/yuruna/host.env | head -n1)
fi
[ -z "$CACHE_HOST" ] && CACHE_HOST="yuruna-caching-proxy-service"
# --- REGION: https://yuruna.link/42e220c4-0005
if ! curl -s --max-time 10 -o /dev/null "http://${CACHE_HOST}:3128" 2>/dev/null; then
    CACHE_HOST=""
fi

if [ -n "$CACHE_HOST" ]; then
    echo "Caching proxy: ${CACHE_HOST} -- dnf and this script's downloads go through it."
    # See https://yuruna.link/42f6b05f-000d
    # Replace the proxy under [main] so it applies to every repository.
    sudo sed -i '/^proxy[[:space:]]*=/d' /etc/dnf/dnf.conf
    sudo sed -i "/^\[main\]/a proxy=http://${CACHE_HOST}:3128" /etc/dnf/dnf.conf
    # sed succeeds on no match; verify that [main] actually received the proxy.
    if ! grep -q "^proxy=http://${CACHE_HOST}:3128\$" /etc/dnf/dnf.conf; then
        echo "Note: /etc/dnf/dnf.conf has no [main] section to hold the proxy key; dnf reaches the upstreams directly."
    fi
    YURUNA_STATUS_SERVICE_IP="${YURUNA_STATUS_SERVICE_IP:-}"
    if [ -r /etc/yuruna/host.env ]; then
        YURUNA_STATUS_SERVICE_IP=$(sed -nE 's/^YURUNA_STATUS_SERVICE_IP=([^[:space:]]+).*/\1/p' /etc/yuruna/host.env | head -n1)
    fi
    NO_PROXY_LIST="localhost,127.0.0.1,${CACHE_HOST},10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,::1"
    [ -n "$YURUNA_STATUS_SERVICE_IP" ] && NO_PROXY_LIST="${YURUNA_STATUS_SERVICE_IP},${NO_PROXY_LIST}"
    export http_proxy="http://${CACHE_HOST}:3128/"
    export https_proxy="http://${CACHE_HOST}:3129/"
    export no_proxy="$NO_PROXY_LIST"
    export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy" NO_PROXY="$no_proxy"
    _ca_rc=0
    yuruna_ca_selfheal || _ca_rc=$?
    if [ "$_ca_rc" -eq 2 ]; then
        echo "Caching proxy: bump CA unavailable -- tunneling HTTPS through the CONNECT port instead (uncached)."
        export https_proxy="http://${CACHE_HOST}:3128/"
        export HTTPS_PROXY="$https_proxy"
    fi
    # See https://yuruna.link/42f6b05f-000d
    # Persist proxy settings for workload shells that do not inherit this environment.
    sudo tee /etc/profile.d/yuruna-proxy.sh >/dev/null <<EOF
export http_proxy="${http_proxy}"
export https_proxy="${https_proxy}"
export no_proxy="${no_proxy}"
export HTTP_PROXY="${http_proxy}"
export HTTPS_PROXY="${https_proxy}"
export NO_PROXY="${no_proxy}"
EOF
    sudo chmod 0644 /etc/profile.d/yuruna-proxy.sh
else
    # Clear stale proxy state so the direct fallback remains usable.
    echo "Caching proxy: none answering -- dnf and downloads go to the upstreams directly."
    sudo sed -i '/^proxy[[:space:]]*=/d' /etc/dnf/dnf.conf
    sudo rm -f /etc/profile.d/yuruna-proxy.sh
    unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY
fi

# --- REGION: Ensure PowerShell is installed
# See https://yuruna.link/42d69dfa-0036
# AL2023 ships no first-party pwsh package; GitHub-release tarball (both arches).
echo ""
echo -e "\e[1;36m==== Ensure PowerShell is installed ====\e[0m"
if ! command -v pwsh >/dev/null 2>&1; then
  # Keep curl-minimal: installing the full curl package conflicts on AL2023.
  dnf_retry sudo dnf -y install libicu tar gzip
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl not on PATH (neither curl nor curl-minimal); cannot fetch PowerShell tarball." >&2
    exit 1
  fi

  if ! command -v yuruna_install_pwsh_tarball >/dev/null 2>&1; then
    # --- REGION: yuruna_install_pwsh_tarball
    # See https://yuruna.link/42d69dfa-0036
    # Preserve the checksum gate when the baked retry library lacks this helper.
    yuruna_install_pwsh_tarball() (
        local arch="$1" ps_arch tag version package url want got
        case "$arch" in x86_64) ps_arch=x64;; aarch64) ps_arch=arm64;; *) return 1;; esac
        local work
        work="$(mktemp -d /tmp/yuruna-pwsh.XXXXXX)" || return 1
        trap 'rm -rf "$work"' EXIT
        tag="$(curl_retry -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/PowerShell/PowerShell/releases/latest)" || return 1
        tag="${tag##*/}"
        [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid PowerShell release tag" >&2; return 1; }
        version="${tag#v}"; package="powershell-${version}-linux-${ps_arch}.tar.gz"
        url="https://github.com/PowerShell/PowerShell/releases/download/${tag}/${package}${YurunaCacheContent:+?nocache=${YurunaCacheContent}}"
        curl_retry -fsSL -o "$work/package.tar.gz" "$url" || return 1
        curl_retry -fsSL -o "$work/hashes.sha256" "https://github.com/PowerShell/PowerShell/releases/download/${tag}/hashes.sha256" || return 1
        local bom
        bom="$(od -An -tx1 -N2 "$work/hashes.sha256" | tr -d ' \n')"
        if [ "$bom" = fffe ] || [ "$bom" = feff ]; then
            iconv -f UTF-16 -t UTF-8 "$work/hashes.sha256" | tr -d '\r' > "$work/hashes.norm" || return 1
        else tr -d '\r' < "$work/hashes.sha256" > "$work/hashes.norm"; fi
        want="$(LC_ALL=C awk -v p="$package" '$2==p || $2=="*"p {print $1;exit}' "$work/hashes.norm")"
        got="$(sha256sum "$work/package.tar.gz" | awk '{print $1}')"
        [[ "$want" =~ ^[0-9a-fA-F]{64}$ ]] && [ "${want,,}" = "$got" ] || { echo "PowerShell checksum missing or mismatched" >&2; return 1; }
        sudo mkdir -p /opt/microsoft/powershell/7 || return 1
        sudo tar zxf "$work/package.tar.gz" -C /opt/microsoft/powershell/7 || return 1
        sudo chmod +x /opt/microsoft/powershell/7/pwsh || return 1
        sudo ln -sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh
    )
  fi
  yuruna_install_pwsh_tarball "$ARCH"
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
# Tarball-only here: the git-clone fallback below needs git, which needs dnf.
echo ""
echo -e "\e[1;36m==== Early yuruna framework extraction ====\e[0m"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
if [ -r /etc/yuruna/host.env ]; then
  # shellcheck disable=SC1091
  . /etc/yuruna/host.env
fi
if yuruna_host_env && [ ! -d "$REAL_HOME/yuruna" ]; then
  TARBALL_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-archive.tar.gz"
  if yuruna_host_livecheck; then
    mkdir -p "$REAL_HOME/yuruna"
    # --- REGION: https://yuruna.link/42e220c4-000e
    if wget --no-proxy --timeout=30 --tries=2 -qO- "$TARBALL_URL" | tar -xz -C "$REAL_HOME/yuruna"; then
      sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/yuruna" 2>/dev/null || true
      echo -e "\e[1;32m---- Yuruna framework available at $REAL_HOME/yuruna (early extract). ----\e[0m"
    else
      rm -rf "$REAL_HOME/yuruna"
      echo "yuruna: early tarball fetch failed -- will retry after dnf phase."
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
sudo systemctl disable --now packagekit.service packagekit-offline-update.service 2>/dev/null || true
sudo systemctl disable --now dnf-automatic.timer dnf-automatic-notifyonly.timer dnf-automatic-install.timer 2>/dev/null || true
sudo -u "$REAL_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u "$REAL_USER")/bus" \
    gsettings set org.gnome.software download-updates false 2>/dev/null || true

# --- REGION: Update system packages
echo ""
echo -e "\e[1;36m==== Update system packages ====\e[0m"
# dnf update and dnf upgrade are aliases; one call covers both.
dnf_retry sudo dnf upgrade -y
dnf_retry sudo dnf autoremove -y

# --- REGION: Ensure Git is installed
echo ""
echo -e "\e[1;36m==== Ensure Git is installed ====\e[0m"
if ! command -v git >/dev/null 2>&1; then
  dnf_retry sudo dnf -y install git
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
  if cfg_body=$(wget --no-proxy --no-cache --tries=1 --timeout=5 -qO- "$CFG_URL" 2>/dev/null); then
    FRAMEWORK_URL=$(printf '%s' "$cfg_body" | python3 -c $'import json,sys\ntry: print((json.load(sys.stdin).get("repositories") or {}).get("frameworkUrl",""))\nexcept Exception: print("")' 2>/dev/null || true)
    PROJECT_URL=$(printf '%s' "$cfg_body" | python3 -c $'import json,sys\ntry: print((json.load(sys.stdin).get("repositories") or {}).get("projectUrl",""))\nexcept Exception: print("")' 2>/dev/null || true)
  fi
fi

# See https://yuruna.link/42fa6f45-000c
# host.env keeps clone URLs available while the status service is unreachable.
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
if command -v yuruna_materialize_repositories >/dev/null 2>&1; then
  yuruna_materialize_repositories "$REAL_HOME" "$REAL_USER" "$FRAMEWORK_URL" "$PROJECT_URL"
else
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
    TARBALL_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-archive.tar.gz"
    if yuruna_host_livecheck; then
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
    PROJECT_TARBALL_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-project-archive.tar.gz"
    if ! yuruna_host_livecheck; then
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

fi

# --- REGION: Wait for network convergence
# See https://yuruna.link/4220a755-0014
# Settle the link (max 30 s, never fatal) before the first host->guest SSH.
echo ""
echo -e "\e[1;36m==== Wait for network convergence ====\e[0m"
if command -v yuruna_wait_network >/dev/null 2>&1; then
  yuruna_wait_network
else
if systemctl is-active --quiet NetworkManager && command -v nm-online >/dev/null 2>&1; then
  nm-online -q -t 30 || echo "WARNING: nm-online did not report 'online' within 30s; continuing."
elif systemctl is-active --quiet systemd-networkd; then
  # See https://yuruna.link/4220a755-0014
  # Resolve the non-PATH wait tool; --any waits for the single guest NIC.
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

fi

# --- REGION: https://yuruna.link/42e220c4-000e
echo -e "\e[1;32m==== Network ready. ====\e[0m"
