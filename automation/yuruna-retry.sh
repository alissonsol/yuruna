#!/bin/bash
# Version: 2026.09.30
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Single source of truth for retry wrappers used by guest provisioning
# scripts. Sourced via /usr/local/lib/yuruna/yuruna-retry.sh after
# cloud-init deploys this file at install time.
#
# --- REGION: https://yuruna.link/4220a755-0003
# Capability marker for the callers that ask for a wall-clock stall bound.
# Setting one is only safe against a lib that wraps with `timeout --foreground`
# hoisted INSIDE sudo: without --foreground the bounded command is stopped by
# SIGTTIN/SIGTTOU the moment it touches the console tty (the background-pgrp
# tty-stop trap), and without the hoist the signal lands on sudo instead of the
# tool. This file does both, so a caller that sees this marker may request a
# bound; one that does not see it is sourcing an older baked copy and must stay
# unbounded. Gating on the marker rather than on a version string means guests
# self-select as images roll over, with no dated "safe after" rule to maintain.
export YURUNA_RETRY_LIB_SAFE_STALL=1

# Writes one structured record to stderr and, when YURUNA_RETRY_RECORD names a
# file, appends it there too.
#
# The wrapper's own diagnostics go to the CALLER's stderr, while the log a
# wrapped attempt writes is opened around the attempt alone. So a consumer
# reading that log sees the attempt's output and nothing the wrapper decided --
# no attempt count, no classification, no outcome. Naming the file here is what
# puts the verdict where the log's reader already looks, instead of leaving them
# to recognize a sentence that never arrives.
#
# Best effort: a record that cannot be written must never fail the run it is
# only describing.
_yuruna_retry_record() {
    echo "YURUNA_RETRY $1" >&2
    if [ -n "${YURUNA_RETRY_RECORD:-}" ]; then
        echo "YURUNA_RETRY $1" >>"${YURUNA_RETRY_RECORD}" 2>/dev/null || true
    fi
}

# --- REGION: Retry configuration
# Match the PowerShell retry defaults; invalid bounds must never skip execution.
_yuruna_retry_positive_integer() {
    local raw="$1" fallback="$2" digits=''
    if [[ "$raw" =~ ^[[:space:]]*\+?([0-9]+)[[:space:]]*$ ]]; then
        digits="${BASH_REMATCH[1]}"
        digits="${digits#"${digits%%[!0]*}"}"
        if [ -n "$digits" ] && [ "${#digits}" -le 10 ] \
            && [ "$((10#$digits))" -le 2147483647 ]; then
            printf '%s' "$((10#$digits))"
            return 0
        fi
    fi
    printf '%s' "$fallback"
}

