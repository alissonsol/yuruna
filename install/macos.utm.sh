#!/bin/bash
# Version: 2026.05.22
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Yuruna macOS bootstrap installer.
#
# One-liner:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos.utm.sh)"
#
# Leaves the machine ready to edit test/test.config.yml and run
# ./test/Invoke-TestRunner.ps1. Idempotent — safe to re-run.

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

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX \033[0m %s\n' "$*" >&2; exit 1; }

# ── Preflight ────────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" ]] || die "This installer only supports macOS."
[[ $EUID -ne 0 ]] || die "Do not run as root. The script will call sudo when needed."

log "Yuruna macOS installer starting"
log "  repo   : $YURUNA_REPO ($YURUNA_BRANCH)"
log "  target : $YURUNA_DIR"

# ── System requirements: warn + confirm if below the tested baseline ─────
# Tested baseline: 32 GB RAM, 512 GB free, macOS 26+ on arm64, 16+ physical
# cores. Anything below is permitted but UNTESTED -- prompt the operator
# before proceeding so an under-spec'd host doesn't burn an hour of installs
# only to fail in the first test cycle.
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

# ── sudo announcement (consistent with other Yuruna scripts) ───────────────
# Every script in this repo that needs elevation says so up front rather than
# surprising the user midway through. Match that convention here and prime
# sudo a single time so the Homebrew installer and cask post-installs all
# reuse the same timestamp.
cat <<'SUDO_NOTICE'

  ┌───────────────────────────────────────────────────────────────┐
  │  This installer needs sudo for:                               │
  │    • Homebrew install + cask post-install scripts             │
  │  You will be prompted for your macOS password ONCE, below.    │
  └───────────────────────────────────────────────────────────────┘

SUDO_NOTICE
sudo -v
export YURUNA_SUDO_PRIMED=1
# Keep the sudo timestamp fresh for the whole run so brew/cask post-install
# scripts don't re-prompt. `|| true` is load-bearing: under `set -e` (top of
# file), a transient `sudo -n true` failure -- e.g. brief timestamp-lock
# contention while brew/cask post-install runs its own sudo -- would
# otherwise kill this subshell.
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

# NOTE: pmset / GlobalPreferences (display sleep, auto-logout, etc.) are
# the test-host configuration that lives in host/macos.utm/Enable-TestAutomation.ps1
# and is intentionally NOT applied by this installer. Run that script
# manually after install if you want this machine to act as a test host.

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
  # Kill any running Invoke-TestRunner (outer), Invoke-TestInnerRunner
  # (per-cycle inner under modules/), Test-Sequence (dev helper), or
  # Start-StatusServer under the current user. Leaves the pwsh running
  # *this* installer alone (bash cmdline doesn't include any of these).
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

# Detect a running squid-cache VM BEFORE quitting UTM. The cache holds
# tens of GB of pre-fetched .deb / .iso content built up across prior
# test cycles. Quitting UTM stops the VM, a UTM cask upgrade refuses to
# run while UTM is open, and -- the data-loss failure this guard exists
# to prevent -- the unconditional Remove-TestVMFiles.ps1 step further
# down chains into Remove-OrphanedVMFiles.ps1 -Force, which deletes any
# *.utm bundle whose VM is not registered in `utmctl list`. A quit-UTM
# window makes the live cache bundle look orphaned, so it gets reclaimed
# and the squid spool is gone.
#
# The previous detector trusted only `utmctl status` and treated every
# non-"started" result -- INCLUDING "utmctl could not reach UTM" -- as
# "not running". An installer launched over SSH or from any context
# where UTM cannot receive Apple Events therefore reported a false
# negative, quit UTM, and the orphan sweep deleted the cache. Two fixes:
#
#   Signal 1 (authoritative, Apple-Events-independent): TCP-connect to
#   the recorded cache IP on :3128. The cache VM is bridged to the LAN
#   and answers squid there directly -- no utmctl, no UTM, no Apple
#   Events. This is the one signal that survives a non-graphical launch.
#
#   Signal 2 (utmctl status): trusted ONLY for a clean status word. An
#   Apple-Events / SSH error now means "cannot tell" -- and the safe
#   answer to "cannot tell" is PRESERVE, never "quit UTM".
#
# Returns 0 (preserve) when the cache is running OR its state is
# uncertain; returns 1 only when the cache is definitely absent/stopped.
SQUID_CACHE_DETECT_REASON=""
is_squid_cache_running() {
  # --- Signal 1: TCP probe of the recorded cache IP ---
  # State file survives the clone/update (preserve_test_status) and at
  # this point still holds the PRIOR run's value -- exactly what we want.
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

  # --- Signal 2: utmctl status ---
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
brew_ensure_formula qemu        # provides qemu-img, needed by Get-Image.ps1 to resize guest disks
brew_ensure_formula wget        # used by several guest Get-Image.ps1 download steps
brew_ensure_formula openssl     # used by cloud-init seed preparation for some guests
brew_ensure_formula gh          # GitHub CLI -- post-install: run `gh auth login` to authenticate

log "Installing / upgrading required casks"
if [[ ${PRESERVE_SQUID_CACHE:-0} -eq 1 ]]; then
  # `brew upgrade --cask utm` requires UTM closed; we kept it running to
  # preserve the squid-cache VM. UTM gets upgraded on the next install
  # re-run when the cache happens to be stopped (or when the operator
  # quits UTM manually).
  log "  skipping UTM cask upgrade -- squid-cache running, UTM cannot be quit"
else
  brew_ensure_cask utm "/Applications/UTM.app"
fi

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

# ── Preserve test/status runtime state across the clone/update ──────────────
# Re-running the installer on a host that's been executing test cycles must
# not lose the dashboard's history, per-cycle log transcripts, or the
# runtime-dir state (status.json with history[], runner.gating.json,
# runner.pid, control flags). None of those are tracked by git -- per
# .gitignore every subdir under test/status/ is gitignored as runtime
# state. The clone/update/renormalize block below is designed to leave
# untracked files alone (`git rm -r --cached . && git reset --hard HEAD`
# only touches tracked files), but we backstop that contract with an
# explicit snapshot-and-restore so a future regression in the renormalize
# logic, or a manual rm -rf YURUNA_DIR between attempts, can't silently
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

# ── Clone / update the repo ─────────────────────────────────────────────────
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
      warn "git pull --ff-only failed — moving the existing checkout aside and re-cloning."
      warn "  from: $YURUNA_DIR"
      warn "  to:   $YURUNA_BACKUP_DIR"
      if ! mv "$YURUNA_DIR" "$YURUNA_BACKUP_DIR"; then
        die "Could not move '$YURUNA_DIR' to '$YURUNA_BACKUP_DIR'. Close any shells / editors / Finder windows holding the path open and re-run this installer."
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

# ── Renormalize line endings under .gitattributes ───────────────────────────
# .gitattributes (committed at repo root) locks LF for every text type a
# Linux guest reads — *.sh, *.yml, user-data, meta-data, etc. macOS itself
# already uses LF natively, but a developer who shares the repo across a
# Windows + macOS pair (or pulls a branch authored on a CRLF-tainted
# Windows checkout) can still end up with CRLF in the working tree on
# this Mac. The host status server then serves those CRLF bytes
# byte-faithfully to the Linux guest, and bash on the guest chokes with
# `$'\r': command not found` on line 2 of fetch-and-execute.sh. We force
# a one-shot rebuild of the working tree from the index so every file
# picks up the eol= rules.
#
# Pin core.autocrlf=input on the LOCAL repo too, so any future file added
# without a matching .gitattributes rule still avoids CRLF on commit.
# (Local config beats global; doesn't touch the user's other repos.)
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
    # Uncommitted local changes — don't clobber them. Only renormalize the
    # index (stages CRLF->LF for tracked-and-modified files) and tell the
    # user how to finish the job.
    warn "  Working tree has uncommitted changes — only renormalizing the index."
    git -C "$YURUNA_DIR" add --renormalize . || true
    warn "  After resolving local changes, run: git checkout HEAD -- ."
  else
    # Clean tree — empty the index and reset --hard to force every file to
    # be re-checked-out under the current .gitattributes.
    git -C "$YURUNA_DIR" rm -r --cached --quiet .
    git -C "$YURUNA_DIR" reset --hard HEAD >/dev/null
    log "  Working tree rebuilt under current .gitattributes (LF for *.sh, etc.)"
  fi
fi
restore_test_status

# ── Seed test.config.yml from template if missing ──────────────────────────
TEST_DIR="$YURUNA_DIR/test"
if [[ ! -f "$TEST_DIR/test.config.yml" && -f "$TEST_DIR/test.config.yml.template" ]]; then
  log "Creating test/test.config.yml from template (review before running tests)"
  cp "$TEST_DIR/test.config.yml.template" "$TEST_DIR/test.config.yml"
fi

# ── Baseline reset: remove every `test-*` VM left over from prior cycles ────
# An install is a "return-to-baseline" operation. Status server + runner
# processes are killed earlier (stop_yuruna_processes); their VMs are not.
# Remove-TestVMFiles.ps1 enumerates VMs matching the `test-` prefix and
# stops + removes each. The yuruna-caching-proxy VM does NOT match this
# prefix and is preserved. Failure here is non-fatal -- a wedged UTM
# helper or locked .utm bundle on one VM must not block the rest of
# the install. Run AFTER the repo update so we use the just-pulled
# version of the script and its host driver modules.
REMOVE_TEST_VMS="$YURUNA_DIR/test/Remove-TestVMFiles.ps1"
if [[ -f "$REMOVE_TEST_VMS" ]]; then
  log "Removing test-* VMs left over from previous cycles (cache VM preserved)"
  pwsh -NoLogo -NoProfile -File "$REMOVE_TEST_VMS" || \
    warn "Remove-TestVMFiles.ps1 exited non-zero; continuing install."
else
  warn "Remove-TestVMFiles.ps1 not found at $REMOVE_TEST_VMS — skipping test-VM cleanup."
fi

# ── Host configuration (disable display sleep, screen saver, etc.) ──────────
# Enable-TestAutomation.ps1 is NOT run automatically. It is the explicit
# opt-in step that turns this macOS machine into a Yuruna test host
# (pmset display/sleep tweaks, auto-logout disable, hot corners off,
# Accessibility / Screen Recording grants) and is therefore left for
# the operator to invoke manually after install.
HOST_SETUP="$YURUNA_DIR/host/macos.utm/Enable-TestAutomation.ps1"
log ""
log "Host configuration (test-host setup) is NOT auto-applied."
log "To enable this machine as a test host, run:"
log "    pwsh '$HOST_SETUP'"

# ── Done ────────────────────────────────────────────────────────────────────
# Figure out which brew shellenv line the user needs to load in their current
# terminal. The installer ran in its own subshell, so the caller's interactive
# shell still has no /opt/homebrew (or /usr/local) on PATH until they either
# open a new terminal or source the profile file Homebrew updated.
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
     automated because macOS TCC requires a human click in System Settings —
     no script (even with sudo) can toggle Accessibility for another process.
       System Settings > Privacy & Security > Accessibility
       → add and enable Terminal.app (or iTerm2, Ghostty, …)

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

# ── Loud notice if we had to side-step a non-ff pull ────────────────────────
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
