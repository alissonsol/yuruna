#!/bin/bash
# Yuruna Ubuntu KVM/libvirt bootstrap installer.
# LICENSEURI https://yuruna.link/license
# Version: 2026.07.14  Copyright (c) 2019-2026 by Alisson Sol et al.
# --- REGION: https://yuruna.link/install/explained
# One-liner: bash <(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh)
# Supported target: Ubuntu 26.04 (Resolute) or newer on x86_64 (aarch64 supported but UNTESTED -- see preflight).

set -euo pipefail

YURUNA_REPO_PUBLIC="https://github.com/alissonsol/yuruna.git"
YURUNA_REPO_PRIVATE="https://github.com/alissonsol/yurunadev.git"
YURUNA_REPO="${YURUNA_REPO:-$YURUNA_REPO_PUBLIC}"
# Track whether the operator pinned a ref explicitly. The development repo
# (yurunadev) is only tagged at the weekly release, so its pinned-CalVer default
# would never resolve mid-week; when targeting it we fall back to latest 'main'
# unless the operator asked for a specific ref.
YURUNA_BRANCH_EXPLICIT=0
[[ -n "${YURUNA_BRANCH:-}" ]] && YURUNA_BRANCH_EXPLICIT=1
YURUNA_BRANCH="${YURUNA_BRANCH:-main}"
# Pin opt-in: PIN_VERSION=1 (env -- used by the remote one-liners) or the
# --pin-version flag (local runs). The default 'main' is a tracking branch the
# runner fast-forwards every cycle (auto-update). When pinning, the host is
# frozen at the CURRENT release AFTER the clone -- the repo's own VERSION file
# (single source of truth, top of the repository) is read and that tag checked
# out as a detached HEAD, so nothing is hard-coded here and a release never
# needs to re-pin the installer. An explicit YURUNA_BRANCH=<ref> wins.
PIN_VERSION="${PIN_VERSION:-0}"
for _yuruna_arg in "$@"; do
  [[ "$_yuruna_arg" == "--pin-version" ]] && PIN_VERSION=1
done
YURUNA_DIR="${YURUNA_DIR:-$HOME/git/yuruna}"

# Pinned apt signing-key fingerprints, verified before each key is trusted as
# an apt anchor (a MITM that swaps the key fetch otherwise plants a permanent
# trust root). Refresh on a vendor key rotation: re-fetch the key, confirm the
# new fingerprint with `gpg --show-keys --with-colons`, and update the value.
MS_APT_KEY_FPR="AA86F75E427A19DD33346403EE4D7792F748182B"       # Microsoft 2025 General GPG Signer (Ubuntu >= 25.10 prod repo)
GH_APT_KEY_FPR_NEW="7F38BBB59D064DBCB3D84D725612B36462313325"   # GitHub CLI (current)
GH_APT_KEY_FPR_OLD="2C6106201985B60E6C7AC87323F3D4EA75716059"   # GitHub CLI (legacy, expires 2026-09-05)

