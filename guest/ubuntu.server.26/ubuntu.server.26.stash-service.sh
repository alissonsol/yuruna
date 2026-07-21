#!/bin/bash
# Version: 2026.07.21
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Bring up the Yuruna Stash Service daemon: build the in-repo Go stash-server,
# bind :22, and register its systemd unit (the cifs share is mounted by the
# cloud-init bring-up, not here). Design + storage layout:
# --- REGION: https://yuruna.link/stash-service
# With no stash storage configured (e.g. a dev/test guest with no NAS) the
# daemon falls back to a local share folder -- it still starts, but data is
# then NOT durable across reimage.
set -euo pipefail

# cloud-init's runcmd runs this as root with a MINIMAL environment where
# $HOME is unset: `set -u` would abort on any $HOME reference
# (locate_server_dir), and `go build` -- a child process -- needs HOME
# EXPORTED to resolve GOPATH/GOMODCACHE, else it fails with "module cache
# not found: neither GOMODCACHE nor GOPATH is set". Set AND export it.
export HOME="${HOME:-/root}"

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
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
  # Baked retry libs may default apt attempts to a wall-clock bound -- the
  # wrapped-apt teardown-hang trap class (apt blocks at end-of-transaction
  # under a timeout(1) parent). Force unbounded regardless of the image's
  # lib vintage; remove once no image predates the lib's unbounded default.
  export YURUNA_APT_STALL_TIMEOUT=0
fi

# --- REGION: Service user
# The daemon runs unprivileged. Prefer the cloud-init-created 'yuruna'
# account; fall back to whoever invoked the script (e.g. an interactive
# test login). The share mount's uid/gid must match this user for writes
# to land (cifs maps all files to one owner).
if id -u yuruna >/dev/null 2>&1; then
  SERVICE_USER=yuruna
else
  SERVICE_USER="$(id -un)"
fi
echo "Service user: $SERVICE_USER"

# --- REGION: Resolve the StashFolder from the stash storage env
# Read values WITHOUT sourcing the file: a sourced env file aborts the
# whole script on a stray quote (feedback_findmnt_target_and_cloudinit_env_source_traps.md).
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
MOUNT=$(get_env YSTASH_NAS_MOUNT)
MOUNT=${MOUNT:-/mnt/ystash-nas}

METADATA_DIR=/var/lib/stash-server/metadata
BUFFER_DIR=/var/lib/stash-server/buffer
LOCAL_FALLBACK=/var/lib/stash-server/share-local

# UI/API HTTP listener + pool knobs (stash-service-ui.md §2, §3.2, §3.4).
# Operator-overridable via the environment; sensible defaults otherwise.
# HTTP_ADDR binds :80 (the unprivileged service user holds
# CAP_NET_BIND_SERVICE, set below, which covers any port <1024).
# AGGREGATOR_URL is the pool-aggregator base (e.g. https://<proxy>:9400) for
# the remote-host deep-link (§3.4) and the presence beacon (§4.7). The
# operator export wins; otherwise the host-baked seed value from
# /etc/yuruna/pool.env; empty leaves both best-effort/off.
# '-' (not ':-') so an operator who exports STASH_HTTP_ADDR='' to DISABLE the
# UI gets an empty value (the daemon treats empty --http-addr as off); ':-'
# would re-substitute the default on empty and force the UI back on.
HTTP_ADDR="${STASH_HTTP_ADDR-0.0.0.0:80}"
POOL_WINDOW_DAYS="${STASH_POOL_WINDOW_DAYS:-30}"
AGGREGATOR_URL_SEED=$(sed -nE "s/^YURUNA_AGGREGATOR_URL='(.*)'\$/\1/p" /etc/yuruna/pool.env 2>/dev/null | head -n1 || true)
AGGREGATOR_URL="${STASH_AGGREGATOR_URL:-$AGGREGATOR_URL_SEED}"
# Host IP (the deploying host): the one non-VM source allowed to DELETE stashes;
# reads and writes stay open to any host. Sed-extracted from the seed's
# host.env (never sourced); empty leaves deletes VM-local-only. An operator
# STASH_HOST_IP export wins for a dev launch off the seed.
HOST_IP_SEED=$(sed -nE 's/^YURUNA_HOST_IP=(.*)$/\1/p' /etc/yuruna/host.env 2>/dev/null | head -n1 || true)
HOST_IP="${STASH_HOST_IP:-$HOST_IP_SEED}"
# Presence beacon (§4.7): the daemon self-announces to the aggregator on
# boot, every PRESENCE_INTERVAL, and at shutdown, so the pool dashboard's
# Extension hosts row exists without the owning host's status server. The
# announce runs under the HOST's identity (HOST_ID, extracted above from the
# stash storage env); no stash storage -> no host identity -> beacon off.
PRESENCE_INTERVAL="${STASH_PRESENCE_INTERVAL:-15m}"
# STASH_BUILD_TAGS lets the VM image opt into the magika detection backend
# (`-tags magika`); that build also needs ONNX Runtime + the model assets
# vendored (stash-service-ui.md §6.1, §14). Default empty = pure-Go heuristic.
BUILD_TAGS="${STASH_BUILD_TAGS:-}"

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

