#!/bin/bash
# Yuruna macOS UTM bootstrap installer.
# LICENSEURI https://yuruna.link/license
# Version: 2026.06.19  Copyright (c) 2019-2026 by Alisson Sol et al.
# --- See https://yuruna.link/install/explained
# One-liner: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos.utm.sh)"

set -euo pipefail

YURUNA_REPO_PUBLIC="https://github.com/alissonsol/yuruna.git"
YURUNA_REPO_PRIVATE="https://github.com/alissonsol/yurunadev.git"
YURUNA_REPO="${YURUNA_REPO:-$YURUNA_REPO_PUBLIC}"
YURUNA_BRANCH="${YURUNA_BRANCH:-2026.06.19}"
YURUNA_DIR="${YURUNA_DIR:-$HOME/git/yuruna}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX \033[0m %s\n' "$*" >&2; exit 1; }

# -- Preflight: macOS only -------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "This installer only supports macOS."
[[ $EUID -ne 0 ]] || die "Do not run as root. The script will call sudo when needed."

log "Yuruna macOS installer starting"
log "  repo   : $YURUNA_REPO ($YURUNA_BRANCH)"
log "  target : $YURUNA_DIR"

# -- Preflight: system requirements ----------------------------------------
preflight_system_requirements() {
  local issues=()
  local osver osmajor arch cores mem_bytes mem_gb disk_kb disk_gb
  osver=$(sw_vers -productVersion 2>/dev/null || echo '')
  osmajor=${osver%%.*}
  if [[ -z "${osmajor:-}" || ! "$osmajor" =~ ^[0-9]+$ || "$osmajor" -lt 26 ]]; then
    issues+=("macOS ${osver:-unknown} detected (need 26+)")
  fi
  arch=$(uname -m)
  if [[ "$arch" != "arm64" ]]; then
    issues+=("architecture '$arch' detected (need arm64 -- Apple Silicon)")
  fi
  cores=$(sysctl -n hw.physicalcpu 2>/dev/null || echo 0)
  if (( cores < 16 )); then
    issues+=("$cores physical cores detected (need 16+)")
  fi
  mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  mem_gb=$(( mem_bytes / 1024 / 1024 / 1024 ))
  if (( mem_gb < 32 )); then
    issues+=("${mem_gb}GB RAM detected (need 32GB+)")
  fi
  disk_kb=$(df -k / 2>/dev/null | awk 'NR==2 {print $4}')
  disk_gb=$(( ${disk_kb:-0} / 1024 / 1024 ))
  if (( disk_gb < 512 )); then
    issues+=("${disk_gb}GB free on / (need 512GB+)")
  fi
  if (( ${#issues[@]} == 0 )); then
    log "System OK: macOS $osver, $arch, $cores cores, ${mem_gb}GB RAM, ${disk_gb}GB free on /"
    return 0
  fi
  warn ''
  warn '============================================================'
  warn '  System does not meet Yuruna TESTED requirements:'
  local i; for i in "${issues[@]}"; do warn "    - $i"; done
  warn ''
  warn '  Tested baseline (macOS host):'
  warn '    32GB RAM, 512GB free, macOS 26+ on arm64, 16+ cores.'
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
  |    * Homebrew install + cask post-install scripts             |
  |  You will be prompted for your macOS password ONCE, below.    |
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

# -- Xcode Command Line Tools ----------------------------------------------
if ! xcode-select -p >/dev/null 2>&1; then
  log "Installing Xcode Command Line Tools (a GUI prompt will appear)"
  xcode-select --install || true
  until xcode-select -p >/dev/null 2>&1; do
    sleep 10
    warn "Waiting for Xcode Command Line Tools to finish installing..."
  done
fi

# -- Homebrew --------------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew"
  # Pin Homebrew's bootstrap to a known commit and verify its SHA-256 before
  # running it -- the upstream one-liner pipes the moving HEAD straight to bash.
  # Homebrew/install publishes no tags or signatures, so a pinned commit + a
  # content hash is the available control. Refresh on a Homebrew installer
  # update: set HOMEBREW_INSTALL_COMMIT to the new Homebrew/install HEAD and
  # HOMEBREW_INSTALL_SHA256 to `shasum -a 256` of that install.sh.
  HOMEBREW_INSTALL_COMMIT='280cbc9adffcbdef15dd1c9d991ef2d1dd7cfc9c'
  HOMEBREW_INSTALL_SHA256='f3e91784ffeda32bc397de7acc1154724cc47522a459c9ac656cca176eeba457'
  hb_tmp="$(mktemp)"
  if ! curl -fsSL "https://raw.githubusercontent.com/Homebrew/install/${HOMEBREW_INSTALL_COMMIT}/install.sh" -o "$hb_tmp"; then
    rm -f "$hb_tmp"
    die "Could not download the pinned Homebrew installer (commit $HOMEBREW_INSTALL_COMMIT)."
  fi
  hb_actual="$(shasum -a 256 "$hb_tmp" | cut -d' ' -f1)"
  if [[ "$hb_actual" != "$HOMEBREW_INSTALL_SHA256" ]]; then
    rm -f "$hb_tmp"
    die "Homebrew install.sh SHA-256 mismatch (pinned $HOMEBREW_INSTALL_COMMIT): expected $HOMEBREW_INSTALL_SHA256, got $hb_actual. If Homebrew updated its installer, refresh the pin in install/macos.utm.sh."
  fi
  NONINTERACTIVE=1 /bin/bash "$hb_tmp"
  rm -f "$hb_tmp"
fi

if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
else
  die "Homebrew installation failed -- 'brew' not found on PATH."
fi

# -- Homebrew health repair (multi-user host) ------------------------------
# A fresh macOS user account on a host where Homebrew was installed by a
# different account inherits a /opt/homebrew with mixed ownership AND
# (often) no .git directory (tarball install). Every subsequent brew op
# then either fails outright (`not writable`, `Can't create brew update
# lock`) or spams the "fatal: not in a git directory" + "update-report
# should not be called directly!" cascade triggered by Homebrew's
# internal auto-update inside every `brew install` / `brew upgrade`.
# Repair on this run instead of asking the operator. sudo creds are
# already cached from the earlier `sudo -v`, so this is silent on a
# correctly-installed host (the writability test short-circuits to no-op).
BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
if [[ -z "$BREW_PREFIX" ]]; then
  if   [[ -x /opt/homebrew/bin/brew ]]; then BREW_PREFIX=/opt/homebrew
  elif [[ -x /usr/local/bin/brew    ]]; then BREW_PREFIX=/usr/local
  fi
fi

# HOMEBREW_NO_AUTO_UPDATE=1 silences the "fatal: not in a git directory"
# + "update-report should not be called directly!" cascade that fires
# INSIDE every `brew install` / `brew upgrade` when the prefix isn't a
# proper git checkout. Without this, each per-package op spams ~10
# lines of noise BEFORE doing its actual work, and the operator can't
# tell real errors from auto-update fallout. The explicit `brew update`
# step below is still run when the prefix IS a git checkout; auto-update
# inside individual ops is redundant with that one explicit call.
export HOMEBREW_NO_AUTO_UPDATE=1
# HOMEBREW_NO_ENV_HINTS=1 suppresses the "Homebrew is run entirely by
# unpaid volunteers" donations banner + similar one-shot hints that
# accumulate across the half-dozen brew ops in this script. Cosmetic;
# the install works either way.
export HOMEBREW_NO_ENV_HINTS=1

BREW_SKIP_UPDATE=0
if [[ -n "$BREW_PREFIX" && -d "$BREW_PREFIX" ]]; then
  # Repair signal #1: the prefix root isn't writable.
  # Repair signal #2: the prefix has no .git directory (tarball-installed
  #   Homebrew). Independent of permissions, but on this multi-user host
  #   strongly correlates with mixed-ownership subdirs from the partial
  #   prior install -- so we treat it as a chown trigger too.
  # Repair signal #3: ANY of the standard write-target subdirs is
  #   non-writable. A single writability check on $BREW_PREFIX does NOT
  #   catch issues in subdirs like etc/bash_completion.d, lib/pkgconfig,
  #   share/{aclocal,doc,info,locale,man,man/*,zsh,zsh/site-functions},
  #   so sample the brew install/upgrade write targets directly.
  NEEDS_REPAIR=0
  if [[ ! -w "$BREW_PREFIX" ]]; then NEEDS_REPAIR=1; fi
  if [[ ! -d "$BREW_PREFIX/.git" ]]; then NEEDS_REPAIR=1; fi
  for sub in \
    etc/bash_completion.d \
    lib/pkgconfig \
    share/aclocal share/doc share/info share/locale \
    share/man share/man/man1 share/man/man3 share/man/man5 \
    share/man/man7 share/man/man8 \
    share/zsh share/zsh/site-functions \
    var/homebrew/locks Cellar Caskroom; do
    if [[ -d "$BREW_PREFIX/$sub" && ! -w "$BREW_PREFIX/$sub" ]]; then
      NEEDS_REPAIR=1
      break
    fi
  done
  if [[ $NEEDS_REPAIR -eq 1 ]]; then
    BREW_OWNER="$(stat -f '%Su' "$BREW_PREFIX" 2>/dev/null || echo '?')"
    log "Homebrew prefix $BREW_PREFIX has ownership/state issues for $USER (top-level owner: $BREW_OWNER) -- transferring ownership recursively (sudo cached)."
    # `|| warn` so a stray protected file (rare but seen on some images)
    # doesn't abort the install -- the chown is best-effort; subsequent
    # brew ops will surface anything still broken.
    sudo chown -R "$USER":admin "$BREW_PREFIX" || warn "  chown -R reported errors; per-package brew ops below will surface anything still broken."
  fi
  # Skip the explicit `brew update` if the prefix isn't a git checkout
  # -- it will only emit "fatal: not in a git directory" and exit non-
  # zero. Per-package install/upgrade still works on cached metadata.
  if [[ ! -d "$BREW_PREFIX/.git" ]]; then
    warn "$BREW_PREFIX has no .git directory (tarball-installed Homebrew) -- skipping 'brew update'."
    BREW_SKIP_UPDATE=1
  fi
fi

if [[ $BREW_SKIP_UPDATE -eq 0 ]]; then
  log "Updating Homebrew"
  # Trap non-zero `brew update` (broken tap, missing tap .git, network
  # blip) and downgrade to a warning. The installer's job is to get
  # Yuruna's package set on disk; stale Homebrew metadata is acceptable
  # as long as `brew install` and `brew upgrade` find the formulae.
  if ! brew update; then
    warn "brew update exited non-zero -- continuing with cached package metadata."
  fi
fi

# -- Stop running Yuruna processes -----------------------------------------
quit_mac_app() {
  local app="$1" procPattern="${2:-$1}"
  if pgrep -x "$procPattern" >/dev/null 2>&1 || pgrep -f "/$app.app/" >/dev/null 2>&1; then
    log "  quitting $app (in-flight upgrade)"
    osascript -e "tell application \"$app\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
      pgrep -x "$procPattern" >/dev/null 2>&1 || ! pgrep -f "/$app.app/" >/dev/null 2>&1 || break
      sleep 1
    done
    if pgrep -x "$procPattern" >/dev/null 2>&1 || pgrep -f "/$app.app/" >/dev/null 2>&1; then
      warn "  $app did not quit gracefully -- sending SIGTERM"
      pkill -x "$procPattern" 2>/dev/null || true
      pkill -f "/$app.app/" 2>/dev/null || true
      sleep 1
    fi
  fi
}

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
  if command -v lsof >/dev/null 2>&1; then
    local port_pids
    port_pids=$(lsof -ti tcp:8080 2>/dev/null || true)
    if [[ -n "$port_pids" ]]; then
      warn "  freeing port 8080 (pids: $port_pids)"
      # shellcheck disable=SC2086
      kill $port_pids 2>/dev/null || true
    fi
  fi
}

# -- Preserve yuruna-caching-proxy if running ------------------------------
SQUID_CACHE_DETECT_REASON=""
is_squid_cache_running() {
  local state_file="$YURUNA_DIR/test/status/runtime/yuruna-caching-proxy.yml"
  if [[ -f "$state_file" ]] && command -v nc >/dev/null 2>&1; then
    local cache_ip
    cache_ip=$(grep -E '^ipAddress:' "$state_file" 2>/dev/null | head -1 \
                 | sed -E "s/^ipAddress:[[:space:]]*//; s/[\"' ]//g")
    if [[ -n "$cache_ip" ]] && nc -G 2 -z "$cache_ip" 3128 >/dev/null 2>&1; then
      SQUID_CACHE_DETECT_REASON="squid answers at ${cache_ip}:3128"
      return 0
    fi
  fi

  command -v utmctl >/dev/null 2>&1 || { SQUID_CACHE_DETECT_REASON=""; return 1; }
  local status
  status=$(utmctl status yuruna-caching-proxy 2>&1 || true)
  case "$status" in
    started|paused|suspended)
      SQUID_CACHE_DETECT_REASON="utmctl reports the cache VM '$status'"
      return 0 ;;
    *OSStatus*|*"-1743"*|*"Apple Event"*|*"does not work from SSH"*)
      SQUID_CACHE_DETECT_REASON="utmctl could not reach UTM (Apple Events denied) -- cannot confirm cache state; preserving out of caution"
      return 0 ;;
    stopped|*"not found"*|"")
      SQUID_CACHE_DETECT_REASON=""
      return 1 ;;
    *)
      SQUID_CACHE_DETECT_REASON="utmctl status returned an unrecognized result ('$status'); preserving out of caution"
      return 0 ;;
  esac
}

