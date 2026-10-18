#!/bin/bash
# Version: 2026.10.18.1
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# See https://yuruna.link/42e220c4-0005
# See https://yuruna.link/4207d71a-000c
# --- REGION: Initialize environment
set -euo pipefail

# Export HOME for Go module-cache discovery under cloud-init.
export HOME="${HOME:-/root}"

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# --- REGION: Detect architecture
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
case "$ARCH" in
  x86_64|aarch64) ;;
  *)
    echo "WARNING: Unsupported architecture: $ARCH (need x86_64 or aarch64)." >&2
    exit 1
    ;;
esac

# --- REGION: Load retry helpers
# Optional on service guests before the update workload has run.
if [ -r /usr/local/lib/yuruna/yuruna-retry.sh ]; then
  # --- REGION: https://yuruna.link/4220a755-0003
  . /usr/local/lib/yuruna/yuruna-retry.sh
  # See https://yuruna.link/4220a755-0005
  # Package transactions stay unbounded, including with an older baked retry library.
  export YURUNA_APT_STALL_TIMEOUT_SECONDS=0
fi

# --- REGION: Service user
# Prefer cloud-init's account; otherwise use an explicit override or the current caller.
# The CIFS mount maps every file to this user's uid/gid.
if id -u pool-control-service-admin >/dev/null 2>&1; then
  SERVICE_USER=pool-control-service-admin
else
  SERVICE_USER="${SERVICE_USER:-$(id -un)}"
fi
echo "Service user: $SERVICE_USER"
# --- REGION: Load service helpers
# Load from the framework checkout even when this entry script was fetched to /tmp.
SERVICE_LIB=''
for candidate in "$HOME/yuruna" "/home/$SERVICE_USER/yuruna" /home/*/yuruna; do
  if [ -r "$candidate/automation/yuruna-service-bringup.sh" ]; then
    SERVICE_LIB="$candidate/automation/yuruna-service-bringup.sh"; break
  fi
done
[ -n "$SERVICE_LIB" ] || { echo "Missing framework automation/yuruna-service-bringup.sh" >&2; exit 1; }
# shellcheck source=../../automation/yuruna-service-bringup.sh
. "$SERVICE_LIB"

# --- REGION: Service locale
# See https://yuruna.link/42fffc2c-000d
# Use the canonical seeded locale; pseudo locales require explicit opt-in.
# See https://yuruna.link/42e220c4-000f
# Existing VMs may carry locale settings only in pool.env.
GLOBALIZATION_ENV=/etc/yuruna/globalization.env
[ -e "$GLOBALIZATION_ENV" ] || GLOBALIZATION_ENV=/etc/yuruna/pool.env
POOL_CONTROL_LANGUAGE="$(sed -n 's/^YURUNA_LANGUAGE=//p' "$GLOBALIZATION_ENV" 2>/dev/null | head -1 || true)"
[ -n "$POOL_CONTROL_LANGUAGE" ] || POOL_CONTROL_LANGUAGE=auto
POOL_CONTROL_ALLOW_PSEUDO_LOCALE="$(sed -n 's/^YURUNA_ALLOW_PSEUDO_LOCALE=//p' "$GLOBALIZATION_ENV" 2>/dev/null | head -1 || true)"
[ "$POOL_CONTROL_ALLOW_PSEUDO_LOCALE" = true ] || POOL_CONTROL_ALLOW_PSEUDO_LOCALE=false

# --- REGION: Service tunables
# See https://yuruna.link/42fffc2c-000d
HTTP_ADDR="${POOL_CONTROL_HTTP_ADDR:-0.0.0.0:80}"
PRESENCE_INTERVAL="${POOL_CONTROL_PRESENCE_INTERVAL:-2m}"
AUTH_TOKEN_FILE="${POOL_CONTROL_AUTH_TOKEN_FILE:-/etc/yuruna/internal-auth.key}"
SCAN_CIDR="${POOL_CONTROL_SCAN_CIDR:-}"
SCAN_PORT="${POOL_CONTROL_SCAN_PORT:-8080}"
SCAN_INTERVAL="${POOL_CONTROL_SCAN_INTERVAL-15m}"
[ -n "$SCAN_INTERVAL" ] || SCAN_INTERVAL=0

# Aggregator URL + host id + host ip from the shared env files (same as stash).
AGGREGATOR_URL="$(sed -n 's/^YURUNA_AGGREGATOR_URL=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
HOST_ID="$(sed -n 's/^YURUNA_HOST_ID=//p' /etc/yuruna/host.env 2>/dev/null | head -1 || true)"
CONFIGURATION_GIT_URL="$(sed -n 's/^YURUNA_POOL_CONFIGURATION_GIT_URL=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
# Existing guest seeds can still carry the older key. An explicitly present
# canonical key, including an empty value, always takes precedence.
if ! grep -q '^YURUNA_POOL_CONFIGURATION_GIT_URL=' /etc/yuruna/pool.env 2>/dev/null; then
  CONFIGURATION_GIT_URL="$(sed -n 's/^YURUNA_POOL_INTENT_GIT_URL=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
fi

# --- REGION: Storage paths
# Pool NAS mount (CIFS) -> state dir. NAS host/share/cred come from pool.env,
# matching Test.PoolStorage's networkStorage.poolStorageNetworkPath contract.
POOL_NAS_UNC="$(sed -n 's/^YURUNA_POOL_NETWORK_PATH=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
POOL_NAS_IP="$(sed -n 's/^YURUNA_POOL_NETWORK_IP=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
POOL_NAS_USER="$(sed -n 's/^YURUNA_POOL_NETWORK_USER=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
echo "Pool NAS user: ${POOL_NAS_USER:-(none configured)}"
MOUNT=/mnt/yuruna-pool
STATE_DIR="$MOUNT/pool-control-service"
# --- REGION: https://yuruna.link/429f3d06-0040
CONFIGURATION_STORE="$MOUNT/pool-configuration.git"
if [[ "$CONFIGURATION_GIT_URL" == "$MOUNT/pool-intent.git" ]]; then
  CONFIGURATION_GIT_URL="$CONFIGURATION_STORE"
fi

# Locate the checkout before using its current shared bootstrap helpers.
locate_repo_dir() {
  yuruna_service_find_repo test/extension/pool-control-service/server
}
REPO_DIR="$(locate_repo_dir)" || {
  echo "pool-control-service: could not locate test/extension/pool-control-service/server/go.mod under any /home/*/yuruna." >&2
  echo "Ensure the yuruna framework is cloned on this VM before running this script." >&2
  exit 1
}
if [ -r "$REPO_DIR/automation/yuruna-retry.sh" ]; then
  . "$REPO_DIR/automation/yuruna-retry.sh"
