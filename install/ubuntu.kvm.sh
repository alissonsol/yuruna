#!/bin/bash
# Version: 2026.05.22
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Yuruna Ubuntu host (KVM/libvirt) bootstrap installer.
#
# One-liner:
#   bash <(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh)
#
# Leaves the machine ready to edit test/test.config.yml and run
# ./test/Invoke-TestRunner.ps1. Idempotent -- safe to re-run.
#
# Supported target: Ubuntu 26.04 LTS (Resolute) or newer, on x86_64 or aarch64.
# Older Ubuntu releases (24.04, 22.04) are rejected at preflight -- the qemu
# package layout, virt-install --osinfo set, and libvirt versions on those
# releases all differ enough that maintaining compatibility was no longer worth
# the duplicated test surface.

set -euo pipefail

# This installer ships in TWO repos that share the same install script:
#   * public   https://github.com/alissonsol/yuruna       (clone works unauthenticated)
#   * private  https://github.com/alissonsol/yurunadev    (clone needs GitHub auth)
# The copy committed to each repo points YURUNA_REPO at its OWN URL so the
# curl|bash one-liner clones the repo the operator chose to download the
# script from. Both constants stay defined regardless of which copy is
# running so the existing-checkout logic further down can recognize the
# remote a previous run cloned from -- and skip a pull that would just
# stall waiting for GitHub credentials this run doesn't have.
YURUNA_REPO_PUBLIC="https://github.com/alissonsol/yuruna.git"
YURUNA_REPO_PRIVATE="https://github.com/alissonsol/yurunadev.git"
YURUNA_REPO="${YURUNA_REPO:-$YURUNA_REPO_PUBLIC}"
YURUNA_BRANCH="${YURUNA_BRANCH:-main}"
YURUNA_DIR="${YURUNA_DIR:-$HOME/git/yuruna}"