# --- REGION: Locate the daemon source under the cloned repo
# update.sh / the cloud-init bring-up clones the framework into a home dir.
# Build from wherever the server/go.mod lives so the binary tracks the
# framework checkout this cycle deployed.
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
SERVER_SRC=$(locate_server_dir) || {
  echo "Could not find test/extension/stash-service/server/go.mod under any /home/*/yuruna." >&2
  echo "Ensure the yuruna framework is cloned on this VM before running this script." >&2
  exit 1
}
echo "Daemon source: $SERVER_SRC"

# Framework version (repo root is four levels above server/) — stamped into
# the binary so the UI header shows it (stash-guide / status pages style).
# Read before staging; empty/missing falls back to "dev".
VERSION_STR=$(cat "$SERVER_SRC/../../../../VERSION" 2>/dev/null | head -n1 | tr -d '[:space:]' || true)
[ -n "$VERSION_STR" ] || VERSION_STR=dev
echo "Framework version: $VERSION_STR"

echo ""
echo -e "\e[1;36m==== Go toolchain ====\e[0m"
if command -v apt_retry >/dev/null 2>&1; then
  apt_retry sudo apt-get update -y
  apt_retry sudo apt-get install -y golang-go libcap2-bin cifs-utils
else
  sudo apt-get update -y
  sudo apt-get install -y golang-go libcap2-bin cifs-utils
fi
go version

# --- REGION: Build
# Stage to a user-writable dir so the module cache lands under this user's
# $HOME/go. go.sum is committed, so DO NOT run `go mod tidy` (it needs the
# network to recompute the graph); `go build` verifies against go.sum and
# fetches any missing modules through the caching proxy.
BUILD_DIR=/tmp/stash-build
echo ""
echo -e "\e[1;36m==== Staging source to $BUILD_DIR ====\e[0m"
sudo rm -rf "$BUILD_DIR"
sudo cp -r "$SERVER_SRC" "$BUILD_DIR"
sudo chown -R "$(id -un):$(id -gn)" "$BUILD_DIR"
echo ""
echo -e "\e[1;36m==== stash-server ====\e[0m"
cd "$BUILD_DIR"
attempts=3
delay=10
for try in $(seq 1 "$attempts"); do
  if go build ${BUILD_TAGS:+-tags "$BUILD_TAGS"} -ldflags "-X main.version=$VERSION_STR" -o stash-server .; then
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

echo ""
echo -e "\e[1;36m==== /usr/local/bin/stash-server ====\e[0m"
sudo install -m 0755 -o root -g root "$BUILD_DIR/stash-server" /usr/local/bin/stash-server
# Allow the unprivileged service user to bind the privileged ports :22
# (SCP/SFTP sink) AND :80 (UI/API). Under the systemd unit the LOAD-BEARING
# grant is AmbientCapabilities=CAP_NET_BIND_SERVICE: with NoNewPrivileges=true
# the kernel ignores file capabilities at execve, so this setcap does NOT
# reach the systemd-launched process. The setcap is the fallback for a
# DIRECT (non-systemd) launch, where no_new_privs is not set.
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/stash-server

# §4.2 mandates the custom daemon binds :22, so the OS sshd has to go.
# `disable --now` is idempotent.
echo ""
echo -e "\e[1;36m==== Disabling OS sshd to free port 22 ====\e[0m"
sudo systemctl disable --now ssh.service 2>/dev/null || true
sudo systemctl disable --now ssh.socket  2>/dev/null || true