# --- REGION: Retry execution
_yuruna_retry() {
    local label="$1"; shift
    local max_attempts delay
    max_attempts=$(_yuruna_retry_positive_integer "${YURUNA_RETRY_MAX_ATTEMPTS:-}" 5)
    delay=$(_yuruna_retry_positive_integer "${YURUNA_RETRY_DELAY_SECONDS:-}" 10)
    local stall="${YURUNA_RETRY_STALL_TIMEOUT_SECONDS:-0}"
    local attempt=1 rc=0
    # Diagnostics go to stderr, never stdout: these wrappers are routinely
    # used in `curl_retry ... | bash` / `wget_try ... | bash` pipelines, where
    # a retry's progress line on stdout would be fed to the interpreter as
    # script text and corrupt the install. The fetch-and-execute log captures
    # 2>&1, so the operator still sees every attempt.
    #
    # Per-attempt wall-clock bound (YURUNA_RETRY_STALL_TIMEOUT_SECONDS, whole
    # seconds; 0 = unbounded) so a stalled or trickling transfer fails into
    # the retry ladder; a malformed value fails LOUD and unbounded.
    # --- REGION: https://yuruna.link/4220a755-0004
    case "$stall" in
        ''|*[!0-9]*)
            echo "!! ${label}: YURUNA_RETRY_STALL_TIMEOUT_SECONDS='$stall' is not a whole number of seconds; running unbounded" >&2
            stall=0
            ;;
    esac
    # bound_mode is invariant across attempts: none | direct | sudo.
    # timeout(1) only execs real commands (shell functions run unbounded);
    # a plain `sudo <tool> ...` hoists the bound INSIDE sudo, and
    # --foreground is load-bearing (background-pgrp tty-stop trap class).
    # --- REGION: https://yuruna.link/4220a755-0004
    local bound_mode=none
    if [ "$stall" -gt 0 ] \
        && [ "$(type -t "$1")" != "function" ] \
        && command -v timeout >/dev/null 2>&1; then
        bound_mode=direct
        if [ "$1" = "sudo" ]; then
            case "${2:-}" in
                ''|-*) : ;;
                *) bound_mode=sudo ;;
            esac
        fi
    fi
    while [ "$attempt" -le "$max_attempts" ]; do
        if [ "$attempt" -gt 1 ]; then
            echo "" >&2
            echo ">> ${label}: attempt $attempt/$max_attempts for: $*" >&2
        fi
        rc=0
        case "$bound_mode" in
            sudo)   sudo timeout --foreground --kill-after=30 "$stall" "${@:2}" || rc=$? ;;
            direct) timeout --foreground --kill-after=30 "$stall" "$@" || rc=$? ;;
            *)      "$@" || rc=$? ;;
        esac
        if [ "$rc" -eq 0 ]; then return 0; fi
        # timeout(1) exits 124 on TERM-expiry, 137 when the KILL backstop fired.
        if [ "$bound_mode" != "none" ] && { [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; }; then
            echo "!! ${label}: attempt $attempt/$max_attempts stalled; killed by the ${stall}s per-attempt bound (rc=$rc): $*" >&2
        else
            echo "!! ${label}: attempt $attempt/$max_attempts failed (rc=$rc): $*" >&2
        fi
        # Transient/permanent gate (opt-in via YURUNA_RETRY_CLASSIFY = a function
        # name): stop the ladder immediately on a classified-PERMANENT failure --
        # a deterministic HTTP 404, a malformed URL -- instead of burning the
        # whole budget (minutes of exponential backoff) on something that cannot
        # succeed. Conservative by contract: the classifier returns non-zero ONLY
        # for a clearly permanent cause; any ambiguity keeps retrying, so a
        # healthy fetch is never turned into a hard failure by a misclassification.
        # Classify ONCE (the curl/wget gate may re-probe the HTTP status) and
        # record the verdict in the structured marker below.
        local permanent=false
        if [ -n "${YURUNA_RETRY_CLASSIFY:-}" ] && ! "$YURUNA_RETRY_CLASSIFY" "$rc"; then permanent=true; fi
        # Structured machine-readable attempt record. A consumer greps
        # YURUNA_RETRY lines; on the SSH verbs the host parses them into the
        # cycle NDJSON stream (the console/OCR path keeps the guest log local).
        # Only safe scalar fields (label is a fixed wrapper name, the rest are
        # ints/bools) so the JSON never needs escaping. On stderr like every
        # other diagnostic here -- stdout stays clean for `... | bash` pipelines.
        _yuruna_retry_record "{\"stack\":\"bash\",\"label\":\"${label}\",\"event\":\"attempt\",\"attempt\":${attempt},\"maxAttempts\":${max_attempts},\"rc\":${rc},\"permanent\":${permanent}}"
        if [ "$permanent" = true ]; then
            _yuruna_retry_record "{\"stack\":\"bash\",\"label\":\"${label}\",\"event\":\"outcome\",\"outcome\":\"permanent\",\"attempt\":${attempt},\"maxAttempts\":${max_attempts},\"rc\":${rc}}"
            echo "!! ${label}: PERMANENT failure (rc=$rc, not retryable) -- not spending the remaining $((max_attempts - attempt)) attempt(s): $*" >&2
            return "$rc"
        fi
        if [ "$attempt" -lt "$max_attempts" ]; then
            # Best-effort repair before the retry (YURUNA_RETRY_HEAL): a
            # bounded attempt can be killed mid-transaction, leaving state
            # the plain re-run would refuse to touch (dpkg's "interrupted,
            # run dpkg --configure -a" latch). Run on every failure kind,
            # not just stall-kills: the latch can also predate this loop,
            # and clearing it is what lets the retry succeed. Skipped after
            # the final attempt, where no retry can benefit.
            if [ -n "${YURUNA_RETRY_HEAL:-}" ]; then
                bash -c "$YURUNA_RETRY_HEAL" >/dev/null 2>&1 || true
            fi
            # Equal jitter: sleep a random point in [delay/2, delay] instead of
            # exactly delay, so parallel guests that failed in lock-step (a shared
            # proxy blip, a mirror 429 burst) don't all wake and retry on the same
            # instant and re-form the thundering herd that caused the failure.
            # Bounded by the base delay, so it never adds wall-clock over the old
            # fixed sleep. $RANDOM is a bash builtin (this lib is bash-only).
            local half=$(( delay / 2 ))
            local nap=$(( half + (RANDOM % (half + 1)) ))
            [ "$nap" -lt 1 ] && nap=1
            echo "!! ${label}: sleeping ${nap}s before retry (backoff ${delay}s, jittered)" >&2
            sleep "$nap"
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done
    _yuruna_retry_record "{\"stack\":\"bash\",\"label\":\"${label}\",\"event\":\"outcome\",\"outcome\":\"exhausted\",\"attempt\":${max_attempts},\"maxAttempts\":${max_attempts},\"rc\":${rc}}"
    echo "!! ${label}: all $max_attempts attempts exhausted for: $*" >&2
    return "$rc"
}