PRESERVE_SQUID_CACHE=0
if is_squid_cache_running; then
  warn "yuruna-caching-proxy cache VM is running (or its state is uncertain): $SQUID_CACHE_DETECT_REASON."
  warn "  Skipping UTM quit + UTM cask upgrade for this run so the cache VM and its"
  warn "  multi-GB squid spool are NOT torn down (a quit-UTM window would let the"
  warn "  orphaned-bundle sweep delete it). To upgrade UTM later: stop the cache"
  warn "  (pwsh test/Stop-CachingProxy.ps1) or quit UTM manually, then re-run this installer."
  PRESERVE_SQUID_CACHE=1
fi

log "Stopping anything that would block an upgrade"
stop_yuruna_processes
if [[ $PRESERVE_SQUID_CACHE -eq 0 ]]; then
  quit_mac_app "UTM"
fi

# -- Install platform packages ---------------------------------------------
brew_ensure_formula() {
  local name="$1"
  if brew list --formula --versions "$name" >/dev/null 2>&1; then
    log "  upgrading $name (formula, if outdated)"
    brew upgrade --formula "$name" 2>&1 | grep -vE "already installed|up-to-date" || true
  else
    log "  installing $name (formula)"
    brew install --formula "$name"
  fi
}

brew_ensure_cask() {
  local name="$1" appPath="${2:-}"
  if brew list --cask --versions "$name" >/dev/null 2>&1; then
    log "  upgrading $name (cask, if outdated)"
    brew upgrade --cask "$name" 2>&1 | grep -vE "already installed|up-to-date" || true
    return 0
  fi
  if [[ -n "$appPath" && -d "$appPath" ]]; then
    log "  $name already present at $appPath (installed outside brew) -- skipping"
    return 0
  fi
  log "  installing $name (cask)"
  brew install --cask "$name"
}