# `log()` records the current phase in $_yuruna_step so the ERR trap below
# can name the human-readable step the script was in when it failed.
_yuruna_step="<starting up>"
log()  { _yuruna_step="$*"; printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX \033[0m %s\n' "$*" >&2; exit 1; }

# -- Failure-trap: surface WHERE and WHY any unhandled non-zero exits ---------
# Under `set -euo pipefail` the shell quits silently on the first non-zero
# command. A previous run silently aborted right after "Refreshing apt index"
# with no message -- the apt-get update or the apt-cache probe failed and the
# operator had no way to see why. ERR fires before exit; print the location
# (line + command) and the captured exit status so the next failure is
# actionable. BASH_COMMAND holds the command text that triggered the trap;
# BASH_LINENO[0] holds its line number in this file.
_yuruna_on_err() {
    local rc=$?
    printf '\n\033[1;31mXX \033[0m installer aborted (exit %d)\n' "$rc" >&2
    printf '   step    : %s\n' "$_yuruna_step" >&2
    printf '   line    : %s\n' "${BASH_LINENO[0]:-?}" >&2
    printf '   command : %s\n' "${BASH_COMMAND:-?}" >&2
    printf '\n   Re-run with `bash -x <script>` to trace every command,\n' >&2
    printf   '   or `sudo apt-get update` directly to see apt errors verbatim.\n' >&2
    exit "$rc"
}
trap _yuruna_on_err ERR

# -- Preflight (hard) --------------------------------------------------------
# Only the truly unrecoverable conditions abort here. Distro / version /
# architecture / RAM / cores / disk are checked in
# preflight_system_requirements below and produce a warn+confirm gate so an
# operator can knowingly proceed off the tested baseline.
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

# -- System requirements: warn + confirm if below the tested baseline ------
# Tested baseline: 32 GB RAM, 512 GB free, Ubuntu 26+ on amd64, 16+ cores.
# Older Ubuntu releases ship a different qemu package layout and an older
# virt-install that doesn't know the newest --osinfo entries; aarch64
# builds work in places but isn't the tested baseline. Anything below is
# permitted but UNTESTED -- prompt the operator before continuing so an
# under-spec'd host doesn't burn an hour of apt installs only to fail in
# the first test cycle.
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
  mem_gb=$(( ${mem_kb:-0} / 1024 / 1024 ))
  if (( mem_gb < 32 )); then
    issues+=("${mem_gb}GB RAM detected (need 32GB+)")
  fi
  disk_kb=$(df -k / 2>/dev/null | awk 'NR==2 {print $4}')
  disk_gb=$(( ${disk_kb:-0} / 1024 / 1024 ))
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

# -- sudo announcement (consistent with the macOS / Windows installers) ------
# Every script in this repo that needs elevation says so up front. Match that
# convention here and prime sudo a single time so apt + usermod + systemctl
# all reuse the same timestamp and the operator is prompted exactly once.
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
# `|| true` is load-bearing: under `set -e` (top of file), a transient
# `sudo -n true` failure -- e.g. brief timestamp-lock contention while
# apt's own sudo runs internally -- would otherwise kill this subshell
# and the cache would expire mid-install.
( while true; do sudo -n true 2>/dev/null || true; sleep 30; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!

# Single EXIT cleanup so the sudo keepalive AND the test/status backup
# (set up further down) both get released on every exit path -- normal
# completion, Ctrl-C, set -e abort.
YURUNA_STATUS_BACKUP=""
yuruna_install_cleanup() {
  kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  if [[ -n "${YURUNA_STATUS_BACKUP:-}" && -d "${YURUNA_STATUS_BACKUP:-}" ]]; then
    rm -rf "$YURUNA_STATUS_BACKUP" 2>/dev/null || true
  fi
}
trap yuruna_install_cleanup EXIT

# -- Virtualization-extension probe (HARD requirement) ----------------------
# `kvm-ok` lives in cpu-checker (apt) and is the canonical Ubuntu probe.
# It is not yet installed at this point of bootstrap -- fall back to
# /proc/cpuinfo. The full kvm-ok / /dev/kvm assertion runs in the final
# preflight after libvirt is installed; this early check just refuses to
# burn time on apt/repo work when the host obviously can't host VMs.
HAVE_VMX=0
if grep -qE '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
  HAVE_VMX=1
elif [[ "$ARCH" == "aarch64" ]]; then
  # ARM64 hosts don't expose vmx/svm. /dev/kvm appears once kvm.ko loads.
  HAVE_VMX=1
fi
if [[ $HAVE_VMX -eq 0 ]]; then
  die "CPU virtualization extensions (vmx/svm) not detected in /proc/cpuinfo.
       Either virtualization is disabled in firmware (enable Intel VT-x or
       AMD-V in BIOS/UEFI) or this is a guest VM without nested
       virtualization. Without KVM acceleration the test harness is
       unusable -- aborting before installing anything."
fi

# -- Stop any running yuruna processes so the repo can be updated cleanly ----
stop_yuruna_processes() {
  # Kill any running Invoke-TestRunner (outer), Invoke-TestInnerRunner
  # (per-cycle inner under modules/), Test-Sequence (dev helper), or
  # Start-StatusServer under the current user.
  local patterns=(
    "Invoke-TestRunner.ps1"
    "Invoke-TestInnerRunner.ps1"
    "Test-Sequence.ps1"
    "Start-StatusServer.ps1"
  )
  for pat in "${patterns[@]}"; do
    local pids
    pids=$(pgrep -f "$pat" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
      log "  stopping $pat (pids: $pids)"
      # shellcheck disable=SC2086
      kill $pids 2>/dev/null || true
      sleep 1
      # shellcheck disable=SC2086
      kill -9 $pids 2>/dev/null || true
    fi
  done
  if command -v ss >/dev/null 2>&1; then
    if ss -ltn '( sport = :8080 )' 2>/dev/null | grep -q ':8080'; then
      warn "  port 8080 still bound -- a status server may be hiding under another shell."
    fi
  fi
}

log "Stopping anything that would block a repo update"
stop_yuruna_processes

# -- apt: install / upgrade required packages --------------------------------
# Architecture-specific UEFI firmware:
#   x86_64  -> ovmf (OVMF + OVMF_VARS for q35-uefi guests like Windows 11)
#   aarch64 -> qemu-efi-aarch64 (AAVMF -- ARM equivalent)
# swtpm provides the TPM 2.0 emulator Windows 11 install requires.

# Refresh the apt index BEFORE probing for the qemu-system-<arch>-hwe
# package below; on a fresh image the apt cache may not yet know the
# -hwe variant exists, and the probe would fall back to the base
# package even though the HWE one is available.
#
# Use `-q` (one quiet) rather than `-qq` so apt warnings and connectivity
# errors are still visible. With `-qq`, a hung mirror or a signature
# verification failure aborted the script with zero output, which made
# the silent exit "just after Refreshing apt index" impossible to
# diagnose without re-running with -x.
log "Refreshing apt index"
sudo apt-get update -q

# `qemu-kvm` is a VIRTUAL package starting with Ubuntu 26.04 (resolute):
#   apt refuses to pick between qemu-system-<arch> and qemu-system-<arch>-hwe
#   automatically. Default to the GA (non-HWE) variant -- it pulls in
#   `ubuntu-virt`, which is the SAME umbrella the rest of our packages
#   (libvirt-daemon-system, libvirt-clients, ovmf, qemu-utils, virtinst)
#   depend on. The `-hwe` variant depends on `ubuntu-virt-hwe`, which
#   *Conflicts* with `ubuntu-virt`, so any attempt to use `-hwe` while
#   keeping the rest of the stack on the GA branch produces an apt
#   "two conflicting assignments" error. On 26.04 there is no parallel
#   HWE set for libvirt/ovmf, so -hwe is effectively unusable; the
#   version delta from the base package is also a single ubuntu build
#   (e.g. -ubuntu4 vs -ubuntu3 of the same upstream qemu point release).
# Operator override: set YURUNA_QEMU_PKG=qemu-system-x86-hwe to try -hwe
# anyway (e.g. once a future LTS ships matching -hwe libvirt/ovmf).
case "$ARCH" in
  x86_64)   qemu_default="qemu-system-x86"   ;;
  aarch64)  qemu_default="qemu-system-arm"   ;;
esac
qemu_kvm_pkg="${YURUNA_QEMU_PKG:-$qemu_default}"
log "  qemu pkg : $qemu_kvm_pkg (override with YURUNA_QEMU_PKG=... if needed)"

APT_PACKAGES=(
  "$qemu_kvm_pkg"             # qemu-system-<arch>[-hwe] -- replaces the qemu-kvm virtual package
  qemu-utils                  # qemu-img: image conversion + sparse-clear
  libvirt-daemon-system
  libvirt-clients
  virtinst                    # virt-install (Debian/Ubuntu package name)
  osinfo-db                   # OS metadata libvirt/virt-install consume via libosinfo (the data files)
  osinfo-db-tools             # osinfo-db-import: refresh osinfo-db from upstream when apt is too old
  bridge-utils
  dnsmasq-base                # libvirt's default network uses this internally
  acl                         # setfacl: grant libvirt-qemu traverse on $HOME (24.04 0750-mode home)
  cpu-checker                 # kvm-ok
  swtpm swtpm-tools           # TPM emulation (Windows 11 prereq)
  genisoimage                 # cloud-init seed ISO + autounattend ISO build
  whois                       # mkpasswd -- generate hashed passwords for cloud-init identity
  cloud-image-utils           # cloud-localds (alternate seed builder)
  sshpass                     # password-auth fallback for Test.Diagnostic' post-failure SSH path (Invoke-RemoteDiagnosticsPasswordSsh)
  git
  wget curl ca-certificates
  tesseract-ocr               # OCR engine for the test harness
  imagemagick                 # `convert` -- PPM (virsh screenshot output) to PNG for OCR
  virt-viewer                 # remote-viewer -- console window so the operator can see VM screens
  xwayland                    # required when virt-viewer is launched with GDK_BACKEND=x11 on Wayland sessions (avoids the xdg-desktop-portal "Allow inhibiting shortcuts" dialog -- see Restart-VMConsole in modules/Yuruna.Host.psm1)
  python3 python3-pip
  jq
  unzip
)
case "$ARCH" in
  x86_64)   APT_PACKAGES+=(ovmf) ;;
  aarch64)  APT_PACKAGES+=(qemu-efi-aarch64) ;;
