#!/bin/bash
# Version: 2026.09.01
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# Yuruna macOS UTM bootstrap installer.
# --- REGION: https://yuruna.link/install/explained
# One-liner: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos.utm.sh)"

set -euo pipefail

YURUNA_REPO_PUBLIC="https://github.com/alissonsol/yuruna.git"
YURUNA_REPO_PRIVATE="https://github.com/alissonsol/yurunadev.git"
YURUNA_REPO="${YURUNA_REPO:-$YURUNA_REPO_PUBLIC}"
# --- REGION: https://yuruna.link/install/explained#development-repo-tracks-latest-main
YURUNA_BRANCH_EXPLICIT=0
[[ -n "${YURUNA_BRANCH:-}" ]] && YURUNA_BRANCH_EXPLICIT=1
YURUNA_BRANCH="${YURUNA_BRANCH:-main}"
# --- REGION: https://yuruna.link/install/explained#release-pinning--signed-integrity
PIN_VERSION="${PIN_VERSION:-0}"
for _yuruna_arg in "$@"; do
  [[ "$_yuruna_arg" == "--pin-version" ]] && PIN_VERSION=1
done
YURUNA_DIR="${YURUNA_DIR:-$HOME/git/yuruna}"

# Where a tool is linked when it has to be reachable by name from the whole
# machine rather than from a shell that ran `brew shellenv`: the stock
# /etc/paths lists this directory, so a login shell, a LaunchAgent and an
# `ssh host command` all resolve what is linked here. utmctl lands in it, and so
# does any tool whose newest copy has to be put in front of an older one.
PATH_LINK_DIR="/usr/local/bin"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!! \033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX \033[0m %s\n' "$*" >&2; exit 1; }

# --- REGION: Deferred issues
# Every non-fatal problem is recorded here as well as printed where it happens.
# An installer prints hundreds of lines; a package that failed to upgrade
# scrolls past long before the operator reads the closing instructions, and the
# only thing that survives to the end is a summary. Nothing here stops the run:
# the operator is mid-install, and a package-manager hiccup should not end it --
# but it must not pass unmentioned either.
YURUNA_ISSUES=()
note_issue() { YURUNA_ISSUES+=("$*"); warn "$*"; }

# --- REGION: https://yuruna.link/install/explained#install-log
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

# --- REGION: Preflight: this account can elevate
# Everything below eventually needs root, and the sudo prompt is 70 lines on,
# past the requirements gate and its question. An account that cannot elevate
# otherwise answers all of that, types a password, and is then refused with no
# message at all -- the EXIT trap that reports a failure is not installed yet at
# that point. macOS grants root through the 'admin' group, so ask the group list
# and read an EXIT CODE: sudo's refusal wording differs between the C sudo and
# the Rust rewrite, and a message matcher silently stops matching.
# The group list is read WITHOUT a username argument on purpose. With one, id
# queries the name service and reports the on-disk grant; sudo authorizes
# against the group token this session was started with, so the bare form is the
# one that agrees with what sudo will actually do here.
_yuruna_whoami="${USER:-$(id -un)}"
if ! sudo -n -v 2>/dev/null && ! id -Gn | tr ' ' '\n' | grep -qx admin; then
  die "$_yuruna_whoami cannot elevate: this session is not in the 'admin' group, so sudo will refuse and the installer cannot continue.

   From an account that IS an administrator, run:
       sudo dseditgroup -o edit -a $_yuruna_whoami -t user admin

   Then sign $_yuruna_whoami out and back in -- the group list is fixed when a
   session starts, so an already-open one stays refused -- and start the
   installer again."
fi

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
  # Round to nearest GB (add half the divisor) so a box a fraction under the
  # boundary is not warned as one GB short of its true capacity.
  mem_gb=$(( (mem_bytes + 512 * 1024 * 1024) / (1024 * 1024 * 1024) ))
  if (( mem_gb < 32 )); then
    issues+=("${mem_gb}GB RAM detected (need 32GB+)")
  fi
  disk_kb=$(df -k / 2>/dev/null | awk 'NR==2 {print $4}')
  disk_gb=$(( (${disk_kb:-0} + 512 * 1024) / (1024 * 1024) ))
  if (( disk_gb < 512 )); then
    issues+=("${disk_gb}GB free on / (need 512GB+)")
  fi
  if (( ${#issues[@]} == 0 )); then
    log "System OK: macOS $osver, $arch, $cores cores, ${mem_gb}GB RAM, ${disk_gb}GB free on /"
    return 0
  fi
  warn ''
  warn '========'
  warn '  System does not meet Yuruna TESTED requirements:'
  local i; for i in "${issues[@]}"; do warn "    - $i"; done
  warn ''
  warn '  Tested baseline (macOS host):'
  warn '    32GB RAM, 512GB free, macOS 26+ on arm64, 16+ cores.'
  warn ''
  warn '  Continuing is permitted but UNTESTED; the test harness may'
  warn '  fail in ways the core development team cannot reproduce.'
  warn '========'
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
sudo -v || die "sudo did not authorize this run; the installer needs root for the Homebrew install and the cask post-install scripts."
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

# --- REGION: https://yuruna.link/install/explained#multi-user-homebrew-ownership-repair
# Best-effort ownership/.git repair; sudo already cached, no-op on a healthy prefix.
BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
if [[ -z "$BREW_PREFIX" ]]; then
  if   [[ -x /opt/homebrew/bin/brew ]]; then BREW_PREFIX=/opt/homebrew
  elif [[ -x /usr/local/bin/brew    ]]; then BREW_PREFIX=/usr/local
  fi
fi

# HOMEBREW_NO_AUTO_UPDATE=1 silences the "fatal: not in a git directory" +
# "update-report should not be called directly!" cascade that fires INSIDE
# every `brew install` / `brew upgrade` when the prefix isn't a proper git
# checkout -- ~10 lines of noise before each per-package op does its work,
# indistinguishable from a real error. The explicit `brew update` step below
# still runs when the prefix IS a git checkout, so per-op auto-update is
# redundant with that one call.
export HOMEBREW_NO_AUTO_UPDATE=1
# HOMEBREW_NO_ENV_HINTS=1 suppresses the "Homebrew is run entirely by unpaid
# volunteers" donations banner and similar one-shot hints that accumulate
# across the half-dozen brew ops here. Cosmetic; the install works either way.
export HOMEBREW_NO_ENV_HINTS=1
# NONINTERACTIVE=1 keeps `brew install` / `brew upgrade` / `--cask` from blocking
# on an interactive confirmation (a cask overwrite, a post-install question)
# during the package phase; it is set inline ABOVE only for the Homebrew
# bootstrap, and without exporting it here the per-package ops can stop and wait
# for a 'y'. The sudo keepalive already handles the password, so this suppresses
# Homebrew's own prompts only.
export NONINTERACTIVE=1

BREW_SKIP_UPDATE=0
if [[ -n "$BREW_PREFIX" && -d "$BREW_PREFIX" ]]; then
  # Repair signals (see the REGION doc): prefix root not writable; no .git
  # (tarball install); or any brew write-target subdir not writable.
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

# --- REGION: Quit a macOS app gracefully
quit_mac_app() {
  local app="$1" procPattern="${2:-$1}"
  if pgrep -x "$procPattern" >/dev/null 2>&1 || pgrep -f "/$app.app/" >/dev/null 2>&1; then
    log "  quitting $app (in-flight upgrade)"
    osascript -e "tell application \"$app\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5; do
      pgrep -x "$procPattern" >/dev/null 2>&1 || pgrep -f "/$app.app/" >/dev/null 2>&1 || break
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

# --- REGION: https://yuruna.link/install/explained#stop-running-yuruna-processes-before-updating
# Stop the runner/inner/status-service and WAIT before the checkout rename.
# VMs (the yuruna-caching-proxy-service cache, a UTM domain) are never touched here;
# UTM quit is gated separately on PRESERVE_SERVICE_VM.
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
    "Start-TestRunner.ps1"
    "Invoke-TestRunnerInnerLoop.ps1"
    "Debug-TestSequence.ps1"
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

  # --- REGION: https://yuruna.link/install/explained#pid-identity-validation-before-kill
  # Keep only pids whose executable (comm) is pwsh; never kill a recycled or self-matched pid.
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
    log "  no running Yuruna runner / status service found"
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

# --- REGION: Preserve running service VMs
# --- REGION: https://yuruna.link/install/explained#preserve-the-yuruna-caching-proxy-service-vm
# Quitting UTM is never confined to the VM the installer cares about: UTM
# saves the state of EVERY running VM on its way out, and they come back
# suspended rather than started. That makes any running service VM -- the
# caching proxy, the stash service, pool-control, the download agent -- a
# reason not to quit, not just the proxy whose spool would also be at risk
# from the orphaned-bundle sweep.
SERVICE_VM_DETECT_REASON=""
YURUNA_SERVICE_VM_NAME=(yuruna-caching-proxy-service yuruna-stash-service yuruna-pool-control-service yuruna-download-agent-service)

is_service_vm_running() {
  local state_file="$YURUNA_DIR/test/status/runtime/yuruna-caching-proxy-service.yml"
  if [[ -f "$state_file" ]] && command -v nc >/dev/null 2>&1; then
    local cache_ip
    cache_ip=$(grep -E '^ipAddress:' "$state_file" 2>/dev/null | head -1 \
                 | sed -E "s/^ipAddress:[[:space:]]*//; s/[\"' ]//g")
    if [[ -n "$cache_ip" ]] && nc -G 2 -z "$cache_ip" 3128 >/dev/null 2>&1; then
      SERVICE_VM_DETECT_REASON="squid answers at ${cache_ip}:3128"
      return 0
    fi
  fi

  # utmctl reaches UTM over Apple Events, so it answers for a host where UTM is
  # RUNNING and misreports one where it is not: on a Mac that has never granted
  # Automation to this terminal the call comes back -1743, which the caution arm
  # below reads as "cannot confirm" and turns into a permanent skip of the UTM
  # upgrade. No VM executes without UTM, so an absent UTM process settles the
  # question before Apple Events are involved. Only a pgrep that RAN and said no
  # short-circuits; where pgrep is unavailable the probe below still decides.
  if command -v pgrep >/dev/null 2>&1 && ! pgrep -x UTM >/dev/null 2>&1; then
    SERVICE_VM_DETECT_REASON=""
    return 1
  fi

  command -v utmctl >/dev/null 2>&1 || { SERVICE_VM_DETECT_REASON=""; return 1; }
  local vm status
  for vm in "${YURUNA_SERVICE_VM_NAME[@]}"; do
    status=$(utmctl status "$vm" 2>&1 || true)
    case "$status" in
      started|paused|suspended)
        SERVICE_VM_DETECT_REASON="utmctl reports $vm '$status'"
        return 0 ;;
      *OSStatus*|*"-1743"*|*"Apple Event"*|*"does not work from SSH"*)
        SERVICE_VM_DETECT_REASON="utmctl could not reach UTM (Apple Events denied) -- cannot confirm service VM state; preserving out of caution"
        return 0 ;;
      stopped|*"not found"*|"")
        ;;
      *)
        SERVICE_VM_DETECT_REASON="utmctl status for $vm returned an unrecognized result ('$status'); preserving out of caution"
        return 0 ;;
    esac
  done
  SERVICE_VM_DETECT_REASON=""
  return 1
}

PRESERVE_SERVICE_VM=0
if is_service_vm_running; then
  warn "A Yuruna service VM is running (or its state is uncertain): $SERVICE_VM_DETECT_REASON."
  warn "  Skipping UTM quit + UTM cask upgrade for this run. Quitting UTM would suspend"
  warn "  every running service VM -- guests that consume the caching proxy, the stash"
  warn "  service or pool-control then fail -- and it would also let the orphaned-bundle"
  warn "  sweep delete the cache VM's multi-GB squid spool. To upgrade UTM later: stop"
  warn "  the services (pwsh test/service/Stop-CachingProxyServiceVM.ps1, test/service/Stop-StashServiceVM.ps1)"
  warn "  or quit UTM manually, then re-run this installer."
  PRESERVE_SERVICE_VM=1
fi

log "Stopping anything that would block a repo update (runner + status service; VMs preserved)"
stop_yuruna_processes
if [[ $PRESERVE_SERVICE_VM -eq 0 ]]; then
  quit_mac_app "UTM"
fi

# --- REGION: Install platform packages
# `brew ... | grep -v <noise>` reports GREP's exit status, not brew's, and grep
# exits 1 when it filters away every line -- so the `|| true` that keeps a
# fully-filtered SUCCESS from killing the script under `set -e` also discards
# brew's verdict and brew's error text along with it. A cask that failed then
# reads in the terminal and in the install log exactly like one that worked.
# Capture instead: brew's status is read directly, and its output is replayed in
# full when it fails and filtered only when it did not.
brew_run() {
  local what="$1"; shift
  local out status=0
  out="$(brew "$@" 2>&1)" || status=$?
  if (( status != 0 )); then
    warn "brew $* failed (exit $status) while $what:"
    [[ -n "$out" ]] && printf '%s\n' "$out" | sed 's/^/     /' >&2
    return "$status"
  fi
  # `|| true` here discards GREP's verdict only -- brew's is already captured
  # and acted on above. It is still needed: grep exits 1 when every line it was
  # given is noise, which under `set -e` would kill the installer on the most
  # ordinary outcome there is, an up-to-date package.
  if [[ -n "$out" ]]; then
    printf '%s\n' "$out" | grep -vE "already installed|up-to-date" || true
  fi
  return 0
}

brew_ensure_formula() {
  local name="$1"
  if brew list --formula --versions "$name" >/dev/null 2>&1; then
    log "  upgrading $name (formula, if outdated)"
    # A failed UPGRADE is reported but not fatal: the installed version is still
    # on the box, and everything this script hard-requires is verified below by
    # running the tool rather than by trusting the package manager.
    brew_run "upgrading the $name formula" upgrade --formula "$name" \
      || note_issue "Homebrew could not upgrade the '$name' formula; the version already on this machine is what the rest of the install used."
  else
    log "  installing $name (formula)"
    brew_run "installing the $name formula" install --formula "$name"
  fi
}

brew_ensure_cask() {
  local name="$1" appPath="${2:-}"
  if brew list --cask --versions "$name" >/dev/null 2>&1; then
    # A brew receipt is not an app. An operator who dragged the bundle to the
    # Trash, or an upgrade that died between removing the old bundle and
    # unpacking the new one, leaves the receipt behind -- and `brew upgrade` on
    # a cask brew already believes is current then does nothing at all, so the
    # step "succeeds" against an application that is not on the disk.
    if [[ -n "$appPath" && ! -d "$appPath" ]]; then
      warn "  $name is recorded as installed but $appPath is missing -- reinstalling the cask"
      brew_run "reinstalling the $name cask" reinstall --cask "$name"
      return
    fi
    log "  upgrading $name (cask, if outdated)"
    brew_run "upgrading the $name cask" upgrade --cask "$name" \
      || note_issue "Homebrew could not upgrade the '$name' cask; the version already on this machine is what the rest of the install used."
    return 0
  fi
  if [[ -n "$appPath" && -d "$appPath" ]]; then
    log "  $name already present at $appPath (installed outside brew) -- skipping"
    return 0
  fi
  log "  installing $name (cask)"
  brew_run "installing the $name cask" install --cask "$name"
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
if [[ ${PRESERVE_SERVICE_VM:-0} -eq 1 ]]; then
  log "  skipping UTM cask upgrade -- a service VM is running, UTM cannot be quit"
else
  # Not fatal here on purpose: the UTM verification region below decides, and it
  # can say what is actually wrong with the end state instead of relaying a
  # package-manager exit code. brew_run has already printed brew's own output.
  brew_ensure_cask utm "/Applications/UTM.app" || note_issue "The UTM cask step did not succeed -- the verification below says whether the installed UTM is still usable."
fi

if ! command -v pwsh >/dev/null 2>&1; then
  log "  installing PowerShell (cask fallback)"
  brew install --cask powershell
fi

# --- REGION: .NET runtime location for a framework-dependent PowerShell
# The Homebrew powershell FORMULA depends on brew's dotnet and finds its runtime
# through DOTNET_ROOT, exported by the wrapper on PATH. Any pwsh started WITHOUT
# that environment -- notably a nested `sudo pwsh`, whose env_reset strips it --
# then fails to locate libhostfxr and exits 131 before running a line of script.
# /etc/dotnet/install_location_<arch> is the runtime's own machine-wide fallback,
# read no matter who starts pwsh or with what environment, so writing it once
# here removes the whole class instead of guarding each call site. Harmless for a
# cask/.pkg PowerShell, which is self-contained and never consults it.
if command -v pwsh >/dev/null 2>&1 && dotnet_libexec="$(brew --prefix dotnet 2>/dev/null)/libexec" \
   && [[ -d "$dotnet_libexec" ]]; then
  dotnet_location_file="/etc/dotnet/install_location_$(uname -m)"
  if [[ "$(cat "$dotnet_location_file" 2>/dev/null)" != "$dotnet_libexec" ]]; then
    log "Recording the .NET runtime location at $dotnet_location_file"
    sudo mkdir -p /etc/dotnet
    printf '%s\n' "$dotnet_libexec" | sudo tee "$dotnet_location_file" >/dev/null
  fi
fi

log "Running brew cleanup"
brew cleanup --quiet || true

command -v pwsh >/dev/null 2>&1 || die "pwsh not found after install."
command -v git  >/dev/null 2>&1 || die "git not found after install."

# --- REGION: UTM verification + utmctl on PATH
# UTM ships its command line INSIDE the app bundle, and neither the cask nor the
# .dmg puts that directory on anyone's PATH. Every VM operation in the harness
# shells out to `utmctl`, so without the link a perfectly correct UTM install
# finishes clean here and the FIRST test cycle refuses to start on a config
# gate -- with the failure pointing at the harness rather than at the install
# that left the binary unreachable.
#
# PATH_LINK_DIR is the target because the stock /etc/paths lists it, so a login
# shell, a LaunchAgent and an `ssh host command` all see it. Homebrew's bin only
# reaches shells that ran `brew shellenv`, which the status service and the
# runner's own children do not.
UTM_APP="/Applications/UTM.app"
UTMCTL_BUNDLE="$UTM_APP/Contents/MacOS/utmctl"
UTMCTL_LINK="$PATH_LINK_DIR/utmctl"
UTMCTL_LINK_DIR="$PATH_LINK_DIR"

[[ -d "$UTM_APP" ]] || die "UTM is not installed at $UTM_APP -- every VM operation needs it, so this install is not usable.
   Look for a 'brew ... failed' block earlier in this run (also in $YURUNA_INSTALL_LOG), then:
       brew install --cask utm
   or install it from https://mac.getutm.app. Re-run this installer afterwards."

[[ -x "$UTMCTL_BUNDLE" ]] || die "UTM is installed at $UTM_APP but the bundle does not carry $UTMCTL_BUNDLE, so the install is incomplete.
   Repair it with:
       brew reinstall --cask utm
   then re-run this installer."

if [[ "$(readlink "$UTMCTL_LINK" 2>/dev/null || true)" == "$UTMCTL_BUNDLE" ]]; then
  log "utmctl already on PATH: $UTMCTL_LINK -> $UTMCTL_BUNDLE"
else
  log "Linking utmctl onto PATH: $UTMCTL_LINK -> $UTMCTL_BUNDLE"
  # -sfn, not -sf: with a plain -sf, a target that is already a symlink to a
  # DIRECTORY makes ln create the new link INSIDE it rather than replacing it.
  sudo mkdir -p "$UTMCTL_LINK_DIR" && sudo ln -sfn "$UTMCTL_BUNDLE" "$UTMCTL_LINK" \
    || die "Could not create $UTMCTL_LINK. Run it by hand and re-run this installer:
       sudo mkdir -p $UTMCTL_LINK_DIR && sudo ln -sfn $UTMCTL_BUNDLE $UTMCTL_LINK"
fi

hash -r 2>/dev/null || true
command -v utmctl >/dev/null 2>&1 || die "$UTMCTL_LINK exists, but 'utmctl' still does not resolve by name -- $UTMCTL_LINK_DIR is not on this shell's PATH.
   The stock macOS /etc/paths lists that directory, so a shell profile here is REPLACING PATH instead of adding to it. Fix the profile, open a new terminal, and re-run this installer.
   PATH seen by this run: $PATH"

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
            Write-Warning "  Invoke-TestProject.ps1 will refuse to run until this is fixed."
            Write-Warning "  Try manually: pwsh -Command ''Install-Module powershell-yaml -Scope CurrentUser''"
            exit 1
        }
    }
