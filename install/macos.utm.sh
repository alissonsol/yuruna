#!/bin/bash
# Yuruna macOS UTM bootstrap installer.
# LICENSEURI https://yuruna.link/license
# Version: 2026.07.10  Copyright (c) 2019-2026 by Alisson Sol et al.
# --- REGION: https://yuruna.link/install/explained
# One-liner: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos.utm.sh)"

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

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX \033[0m %s\n' "$*" >&2; exit 1; }

# --- REGION: Install log
# Mirror stdout+stderr to a file as well as the terminal so a mid-install
# failure can be inspected afterwards. A FIFO + backgrounded tee (rather than
# `exec > >(tee ...)`) lets the EXIT path wait for tee to flush, so the file is
# complete even on an abrupt exit -- a plain process-substitution tee is left
# an orphan that may be killed before flushing its block-buffered file write.
# Standard per-user log dir, ${TMPDIR:-/tmp} fallback.
if [[ -z "${YURUNA_INSTALL_LOG:-}" ]]; then
  _yuruna_log_dir="$HOME/Library/Logs/Yuruna"
  mkdir -p "$_yuruna_log_dir" 2>/dev/null || _yuruna_log_dir="${TMPDIR:-/tmp}"
  YURUNA_INSTALL_LOG="$_yuruna_log_dir/macos.utm.install.$(date +%Y%m%d-%H%M%S).log"
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

# --- REGION: Preflight: macOS only
[[ "$(uname -s)" == "Darwin" ]] || die "This installer only supports macOS."
[[ $EUID -ne 0 ]] || die "Do not run as root. The script will call sudo when needed."

# --- REGION: Preflight: Apple Silicon required (HARD gate)
# Architecture is a hard incompatibility, not a tunable performance baseline:
# the guest VMs are arm64 images and Homebrew publishes no x86_64 bottles for
# the required formulae/casks (qemu, tesseract, UTM, ...). Fail up front with
# an actionable message instead of part-way through the brew package phase.
[[ "$(uname -m)" == "arm64" ]] || die "This installer requires Apple Silicon (arm64). This Mac reports '$(uname -m)', which cannot run the arm64 test VMs or install the required Homebrew arm64 bottles (qemu, tesseract, UTM)."

log "Yuruna macOS installer starting"
log "  repo   : $YURUNA_REPO ($YURUNA_BRANCH)"
log "  target : $YURUNA_DIR"

# --- REGION: Preflight: system requirements
preflight_system_requirements() {
  local issues=()
  local osver osmajor arch cores mem_bytes mem_gb disk_kb disk_gb
  osver=$(sw_vers -productVersion 2>/dev/null || echo '')
  osmajor=${osver%%.*}
  if [[ -z "${osmajor:-}" || ! "$osmajor" =~ ^[0-9]+$ || "$osmajor" -lt 26 ]]; then
    issues+=("macOS ${osver:-unknown} detected (need 26+)")
  fi
  arch=$(uname -m)   # guaranteed arm64 by the hard gate above; kept for the summary line
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

# --- REGION: sudo announcement + keepalive
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
  local rc=$?
  kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  if [[ -n "${YURUNA_STATUS_BACKUP:-}" && -d "${YURUNA_STATUS_BACKUP:-}" ]]; then
    rm -rf "$YURUNA_STATUS_BACKUP" 2>/dev/null || true
  fi
  if [[ $rc -ne 0 ]]; then
    printf '\n\033[1;31mXX \033[0m installer exited with code %d.\n' "$rc" >&2
    printf '   Full log: %s\n' "${YURUNA_INSTALL_LOG:-<none>}" >&2
  fi
  _yuruna_flush_log
}
trap yuruna_install_cleanup EXIT

# --- REGION: Xcode Command Line Tools
if ! xcode-select -p >/dev/null 2>&1; then
  log "Installing Xcode Command Line Tools (a GUI prompt will appear)"
  xcode-select --install || true
  until xcode-select -p >/dev/null 2>&1; do
    sleep 10
    warn "Waiting for Xcode Command Line Tools to finish installing..."
  done
fi

# --- REGION: Homebrew
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

# --- REGION: Homebrew health repair (multi-user host)
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
# NONINTERACTIVE=1 keeps `brew install` / `brew upgrade` / `--cask` from
# blocking on interactive confirmation prompts (e.g. a cask overwrite or
# post-install confirmation) during the package phase. It is set inline
# ABOVE only for the Homebrew bootstrap; without exporting it here the
# per-package ops can stop and wait for a 'y'. The sudo keepalive already
# handles the password, so this only suppresses Homebrew's own prompts.
export NONINTERACTIVE=1

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

# --- REGION: Stop running Yuruna processes
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

# --- REGION: Stop running Yuruna host services
# Force-stop the outer runner, its per-cycle inner pwsh, and the detached
# status HTTP server, then WAIT for them to exit before the repo update
# renames the checkout aside. VMs (the yuruna-caching-proxy cache, a UTM
# domain) are never touched here: they are not children of the runner, and
# this installer issues no VM stop/destroy (UTM quit is gated separately on
# PRESERVE_SQUID_CACHE).
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
  # have RECYCLED to an unrelated process, and on the `-c "<script>"` /
  # `bash <(...)` launch a pgrep -f pattern can even match THIS installer or its
  # sudo-keepalive subshell (the script text carries the .ps1 names in argv).
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
    # argv with the .ps1 pattern names on the -c / bash <(...) launch. -ww so
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

# --- REGION: Preserve yuruna-caching-proxy if running
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

log "Stopping anything that would block a repo update (runner + status server; VMs preserved)"
stop_yuruna_processes
if [[ $PRESERVE_SQUID_CACHE -eq 0 ]]; then
  quit_mac_app "UTM"
fi

# --- REGION: Install platform packages
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
        die "Could not move '$YURUNA_DIR' to '$YURUNA_BACKUP_DIR'. Close any shells / editors / Finder windows holding the path open and re-run this installer."
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
  pwsh -NoLogo -NoProfile -File "$REMOVE_TEST_VMS" || \
    warn "Remove-TestVMFiles.ps1 exited non-zero; continuing install."
else
  warn "Remove-TestVMFiles.ps1 not found at $REMOVE_TEST_VMS -- skipping test-VM cleanup."
fi

# --- REGION: Enable-TestAutomation.ps1 hint
HOST_SETUP="$YURUNA_DIR/host/macos.utm/Enable-TestAutomation.ps1"
log ""
log "Host configuration (test-host setup) is NOT auto-applied."
log "To enable this machine as a test host, run:"
log "    pwsh '$HOST_SETUP'"

# --- REGION: Done summary
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
