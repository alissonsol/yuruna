#!/bin/bash
# Yuruna Ubuntu KVM/libvirt bootstrap installer.
# LICENSEURI https://yuruna.link/license
# Version: 2026.06.05  Copyright (c) 2019-2026 by Alisson Sol et al.
# --- See https://yuruna.link/install/explained
# One-liner: bash <(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh)
# Supported target: Ubuntu 26.04 (Resolute) or newer, x86_64 or aarch64.

set -euo pipefail

YURUNA_REPO_PUBLIC="https://github.com/alissonsol/yuruna.git"
YURUNA_REPO_PRIVATE="https://github.com/alissonsol/yurunadev.git"
YURUNA_REPO="${YURUNA_REPO:-$YURUNA_REPO_PUBLIC}"
YURUNA_BRANCH="${YURUNA_BRANCH:-main}"
YURUNA_DIR="${YURUNA_DIR:-$HOME/git/yuruna}"

_yuruna_step="<starting up>"
log()  { _yuruna_step="$*"; printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX \033[0m %s\n' "$*" >&2; exit 1; }

# -- ERR trap --------------------------------------------------------------
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

# -- Preflight: Linux only -------------------------------------------------
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

# -- Preflight: system requirements ----------------------------------------
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

# -- sudo announcement + keepalive -----------------------------------------
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
}
trap yuruna_install_cleanup EXIT

# -- Preflight: CPU virtualization (vmx/svm) -------------------------------
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

# -- Stop running Yuruna processes -----------------------------------------
stop_yuruna_processes() {
  local patterns=(
    "Invoke-TestRunner.ps1"
    "Invoke-TestInnerRunner.ps1"
    "Test-Sequence.ps1"
    "Start-StatusService.ps1"
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

# -- Install platform packages ---------------------------------------------
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

# -- osinfo-db refresh -----------------------------------------------------
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

# -- PowerShell (apt for x86_64, tarball fallback for aarch64) -------------
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

# -- PowerShell modules ----------------------------------------------------
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

# -- libvirt: enable + groups + ACL + default network ----------------------
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

# -- Preserve test/status runtime state ------------------------------------
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

# -- Clone / update the repo -----------------------------------------------
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
    git -C "$YURUNA_DIR" fetch --tags origin
    git -C "$YURUNA_DIR" checkout "$YURUNA_BRANCH"
    if ! git -C "$YURUNA_DIR" pull --ff-only origin "$YURUNA_BRANCH"; then
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
  log "Cloning Yuruna into $YURUNA_DIR from $YURUNA_REPO"
  git clone --branch "$YURUNA_BRANCH" "$YURUNA_REPO" "$YURUNA_DIR"
fi

# -- Renormalize line endings under .gitattributes -------------------------
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
restore_test_status

# -- Seed test.config.yml from template ------------------------------------
TEST_DIR="$YURUNA_DIR/test"
if [[ ! -f "$TEST_DIR/test.config.yml" && -f "$TEST_DIR/test.config.yml.template" ]]; then
  log "Creating test/test.config.yml from template (review before running tests)"
  cp "$TEST_DIR/test.config.yml.template" "$TEST_DIR/test.config.yml"
fi

# -- Baseline reset: remove test-* VMs -------------------------------------
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

# -- Enable-TestAutomation.ps1 hint ----------------------------------------
HOST_SETUP="$YURUNA_DIR/host/ubuntu.kvm/Enable-TestAutomation.ps1"
log ""
log "Host configuration (test-host setup) is NOT auto-applied."
log "To enable this machine as a test host, run:"
log "    pwsh '$HOST_SETUP'"

# -- GitHub CLI ------------------------------------------------------------
install_gh_apt() {
  log "Installing GitHub CLI (gh) via cli.github.com apt repo"
  sudo install -d -m 0755 /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/githubcli-archive-keyring.gpg ]]; then
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

# -- Final preflight -------------------------------------------------------
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

# -- Done summary ----------------------------------------------------------
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

# -- Backup notice ---------------------------------------------------------
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