# Package-manager attempts run UNBOUNDED by default (opt in via
# YURUNA_APT_STALL_TIMEOUT_SECONDS / YURUNA_DNF_STALL_TIMEOUT_SECONDS, seconds): wrapping
# apt in timeout(1) is the wrapped-apt teardown-hang trap class, so the
# mirror-stall exposure is bounded at the transfer layer instead.
#
# Every attempt is forced non-interactive HERE rather than by an ambient export
# in the calling script, because an export does not survive the trip: sudo
# resets the environment to whatever env_keep lists, and neither of these
# variables is on that list, so `export DEBIAN_FRONTEND=noninteractive; sudo
# apt-get ...` reaches apt with the frontend unset. What that costs is not a
# visible error. These guests are driven by OCR of a console, so a debconf
# question is a HANG: dpkg-preconfigure blocks on a read nothing will answer
# while holding /var/lib/dpkg/lock-frontend, and because stdout here is a pipe
# the question itself never flushes -- the console freezes on the last line
# apt printed and the step spends its entire timeout with no prompt on screen
# to explain why. Unbounded attempts (above) make that the full budget.
#
# `env` rather than a bare VAR=value word for two reasons: it sets the
# variables in the child regardless of sudoers policy, and it stays a real
# command, so the stall bound can still hoist timeout(1) inside sudo --
# timeout execs its argument and cannot exec an assignment, while env execs
# the tool in the same PID, leaving the signal target unchanged.
# DEBIAN_PRIORITY is the belt to that brace, for a config script that consults
# the priority directly instead of the frontend. The heal command gets the
# same treatment: `dpkg --configure -a` runs the postinst scripts, so it can
# block on the identical question it was invoked to clear.
# --- REGION: https://yuruna.link/4220a755-0005
apt_retry() {
    local -a cmd=()
    if [ "${1:-}" = "sudo" ]; then
        cmd+=("$1"); shift
    fi
    cmd+=(env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical "$@")
    YURUNA_RETRY_STALL_TIMEOUT_SECONDS="${YURUNA_APT_STALL_TIMEOUT_SECONDS:-0}" \
    YURUNA_RETRY_HEAL='sudo env DEBIAN_FRONTEND=noninteractive DEBIAN_PRIORITY=critical dpkg --configure -a' \
        _yuruna_retry apt_retry "${cmd[@]}"
}
dnf_retry() {
    YURUNA_RETRY_STALL_TIMEOUT_SECONDS="${YURUNA_DNF_STALL_TIMEOUT_SECONDS:-0}" \
        _yuruna_retry dnf_retry "$@"
}

# --- REGION: https://yuruna.link/4220a755-0003
# Shared HTTP-status classifier for the curl/wget gates. curl -f (exit 22) and
# wget (exit 8) both collapse EVERY HTTP error to one exit code -- a 404 and a
# 503 are indistinguishable at that level -- so we re-probe the status: a cheap,
# bounded, output-discarding GET that inherits the same proxy env as the real
# fetch. Re-probing (rather than adding `-w`/`-S` to the real fetch) keeps the
# code off the stdout that feeds the `... | bash` install pipelines. Returns 0
# (transient: 429 / 5xx / no-answer) or 1 (permanent: other 4xx). An empty or
# unreachable URL is treated as transient so the gate never hardens a healthy
# fetch into a failure.
_yuruna_http_status_class() {
    local url="$1"
    [ -z "$url" ] && return 0
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null)" || true
    [ -n "$code" ] || code=000
    echo "  yuruna-retry: re-probed HTTP status for ${url} = ${code}" >&2
    case "$code" in
        429|5[0-9][0-9]|000) return 0 ;;               # rate-limit / server error / no-answer -> transient
        4[0-9][0-9]) return 1 ;;                        # 404/403/401/... -> permanent (retrying cannot help)
    esac
    return 0
}