esac

log "Resolving apt dependencies (dry-run)"
# Run apt's solver in simulate mode FIRST. If a dependency conflict
# exists -- e.g. -hwe qemu pulling `ubuntu-virt-hwe` against the rest
# of the stack's `ubuntu-virt` -- it surfaces here BEFORE we start
# actually installing anything, with the same "X depends Y but it is
# not going to be installed" diagnostic the real install would emit.
# `set -e` + the ERR trap means a non-zero apt-get exit will print
# the abort block naming this step.
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
# --no-install-recommends keeps the host lean; libvirtd already pulls every
# hard dep we need, and Recommends pulls in lots of GUI bits on a server box.
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"

# -- osinfo-db: refresh from upstream if the apt-shipped data is too old ----
# Noble's apt-shipped osinfo-db can predate Ubuntu 24.04's release, so
# `virt-install --osinfo list` may not include 'ubuntu24.04' even after
# the osinfo-db package above is installed. Per-guest scripts already
# fall back to 'linux2022' when the precise variant is missing, but
# the operator's better off with proper hypervisor tuning.
#
# Best-effort upstream refresh: scrape pagure.org's release index for
# the latest osinfo-db-YYYYMMDD.tar.xz, fetch it, and import system-wide
# (--local writes to /usr/local/share/osinfo, which libosinfo searches
# unconditionally on Ubuntu). Any failure (no network, pagure.org down,
# malformed tarball) emits a warn line and proceeds -- the per-guest
# scripts' linux2022 fallback already covers that case.
#
# Variant lookup: virt-install --osinfo list does NOT emit one short-id
# per line. Each line is `<canonical-id>, <alias1> <alias2>` -- so a
# naive `grep -qx 'ubuntu24.04'` never matches because the line is
# actually `ubuntu24.04, ubuntunoble`. osinfo_has_variant strips the
# alias tail (first whitespace-or-comma-separated token, trailing comma
# removed) before exact-matching, which is what we actually want.