log "Installing / upgrading required formulae"
brew_ensure_formula git
brew_ensure_formula powershell || brew_ensure_cask powershell
brew_ensure_formula tesseract
brew_ensure_formula qemu
brew_ensure_formula wget
brew_ensure_formula openssl
brew_ensure_formula gh

log "Installing / upgrading required casks"
if [[ ${PRESERVE_SQUID_CACHE:-0} -eq 1 ]]; then
  log "  skipping UTM cask upgrade -- caching-proxy running, UTM cannot be quit"
else
  brew_ensure_cask utm "/Applications/UTM.app"
fi

if ! command -v pwsh >/dev/null 2>&1; then
  log "  installing PowerShell (cask fallback)"
  brew install --cask powershell
fi

log "Running brew cleanup"
brew cleanup --quiet || true

command -v pwsh >/dev/null 2>&1 || die "pwsh not found after install."
command -v git  >/dev/null 2>&1 || die "git not found after install."
[[ -d /Applications/UTM.app ]]  || warn "UTM.app not found under /Applications -- test runner will warn."

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
        die "Could not move '$YURUNA_DIR' to '$YURUNA_BACKUP_DIR'. Close any shells / editors / Finder windows holding the path open and re-run this installer."
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
  pwsh -NoLogo -NoProfile -File "$REMOVE_TEST_VMS" || \
    warn "Remove-TestVMFiles.ps1 exited non-zero; continuing install."
