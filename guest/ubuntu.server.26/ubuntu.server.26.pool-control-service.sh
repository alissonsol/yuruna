#!/usr/bin/env bash
# Version: 2026.08.07
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Guest bring-up for the Yuruna Pool control service VM. Mirrors the stash-service
# bring-up: build the Go daemon from the framework checkout, install it, and run
# it under systemd. UNLIKE stash (pure Go), pool-control-service shells out to the
# PowerShell pool-admin CLIs, so this also installs pwsh + powershell-yaml and
# points the daemon at the framework checkout (--repo-dir) whose test/*.ps1 it
# invokes. The daemon persists its audit log + status.json under the pool NAS
# (poolStorageNetworkPath/pool-control-service/), which is CIFS-mounted here with the same
# credential path the pool-storage replication uses.
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
# 'pool-control-service-admin' account; fall back to whoever invoked the script (e.g.
# an interactive test login). The NAS mount's uid/gid must match this user for
# the state-dir writes to land (cifs maps every file to one owner).
if id -u pool-control-service-admin >/dev/null 2>&1; then
  SERVICE_USER=pool-control-service-admin
else
  SERVICE_USER="${SERVICE_USER:-$(id -un)}"
fi
echo "Service user: $SERVICE_USER"
HTTP_ADDR="${POOL_CONTROL_HTTP_ADDR:-0.0.0.0:80}"
PRESENCE_INTERVAL="${POOL_CONTROL_PRESENCE_INTERVAL:-15m}"
# The lab-auth token opens the bearer path on the routes that change pool
# configuration, for automation. Absent file => bearer disabled; an operator
# unlocking with the dashboard's Lab token is then the only way in, and a change
# with neither is refused rather than running ungated.
AUTH_TOKEN_FILE="${POOL_CONTROL_AUTH_TOKEN_FILE:-/etc/yuruna/lab-auth.token}"

# Aggregator URL + host id + host ip from the shared env files (same as stash).
AGGREGATOR_URL="$(sed -n 's/^YURUNA_AGGREGATOR_URL=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
HOST_ID="$(sed -n 's/^YURUNA_HOST_ID=//p' /etc/yuruna/host.env 2>/dev/null | head -1 || true)"
INTENT_GIT_URL="$(sed -n 's/^YURUNA_POOL_INTENT_GIT_URL=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"

# Pool NAS mount (CIFS) -> state dir. NAS host/share/cred come from pool.env,
# matching Test.PoolStorage's networkStorage.poolStorageNetworkPath contract.
POOL_NAS_UNC="$(sed -n 's/^YURUNA_POOL_NETWORK_PATH=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
POOL_NAS_IP="$(sed -n 's/^YURUNA_POOL_NETWORK_IP=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
POOL_NAS_USER="$(sed -n 's/^YURUNA_POOL_NETWORK_USER=//p' /etc/yuruna/pool.env 2>/dev/null | head -1 || true)"
MOUNT=/mnt/yuruna-pool
STATE_DIR="$MOUNT/pool-control-service"
# The intent store the daemon COMMITS to. The proxy's http://<proxy>/pool-intent.git
# route is dumb-HTTP (apache Alias, no git-http-backend), i.e. pull-only -- pointing
# the daemon at it yields a UI that reads but fails every write at push time. The
# pool NAS is the one location both this VM and the proxy mount read-write, so the
# writable store lives there and the proxy can serve those same bytes to runners.
INTENT_STORE="$MOUNT/pool-intent.git"

echo "== pool-control-service bring-up: installing deps =="
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
# --- REGION: https://yuruna.link/memory#why-ubuntu-guest-update-scripts-install-powershell-first
# PowerShell (the daemon shells out to the pool-admin CLIs). Install from the
# GitHub-release tarball, NOT packages.microsoft.com: the prod repo publishes a
# resolute suite but ships no `powershell` package in it, so the apt path leaves
# the guest with no pwsh at all. The tarball is version- and distro-independent
# and is what the sibling ubuntu.server.26 update path already uses.
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

  # Verify against the release's published hashes.sha256 before unpacking (pwsh
  # is the interpreter for every pool-admin CLI this daemon drives). The asset is
  # UTF-16 LE (BOM+CRLF, Windows-generated) -> normalize to UTF-8/LF. A genuine
  # MISMATCH is fatal; a hashes.sha256 that cannot be fetched or parsed only
  # WARNs so a transient GitHub blip never fails the whole bring-up.
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

# Locate the framework checkout (the pool-control-service source + the pool-admin CLIs).
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
VERSION_STR="$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo dev)"