_yuruna_step="<starting up>"
log()  { _yuruna_step="$*"; printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX \033[0m %s\n' "$*" >&2; exit 1; }

# --- REGION: Install log
# Mirror stdout+stderr to a file as well as the terminal so a mid-install
# failure can be inspected afterwards. A FIFO + backgrounded tee (rather than
# `exec > >(tee ...)`) lets the EXIT path wait for tee to flush, so the file is
# complete even on an abrupt exit -- a plain process-substitution tee is left
# an orphan that may be killed before flushing its block-buffered file write.
# Standard per-user state dir, ${TMPDIR:-/tmp} fallback.
if [[ -z "${YURUNA_INSTALL_LOG:-}" ]]; then
  _yuruna_log_dir="${XDG_STATE_HOME:-$HOME/.local/state}/yuruna/logs"
  mkdir -p "$_yuruna_log_dir" 2>/dev/null || _yuruna_log_dir="${TMPDIR:-/tmp}"
  YURUNA_INSTALL_LOG="$_yuruna_log_dir/ubuntu.kvm.install.$(date +%Y%m%d-%H%M%S).log"
fi
export YURUNA_INSTALL_LOG
_yuruna_tee_pid=""
_yuruna_logfifo="$(mktemp -u 2>/dev/null || echo "${TMPDIR:-/tmp}/yuruna-logfifo.$$")"
if mkfifo "$_yuruna_logfifo" 2>/dev/null; then
  tee -a "$YURUNA_INSTALL_LOG" < "$_yuruna_logfifo" &
  _yuruna_tee_pid=$!
  exec > "$_yuruna_logfifo" 2>&1
  rm -f "$_yuruna_logfifo"        # fds keep the unlinked pipe alive
fi
# Flush + reap tee at exit so the on-disk log is complete. Called LAST from the
# EXIT trap, after the sudo keepalive (another holder of the pipe) is killed.
_yuruna_flush_log() {
  if [[ -n "${_yuruna_tee_pid:-}" ]]; then
    exec >&- 2>&- || true        # close the write end so tee sees EOF
    wait "$_yuruna_tee_pid" 2>/dev/null || true
  fi
}
if [[ -n "$_yuruna_tee_pid" ]]; then
  log "Install log: $YURUNA_INSTALL_LOG"
  log "  (inspect this file if the installer stops midway)"
else
  warn "Could not create an install log file; output goes to this terminal only."
fi

# Verify a downloaded apt signing key before trusting it as an apt anchor (a
# MITM that swaps the key fetch would otherwise plant a permanent trust root).
# Args after the key file are the ALLOWED primary fingerprints; the FIRST is
# also REQUIRED to be present. Dies if the file carries any fingerprint outside
# the allow-set, or if the required one is missing. Works on armored .asc and
# binary .gpg key files.
verify_key_fingerprints() {
  local keyfile="$1"; shift
  local required="${1^^}"
  local allowed=("$@")
  local present a fpr ok found_required=0
  present="$(gpg --show-keys --with-colons "$keyfile" 2>/dev/null \
            | awk -F: '/^pub:/{p=1} /^fpr:/{if(p){print toupper($10); p=0}}')"
  [[ -n "$present" ]] || die "No primary key fingerprints in $keyfile (is gpg installed?)"
  while IFS= read -r fpr; do
    fpr="${fpr//[$'\r\n\t ']/}"
    [[ -z "$fpr" ]] && continue
    ok=0
    for a in "${allowed[@]}"; do [[ "${a^^}" == "$fpr" ]] && { ok=1; break; }; done
    (( ok )) || die "Unexpected key fingerprint in $keyfile: $fpr (not in the pinned allow-set)"
    [[ "$fpr" == "$required" ]] && found_required=1
  done <<<"$present"
  (( found_required )) || die "Required key fingerprint $required missing from $keyfile"
}

# --- REGION: ERR trap
_yuruna_on_err() {
    local rc=$?
    printf '\n\033[1;31mXX \033[0m installer aborted (exit %d)\n' "$rc" >&2
    printf '   step    : %s\n' "$_yuruna_step" >&2
    printf '   line    : %s\n' "${BASH_LINENO[0]:-?}" >&2
    printf '   command : %s\n' "${BASH_COMMAND:-?}" >&2
    printf '   log     : %s\n' "${YURUNA_INSTALL_LOG:-<none>}" >&2
    printf '\n   Re-run with `bash -x <script>` to trace every command,\n' >&2
    printf   '   or `sudo apt-get update` directly to see apt errors verbatim.\n' >&2
    exit "$rc"
}
trap _yuruna_on_err ERR

# --- REGION: Preflight: Linux only
[[ "$(uname -s)" == "Linux" ]] || die "This installer only supports Linux."
[[ -r /etc/os-release ]] || die "/etc/os-release missing -- not a recognized Linux."
. /etc/os-release
[[ $EUID -ne 0 ]] || die "Do not run as root. The script will call sudo when needed."

ARCH="$(uname -m)"

log "Yuruna Ubuntu KVM installer starting"
log "  distro : ${PRETTY_NAME:-$ID $VERSION_ID}"
log "  arch   : $ARCH"
log "  repo   : $YURUNA_REPO ($YURUNA_BRANCH)"
log "  target : $YURUNA_DIR"

# --- REGION: Preflight: system requirements
preflight_system_requirements() {
  local issues=()
  local cores mem_kb mem_gb disk_kb disk_gb ubuntu_major ubuntu_minor ubuntu_num
  if [[ "${ID:-unknown}" != "ubuntu" ]]; then
    issues+=("distro '${PRETTY_NAME:-$ID}' detected (need Ubuntu 26+)")
  fi
  ubuntu_major="${VERSION_ID%%.*}"
  ubuntu_minor="${VERSION_ID#*.}"
  ubuntu_num=$(( 10#${ubuntu_major:-0} * 100 + 10#${ubuntu_minor:-0} ))
  if (( ubuntu_num < 2604 )); then
    issues+=("Ubuntu ${VERSION_ID:-?} detected (need 26.04+)")
  fi
  if [[ "$ARCH" != "x86_64" ]]; then
    issues+=("architecture '$ARCH' detected (need amd64/x86_64)")
  fi
  cores=$(nproc --all 2>/dev/null || echo 0)
  if (( cores < 16 )); then
    issues+=("$cores cores detected (need 16+)")
  fi
  mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  # Round to nearest GB (add half the divisor) so a box a fraction under the
  # boundary -- e.g. 32 GB reporting 31.6 GB MemTotal -- is not warned as 31.
  mem_gb=$(( (${mem_kb:-0} + 512 * 1024) / (1024 * 1024) ))
  if (( mem_gb < 32 )); then
    issues+=("${mem_gb}GB RAM detected (need 32GB+)")
  fi
  disk_kb=$(df -k / 2>/dev/null | awk 'NR==2 {print $4}')
  disk_gb=$(( (${disk_kb:-0} + 512 * 1024) / (1024 * 1024) ))
  if (( disk_gb < 512 )); then
    issues+=("${disk_gb}GB free on / (need 512GB+)")
  fi
  if (( ${#issues[@]} == 0 )); then
    log "System OK: $cores cores, ${mem_gb}GB RAM, ${disk_gb}GB free on /"
    return 0
  fi
  warn ''
  warn '============================================================'
  warn '  System does not meet Yuruna TESTED requirements:'
  local i; for i in "${issues[@]}"; do warn "    - $i"; done
  warn ''
  warn '  Tested baseline (Ubuntu host):'
  warn '    32GB RAM, 512GB free, Ubuntu 26+ on amd64, 16+ cores.'
  warn ''
  warn '  Continuing is permitted but UNTESTED; the test harness may'
  warn '  fail in ways the core development team cannot reproduce.'
  warn '============================================================'
  warn ''
  local ans
  read -r -p 'Continue anyway? [y/N]: ' ans
  case "$(printf '%s' "${ans:-}" | tr '[:upper:]' '[:lower:]')" in
    y|yes) log 'Proceeding despite unmet requirements.' ;;
    *)     die 'Aborted by user (system requirements not met).' ;;
  esac
}
preflight_system_requirements

# --- REGION: sudo announcement + keepalive
cat <<'SUDO_NOTICE'

  +---------------------------------------------------------------+
  |  This installer needs sudo for:                               |
  |    * apt-get install (qemu/libvirt/virt-install/pwsh/...)     |
  |    * usermod -aG libvirt,kvm <you>                            |
  |    * systemctl enable --now libvirtd virtlogd                 |
  |    * cloud-init ISO build (genisoimage / cloud-localds)       |
  |  You will be prompted for your sudo password ONCE, below.     |
  +---------------------------------------------------------------+

SUDO_NOTICE
sudo -v
export YURUNA_SUDO_PRIMED=1
( while true; do sudo -n true 2>/dev/null || true; sleep 30; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!

YURUNA_STATUS_BACKUP=""
yuruna_install_cleanup() {
  kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  if [[ -n "${YURUNA_STATUS_BACKUP:-}" && -d "${YURUNA_STATUS_BACKUP:-}" ]]; then
    rm -rf "$YURUNA_STATUS_BACKUP" 2>/dev/null || true
  fi
  _yuruna_flush_log
}
trap yuruna_install_cleanup EXIT

# --- REGION: Preflight: CPU virtualization (vmx/svm)
HAVE_VMX=0
if grep -qE '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
  HAVE_VMX=1
elif [[ "$ARCH" == "aarch64" ]]; then
  HAVE_VMX=1
fi
if [[ $HAVE_VMX -eq 0 ]]; then
  die "CPU virtualization extensions (vmx/svm) not detected in /proc/cpuinfo.
       Either virtualization is disabled in firmware (enable Intel VT-x or
       AMD-V in BIOS/UEFI) or this is a guest VM without nested
       virtualization. Without KVM acceleration the test harness is
       unusable -- aborting before installing anything."
fi

# --- REGION: Stop running Yuruna host services
# Force-stop the outer runner, its per-cycle inner pwsh, and the detached
# status HTTP server, then WAIT for them to exit before the repo update
# renames the checkout aside. VMs (the yuruna-caching-proxy cache, a libvirt
# domain) are never touched here: they are not children of the runner, and
# this installer issues no domain stop/destroy.
#
# Targets are collected from three channels so a service is caught even when
# one misses it: (1) the PID files the runner/server write (runner.pid,
# inner.pid, server.pid under the runtime dir) -- authoritative; (2) a
# command-line match, including the detached server's generated script name
# .status-service.ps1, which does NOT contain "Start-StatusService.ps1"; and
# (3) the status port's listener (configured port + the 8080 default).
stop_yuruna_processes() {
  local runtime_dir="${YURUNA_RUNTIME_DIR:-$YURUNA_DIR/test/status/runtime}"
  local -a target_pids=()
  local pid

  # (1) PID files -- readable even when a process's command line is not.
  local pidname pidfile raw
  for pidname in runner.pid inner.pid server.pid; do
    pidfile="$runtime_dir/$pidname"
    if [[ -f "$pidfile" ]]; then
      raw=$(tr -dc '0-9' < "$pidfile" 2>/dev/null || true)
      if [[ -n "$raw" ]]; then target_pids+=("$raw"); fi
    fi
  done

  # (2) Command-line pattern match.
  local -a patterns=(
    "Invoke-TestRunner.ps1"
    "Invoke-TestInnerRunner.ps1"
    "Test-Sequence.ps1"
    "Start-StatusService.ps1"
    ".status-service.ps1"
  )
  local pat p
  for pat in "${patterns[@]}"; do
    while IFS= read -r p; do
      if [[ -n "$p" ]]; then target_pids+=("$p"); fi
    done < <(pgrep -f "$pat" 2>/dev/null || true)
  done

  # (3) Status-port listener(s): configured port + the 8080 default.
  local -a ports=("8080")
  local cfg="$YURUNA_DIR/test/test.config.yml"
  if [[ -f "$cfg" ]]; then
    local cport
    cport=$(awk '
      /^statusService:[[:space:]]*$/ { inblk=1; next }
      inblk && /^[^[:space:]]/        { exit }
      inblk && /^[[:space:]]+port:[[:space:]]*[0-9]+/ { gsub(/[^0-9]/,""); print; exit }
    ' "$cfg" 2>/dev/null || true)
    if [[ -n "$cport" && "$cport" != "8080" ]]; then ports+=("$cport"); fi
  fi
  local port plist pp
  for port in "${ports[@]}"; do
    plist=""
    if command -v lsof >/dev/null 2>&1; then
      plist=$(lsof -ti "tcp:$port" 2>/dev/null || true)
    elif command -v ss >/dev/null 2>&1; then
      plist=$(ss -ltnpH "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 || true)
    fi
    if [[ -n "$plist" ]]; then
      while IFS= read -r pp; do
        if [[ -n "$pp" ]]; then target_pids+=("$pp"); fi
      done <<< "$plist"
    fi
  done

  # Dedupe, drop our own pid, and IDENTITY-VALIDATE each candidate: keep only
  # PIDs whose executable is actually a PowerShell interpreter. Every real
  # target (runner / inner / detached status server) is pwsh; a PID read from a
  # PID file a crashed run left behind holds a raw integer the kernel may since
  # have RECYCLED to an unrelated process, and on the `bash <(...)` /
  # `-c "<script>"` launch a pgrep -f pattern can even match THIS installer or
  # its sudo-keepalive subshell (the script text carries the .ps1 names in argv).
  # Killing such a match could reap this installer's own log `tee` (-> SIGPIPE ->
  # the installer dies; there is no PIPE trap) or its sudo keepalive. Gating on
  # the executable name (comm) -- `pwsh` for every real target, `bash`/`tee`/
  # `sleep`/... for everything we must NOT touch -- closes that. Mirrors the
  # PowerShell side's PID-identity check (Invoke-TestRunner.ps1 stale-pid guard).
  local -a uniq_pids=()
  local seen=" " pcomm
  for pid in "${target_pids[@]:-}"; do
    if [[ -z "$pid" || "$pid" == "$$" ]]; then continue; fi
    case "$seen" in *" $pid "*) continue ;; esac
    seen="$seen$pid "
    kill -0 "$pid" 2>/dev/null || continue   # dead or not ours -- nothing to stop
    # Match the executable name (comm), NOT argv -- the script text contaminates
    # argv with the .ps1 pattern names on the bash <(...) / -c launch. -ww so
    # BSD/macOS ps does not truncate the path (feedback_bsd_ps_args_truncation).
    # Empty comm on a LIVE pid means ps could not report it: keep the pid rather
    # than silently disabling the stop (degrade to the pre-validation behavior).
    pcomm="$(ps -ww -p "$pid" -o comm= 2>/dev/null || ps -p "$pid" -o comm= 2>/dev/null || true)"
    case "$pcomm" in
      ''|*pwsh*|*powershell*|*PowerShell*) uniq_pids+=("$pid") ;;
      *) ;;   # alive and provably NOT a PowerShell process -- stale/recycled, skip
    esac
  done

  if [[ ${#uniq_pids[@]} -eq 0 ]]; then
    log "  no running Yuruna runner / status server found"
    return 0
  fi

  log "  stopping Yuruna services and waiting for exit (pids: ${uniq_pids[*]})"
  kill "${uniq_pids[@]}" 2>/dev/null || true

  # Wait up to 15s for a clean exit, then SIGKILL any straggler.
  local waited alive
  waited=0
  while [[ $waited -lt 15 ]]; do
    alive=0
    for pid in "${uniq_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then alive=1; break; fi
    done
    if [[ $alive -eq 0 ]]; then break; fi
    sleep 1
    waited=$((waited + 1))
  done
  for pid in "${uniq_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
  done

  # Final settle so the caller's checkout rename does not race a dying tree.
  waited=0
  while [[ $waited -lt 5 ]]; do
    alive=0
    for pid in "${uniq_pids[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then alive=1; break; fi
    done
    if [[ $alive -eq 0 ]]; then return 0; fi
    sleep 1
    waited=$((waited + 1))
  done
  warn "  some Yuruna service PIDs did not exit; re-run the installer if the repo update reports the checkout is busy."
}

log "Stopping anything that would block a repo update (runner + status server; VMs preserved)"
stop_yuruna_processes

# --- REGION: Install platform packages
log "Refreshing apt index"
sudo apt-get update -q

case "$ARCH" in
  x86_64)   qemu_default="qemu-system-x86"   ;;
  aarch64)  qemu_default="qemu-system-arm"   ;;
esac
qemu_kvm_pkg="${YURUNA_QEMU_PKG:-$qemu_default}"
log "  qemu pkg : $qemu_kvm_pkg (override with YURUNA_QEMU_PKG=... if needed)"

APT_PACKAGES=(
  "$qemu_kvm_pkg"
  qemu-utils
  libvirt-daemon-system
  libvirt-clients
  virtinst
  osinfo-db
  osinfo-db-tools
  bridge-utils
  dnsmasq-base
  acl
  cifs-utils       # mount.cifs helper for the optional networkStorage pool (ypool-nas) SMB share
  cpu-checker
  swtpm swtpm-tools
  genisoimage
  whois
  cloud-image-utils
  sshpass
  git
  wget curl ca-certificates
  tesseract-ocr
  imagemagick
  virt-viewer
  xwayland
  python3 python3-pip
  jq
  unzip
)
case "$ARCH" in
  x86_64)   APT_PACKAGES+=(ovmf) ;;
  aarch64)  APT_PACKAGES+=(qemu-efi-aarch64) ;;
esac

log "Resolving apt dependencies (dry-run)"
if ! apt_sim_out="$(sudo DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends --simulate \
        "${APT_PACKAGES[@]}" 2>&1)"; then
    printf '%s\n' "$apt_sim_out" >&2
    warn ""
    warn "apt's solver rejected the package set above. Common causes:"
    warn "  * YURUNA_QEMU_PKG points at an -hwe variant that conflicts"
    warn "    with the rest of the virt stack (ubuntu-virt vs ubuntu-virt-hwe)"
    warn "  * universe / multiverse pocket disabled in /etc/apt/sources.list*"
    warn "  * a third-party PPA is pinning an older libvirt -- check"
    warn "    'apt-cache policy libvirt-daemon-system' for the Candidate."
    die "Dependency resolution failed; see solver output above."
fi

log "Installing / upgrading required apt packages"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"

# --- REGION: osinfo-db refresh
osinfo_has_variant() {
  local v="$1"
  local re="${v//./\\.}"
  virt-install --osinfo list 2>/dev/null \
    | grep -qE "(^|[[:space:],])${re}([[:space:],]|$)"
}
osinfo_db_diag() {
  local label="$1"
  log "    [$label] osinfo-db package: $(dpkg-query -W -f='${Version}' osinfo-db 2>/dev/null || echo 'not installed')"
  local count
  count=$(virt-install --osinfo list 2>/dev/null | wc -l)
  log "    [$label] virt-install --osinfo list count: $count lines"
  local ubu
  ubu=$(virt-install --osinfo list 2>/dev/null | grep -iE '^ubuntu' | tr '\n' ' ')
  log "    [$label] ubuntu* short-ids visible: ${ubu:-<none>}"
  for d in /usr/share/osinfo /usr/local/share/osinfo "$HOME/.local/share/osinfo"; do
    log "    [$label] $d exists: $(test -d "$d" && echo yes || echo no); ubuntu-24.04*.xml: $(find "$d" -name 'ubuntu-24.04*.xml' 2>/dev/null | head -3 | tr '\n' ' ')"
  done
}

ensure_osinfo_db_has_ubuntu24() {
  if ! command -v virt-install >/dev/null 2>&1; then
    warn "  virt-install missing -- skipping osinfo-db ubuntu24.04 check."
    return
  fi
  log "Checking osinfo-db for 'ubuntu24.04' variant"
  if osinfo_has_variant 'ubuntu24.04'; then
    log "  ubuntu24.04 already present in osinfo-db (no refresh needed)"
    return
  fi
  log "  ubuntu24.04 missing -- diagnostics before refresh:"
  osinfo_db_diag pre

  if ! command -v osinfo-db-import >/dev/null 2>&1; then
    warn "  osinfo-db-tools not on PATH after apt install -- skipping upstream refresh."
    return
  fi

  log "  attempting upstream refresh from pagure.org"
  local listing latest tmpdir tarball_url
  if ! listing=$(curl -fsSL --max-time 10 'https://releases.pagure.org/libosinfo/' 2>/dev/null); then
    warn "  could not list pagure.org libosinfo releases -- staying on apt-shipped data."
    return
  fi
  latest=$(printf '%s' "$listing" | grep -oE 'osinfo-db-[0-9]+\.tar\.xz' | sort -V | tail -1)
  if [[ -z "$latest" ]]; then
    warn "  pagure.org index parsing returned no tarballs (HTML format change?) -- staying on apt-shipped data."
    return
  fi
  log "  latest upstream tarball: $latest"
  tmpdir=$(mktemp -d)
  tarball_url="https://releases.pagure.org/libosinfo/$latest"
  log "  downloading $tarball_url"
  if ! curl -fsSL --max-time 60 "$tarball_url" -o "$tmpdir/$latest"; then
    warn "  could not download $tarball_url -- staying on apt-shipped data."
    rm -rf "$tmpdir"
    return
  fi

  # Verify the tarball's detached GPG signature against the pinned libosinfo
  # release key before importing it: pagure serves over HTTPS but publishes no
  # checksum, so the .asc is the integrity control. FAIL CLOSED -- a tarball we
  # cannot verify is never imported; the apt-shipped osinfo-db stays in place.
  # Refresh on a signing-key rotation: confirm the new primary fingerprint with
  # `gpg --list-packets <tarball>.asc` and update LIBOSINFO_KEY_FPR.
  local LIBOSINFO_KEY_FPR='4252D86A52041137C291CADFC85C5E957062A701'  # Pavel Hrdina (osinfo-db releases)
  if ! command -v gpg >/dev/null 2>&1; then
    warn "  gpg unavailable -- not importing unverified upstream osinfo-db; staying on apt-shipped data."
    rm -rf "$tmpdir"; return
  fi
  if ! curl -fsSL --max-time 30 "${tarball_url}.asc" -o "$tmpdir/$latest.asc"; then
    warn "  no detached signature for $latest -- not importing unverified data; staying on apt-shipped data."
    rm -rf "$tmpdir"; return
  fi
  local gpghome="$tmpdir/gnupg"
  mkdir -p "$gpghome"; chmod 700 "$gpghome"
  if ! gpg --homedir "$gpghome" --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys "$LIBOSINFO_KEY_FPR" >/dev/null 2>&1; then
    warn "  could not fetch the libosinfo signing key -- not importing unverified data; staying on apt-shipped data."
    rm -rf "$tmpdir"; return
  fi
  local vstatus
  vstatus=$(gpg --homedir "$gpghome" --batch --status-fd 1 --verify "$tmpdir/$latest.asc" "$tmpdir/$latest" 2>/dev/null)
  if printf '%s\n' "$vstatus" | grep -qE '^\[GNUPG:\] BADSIG ' \
     || ! printf '%s\n' "$vstatus" | grep -qE "^\[GNUPG:\] VALIDSIG .*${LIBOSINFO_KEY_FPR}"; then
    warn "  GPG verification FAILED for $latest -- not importing; staying on apt-shipped data."
    rm -rf "$tmpdir"; return
  fi
  log "  GPG signature verified (libosinfo release key $LIBOSINFO_KEY_FPR)"

  log "  importing into /usr/local/share/osinfo (system-local, needs sudo)"
  local imported=0
  if sudo osinfo-db-import --local "$tmpdir/$latest"; then
    log "  imported $latest into /usr/local/share/osinfo"
    imported=1
  else
    warn "  osinfo-db-import --local failed -- trying --user fallback"
    if osinfo-db-import --user "$tmpdir/$latest"; then
      log "  imported $latest into ~/.local/share/osinfo"
      imported=1
    else
      warn "  osinfo-db-import --user also failed -- giving up."
    fi
  fi
  rm -rf "$tmpdir"
  if [[ $imported -eq 0 ]]; then return; fi

  if osinfo_has_variant 'ubuntu24.04'; then
    log "  ubuntu24.04 is now present in osinfo-db"
  else
    warn "  ubuntu24.04 STILL missing after import -- diagnostics after refresh:"
    osinfo_db_diag post
    warn "  The per-guest scripts' linux2022 fallback still works -- this"
    warn "  affects hypervisor tuning only, not bring-up."
  fi
}
ensure_osinfo_db_has_ubuntu24

# --- REGION: PowerShell (apt for x86_64, tarball fallback for aarch64)
install_pwsh_apt() {
  local codename
  codename="$(lsb_release -cs 2>/dev/null || echo noble)"
  log "Adding Microsoft apt repo (codename=$codename)"
  if [[ ! -f /etc/apt/keyrings/microsoft.gpg ]]; then
    sudo install -d -m 0755 /etc/apt/keyrings
    # Fetch to a temp file and pin the fingerprint BEFORE dearmoring into the
    # keyring -- never pipe an unverified key straight into apt's trust store.
    # The 2025 key signs the prod repo for Ubuntu >= 25.10; the preflight
    # requires 26.04+, so the legacy key (whose mismatch against the
    # 2025-signed prod repo causes NO_PUBKEY at apt-get update) never applies.
    local ms_tmp; ms_tmp="$(mktemp -d)"
    curl -fsSL "https://packages.microsoft.com/keys/microsoft-2025.asc" -o "$ms_tmp/microsoft.asc"
    verify_key_fingerprints "$ms_tmp/microsoft.asc" "$MS_APT_KEY_FPR"
    sudo gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg "$ms_tmp/microsoft.asc"
    sudo chmod 0644 /etc/apt/keyrings/microsoft.gpg
    rm -rf "$ms_tmp"
  fi
  if [[ ! -f /etc/apt/sources.list.d/microsoft-prod.list ]]; then
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/$(. /etc/os-release; echo "$VERSION_ID")/prod $codename main" \
      | sudo tee /etc/apt/sources.list.d/microsoft-prod.list >/dev/null
  fi
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y powershell
}

install_pwsh_tarball() {
  # aarch64 has no Microsoft apt package, and x86_64 lands here only when the
  # apt path fails, so this is the fallback PowerShell source for all
  # downstream Yuruna automation. Resolve the latest-stable tag by following
  # the /releases/latest redirect (a HEAD-follow -- no rate-limited
  # api.github.com call) so the tarball tracks the same current release the
  # apt path would install instead of freezing on one line. PowerShell ships
  # both a linux-x64 and a linux-arm64 tarball (plus hashes.sha256) for every
  # GA release, so both arches resolve. PWSH_VERSION overrides the discovery
  # for a pinned or air-gapped build.
  local ver="${PWSH_VERSION:-}"
  if [[ -z "$ver" ]]; then
    local tag
    tag="$(curl -fsSLI --retry 3 --retry-delay 5 --retry-connrefused \
      -o /dev/null -w '%{url_effective}' \
      "https://github.com/PowerShell/PowerShell/releases/latest")"
    tag="${tag##*/}"
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || die "PowerShell latest-version discovery failed (got: '$tag')"
    ver="${tag#v}"
  fi
  local pkg
  case "$ARCH" in
    x86_64)  pkg="powershell-${ver}-linux-x64.tar.gz" ;;
    aarch64) pkg="powershell-${ver}-linux-arm64.tar.gz" ;;
    *)       die "no pwsh tarball for $ARCH" ;;
  esac
  log "Downloading PowerShell $ver tarball ($ARCH)"
  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  curl -fsSL -o "$tmp/$pkg" "https://github.com/PowerShell/PowerShell/releases/download/v${ver}/${pkg}"
  # Verify the tarball against the release's published hashes.sha256 before
  # unpacking it as the interpreter for all downstream Yuruna automation. Pull
  # the single pinned-version line out first (awk index() = literal match):
  # `sha256sum -c` over the whole file fails on the sibling artifacts
  # (arm64/musl/.deb) that are not downloaded.
  curl -fsSL -o "$tmp/hashes.sha256" "https://github.com/PowerShell/PowerShell/releases/download/v${ver}/hashes.sha256" \
    || die "PowerShell $ver: could not fetch hashes.sha256 for verification"
  # The release asset is UTF-16 LE (BOM + CRLF) -- it is generated on Windows.
  # Read raw, awk's index() matches nothing (the NUL interleaved after every
  # ASCII byte hides the filename) and awk warns "Invalid multibyte data", so
  # the exactly-one-line check below fails on an otherwise valid hash file.
  # Normalize to UTF-8/LF first, transcoding only when a UTF-16 BOM is present
  # so a plain-UTF-8 asset keeps working. iconv ships in libc-bin, od/tr in
  # coreutils -- all always installed.
  case "$(od -An -tx1 -N2 "$tmp/hashes.sha256" | tr -d ' \n')" in
    fffe|feff) iconv -f UTF-16 -t UTF-8 "$tmp/hashes.sha256" | tr -d '\r' > "$tmp/hashes.norm" ;;
    *)         tr -d '\r' < "$tmp/hashes.sha256" > "$tmp/hashes.norm" ;;
  esac
  LC_ALL=C awk -v p="$pkg" 'index($0,p){print}' "$tmp/hashes.norm" > "$tmp/pkg.sha256"
  [[ "$(wc -l < "$tmp/pkg.sha256")" -eq 1 ]] \
    || die "PowerShell $ver: expected exactly one checksum line for $pkg in hashes.sha256"
  ( cd "$tmp" && sha256sum -c --quiet pkg.sha256 ) \
    || die "PowerShell $ver: tarball SHA-256 does not match hashes.sha256 (possible tamper)"
  sudo install -d -m 0755 /opt/microsoft/powershell/7
  sudo tar -xzf "$tmp/$pkg" -C /opt/microsoft/powershell/7
  sudo chmod +x /opt/microsoft/powershell/7/pwsh
  sudo ln -sf /opt/microsoft/powershell/7/pwsh /usr/local/bin/pwsh
}

