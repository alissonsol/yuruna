#!/bin/bash
# Version: 2026.09.24
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# --- REGION: https://yuruna.link/42e220c4-0005
# See https://yuruna.link/4268e4cb
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
if id -u download-agent-service-admin >/dev/null 2>&1; then
  SERVICE_USER=download-agent-service-admin
else
  SERVICE_USER="${SERVICE_USER:-$(id -un)}"
fi
echo "Service user: $SERVICE_USER"

# --- REGION: Service tunables
# See https://yuruna.link/42fffc2c-000d
SERVICE_LANGUAGE="$(sed -n 's/^YURUNA_LANGUAGE=//p' /etc/yuruna/globalization.env 2>/dev/null | head -1 || true)"
[ -n "$SERVICE_LANGUAGE" ] || SERVICE_LANGUAGE=auto
SERVICE_ALLOW_PSEUDO_LOCALE="$(sed -n 's/^YURUNA_ALLOW_PSEUDO_LOCALE=//p' /etc/yuruna/globalization.env 2>/dev/null | head -1 || true)"
[ "$SERVICE_ALLOW_PSEUDO_LOCALE" = true ] || SERVICE_ALLOW_PSEUDO_LOCALE=false
HTTP_ADDR="${DOWNLOAD_AGENT_HTTP_ADDR:-0.0.0.0:80}"
PRESENCE_INTERVAL="${DOWNLOAD_AGENT_PRESENCE_INTERVAL:-2m}"
AUTH_TOKEN_FILE="${DOWNLOAD_AGENT_AUTH_TOKEN_FILE:-/etc/yuruna/internal-auth.key}"

# Aggregator URL + host id from the shared env files (same as pool-control).
AGGREGATOR_URL="$(sed -n 's/^YURUNA_AGGREGATOR_URL=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
HOST_ID="$(sed -n 's/^YURUNA_HOST_ID=//p' /etc/yuruna/host.env 2>/dev/null | head -1 || true)"

# Agent tunables. download-agent.env is 0600 root, so read it through sudo --
# this script also runs from an interactive admin login, not only as cloud-init's
# root.
read_agent_env() {
  sudo sed -n "s/^$1=//p" /etc/yuruna/download-agent.env 2>/dev/null | head -1 || true
}
SCAN_INTERVAL="$(read_agent_env DOWNLOAD_AGENT_SCAN_INTERVAL)"
FRESHNESS="$(read_agent_env DOWNLOAD_AGENT_FRESHNESS)"
PREFETCH_LEAD="$(read_agent_env DOWNLOAD_AGENT_PREFETCH_LEAD)"
AUTO_SEED="$(read_agent_env DOWNLOAD_AGENT_AUTO_SEED)"
CACHE_PROXY_IP="$(read_agent_env YURUNA_CACHE_PROXY_IP)"
# Same frozen defaults the daemon's own config package carries, so a seed that
# omitted a tunable and a bare daemon behave identically.
SCAN_INTERVAL="${SCAN_INTERVAL:-15m}"
FRESHNESS="${FRESHNESS:-24h}"
PREFETCH_LEAD="${PREFETCH_LEAD:-2h}"
AUTO_SEED="${AUTO_SEED:-true}"