osinfo_has_variant() {
  local v="$1"
  # Match $v as a whole token: preceded by start-of-line, whitespace, or
  # comma; followed by end-of-line, whitespace, or comma. Dots in $v
  # are escaped so 'ubuntu24.04' doesn't accidentally match a hypothetical
  # 'ubuntu24x04'. Robust against every line-format variant we've seen
  # from `virt-install --osinfo list`: bare canonical id, canonical
  # plus space-separated aliases, canonical plus comma-separated aliases,
  # mixed.
  local re="${v//./\\.}"
  virt-install --osinfo list 2>/dev/null \
    | grep -qE "(^|[[:space:],])${re}([[:space:],]|$)"
}
# Diagnostic helper -- shows enough about libosinfo's view of the world
# that the operator can tell whether we're dealing with stale data, a
# short-id mismatch (libosinfo renamed the variant), or a path-search
# issue (libosinfo isn't seeing the data we just dropped on disk).
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

  # `--local` writes to /usr/local/share/osinfo/, which libosinfo searches
  # unconditionally on Ubuntu. Falls back to `--user` (~/.local/share/
  # osinfo) only if the local import fails -- some libosinfo builds don't
  # honor XDG_DATA_HOME, so --local is the more reliable target.
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

# -- PowerShell: not in the default Ubuntu archive --------------------------
# Microsoft's apt repo is the canonical source; on aarch64 there's no apt
# package, so fall through to the tarball under /opt and a /usr/local/bin
# wrapper. Both paths leave `pwsh` on PATH for subsequent steps.
install_pwsh_apt() {
  local codename
  codename="$(lsb_release -cs 2>/dev/null || echo noble)"
  log "Adding Microsoft apt repo (codename=$codename)"
  if [[ ! -f /etc/apt/keyrings/microsoft.gpg ]]; then
    sudo install -d -m 0755 /etc/apt/keyrings
    curl -fsSL "https://packages.microsoft.com/keys/microsoft.asc" \
      | sudo gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg
    sudo chmod 0644 /etc/apt/keyrings/microsoft.gpg
  fi
  if [[ ! -f /etc/apt/sources.list.d/microsoft-prod.list ]]; then
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/$(. /etc/os-release; echo "$VERSION_ID")/prod $codename main" \
      | sudo tee /etc/apt/sources.list.d/microsoft-prod.list >/dev/null
  fi
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y powershell
}

