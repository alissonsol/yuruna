#!/bin/bash
# Version: 2026.05.29
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Single source of truth for retry wrappers used by guest provisioning
# scripts. Sourced via /usr/local/lib/yuruna/yuruna_retry.sh after
# cloud-init deploys this file at install time.
#
# --- See https://yuruna.link/network#defining-yuruna-retry-lib

_yuruna_retry() {
    local label="$1"; shift
    local max_attempts="${YURUNA_RETRY_MAX_ATTEMPTS:-5}"
    local delay="${YURUNA_RETRY_DELAY:-10}"
    local attempt=1 rc=0
    while [ "$attempt" -le "$max_attempts" ]; do
        if [ "$attempt" -gt 1 ]; then
            echo ""
            echo ">> ${label}: attempt $attempt/$max_attempts for: $*"
        fi
        rc=0; "$@" || rc=$?
        if [ "$rc" -eq 0 ]; then return 0; fi
        echo "!! ${label}: attempt $attempt/$max_attempts failed (rc=$rc): $*"
        if [ "$attempt" -lt "$max_attempts" ]; then
            echo "!! ${label}: sleeping ${delay}s before retry"
            sleep "$delay"
            delay=$((delay * 2))
        fi
        attempt=$((attempt + 1))
    done
    echo "!! ${label}: all $max_attempts attempts exhausted for: $*"
    return "$rc"
}

apt_retry() { _yuruna_retry apt_retry "$@"; }
dnf_retry() { _yuruna_retry dnf_retry "$@"; }

# --- See https://yuruna.link/network#defining-yuruna-retry-lib
curl_retry() {
    _yuruna_retry curl_retry curl --retry 3 --retry-connrefused --retry-delay 5 "$@"
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

export -f _yuruna_retry apt_retry dnf_retry curl_retry pwsh_retry _yuruna_pwsh_attempt
