#!/bin/bash
# Version: 2026.09.18
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# --- REGION: https://yuruna.link/42e220c4-0005
# See https://yuruna.link/4207d71a-000c
set -euo pipefail

# --- REGION: Initialize environment
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
  # Baked retry libs may bound apt attempts on wall-clock -- the wrapped-apt
  # teardown-hang trap class (apt blocks at end-of-transaction under a timeout(1)
  # parent). Force unbounded until no image predates the lib's unbounded default.
  export YURUNA_APT_STALL_TIMEOUT_SECONDS=0
fi

# --- REGION: Service user
# Prefer cloud-init's account; allow an explicit override or the current caller.
# The CIFS mount maps every file to this user's uid/gid.
if id -u pool-control-service-admin >/dev/null 2>&1; then
  SERVICE_USER=pool-control-service-admin
else
  SERVICE_USER="${SERVICE_USER:-$(id -un)}"
fi
echo "Service user: $SERVICE_USER"

# --- REGION: Service tunables
# See https://yuruna.link/42fffc2c-000d
HTTP_ADDR="${POOL_CONTROL_HTTP_ADDR:-0.0.0.0:80}"
PRESENCE_INTERVAL="${POOL_CONTROL_PRESENCE_INTERVAL:-2m}"
AUTH_TOKEN_FILE="${POOL_CONTROL_AUTH_TOKEN_FILE:-/etc/yuruna/internal-auth.key}"
SCAN_CIDR="${POOL_CONTROL_SCAN_CIDR:-}"
SCAN_PORT="${POOL_CONTROL_SCAN_PORT:-8080}"
SCAN_INTERVAL="${POOL_CONTROL_SCAN_INTERVAL-15m}"
[ -n "$SCAN_INTERVAL" ] || SCAN_INTERVAL=0

# The host validates and canonicalizes the lab-wide language before baking it
# into pool.env. Pseudo negotiation is a separate, explicit reference-run gate
# and stays false in every ordinary VM seed.
POOL_CONTROL_LANGUAGE="$(sed -n 's/^YURUNA_LANGUAGE=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
[ -n "$POOL_CONTROL_LANGUAGE" ] || POOL_CONTROL_LANGUAGE=auto
POOL_CONTROL_ALLOW_PSEUDO_LOCALE="$(sed -n 's/^YURUNA_ALLOW_PSEUDO_LOCALE=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
[ "$POOL_CONTROL_ALLOW_PSEUDO_LOCALE" = true ] || POOL_CONTROL_ALLOW_PSEUDO_LOCALE=false

# Aggregator URL + host id + host ip from the shared env files (same as stash).
AGGREGATOR_URL="$(sed -n 's/^YURUNA_AGGREGATOR_URL=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
HOST_ID="$(sed -n 's/^YURUNA_HOST_ID=//p' /etc/yuruna/host.env 2>/dev/null | head -1 || true)"
INTENT_GIT_URL="$(sed -n 's/^YURUNA_POOL_INTENT_GIT_URL=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"

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
INTENT_STORE="$MOUNT/pool-intent.git"

# --- REGION: Package dependencies
echo ""
echo -e "\e[1;36m==== Package dependencies ====\e[0m"
# libcap2-bin supplies setcap for the DIRECT (non-systemd) launch path; under
# systemd the load-bearing grant is AmbientCapabilities (see the unit below).
if command -v apt_retry >/dev/null 2>&1; then
  apt_retry sudo apt-get update -y
  apt_retry sudo apt-get install -y golang-go git cifs-utils wget ca-certificates libcap2-bin
else
  sudo apt-get update -y
  sudo apt-get install -y golang-go git cifs-utils wget ca-certificates libcap2-bin