fi

# --- REGION: Package dependencies
echo ""
echo -e "\e[1;36m==== Package dependencies ====\e[0m"
# libcap2-bin supplies setcap for the DIRECT (non-systemd) launch path; under
# systemd the load-bearing grant is AmbientCapabilities (see the unit below).
yuruna_service_packages golang-go git cifs-utils wget curl ca-certificates libcap2-bin
go version
# --- REGION: https://yuruna.link/42d69dfa-0036
# Resolute has no PowerShell package; use the cross-version release tarball.
if ! command -v pwsh >/dev/null 2>&1; then
  if command -v apt_retry >/dev/null 2>&1; then
    apt_retry sudo apt-get install -y curl tar gzip
  else
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar gzip
  fi
  # See https://yuruna.link/42d69dfa-0036
  # Retain a bounded curl fallback for images without the retry library.
  if ! command -v curl_retry >/dev/null 2>&1; then
    curl_retry() { curl --retry 5 --retry-delay 5 --retry-connrefused "$@"; }
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
# See https://yuruna.link/42e220c4-000f
# PowerShell is required for pool-admin commands; fail before starting an unusable daemon.
if ! command -v pwsh >/dev/null 2>&1; then
  echo "pool-control-service: pwsh is NOT installed; the daemon cannot run any pool-admin CLI. Aborting." >&2
  exit 1
