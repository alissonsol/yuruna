#!/bin/sh
# Version: 2026.11.16
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42f6780f-6201-4bb8-94a5-7862ef198dac
#
# Write one NAS credential (stash or pool) as a cifs credentials file, read
# from the building host's config service over mutual TLS. cloud-init deploys
# this file at /usr/local/bin/yuruna-nas-credential.sh, and a service guest
# runs it before its first share mount, so the NAS password is never part of
# the seed media and is never written anywhere but the 0600 file the mount
# reads.
#
# Usage: yuruna-nas-credential.sh <stash|pool> <credentials-file> [<mount-point>]
# Exit 0 when the file was written (or, with a mount point, is current); 1
# otherwise, with the reason on stderr. The caller's mount then fails the way an
# absent share already does, so a host without a running config service
# degrades instead of blocking boot.
#
# With a mount point the script is the periodic refresh: a rotated NAS password
# would otherwise reach the guest only through a rebuild, and the kernel keeps
# the password a share was mounted with, so every reconnect after a rotation
# fails. A changed credential replaces the file; an unchanged one is left alone.
# A share that is mounted is remounted in place when the credential changed or
# when it no longer answers, so the kernel takes the current password: it
# accepts a new one while the session needs to reconnect, which is what a
# rotation causes. The share is never unmounted, and one that is not mounted
# stays so: the services decided at boot whether to use it, and anything they
# wrote to the bare mount point would be shadowed by a later mount.
set -u
NAME="${1:-}"
CRED="${2:-}"
MOUNT="${3:-}"
CDIR="${YURUNA_HOST_CONFIG_DIR:-/etc/yuruna/host-config}"
HOST_ENV="${YURUNA_HOST_ENV_FILE:-/etc/yuruna/host.env}"
ATTEMPTS="${YURUNA_NAS_CREDENTIAL_ATTEMPTS:-5}"
PAUSE="${YURUNA_NAS_CREDENTIAL_PAUSE_SECONDS:-10}"
fail() { echo "yuruna-nas-credential: $NAME: $1" >&2; exit 1; }
case "$NAME" in stash|pool) ;; *) fail "usage: $0 <stash|pool> <credentials-file>" ;; esac
[ -n "$CRED" ] || fail "no credentials file named"
# Read, never sourced: the values are written by the host but this script
# runs as root, and sourcing would execute anything a value carried.
HOST_IP=$(sed -nE 's/^YURUNA_STATUS_SERVICE_IP=([0-9A-Za-z.:-]+)$/\1/p' "$HOST_ENV" 2>/dev/null | head -n1)
PORT=$(sed -nE 's/^YURUNA_CONFIG_SERVICE_PORT=([0-9]+)$/\1/p' "$CDIR/config.env" 2>/dev/null | head -n1)
PORT="${PORT:-8443}"
SAN="yuruna-host-config"
[ -n "$HOST_IP" ] || fail "no host address in $HOST_ENV"
for f in ca.crt client.crt client.key; do
  [ -s "$CDIR/$f" ] || fail "mutual-TLS material $CDIR/$f is absent"
done
command -v curl >/dev/null 2>&1 || fail "curl is not installed"
command -v python3 >/dev/null 2>&1 || fail "python3 is not installed"
# The host config service may still be starting while the guest boots.
JSON=''
i=1
while [ "$i" -le "$ATTEMPTS" ]; do
  JSON=$(curl -sS --max-time 20 --cacert "$CDIR/ca.crt" --cert "$CDIR/client.crt" --key "$CDIR/client.key" \
    --connect-to "$SAN:$PORT:$HOST_IP:$PORT" "https://$SAN:$PORT/v1/nas/$NAME" 2>/dev/null) && [ -n "$JSON" ] && break
  JSON=''
  i=$((i + 1))
  [ "$i" -le "$ATTEMPTS" ] && sleep "$PAUSE"