if ! command -v pwsh >/dev/null 2>&1; then
  case "$ARCH" in
    x86_64)  install_pwsh_apt || install_pwsh_tarball ;;
    aarch64) install_pwsh_tarball ;;
  esac
fi
command -v pwsh >/dev/null 2>&1 || die "pwsh not found after install."

# --- REGION: PowerShell modules
log "Installing required PowerShell modules"
pwsh -NoProfile -Command '
    if (Get-Module -ListAvailable -Name powershell-yaml -ErrorAction SilentlyContinue) {
        Write-Output "  powershell-yaml already installed"
    } else {
        Write-Output "  installing powershell-yaml (CurrentUser scope)"
        try {
            Install-Module -Name powershell-yaml -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
        } catch {
            Write-Warning "  Install-Module powershell-yaml failed: $($_.Exception.Message)"
            Write-Warning "  Test-Project.ps1 will refuse to run until this is fixed."
            Write-Warning "  Try manually: pwsh -Command ''Install-Module powershell-yaml -Scope CurrentUser''"
            exit 1
        }
    }
' || warn "powershell-yaml install reported an error -- see above. Continuing install."

# --- REGION: libvirt: enable + groups + ACL + default network
log "Enabling libvirtd + virtlogd"
sudo systemctl enable --now libvirtd
sudo systemctl enable --now virtlogd