' || note_issue "Installing the powershell-yaml module reported an error; the harness needs it to read any YAML config. Retry with: pwsh -Command 'Install-Module powershell-yaml -Scope CurrentUser'"

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
# --- REGION: https://yuruna.link/install/explained#tolerating-a-v-prefixed-tag-ref
# Echoes the ref on stdout; warn -> stderr, so a warning never pollutes the
# captured stdout used to set YURUNA_BRANCH.
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
# --- REGION: https://yuruna.link/install/explained#development-repo-tracks-latest-main
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
      warn "========"
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
      warn "========"
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
# --- REGION: https://yuruna.link/install/explained#release-pinning--signed-integrity
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

# --- REGION: Version floors: bring the managed tools up to them
# The floors live in automation/Yuruna.Requirement.yml -- the same file the
# requirement report and the diagnostic read, so a floor is written down once.
# Only the tools this script is responsible for are checked; reporting on a
# cloud CLI the bootstrapper never touches would bury a real problem in a dozen
# expected absences.
#
# Repaired here, not merely reported. An operator who is asked to fix a version
# by hand at the end of an installer that had root for the whole run is being
# asked to do the installer's job, and the two things that put a Mac below a
# floor are both mechanical:
#
#   * Homebrew keeps some formulae keg-only (curl among them) -- installed under
#     $(brew --prefix <formula>) and deliberately NOT linked, so the name keeps
#     resolving to Apple's copy, which never advances past what shipped with the
#     OS. `brew install curl` alone changes nothing that `curl --version` says.
#   * A tool installed twice (Microsoft's PowerShell .pkg or cask alongside the
#     Homebrew formula) resolves to whichever directory comes first on PATH, and
#     that can be the older of the two. `brew upgrade` then reports success, run
#     after run, on a keg nothing actually runs.
#
# Every floor is judged on what the tool prints when it is invoked BY NAME, so
# both shapes are repaired the same way: find the newest copy this Mac carries
# and make the name resolve to it, through PATH_LINK_DIR for the reason utmctl
# uses it -- the stock /etc/paths lists that directory, so the runner, the
# status service and an `ssh host command` all see the same tool, where
# $(brew --prefix)/bin reaches only shells that ran `brew shellenv`.
#
# Never fatal: a machine that is merely behind still installs, and the closing
# summary carries whatever the repair passes could not reach. What must not
# happen is finishing SILENTLY below a floor -- that is how a host ran for weeks
# on a PowerShell too old to do the crypto every lab enrollment needs, and
# surfaced it as a rejected Lab token.
FLOOR_TOOL_LIST="PowerShell,git,qemu-img,wget,tesseract,curl"

