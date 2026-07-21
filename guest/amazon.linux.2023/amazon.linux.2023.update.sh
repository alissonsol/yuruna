#!/bin/bash
# Version: 2026.07.21
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

# --- REGION: https://yuruna.link/network#defining-yuruna-retry-lib
. /usr/local/lib/yuruna/yuruna-retry.sh
# Baked retry libs may default dnf attempts to a wall-clock bound -- the
# wrapped-apt teardown-hang trap class (the package manager blocks at
# end-of-transaction under a timeout(1) parent). Force unbounded regardless
# of the image's lib vintage; remove once no image predates the lib's
# unbounded default.
export YURUNA_DNF_STALL_TIMEOUT=0

# --- REGION: https://yuruna.link/memory#why-ubuntu-guest-update-scripts-install-powershell-first
# AL2023 ships no first-party pwsh package; GitHub-release tarball (both arches).
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
  # Verify the pwsh tarball against the release's published
  # hashes.sha256 before unpacking it (pwsh is the interpreter for all
  # downstream automation). The asset is UTF-16 LE (BOM+CRLF, Windows-
  # generated) -> normalize to UTF-8/LF. A genuine MISMATCH is fatal
  # (corruption/tamper); a hashes.sha256 that can't be fetched or parsed
  # after retries only WARNs and proceeds so a transient GitHub blip never
  # fails every guest's provisioning.
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
try {
    Install-Module -Name powershell-yaml -Scope AllUsers -Force -Verbose 4>&1
} catch {
    "INSTALL ERROR: $($_.Exception.Message)"
}

"--- Import + ConvertFrom-Yaml smoke ---"
# Install-Module can leave powershell-yaml ABSENT while writing only a
# non-terminating error: a corrupt/truncated .nupkg trips a hash mismatch and
# an invalid-zip "End of Central Directory record could not be found", which
# does not stop the block, so it would otherwise print "OK" and exit 0 -- a
# green guest with no powershell-yaml, and pwsh_retry's backoff never engages
# against what is usually a transient bad transfer. Verify the end state (the
# Get-Module -ListAvailable gate ConvertFrom-Content enforces at workload time)
# and exit non-zero on any gap so a fresh download is retried.
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

# --- REGION: https://yuruna.link/memory#why-ubuntu-guest-update-scripts-pre-extract-the-yuruna-tarball
# Tarball-only here: the git-clone fallback below needs git, which needs dnf.
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
# Settle the link (max 30 s, never fatal) before the first host->guest SSH.
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