NEEDS_RELOG=0
for grp in libvirt kvm; do
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx "$grp"; then
    log "  adding $USER to group $grp"
    sudo usermod -aG "$grp" "$USER"
    NEEDS_RELOG=1
  fi
done

if getent passwd libvirt-qemu >/dev/null 2>&1; then
  if command -v setfacl >/dev/null 2>&1; then
    log "Granting libvirt-qemu traverse on $HOME (POSIX ACL)"
    sudo setfacl -m 'u:libvirt-qemu:--x' "$HOME" || \
      warn "  setfacl failed -- preflight will retry / report"
  else
    warn "  setfacl absent -- 'sudo apt-get install acl' (already a hard apt dep, this should not happen)."
  fi
fi

ensure_default_network() {
  if ! sudo virsh net-info default >/dev/null 2>&1; then
    warn "  libvirt 'default' network missing -- not redefining (rare)."
    return
  fi
  if ! sudo virsh net-list --name | grep -qx default; then
    log "  starting libvirt 'default' network"
    sudo virsh net-start default >/dev/null 2>&1 || true
  fi
  sudo virsh net-autostart default >/dev/null 2>&1 || true
}
ensure_default_network

# --- REGION: Preserve test/status runtime state
TEST_STATUS_SUBDIRS=(runtime perf log extension captures ssh)
preserve_test_status() {
  local src="$YURUNA_DIR/test/status"
  [[ -d "$src" ]] || return 0
  local has_runtime=""
  local sub
  for sub in "${TEST_STATUS_SUBDIRS[@]}"; do
    [[ -d "$src/$sub" ]] || continue
    if find "$src/$sub" -mindepth 1 -not -name '.gitkeep' -print -quit 2>/dev/null | grep -q .; then
      has_runtime=1; break
    fi
  done
  [[ -n "$has_runtime" ]] || return 0
  YURUNA_STATUS_BACKUP=$(mktemp -d) || { warn "  could not create temp dir; skipping test/status preservation"; return 0; }
  log "Preserving test/status runtime state (cycle history, logs, perf, vault, captures, ssh keys)"
  log "  source : $src"
  log "  backup : $YURUNA_STATUS_BACKUP"
  for sub in "${TEST_STATUS_SUBDIRS[@]}"; do
    if [[ -d "$src/$sub" ]]; then
      mkdir -p "$YURUNA_STATUS_BACKUP/$sub"
      cp -a "$src/$sub/." "$YURUNA_STATUS_BACKUP/$sub/" 2>/dev/null || true
    fi
  done
}
restore_test_status() {
  [[ -n "${YURUNA_STATUS_BACKUP:-}" && -d "${YURUNA_STATUS_BACKUP:-}" ]] || return 0
  local dst="$YURUNA_DIR/test/status"
  log "Restoring preserved test/status runtime state"
  local sub
  for sub in "${TEST_STATUS_SUBDIRS[@]}"; do
    if [[ -d "$YURUNA_STATUS_BACKUP/$sub" ]]; then
      mkdir -p "$dst/$sub"
      cp -a "$YURUNA_STATUS_BACKUP/$sub/." "$dst/$sub/" 2>/dev/null || true
    fi
  done
  rm -rf "$YURUNA_STATUS_BACKUP"
  YURUNA_STATUS_BACKUP=""
}

