#!/bin/bash
# Version: 2026.09.12
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# --- REGION: https://yuruna.link/42e220c4-0005
# See https://yuruna.link/42f5e921
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
if id -u stash-admin >/dev/null 2>&1; then
  SERVICE_USER=stash-admin
else
  SERVICE_USER="${SERVICE_USER:-$(id -un)}"
fi
echo "Service user: $SERVICE_USER"

# --- REGION: Service tunables
# See https://yuruna.link/42fffc2c-000d
HTTP_ADDR="${STASH_HTTP_ADDR-0.0.0.0:80}"
POOL_WINDOW_DAYS="${STASH_POOL_WINDOW_DAYS:-30}"
AGGREGATOR_URL_SEED=$(sed -nE "s/^YURUNA_AGGREGATOR_URL='(.*)'\$/\1/p" /etc/yuruna/pool.env 2>/dev/null | head -n1 || true)
AGGREGATOR_URL="${STASH_AGGREGATOR_URL:-$AGGREGATOR_URL_SEED}"
if [ -n "$AGGREGATOR_URL" ]; then
  echo "Delete authorization: Lab token or Yuruna hosts dashboard link, checked by $AGGREGATOR_URL."
else
  echo "WARNING: no aggregator URL resolved (STASH_AGGREGATOR_URL unset, /etc/yuruna/pool.env carries none)."
  echo "         Browsing and creating still work, but nothing can be DELETED through the UI."
fi
PRESENCE_INTERVAL="${STASH_PRESENCE_INTERVAL:-2m}"
BUILD_TAGS="${STASH_BUILD_TAGS:-}"

# --- REGION: Storage paths
# Read values WITHOUT sourcing the file: a sourced env file aborts the
# whole script on a stray quote.
# Values are single-quoted by the host-side bake; sed-extract them.
ENVF=/etc/yuruna/ystash-nas.env
get_env() {
  [ -r "$ENVF" ] || return 0
  # head closes the pipe after the first line, so sed can take SIGPIPE (141);
  # under pipefail that would abort a successful lookup. Swallow it.
  sed -nE "s/^$1='(.*)'\$/\1/p" "$ENVF" | head -n1 || true
}
NETWORK_PATH=$(get_env YSTASH_NAS_NETWORK_PATH)
HOST_ID=$(get_env YSTASH_NAS_HOST_ID)
# --- REGION: https://yuruna.link/42e220c4-000f
[ -n "$HOST_ID" ] || HOST_ID="$(sed -n 's/^YURUNA_HOST_ID=//p' /etc/yuruna/host.env 2>/dev/null | head -1 || true)"
MOUNT=$(get_env YSTASH_NAS_MOUNT)
MOUNT=${MOUNT:-/mnt/ystash-nas}

METADATA_DIR=/var/lib/stash-service/metadata
BUFFER_DIR=/var/lib/stash-service/buffer
LOCAL_FALLBACK=/var/lib/stash-service/share-local

if [ -n "$NETWORK_PATH" ] && [ -n "$HOST_ID" ]; then
  SHARE_FOLDER="$MOUNT/stash/$HOST_ID"
  echo "StashFolder (stash share): $SHARE_FOLDER"
  if ! mountpoint -q "$MOUNT" 2>/dev/null; then
    # The daemon buffers locally until the mount returns; warn but proceed.
    echo "WARNING: $MOUNT is not mounted yet; the daemon will buffer locally until it is."
  fi
else
  SHARE_FOLDER="$LOCAL_FALLBACK"
  echo "WARNING: stash storage not configured in $ENVF; using local share fallback $SHARE_FOLDER."
  echo "         Data stored here is NOT durable across a VM reimage."
fi

# --- REGION: Package dependencies
echo ""
echo -e "\e[1;36m==== Package dependencies ====\e[0m"
if command -v apt_retry >/dev/null 2>&1; then
  apt_retry sudo apt-get update -y
  apt_retry sudo apt-get install -y golang-go libcap2-bin cifs-utils
else
  sudo apt-get update -y
  sudo apt-get install -y golang-go libcap2-bin cifs-utils
fi
go version