# --- REGION: https://yuruna.link/4220a755-0015
# Does bumped HTTPS verify from here? One spider request through whatever proxy
# env this shell carries; the URL is overridable so a lab with no reachable
# github.com can point it at something its cache does serve.
_yuruna_bump_trusted() {
    wget -q --spider --timeout="${YURUNA_CA_PROBE_TIMEOUT:-15}" --tries=1 \
        "${YURUNA_CA_PROBE_URL:-https://github.com/}" 2>/dev/null
}

# --- REGION: https://yuruna.link/4220a755-0015
# The ssl-bump CA is a trust anchor this guest holds a COPY of, and the copy is
# only as current as the cache that minted it: a cache rebuilt from a blank disk
# mints a fresh CA, after which every bumped HTTPS from here fails certificate
# verification and no re-run of the same bytes can recover it. The repair is to
# re-fetch the current CA from the host status service, which is reached over
# the RFC1918 plain-HTTP path the bump is not in front of.
#
# Three-way exit code, because the callers have to tell these apart:
#   0 -- repaired: the trust store changed and bumped HTTPS now verifies, so a
#        retry of whatever just failed is worth spending.
#   1 -- nothing to repair: no bump in front of this guest, or it already
#        verifies. A cert failure here is the far end's certificate, not ours.
#   2 -- tried and still untrusted: no coordinates, no usable CA served, or a
#        CA that does not match the bump.
# Diagnostics go to stderr: stdout stays clean for the `... | bash` install
# pipelines that source this lib.
# Add one PEM to the system trust store. This lib is sourced by guests of both
# the Debian and the RHEL family, which take an extra anchor in different
# directories AND re-hash the store with different commands. The two halves have
# to be chosen together -- a Debian-layout drop on a RHEL guest leaves a file
# nothing reads and reports success -- so the refresh command selects the pair.
# The extension must stay .crt: update-ca-certificates ignores every other one.
_yuruna_ca_trust() {
    if command -v update-ca-certificates >/dev/null 2>&1; then
        sudo install -d -m 0755 /usr/local/share/ca-certificates \
            && sudo install -m 0644 "$1" /usr/local/share/ca-certificates/yuruna-squid-ca.crt \
            && sudo update-ca-certificates >/dev/null 2>&1
    elif command -v update-ca-trust >/dev/null 2>&1; then
        sudo install -d -m 0755 /etc/pki/ca-trust/source/anchors \
            && sudo install -m 0644 "$1" /etc/pki/ca-trust/source/anchors/yuruna-squid-ca.crt \
            && sudo update-ca-trust extract >/dev/null 2>&1
    else
        echo "CA self-heal: no update-ca-certificates or update-ca-trust on PATH; cannot add a trust anchor here." >&2
        return 1
    fi
}

yuruna_ca_selfheal() {
    # Guard on the bump port with a boundary so a no-cache/direct guest (empty
    # https_proxy) or a proxy on some other port is a hard no-op.
    printf '%s' "${https_proxy:-}" | grep -qE ':3129/?($|[^0-9])' || return 1
    _yuruna_bump_trusted && return 1
    if [ -r /etc/yuruna/host.env ]; then
        # shellcheck disable=SC1091
        . /etc/yuruna/host.env
    fi
    if [ -z "${YURUNA_STATUS_SERVICE_IP:-}" ] || [ -z "${YURUNA_STATUS_SERVICE_PORT:-}" ]; then
        echo "CA self-heal: bump HTTPS untrusted and no host.env coordinates; cannot recover CA." >&2
        return 2
    fi
    echo "CA self-heal: bump HTTPS untrusted; fetching CA from host status service ..." >&2
    local ca_tmp rc=2
    ca_tmp=$(mktemp) || return 2
    if wget --no-proxy --timeout=10 --tries=2 -qO "$ca_tmp" \
            "http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/ca.crt" \
       && [ -s "$ca_tmp" ] && grep -q 'BEGIN CERTIFICATE' "$ca_tmp"; then
        _yuruna_ca_trust "$ca_tmp" || true
        if _yuruna_bump_trusted; then
            echo "CA self-heal: OK -- bump HTTPS now trusted." >&2
            rc=0
        else
            echo "CA self-heal: CA installed but bump still untrusted (stale/wrong CA, or cache unreachable); HTTPS through the bump will still fail." >&2
        fi
    else
        echo "CA self-heal: host status service served no usable CA (cache may still be unreachable); HTTPS through the bump will still fail." >&2
    fi
    rm -f "$ca_tmp"
    return "$rc"
}