install_pwsh_tarball() {
  # Pinning to a known LTS line; the 7.4.x stream maintains aarch64 builds.
  local ver="${PWSH_VERSION:-7.4.6}"
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

# -- libvirt: enable + add user to groups -----------------------------------
# 'libvirt' grants /var/run/libvirt/libvirt-sock access (no password); 'kvm'
# grants /dev/kvm. Both are required for non-root virsh / virt-install.
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

# -- libvirt-qemu traverse ACL on $HOME -------------------------------------
# Ubuntu 24.04 cloud images create /home/<user> at mode 0750, which blocks
# the libvirt-qemu user (uid 64055, gid kvm) that runs guest qemu processes
# from traversing $HOME to reach VM disk files. virt-install then errors
# out with "Cannot access storage file ... Permission denied". Apply the
# traverse-only POSIX ACL up front so the operator does not discover this
# the first time New-VM.ps1 runs. Idempotent; the final preflight verifies
# libvirt-qemu can actually reach files under $HOME.
if getent passwd libvirt-qemu >/dev/null 2>&1; then
  if command -v setfacl >/dev/null 2>&1; then
    log "Granting libvirt-qemu traverse on $HOME (POSIX ACL)"
    sudo setfacl -m 'u:libvirt-qemu:--x' "$HOME" || \
      warn "  setfacl failed -- preflight will retry / report"
  else
    warn "  setfacl absent -- 'sudo apt-get install acl' (already a hard apt dep, this should not happen)."
  fi
fi

# Default network ('default', 192.168.122.0/24 NAT) is shipped by
# libvirt-daemon-system but starts disabled. Make sure it's autostart + up
# so virt-install can attach guests without a manual `virsh net-start`.
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

# -- Preserve test/status runtime state across the clone/update --------------
# Re-running the installer on a host that's been executing test cycles must
# not lose the dashboard's history, per-cycle log transcripts, or the
# runtime-dir state (status.json with history[], runner.gating.json,
# runner.pid, control flags). None of those are tracked by git -- per
# .gitignore every subdir under test/status/ is gitignored as runtime
# state. The clone/update/renormalize block below is designed to leave
# untracked files alone (`git rm -r --cached . && git reset --hard HEAD`
# only touches tracked files), but we backstop that contract with an
# explicit snapshot-and-restore so a future regression in the renormalize
# logic, or a manual `rm -rf YURUNA_DIR` between attempts, can't silently
# wipe weeks of cycle history.
#
# All harness runtime state lives under test/status/<sub>/ for the layout
# introduced in the status reorg: runtime/, perf/, log/, extension/,
# captures/, ssh/. Preserve every subdir so cycle history, perf JSONL,
# vault state, training/sequence captures, and the generated SSH key pair
# all survive a clone/update.
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

# -- Clone / update the repo ------------------------------------------------
# YURUNA_BACKUP_CREATED is set when 'git pull --ff-only' could not advance
# the local repo and we had to move it aside. The final-summary block at
# the end of the installer reads this var and surfaces the backup path
# loudly so the operator can salvage local edits before deleting it.
YURUNA_BACKUP_CREATED=""
preserve_test_status
mkdir -p "$(dirname "$YURUNA_DIR")"
if [[ -d "$YURUNA_DIR/.git" ]]; then
  log "Updating existing Yuruna checkout at $YURUNA_DIR"
  # Pull from whatever remote the LOCAL repo was cloned from -- not from
  # whichever YURUNA_REPO default this copy of the installer ships. A
  # previous run may have cloned the OTHER repo (the public 'yuruna'
  # checkout works for everyone; the private 'yurunadev' checkout needs
  # GitHub auth) and we must not silently migrate the operator's local
  # tree to a different remote.
  actual_remote="$(git -C "$YURUNA_DIR" remote get-url origin 2>/dev/null || true)"
  remote_normalized="${actual_remote%/}"
  remote_basename="$(basename "${remote_normalized%.git}" 2>/dev/null || true)"
  log "  remote : ${actual_remote:-<none>}"

  skip_pull=0
  if [[ "$remote_basename" == "yurunadev" ]]; then
    # Private remote: require demonstrated access before we attempt
    # `git fetch`. `ls-remote` fails fast on 401/403, sparing the
    # operator a stalled credential prompt or an error transcript
    # that looks like the test harness broke when really only auth
    # was missing. The pull is skipped (not the rest of the install)
    # so a contributor on a flaky/unauthenticated session can still
    # keep iterating with the last-known-good code on disk.
    # GIT_TERMINAL_PROMPT=0: fail fast on missing credentials instead of
    # blocking the installer on an interactive `Username:` prompt.
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
    git -C "$YURUNA_DIR" fetch --tags origin
    git -C "$YURUNA_DIR" checkout "$YURUNA_BRANCH"
    if ! git -C "$YURUNA_DIR" pull --ff-only origin "$YURUNA_BRANCH"; then
      # Fast-forward not possible: uncommitted changes, divergent commits,
      # detached HEAD, file-mode quirks across mount points, or just a
      # working tree that diverged identically-but-not-as-a-ff (e.g. a
      # local revert that happens to match HEAD content-wise but adds
      # commits the remote doesn't have). Rather than leaving the
      # installer in a half-updated state, move the existing checkout
      # aside as a timestamped backup and re-clone fresh. The
      # test/status runtime state was already captured to TEMP by
      # preserve_test_status above, so cycle history survives this path.
      YURUNA_BACKUP_DIR="${YURUNA_DIR}.backup.$(date +%Y-%m-%d.%H-%M)"
      warn "git pull --ff-only failed -- moving the existing checkout aside and re-cloning."
      warn "  from: $YURUNA_DIR"
      warn "  to:   $YURUNA_BACKUP_DIR"
      if ! mv "$YURUNA_DIR" "$YURUNA_BACKUP_DIR"; then
        die "Could not move '$YURUNA_DIR' to '$YURUNA_BACKUP_DIR'. Close any shells / editors / file managers holding the path open and re-run this installer."
      fi
      YURUNA_BACKUP_CREATED="$YURUNA_BACKUP_DIR"
      # Re-clone from whatever remote the local repo had, falling back
      # to the per-copy YURUNA_REPO default only if the original remote
      # could not be read for some reason.
      reclone_remote="${actual_remote:-$YURUNA_REPO}"
      log "Cloning fresh Yuruna into $YURUNA_DIR from $reclone_remote"
      git clone --branch "$YURUNA_BRANCH" "$reclone_remote" "$YURUNA_DIR"
    fi
  fi
else
  log "Cloning Yuruna into $YURUNA_DIR from $YURUNA_REPO"
  git clone --branch "$YURUNA_BRANCH" "$YURUNA_REPO" "$YURUNA_DIR"
fi

# -- Renormalize line endings under .gitattributes --------------------------
# Same rationale as install/macos.utm.sh -- a Windows + Linux pair sharing the
# repo can let CRLF sneak into *.sh / user-data / meta-data on the working
# tree, and the host status server then serves CRLF bytes byte-faithfully to
# Linux guests, where bash chokes with $'\r' on line 2 of fetch-and-execute.sh.
if [[ -d "$YURUNA_DIR/.git" ]]; then
  log "Renormalizing repo line endings (per .gitattributes)"
  git -C "$YURUNA_DIR" config core.autocrlf input

  # Pull in .gitconfig.yuruna (tracked in the repo root) for pull.rebase
  # + rebase.autoStash defaults so `git pull` here rebases instead of
  # creating merge commits. include.path can hold multiple values, so
  # add idempotently rather than overwriting whatever else the operator
  # may have included.
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
restore_test_status

# -- Seed test.config.yml from template if missing --------------------------
TEST_DIR="$YURUNA_DIR/test"
if [[ ! -f "$TEST_DIR/test.config.yml" && -f "$TEST_DIR/test.config.yml.template" ]]; then
  log "Creating test/test.config.yml from template (review before running tests)"
  cp "$TEST_DIR/test.config.yml.template" "$TEST_DIR/test.config.yml"
fi

# -- Baseline reset: remove every `test-*` VM left over from prior cycles ---
# An install is a "return-to-baseline" operation. Status server + runner
# processes are killed earlier (stop_yuruna_processes); their VMs are not.
# Remove-TestVMFiles.ps1 enumerates libvirt domains matching the `test-`
# prefix and destroys + undefines each. The yuruna-caching-proxy VM does
# NOT match this prefix and is preserved. Failure here is non-fatal -- a
# wedged virsh or locked qcow2 on one VM must not block the rest of the
# install. Run AFTER the repo update so we use the just-pulled version
# of the script and its host driver modules.
#
# Group activation: `usermod -aG libvirt $USER` above adds the user to
# /etc/group, but the CURRENT shell's effective group set was sampled at
# login and won't include libvirt until a re-login or `newgrp`. Calling
# pwsh directly here inherits the parent's stale group set, so virsh
# fails with "Permission denied" on /var/run/libvirt/libvirt-sock the
# very first time after group add. `sg libvirt -c '<cmd>'` runs a
# subshell with libvirt as an effective supplementary group, which
# works the instant /etc/group has the membership -- no re-login
# required. Idempotent: on re-runs where the user already has libvirt
# in their active group set, `sg` is a no-op shim.
REMOVE_TEST_VMS="$YURUNA_DIR/test/Remove-TestVMFiles.ps1"
if [[ -f "$REMOVE_TEST_VMS" ]]; then
  log "Removing test-* VMs left over from previous cycles (cache VM preserved)"
  # `getent group libvirt` reads /etc/group, which `usermod -aG` above
  # has just updated -- so this check is true the instant we add the
  # user, BEFORE the parent shell re-samples its group set. Don't use
  # `id -nG` here: it reflects the (stale) live group set of THIS shell
  # and would force us down the direct-pwsh fallback the first run.
  libvirt_members="$(getent group libvirt 2>/dev/null | awk -F: '{print $4}')"
  if command -v sg >/dev/null 2>&1 && \
     [[ ",${libvirt_members}," == *",${USER},"* ]]; then
    sg libvirt -c "pwsh -NoLogo -NoProfile -File '$REMOVE_TEST_VMS'" || \
      warn "Remove-TestVMFiles.ps1 (via sg libvirt) exited non-zero; continuing install."
  else
    # No libvirt membership yet (e.g. system without that group); fall
    # back to a direct call so a fresh install on an unusual system
    # still tries the cleanup. virsh's own error is then visible.
    pwsh -NoLogo -NoProfile -File "$REMOVE_TEST_VMS" || \
      warn "Remove-TestVMFiles.ps1 exited non-zero; continuing install."
  fi
else
  warn "Remove-TestVMFiles.ps1 not found at $REMOVE_TEST_VMS -- skipping test-VM cleanup."
fi

# -- Host configuration: disable display sleep, etc. ------------------------
# Enable-TestAutomation.ps1 is NOT run automatically. It is the explicit
# opt-in step that turns this Ubuntu host into a Yuruna test host (display
# sleep / screensaver off, VM image storage pool path tuning) and is
# therefore left for the operator to invoke manually after install.
HOST_SETUP="$YURUNA_DIR/host/ubuntu.kvm/Enable-TestAutomation.ps1"
log ""
log "Host configuration (test-host setup) is NOT auto-applied."
log "To enable this machine as a test host, run:"
log "    pwsh '$HOST_SETUP'"

# -- GitHub CLI (gh) --------------------------------------------------------
# Not pinned to a current version in Ubuntu's default archive; follow
# cli.github.com's recommended apt-repo install. Mirrors the Microsoft
# pwsh path above: keyring under /etc/apt/keyrings, repo source under
# /etc/apt/sources.list.d, then apt-get install. Idempotent on re-runs --
# an existing keyring or source-list file triggers a no-op.
install_gh_apt() {
  log "Installing GitHub CLI (gh) via cli.github.com apt repo"
  sudo install -d -m 0755 /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/githubcli-archive-keyring.gpg ]]; then
    # The key at cli.github.com is already binary GPG (not armored), so
    # save it verbatim. `dd status=none` keeps the transcript clean; the
    # explicit chmod is belt-and-suspenders in case the umask drops bits.
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | sudo dd of=/etc/apt/keyrings/githubcli-archive-keyring.gpg status=none
    sudo chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
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