# --- REGION: Locate the daemon source
# Avoid find|head: under pipefail the expected producer SIGPIPE aborts lookup.
locate_server_dir() {
  local candidates=( "$HOME/yuruna" "/home/$SERVICE_USER/yuruna" )
  local home
  for home in /home/*; do
    [ -d "$home/yuruna" ] || continue
    candidates+=("$home/yuruna")
  done
  local enlistment
  for enlistment in "${candidates[@]}"; do
    if [ -f "$enlistment/test/extension/stash-service/server/go.mod" ]; then
      printf '%s' "$enlistment/test/extension/stash-service/server"
      return 0
    fi
  done
  return 1
}
SERVER_DIR=$(locate_server_dir) || {
  echo "Could not find test/extension/stash-service/server/go.mod under any /home/*/yuruna." >&2
  echo "Ensure the yuruna framework is cloned on this VM before running this script." >&2
  exit 1
}
echo "Daemon source: $SERVER_DIR"
# <enlistment>/test/extension/extension-sdk -- three levels up from server/.
SDK_DIR="$(cd "$SERVER_DIR/../.." && pwd)/extension-sdk"
[ -f "$SDK_DIR/go.mod" ] || {
  echo "Could not find the extension SDK at $SDK_DIR (expected beside stash-service/)." >&2
  exit 1
}
echo "SDK source:    $SDK_DIR"