# curl transient/permanent classifier: network / timeout codes are transient
# (retry); a malformed URL or bad usage is permanent; a certificate that will
# not verify (60) re-anchors the bump CA; an HTTP-error exit (22) re-probes the
# status. Any unclassified code falls through to retry.
_yuruna_classify_curl() {
    local rc="$1"
    case "$rc" in
        3|43) return 1 ;;                              # malformed URL / bad usage -> permanent
        5|6|7|16|18|28|35|52|55|56|92) return 0 ;;     # DNS/connect/timeout/recv/http2 -> transient
    esac
    # A peer certificate that will not verify is a trust-anchor mismatch, and
    # re-running the identical fetch cannot change the anchor -- the ladder can
    # only spend its whole budget arriving back here. The one thing that CAN
    # change it is replacing this guest's stale copy of the ssl-bump CA, so try
    # that once and let the outcome decide: a retry is worth spending only when
    # the copy actually changed.
    if [ "$rc" -eq 60 ]; then
        if yuruna_ca_selfheal; then return 0; fi
        return 1
    fi
    if [ "$rc" -eq 22 ]; then _yuruna_http_status_class "${YURUNA_RETRY_CURL_URL:-}"; return $?; fi
    return 0
}

# wget exit-code handling: ../docs/network.md#defining-yuruna-retry-lib.
_yuruna_classify_wget() {
    local rc="$1"
    case "$rc" in
        2|6) return 1 ;;                               # command-line/parse, auth -> permanent
        3|4|7) return 0 ;;                             # file I/O, network, protocol -> transient
    esac
    if [ "$rc" -eq 5 ]; then
        if yuruna_ca_selfheal; then return 0; fi
        return 1
    fi
    if [ "$rc" -eq 8 ]; then _yuruna_http_status_class "${YURUNA_RETRY_WGET_URL:-}"; return $?; fi
    return 0
}

# --- REGION: https://yuruna.link/4220a755-0003
# --speed-limit/--speed-time abort a transfer that drops below 1 KB/s for
# 60s (curl exit 28), turning a stalled-after-headers or trickling download
# into a retryable failure instead of an unbounded hang. Wall-clock bounds
# would be wrong here: a large asset on a slow-but-moving link must be
# allowed to finish. The transient gate fails fast on a deterministic 404
# rather than retrying it; YURUNA_RETRY_NO_TRANSIENT_GATE=1 restores the
# retry-everything behavior.
curl_retry() {
    local url="" _a
    for _a in "$@"; do case "$_a" in http://*|https://*) url="$_a" ;; esac; done
    local classify=_yuruna_classify_curl
    [ -n "${YURUNA_RETRY_NO_TRANSIENT_GATE:-}" ] && classify=""
    YURUNA_RETRY_CLASSIFY="$classify" YURUNA_RETRY_CURL_URL="$url" \
    _yuruna_retry curl_retry curl --retry 3 --retry-connrefused --retry-delay 5 \
        --speed-limit 1024 --speed-time 60 "$@"
}

# --- REGION: https://yuruna.link/4220a755-0003
# wget counterpart of curl_retry, for the scripts that pipe a remote
# install.sh straight to bash (nvm, nodesource). The inner --tries/--waitretry
# rides out a single connection blip; the outer _yuruna_retry loop re-runs the
# whole fetch with exponential backoff when wget exhausts its own tries.
# --read-timeout aborts when no data arrives for 60s, so a transfer stalled
# mid-body fails into the retry ladder instead of hanging the attempt.
wget_try() {
    local url="" _a
    for _a in "$@"; do case "$_a" in http://*|https://*) url="$_a" ;; esac; done
    local classify=_yuruna_classify_wget
    [ -n "${YURUNA_RETRY_NO_TRANSIENT_GATE:-}" ] && classify=""
    YURUNA_RETRY_CLASSIFY="$classify" YURUNA_RETRY_WGET_URL="$url" \
    _yuruna_retry wget_try wget --tries=3 --waitretry=5 --retry-connrefused \
        --read-timeout=60 "$@"
}

