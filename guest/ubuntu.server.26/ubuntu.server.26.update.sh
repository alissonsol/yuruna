#!/bin/bash
# Version: 2026.07.14
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

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

# --- REGION: https://yuruna.link/network#defining-yuruna-retry-lib
. /usr/local/lib/yuruna/yuruna-retry.sh
# Baked retry libs may default apt attempts to a wall-clock bound -- the
# wrapped-apt teardown-hang trap class (apt blocks at end-of-transaction
# under a timeout(1) parent). Force unbounded regardless of the image's
# lib vintage; remove once no image predates the lib's unbounded default.
export YURUNA_APT_STALL_TIMEOUT=0

# --- REGION: https://yuruna.link/network#caching-proxy-ca-cert-rc60-gate
# CA self-heal: if this guest is routed through the SSL-bump proxy (:3129) but
# does not trust its CA -- e.g. the caching proxy was unreachable when the host
# built this guest's seed, so an empty CA was baked -- every HTTPS returns a
# "self-signed certificate in certificate chain" error (curl rc=60) and the run
# aborts on the first github HTTPS below. By now the cache has typically
# recovered, so the CA is re-fetchable from the host status server (which
# live-reads the current cache) over the RFC1918-permitted plain-HTTP path.
# Installing it does NOT relax egress: HTTPS still flows through the auditable
# bump; this only supplies the trust anchor the bump already expects.
# Best-effort and non-fatal -- a missing host, empty body, or absent host.env
# degrades to the existing rc=60 with a clear diagnostic, never a silent pass.
# See project_sslbump_ca_gating_durable_fix.
yuruna_ca_selfheal() {
  # Guard on the bump port with a boundary so a no-cache/direct guest (empty
  # https_proxy) or a proxy on some other port is a hard no-op.
  printf '%s' "${https_proxy:-}" | grep -qE ':3129/?($|[^0-9])' || return 0
  # Already trusted? A bump HTTPS that verifies needs no repair.
  if wget -q --spider --timeout=15 --tries=1 "https://github.com/" 2>/dev/null; then
    return 0
  fi
  if [ -r /etc/yuruna/host.env ]; then . /etc/yuruna/host.env; fi
  if [ -z "${YURUNA_HOST_IP:-}" ] || [ -z "${YURUNA_HOST_PORT:-}" ]; then
    echo "CA self-heal: bump HTTPS untrusted and no host.env coordinates; cannot recover CA." >&2
    return 0
  fi
  echo "CA self-heal: bump HTTPS untrusted; fetching CA from host status server ..."
  local ca_tmp
  ca_tmp=$(mktemp) || return 0
  if wget --no-proxy --timeout=10 --tries=2 -qO "$ca_tmp" \
        "http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/ca.crt" \
     && [ -s "$ca_tmp" ] && grep -q 'BEGIN CERTIFICATE' "$ca_tmp"; then
    sudo install -m 0644 "$ca_tmp" /usr/local/share/ca-certificates/yuruna-squid-ca.crt || true
    sudo update-ca-certificates >/dev/null 2>&1 || true
    if wget -q --spider --timeout=15 --tries=1 "https://github.com/" 2>/dev/null; then
      echo "CA self-heal: OK -- bump HTTPS now trusted."
    else
      echo "CA self-heal: CA installed but bump still untrusted (stale/wrong CA, or cache unreachable); HTTPS through the bump will still fail." >&2
    fi
  else
    echo "CA self-heal: host status server served no usable CA (cache may still be unreachable); HTTPS through the bump will still fail." >&2
  fi
  rm -f "$ca_tmp"
  return 0
}
yuruna_ca_selfheal

# --- REGION: https://yuruna.link/memory#why-ubuntu-guest-update-scripts-install-powershell-first
echo ""
echo -e "\e[1;36m==== PowerShell ====\e[0m"
if ! command -v pwsh >/dev/null 2>&1; then
  case "$ARCH" in
    x86_64)  PS_ARCH="x64" ;;
    aarch64) PS_ARCH="arm64" ;;
  esac
  apt_retry sudo apt-get install -y curl tar gzip

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

# --- REGION: https://yuruna.link/memory#why-ubuntu--al2023-guest-update-scripts-wrap-install-module-powershell-yaml-with-pwsh_retry
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

# --- REGION: https://yuruna.link/memory#why-ubuntu-guest-update-scripts-pre-extract-the-yuruna-tarball
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
      echo "yuruna: early tarball fetch failed -- will retry after apt phase."
    fi
  else
    echo "yuruna: host status server livecheck failed -- skipping early extract."
  fi
fi

echo "TESTHACK: Disabling services that may suspend the machine."
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

echo "TESTHACK: Disabling update notifier popups that steal focus from the Terminal during tests."
sudo sed -i 's/^Prompt=.*/Prompt=never/' /etc/update-manager/release-upgrades 2>/dev/null || true
sudo tee /etc/apt/apt.conf.d/10periodic >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

echo ""
echo -e "\e[1;36m==== system packages update ====\e[0m"
apt_retry sudo apt-get update;
# dist-upgrade is a superset of upgrade; running both repeats resolver work.
apt_retry sudo apt-get -o APT::Get::Always-Include-Phased-Updates=true dist-upgrade -y;
apt_retry sudo apt-get autoclean -y;
apt_retry sudo apt-get autoremove -y;
# deborphan was dropped from Ubuntu 26 (resolute) repos; skip the orphan
# purge on releases that no longer ship it instead of hard-failing.
# apt-cache show / policy both succeed for "referenced but not installable"
# packages, so probe via madison (empty output = no candidate in any source).
if [ -n "$(apt-cache madison deborphan 2>/dev/null)" ]; then
  apt_retry sudo apt-get install deborphan -y;
  orphans=$(sudo deborphan)
  if [ -n "$orphans" ]; then apt_retry sudo apt-get -y remove --purge $orphans; fi
  orphans=$(sudo deborphan --guess-data)
  if [ -n "$orphans" ]; then apt_retry sudo apt-get -y remove --purge $orphans; fi
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo ""
echo -e "\e[1;36m==== Git ====\e[0m"
if ! command -v git >/dev/null 2>&1; then
  apt_retry sudo apt-get install -y git
fi
git --version

# --- REGION: https://yuruna.link/definition#defining-the-two-source-scheme-for-framework-and-project-urls
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

# The config endpoint lives ON the host, so a guest that cannot reach the host
# gets nothing from it -- exactly when it most needs a URL to clone from.
# host.env carries the same two URLs, baked at New-VM time, for that case.
: "${FRAMEWORK_URL:=${YURUNA_FRAMEWORK_URL:-}}"
: "${PROJECT_URL:=${YURUNA_PROJECT_URL:-}}"

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

# --- REGION: https://yuruna.link/network#guest-update-network-convergence-before-handoff
# apt transactions can bounce the DHCP lease at the transaction tail;
# settle the link (max 30 s, never fatal) before the first host->guest SSH.
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

# A definite end-of-script line keeps the console repainting up to the
# handoff, so the FETCHED AND EXECUTED marker lands adjacent to real output
# instead of after a silent gap a headless capture surface would freeze on.
# See feedback_frozen_capture_feed_idle_tail.
echo -e "\e[1;32m==== Network ready. ====\e[0m"
