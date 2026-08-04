#!/usr/bin/env bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Guest bring-up for the Yuruna Download-agent service VM. Mirrors the
# pool-control-service bring-up: build the Go daemon from the framework checkout,
# install it, and run it under systemd. The daemon is pure Go, and shells out to
# PowerShell for exactly one thing: the Windows 11 family, whose download URL is
# minted per request by Fido, a PowerShell script. Both pwsh and Fido are
# installed by cloud-init, best-effort -- when either is missing the daemon
# reports that family unavailable and hosts keep fetching Windows for themselves.
# The pool NAS is CIFS-mounted with the same credential path the
# pool-storage replication uses; it holds BOTH the download pool
# (<mount>/images) and the daemon's audit log + status.json
# (<mount>/download-agent-service/).
set -euo pipefail

# cloud-init's runcmd runs this as root with a MINIMAL environment where
# $HOME is unset, and `go build` -- a child process -- needs HOME EXPORTED to
# resolve GOPATH/GOMODCACHE, else it fails with "module cache not found:
# neither GOMODCACHE nor GOPATH is set". Set AND export it.
export HOME="${HOME:-/root}"

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|aarch64) ;;
  *)
    echo "WARNING: Unsupported architecture: $ARCH (need x86_64 or aarch64)." >&2
    exit 1
    ;;
esac

# Optional shared retry helpers (present once update.sh has run).
if [ -r /usr/local/lib/yuruna/yuruna-retry.sh ]; then
  # --- REGION: https://yuruna.link/network#defining-yuruna-retry-lib
  . /usr/local/lib/yuruna/yuruna-retry.sh
  # Baked retry libs may bound apt attempts on wall-clock -- the wrapped-apt
  # teardown-hang trap class (apt blocks at end-of-transaction under a timeout(1)
  # parent). Force unbounded until no image predates the lib's unbounded default.
  export YURUNA_APT_STALL_TIMEOUT_SECONDS=0
fi

# The daemon runs unprivileged. Prefer the cloud-init-created
# 'download-agent-service-admin' account; fall back to whoever invoked the script
# (e.g. an interactive test login). The NAS mount's uid/gid must match this user
# for the pool writes to land (cifs maps every file to one owner).
if id -u download-agent-service-admin >/dev/null 2>&1; then
  SERVICE_USER=download-agent-service-admin
else
  SERVICE_USER="${SERVICE_USER:-$(id -un)}"
fi
echo "Service user: $SERVICE_USER"
HTTP_ADDR="${DOWNLOAD_AGENT_HTTP_ADDR:-0.0.0.0:80}"
PRESENCE_INTERVAL="${DOWNLOAD_AGENT_PRESENCE_INTERVAL:-15m}"
# The lab-auth token opens the bearer path on the mutating routes for
# automation. Absent file => bearer disabled; the UI's lab-token unlock (the
# daemon redeems the typed code at the aggregator) is then the only way in, and
# a mutation with neither is refused rather than running ungated.
AUTH_TOKEN_FILE="${DOWNLOAD_AGENT_AUTH_TOKEN_FILE:-/etc/yuruna/lab-auth.token}"

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

echo "== download-agent-service bring-up: installing deps =="
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

# Locate the framework checkout (the download-agent-service source).
# Enumerate candidate enlistments directly rather than piping `find` into
# `head`: under pipefail the reader closing the pipe leaves the producer with
# SIGPIPE (141), which aborts the lookup even when it succeeded.
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
VERSION_STR="$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo dev)"

echo "== building download-agent-service ($VERSION_STR) from $SERVER_DIR =="
BUILD=/tmp/download-agent-service-build
rm -rf "$BUILD"; cp -r "$SERVER_DIR" "$BUILD"
# go.sum is committed, so DO NOT run `go mod tidy` (it needs the network to
# recompute the graph); `go build` verifies against go.sum and fetches missing
# modules through the caching-proxy service. Retry: a cache miss the proxy cannot
# relay surfaces as a transient fetch failure that clears once it has the object.
attempts=3
delay=10
for try in $(seq 1 "$attempts"); do
  if ( cd "$BUILD" && go build -ldflags "-X main.version=$VERSION_STR" -o download-agent-service . ); then
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
sudo install -m 0755 -o root -g root "$BUILD/download-agent-service" /usr/local/bin/download-agent-service
# Fallback for a DIRECT (non-systemd) launch only: with NoNewPrivileges=true
# the kernel ignores file capabilities at execve, so this does not reach the
# systemd-launched process -- AmbientCapabilities in the unit does.
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/download-agent-service || true

