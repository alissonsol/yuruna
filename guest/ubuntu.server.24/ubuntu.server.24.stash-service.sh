#!/bin/bash
# Version: 2026.05.29
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Bring up the Yuruna Stash Service daemon on this VM. Compiles the
# Go source under <enlistment>/test/extension/stash-service/server/,
# installs the binary at /usr/local/bin/stash-server, disables the
# OS sshd so the custom server can bind :22 (§4.2), grants the
# binary CAP_NET_BIND_SERVICE, and registers a systemd unit so the
# daemon starts on boot and restarts on failure.
#
# --- See https://yuruna.link/stash-service
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export NONINTERACTIVE=1

# ===== Detect architecture =====
ARCH=$(uname -m)
echo "Detected architecture: $ARCH"
case "$ARCH" in
  x86_64|aarch64) ;;
  *)
    echo "WARNING: Unsupported architecture: $ARCH (need x86_64 or aarch64)." >&2
    exit 1
    ;;
esac

# --- See https://yuruna.link/network#defining-yuruna-retry-lib
. /usr/local/lib/yuruna/yuruna_retry.sh

# ===== Locate the Yuruna enlistment that holds the daemon source =====
# update.sh clones the framework into $HOME/yuruna for the user that
# ran it (typically yuuser24). When this script runs as a different
# user (the workload's service user, e.g. ystash), $HOME/yuruna may
# not exist; fall back to whichever /home/*/yuruna carries the
# server/ directory. Building from there keeps the binary in lock-
# step with the framework checkout the harness deployed this cycle.
locate_server_dir() {
  local candidates=( "$HOME/yuruna" )
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

# ===== Install Go toolchain =====
echo ""
echo -e "\e[1;36m>>> Installing Go toolchain...\e[0m"
apt_retry sudo apt-get update -y
apt_retry sudo apt-get install -y golang-go libcap2-bin
go version
echo -e "\e[1;32m<<< Go toolchain ready.\e[0m"

# ===== Stage the source under /tmp (avoids cross-home perm issues) =====
# /home/<other-user>/yuruna may be mode 0750 and unreadable by this
# user. sudo cp lets the source traverse anyway; chown lets the
# subsequent `go build` run unprivileged (so the module cache lands
# under this user's $HOME/go/, not root's, which keeps repeat builds
# fast).
BUILD_DIR=/tmp/stash-build
echo ""
echo -e "\e[1;36m>>> Staging source to $BUILD_DIR...\e[0m"
sudo rm -rf "$BUILD_DIR"
sudo cp -r "$SERVER_SRC" "$BUILD_DIR"
sudo chown -R "$USER:$USER" "$BUILD_DIR"
echo -e "\e[1;32m<<< Source staged.\e[0m"

# ===== Build the daemon =====
echo ""
echo -e "\e[1;36m>>> Building stash-server...\e[0m"
cd "$BUILD_DIR"
# go mod tidy reaches out to proxy.golang.org for the two deps in
# go.mod (golang.org/x/crypto, modernc.org/sqlite). Wrap with
# curl_retry-equivalent semantics by retrying go itself; transient
# 5xx from the proxy is the most common failure mode here.
attempts=3
delay=10
for try in $(seq 1 "$attempts"); do
  if go mod tidy && go build -o stash-server .; then
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
echo -e "\e[1;32m<<< stash-server built at $BUILD_DIR/stash-server.\e[0m"

# ===== Install binary =====
echo ""
echo -e "\e[1;36m>>> Installing /usr/local/bin/stash-server...\e[0m"
sudo install -m 0755 -o root -g root "$BUILD_DIR/stash-server" /usr/local/bin/stash-server
# CAP_NET_BIND_SERVICE lets the unprivileged service user bind :22
# without running the daemon as root. The systemd unit below ALSO
# sets AmbientCapabilities for the same capability (belt + braces:
# either alone would work; carrying both makes the configuration
# resilient to either being stripped).
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/stash-server
echo -e "\e[1;32m<<< Binary installed; cap_net_bind_service granted.\e[0m"

# ===== Free up port 22 =====
# §4.2 mandates the custom daemon binds :22, so the OS sshd has to go.
# `disable --now ssh` is idempotent — re-running this script when
# sshd is already gone is a no-op.
echo ""
echo -e "\e[1;36m>>> Disabling OS sshd to free port 22...\e[0m"
sudo systemctl disable --now ssh.service 2>/dev/null || true
sudo systemctl disable --now ssh.socket  2>/dev/null || true
echo -e "\e[1;32m<<< OS sshd disabled.\e[0m"

# ===== Ensure StashFolder exists =====
# Default path (§6.1): $HOME/yuruna/test/status/stash. The daemon
# also creates it on startup, but pre-creating it lets us verify
# write access up front and lets the systemd unit's WorkingDirectory
# resolve to a real path on first start.
STASH_FOLDER="$HOME/yuruna/test/status/stash"
mkdir -p "$STASH_FOLDER"
echo "StashFolder: $STASH_FOLDER"

# ===== Install systemd unit =====
# §4.6 of the spec deferred daemon supervision; including it here
# anyway because it is the unblocking lift for "the daemon survives
# a VM reboot without manual restart". Restart=on-failure backs off
# RestartSec=5s between attempts. The unit logs to stderr by design
# (§4.6); journald collects it under `journalctl -u stash-server`.
echo ""
echo -e "\e[1;36m>>> Writing /etc/systemd/system/stash-server.service...\e[0m"
sudo tee /etc/systemd/system/stash-server.service >/dev/null <<UNIT
[Unit]
Description=Yuruna Stash Service daemon
Documentation=https://yuruna.link/stash-service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$HOME
ExecStart=/usr/local/bin/stash-server --folder $STASH_FOLDER
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
# Allow the non-root service user to bind :22.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
# Mild hardening; the spec (§11) calls the daemon trusted-network
# only, but these settings cost nothing and reduce blast radius.
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=false

[Install]
WantedBy=multi-user.target
UNIT
echo -e "\e[1;32m<<< Unit file written.\e[0m"

# ===== Enable + start the service =====
echo ""
echo -e "\e[1;36m>>> Enabling and starting stash-server.service...\e[0m"
sudo systemctl daemon-reload
sudo systemctl enable --now stash-server.service

# Wait briefly for the unit to settle (binding :22 is fast, but the
# Go runtime adds a couple hundred ms before the first listen).
for i in 1 2 3 4 5 6; do
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
echo -e "\e[1;32m<<< stash-server.service is active.\e[0m"

# ===== Confirm port 22 is the daemon's =====
ss -ltnp '( sport = :22 )' 2>/dev/null | sed -n '1,5p' || true

echo ""
echo "=== Stash Service ready ==="
echo "  Binary    : /usr/local/bin/stash-server"
echo "  StashFolder: $STASH_FOLDER"
echo "  systemd    : sudo systemctl status stash-server.service"
echo "  logs       : sudo journalctl -u stash-server.service -f"
echo "  Exercise   : scp ./file alice@<vm-ip>:/scratch"
echo "               (any username / any password / any key accepted; §4.3)"