# --- REGION: https://yuruna.link/4220a755-0003
pwsh_retry() {
    local log_file="$1"
    if [ -z "$log_file" ]; then
        echo "pwsh_retry: usage: pwsh_retry <log_file> <<<pwsh body on stdin>>>" >&2
        return 2
    fi
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
    local body
    body="$(cat)"
    # The log this wrapper's attempts append to is the one a diagnostic reads
    # later, so the wrapper's verdict belongs in it.
    local prior_record="${YURUNA_RETRY_RECORD:-}"
    YURUNA_RETRY_RECORD="$log_file"
    local rc=0
    _yuruna_retry pwsh_retry _yuruna_pwsh_attempt "$log_file" "$body" || rc=$?
    YURUNA_RETRY_RECORD="$prior_record"
    return "$rc"
}

_yuruna_pwsh_attempt() {
    local log="$1"; shift
    local body="$*"
    # The body must reach pwsh as a script FILE, never on stdin: piped
    # into `pwsh -Command -`, stdin is read REPL-style, which silently
    # stops executing at multi-line constructs it fails to assemble AND
    # exits 0 regardless of the body's own `exit` code. Under that mode a
    # verify block at the end of a body never runs, and a failing body
    # can never engage the retry ladder -- the attempt always reports
    # success. `-File` runs the body as one script and propagates its
    # exit code. The rename after mktemp gives the file the .ps1
    # extension: whether -File accepts an extensionless target varies
    # across PowerShell versions, and .ps1 is the one name every
    # version runs.
    local rc=0 tmp script
    tmp="$(mktemp /tmp/yuruna-pwsh-attempt.XXXXXX)" || return 1
    script="${tmp}.ps1"
    mv "$tmp" "$script" || { rm -f "$tmp"; return 1; }
    printf '%s\n' "$body" >"$script"
    # The attempt is a shell function, so _yuruna_retry's generic stall
    # bound cannot wrap it; bound the inner exec here instead. Same
    # stalled-transfer exposure as the package managers (Install-Module
    # fetches from PSGallery), same sudo-hoist rationale: timeout must
    # signal pwsh directly, not sudo.
    local stall="${YURUNA_PWSH_STALL_TIMEOUT_SECONDS:-600}"
    {
        printf '\n===== %s sudo pwsh attempt =====\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [ "$stall" -gt 0 ] 2>/dev/null && command -v timeout >/dev/null 2>&1; then
            sudo timeout --foreground --kill-after=30 "$stall" pwsh -NoProfile -File "$script"
        else
            sudo pwsh -NoProfile -File "$script"
        fi
    } >>"$log" 2>&1 || rc=$?
    rm -f "$script"
    return "$rc"
}


# Guest update bootstrap shared by Ubuntu and Amazon Linux.
yuruna_host_env() {
    [ -r /etc/yuruna/host.env ] || return 1
    # shellcheck disable=SC1091
    . /etc/yuruna/host.env
    [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ]
}

# Force one refresh after a failed fetch instead of retrying stale coordinates.
yuruna_host_relocate() {
    [ -x /usr/local/lib/yuruna/yuruna-host-locate.sh ] || return 1
    # --- REGION: https://yuruna.link/42e220c4-0005
    /usr/local/lib/yuruna/yuruna-host-locate.sh >/dev/null || return 1
    yuruna_host_env
}