echo "== building pool-control-service ($VERSION_STR) from $SERVER_DIR =="
BUILD=/tmp/pool-control-service-build
rm -rf "$BUILD"; cp -r "$SERVER_DIR" "$BUILD"
# go.sum is committed, so DO NOT run `go mod tidy` (it needs the network to
# recompute the graph); `go build` verifies against go.sum and fetches missing
# modules through the caching-proxy service. Retry: a cache miss the proxy cannot
# relay surfaces as a transient fetch failure that clears once it has the object.
attempts=3
delay=10
for try in $(seq 1 "$attempts"); do
  if ( cd "$BUILD" && go build -ldflags "-X main.version=$VERSION_STR" -o pool-control-service . ); then
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
sudo install -m 0755 -o root -g root "$BUILD/pool-control-service" /usr/local/bin/pool-control-service
# Fallback for a DIRECT (non-systemd) launch only: with NoNewPrivileges=true
# the kernel ignores file capabilities at execve, so this does not reach the
# systemd-launched process -- AmbientCapabilities in the unit does.
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/pool-control-service || true

# Mount the pool NAS for the state dir (best-effort; the daemon degrades to no
# persistence if the mount is absent).
if [[ -n "$POOL_NAS_UNC" ]]; then
  sudo mkdir -p "$MOUNT"
  # NO iocharset=utf8: nls_utf8 is absent on the minimal cloud kernel and the
  # mount fails with error(79); the state-dir names are ASCII. Open modes
  # (0777/0666) match the parent share -- the server maps the cifs mount mode
  # onto the created object's ACL, so a restrictive dir_mode would lock every
  # folder the VM creates to the single creator and the host could not read
  # the audit log back. nofail/_netdev keep a NAS outage from wedging boot.
  MOUNT_OPTS="credentials=/etc/yuruna/pool-nas.cifs.cred,vers=3.0,uid=$(id -u "$SERVICE_USER"),gid=$(id -g "$SERVICE_USER"),file_mode=0666,dir_mode=0777,noperm,nofail,_netdev"
  # ip= lets cifs connect when the guest cannot resolve the share's server name
  # -- a bare NetBIOS name, or a host-side alias that only the host resolves.
  # Baked by Get-YurunaPoolSeedValue, which never emits an address a guest
  # cannot dial. Same option, same reason, as the stash guest's mount.
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
sudo mkdir -p "$STATE_DIR" 2>/dev/null || true
# Only chown the LOCAL fallback: on a mode-mapped cifs mount the uid/gid mount
# options already place ownership, and a chown there can re-impose an
# owner-only ACL that locks the host out of the audit log.
if ! mountpoint -q "$MOUNT" 2>/dev/null; then
  sudo chown -R "$SERVICE_USER":"$SERVICE_USER" "$STATE_DIR" 2>/dev/null || true
fi

# --- REGION: intent store bootstrap
# A pool-control-service VM with no intent store has no working UI: every read and write
# targets it. Resolve one, and CREATE it when it is absent, so a first bring-up
# reaches a working state without an operator pre-staging anything.
#
# Precedence: an explicit seed value wins; otherwise the pool NAS store, which is
# writable from here. The host bake resolves the same order, so the seed usually
# ALREADY carries the NAS path -- which is why creation below keys on "the
# resolved path is not a repo yet" rather than on "no URL was supplied". Keying
# on emptiness would skip creation in exactly the case that needs it.
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
    echo "== initializing pool intent store at $INTENT_GIT_URL =="
    # Run git AS THE SERVICE USER, not as the root cloud-init runs this under:
    # the cifs mount maps every file to the service user's uid, so a root-created
    # repo is owned by someone other than the caller and git then refuses it with
    # "detected dubious ownership". Creating it as the eventual owner keeps the
    # daemon's own git calls out of that trap too.
    # core.fileMode=false: cifs maps modes from the mount options, so git would
    # otherwise see a permission change on every file it writes back.
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

echo "== env + systemd unit =="
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
EOF

sudo tee /etc/systemd/system/pool-control-service.service >/dev/null <<EOF
[Unit]
Description=Yuruna Pool control service
Documentation=https://yuruna.link/pool-control-service
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
ExecStart=/usr/local/bin/pool-control-service --http-addr=\${POOL_CONTROL_HTTP_ADDR} --repo-dir=\${POOL_CONTROL_REPO_DIR} --pwsh=\${POOL_CONTROL_PWSH} --aggregator-url=\${POOL_CONTROL_AGGREGATOR_URL} --host-id=\${POOL_CONTROL_HOST_ID} --intent-git-url=\${POOL_CONTROL_INTENT_GIT_URL} --state-dir=\${POOL_CONTROL_STATE_DIR} --presence-interval=\${POOL_CONTROL_PRESENCE_INTERVAL} --auth-token-file=\${POOL_CONTROL_AUTH_TOKEN_FILE}
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF

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
  echo "FETCHED AND EXECUTED: pool-control-service.service active on $HTTP_ADDR (state=$STATE_DIR)"
else
  echo "pool-control-service.service failed to start:" >&2
  sudo journalctl -u pool-control-service.service --no-pager -n 40 >&2 || true
  exit 1
fi