# --- REGION: Tolerate a v / no-v tag mismatch
# Canonical Yuruna release tags are BARE CalVer (YYYY.MM.DD, no 'v'); the
# release tool refuses to create a 'v'-variant. But a human or a tool (or a
# YURUNA_BRANCH=... arg) can ask for the wrong form -- a v-prefixed ref when
# only the bare CalVer tag exists fails to resolve. If the
# requested ref is CalVer-shaped and does NOT resolve on the remote but its
# v-toggled variant DOES, echo the variant so the mismatch self-heals; else
# echo the requested ref unchanged. (warn -> stderr, so it never pollutes the
# captured stdout used to set YURUNA_BRANCH.)
resolve_yuruna_ref() {
  local remote="$1" ref="$2" variant=""
  if [[ -z "$remote" || -z "$ref" ]]; then printf '%s' "$ref"; return 0; fi
  if   [[ "$ref" =~ ^v([0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?)$ ]]; then variant="${BASH_REMATCH[1]}"
  elif [[ "$ref" =~ ^([0-9]{4}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?)$  ]]; then variant="v$ref"
  else printf '%s' "$ref"; return 0; fi
  if GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "$remote" "refs/tags/$ref" "refs/heads/$ref" >/dev/null 2>&1; then
    printf '%s' "$ref"; return 0
  fi
  if GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "$remote" "refs/tags/$variant" "refs/heads/$variant" >/dev/null 2>&1; then
    warn "Requested ref '$ref' not found on $remote; using existing variant '$variant' (canonical Yuruna release tags are bare CalVer, no 'v')."
    printf '%s' "$variant"; return 0
  fi
  # Neither form resolves -- for a CalVer ref the pinned release tag is likely
  # not published yet (the VERSION/installer pin ran ahead of the tag).
  warn "Neither '$ref' nor '$variant' resolves on $remote -- the pinned release tag may not be published yet. To install the latest unreleased code, re-run with YURUNA_BRANCH=main."
  printf '%s' "$ref"
}

# --- REGION: Development repo pulls latest main, not a release tag
# yurunadev is only tagged at the weekly release, so the pinned-CalVer default
# resolves to nothing mid-week. When the target repo is yurunadev and the
# operator did not pin a ref explicitly, track 'main' (latest code) instead.
use_dev_branch_if_needed() {
  local basename="$1"
  if [[ "$basename" == "yurunadev" && "$YURUNA_BRANCH_EXPLICIT" -eq 0 && "$YURUNA_BRANCH" != "main" ]]; then
    log "  yurunadev is a development repo (tagged only at release) -- tracking latest 'main' instead of '$YURUNA_BRANCH'"
    YURUNA_BRANCH="main"
  fi
}

# --- REGION: Clone / update the repo
YURUNA_BACKUP_CREATED=""
preserve_test_status
mkdir -p "$(dirname "$YURUNA_DIR")"
if [[ -d "$YURUNA_DIR/.git" ]]; then
  log "Updating existing Yuruna checkout at $YURUNA_DIR"
  actual_remote="$(git -C "$YURUNA_DIR" remote get-url origin 2>/dev/null || true)"
  remote_normalized="${actual_remote%/}"
  remote_basename="$(basename "${remote_normalized%.git}" 2>/dev/null || true)"
  log "  remote : ${actual_remote:-<none>}"

  skip_pull=0
  if [[ "$remote_basename" == "yurunadev" ]]; then
    if ! GIT_TERMINAL_PROMPT=0 git ls-remote --exit-code "$actual_remote" HEAD >/dev/null 2>&1; then
      warn ""
      warn "============================================================"
      warn "  $actual_remote requires GitHub authentication to pull, and"
      warn "  the current credentials don't grant access (or no credentials"
      warn "  are configured)."
      warn ""
      warn "  Authenticate first, then re-run this installer:"
      warn "    gh auth login     # interactive GitHub CLI sign-in"
      warn "    # OR configure an SSH key with read access to the repo"
      warn ""
      warn "  Continuing this run WITHOUT updating $YURUNA_DIR --"
      warn "  existing on-disk content will be used as-is."
      warn "============================================================"
      warn ""
      skip_pull=1
    fi
  fi

  if [[ $skip_pull -eq 0 ]]; then
    use_dev_branch_if_needed "$remote_basename"
    YURUNA_BRANCH="$(resolve_yuruna_ref "$actual_remote" "$YURUNA_BRANCH")"
    # --force so a remote-moved release tag overwrites the stale local one. A
    # CalVer tag (YYYY.MM.DD) can point at different commits in the public vs
    # development repo, so a plain `fetch --tags` hits "would clobber existing
    # tag", which makes git exit non-zero -- and unguarded under `set -e` that
    # aborts the whole installer before checkout/pull. The guard degrades any
    # remaining fetch error to a warning so the pull --ff-only fallback below
    # still gets to run.
    if ! git -C "$YURUNA_DIR" fetch --tags --force origin; then
      warn "git fetch reported rejected/partial tag updates -- continuing; checkout/pull below will surface anything fatal."
    fi
    # Guard the checkout (not just the pull): under `set -e` an unguarded
    # `git checkout` that fails -- e.g. switching a dirty tree between the
    # moving 'main' branch and a pinned tag, which would overwrite local
    # changes -- aborts the whole installer before the move-aside-and-reclone
    # rescue below can run. Routing a failed checkout into the same rescue
    # keeps a mode flip (PIN_VERSION on/off) robust to a dirty working tree.
    if ! { git -C "$YURUNA_DIR" checkout "$YURUNA_BRANCH" \
           && git -C "$YURUNA_DIR" pull --ff-only origin "$YURUNA_BRANCH"; }; then
      YURUNA_BACKUP_DIR="${YURUNA_DIR}.backup.$(date +%Y-%m-%d.%H-%M)"
      warn "git pull --ff-only failed -- moving the existing checkout aside and re-cloning."
      warn "  from: $YURUNA_DIR"
      warn "  to:   $YURUNA_BACKUP_DIR"
      if ! mv "$YURUNA_DIR" "$YURUNA_BACKUP_DIR"; then
        die "Could not move '$YURUNA_DIR' to '$YURUNA_BACKUP_DIR'. Close any shells / editors / file managers holding the path open and re-run this installer."
      fi
      YURUNA_BACKUP_CREATED="$YURUNA_BACKUP_DIR"
      reclone_remote="${actual_remote:-$YURUNA_REPO}"
      log "Cloning fresh Yuruna into $YURUNA_DIR from $reclone_remote"
      git clone --branch "$YURUNA_BRANCH" "$reclone_remote" "$YURUNA_DIR"
    fi
  fi
else
  clone_basename="$(basename "${YURUNA_REPO%/}" 2>/dev/null || true)"
  clone_basename="${clone_basename%.git}"
  use_dev_branch_if_needed "$clone_basename"
  YURUNA_BRANCH="$(resolve_yuruna_ref "$YURUNA_REPO" "$YURUNA_BRANCH")"
  log "Cloning Yuruna into $YURUNA_DIR from $YURUNA_REPO"
  git clone --branch "$YURUNA_BRANCH" "$YURUNA_REPO" "$YURUNA_DIR"
fi

# --- REGION: Renormalize line endings under .gitattributes
if [[ -d "$YURUNA_DIR/.git" ]]; then
  log "Renormalizing repo line endings (per .gitattributes)"
  git -C "$YURUNA_DIR" config core.autocrlf input

  if ! git -C "$YURUNA_DIR" config --get-all include.path 2>/dev/null \
       | grep -Fxq '../.gitconfig.yuruna'; then
    git -C "$YURUNA_DIR" config --local --add include.path '../.gitconfig.yuruna'
    log "  Enabled pull.rebase via .gitconfig.yuruna include"
  fi

  git -C "$YURUNA_DIR" update-index --refresh >/dev/null 2>&1 || true
  if ! git -C "$YURUNA_DIR" diff-index --quiet HEAD -- 2>/dev/null; then
    warn "  Working tree has uncommitted changes -- only renormalizing the index."
    git -C "$YURUNA_DIR" add --renormalize . || true
    warn "  After resolving local changes, run: git checkout HEAD -- ."
  else
    git -C "$YURUNA_DIR" rm -r --cached --quiet .
    git -C "$YURUNA_DIR" reset --hard HEAD >/dev/null
    log "  Working tree rebuilt under current .gitattributes (LF for *.sh, etc.)"
  fi
fi

# --- REGION: Pin to the current release (opt-in)
# PIN_VERSION / --pin-version: now that 'main' is cloned/updated, read the
# repo's own VERSION file (single source of truth -- top of the repository) and
# detach HEAD at that release tag so the host freezes there and the per-cycle
# `git pull` is a no-op. An explicit YURUNA_BRANCH already chose a ref, so skip.
# If VERSION runs ahead of the published tag, warn and leave the host on 'main'
# rather than fail the install.
if [[ "$PIN_VERSION" != "0" && "$YURUNA_BRANCH_EXPLICIT" -eq 0 && -d "$YURUNA_DIR/.git" ]]; then
  if [[ -f "$YURUNA_DIR/VERSION" ]]; then
    pin_tag="$(tr -d '[:space:]' < "$YURUNA_DIR/VERSION")"
    log "Pinning to release $pin_tag (from VERSION) -- this host will NOT auto-update"
    if ! git -C "$YURUNA_DIR" checkout "$pin_tag"; then
      warn "Could not check out '$pin_tag' (the release tag may not be published yet) -- leaving the host on 'main' (it will auto-update). Re-run with PIN_VERSION=1 after the tag is cut, or set YURUNA_BRANCH=<tag>."
    fi
  else
    warn "No VERSION file in $YURUNA_DIR -- cannot resolve a release to pin; leaving the host on 'main'."
  fi
fi
restore_test_status

# --- REGION: Seed test.config.yml from template
TEST_DIR="$YURUNA_DIR/test"
if [[ ! -f "$TEST_DIR/test.config.yml" && -f "$TEST_DIR/test.config.yml.template" ]]; then
  log "Creating test/test.config.yml from template (review before running tests)"
  cp "$TEST_DIR/test.config.yml.template" "$TEST_DIR/test.config.yml"
fi

# --- REGION: Baseline reset: remove test-* VMs
REMOVE_TEST_VMS="$YURUNA_DIR/test/Remove-TestVMFiles.ps1"
if [[ -f "$REMOVE_TEST_VMS" ]]; then
  log "Removing test-* VMs left over from previous cycles (cache VM preserved)"
  libvirt_members="$(getent group libvirt 2>/dev/null | awk -F: '{print $4}')"
  if command -v sg >/dev/null 2>&1 && \
     [[ ",${libvirt_members}," == *",${USER},"* ]]; then
    sg libvirt -c "pwsh -NoLogo -NoProfile -File '$REMOVE_TEST_VMS'" || \
      warn "Remove-TestVMFiles.ps1 (via sg libvirt) exited non-zero; continuing install."
  else
    pwsh -NoLogo -NoProfile -File "$REMOVE_TEST_VMS" || \
      warn "Remove-TestVMFiles.ps1 exited non-zero; continuing install."
  fi
else
  warn "Remove-TestVMFiles.ps1 not found at $REMOVE_TEST_VMS -- skipping test-VM cleanup."
fi

# --- REGION: Enable-TestAutomation.ps1 hint
HOST_SETUP="$YURUNA_DIR/host/ubuntu.kvm/Enable-TestAutomation.ps1"
log ""
log "Host configuration (test-host setup) is NOT auto-applied."
log "To enable this machine as a test host, run:"
log "    pwsh '$HOST_SETUP'"

# --- REGION: GitHub CLI
install_gh_apt() {
  log "Installing GitHub CLI (gh) via cli.github.com apt repo"
  sudo install -d -m 0755 /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/githubcli-archive-keyring.gpg ]]; then
    # Fetch to a temp file and pin the fingerprints BEFORE installing the
    # keyring as the apt anchor. The keyring ships both the current and the
    # legacy (expiring) GitHub CLI keys during the rotation window; require the
    # current one present and reject any key outside the pinned allow-set.
    local gh_tmp; gh_tmp="$(mktemp -d)"
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$gh_tmp/gh.gpg"
    verify_key_fingerprints "$gh_tmp/gh.gpg" "$GH_APT_KEY_FPR_NEW" "$GH_APT_KEY_FPR_OLD"
    sudo install -m 0644 "$gh_tmp/gh.gpg" /etc/apt/keyrings/githubcli-archive-keyring.gpg
    rm -rf "$gh_tmp"
  fi
  if [[ ! -f /etc/apt/sources.list.d/github-cli.list ]]; then
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  fi
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y gh
}
if ! command -v gh >/dev/null 2>&1; then
  install_gh_apt