yuruna_materialize_repositories() {
    local REAL_HOME="$1" REAL_USER="$2" FRAMEWORK_URL="$3" PROJECT_URL="$4"
if [ ! -d "$REAL_HOME/yuruna" ]; then
  HOST_OK=false
  for host_attempt in 1 2; do
    if [ "$host_attempt" -eq 2 ]; then
      if ! yuruna_host_relocate; then
        echo "yuruna: host coordinates could not be refreshed - the pool directory has no live address for this host."
        break
      fi
      echo "yuruna: host coordinates refreshed; retrying the tarball fetch."
    else
      yuruna_host_env || break
    fi
    LIVECHECK_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/livecheck"
    TARBALL_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-archive.tar.gz"
    if wget --no-proxy --tries=1 --timeout=2 -qO /dev/null "$LIVECHECK_URL" 2>/dev/null; then
      echo "yuruna: fetching committed tarball from $TARBALL_URL"
      mkdir -p "$REAL_HOME/yuruna"
      if wget --no-proxy --timeout=30 --tries=2 -qO- "$TARBALL_URL" | tar -xz -C "$REAL_HOME/yuruna"; then
        HOST_OK=true
        break
      else
        echo "yuruna: tarball fetch/extract failed - falling back to git clone"
        rm -rf "$REAL_HOME/yuruna"
      fi
    fi
  done
  if [ "$HOST_OK" = "false" ]; then
    if [ -z "$FRAMEWORK_URL" ]; then
      echo "yuruna: repositories.frameworkUrl missing from test.config.yml - cannot clone framework" >&2
      exit 1
    fi
    for attempt in 1 2 3; do
      git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 clone "$FRAMEWORK_URL" "$REAL_HOME/yuruna" && break
      echo "git clone attempt $attempt failed"
      rm -rf "$REAL_HOME/yuruna"
      [ $attempt -lt 3 ] && sleep 60
    done
    if [ ! -d "$REAL_HOME/yuruna" ]; then
      echo "git clone failed after 3 attempts" >&2
      exit 1
    fi
  fi
fi

if [ ! -d "$REAL_HOME/yuruna/project" ]; then
  PROJECT_HOST_OK=false
  # --- REGION: https://yuruna.link/42e220c4-0005
  for project_attempt in 1 2; do
    if [ "$project_attempt" -eq 2 ]; then
      if ! yuruna_host_relocate; then
        echo "yuruna: host coordinates could not be refreshed - the pool directory has no live address for this host."
        break
      fi
      echo "yuruna: host coordinates refreshed; retrying the project tarball fetch."
    else
      yuruna_host_env || break
    fi
    PROJECT_LIVECHECK_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/livecheck"
    PROJECT_TARBALL_URL="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-project-archive.tar.gz"
    if ! wget --no-proxy --tries=1 --timeout=2 -qO /dev/null "$PROJECT_LIVECHECK_URL" 2>/dev/null; then
      echo "yuruna: host status service did not answer at ${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}"
      continue
    fi
    echo "yuruna: trying project tarball at $PROJECT_TARBALL_URL"
    mkdir -p "$REAL_HOME/yuruna/project"
    if wget --no-proxy --timeout=30 --tries=2 -qO- "$PROJECT_TARBALL_URL" \
         | tar -xz -C "$REAL_HOME/yuruna/project" 2>/dev/null \
         && [ -n "$(ls -A "$REAL_HOME/yuruna/project" 2>/dev/null)" ]; then
      PROJECT_HOST_OK=true
      break
    else
      echo "yuruna: project tarball not served (or empty) - falling back to git clone"
      rm -rf "$REAL_HOME/yuruna/project"
    fi
  done
  if [ "$PROJECT_HOST_OK" = "false" ] && [ -n "$PROJECT_URL" ]; then
    for attempt in 1 2 3; do
      git -c http.lowSpeedLimit=1024 -c http.lowSpeedTime=60 clone "$PROJECT_URL" "$REAL_HOME/yuruna/project" && break
      echo "project git clone attempt $attempt failed"
      rm -rf "$REAL_HOME/yuruna/project"
      [ $attempt -lt 3 ] && sleep 60
    done
    if [ ! -d "$REAL_HOME/yuruna/project" ]; then
      echo "project git clone failed after 3 attempts" >&2
      exit 1
    fi
  fi
fi

# Tarball extraction and any sudo'd cleanup may have left root-owned files.
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/yuruna" 2>/dev/null || true

}

yuruna_wait_network() {
if systemctl is-active --quiet NetworkManager && command -v nm-online >/dev/null 2>&1; then
  nm-online -q -t 30 || echo "WARNING: nm-online did not report 'online' within 30s; continuing."
elif systemctl is-active --quiet systemd-networkd; then
  # systemd-networkd-wait-online lives outside PATH; resolve it explicitly.
  # --any: succeed once at least one link is online (single-NIC guests have
  # no second link to wait on).
  networkd_wait=""
  for cand in /usr/lib/systemd/systemd-networkd-wait-online /lib/systemd/systemd-networkd-wait-online; do
    if [ -x "$cand" ]; then
      networkd_wait="$cand"
      break
    fi
  done
  if [ -n "$networkd_wait" ]; then
    "$networkd_wait" --any --timeout=30 || echo "WARNING: systemd-networkd-wait-online did not report 'online' within 30s; continuing."
  else
    echo "WARNING: systemd-networkd active but systemd-networkd-wait-online not found; continuing."
  fi
else
  echo "WARNING: no active NetworkManager/systemd-networkd to wait on; continuing."
fi

}

