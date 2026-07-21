#!/bin/bash
# Version: 2026.07.21
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Single source of truth for retry wrappers used by guest provisioning
# scripts. Sourced via /usr/local/lib/yuruna/yuruna-retry.sh after
# cloud-init deploys this file at install time.
#
# --- REGION: https://yuruna.link/network#defining-yuruna-retry-lib

_yuruna_retry() {
    local label="$1"; shift
    local max_attempts="${YURUNA_RETRY_MAX_ATTEMPTS:-5}"
    local delay="${YURUNA_RETRY_DELAY:-10}"
    local stall="${YURUNA_RETRY_STALL_TIMEOUT:-0}"
    local attempt=1 rc=0
    # Diagnostics go to stderr, never stdout: these wrappers are routinely
    # used in `curl_retry ... | bash` / `wget_try ... | bash` pipelines, where
    # a retry's progress line on stdout would be fed to the interpreter as
    # script text and corrupt the install. The fetch-and-execute log captures
    # 2>&1, so the operator still sees every attempt.
    #
    # Per-attempt wall-clock bound (YURUNA_RETRY_STALL_TIMEOUT, whole
    # seconds; 0 = unbounded): an HTTP transfer that stalls after response
    # headers -- or trickles too slowly to trip the client's own
    # connect/read-gap timeout -- otherwise hangs the attempt forever, and
    # this loop never gets to retry on a fresh connection (the
    # stalled-transfer trap class: apt InRelease fetches wedging mid-body
    # behind a caching proxy). A malformed value must fail LOUD and
    # unbounded, not silently unbounded: the operator believes a bound is
    # active.
    case "$stall" in
        ''|*[!0-9]*)
            echo "!! ${label}: YURUNA_RETRY_STALL_TIMEOUT='$stall' is not a whole number of seconds; running unbounded" >&2
            stall=0
            ;;
    esac
    # bound_mode is invariant across attempts: none | direct | sudo.
    # timeout(1) can only exec real commands, so shell-function attempts
    # (pwsh_retry's helper) always run unbounded. When the command is a
    # plain `sudo <tool> ...`, hoist the bound INSIDE sudo so the expiry
    # TERM -- and the unrelayable KILL backstop -- land on the privileged
    # tool itself; signaling sudo from outside can reap sudo while the
    # root child survives, still holding e.g. the dpkg lock, which would
    # wedge every retry. The hoist is skipped when the word after sudo is
    # an option (it would be misread as an option of timeout).
    #
    # --foreground is load-bearing: without it timeout setpgid()s the
    # command into its own process group, which on a console/pty (these
    # scripts run on the guest console, and sudo's use_pty adds a pty of
    # its own) makes the command a BACKGROUND group of that terminal. The
    # first tty read or tcsetattr in a maintainer-script/hook then stops
    # the whole run with SIGTTIN/SIGTTOU -- it freezes silently until the
    # expiry TERM+CONT wakes it to die, converting a healthy apt run into
    # a phantom 600s "stall" (the background-pgrp tty-stop trap class).
    # With --foreground the command keeps the inherited foreground group;
    # the tradeoff -- expiry signals only the direct child, not a group --
    # is what the sudo-hoist already assumes.
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
        echo "YURUNA_RETRY {\"stack\":\"bash\",\"label\":\"${label}\",\"attempt\":${attempt},\"maxAttempts\":${max_attempts},\"rc\":${rc},\"permanent\":${permanent}}" >&2
        if [ "$permanent" = true ]; then
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
    echo "!! ${label}: all $max_attempts attempts exhausted for: $*" >&2
    return "$rc"
}

# Package-manager attempts run UNBOUNDED by default (opt in via
# YURUNA_APT_STALL_TIMEOUT / YURUNA_DNF_STALL_TIMEOUT, seconds). A
# wall-clock bound here is attractive -- a wedged mirror/proxy transfer
# otherwise consumes the whole step budget as one silent hang -- but
# wrapping apt in timeout(1) is the wrapped-apt teardown-hang trap class:
# with the wrapper as apt's parent, every apt run that performs REAL dpkg
# work (upgrade with triggers, removal, install) has been observed to
# block silently at end-of-transaction AFTER dpkg fully commits (~0 CPU,
# no sockets, dpkg gone, locks held) until the bound kills it, while a
# control guest running the identical transaction unwrapped completes in
# seconds, every time. Until that interaction is root-caused (suspects:
# apt's dpkg-pty EOF drain or its hook-child wait under a timeout(1)
# parent), the safe default is the plain unwrapped invocation; the
# mirror-stall exposure is instead bounded at the transfer layer
# (curl/wget/git low-speed aborts, apt's own Acquire::http::Timeout,
# and the caching proxy's read_timeout).
apt_retry() {
    YURUNA_RETRY_STALL_TIMEOUT="${YURUNA_APT_STALL_TIMEOUT:-0}" \
    YURUNA_RETRY_HEAL='sudo dpkg --configure -a' \
        _yuruna_retry apt_retry "$@"
}
dnf_retry() {
    YURUNA_RETRY_STALL_TIMEOUT="${YURUNA_DNF_STALL_TIMEOUT:-0}" \
        _yuruna_retry dnf_retry "$@"
}