fi
command -v gh >/dev/null 2>&1 || die "gh not found after install."

# --- REGION: Final preflight
log "Running final preflight checks"

PREFLIGHT_ERRORS=()
PREFLIGHT_WARNINGS=()

if command -v kvm-ok >/dev/null 2>&1; then
  if ! sudo kvm-ok >/dev/null 2>&1; then
    PREFLIGHT_ERRORS+=("KVM hardware acceleration not available. Run 'sudo kvm-ok' for the diagnostic. Likely cause: VT-x/AMD-V disabled in firmware, or nested virtualization not enabled in the L1 hypervisor.")
  fi
fi

if [[ ! -c /dev/kvm ]]; then
  PREFLIGHT_ERRORS+=("/dev/kvm character device missing -- kvm.ko not loaded. Try: 'sudo modprobe kvm_intel' (Intel) or 'sudo modprobe kvm_amd' (AMD), then re-run.")
fi

for grp in libvirt kvm; do
  group_members="$(getent group "$grp" 2>/dev/null | awk -F: '{print $4}')"
  if [[ ",${group_members}," != *",${USER},"* ]]; then
    PREFLIGHT_ERRORS+=("$USER is not a member of '$grp' in /etc/group -- usermod -aG must have failed earlier. Run: 'sudo usermod -aG $grp $USER' manually.")
  fi