else
  warn "Remove-TestVMFiles.ps1 not found at $REMOVE_TEST_VMS -- skipping test-VM cleanup."
fi

# -- Enable-TestAutomation.ps1 hint ----------------------------------------
HOST_SETUP="$YURUNA_DIR/host/macos.utm/Enable-TestAutomation.ps1"
log ""
log "Host configuration (test-host setup) is NOT auto-applied."
log "To enable this machine as a test host, run:"
log "    pwsh '$HOST_SETUP'"

# -- Done summary ----------------------------------------------------------
BREW_PREFIX="$(brew --prefix)"
BREW_SHELLENV="eval \"\$($BREW_PREFIX/bin/brew shellenv)\""

cat <<EOF

$(log "Yuruna is ready.")

Next steps (in order):

  1. Activate the new PATH in your CURRENT terminal. The installer ran in a
     subshell so 'brew', 'pwsh', 'git' from Homebrew are not yet visible to
     the shell you used to paste the curl command. Either open a new Terminal
     window, or run this one-liner to patch the current session:

       $BREW_SHELLENV

  2. Review and edit the test config:
       \$EDITOR $TEST_DIR/test.config.yml

  3. Launch UTM once so it can register with macOS and request any first-run
     permissions (network, file access):
       open -a UTM

  4. Grant Accessibility permission to your terminal app. This step is NOT
     automated because macOS TCC requires a human click in System Settings --
     no script (even with sudo) can toggle Accessibility for another process.
       System Settings > Privacy & Security > Accessibility
       -> add and enable Terminal.app (or iTerm2, Ghostty, ...)

  5. (Optional) Enable this machine as a test host -- disables display sleep,
     auto-logout, and screen lock so VM screen captures stay readable. NOT
     run automatically; opt in only if this Mac will run Invoke-TestRunner:
       pwsh $YURUNA_DIR/host/macos.utm/Enable-TestAutomation.ps1

  6. Run the test runner:
       cd $TEST_DIR && pwsh ./Invoke-TestRunner.ps1

  7. (Optional, one-time) Authenticate the GitHub CLI so 'gh' can act on
     your behalf -- the installer installs the binary, but authentication
     requires an interactive web-or-token flow you have to drive:
       gh auth login

Re-running this installer is safe; it will update Homebrew packages and
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
