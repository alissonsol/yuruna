#!/bin/bash
#
# Yuruna macOS bootstrap installer.
#
# One-liner:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos-install.sh)"
#
# Leaves the machine ready to edit test/test-config.json and run
# ./test/Invoke-TestRunner.ps1. Idempotent — safe to re-run.

set -euo pipefail

YURUNA_REPO="${YURUNA_REPO:-https://github.com/alissonsol/yuruna.git}"
YURUNA_BRANCH="${YURUNA_BRANCH:-main}"
YURUNA_DIR="${YURUNA_DIR:-$HOME/git/yuruna}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX \033[0m %s\n' "$*" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" ]] || die "This installer only supports macOS."
[[ $EUID -ne 0 ]] || die "Do not run as root. The script will call sudo when needed."

log "Yuruna macOS installer starting"
log "  repo   : $YURUNA_REPO ($YURUNA_BRANCH)"
log "  target : $YURUNA_DIR"

# Prime sudo once so later steps (pmset in Set-MacHostConditionSet) don't stall.
log "Requesting sudo (needed for Homebrew + host configuration)"
sudo -v
( while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# ── Xcode Command Line Tools (prereq for Homebrew + git) ────────────────────
if ! xcode-select -p >/dev/null 2>&1; then
  log "Installing Xcode Command Line Tools (a GUI prompt will appear)"
  xcode-select --install || true
  until xcode-select -p >/dev/null 2>&1; do
    sleep 10
    warn "Waiting for Xcode Command Line Tools to finish installing…"
  done
fi

# ── Homebrew ─────────────────────────────────────────────────────────────────
if ! command -v brew >/dev/null 2>&1; then
  log "Installing Homebrew"
  NONINTERACTIVE=1 /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Make brew available in this shell regardless of CPU architecture.
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
else
  die "Homebrew installation failed — 'brew' not found on PATH."
fi

log "Updating Homebrew"
brew update

# ── Stop anything that would block an upgrade ───────────────────────────────
# Re-runs of this script must be able to upgrade UTM, PowerShell, and the
# repository in place. Casks refuse to upgrade while their app is running,
# and an active Yuruna test run or status server would fight with us for
# the repo working tree and port 8080.

quit_mac_app() {
  # Graceful Cmd-Q via AppleScript; fall back to pkill if it refuses.
  local app="$1" procPattern="${2:-$1}"
  if pgrep -x "$procPattern" >/dev/null 2>&1 || pgrep -f "/$app.app/" >/dev/null 2>&1; then
    log "  quitting $app (in-flight upgrade)"
    osascript -e "tell application \"$app\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
      pgrep -x "$procPattern" >/dev/null 2>&1 || ! pgrep -f "/$app.app/" >/dev/null 2>&1 || break
      sleep 1
    done
    if pgrep -x "$procPattern" >/dev/null 2>&1 || pgrep -f "/$app.app/" >/dev/null 2>&1; then
      warn "  $app did not quit gracefully — sending SIGTERM"
      pkill -x "$procPattern" 2>/dev/null || true
      pkill -f "/$app.app/" 2>/dev/null || true
      sleep 1
    fi
  fi
}

stop_yuruna_processes() {
  # Kill any running Invoke-TestRunner / Invoke-TestSequence / Start-StatusServer
  # under the current user, but leave the pwsh running *this* installer alone.
  local patterns=(
    "Invoke-TestRunner.ps1"
    "Invoke-TestSequence.ps1"
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
  # Free port 8080 if the status server is still holding it.
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

log "Stopping anything that would block an upgrade"
stop_yuruna_processes
quit_mac_app "UTM"

# ── Formulae + casks ─────────────────────────────────────────────────────────
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
    log "  $name already present at $appPath (installed outside brew) — skipping"
    return 0
  fi
  log "  installing $name (cask)"
  brew install --cask "$name"
}

log "Installing / upgrading required formulae"
brew_ensure_formula git
brew_ensure_formula powershell || brew_ensure_cask powershell
brew_ensure_formula tesseract   # needed by Test.Tesseract.psm1 for OCR steps

log "Installing / upgrading required casks"
brew_ensure_cask utm "/Applications/UTM.app"

# powershell ships as a cask on some taps; make sure pwsh is on PATH.
if ! command -v pwsh >/dev/null 2>&1; then
  log "  installing PowerShell (cask fallback)"
  brew install --cask powershell
fi

log "Running brew cleanup"
brew cleanup --quiet || true

command -v pwsh >/dev/null 2>&1 || die "pwsh not found after install."
command -v git  >/dev/null 2>&1 || die "git not found after install."
[[ -d /Applications/UTM.app ]]  || warn "UTM.app not found under /Applications — test runner will warn."

# ── Clone / update the repo ─────────────────────────────────────────────────
mkdir -p "$(dirname "$YURUNA_DIR")"
if [[ -d "$YURUNA_DIR/.git" ]]; then
  log "Updating existing Yuruna checkout at $YURUNA_DIR"
  git -C "$YURUNA_DIR" fetch --tags origin
  git -C "$YURUNA_DIR" checkout "$YURUNA_BRANCH"
  git -C "$YURUNA_DIR" pull --ff-only origin "$YURUNA_BRANCH" || \
    warn "Could not fast-forward — local changes present. Leaving as-is."
else
  log "Cloning Yuruna into $YURUNA_DIR"
  git clone --branch "$YURUNA_BRANCH" "$YURUNA_REPO" "$YURUNA_DIR"
fi

# ── Seed test-config.json from template if missing ─────────────────────────
TEST_DIR="$YURUNA_DIR/test"
if [[ ! -f "$TEST_DIR/test-config.json" && -f "$TEST_DIR/test-config.json.template" ]]; then
  log "Creating test/test-config.json from template (review before running tests)"
  cp "$TEST_DIR/test-config.json.template" "$TEST_DIR/test-config.json"
fi

# ── Host configuration (disable display sleep, screen saver, etc.) ──────────
if [[ -f "$TEST_DIR/Set-MacHostConditionSet.ps1" ]]; then
  log "Running Set-MacHostConditionSet.ps1"
  ( cd "$TEST_DIR" && pwsh -NoLogo -NoProfile -File ./Set-MacHostConditionSet.ps1 )
else
  warn "Set-MacHostConditionSet.ps1 not found under $TEST_DIR — skipping host config."
fi

# ── Done ────────────────────────────────────────────────────────────────────
cat <<EOF

$(log "Yuruna is ready.")

Next steps:
  1. Review and edit the test config:
       \$EDITOR $TEST_DIR/test-config.json
  2. Launch UTM once so it can request any first-run permissions:
       open -a UTM
  3. Run the test runner:
       cd $TEST_DIR && pwsh ./Invoke-TestRunner.ps1

Re-running this installer is safe; it will update Homebrew packages and
fast-forward the Yuruna checkout when possible.
EOF