done

for svc in libvirtd virtlogd; do
  if ! systemctl is-active --quiet "$svc"; then
    PREFLIGHT_ERRORS+=("systemd service '$svc' is not active. 'sudo systemctl status $svc' for details.")
  fi
done

if ! getent passwd libvirt-qemu >/dev/null 2>&1; then
  PREFLIGHT_ERRORS+=("System user 'libvirt-qemu' missing -- libvirt-daemon-system postinst did not run. Try 'sudo dpkg-reconfigure libvirt-daemon-system'.")
fi

if ! sudo virsh net-list --name 2>/dev/null | grep -qx default; then
  PREFLIGHT_ERRORS+=("libvirt 'default' network is not running. 'sudo virsh net-start default' to retry.")
fi
if ! sudo virsh net-list --autostart --name 2>/dev/null | grep -qx default; then
  PREFLIGHT_ERRORS+=("libvirt 'default' network is not set to autostart. 'sudo virsh net-autostart default' to fix.")
fi

if getent passwd libvirt-qemu >/dev/null 2>&1; then
  TRAVERSE_PROBE=$(mktemp -p "$HOME" .yuruna-acl-probe.XXXXXX 2>/dev/null || true)
  if [[ -n "$TRAVERSE_PROBE" && -f "$TRAVERSE_PROBE" ]]; then
    chmod 644 "$TRAVERSE_PROBE"
    if ! sudo -u libvirt-qemu test -r "$TRAVERSE_PROBE"; then
      PREFLIGHT_ERRORS+=("libvirt-qemu cannot read '$TRAVERSE_PROBE' through \$HOME -- traverse ACL did not take. Try: 'sudo setfacl -m u:libvirt-qemu:--x $HOME' or fall back to 'chmod o+x $HOME'. Without this, virt-install errors with 'Cannot access storage file ... Permission denied'.")
    fi
    rm -f "$TRAVERSE_PROBE"
  else
    PREFLIGHT_WARNINGS+=("Could not create traverse-ACL probe under $HOME (skipping that check).")
  fi