# -- Final preflight: assert every requirement is met -----------------------
# Up to here we APPLIED configuration. Below we VERIFY the host actually
# reached the state Invoke-TestRunner.ps1 needs. Every check is a hard
# requirement; the script collects all failures so the operator sees the
# full punch list at once instead of fix-and-rerun N times. A partial
# install is worse than no install -- subsequent runs see "looks
# configured" and skip steps that would have re-applied them.
log "Running final preflight checks"

PREFLIGHT_ERRORS=()
PREFLIGHT_WARNINGS=()

# 1. Hardware virtualization (full kvm-ok now that cpu-checker is installed).
if command -v kvm-ok >/dev/null 2>&1; then
  if ! sudo kvm-ok >/dev/null 2>&1; then
    PREFLIGHT_ERRORS+=("KVM hardware acceleration not available. Run 'sudo kvm-ok' for the diagnostic. Likely cause: VT-x/AMD-V disabled in firmware, or nested virtualization not enabled in the L1 hypervisor.")
  fi
fi

# 2. /dev/kvm must exist as a character device.
if [[ ! -c /dev/kvm ]]; then
  PREFLIGHT_ERRORS+=("/dev/kvm character device missing -- kvm.ko not loaded. Try: 'sudo modprobe kvm_intel' (Intel) or 'sudo modprobe kvm_amd' (AMD), then re-run.")
