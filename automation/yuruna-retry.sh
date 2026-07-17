#!/bin/bash
# Version: 2026.07.17
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
            echo "!! ${label}: sleeping ${delay}s before retry" >&2
            sleep "$delay"
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
# --speed-limit/--speed-time abort a transfer that drops below 1 KB/s for
# 60s (curl exit 28), turning a stalled-after-headers or trickling download
# into a retryable failure instead of an unbounded hang. Wall-clock bounds
# would be wrong here: a large asset on a slow-but-moving link must be
# allowed to finish.
curl_retry() {
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

export -f _yuruna_retry apt_retry dnf_retry curl_retry wget_try pwsh_retry _yuruna_pwsh_attempt

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