# The version a binary reports when asked directly. Every managed tool answers
# `--version` within its first lines and the first dotted number token is the
# version. A binary that cannot run -- a framework-dependent pwsh with no .NET
# runtime, a half-removed keg -- prints nothing, and that empty answer is what
# keeps it from being promoted below.
tool_version() {
  local bin="$1"
  [[ -n "$bin" && -x "$bin" ]] || return 1
  "$bin" --version 2>/dev/null | head -3 | grep -oE '[0-9]+(\.[0-9]+){1,3}' | head -1
}

# A >= B, field by field as numbers. 8.21.0 is newer than 8.7.1, which both a
# string compare and a float compare get backwards -- and that pair is exactly
# the curl floor this installer is judged on.
version_ge() {
  [[ -n "$1" ]] || return 1
  [[ -n "$2" ]] || return 0
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | head -1)" == "$2" ]]
}

# The binary a Homebrew formula provides, whether or not brew linked it: a
# keg-only formula is installed and unlinked BY DESIGN, so `command -v` is not
# the question to ask about it.
brew_formula_binary() {
  local formula="$1" cmd="$2" prefix
  prefix="$(brew --prefix --installed "$formula" 2>/dev/null || true)"
  [[ -n "$prefix" && -x "$prefix/bin/$cmd" ]] || return 1
  printf '%s\n' "$prefix/bin/$cmd"
}