fi

# 3. Group membership: only check /etc/group. The install body uses
# `sg libvirt -c "sg kvm -c '...'"` to bypass the parent shell's stale
# group set wherever it actually matters (Remove-TestVMFiles, Enable-
# TestAutomation). What the parent shell sees is the operator's
# problem, not a preflight question -- they'll refresh it themselves
# (or via `newgrp`) before their NEXT interactive `pwsh
# ./Invoke-TestRunner.ps1`. The final success block detects the stale-
# shell case and prints a "Step 0: refresh your shell" hint.
#
# Only failure mode left here: usermod -aG didn't take at all, so the
# user wouldn't see the groups even after re-login. That's a real
# install error.
for grp in libvirt kvm; do
  group_members="$(getent group "$grp" 2>/dev/null | awk -F: '{print $4}')"
  if [[ ",${group_members}," != *",${USER},"* ]]; then
    PREFLIGHT_ERRORS+=("$USER is not a member of '$grp' in /etc/group -- usermod -aG must have failed earlier. Run: 'sudo usermod -aG $grp $USER' manually.")
  fi
done

# 4. libvirt services active.
for svc in libvirtd virtlogd; do
  if ! systemctl is-active --quiet "$svc"; then
    PREFLIGHT_ERRORS+=("systemd service '$svc' is not active. 'sudo systemctl status $svc' for details.")
  fi
done

# 5. libvirt-qemu system user must exist (created by libvirt-daemon-system postinst).
if ! getent passwd libvirt-qemu >/dev/null 2>&1; then
  PREFLIGHT_ERRORS+=("System user 'libvirt-qemu' missing -- libvirt-daemon-system postinst did not run. Try 'sudo dpkg-reconfigure libvirt-daemon-system'.")
fi

# 6. libvirt 'default' NAT network running AND set to autostart.
if ! sudo virsh net-list --name 2>/dev/null | grep -qx default; then
  PREFLIGHT_ERRORS+=("libvirt 'default' network is not running. 'sudo virsh net-start default' to retry.")
fi
if ! sudo virsh net-list --autostart --name 2>/dev/null | grep -qx default; then
  PREFLIGHT_ERRORS+=("libvirt 'default' network is not set to autostart. 'sudo virsh net-autostart default' to fix.")