fi
PWSH_BIN="$(command -v pwsh)"
pwsh --version
# The daemon needs a working YAML parser before it can administer configuration.
for attempt in 1 2 3; do
  if sudo pwsh -NoProfile -NonInteractive -Command "\$ErrorActionPreference = 'Stop'; if (-not (Get-Module -ListAvailable powershell-yaml)) { Install-Module powershell-yaml -Scope AllUsers -Force -AcceptLicense -ErrorAction Stop }; Import-Module powershell-yaml -ErrorAction Stop; if ((ConvertFrom-Yaml 'k: v').k -cne 'v') { throw 'powershell-yaml smoke check failed' }"; then
    break
  fi
  if [ "$attempt" -eq 3 ]; then
    echo 'pool-control-service: powershell-yaml is unavailable after three attempts; aborting.' >&2
    exit 1
  fi
  sleep 5
done

# --- REGION: Locate the daemon source
# The checkout was resolved once above; build from that same source tree.
SERVER_DIR="$REPO_DIR/test/extension/pool-control-service/server"
VERSION_STR=$(cat "$REPO_DIR/VERSION" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
[ -n "$VERSION_STR" ] || VERSION_STR=dev

# --- REGION: Build
# See https://yuruna.link/42e220c4-000f
echo ""
echo -e "\e[1;36m==== Building pool-control-service ($VERSION_STR) from $SERVER_DIR ====\e[0m"
BUILD="$(yuruna_service_stage "$SERVER_DIR" 'pool-control-service')"
# One EXIT trap for every temp path this script makes: the configuration seed
# below is created later, and a set -e abort between its mktemp and its own
# removal would otherwise leave it in this long-lived VM's /tmp.
SEED_TMP=""
trap 'rm -rf -- "$BUILD"; [ -z "${SEED_TMP:-}" ] || sudo -u "$SERVICE_USER" rm -rf -- "$SEED_TMP"' EXIT
yuruna_service_build "$BUILD" 'pool-control-service' "$VERSION_STR"

# --- REGION: Install the binary
yuruna_service_install "$BUILD/server/pool-control-service" /usr/local/bin/pool-control-service

# --- REGION: Storage directories
# Mount the pool NAS for the state dir (best-effort; the daemon degrades to no
# persistence if the mount is absent).
if [[ -n "$POOL_NAS_UNC" ]]; then
  sudo mkdir -p "$MOUNT"
  # --- REGION: https://yuruna.link/428405a0-000b
  MOUNT_OPTS="credentials=/etc/yuruna/pool-nas.cifs.cred,vers=3.0,uid=$(id -u "$SERVICE_USER"),gid=$(id -g "$SERVICE_USER"),file_mode=0666,dir_mode=0777,noperm,nofail,_netdev"
  # ip= carries the mount past a server name the guest has no way to resolve.
  [ -n "$POOL_NAS_IP" ] && MOUNT_OPTS="$MOUNT_OPTS,ip=$POOL_NAS_IP"
  # Persist via fstab so the state dir survives a VM reboot and systemd
  # exposes a .mount unit the daemon can order After=.
  if ! grep -q " $MOUNT cifs " /etc/fstab 2>/dev/null; then
    printf '%s %s cifs %s 0 0\n' "$POOL_NAS_UNC" "$MOUNT" "$MOUNT_OPTS" | sudo tee -a /etc/fstab >/dev/null
  fi
  sudo systemctl daemon-reload
  if ! mountpoint -q "$MOUNT"; then
    sudo timeout 60 mount "$MOUNT" || echo "pool-control-service: NAS mount failed; persistence disabled" >&2
  fi
fi
# Do not create state below an unmounted NAS path; a later mount would shadow it.
# An empty path disables persistence without recreating the local directory.
if mountpoint -q "$MOUNT" 2>/dev/null; then
  # No chown on the mounted share: the uid/gid mount options have already placed
  # ownership and a chown can lock the host out.
  sudo mkdir -p "$STATE_DIR" 2>/dev/null || true
else
  echo "pool-control-service: $MOUNT is not mounted; state persistence is off (a state dir created here would be shadowed by a later mount)." >&2
  STATE_DIR=''
fi

# --- REGION: Configuration store bootstrap
# See https://yuruna.link/42e220c4-000f
if mountpoint -q "$MOUNT" 2>/dev/null && [[ ! -e "$CONFIGURATION_STORE" && -d "$MOUNT/pool-intent.git/refs" ]]; then
  sudo -u "$SERVICE_USER" mv "$MOUNT/pool-intent.git" "$CONFIGURATION_STORE"
fi
if [[ -z "$CONFIGURATION_GIT_URL" ]] && mountpoint -q "$MOUNT" 2>/dev/null; then
  CONFIGURATION_GIT_URL="$CONFIGURATION_STORE"
fi

# See https://yuruna.link/42e220c4-000f
# Initialize every resolved local configuration store with schema-valid empty pools on main.
if [[ -n "$CONFIGURATION_GIT_URL" && "$CONFIGURATION_GIT_URL" != *://* ]] && ! sudo -u "$SERVICE_USER" git -C "$CONFIGURATION_GIT_URL" show-ref --verify --quiet refs/heads/main; then
  # See https://yuruna.link/42e220c4-000f
  # An unmounted NAS path must not hide locally written configuration when it later mounts.
  if [[ "$CONFIGURATION_GIT_URL" == "$MOUNT"/* ]] && ! mountpoint -q "$MOUNT" 2>/dev/null; then
    echo "pool-control-service: $MOUNT is not mounted; refusing to create $CONFIGURATION_GIT_URL on local disk (a later mount would shadow it)." >&2
    CONFIGURATION_GIT_URL=''
  else
    echo -e "\e[1;36m==== Initializing pool configuration store at $CONFIGURATION_GIT_URL ====\e[0m"
    # --- REGION: https://yuruna.link/42e220c4-0005
    if sudo -u "$SERVICE_USER" git init --bare --initial-branch=main "$CONFIGURATION_GIT_URL" >/dev/null 2>&1 &&
       sudo -u "$SERVICE_USER" git -C "$CONFIGURATION_GIT_URL" config core.fileMode false &&
       # See https://yuruna.link/42e220c4-000f
       # Use receive.updateServerInfo; CIFS cannot preserve an executable post-update hook.
       sudo -u "$SERVICE_USER" git -C "$CONFIGURATION_GIT_URL" config receive.updateServerInfo true; then
      SEED_TMP="$(sudo -u "$SERVICE_USER" mktemp -d)"
      sudo -u "$SERVICE_USER" git -C "$SEED_TMP" init -q --initial-branch=main
      sudo -u "$SERVICE_USER" git -C "$SEED_TMP" config core.fileMode false
      # See https://yuruna.link/42e220c4-000f
      # Match the current pools schema so the first write passes validation.
      printf 'schemaVersion: 4\npools: []\n' | sudo -u "$SERVICE_USER" tee "$SEED_TMP/pools.yml" >/dev/null
      sudo -u "$SERVICE_USER" git -C "$SEED_TMP" add -A
      sudo -u "$SERVICE_USER" git -C "$SEED_TMP" \
        -c user.name=yuruna -c user.email=pool@yuruna.local commit -q -m 'seed pool configuration'
      if sudo -u "$SERVICE_USER" git -C "$SEED_TMP" push -q "$CONFIGURATION_GIT_URL" HEAD:main; then
        # Keep the dumb-HTTP indexes current so the proxy can serve this repo
        # read-only to runners without a smart-HTTP backend.
        sudo -u "$SERVICE_USER" git -C "$CONFIGURATION_GIT_URL" update-server-info || true
        echo "pool-control-service: configuration store seeded at $CONFIGURATION_GIT_URL (empty, schema-valid)"
      else
        echo "pool-control-service: could not seed $CONFIGURATION_GIT_URL; the UI will report an unreadable store." >&2
      fi
      sudo -u "$SERVICE_USER" rm -rf "$SEED_TMP"
    else
      echo "pool-control-service: could not create $CONFIGURATION_GIT_URL; the UI will report an unreadable store." >&2
    fi
  fi
fi
if [[ -n "$CONFIGURATION_GIT_URL" && "$CONFIGURATION_GIT_URL" != *://* ]]; then
  # See https://yuruna.link/42e220c4-000f
  # Permit diagnostic Git reads despite CIFS mapping ownership to the service user.
  sudo git config --system --add safe.directory "$CONFIGURATION_GIT_URL" 2>/dev/null || true
  if [[ -d "$CONFIGURATION_GIT_URL/refs" ]]; then
    echo "pool-control-service: configuration store -> $CONFIGURATION_GIT_URL (writable)"
  fi
fi
if [[ -z "$CONFIGURATION_GIT_URL" ]]; then
  echo "pool-control-service: no configuration store resolved (pool NAS unmounted and no seeded URL); the UI will start read-only and report why on /diagnostics." >&2
fi

# --- REGION: Environment file
echo ""
echo -e "\e[1;36m==== /etc/yuruna/pool-control-service.env ====\e[0m"
sudo mkdir -p /etc/yuruna
sudo tee /etc/yuruna/pool-control-service.env >/dev/null <<EOF
POOL_CONTROL_HTTP_ADDR=$HTTP_ADDR
POOL_CONTROL_PWSH=$PWSH_BIN
POOL_CONTROL_REPO_DIR=$REPO_DIR
POOL_CONTROL_AGGREGATOR_URL=$AGGREGATOR_URL
POOL_CONTROL_HOST_ID=$HOST_ID
POOL_CONTROL_CONFIGURATION_GIT_URL=$CONFIGURATION_GIT_URL
POOL_CONTROL_STATE_DIR=$STATE_DIR
POOL_CONTROL_PRESENCE_INTERVAL=$PRESENCE_INTERVAL
POOL_CONTROL_AUTH_TOKEN_FILE=$AUTH_TOKEN_FILE
POOL_CONTROL_SCAN_CIDR=$SCAN_CIDR
POOL_CONTROL_SCAN_PORT=$SCAN_PORT
POOL_CONTROL_SCAN_INTERVAL=$SCAN_INTERVAL
POOL_CONTROL_LANGUAGE=$POOL_CONTROL_LANGUAGE
POOL_CONTROL_ALLOW_PSEUDO_LOCALE=$POOL_CONTROL_ALLOW_PSEUDO_LOCALE
EOF

# --- REGION: systemd unit
echo ""
echo -e "\e[1;36m==== /etc/systemd/system/pool-control-service.service ====\e[0m"
sudo tee /etc/systemd/system/pool-control-service.service >/dev/null <<EOF
# --- REGION: [Unit]
[Unit]
Description=Yuruna Pool control service
Documentation=https://yuruna.link/4207d71a-000c
# See https://yuruna.link/42e220c4-000f
# Order after the NAS mount without requiring it; offline service startup is supported.
After=network-online.target mnt-yuruna\x2dpool.mount
Wants=network-online.target
# --- REGION: [Service]
[Service]
Type=simple
User=$SERVICE_USER
EnvironmentFile=/etc/yuruna/pool-control-service.env
ExecStart=/usr/local/bin/pool-control-service --http-addr=\${POOL_CONTROL_HTTP_ADDR} --repo-dir=\${POOL_CONTROL_REPO_DIR} --pwsh=\${POOL_CONTROL_PWSH} --aggregator-url=\${POOL_CONTROL_AGGREGATOR_URL} --host-id=\${POOL_CONTROL_HOST_ID} --configuration-git-url=\${POOL_CONTROL_CONFIGURATION_GIT_URL} --state-dir=\${POOL_CONTROL_STATE_DIR} --presence-interval=\${POOL_CONTROL_PRESENCE_INTERVAL} --auth-token-file=\${POOL_CONTROL_AUTH_TOKEN_FILE} --scan-cidr=\${POOL_CONTROL_SCAN_CIDR} --scan-port=\${POOL_CONTROL_SCAN_PORT} --scan-interval=\${POOL_CONTROL_SCAN_INTERVAL} --language=\${POOL_CONTROL_LANGUAGE} --allow-pseudo-locale=\${POOL_CONTROL_ALLOW_PSEUDO_LOCALE}
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
# --- REGION: [Install]
[Install]
WantedBy=multi-user.target
EOF

# --- REGION: Start the service and wait for readiness
sudo systemctl daemon-reload
sudo systemctl enable --now pool-control-service.service

if yuruna_service_wait_active pool-control-service.service 30 "http://127.0.0.1:${HTTP_ADDR##*:}/healthz"; then
  ss -ltnp '( sport = :80 )' 2>/dev/null | sed -n '1,4p' || true
  echo "pool-control-service.service ready on $HTTP_ADDR (state=${STATE_DIR:-off})"
else
  echo "pool-control-service.service failed to start:" >&2
  sudo journalctl -u pool-control-service.service --no-pager -n 40 >&2 || true
  exit 1
fi