# A pin is a deliberate "hold this version", and it is also the one state in
# which `brew upgrade` reports success while changing nothing. Lifted only for a
# formula whose version is already failing a floor, and said out loud.
brew_unpin_if_pinned() {
  local formula="$1"
  brew list --pinned 2>/dev/null | grep -qx "$formula" || return 0
  log "  unpinning the '$formula' formula -- a pin is why 'brew upgrade' left it where it was"
  brew unpin "$formula" >/dev/null 2>&1 || warn "  could not unpin '$formula'"
}

# Make `<cmd>` resolve to the newest copy this Mac carries. Extra arguments are
# install locations no package manager reports (Microsoft's PowerShell .pkg
# lands outside every Homebrew prefix).
prefer_newest_binary() {
  local cmd="$1" formula="$2"; shift 2
  local link="$PATH_LINK_DIR/$cmd"
  local current="" current_ver="" best="" best_ver="" cand cand_ver
  local brew_bin="" brew_link keep now now_ver

  current="$(command -v "$cmd" 2>/dev/null || true)"
  brew_bin="$(brew_formula_binary "$formula" "$cmd" || true)"
  [[ -n "$current" ]] && current_ver="$(tool_version "$current" || true)"

  for cand in "$current" "$brew_bin" "$link" "$@"; do
    [[ -n "$cand" ]] || continue
    cand_ver="$(tool_version "$cand" || true)"
    [[ -n "$cand_ver" ]] || continue
    if [[ -z "$best_ver" ]] || ! version_ge "$best_ver" "$cand_ver"; then
      best="$cand"; best_ver="$cand_ver"
    fi
  done
  if [[ -z "$best" ]]; then
    warn "  no runnable '$cmd' to promote -- nothing on this Mac answers --version"
    return 1
  fi
  if [[ -n "$current_ver" ]] && version_ge "$current_ver" "$best_ver"; then
    log "  '$cmd' already resolves to the newest copy here: $current_ver ($current)"
    return 0
  fi

  log "  '$cmd' resolves to ${current_ver:-nothing} (${current:-not on PATH}); this Mac carries $best_ver at $best"
  if [[ "$best" != "$link" && "$(readlink "$link" 2>/dev/null || true)" != "$best" ]]; then
    if [[ -e "$link" && ! -L "$link" ]]; then
      # A real binary someone put there is not this installer's to delete, and
      # a timestamped neighbor is a state the operator can walk back from.
      keep="$link.pre-yuruna.$(date +%Y%m%d-%H%M%S)"
      warn "  $link is a real file rather than a link -- keeping it as $keep"
      sudo mv "$link" "$keep" \
        || { note_issue "Could not move $link aside, so '$cmd' still resolves to ${current_ver:-nothing}. Move it by hand and re-run this installer."; return 1; }
    fi
    log "  linking $cmd $best_ver onto PATH: $link -> $best"
    # -sfn, not -sf: with a plain -sf, a target that is already a symlink to a
    # DIRECTORY makes ln create the new link INSIDE it rather than replacing it.
    sudo mkdir -p "$PATH_LINK_DIR" && sudo ln -sfn "$best" "$link" \
      || { note_issue "Could not create $link, so '$cmd' still resolves to ${current_ver:-nothing}. Run 'sudo ln -sfn $best $link' and re-run this installer."; return 1; }
  fi

  # A Homebrew-linked copy that is OLDER than the best one keeps winning
  # whatever the link above says: `brew shellenv` puts $(brew --prefix)/bin
  # ahead of /usr/local/bin. Unlinking leaves the keg installed -- `brew link`
  # puts it back -- and is the only way the newer copy becomes reachable by name
  # in this shell as well as in the ones that never ran shellenv.
  if [[ -n "$brew_bin" && "$brew_bin" != "$best" ]]; then
    brew_link="$(brew --prefix)/bin/$cmd"
    if [[ -e "$brew_link" || -L "$brew_link" ]]; then
      log "  unlinking Homebrew's '$formula': its $cmd is older than $best_ver and sits ahead of $link on PATH"
      brew unlink "$formula" >/dev/null 2>&1 || warn "  could not unlink '$formula'"
    fi
  fi

  hash -r 2>/dev/null || true
  now="$(command -v "$cmd" 2>/dev/null || true)"
  now_ver=""
  [[ -n "$now" ]] && now_ver="$(tool_version "$now" || true)"
  log "  '$cmd' now resolves to ${now_ver:-nothing} (${now:-not on PATH})"
}