fi

# 7. libvirt-qemu must be able to traverse $HOME and read a file under it.
# This is the trap that breaks every fresh New-VM.ps1 run on Ubuntu 24.04
# (0750 home mode). Verify by su'ing as libvirt-qemu against a sentinel
# rather than trusting that setfacl took.
#
# CRITICAL: mktemp defaults the probe file to mode 0600 (owner-only). A
# direct `test -r` from another user would then ALWAYS fail -- not
# because the traverse ACL is missing, but because the file itself
# isn't world-readable. We must `chmod 644` the probe so the only thing
# the libvirt-qemu read-test can fail on is the directory-traverse step
# (which is the actual ACL question this preflight is asking).
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

# 8. Cloud-init seed builder available (per-guest scripts pick whichever).
if ! command -v genisoimage >/dev/null 2>&1 && ! command -v cloud-localds >/dev/null 2>&1; then
  PREFLIGHT_ERRORS+=("Neither 'genisoimage' nor 'cloud-localds' on PATH -- cloud-init seed ISO build will fail.")
fi

# 9. pwsh on PATH (re-check; both apt + tarball paths should leave it here).
if ! command -v pwsh >/dev/null 2>&1; then
  PREFLIGHT_ERRORS+=("pwsh missing from PATH after install.")
fi

# 10. virt-install present (sanity; apt should have brought it in).
if ! command -v virt-install >/dev/null 2>&1; then
  PREFLIGHT_ERRORS+=("'virt-install' not on PATH -- the 'virtinst' apt package did not install.")
fi

# 11. osinfo-db variants the per-guest scripts request. Missing entries
# fall back to a generic profile -- guest still boots, but warn.
# 'linux2022' is the always-required floor (every per-guest New-VM.ps1
# can fall back to it). For Ubuntu we accept either 'ubuntu24.04' or
# 'ubuntu22.04' as good-enough -- the per-guest script probes and
# picks whichever is present, so warning on both being absent is the
# right granularity.
#
# Use osinfo_has_variant (defined near the top of this script) instead
# of `grep -qx`. virt-install --osinfo list emits `<canonical>, <aliases>`
# per line, so a naive grep -qx 'ubuntu24.04' against the raw output
# never matches even when the variant is actually present -- that bug
# masked the upstream-import success and kept this warning printing in
# perpetuity. osinfo_has_variant strips the alias tail before matching.
if command -v virt-install >/dev/null 2>&1; then
  if ! osinfo_has_variant 'linux2022'; then
    PREFLIGHT_WARNINGS+=("osinfo-db is missing variant 'linux2022' -- per-guest scripts may fail to find any usable variant.")
  fi
  if ! osinfo_has_variant 'ubuntu24.04' && ! osinfo_has_variant 'ubuntu22.04'; then
    PREFLIGHT_WARNINGS+=("osinfo-db has neither 'ubuntu24.04' nor 'ubuntu22.04' -- guest.ubuntu.server.24 New-VM.ps1 will fall back to the 'linux2022' generic profile (still boots, just less hypervisor tuning). Update the osinfo-db package on the host to silence this.")
  fi
fi

# 12. UEFI firmware for Windows 11 guest (architecture-specific package).
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

# 13. swtpm + swtpm_setup for Windows 11 vTPM.
for bin in swtpm swtpm_setup; do
  command -v "$bin" >/dev/null 2>&1 || \
    PREFLIGHT_ERRORS+=("'$bin' missing -- Windows 11 guest cannot satisfy TPM 2.0 requirement. Verify 'swtpm' / 'swtpm-tools' apt packages installed.")
done

# 14. GitHub CLI (gh) on PATH. Not used by Invoke-TestRunner itself, but
# the installer just put it on the system; if it is not visible here,
# the cli.github.com apt step silently fell through.
if ! command -v gh >/dev/null 2>&1; then
  PREFLIGHT_ERRORS+=("'gh' missing from PATH after install -- check 'apt-cache policy gh' for the cli.github.com source, then re-run.")
fi

# -- Report -----------------------------------------------------------------
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

# -- Done -------------------------------------------------------------------
# Detect whether the current shell is missing the just-granted libvirt/kvm
# groups so we can lead the "Next steps" with the re-login reminder. The
# preflight has already issued WARN messages for this case; surface it
# again here because operators tend to scroll right past the orange WARN
# lines and look for the green "next steps".
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

# -- Loud notice if we had to side-step a non-ff pull -----------------------
# Printed AFTER the success heredoc so it sits at the bottom of the
# transcript (highest visibility); printed via warn() so it lands on
# stderr and shows up in colour even when the operator pipes stdout to
# a file.
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
