#!/bin/bash
# Version: 2026.10.18.1
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Guest host-address resolver. Sourced by fetch-and-execute.sh and run
# standalone by the periodic refresh unit. cloud-init deploys this file at
# /usr/local/lib/yuruna/yuruna-host-locate.sh at install time.
#
# --- REGION: https://yuruna.link/4220a755-002d
# Nothing here throws: the caller degrades on a return code, so a guest that
# cannot resolve ends up exactly where it would have been without this file.

# --- REGION: https://yuruna.link/4220a755-002e
# Override persistence paths for fixtures; production defaults remain unchanged.
YURUNA_HOST_ENV_FILE="${YURUNA_HOST_ENV_FILE:-/etc/yuruna/host.env}"
YURUNA_HOSTS_FILE="${YURUNA_HOSTS_FILE:-/etc/hosts}"
YURUNA_WGETRC_FILE="${YURUNA_WGETRC_FILE:-/etc/wgetrc}"

# See https://yuruna.link/4220a755-002e
# Bound unreachable peers; the ordinary probe costs one LAN round trip.
YURUNA_LOCATE_PROBE_TIMEOUT="${YURUNA_LOCATE_PROBE_TIMEOUT:-2}"
YURUNA_LOCATE_QUERY_TIMEOUT="${YURUNA_LOCATE_QUERY_TIMEOUT:-3}"

# See https://yuruna.link/4220a755-0033
# Space directory queries so registration can catch up with a host address change.
YURUNA_LOCATE_RETRY_ATTEMPTS="${YURUNA_LOCATE_RETRY_ATTEMPTS:-4}"
YURUNA_LOCATE_RETRY_DELAY="${YURUNA_LOCATE_RETRY_DELAY:-3}"

# See https://yuruna.link/4220a755-002e
# The directory port belongs to the aggregator service, independently of this seed.
YURUNA_LOCATE_DIRECTORY_PORT="${YURUNA_LOCATE_DIRECTORY_PORT:-9400}"

# See https://yuruna.link/4220a755-002e
# Bound directory responses during bootstrap before parsing.
YURUNA_LOCATE_MAX_BYTES="${YURUNA_LOCATE_MAX_BYTES:-262144}"

__yhl_note() {
    >&2 echo "$1"
}

# --- REGION: https://yuruna.link/4220a755-002f
# Fetch proxy-free with wget or curl; preserve the fetcher exit code.
__yhl_http_get() {
    local url="$1" timeout="$2"
    if command -v wget >/dev/null 2>&1; then
        wget -q --no-proxy --timeout="$timeout" --tries=1 -O - "$url" 2>/dev/null \
            | head -c "$YURUNA_LOCATE_MAX_BYTES"
        return "${PIPESTATUS[0]}"
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -s --noproxy '*' --max-time "$timeout" --fail "$url" 2>/dev/null \
            | head -c "$YURUNA_LOCATE_MAX_BYTES"
        return "${PIPESTATUS[0]}"
    fi
    return 1
}

# Does a status service answer at this base URL? The one question that
# decides everything else in this file.
__yhl_livecheck() {
    local base="$1"
    __yhl_http_get "${base%/}/livecheck" "$YURUNA_LOCATE_PROBE_TIMEOUT" >/dev/null 2>&1
}