repair_brew_tool() {
  local cmd="$1" formula="$2"
  log "  repairing '$cmd' through the '$formula' formula"
  brew_unpin_if_pinned "$formula"
  brew_ensure_formula "$formula"
  prefer_newest_binary "$cmd" "$formula"
}

# PowerShell ships two ways and they advance independently: the Homebrew formula
# (framework-dependent, built on brew's dotnet) and Microsoft's own build, which
# Homebrew delivers as a cask. Whichever is installed gets upgraded first; if
# that still leaves this Mac short, the other one is added on the second pass.
# Both may end up installed -- harmless, because the promotion decides which one
# the NAME resolves to, and that is the only copy anything here runs.
repair_powershell() {
  local round="$1" have_formula=0
  if brew list --formula --versions powershell >/dev/null 2>&1; then have_formula=1; fi
  log "  repairing 'pwsh' (Homebrew formula installed: $have_formula, repair pass $round)"
  brew_unpin_if_pinned powershell
  if (( have_formula )); then
    brew_ensure_formula powershell
  fi
  if (( round >= 2 )) || (( have_formula == 0 )); then
    brew_ensure_cask powershell
  fi
  # Microsoft's .pkg installs outside every Homebrew prefix and is invisible to
  # `brew --prefix`, so its location is named here.
  prefer_newest_binary pwsh powershell /usr/local/microsoft/powershell/7/pwsh
}

