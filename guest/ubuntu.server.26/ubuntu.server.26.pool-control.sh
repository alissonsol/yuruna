#!/usr/bin/env bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Guest bring-up for the Yuruna Pool control service VM. Mirrors the stash-service
# bring-up: build the Go daemon from the framework checkout, install it, and run
# it under systemd. UNLIKE stash (pure Go), pool-control shells out to the
# PowerShell pool-admin CLIs, so this also installs pwsh + powershell-yaml and
# points the daemon at the framework checkout (--repo-dir) whose test/*.ps1 it
# invokes. The daemon persists its audit log + status.json under the pool NAS
# (poolNetworkPath/pool-control/), which is CIFS-mounted here with the same
# credential path the pool-storage replication uses.
set -euo pipefail

SERVICE_USER="${SERVICE_USER:-$(id -un)}"
HTTP_ADDR="${POOL_CONTROL_HTTP_ADDR:-0.0.0.0:80}"
PRESENCE_INTERVAL="${POOL_CONTROL_PRESENCE_INTERVAL:-15m}"

# Aggregator URL + host id + host ip from the shared env files (same as stash).
AGGREGATOR_URL="$(sed -n 's/^YURUNA_AGGREGATOR_URL=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
HOST_ID="$(sed -n 's/^YURUNA_HOST_ID=//p' /etc/yuruna/host.env 2>/dev/null | head -1 || true)"
INTENT_GIT_URL="$(sed -n 's/^YURUNA_POOL_INTENT_GIT_URL=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"

# Pool NAS mount (CIFS) -> state dir. NAS host/share/cred come from pool.env,
# matching Test.PoolStorage's networkStorage.poolNetworkPath contract.
POOL_NAS_UNC="$(sed -n 's/^YURUNA_POOL_NETWORK_PATH=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
POOL_NAS_USER="$(sed -n 's/^YURUNA_POOL_NETWORK_USER=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
MOUNT=/mnt/yuruna-pool
STATE_DIR="$MOUNT/pool-control"

echo "== pool-control bring-up: installing deps =="
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y golang-go git cifs-utils wget ca-certificates
# PowerShell (the daemon shells out to the pool-admin CLIs).
if ! command -v pwsh >/dev/null 2>&1; then
  wget -q "https://packages.microsoft.com/config/ubuntu/$(. /etc/os-release; echo "$VERSION_ID")/packages-microsoft-prod.deb" -O /tmp/pmc.deb || true
  sudo dpkg -i /tmp/pmc.deb || true
  sudo apt-get update -y
  sudo apt-get install -y powershell || true
fi
pwsh -NoProfile -Command "if (-not (Get-Module -ListAvailable powershell-yaml)) { Install-Module powershell-yaml -Scope AllUsers -Force -AcceptLicense }" || true

# Locate the framework checkout (the pool-control source + the pool-admin CLIs).
REPO_DIR="$(dirname "$(find /home/*/yuruna -type f -path '*/test/extension/pool-control/server/go.mod' 2>/dev/null | head -1)")"
REPO_DIR="$(cd "$REPO_DIR/../../../.." && pwd)"   # .../server -> yuruna repo root
SERVER_DIR="$REPO_DIR/test/extension/pool-control/server"
if [[ ! -f "$SERVER_DIR/go.mod" ]]; then
  echo "pool-control: could not locate the server source under /home/*/yuruna" >&2
  exit 1
fi
VERSION_STR="$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo dev)"

echo "== building pool-control ($VERSION_STR) from $SERVER_DIR =="
BUILD=/tmp/pool-control-build
rm -rf "$BUILD"; cp -r "$SERVER_DIR" "$BUILD"
( cd "$BUILD" && go build -ldflags "-X main.version=$VERSION_STR" -o pool-control . )   # go.sum committed; never go mod tidy on the VM
sudo install -m 0755 -o root -g root "$BUILD/pool-control" /usr/local/bin/pool-control
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/pool-control || true

# Mount the pool NAS for the state dir (best-effort; the daemon degrades to no
# persistence if the mount is absent).
if [[ -n "$POOL_NAS_UNC" ]]; then
  sudo mkdir -p "$MOUNT"
  if ! mountpoint -q "$MOUNT"; then
    sudo mount -t cifs "$POOL_NAS_UNC" "$MOUNT" -o "credentials=/etc/yuruna/pool-nas.cifs.cred,uid=$(id -u "$SERVICE_USER"),gid=$(id -g "$SERVICE_USER"),iocharset=utf8,vers=3.0" || echo "pool-control: NAS mount failed; persistence disabled" >&2
  fi
fi
sudo mkdir -p "$STATE_DIR" 2>/dev/null || true

echo "== env + systemd unit =="
sudo mkdir -p /etc/yuruna
sudo tee /etc/yuruna/pool-control.env >/dev/null <<EOF
POOL_CONTROL_HTTP_ADDR=$HTTP_ADDR
POOL_CONTROL_REPO_DIR=$REPO_DIR
POOL_CONTROL_AGGREGATOR_URL=$AGGREGATOR_URL
POOL_CONTROL_HOST_ID=$HOST_ID
POOL_CONTROL_INTENT_GIT_URL=$INTENT_GIT_URL
POOL_CONTROL_STATE_DIR=$STATE_DIR
POOL_CONTROL_PRESENCE_INTERVAL=$PRESENCE_INTERVAL
EOF

sudo tee /etc/systemd/system/pool-control.service >/dev/null <<EOF
[Unit]
Description=Yuruna Pool control service
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=$SERVICE_USER
EnvironmentFile=/etc/yuruna/pool-control.env
ExecStart=/usr/local/bin/pool-control --http-addr=\${POOL_CONTROL_HTTP_ADDR} --repo-dir=\${POOL_CONTROL_REPO_DIR} --pwsh=/usr/bin/pwsh --aggregator-url=\${POOL_CONTROL_AGGREGATOR_URL} --host-id=\${POOL_CONTROL_HOST_ID} --intent-git-url=\${POOL_CONTROL_INTENT_GIT_URL} --state-dir=\${POOL_CONTROL_STATE_DIR} --presence-interval=\${POOL_CONTROL_PRESENCE_INTERVAL}
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now pool-control.service
sleep 2
if systemctl is-active --quiet pool-control.service; then
  echo "FETCHED AND EXECUTED: pool-control.service active on $HTTP_ADDR (state=$STATE_DIR)"
else
  echo "pool-control.service failed to start:" >&2
  sudo journalctl -u pool-control.service --no-pager -n 40 >&2 || true
  exit 1
fi
