#!/bin/bash
# Version: 2026.06.12
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Single source of truth for retry wrappers used by guest provisioning
# scripts. Sourced via /usr/local/lib/yuruna/yuruna-retry.sh after
# cloud-init deploys this file at install time.
#
# --- See https://yuruna.link/network#defining-yuruna-retry-lib

_yuruna_retry() {
    local label="$1"; shift
    local max_attempts="${YURUNA_RETRY_MAX_ATTEMPTS:-5}"
    local delay="${YURUNA_RETRY_DELAY:-10}"
    local attempt=1 rc=0
    # Diagnostics go to stderr, never stdout: these wrappers are routinely
    # used in `curl_retry ... | bash` / `wget_try ... | bash` pipelines, where
    # a retry's progress line on stdout would be fed to the interpreter as
    # script text and corrupt the install. The fetch-and-execute log captures
    # 2>&1, so the operator still sees every attempt.
    while [ "$attempt" -le "$max_attempts" ]; do
        if [ "$attempt" -gt 1 ]; then
            echo "" >&2
            echo ">> ${label}: attempt $attempt/$max_attempts for: $*" >&2
        fi
        rc=0; "$@" || rc=$?
        if [ "$rc" -eq 0 ]; then return 0; fi
        echo "!! ${label}: attempt $attempt/$max_attempts failed (rc=$rc): $*" >&2
        if [ "$attempt" -lt "$max_attempts" ]; then
            echo "!! ${label}: sleeping ${delay}s before retry" >&2
            sleep "$delay"
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done
    echo "!! ${label}: all $max_attempts attempts exhausted for: $*" >&2
    return "$rc"
}

apt_retry() { _yuruna_retry apt_retry "$@"; }
dnf_retry() { _yuruna_retry dnf_retry "$@"; }

# --- See https://yuruna.link/network#defining-yuruna-retry-lib
curl_retry() {
    _yuruna_retry curl_retry curl --retry 3 --retry-connrefused --retry-delay 5 "$@"
}

# --- See https://yuruna.link/network#defining-yuruna-retry-lib
# wget counterpart of curl_retry, for the scripts that pipe a remote
# install.sh straight to bash (nvm, nodesource). The inner --tries/--waitretry
# rides out a single connection blip; the outer _yuruna_retry loop re-runs the
# whole fetch with exponential backoff when wget exhausts its own tries.
wget_try() {
    _yuruna_retry wget_try wget --tries=3 --waitretry=5 --retry-connrefused "$@"
}

# --- See https://yuruna.link/network#defining-yuruna-retry-lib
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
    {
        printf '\n===== %s sudo pwsh attempt =====\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '%s' "$body" | sudo pwsh -NoProfile -Command -
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