done
[ -n "$JSON" ] || fail "the config service at $HOST_IP:$PORT did not answer"
# One field per line; a value holding a newline is refused rather than split.
FIELDS=$(printf '%s' "$JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
u, p = str(d.get("username") or ""), str(d.get("password") or "")
if not u or not p or "\n" in u + p:
    sys.exit(1)
print(u)
print(p)
' 2>/dev/null) || fail "the config service returned no usable credential"
NAS_USER=$(printf '%s\n' "$FIELDS" | sed -n 1p)
NAS_PASS=$(printf '%s\n' "$FIELDS" | sed -n 2p)
# A disconnected CIFS mount can make mountpoint's filesystem probe fail.
# Read the mount table without resolving the target; keep the original probe
# as a fallback where findmnt is absent or cannot answer.
share_is_mounted() {
  if command -v findmnt >/dev/null 2>&1 && \
     findmnt --nocanonicalize --mountpoint "$MOUNT" --noheadings --output TARGET >/dev/null 2>&1; then
    return 0
  fi
  mountpoint -q "$MOUNT" 2>/dev/null
}
# Linux refuses a changed primary password while its session is active. A
# password2-only reconfigure leaves that primary alone across successive
# rotations. Both source and target are named so mount does not merge the
# fstab credentials back in. Existing noncredential mount options are retained.
# https://github.com/piastry/cifs-utils/blob/master/mount.cifs.rst
remount_alternate_password() {
  python3 - "$MOUNT" "$CRED" <<'PY_REMOUNT'
import json, os, subprocess, sys, tempfile, time
from pathlib import Path

mount, credentials = sys.argv[1:]
path = None
try:
    table = subprocess.run(["findmnt", "--json", "--nocanonicalize", "--mountpoint", mount,
                            "--output", "SOURCE,OPTIONS"], capture_output=True, text=True, timeout=5, check=True)
    entry = json.loads(table.stdout)["filesystems"][0]
    values = dict(line.split("=", 1) for line in Path(credentials).read_text().splitlines() if "=" in line)
    excluded = {"credentials", "cred", "password", "pass", "password2", "pass2", "username", "user"}
    options = [item for item in entry["options"].split(",") if item.split("=", 1)[0] not in excluded]
    with tempfile.NamedTemporaryFile(mode="w", prefix=".nas-remount-", dir=Path(credentials).parent,
                                     delete=False) as temporary:
        path = Path(temporary.name)
        temporary.write("username=" + values["username"] + "\npassword2=" + values["password"] + "\n")
    deadline = time.monotonic() + 60
    subprocess.run(["mount", "-t", "cifs", "-o", "remount," + ",".join(options) + ",credentials=" + str(path),
                    entry["source"], mount], timeout=60, check=True)
    # Updating the alternate password need not finish the kernel's reconnect.
    # Wait for a bounded filesystem read instead of reporting the mount call alone.
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        try:
            ready = subprocess.run(["stat", "-f", mount], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   timeout=min(5, remaining)).returncode == 0
        except subprocess.TimeoutExpired:
            ready = False
        if ready:
            sys.exit(0)
        time.sleep(min(0.5, max(0, deadline - time.monotonic())))
except (OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError):
    pass
finally:
    if path is not None:
        path.unlink(missing_ok=True)
sys.exit(1)
PY_REMOUNT
}
# remount_share: in place, with the credentials file the share's fstab entry names.
remount_share() {
  if timeout 60 mount -o remount "$MOUNT" || remount_alternate_password; then
    echo "yuruna-nas-credential: $NAME: $MOUNT remounted with the current credentials"
  else
    fail "$MOUNT could not be remounted; it keeps its previous session until the guest is rebuilt or the share is remounted by hand"
  fi
}
if [ -n "$MOUNT" ] && [ -f "$CRED" ] && \
   [ "$(cat "$CRED" 2>/dev/null)" = "$(printf 'username=%s\npassword=%s' "$NAS_USER" "$NAS_PASS")" ]; then
  if share_is_mounted && ! timeout 15 stat -f "$MOUNT" >/dev/null 2>&1; then
    echo "yuruna-nas-credential: $NAME: $MOUNT does not answer; remounting it"
    remount_share
  fi
  echo "yuruna-nas-credential: $NAME: credentials in $CRED are current"
  exit 0
fi
umask 077
TMP="$CRED.tmp.$$"
# printf %s writes the password literally, so vault special characters reach
# the credentials file intact.
printf 'username=%s\npassword=%s\n' "$NAS_USER" "$NAS_PASS" > "$TMP" || fail "could not write $TMP"
if ! { chmod 600 "$TMP" && mv -f "$TMP" "$CRED"; }; then
  rm -f "$TMP"
  fail "could not install $CRED"
fi
echo "yuruna-nas-credential: $NAME: credentials written to $CRED"
if [ -n "$MOUNT" ] && share_is_mounted; then
  remount_share
fi
exit 0