# Which repair a requirement line asks for. The report names the tool first.
# AES-GCM is a property of the PowerShell runtime rather than a tool of its own,
# so it repairs as PowerShell -- and disappears with it.
requirement_repair_key() {
  case "$1" in
    PowerShell*|AES-GCM*) printf 'powershell\n' ;;
    curl*)                printf 'curl\n' ;;
    git*)                 printf 'git\n' ;;
    wget*)                printf 'wget\n' ;;
    tesseract*)           printf 'tesseract\n' ;;
    qemu-img*)            printf 'qemu-img\n' ;;
    *) return 1 ;;
  esac
}

# The command name a repair key is judged on, for the closing report.
requirement_key_command() {
  case "$1" in
    powershell) printf 'pwsh\n' ;;
    *)          printf '%s\n' "$1" ;;
  esac
}

run_requirement_repair() {
  local key="$1" round="$2"
  case "$key" in
    powershell) repair_powershell "$round" ;;
    curl)       repair_brew_tool curl curl ;;
    git)        repair_brew_tool git git ;;
    wget)       repair_brew_tool wget wget ;;
    tesseract)  repair_brew_tool tesseract tesseract ;;
    qemu-img)   repair_brew_tool qemu-img qemu ;;
    *) return 1 ;;
  esac
}