fi
go version
# --- REGION: https://yuruna.link/42d69dfa-0036
# Resolute has no PowerShell package; use the cross-version release tarball.
if ! command -v pwsh >/dev/null 2>&1; then
  case "$ARCH" in
    x86_64)  PS_ARCH="x64" ;;
    aarch64) PS_ARCH="arm64" ;;
  esac
  if command -v apt_retry >/dev/null 2>&1; then
    apt_retry sudo apt-get install -y curl tar gzip
  else
    sudo apt-get install -y curl tar gzip
  fi
  # curl_retry comes from the shared retry lib when the image has it; plain curl
  # with its own retry budget otherwise, so a first boot that predates the lib
  # still installs.
  if ! command -v curl_retry >/dev/null 2>&1; then
    curl_retry() { curl --retry 5 --retry-delay 5 --retry-connrefused "$@"; }
  fi

  # Resolve the latest-stable release tag via HEAD-follow of /releases/latest.
  # Avoids the 60/hr unauthenticated GitHub API rate limit.
  PS_TAG=$(curl_retry -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/PowerShell/PowerShell/releases/latest")
  PS_TAG="${PS_TAG##*/}"
  if [[ ! "$PS_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "pool-control-service: PowerShell version discovery failed (got: '$PS_TAG')" >&2
    exit 1
  fi
  PS_VER="${PS_TAG#v}"
  PS_PKG="powershell-${PS_VER}-linux-${PS_ARCH}.tar.gz"
  PS_URL="https://github.com/PowerShell/PowerShell/releases/download/${PS_TAG}/${PS_PKG}${YurunaCacheContent:+?nocache=${YurunaCacheContent}}"
  echo "Installing PowerShell ${PS_VER} (${PS_ARCH}) from ${PS_URL}"
  curl_retry -fsSL -o /tmp/powershell.tar.gz "$PS_URL"

  # --- REGION: https://yuruna.link/429f3d06-008b
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
# Hard gate: the daemon's every read and write shells out to pwsh, so a missing
# interpreter is not a degraded mode -- it is a service that answers every UI
# call with "fork/exec: no such file or directory". Fail here, where the log
# still says why, instead of at the first request.
if ! command -v pwsh >/dev/null 2>&1; then
  echo "pool-control-service: pwsh is NOT installed; the daemon cannot run any pool-admin CLI. Aborting." >&2
  exit 1
fi
PWSH_BIN="$(command -v pwsh)"
pwsh --version
# powershell-yaml is a hard dependency of the pool-admin CLIs; warn loudly (but
# do not abort) so the diagnostics page can report it rather than a bare parse error.
sudo pwsh -NoProfile -NonInteractive -Command "if (-not (Get-Module -ListAvailable powershell-yaml)) { Install-Module powershell-yaml -Scope AllUsers -Force -AcceptLicense }" \
  || echo "pool-control-service: powershell-yaml install failed; the pool-admin CLIs will fail to parse intent. See /diagnostics." >&2

# --- REGION: Locate the daemon source
# Avoid find|head: under pipefail the expected producer SIGPIPE aborts lookup.
locate_repo_dir() {
  local candidates=( "$HOME/yuruna" "/home/$SERVICE_USER/yuruna" )
  local home
  for home in /home/*; do
    [ -d "$home/yuruna" ] || continue
    candidates+=("$home/yuruna")
  done
  local enlistment
  for enlistment in "${candidates[@]}"; do
    if [ -f "$enlistment/test/extension/pool-control-service/server/go.mod" ]; then
      printf '%s' "$enlistment"
      return 0
    fi
  done
  return 1
}
REPO_DIR="$(locate_repo_dir)" || {
  echo "pool-control-service: could not locate test/extension/pool-control-service/server/go.mod under any /home/*/yuruna." >&2
  echo "Ensure the yuruna framework is cloned on this VM before running this script." >&2
  exit 1
}
SERVER_DIR="$REPO_DIR/test/extension/pool-control-service/server"
VERSION_STR=$(cat "$REPO_DIR/VERSION" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
[ -n "$VERSION_STR" ] || VERSION_STR=dev

# --- REGION: Build
# See https://yuruna.link/42e220c4-000f
echo ""
echo -e "\e[1;36m==== Building pool-control-service ($VERSION_STR) from $SERVER_DIR ====\e[0m"
BUILD=/tmp/pool-control-service-build
rm -rf "$BUILD"; mkdir -p "$BUILD"; cp -r "$SERVER_DIR" "$BUILD/server"
SDK_DIR="$(cd "$SERVER_DIR/../.." && pwd)/extension-sdk"
[ -f "$SDK_DIR/go.mod" ] || { echo "Could not find the extension SDK at $SDK_DIR." >&2; exit 1; }
cp -r "$SDK_DIR" "$BUILD/extension-sdk"
# This module has no external graph; do not run networked go mod tidy here.
# Retry the build because a fresh module cache can still need the proxy.
attempts=3
delay=10
for try in $(seq 1 "$attempts"); do
  if ( cd "$BUILD/server" && go build -ldflags "-X main.version=$VERSION_STR" -o pool-control-service . ); then
    break
  fi
  if [ "$try" -ge "$attempts" ]; then
    echo "go build failed after $attempts attempts" >&2
    exit 1
  fi
  echo "go build attempt $try/$attempts failed; retrying in ${delay}s..." >&2
  sleep "$delay"
  delay=$((delay * 2))
done

# --- REGION: Install the binary
sudo install -m 0755 -o root -g root "$BUILD/server/pool-control-service" /usr/local/bin/pool-control-service
# Fallback for a DIRECT (non-systemd) launch only: under the unit's
# NoNewPrivileges=true the grant that reaches the daemon is AmbientCapabilities,
# so a failure here is not fatal.
# --- REGION: https://yuruna.link/42d69dfa-0025
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/pool-control-service || true

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

# --- REGION: Intent store bootstrap
# See https://yuruna.link/42e220c4-000f
if [[ -z "$INTENT_GIT_URL" ]] && mountpoint -q "$MOUNT" 2>/dev/null; then
  INTENT_GIT_URL="$INTENT_STORE"
fi

# Create + seed the store when the resolved URL is a LOCAL path with no repo yet.
# Seeding matches the caching-proxy-service's own bootstrap byte for byte -- an empty,
# schema-valid pools.yml on 'main' -- so a store created here and one created
# there are interchangeable.
if [[ -n "$INTENT_GIT_URL" && "$INTENT_GIT_URL" != *://* && ! -d "$INTENT_GIT_URL/refs" ]]; then
  # Never materialize a store on the local disk underneath an unmounted NAS
  # mountpoint: the NAS mounting later would shadow it, silently stranding
  # whatever intent had been written in the meantime.
  if [[ "$INTENT_GIT_URL" == "$MOUNT"/* ]] && ! mountpoint -q "$MOUNT" 2>/dev/null; then
    echo "pool-control-service: $MOUNT is not mounted; refusing to create $INTENT_GIT_URL on local disk (a later mount would shadow it)." >&2
    INTENT_GIT_URL=''
  else
    echo -e "\e[1;36m==== Initializing pool intent store at $INTENT_GIT_URL ====\e[0m"
    # --- REGION: https://yuruna.link/42e220c4-0005
    if sudo -u "$SERVICE_USER" git init --bare --initial-branch=main "$INTENT_GIT_URL" >/dev/null 2>&1 &&
       sudo -u "$SERVICE_USER" git -C "$INTENT_GIT_URL" config core.fileMode false &&
       # Refresh the dumb-HTTP indexes after every push, via git's built-in
       # rather than a post-update hook: a hook on cifs never becomes executable
       # (the mount fixes modes), so info/refs would go stale the moment this UI
       # wrote intent and the proxy would keep serving runners the old refs.
       sudo -u "$SERVICE_USER" git -C "$INTENT_GIT_URL" config receive.updateServerInfo true; then
      SEED_TMP="$(sudo -u "$SERVICE_USER" mktemp -d)"
      sudo -u "$SERVICE_USER" git -C "$SEED_TMP" init -q --initial-branch=main
      sudo -u "$SERVICE_USER" git -C "$SEED_TMP" config core.fileMode false
      # schemaVersion 2, matching pools.schema.yml's `const: 2` and the fresh-doc
      # default in Read-YurunaPoolsDoc. A store seeded at 1 READS fine -- nothing
      # validates on read -- and then fails every write at schema validation, so
      # the UI looks healthy right up until the operator creates a pool.
      printf 'schemaVersion: 2\npools: []\n' | sudo -u "$SERVICE_USER" tee "$SEED_TMP/pools.yml" >/dev/null
      sudo -u "$SERVICE_USER" git -C "$SEED_TMP" add -A
      sudo -u "$SERVICE_USER" git -C "$SEED_TMP" \
        -c user.name=yuruna -c user.email=pool@yuruna.local commit -q -m 'seed pool intent'
      if sudo -u "$SERVICE_USER" git -C "$SEED_TMP" push -q "$INTENT_GIT_URL" HEAD:main; then
        # Keep the dumb-HTTP indexes current so the proxy can serve this repo
        # read-only to runners without a smart-HTTP backend.
        sudo -u "$SERVICE_USER" git -C "$INTENT_GIT_URL" update-server-info || true
        echo "pool-control-service: intent store seeded at $INTENT_GIT_URL (empty, schema-valid)"
      else
        echo "pool-control-service: could not seed $INTENT_GIT_URL; the UI will report an unreadable store." >&2
      fi
      sudo -u "$SERVICE_USER" rm -rf "$SEED_TMP"
    else
      echo "pool-control-service: could not create $INTENT_GIT_URL; the UI will report an unreadable store." >&2
    fi
  fi
fi
if [[ -n "$INTENT_GIT_URL" && "$INTENT_GIT_URL" != *://* ]]; then
  # An operator debugging over SSH runs git as root or as themselves against a
  # tree the mount says belongs to the service user; without this every such
  # call stops at "dubious ownership" before reaching the actual problem.
  sudo git config --system --add safe.directory "$INTENT_GIT_URL" 2>/dev/null || true
  if [[ -d "$INTENT_GIT_URL/refs" ]]; then
    echo "pool-control-service: intent store -> $INTENT_GIT_URL (writable)"
  fi
fi
if [[ -z "$INTENT_GIT_URL" ]]; then
  echo "pool-control-service: no intent store resolved (pool NAS unmounted and no seeded URL); the UI will start read-only and report why on /diagnostics." >&2
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
POOL_CONTROL_INTENT_GIT_URL=$INTENT_GIT_URL
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
[Unit]
Description=Yuruna Pool control service
Documentation=https://yuruna.link/4207d71a-000c
# After= the cifs mount unit so the daemon starts once the state dir is up;
# NOT Requires=/Wants= it -- the daemon is meant to start and degrade to no
# persistence when the NAS is down, and on a guest with no pool storage the
# mount unit does not exist (After= a missing unit is a harmless no-op).
After=network-online.target mnt-yuruna\x2dpool.mount
Wants=network-online.target
[Service]
Type=simple
User=$SERVICE_USER
EnvironmentFile=/etc/yuruna/pool-control-service.env
ExecStart=/usr/local/bin/pool-control-service --http-addr=\${POOL_CONTROL_HTTP_ADDR} --repo-dir=\${POOL_CONTROL_REPO_DIR} --pwsh=\${POOL_CONTROL_PWSH} --aggregator-url=\${POOL_CONTROL_AGGREGATOR_URL} --host-id=\${POOL_CONTROL_HOST_ID} --intent-git-url=\${POOL_CONTROL_INTENT_GIT_URL} --state-dir=\${POOL_CONTROL_STATE_DIR} --presence-interval=\${POOL_CONTROL_PRESENCE_INTERVAL} --auth-token-file=\${POOL_CONTROL_AUTH_TOKEN_FILE} --scan-cidr=\${POOL_CONTROL_SCAN_CIDR} --scan-port=\${POOL_CONTROL_SCAN_PORT} --scan-interval=\${POOL_CONTROL_SCAN_INTERVAL} --language=\${POOL_CONTROL_LANGUAGE} --allow-pseudo-locale=\${POOL_CONTROL_ALLOW_PSEUDO_LOCALE}
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF

# --- REGION: Start the service and wait for readiness
sudo systemctl daemon-reload
sudo systemctl enable --now pool-control-service.service

# Wait for the unit to settle: the Go runtime adds a few hundred ms before the
# first listen, and a single sleep races that on a loaded first boot.
for _ in 1 2 3 4 5 6; do
  if sudo systemctl is-active --quiet pool-control-service.service; then
    break
  fi
  sleep 1
done

if sudo systemctl is-active --quiet pool-control-service.service; then
  ss -ltnp '( sport = :80 )' 2>/dev/null | sed -n '1,4p' || true
  echo "FETCHED AND EXECUTED: pool-control-service.service active on $HTTP_ADDR (state=${STATE_DIR:-off})"
else
  echo "pool-control-service.service failed to start:" >&2
  sudo journalctl -u pool-control-service.service --no-pager -n 40 >&2 || true
  exit 1
fi