# Mount the pool NAS: it is both the download pool and the state dir. Best-effort
# -- the daemon serves /healthz and reports poolAvailable:false when it is absent.
if [[ -n "$POOL_NAS_UNC" ]]; then
  sudo mkdir -p "$MOUNT"
  # NO iocharset=utf8: nls_utf8 is absent on the minimal cloud kernel and the
  # mount fails with error(79); the pool's names are ASCII. Open modes
  # (0777/0666) match the parent share -- the server maps the cifs mount mode
  # onto the created object's ACL, so a restrictive dir_mode would lock every
  # folder the VM creates to the single creator and the hosts could not read
  # the images back. nofail/_netdev keep a NAS outage from wedging boot.
  MOUNT_OPTS="credentials=/etc/yuruna/pool-nas.cifs.cred,vers=3.0,uid=$(id -u "$SERVICE_USER"),gid=$(id -g "$SERVICE_USER"),file_mode=0666,dir_mode=0777,noperm,nofail,_netdev"
  # ip= lets cifs connect when the guest cannot resolve the share's server name
  # -- a bare NetBIOS name, or a host-side alias that only the host resolves.
  # Baked by Get-YurunaPoolSeedValue, which never emits an address a guest
  # cannot dial. Same option, same reason, as the stash guest's mount.
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
sudo mkdir -p "$STATE_DIR" 2>/dev/null || true
# Only chown the LOCAL fallback: on a mode-mapped cifs mount the uid/gid mount
# options already place ownership, and a chown there can re-impose an
# owner-only ACL that locks the hosts out of the pool.
if ! mountpoint -q "$MOUNT" 2>/dev/null; then
  sudo chown -R "$SERVICE_USER":"$SERVICE_USER" "$STATE_DIR" 2>/dev/null || true
fi

# --- REGION: caching-proxy routing for byte downloads
# Bytes go through squid when a cache is reachable; freshness probes always go
# direct (a proxied HEAD returns the prewarm-era headers squid pins for
# .iso/.zip and would certify staleness as freshness forever). 3128 is the plain
# HTTP port, 3129 the ssl-bump port -- the pair the caching-proxy service
# publishes. Empty values disable proxying, never startup.
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

echo "== env + systemd unit =="
sudo mkdir -p /etc/yuruna
sudo tee /etc/yuruna/download-agent-service.env >/dev/null <<EOF
DOWNLOAD_AGENT_HTTP_ADDR=$HTTP_ADDR
DOWNLOAD_AGENT_AGGREGATOR_URL=$AGGREGATOR_URL
DOWNLOAD_AGENT_HOST_ID=$HOST_ID
DOWNLOAD_AGENT_PRESENCE_INTERVAL=$PRESENCE_INTERVAL
DOWNLOAD_AGENT_AUTH_TOKEN_FILE=$AUTH_TOKEN_FILE
DOWNLOAD_AGENT_POOL_DIR=$POOL_DIR
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

sudo tee /etc/systemd/system/download-agent-service.service >/dev/null <<EOF
[Unit]
Description=Yuruna Download-agent service
Documentation=https://yuruna.link/download-agent-service
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
ExecStart=/usr/local/bin/download-agent-service --http-addr=\${DOWNLOAD_AGENT_HTTP_ADDR} --aggregator-url=\${DOWNLOAD_AGENT_AGGREGATOR_URL} --host-id=\${DOWNLOAD_AGENT_HOST_ID} --presence-interval=\${DOWNLOAD_AGENT_PRESENCE_INTERVAL} --auth-token-file=\${DOWNLOAD_AGENT_AUTH_TOKEN_FILE} --pool-dir=\${DOWNLOAD_AGENT_POOL_DIR} --state-dir=\${DOWNLOAD_AGENT_STATE_DIR} --scan-interval=\${DOWNLOAD_AGENT_SCAN_INTERVAL} --freshness=\${DOWNLOAD_AGENT_FRESHNESS} --prefetch-lead=\${DOWNLOAD_AGENT_PREFETCH_LEAD} --auto-seed=\${DOWNLOAD_AGENT_AUTO_SEED} --proxy-http=\${DOWNLOAD_AGENT_PROXY_HTTP} --proxy-https=\${DOWNLOAD_AGENT_PROXY_HTTPS} --proxy-ca=\${DOWNLOAD_AGENT_PROXY_CA}
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF

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
  echo "FETCHED AND EXECUTED: download-agent-service.service active on $HTTP_ADDR (pool=$POOL_DIR state=$STATE_DIR)"
else
  echo "download-agent-service.service failed to start:" >&2
  sudo journalctl -u download-agent-service.service --no-pager -n 40 >&2 || true
  exit 1
fi