# --- REGION: VM-local dirs (metadata index + offline buffer), owned by the user
echo ""
echo -e "\e[1;36m==== VM-local storage: /var/lib/stash-server ====\e[0m"
sudo mkdir -p "$METADATA_DIR" "$BUFFER_DIR"
if [ "$SHARE_FOLDER" = "$LOCAL_FALLBACK" ]; then
  sudo mkdir -p "$LOCAL_FALLBACK"
fi
sudo chown -R "$SERVICE_USER":"$SERVICE_USER" /var/lib/stash-server
echo "  metadata: $METADATA_DIR"
echo "  buffer  : $BUFFER_DIR"

# --- REGION: /etc/yuruna/stash.env (consumed by the systemd unit)
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
HOST_IP=$HOST_IP
PRESENCE_INTERVAL=$PRESENCE_INTERVAL
ENV

# --- REGION: systemd unit
# After= the cifs mount unit so the daemon starts once the share is up;
# NOT Requires=/Wants= it -- with the offline buffer (§8.4) the daemon is
# meant to start and buffer even when the share is down, and on a dev
# guest with no NAS the mnt-ystash\x2dnas.mount unit doesn't exist (After= a
# missing unit is a harmless no-op).
echo ""
echo -e "\e[1;36m==== /etc/systemd/system/stash-server.service ====\e[0m"
sudo tee /etc/systemd/system/stash-server.service >/dev/null <<UNIT
[Unit]
Description=Yuruna Stash Service daemon
Documentation=https://yuruna.link/stash-service
After=network-online.target mnt-ystash\x2dnas.mount
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
EnvironmentFile=/etc/yuruna/stash.env
ExecStart=/usr/local/bin/stash-server --share-folder \${SHARE_FOLDER} --metadata-dir \${METADATA_DIR} --buffer-dir \${BUFFER_DIR} --http-addr=\${HTTP_ADDR} --pool-window-days=\${POOL_WINDOW_DAYS} --aggregator-url=\${AGGREGATOR_URL} --host-id=\${HOST_ID} --host-ip=\${HOST_IP} --presence-interval=\${PRESENCE_INTERVAL}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
# The load-bearing grant that lets the non-root service user bind :22 + :80
# (ambient caps survive NoNewPrivileges, unlike the setcap file capability).
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
# Mild hardening; the service is trusted-network only (§11), but these
# cost nothing. ReadWritePaths keeps the VM-local dirs + the share mount
# writable under ProtectSystem. The share mount is '-'-prefixed so a
# missing path is ignored rather than fatal: in the no-stash storage dev
# fallback \$MOUNT (/mnt/ystash-nas) is never created, and an unprefixed entry
# would fail mount-namespace setup (status 226/NAMESPACE) and the unit
# would never start.
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=false
ReadWritePaths=/var/lib/stash-server -$MOUNT

[Install]
WantedBy=multi-user.target
UNIT

echo ""
echo -e "\e[1;36m==== stash-server.service start and enable ====\e[0m"
sudo systemctl daemon-reload
sudo systemctl enable --now stash-server.service

# Wait briefly for the unit to settle (binding :22 is fast, but the Go
# runtime adds a couple hundred ms before the first listen).
for _ in 1 2 3 4 5 6; do
  if sudo systemctl is-active --quiet stash-server.service; then
    break
  fi
  sleep 1
done

if ! sudo systemctl is-active --quiet stash-server.service; then
  echo "stash-server.service did not reach active state. journalctl tail:" >&2
  sudo journalctl -u stash-server.service -n 50 --no-pager >&2 || true
  exit 1
fi
ss -ltnp '( sport = :22 or sport = :80 )' 2>/dev/null | sed -n '1,6p' || true

echo ""
echo "== Stash Service ready =="
echo "  Binary     : /usr/local/bin/stash-server"
echo "  StashFolder: $SHARE_FOLDER"
echo "  Metadata   : $METADATA_DIR"
echo "  Buffer     : $BUFFER_DIR"
if [ -n "$HTTP_ADDR" ]; then
  echo "  UI/API     : http://<vm-ip>:${HTTP_ADDR##*:}  (browse / create / delete; stash-service-ui.md)"
else
  echo "  UI/API     : disabled (STASH_HTTP_ADDR empty)"
fi
echo "  systemd    : sudo systemctl status stash-server.service"
echo "  logs       : sudo journalctl -u stash-server.service -f"
echo "  Exercise   : scp ./file alice@<vm-ip>:/scratch"
echo "               (any username / any password / any key accepted; §4.3)"