_yuruna_verify_key_fpr() {
    local keyfile="$1"; shift
    local required="${1^^}" allowed=("$@") present a fpr ok found=0
    present="$(gpg --show-keys --with-colons "$keyfile" 2>/dev/null \
              | awk -F: '/^pub:/{p=1} /^fpr:/{if(p){print toupper($10); p=0}}')"
    [ -n "$present" ] || { echo "!! key verify: no primary key fingerprints in $keyfile (is gpg installed?)" >&2; return 1; }
    while IFS= read -r fpr; do
        fpr="${fpr//[$'\r\n\t ']/}"; [ -z "$fpr" ] && continue
        ok=0; for a in "${allowed[@]}"; do [ "${a^^}" = "$fpr" ] && { ok=1; break; }; done
        [ "$ok" = 1 ] || { echo "!! key verify: unexpected fingerprint $fpr in $keyfile (not in the pinned allow-set)" >&2; return 1; }
        [ "$fpr" = "$required" ] && found=1
    done <<< "$present"
    [ "$found" = 1 ] || { echo "!! key verify: required fingerprint $required missing from $keyfile" >&2; return 1; }
    echo "  key verify: OK ($keyfile)"
}

# Install the same verified tarball on every Linux guest. Dependencies are caller-owned.
yuruna_install_pwsh_tarball() (
    local arch="$1" ps_arch tag version package url want got
    case "$arch" in x86_64) ps_arch=x64;; aarch64) ps_arch=arm64;; *) return 1;; esac
    local work
    work="$(mktemp -d /tmp/yuruna-pwsh.XXXXXX)" || return 1
    trap 'rm -rf "$work"' EXIT
    tag="$(curl_retry -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/PowerShell/PowerShell/releases/latest)" || return 1
    tag="${tag##*/}"
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid PowerShell release tag" >&2; return 1; }
    version="${tag#v}"; package="powershell-${version}-linux-${ps_arch}.tar.gz"
    url="https://github.com/PowerShell/PowerShell/releases/download/${tag}/${package}${YurunaCacheContent:+?nocache=${YurunaCacheContent}}"
    curl_retry -fsSL -o "$work/package.tar.gz" "$url" || return 1
    curl_retry -fsSL -o "$work/hashes.sha256" "https://github.com/PowerShell/PowerShell/releases/download/${tag}/hashes.sha256" || return 1
    local bom
    bom="$(od -An -tx1 -N2 "$work/hashes.sha256" | tr -d ' \n')"
    if [ "$bom" = fffe ] || [ "$bom" = feff ]; then
        iconv -f UTF-16 -t UTF-8 "$work/hashes.sha256" | tr -d '\r' > "$work/hashes.norm" || return 1
    else tr -d '\r' < "$work/hashes.sha256" > "$work/hashes.norm"; fi
    want="$(LC_ALL=C awk -v p="$package" '$2==p || $2=="*"p {print $1;exit}' "$work/hashes.norm")"
    got="$(sha256sum "$work/package.tar.gz" | awk '{print $1}')"
    [[ "$want" =~ ^[0-9a-fA-F]{64}$ ]] && [ "${want,,}" = "$got" ] || { echo "PowerShell checksum missing or mismatched" >&2; return 1; }
    sudo mkdir -p /opt/microsoft/powershell/7 || return 1
    sudo tar zxf "$work/package.tar.gz" -C /opt/microsoft/powershell/7 || return 1
    sudo chmod +x /opt/microsoft/powershell/7/pwsh || return 1
    sudo ln -sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh
)
export -f yuruna_host_env yuruna_host_relocate yuruna_materialize_repositories yuruna_wait_network _yuruna_verify_key_fpr yuruna_install_pwsh_tarball

# --- REGION: https://yuruna.link/4220a755-0003
# Child Bash payloads need the wrappers and every helper they call.
export -f _yuruna_retry _yuruna_retry_positive_integer _yuruna_retry_record \
    apt_retry dnf_retry curl_retry wget_try pwsh_retry _yuruna_pwsh_attempt \
    _yuruna_http_status_class _yuruna_classify_curl _yuruna_classify_wget \
    yuruna_ca_selfheal _yuruna_bump_trusted _yuruna_ca_trust

# Pull in the pinned dependency versions ($YURUNA_K8S_MINOR, etc.) so every
# guest script that sources this retry lib also gets the version pins, with
# no second `source` line per script. The vars are exported by that file, so
# they reach `bash << 'EOF'` heredocs too. Guarded: a guest provisioned before
# the manifest shipped simply runs without the pins (the scripts that need a
# pin fail loudly on the unset variable under `set -u`, which is the correct
# signal that the seed predates this file).
if [ -r /usr/local/lib/yuruna/yuruna-versions.sh ]; then
    . /usr/local/lib/yuruna/yuruna-versions.sh
fi