# --- REGION: Storage paths
# Pool NAS mount (CIFS) -> download pool + state dir. NAS host/share/cred come
# from pool.env, matching Test.PoolStorage's networkStorage.poolStorageNetworkPath
# contract.
POOL_NAS_UNC="$(sed -n 's/^YURUNA_POOL_NETWORK_PATH=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
POOL_NAS_IP="$(sed -n 's/^YURUNA_POOL_NETWORK_IP=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
POOL_NAS_USER="$(sed -n 's/^YURUNA_POOL_NETWORK_USER=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
MOUNT=/mnt/yuruna-pool
POOL_DIR="$MOUNT"
STATE_DIR="$MOUNT/download-agent-service"
echo "Pool NAS user: ${POOL_NAS_USER:-(none configured)}"

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
    if [ -f "$enlistment/test/extension/download-agent-service/server/go.mod" ]; then
      printf '%s' "$enlistment"
      return 0
    fi
  done
  return 1
}
REPO_DIR="$(locate_repo_dir)" || {
  echo "download-agent-service: could not locate test/extension/download-agent-service/server/go.mod under any /home/*/yuruna." >&2
  echo "Ensure the yuruna framework is cloned on this VM before running this script." >&2
  exit 1
}
SERVER_DIR="$REPO_DIR/test/extension/download-agent-service/server"
VERSION_STR=$(cat "$REPO_DIR/VERSION" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
[ -n "$VERSION_STR" ] || VERSION_STR=dev

# --- REGION: Build
# See https://yuruna.link/42e220c4-000f
echo ""
echo -e "\e[1;36m==== Building download-agent-service ($VERSION_STR) from $SERVER_DIR ====\e[0m"
BUILD=/tmp/download-agent-service-build
rm -rf "$BUILD"; mkdir -p "$BUILD"; cp -r "$SERVER_DIR" "$BUILD/server"
SDK_DIR="$(cd "$SERVER_DIR/../.." && pwd)/extension-sdk"
[ -f "$SDK_DIR/go.mod" ] || { echo "Could not find the extension SDK at $SDK_DIR." >&2; exit 1; }
cp -r "$SDK_DIR" "$BUILD/extension-sdk"
# This module has no external graph; do not run networked go mod tidy here.
# Retry the build because a fresh module cache can still need the proxy.
attempts=3
delay=10
for try in $(seq 1 "$attempts"); do
  if ( cd "$BUILD/server" && go build -ldflags "-X main.version=$VERSION_STR" -o download-agent-service . ); then
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
sudo install -m 0755 -o root -g root "$BUILD/server/download-agent-service" /usr/local/bin/download-agent-service
# Fallback for a DIRECT (non-systemd) launch only: under the unit's
# NoNewPrivileges=true the grant that reaches the daemon is AmbientCapabilities,
# so a failure here is not fatal.
# --- REGION: https://yuruna.link/42d69dfa-0025
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/download-agent-service || true

# --- REGION: Storage directories
# Mount the pool NAS best-effort; the daemon reports an absent pool via /healthz.
if [[ -n "$POOL_NAS_UNC" ]]; then
  sudo mkdir -p "$MOUNT"
  # --- REGION: https://yuruna.link/428405a0-000b
  MOUNT_OPTS="credentials=/etc/yuruna/pool-nas.cifs.cred,vers=3.0,uid=$(id -u "$SERVICE_USER"),gid=$(id -g "$SERVICE_USER"),file_mode=0666,dir_mode=0777,noperm,nofail,_netdev"
  # ip= carries the mount past a server name the guest has no way to resolve.
  [ -n "$POOL_NAS_IP" ] && MOUNT_OPTS="$MOUNT_OPTS,ip=$POOL_NAS_IP"
  # Persist via fstab so the pool survives a VM reboot and systemd exposes a
  # .mount unit the daemon can order After=.
  if ! grep -q " $MOUNT cifs " /etc/fstab 2>/dev/null; then
    printf '%s %s cifs %s 0 0\n' "$POOL_NAS_UNC" "$MOUNT" "$MOUNT_OPTS" | sudo tee -a /etc/fstab >/dev/null
  fi
  sudo systemctl daemon-reload
  if ! mountpoint -q "$MOUNT"; then
    sudo timeout 60 mount "$MOUNT" || echo "download-agent-service: NAS mount failed; the pool is unavailable and every ensure answers 503" >&2
  fi
fi
# Do not create state below an unmounted NAS path; a later mount would shadow it.
# An empty path disables persistence without recreating the local directory.
if mountpoint -q "$MOUNT" 2>/dev/null; then
  # No chown on the mounted share: the uid/gid mount options have already placed
  # ownership and a chown can lock the hosts out.
  sudo mkdir -p "$STATE_DIR" 2>/dev/null || true
else
  echo "download-agent-service: $MOUNT is not mounted; state persistence is off (a state dir created here would be shadowed by a later mount)." >&2
  STATE_DIR=''
fi

# --- REGION: Caching-proxy routing for byte downloads
# See https://yuruna.link/4268e4cb-0005
PROXY_HTTP=''
PROXY_HTTPS=''
PROXY_CA=''
if [[ -n "$CACHE_PROXY_IP" ]]; then
  PROXY_HTTP="http://$CACHE_PROXY_IP:3128"
  PROXY_HTTPS="http://$CACHE_PROXY_IP:3129"
  # The bumped chain is signed by the cache's own CA, so HTTPS through :3129
  # verifies only against this PEM. Seeded by cloud-init; absent means the
  # daemon leaves the HTTPS proxy unpinned and falls back to a direct fetch.
  if [ -s /etc/yuruna/yuruna-squid-ca.crt ]; then
    PROXY_CA=/etc/yuruna/yuruna-squid-ca.crt
  else
    echo "download-agent-service: cache at $CACHE_PROXY_IP but no CA at /etc/yuruna/yuruna-squid-ca.crt; HTTPS byte downloads fall back to direct." >&2
    PROXY_HTTPS=''
  fi
fi

# --- REGION: Environment file
echo ""
echo -e "\e[1;36m==== /etc/yuruna/download-agent-service.env ====\e[0m"
sudo mkdir -p /etc/yuruna
sudo tee /etc/yuruna/download-agent-service.env >/dev/null <<EOF
YURUNA_LANGUAGE=$SERVICE_LANGUAGE
YURUNA_ALLOW_PSEUDO_LOCALE=$SERVICE_ALLOW_PSEUDO_LOCALE
DOWNLOAD_AGENT_HTTP_ADDR=$HTTP_ADDR
DOWNLOAD_AGENT_AGGREGATOR_URL=$AGGREGATOR_URL
DOWNLOAD_AGENT_HOST_ID=$HOST_ID
DOWNLOAD_AGENT_PRESENCE_INTERVAL=$PRESENCE_INTERVAL
DOWNLOAD_AGENT_AUTH_TOKEN_FILE=$AUTH_TOKEN_FILE
DOWNLOAD_AGENT_POOL_DIR=$POOL_DIR
DOWNLOAD_AGENT_POOL_NETWORK_PATH=$POOL_NAS_UNC
DOWNLOAD_AGENT_STATE_DIR=$STATE_DIR
DOWNLOAD_AGENT_SCAN_INTERVAL=$SCAN_INTERVAL
DOWNLOAD_AGENT_FRESHNESS=$FRESHNESS
DOWNLOAD_AGENT_PREFETCH_LEAD=$PREFETCH_LEAD
DOWNLOAD_AGENT_AUTO_SEED=$AUTO_SEED
DOWNLOAD_AGENT_PROXY_HTTP=$PROXY_HTTP
DOWNLOAD_AGENT_PROXY_HTTPS=$PROXY_HTTPS
DOWNLOAD_AGENT_PROXY_CA=$PROXY_CA
EOF
# Root-only: the file names the aggregator and the pool paths this daemon acts
# on, and nothing outside the unit needs it. systemd reads EnvironmentFile as
# root before dropping to User=, so the daemon still sees it.
sudo chmod 0600 /etc/yuruna/download-agent-service.env

# --- REGION: systemd unit
echo ""
echo -e "\e[1;36m==== /etc/systemd/system/download-agent-service.service ====\e[0m"
sudo tee /etc/systemd/system/download-agent-service.service >/dev/null <<EOF
[Unit]
Description=Yuruna Download-agent service
Documentation=https://yuruna.link/4268e4cb
# After= the cifs mount unit so the daemon starts once the pool is up;
# NOT Requires=/Wants= it -- the daemon is meant to start and report
# "pool unavailable" when the NAS is down, and on a guest with no pool storage
# the mount unit does not exist (After= a missing unit is a harmless no-op).
After=network-online.target mnt-yuruna\x2dpool.mount
Wants=network-online.target
[Service]
Type=simple
User=$SERVICE_USER
EnvironmentFile=/etc/yuruna/download-agent-service.env
ExecStart=/usr/local/bin/download-agent-service --http-addr=\${DOWNLOAD_AGENT_HTTP_ADDR} --aggregator-url=\${DOWNLOAD_AGENT_AGGREGATOR_URL} --host-id=\${DOWNLOAD_AGENT_HOST_ID} --presence-interval=\${DOWNLOAD_AGENT_PRESENCE_INTERVAL} --auth-token-file=\${DOWNLOAD_AGENT_AUTH_TOKEN_FILE} --pool-dir=\${DOWNLOAD_AGENT_POOL_DIR} --pool-network-path=\${DOWNLOAD_AGENT_POOL_NETWORK_PATH} --state-dir=\${DOWNLOAD_AGENT_STATE_DIR} --scan-interval=\${DOWNLOAD_AGENT_SCAN_INTERVAL} --freshness=\${DOWNLOAD_AGENT_FRESHNESS} --prefetch-lead=\${DOWNLOAD_AGENT_PREFETCH_LEAD} --auto-seed=\${DOWNLOAD_AGENT_AUTO_SEED} --proxy-http=\${DOWNLOAD_AGENT_PROXY_HTTP} --proxy-https=\${DOWNLOAD_AGENT_PROXY_HTTPS} --proxy-ca=\${DOWNLOAD_AGENT_PROXY_CA} --language=\${YURUNA_LANGUAGE} --allow-pseudo-locale=\${YURUNA_ALLOW_PSEUDO_LOCALE}
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
sudo systemctl enable --now download-agent-service.service

# Wait for the unit to settle: the Go runtime adds a few hundred ms before the
# first listen, and a single sleep races that on a loaded first boot.
for _ in 1 2 3 4 5 6; do
  if sudo systemctl is-active --quiet download-agent-service.service; then
    break
  fi
  sleep 1
done

if sudo systemctl is-active --quiet download-agent-service.service; then
  ss -ltnp '( sport = :80 )' 2>/dev/null | sed -n '1,4p' || true
  echo "FETCHED AND EXECUTED: download-agent-service.service active on $HTTP_ADDR (pool=$POOL_DIR state=${STATE_DIR:-off})"
else
  echo "download-agent-service.service failed to start:" >&2
  sudo journalctl -u download-agent-service.service --no-pager -n 40 >&2 || true
  exit 1
fi