# --- REGION: https://yuruna.link/network#defining-yuruna-retry-lib
# Shared HTTP-status classifier for the curl/wget gates. curl -f (exit 22) and
# wget (exit 8) both collapse EVERY HTTP error to one exit code -- a 404 and a
# 503 are indistinguishable at that level -- so we re-probe the status: a cheap,
# bounded, output-discarding GET that inherits the same proxy env as the real
# fetch. Re-probing (rather than adding `-w`/`-S` to the real fetch) keeps the
# code off the stdout that feeds the `... | bash` install pipelines. Returns 0
# (transient: 429 / 5xx / no-answer) or 1 (permanent: other 4xx). An empty or
# unreplicable URL is treated as transient so the gate never hardens a healthy
# fetch into a failure.
_yuruna_http_status_class() {
    local url="$1"
    [ -z "$url" ] && return 0
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || echo 000)"
    echo "  yuruna-retry: re-probed HTTP status for ${url} = ${code}" >&2
    case "$code" in
        429|5[0-9][0-9]|000) return 0 ;;               # rate-limit / server error / no-answer -> transient
        4[0-9][0-9]) return 1 ;;                        # 404/403/401/... -> permanent (retrying cannot help)
    esac
    return 0
}

# curl transient/permanent classifier: network / SSL / timeout codes are
# transient (retry); a malformed URL or bad usage is permanent; an HTTP-error
# exit (22) re-probes the status. Any unclassified code falls through to retry.
_yuruna_classify_curl() {
    local rc="$1"
    case "$rc" in
        3|43) return 1 ;;                              # malformed URL / bad usage -> permanent
        5|6|7|16|18|28|35|52|55|56|60|92) return 0 ;;  # DNS/connect/timeout/SSL/recv/http2 -> transient
    esac
    if [ "$rc" -eq 22 ]; then _yuruna_http_status_class "${YURUNA_RETRY_CURL_URL:-}"; return $?; fi
    return 0
}

# wget classifier, the exact analog of the curl one. wget has per-class exit
# codes: 2 (command-line/parse) and 6 (authentication) are permanent; 3/4/5/7
# (file I/O, network, SSL, protocol) are transient; 8 ("server issued an error
# response") is the HTTP-error analog of curl's 22 and re-probes the status.
# 1 (generic) and anything else fall through to retry.
_yuruna_classify_wget() {
    local rc="$1"
    case "$rc" in
        2|6) return 1 ;;                               # command-line/parse, auth -> permanent
        3|4|5|7) return 0 ;;                           # file I/O, network, SSL, protocol -> transient
    esac
    if [ "$rc" -eq 8 ]; then _yuruna_http_status_class "${YURUNA_RETRY_WGET_URL:-}"; return $?; fi
    return 0
}

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

# --- REGION: https://yuruna.link/network#defining-yuruna-retry-lib
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

# --- REGION: https://yuruna.link/network#defining-yuruna-retry-lib
pwsh_retry() {
    local log_file="$1"
    if [ -z "$log_file" ]; then
        echo "pwsh_retry: usage: pwsh_retry <log_file> <<<pwsh body on stdin>>>" >&2
        return 2
    fi
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
    local body
    body="$(cat)"
    _yuruna_retry pwsh_retry _yuruna_pwsh_attempt "$log_file" "$body"
}

_yuruna_pwsh_attempt() {
    local log="$1"; shift
    local body="$*"
    # The attempt is a shell function, so _yuruna_retry's generic stall
    # bound cannot wrap it; bound the inner exec here instead. Same
    # stalled-transfer exposure as the package managers (Install-Module
    # fetches from PSGallery), same sudo-hoist rationale: timeout must
    # signal pwsh directly, not sudo. stdin passes through timeout
    # untouched, so the heredoc body still reaches pwsh.
    local stall="${YURUNA_PWSH_STALL_TIMEOUT:-600}"
    {
        printf '\n===== %s sudo pwsh attempt =====\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if [ "$stall" -gt 0 ] 2>/dev/null && command -v timeout >/dev/null 2>&1; then
            printf '%s' "$body" | sudo timeout --foreground --kill-after=30 "$stall" pwsh -NoProfile -Command -
        else
            printf '%s' "$body" | sudo pwsh -NoProfile -Command -
        fi
    } >>"$log" 2>&1
}

export -f _yuruna_retry apt_retry dnf_retry curl_retry wget_try pwsh_retry _yuruna_pwsh_attempt _yuruna_http_status_class _yuruna_classify_curl _yuruna_classify_wget

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