requirement_issue_line() {
  pwsh -NoProfile -File "$YURUNA_DIR/automation/Test-Requirement.ps1" \
       -Tool "$FLOOR_TOOL_LIST" -WarnOnly 2>/dev/null \
    | sed -n 's/^REQUIREMENT-ISSUE: //p'
}

# Check, repair, check again. Arrays stay global rather than `local`: the bash
# macOS ships as /bin/bash is 3.2, where a local array declaration is a syntax
# error, and this function is called once.
bring_tools_to_required_versions() {
  log "Checking installed versions against the required floors"
  floor_round=0
  floor_issues=()
  # Two repair passes, then report. The second exists for the one escalation
  # that needs a first attempt to have failed (adding the other PowerShell
  # build); a third would only repeat the second against a floor no build on
  # this Mac can reach, which is the operator's to decide about, not this
  # script's to loop on.
  while :; do
    floor_issues=()
    while IFS= read -r floor_line; do
      [[ -n "$floor_line" ]] && floor_issues+=("$floor_line")
    done < <(requirement_issue_line)
    if (( ${#floor_issues[@]} == 0 )); then
      log "  every managed tool meets its required version"
      break
    fi
    if (( floor_round >= 2 )); then break; fi
    floor_round=$(( floor_round + 1 ))
    log "Bringing ${#floor_issues[@]} tool(s) up to the required versions (pass $floor_round)"
    floor_keys=()
    for floor_line in "${floor_issues[@]}"; do
      floor_key="$(requirement_repair_key "$floor_line" || true)"
      [[ -n "$floor_key" ]] || continue
      case " ${floor_keys[*]:-} " in *" $floor_key "*) continue ;; esac
      floor_keys+=("$floor_key")
    done
    if (( ${#floor_keys[@]} == 0 )); then break; fi
    for floor_key in "${floor_keys[@]}"; do
      run_requirement_repair "$floor_key" "$floor_round" || true
    done
    hash -r 2>/dev/null || true
  done
  # What survived two repair passes. The binary each name resolves to is named
  # with it: a floor no package on this Mac can reach and a newer copy that
  # something ahead on PATH is hiding read identically without it.
  if (( ${#floor_issues[@]} > 0 )); then
    for floor_line in "${floor_issues[@]}"; do
      floor_key="$(requirement_repair_key "$floor_line" || true)"
      floor_note=""
      if [[ -n "$floor_key" ]]; then
        floor_cmd="$(requirement_key_command "$floor_key")"
        floor_bin="$(command -v "$floor_cmd" 2>/dev/null || true)"
        if [[ -n "$floor_bin" ]]; then
          floor_note=" ('$floor_cmd' resolves to $floor_bin after the repair passes)"
        fi
      fi
      note_issue "$floor_line$floor_note"
    done
  fi
}

if command -v pwsh >/dev/null 2>&1 && [[ -f "$YURUNA_DIR/automation/Test-Requirement.ps1" ]]; then
  bring_tools_to_required_versions
fi

# --- REGION: Enable-TestAutomation.ps1 hint
HOST_SETUP="$YURUNA_DIR/host/macos.utm/Enable-TestAutomation.ps1"
log ""
log "Host configuration (test-host setup) is NOT auto-applied. It is REQUIRED"
log "before Start-TestRunner: the pre-cycle gate refuses a host whose display"
log "sleep, screen lock or TCC grants are not in place. Run:"
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

  5. Enable this machine as a test host. REQUIRED before step 6 if this Mac
     will run Start-TestRunner -- it disables display sleep, auto-logout and
     screen lock (so VM screen captures stay readable), keeps utmctl on PATH,
     and requests the TCC grants. The cycle gate refuses to start without it.
     Skip it only on a Mac that will never run the runner:
       pwsh $YURUNA_DIR/host/macos.utm/Enable-TestAutomation.ps1

  6. Confirm the host is ready. This is the same gate Start-TestRunner runs
     before every cycle, and it names each thing that is missing plus the
     command that fixes it:
       pwsh $TEST_DIR/Test-Config.ps1

  7. Run the test runner:
       cd $TEST_DIR && pwsh ./Start-TestRunner.ps1

  8. (Optional, one-time) Authenticate the GitHub CLI so 'gh' can act on
     your behalf -- the installer installs the binary, but authentication
     requires an interactive web-or-token flow you have to drive:
       gh auth login

If Start-TestRunner reports "Pre-cycle config gate FAILED", run step 6: every
FAILURE it prints carries its own remediation command. The two that block a
fresh Mac most often are utmctl not being on PATH (this installer linked
$UTMCTL_LINK; re-create it with
'sudo mkdir -p $UTMCTL_LINK_DIR && sudo ln -sfn $UTMCTL_BUNDLE $UTMCTL_LINK')
and the host settings from step 5 not having been applied.

Re-running this installer is safe; it will update Homebrew packages and
fast-forward the Yuruna checkout when possible.
EOF

# --- REGION: Backup notice
if [[ -n "$YURUNA_BACKUP_CREATED" ]]; then
  warn ""
  warn "========"
  warn "IMPORTANT: a backup of your previous Yuruna checkout was created"
  warn "  because 'git pull --ff-only' could not advance the local repo."
  warn ""
  warn "  Backup location: $YURUNA_BACKUP_CREATED"
  warn ""
  warn "Review the backup for any local edits you want to preserve."
  warn "When you no longer need it, delete it manually:"
  warn "  rm -rf '$YURUNA_BACKUP_CREATED'"
  warn "========"
fi

# --- REGION: Install summary
# The last thing printed. Everything above scrolls; this does not.
if [[ ${#YURUNA_ISSUES[@]} -gt 0 ]]; then
  warn ""
  warn "========"
  warn "INSTALL FINISHED WITH ${#YURUNA_ISSUES[@]} ISSUE(S)"
  warn ""
  for issue in "${YURUNA_ISSUES[@]}"; do
    warn "  - $issue"
  done
  warn ""
  warn "The install completed and the machine is usable. Each line above is"
  warn "something that did not happen as intended -- re-running this installer"
  warn "is safe and retries every one of them."
  warn "========"
else
  log ""
  log "Install finished with no issues."
fi