fi

if ! command -v genisoimage >/dev/null 2>&1 && ! command -v cloud-localds >/dev/null 2>&1; then
  PREFLIGHT_ERRORS+=("Neither 'genisoimage' nor 'cloud-localds' on PATH -- cloud-init seed ISO build will fail.")
fi

if ! command -v pwsh >/dev/null 2>&1; then
  PREFLIGHT_ERRORS+=("pwsh missing from PATH after install.")
fi

if ! command -v virt-install >/dev/null 2>&1; then
  PREFLIGHT_ERRORS+=("'virt-install' not on PATH -- the 'virtinst' apt package did not install.")
fi

if command -v virt-install >/dev/null 2>&1; then
  if ! osinfo_has_variant 'linux2022'; then
    PREFLIGHT_WARNINGS+=("osinfo-db is missing variant 'linux2022' -- per-guest scripts may fail to find any usable variant.")
  fi
  if ! osinfo_has_variant 'ubuntu24.04' && ! osinfo_has_variant 'ubuntu22.04'; then
    PREFLIGHT_WARNINGS+=("osinfo-db has neither 'ubuntu24.04' nor 'ubuntu22.04' -- guest.ubuntu.server.24 New-VM.ps1 will fall back to the 'linux2022' generic profile (still boots, just less hypervisor tuning). Update the osinfo-db package on the host to silence this.")
  fi
fi

case "$ARCH" in
  x86_64)
    [[ -r /usr/share/OVMF/OVMF_CODE.fd || -r /usr/share/OVMF/OVMF_CODE_4M.fd ]] || \
      PREFLIGHT_ERRORS+=("OVMF firmware images missing under /usr/share/OVMF/ -- Windows 11 guest cannot boot UEFI. Verify 'ovmf' apt package installed.")
    ;;
  aarch64)
    [[ -r /usr/share/AAVMF/AAVMF_CODE.fd ]] || \
      PREFLIGHT_ERRORS+=("AAVMF firmware missing under /usr/share/AAVMF/ -- aarch64 guests cannot boot UEFI. Verify 'qemu-efi-aarch64' apt package installed.")
    ;;
esac

for bin in swtpm swtpm_setup; do
  command -v "$bin" >/dev/null 2>&1 || \
    PREFLIGHT_ERRORS+=("'$bin' missing -- Windows 11 guest cannot satisfy TPM 2.0 requirement. Verify 'swtpm' / 'swtpm-tools' apt packages installed.")
done

if ! command -v gh >/dev/null 2>&1; then
  PREFLIGHT_ERRORS+=("'gh' missing from PATH after install -- check 'apt-cache policy gh' for the cli.github.com source, then re-run.")
fi

if (( ${#PREFLIGHT_WARNINGS[@]} > 0 )); then
  printf '\n'
  for w in "${PREFLIGHT_WARNINGS[@]}"; do warn "$w"; done
fi

if (( ${#PREFLIGHT_ERRORS[@]} > 0 )); then
  printf '\n'
  printf '\033[1;31mXX \033[0m %s\n' "Yuruna preflight failed -- ${#PREFLIGHT_ERRORS[@]} requirement(s) not met:" >&2
  for e in "${PREFLIGHT_ERRORS[@]}"; do
    printf '   - %s\n' "$e" >&2
  done
  printf '\n' >&2
  printf 'Resolve the items above and re-run this installer. The host is NOT\n' >&2
  printf 'ready for Invoke-TestRunner.ps1.\n' >&2
  exit 2
fi

# --- REGION: Done summary
NEEDS_RELOG_HINT=0
ACTIVE_GROUPS=$(id -Gn 2>/dev/null | tr ' ' '\n')
for grp in libvirt kvm; do
  group_members="$(getent group "$grp" 2>/dev/null | awk -F: '{print $4}')"
  if [[ ",${group_members}," == *",${USER},"* ]] && \
     ! echo "$ACTIVE_GROUPS" | grep -qx "$grp"; then
    NEEDS_RELOG_HINT=1
  fi
done

cat <<EOF

$(log "Yuruna is ready -- all preflight checks passed.")

Next steps (in order):
EOF
if (( NEEDS_RELOG_HINT == 1 )); then
  cat <<EOF

  0. THIS shell pre-dates the libvirt/kvm group membership added during
     install -- refresh it before running pwsh:
       Option A (recommended): log out and log back in
       Option B (one-off):     newgrp libvirt && newgrp kvm
     (The install itself is complete. This step only affects YOUR next
     interactive pwsh call.)
EOF
fi
cat <<EOF

  1. Review and edit the test config:
       \$EDITOR $TEST_DIR/test.config.yml

  2. (Optional) Enable this machine as a test host -- disables display sleep
     and tunes the libvirt image pool path. NOT run automatically; opt in
     only if this Ubuntu host will run Invoke-TestRunner:
       pwsh $YURUNA_DIR/host/ubuntu.kvm/Enable-TestAutomation.ps1

  3. Run the test runner:
       cd $TEST_DIR && pwsh ./Invoke-TestRunner.ps1

  4. (Optional, one-time) Authenticate the GitHub CLI so 'gh' can act on
     your behalf -- the installer installs the binary, but authentication
     requires an interactive web-or-token flow you have to drive:
       gh auth login

Re-running this installer is safe; it will refresh apt packages and
fast-forward the Yuruna checkout when possible.
EOF

# --- REGION: Backup notice
if [[ -n "$YURUNA_BACKUP_CREATED" ]]; then
  warn ""
  warn "============================================================"
  warn "IMPORTANT: a backup of your previous Yuruna checkout was created"
  warn "  because 'git pull --ff-only' could not advance the local repo."
  warn ""
  warn "  Backup location: $YURUNA_BACKUP_CREATED"
  warn ""
  warn "Review the backup for any local edits you want to preserve."
  warn "When you no longer need it, delete it manually:"
  warn "  rm -rf '$YURUNA_BACKUP_CREATED'"
  warn "============================================================"
fi
