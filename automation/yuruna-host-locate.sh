#!/bin/bash
# Version: 2026.11.05
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 4221843a-c40e-4a85-9988-8cf2fe9942f1
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
YURUNA_GUEST_CHANNEL_KEY_FILE="${YURUNA_GUEST_CHANNEL_KEY_FILE:-/etc/yuruna/guest-channel.key}"

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

# --- REGION: Guest-channel proof
# The host's guest-channel key, seeded with the guest, or nothing. A guest built
# before the key existed has no file and keeps the unverified probe.
__yhl_channel_key() {
    local key=''
    if [ -r "$YURUNA_GUEST_CHANNEL_KEY_FILE" ]; then
        key="$(head -n 1 "$YURUNA_GUEST_CHANNEL_KEY_FILE" 2>/dev/null | tr -d '[:space:]')"
    fi
    if [[ "$key" =~ ^[0-9a-f]{64}$ ]]; then printf '%s' "$key"; fi
    return 0
}

# hex(HMAC-SHA256) of the livecheck question under the key, as the host's
# Get-YurunaGuestChannelProof computes it. The key is used as the ASCII bytes of
# its hex form, which every openssl (and LibreSSL) takes through -hmac.
__yhl_channel_proof() {
    printf 'yuruna-livecheck/1\n%s\n%s' "$2" "$3" | openssl dgst -sha256 -hmac "$1" 2>/dev/null | awk '{ print $NF }'
}

# Does this guest's own host answer at this base URL? The one question that
# decides everything else in this file. With the guest-channel key, only a
# status service that answers a fresh nonce with the key's HMAC counts, so a
# directory answer or a stale address cannot hand this guest to another
# responder; the reason a responder was refused goes to stderr.
__yhl_livecheck() {
    local base="$1" key nonce body proof host_id expected
    key="$(__yhl_channel_key)"
    if [ -z "$key" ]; then
        __yhl_http_get "${base%/}/livecheck" "$YURUNA_LOCATE_PROBE_TIMEOUT" >/dev/null 2>&1
        return
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        __yhl_note "yuruna-host-locate: openssl is missing, so ${base} cannot be checked against this host's guest-channel key; not accepted"
        return 1
    fi
    nonce="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
    [[ "$nonce" =~ ^[0-9a-f]{32}$ ]] || return 1
    body="$(__yhl_http_get "${base%/}/livecheck?nonce=${nonce}" "$YURUNA_LOCATE_PROBE_TIMEOUT")" || return 1
    proof="$(printf '%s' "$body" | sed -n 's/.*"proof":"\([0-9a-f]\{64\}\)".*/\1/p' | head -n 1)"
    host_id="$(printf '%s' "$body" | sed -n 's/.*"hostId":"\([^"]*\)".*/\1/p' | head -n 1)"
    if [ -z "$proof" ]; then
        __yhl_note "yuruna-host-locate: ${base} answered without proving this host's guest-channel key; not accepted"
        return 1
    fi
    if [ -n "${YURUNA_HOST_ID:-}" ] && [ "$host_id" != "$YURUNA_HOST_ID" ]; then
        __yhl_note "yuruna-host-locate: ${base} speaks for host '${host_id}', not this guest's host '${YURUNA_HOST_ID}'; not accepted"
        return 1
    fi
    expected="$(__yhl_channel_proof "$key" "$host_id" "$nonce")"
    if [ "$proof" != "$expected" ]; then
        __yhl_note "yuruna-host-locate: ${base} did not prove this host's guest-channel key; not accepted"
        return 1
    fi
    return 0
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

# --- REGION: yuruna_read_env_file
# host.env is data, not a script: KEY=VALUE lines the seed and the host-locate
# refresh write. Sourcing it would run whatever a value spells as shell, so
# only YURUNA_* names are taken, each value literally, with one level of
# matching quotes removed. The same function is in fetch-and-execute.sh,
# yuruna-host-locate.sh and yuruna-retry.sh, each of which is deployed alone.
yuruna_read_env_file() {
    local file="$1" line key value
    [ -r "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        key="${line%%=*}"
        [ "$key" != "$line" ] || continue
        [[ "$key" =~ ^YURUNA_[A-Z0-9_]+$ ]] || continue
        value="${line#*=}"
        value="${value%$'\r'}"
        case "$value" in
            \'*\'|\"*\") value="${value:1:${#value}-2}" ;;
        esac
        printf -v "$key" '%s' "$value"
    done < "$file"
    return 0
}

# --- REGION: https://yuruna.link/4220a755-0033
# Probe the seeded address first; export only a guest-verified endpoint.
yuruna_host_locate() {
    # Locals, not globals: fetch-and-execute sources this file, so anything
    # left unscoped here lands in the caller's shell.
    local base new_base ip port attempt

    yuruna_read_env_file "$YURUNA_HOST_ENV_FILE" || true

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