# --- REGION: https://yuruna.link/4220a755-0030
# Coordinates become shell assignments in host.env. Accept only literal
# dotted IPv4 and a decimal TCP port before any persistence or export.
__yhl_valid_endpoint() {
    local ip="$1" port="$2" octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    for octet in ${ip//./ }; do
        (( 10#$octet <= 255 )) || return 1
    done
    (( 10#$port >= 1 && 10#$port <= 65535 ))
}

__yhl_plausible() {
    local url="$1" hostpart port
    # See https://yuruna.link/4220a755-0030
    # Reject non-origin and local-only addresses before probing or persisting.
    [[ "$url" =~ ^https?://([0-9]{1,3}\.){3}[0-9]{1,3}(:[0-9]{1,5})?/?$ ]] || return 1
    hostpart="${url#*://}"
    hostpart="${hostpart%/}"
    port="${hostpart##*:}"
    if [ "$port" = "$hostpart" ]; then port=80; fi
    hostpart="${hostpart%%:*}"
    __yhl_valid_endpoint "$hostpart" "$port" || return 1
    case "$hostpart" in
        127.*|0.0.0.0) return 1 ;;
        169.254.*) return 1 ;;
        22[4-9].*|23[0-9].*) return 1 ;;
    esac
    return 0
}

# --- REGION: https://yuruna.link/4220a755-0031
# Use read-only host-address routes; control redirects mint proofs guests must not receive.
__yhl_query_directory() {
    local cache="$1" host_id="$2" body base

    body=$(__yhl_http_get \
        "http://${cache}:${YURUNA_LOCATE_DIRECTORY_PORT}/api/v1/host-address?hostId=${host_id}" \
        "$YURUNA_LOCATE_QUERY_TIMEOUT") || body=''
    if [ -n "$body" ]; then
        base=$(printf '%s' "$body" | sed -n 's/.*"baseUrl":"\([^"]*\)".*/\1/p' | head -n 1)
        if [ -n "$base" ]; then
            printf '%s' "$base"
            return 0
        fi
    fi

    body=$(__yhl_http_get \
        "http://${cache}:${YURUNA_LOCATE_DIRECTORY_PORT}/api/v1/pool-status" \
        "$YURUNA_LOCATE_QUERY_TIMEOUT") || return 1
    [ -n "$body" ] || return 1

    # See https://yuruna.link/4220a755-0031
    # Require hostId and baseUrl on one flat JSON fragment; unknown shapes fail closed.
    base=$(printf '%s' "$body" | tr '{' '\n' \
        | grep -F "\"hostId\":\"${host_id}\"" \
        | sed -n 's/.*"baseUrl":"\([^"]*\)".*/\1/p' \
        | head -n 1)
    [ -n "$base" ] || return 1
    printf '%s' "$base"
}

# --- REGION: https://yuruna.link/4220a755-0032
# Persist each coordinate file best-effort; in-memory resolution still succeeds.

# See https://yuruna.link/4220a755-0032
# Try direct persistence first, then nonprompting sudo.
__yhl_install_file() {
    local tmp="$1" dest="$2"
    cp "$tmp" "$dest" 2>/dev/null && return 0
    sudo -n cp "$tmp" "$dest" 2>/dev/null
}

__yhl_persist() {
    local ip="$1" port="$2" tmp
    __yhl_valid_endpoint "$ip" "$port" || return 1

    # See https://yuruna.link/4220a755-0032
    # Replace only coordinates, preserving repository and identity fields.
    if [ -r "$YURUNA_HOST_ENV_FILE" ]; then
        tmp=$(mktemp 2>/dev/null) || tmp=''
        if [ -n "$tmp" ]; then
            if sed -e "s|^YURUNA_STATUS_SERVICE_IP=.*|YURUNA_STATUS_SERVICE_IP=${ip}|" \
                   -e "s|^YURUNA_STATUS_SERVICE_PORT=.*|YURUNA_STATUS_SERVICE_PORT=${port}|" \
                   "$YURUNA_HOST_ENV_FILE" > "$tmp" 2>/dev/null; then
                __yhl_install_file "$tmp" "$YURUNA_HOST_ENV_FILE" || true
            fi
            rm -f "$tmp" 2>/dev/null
        fi
    fi

    # See https://yuruna.link/4220a755-0032
    # Remove alias mappings by whole line, matching the host Set-HostAlias contract.
    tmp=$(mktemp 2>/dev/null) || tmp=''
    if [ -n "$tmp" ]; then
        { grep -v -E "[[:space:]]yuruna-host([[:space:]]|\$)" "$YURUNA_HOSTS_FILE" 2>/dev/null || true; } > "$tmp"
        printf '%s\tyuruna-host\n' "$ip" >> "$tmp"
        __yhl_install_file "$tmp" "$YURUNA_HOSTS_FILE" || true
        rm -f "$tmp" 2>/dev/null
    fi

    # See https://yuruna.link/4220a755-0032
    # Refresh wgetrc so a stale literal cannot send host traffic through Squid.
    if [ -f "$YURUNA_WGETRC_FILE" ]; then
        tmp=$(mktemp 2>/dev/null) || tmp=''
        if [ -n "$tmp" ]; then
            if sed -e "s|^no_proxy = .*|no_proxy = ${ip}|" "$YURUNA_WGETRC_FILE" > "$tmp" 2>/dev/null; then
                __yhl_install_file "$tmp" "$YURUNA_WGETRC_FILE" || true
            fi
            rm -f "$tmp" 2>/dev/null
        fi
    fi
}

# --- REGION: https://yuruna.link/4220a755-0033
# Probe the seeded address first; export only a guest-verified endpoint.
yuruna_host_locate() {
    # Locals, not globals: fetch-and-execute sources this file, so anything
    # left unscoped here lands in the caller's shell.
    local base new_base ip port attempt

    if [ -r "$YURUNA_HOST_ENV_FILE" ]; then
        # shellcheck disable=SC1090
        . "$YURUNA_HOST_ENV_FILE"
    fi

    if [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ]; then
        base="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}"
        if __yhl_livecheck "$base"; then
            export YURUNA_STATUS_SERVICE_IP YURUNA_STATUS_SERVICE_PORT
            return 0
        fi
    fi

    # See https://yuruna.link/4220a755-0033
    # A directory lookup needs both host identity and caching-proxy coordinates.
    if [ -z "${YURUNA_HOST_ID:-}" ] || [ -z "${YURUNA_CACHING_PROXY_SERVICE_IP:-}" ]; then
        return 1
    fi

    # See https://yuruna.link/4220a755-0033
    # Retry stale directory answers while host registration catches up.
    new_base=''
    attempt=1
    while [ "$attempt" -le "$YURUNA_LOCATE_RETRY_ATTEMPTS" ]; do
        if [ "$attempt" -gt 1 ]; then sleep "$YURUNA_LOCATE_RETRY_DELAY"; fi
        attempt=$((attempt + 1))
        new_base=$(__yhl_query_directory "$YURUNA_CACHING_PROXY_SERVICE_IP" "$YURUNA_HOST_ID") || continue
        [ -n "$new_base" ] || continue
        if ! __yhl_plausible "$new_base"; then new_base=''; continue; fi
        # See https://yuruna.link/4220a755-0033
        # Confirm every directory answer from this guest before adopting it.
        if __yhl_livecheck "$new_base"; then break; fi
        new_base=''
    done
    [ -n "$new_base" ] || return 1

    new_base="${new_base%/}"
    ip="${new_base#*://}"
    ip="${ip%%/*}"
    port="${ip##*:}"
    if [ "$port" = "$ip" ]; then port=80; fi
    ip="${ip%%:*}"
    __yhl_valid_endpoint "$ip" "$port" || return 1

    __yhl_note "yuruna-host-locate: host moved to ${ip}:${port} (was ${YURUNA_STATUS_SERVICE_IP:-unset}:${YURUNA_STATUS_SERVICE_PORT:-unset}), resolved via ${YURUNA_CACHING_PROXY_SERVICE_IP}"
    __yhl_persist "$ip" "$port"

    YURUNA_STATUS_SERVICE_IP="$ip"
    YURUNA_STATUS_SERVICE_PORT="$port"
    export YURUNA_STATUS_SERVICE_IP YURUNA_STATUS_SERVICE_PORT
    return 0
}

# See https://yuruna.link/4220a755-0033
# Sourcing defines helpers; direct execution performs one host refresh.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    yuruna_host_locate
fi