# Framework version (repo root is four levels above server/) -- stamped into
# the binary so the UI header shows it (stash-guide / status pages style).
# Read before staging; empty/missing falls back to "dev".
VERSION_STR=$(cat "$SERVER_DIR/../../../../VERSION" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
[ -n "$VERSION_STR" ] || VERSION_STR=dev
echo "Framework version: $VERSION_STR"

# --- REGION: Build
# See https://yuruna.link/42e220c4-000f
# Keep the committed go.sum authoritative; provisioning must not rewrite it.
BUILD=/tmp/stash-build
echo ""
echo -e "\e[1;36m==== Staging source to $BUILD ====\e[0m"
sudo rm -rf "$BUILD"
sudo mkdir -p "$BUILD"
sudo cp -r "$SERVER_DIR" "$BUILD/server"
sudo cp -r "$SDK_DIR" "$BUILD/extension-sdk"
sudo chown -R "$(id -un):$(id -gn)" "$BUILD"
echo ""
echo -e "\e[1;36m==== stash-service ====\e[0m"
cd "$BUILD/server"
attempts=3
delay=10
for try in $(seq 1 "$attempts"); do
  if go build ${BUILD_TAGS:+-tags "$BUILD_TAGS"} -ldflags "-X main.version=$VERSION_STR" -o stash-service .; then
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
echo ""
echo -e "\e[1;36m==== /usr/local/bin/stash-service ====\e[0m"
sudo install -m 0755 -o root -g root "$BUILD/server/stash-service" /usr/local/bin/stash-service
# --- REGION: https://yuruna.link/42d69dfa-0025
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/stash-service || true

# --- REGION: Mask the OS sshd to free port 22
# See https://yuruna.link/42d69dfa-0026
echo ""
echo -e "\e[1;36m==== Masking OS sshd to free port 22 ====\e[0m"
sudo systemctl mask --now ssh.service 2>/dev/null || true
sudo systemctl mask --now ssh.socket  2>/dev/null || true
# The alias cloud-init actually names.
sudo systemctl mask --now sshd.service 2>/dev/null || true

# --- REGION: Storage directories
echo ""
echo -e "\e[1;36m==== VM-local storage: /var/lib/stash-service ====\e[0m"
sudo mkdir -p "$METADATA_DIR" "$BUFFER_DIR"
if [ "$SHARE_FOLDER" = "$LOCAL_FALLBACK" ]; then
  sudo mkdir -p "$LOCAL_FALLBACK"
fi
sudo chown -R "$SERVICE_USER":"$SERVICE_USER" /var/lib/stash-service
echo "  metadata: $METADATA_DIR"
echo "  buffer  : $BUFFER_DIR"

# --- REGION: Environment file
echo ""
echo -e "\e[1;36m==== /etc/yuruna/stash.env ====\e[0m"
sudo mkdir -p /etc/yuruna
sudo tee /etc/yuruna/stash.env >/dev/null <<ENV
SHARE_FOLDER=$SHARE_FOLDER
METADATA_DIR=$METADATA_DIR
BUFFER_DIR=$BUFFER_DIR
HTTP_ADDR=$HTTP_ADDR
POOL_WINDOW_DAYS=$POOL_WINDOW_DAYS
AGGREGATOR_URL=$AGGREGATOR_URL
HOST_ID=$HOST_ID
PRESENCE_INTERVAL=$PRESENCE_INTERVAL
ENV

# --- REGION: systemd unit
# See https://yuruna.link/42e220c4-000f
# Order after the mount without requiring it; offline buffering must still start.
echo ""
echo -e "\e[1;36m==== /etc/systemd/system/stash-service.service ====\e[0m"
sudo tee /etc/systemd/system/stash-service.service >/dev/null <<UNIT
[Unit]
Description=Yuruna stash service daemon
Documentation=https://yuruna.link/42f5e921
After=network-online.target mnt-ystash\x2dnas.mount
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
EnvironmentFile=/etc/yuruna/stash.env
ExecStart=/usr/local/bin/stash-service --share-folder \${SHARE_FOLDER} --metadata-dir \${METADATA_DIR} --buffer-dir \${BUFFER_DIR} --http-addr=\${HTTP_ADDR} --pool-window-days=\${POOL_WINDOW_DAYS} --aggregator-url=\${AGGREGATOR_URL} --host-id=\${HOST_ID} --presence-interval=\${PRESENCE_INTERVAL}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
# The load-bearing grant that lets the non-root service user bind :22 + :80
# (ambient caps survive NoNewPrivileges, unlike the setcap file capability).
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
# --- REGION: https://yuruna.link/42e220c4-0005
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=false
ReadWritePaths=/var/lib/stash-service -$MOUNT

[Install]
WantedBy=multi-user.target
UNIT

# --- REGION: Start the service and wait for readiness
echo ""
echo -e "\e[1;36m==== stash-service.service start and enable ====\e[0m"
sudo systemctl daemon-reload
sudo systemctl enable --now stash-service.service

# Wait briefly for the unit to settle (binding :22 is fast, but the Go
# runtime adds a couple hundred ms before the first listen).
for _ in 1 2 3 4 5 6; do
  if sudo systemctl is-active --quiet stash-service.service; then
    break
  fi
  sleep 1
done

if ! sudo systemctl is-active --quiet stash-service.service; then
  echo "stash-service.service did not reach active state. journalctl tail:" >&2
  sudo journalctl -u stash-service.service -n 50 --no-pager >&2 || true
  exit 1
fi
ss -ltnp '( sport = :22 or sport = :80 )' 2>/dev/null | sed -n '1,6p' || true

echo ""
echo "== stash service ready =="
echo "  Binary     : /usr/local/bin/stash-service"
echo "  StashFolder: $SHARE_FOLDER"
echo "  Metadata   : $METADATA_DIR"
echo "  Buffer     : $BUFFER_DIR"
if [ -n "$HTTP_ADDR" ]; then
  echo "  UI/API     : http://<vm-ip>:${HTTP_ADDR##*:}  (browse / create / delete; docs/stash-guide.md)"
else
  echo "  UI/API     : disabled (STASH_HTTP_ADDR empty)"
fi
if [ -n "$AGGREGATOR_URL" ]; then
  echo "  Delete     : unlock with the dashboard Lab token, or arrive from the Yuruna hosts dashboard"
  echo "               (reaches every host's stashes on the share, not only this one's)"
else
  echo "  Delete     : unavailable -- no aggregator URL, so no Lab token can be checked"
  echo "               (re-run with STASH_AGGREGATOR_URL=<url> to enable it)"
fi
echo "  systemd    : sudo systemctl status stash-service.service"
echo "  logs       : sudo journalctl -u stash-service.service -f"
echo "  Exercise   : scp ./file alice@<vm-ip>:/scratch"
echo "               (any username / any password / any key accepted)"
