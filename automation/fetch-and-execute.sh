#!/bin/bash
# Version: 2026.10.14
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.

# --- REGION: https://yuruna.link/42fa6f45-0005
# Honor trusted payload/library hashes and source pins before running downloaded bytes.

# --- REGION: https://yuruna.link/42fa6f45-0003
# Prefer the host, then the same repository at the trusted commit pin.
FETCH_SOURCE=''   # 'host' | 'base' | 'github'
HOST_BASE=''      # http://<ip>:<port>/yuruna-repo/  (host), or the EXEC_BASE_URL override
GH_REPO=''        # owner/repo
GH_REF=''         # exact commit sha

# See https://yuruna.link/42fa6f45-0004
# Space failed probes so bridge learning and ARP can settle.
HOST_PROBE_ROUNDS=4
HOST_PROBE_GAP_SECONDS=3

fae_has_ipv4() {
    if command -v yuruna_has_ipv4 >/dev/null 2>&1; then
        yuruna_has_ipv4
    elif command -v ip >/dev/null 2>&1; then
        local _index ifc family _rest
        while read -r _index ifc family _rest; do
            ifc="${ifc%%@*}"
            case "$ifc" in
                lo|veth*|docker*|br-*|virbr*|cni*|flannel*|kube*|tap*|tun*) continue ;;
            esac
            [ "$family" = inet ] && return 0
        done < <(ip -4 -o address show up scope global 2>/dev/null)
        return 1
    else
        # An unavailable diagnostic is not evidence that the guest has no address.
        return 0
    fi
}

resolve_fetch_source() {
    if [ -r /etc/yuruna/host.env ]; then
        # shellcheck disable=SC1091
        . /etc/yuruna/host.env
    fi
    # Typed values win: they describe the commit the host is serving right now,
    # while host.env holds whatever was current when this VM was provisioned.
    GH_REPO="${E_FB_REPO:-${EXEC_FALLBACK_REPO:-${YURUNA_GITHUB_REPO:-}}}"
    GH_REF="${E_FB_REF:-${EXEC_FALLBACK_REF:-${YURUNA_GITHUB_REF:-}}}"

    # See https://yuruna.link/42fa6f45-0003
    # Classify manual overrides by scheme so only local host traffic bypasses proxies.
    if [ -n "${EXEC_BASE_URL:-}" ]; then
        HOST_BASE="$EXEC_BASE_URL"
        case "$EXEC_BASE_URL" in
            http://*) FETCH_SOURCE='host' ;;
            *)        FETCH_SOURCE='base' ;;
        esac
        return
    fi
    # --- REGION: https://yuruna.link/42fa6f45-0007
    # Check the guest address before attributing unreachable peers to the host.
    if ! fae_has_ipv4; then
        >&2 echo ""
        >&2 echo "!! GUEST HAS NO IPv4"
        >&2 echo "!!   state:   no global IPv4 address on any interface"
        >&2 echo "!!   meaning: nothing is reachable from here -- neither the host nor"
        >&2 echo "!!            GitHub -- so neither of those is implicated by this"
        >&2 echo "!!            failure."
        >&2 echo "!!   cause:   could be either side, and only the diagnostic can say"
        >&2 echo "!!            which. A link held down from inside this guest is a"
        >&2 echo "!!            guest-side fault no host can cause; no carrier, or a"
        >&2 echo "!!            carrier with no lease, is host- or LAN-side. Read the"
        >&2 echo "!!            verdict in the NETWORK DIAGNOSTIC below before"
        >&2 echo "!!            attributing this to the host."
        >&2 echo ""
        FETCH_SOURCE='github'
        return
    fi
    # --- REGION: https://yuruna.link/42fa6f45-0006
    # Repair stale host coordinates before falling back; reuse a successful resolver probe.
    if [ -r /usr/local/lib/yuruna/yuruna-host-locate.sh ]; then
        # shellcheck disable=SC1091
        . /usr/local/lib/yuruna/yuruna-host-locate.sh
        if yuruna_host_locate; then
            FETCH_SOURCE='host'
            HOST_BASE="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-repo/"
            return
        fi
    fi
    if [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ]; then
        # --- REGION: https://yuruna.link/42fa6f45-0004
        # Space failed host probes; default bounds here also support isolated callers.
        _probe_rounds="${HOST_PROBE_ROUNDS:-4}"
        _probe_gap="${HOST_PROBE_GAP_SECONDS:-3}"
        _livecheck_url="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/livecheck"
        _probe_round=1
        while [ "$_probe_round" -le "$_probe_rounds" ]; do
            if wget -q --no-proxy --timeout=2 --tries=1 -O /dev/null "$_livecheck_url" 2>/dev/null; then
                if [ "$_probe_round" -gt 1 ]; then
                    # See https://yuruna.link/42fa6f45-0004
                    # Report late host answers so recovered transport delay remains visible.
                    >&2 echo "!! HOST ANSWERED LATE: ${_livecheck_url} responded on probe ${_probe_round}/${_probe_rounds}"
                fi
                FETCH_SOURCE='host'
                HOST_BASE="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-repo/"
                return
            fi
            if [ "$_probe_round" -lt "$_probe_rounds" ]; then sleep "$_probe_gap"; fi
            _probe_round=$((_probe_round + 1))
        done
        # --- REGION: https://yuruna.link/42fa6f45-0007
        >&2 echo ""
        >&2 echo "!! HOST UNREACHABLE"
        >&2 echo "!!   url:     http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/livecheck"
        >&2 echo "!!   source:  /etc/yuruna/host.env (provisioned at New-VM time)"
        >&2 echo "!!   probe:   wget --no-proxy --timeout=2 -O /dev/null, ${_probe_rounds} attempts"
        >&2 echo "!!            ${_probe_gap}s apart -> no response to any of them. A path still"
        >&2 echo "!!            settling answers inside that spread, so this is a host or"
        >&2 echo "!!            route that stayed dead, not one that was merely slow."
        >&2 echo "!!   common:  this guest holds an IPv4 but its path may still be dead --"
        >&2 echo "!!            bridged to a virtual switch with no live uplink, or landed"
        >&2 echo "!!            on another segment; see the NETWORK DIAGNOSTIC below. Or"
        >&2 echo "!!            the host's IP changed since this VM was provisioned (DHCP"
        >&2 echo "!!            lease renewed across a reboot, or Wi-Fi roamed to another"
        >&2 echo "!!            subnet), or the status service is down, or the host firewall"
        >&2 echo "!!            changed."
        # See https://yuruna.link/42fa6f45-0006
        # Report the directory lookup already attempted, including missing coordinates.
        if [ -r /usr/local/lib/yuruna/yuruna-host-locate.sh ]; then
            >&2 echo "!!   lookup:  asked the pool directory at ${YURUNA_CACHING_PROXY_SERVICE_IP:-(no caching proxy seeded)}:9400"
            >&2 echo "!!            for hostId ${YURUNA_HOST_ID:-(none seeded)} -- no address this guest can"
            >&2 echo "!!            reach came back, so a renumbered host is already ruled out"
            >&2 echo "!!            unless the directory itself is stale or unreachable."
        fi
        if [ -n "$GH_REPO" ] && [ -n "$GH_REF" ]; then
            >&2 echo "!!   action:  falling back to GitHub -- ${GH_REPO} at ${GH_REF}"
        fi
        >&2 echo ""
    fi
    FETCH_SOURCE='github'
}

# See https://yuruna.link/42fa6f45-0003
# Project payloads and framework helpers have independent repository pins.
github_fetch_coordinates() {
    GITHUB_FETCH_PATH="$1"
    GITHUB_FETCH_REPO="$GH_REPO"
    GITHUB_FETCH_REF="$GH_REF"
    case "$GITHUB_FETCH_PATH" in
        project/*)
            GITHUB_FETCH_REPO="${E_PROJECT_REPO:-}"
            GITHUB_FETCH_REF="${E_PROJECT_REF:-}"
            GITHUB_FETCH_PATH="${GITHUB_FETCH_PATH#project/}"
            if [[ ! "$GITHUB_FETCH_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
               || [[ ! "$GITHUB_FETCH_REF" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]]; then
                >&2 echo "!! PROJECT FALLBACK UNAVAILABLE: E_PROJECT_REPO and E_PROJECT_REF must pin the project checkout."
                >&2 echo "!! The framework repository cannot supply a separately cloned project."
                return 2
            fi
            ;;
    esac
    [ -n "$GITHUB_FETCH_REPO" ] && [ -n "$GITHUB_FETCH_REF" ]
}

# Authenticated reads use the raw Contents API; host paths keep their project prefix.
# --- REGION: https://yuruna.link/42fa6f45-0003
build_fetch_url() {
    local _bu_request="$1" _bu_path="${1%%\?*}" _bu_url _bu_query _bu_separator
    local _bu_request_query=''
    case "$_bu_request" in *\?*) _bu_request_query="${_bu_request#*\?}" ;; esac
    case "$FETCH_SOURCE" in
        host|base)
            _bu_url="${HOST_BASE}${_bu_path}"
            for _bu_query in "$_bu_request_query" "${QUERY_PARAMS#[?&]}"; do
                [ -n "$_bu_query" ] || continue
                case "$_bu_url" in
                    *\?|*\&) _bu_separator='' ;;
                    *\?*) _bu_separator='&' ;;
                    *) _bu_separator='?' ;;
                esac
                _bu_url="${_bu_url}${_bu_separator}${_bu_query}"
            done
            printf '%s' "$_bu_url"
            ;;
        github)
            github_fetch_coordinates "$_bu_path" || return $?
            if [ -n "${GH_TOKEN:-}" ]; then
                printf 'https://api.github.com/repos/%s/contents/%s?ref=%s' "$GITHUB_FETCH_REPO" "$GITHUB_FETCH_PATH" "$GITHUB_FETCH_REF"
            else
                printf 'https://raw.githubusercontent.com/%s/%s/%s' "$GITHUB_FETCH_REPO" "$GITHUB_FETCH_REF" "$GITHUB_FETCH_PATH"
            fi
            ;;
    esac
}

# See https://yuruna.link/42fa6f45-0003
# Keep the token in a private wgetrc, never world-readable argv.
# --- REGION: https://yuruna.link/42fa6f45-0003
AUTH_CONFIG=''
WGET_FETCH_FLAGS=()

wget_flags_for_source() {
    WGET_FETCH_FLAGS=()
    if [ "$FETCH_SOURCE" = 'host' ]; then
        WGET_FETCH_FLAGS=(--no-proxy)
        return
    fi
    # Only the repo+ref route authenticates. A 'base' override is an explicit
    # operator-supplied URL and stays unauthenticated.
    [ "$FETCH_SOURCE" = 'github' ] || return 0
    [ -z "${GH_TOKEN:-}" ] && return
    if [ -z "$AUTH_CONFIG" ]; then
        AUTH_CONFIG="$(mktemp /tmp/yuruna-fae-auth.XXXXXX 2>/dev/null)" || return 1
        [ -n "$AUTH_CONFIG" ] || return 1
        chmod 600 "$AUTH_CONFIG" 2>/dev/null || return 1
        {
            echo "header = Authorization: Bearer ${GH_TOKEN}"
            echo "header = Accept: application/vnd.github.raw"
            echo "header = X-GitHub-Api-Version: 2022-11-28"
        } > "$AUTH_CONFIG" || return 1
    fi
    WGET_FETCH_FLAGS=(--config="$AUTH_CONFIG")
}

# The wgetrc holds a live credential; drop it however this script leaves.
cleanup_auth_config() {
    local final_rc=$?
    if declare -F fae_stop_recorder >/dev/null; then fae_stop_recorder; fi
    [ -n "$AUTH_CONFIG" ] && rm -f "$AUTH_CONFIG" 2>/dev/null
    if [ -n "${fae_log:-}" ] && [ "${fae_log_completed:-0}" != 1 ]; then
        {
            printf '# exit code: %s\n' "$final_rc"
            printf '# ended:     %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        } >> "$fae_log" 2>/dev/null || true
    fi
    return 0
}
trap cleanup_auth_config EXIT

# --- REGION: https://yuruna.link/42fa6f45-0008
# Separate wget network errors using local address, route, and DNS evidence.
classify_wget_rc() {
    _cw_rc="$1"; _cw_url="$2"
    case "$_cw_rc" in
        0) echo "no transport error -- the response body was empty"; return ;;
        1) echo "generic error"; return ;;
        2) echo "command-line/parse error"; return ;;
        3) echo "local file I/O error"; return ;;
        5) echo "SSL verification failure"; return ;;
        6) echo "authentication failure -- the credential was rejected"; return ;;
        7) echo "protocol error"; return ;;
        8) echo "server answered with an error status (HTTP 4xx/5xx)"; return ;;
        4) : ;;
        *) echo "unclassified"; return ;;
    esac
    if ! command -v ip >/dev/null 2>&1; then
        echo "network failure (DNS, no route, or refused -- wget does not separate them)"
        return
    fi
    if ! fae_has_ipv4; then
        echo "network failure -- this guest holds no IPv4 address (no carrier, or no DHCP lease)"
        return
    fi
    if [ -z "$(ip -4 route show default 2>/dev/null)" ]; then
        echo "network failure -- no default route, so nothing can leave this subnet"
        return
    fi
    _cw_host="${_cw_url#*://}"; _cw_host="${_cw_host%%/*}"; _cw_host="${_cw_host%%:*}"
    case "$_cw_host" in
        ''|*[!0-9.]*)
            if command -v getent >/dev/null 2>&1 \
               && ! getent hosts "$_cw_host" >/dev/null 2>&1; then
                echo "network failure -- the name '$_cw_host' does not resolve (DNS)"
                return
            fi
            ;;
    esac
    echo "network failure -- addressed and routed, so the peer refused or dropped the connection"
}

# See https://yuruna.link/42fa6f45-0005
# Require the trusted digest; manual waiver covers only an unenforced missing digest.
verify_sha256() {
    _vf_file="$1"; _vf_expected="$2"; _vf_label="$3"; _vf_var="${4:-E_SHA}"
    if [ -z "${_vf_expected:-}" ]; then
        if [ "${EXEC_REQUIRE_SHA256:-}" = "1" ]; then
            >&2 echo "!! integrity: host requires a digest (EXEC_REQUIRE_SHA256=1) but none was supplied for $_vf_label -- refusing"
            if [ "${EXEC_ALLOW_UNVERIFIED:-}" = "1" ]; then
                >&2 echo "!!   EXEC_ALLOW_UNVERIFIED=1 does not apply while EXEC_REQUIRE_SHA256=1"
            fi
            return 1
        fi
        if [ "${EXEC_ALLOW_UNVERIFIED:-}" != "1" ]; then
            >&2 echo ""
            >&2 echo "!! NO EXPECTED DIGEST"
            >&2 echo "!!   file:    $_vf_label"
            >&2 echo "!!   effect:  refusing to use bytes that nothing vouches for"
            >&2 echo "!!   fix:     repeat the same command with the file's SHA-256 in front of it,"
            >&2 echo "!!            taken from a checkout you trust and not from this download:"
            >&2 echo "!!              $_vf_var=<64 hex digits> <the same command>"
            >&2 echo "!!   last resort, for manual recovery when no digest can be obtained:"
            >&2 echo "!!              EXEC_ALLOW_UNVERIFIED=1 <the same command>"
            if [ -n "${EXEC_ALLOW_UNVERIFIED:-}" ]; then
                >&2 echo "!!   note:    EXEC_ALLOW_UNVERIFIED is set to '${EXEC_ALLOW_UNVERIFIED}', but only the value 1 enables it"
            fi
            >&2 echo ""
            return 1
        fi
        case "${FETCH_SOURCE:-}" in
            github)    _vf_src="GitHub ${GH_REPO:-?} at ${GH_REF:-?}" ;;
            host|base) _vf_src="${HOST_BASE:-the configured server}" ;;
            *)         _vf_src='its source' ;;
        esac
        >&2 echo ""
        >&2 echo "!! UNVERIFIED CODE WILL RUN: EXEC_ALLOW_UNVERIFIED=1"
        >&2 echo "!!   file:    $_vf_label"
        >&2 echo "!!   digest:  none supplied -- these bytes are NOT checked against any SHA-256"
        >&2 echo "!!   source:  $_vf_src"
        >&2 echo "!!   effect:  whatever that source returns runs here as this user, exactly as served"
        >&2 echo "!!   scope:   a manual-recovery override for when no digest can be obtained;"
        >&2 echo "!!            an automated run never sets it"
        >&2 echo "!!   safer:   drop the override and pass $_vf_var=<64 hex digits> computed on a"
        >&2 echo "!!            machine you trust"
        >&2 echo ""
        return 0
    fi
    _vf_actual="$(sha256sum "$_vf_file" 2>/dev/null | awk '{print $1}')"
    [ -z "$_vf_actual" ] && _vf_actual="$(shasum -a 256 "$_vf_file" 2>/dev/null | awk '{print $1}')"
    _vf_expected="$(printf '%s' "$_vf_expected" | tr 'A-F' 'a-f')"
    _vf_actual="$(printf '%s' "$_vf_actual" | tr 'A-F' 'a-f')"
    if [ -n "$_vf_actual" ] && [ "$_vf_actual" = "$_vf_expected" ]; then
        echo "  integrity: sha256 verified ($_vf_label)"
        return 0
    fi
    >&2 echo ""
    >&2 echo "!! INTEGRITY MISMATCH"
    >&2 echo "!!   file:     $_vf_label"
    >&2 echo "!!   expected: $_vf_expected"
    >&2 echo "!!   actual:   ${_vf_actual:-<none>}"
    >&2 echo "!!   refusing to run code that does not match the expected digest."
    if [ "${EXEC_ALLOW_UNVERIFIED:-}" = "1" ]; then
        >&2 echo "!!   EXEC_ALLOW_UNVERIFIED=1 covers a missing digest only; it never excuses a wrong one."
    fi
    >&2 echo ""
    return 1
}
# --- REGION: Fetch evidence
fae_note() {
    printf '# %s: %s\n' "$1" "$2" >> "$fae_log" 2>/dev/null || true
}

fae_safe_url() {
    local value="$1" prefix authority rest query
    [ -z "${GH_TOKEN:-}" ] || value="${value//"$GH_TOKEN"/[REDACTED]}"
    case "$value" in
        *://*)
            prefix="${value%%://*}://"
            rest="${value#*://}"
            authority="${rest%%/*}"
            case "$authority" in *@*) value="${prefix}[REDACTED]@${rest#*@}" ;; esac
            ;;
    esac
    value="${value%%#*}"
    case "$value" in
        *\?*)
            query="${value#*\?}"
            [[ "$query" =~ ^ref=([[:xdigit:]]{40}|[[:xdigit:]]{64})$ ]] \
                || value="${value%%\?*}?[REDACTED]"
            ;;
    esac
    printf '%s' "$value"
}

# Keep only the numeric HTTP status; response headers can contain credentials.
fae_download() {
    local destination="$1" url="$2" headers download_rc
    fae_note phase downloading
    fae_note url "$(fae_safe_url "$url")"
    headers=$(mktemp /tmp/yuruna-fae-response.XXXXXX 2>/dev/null) || return 3
    wget --timeout=20 --tries=2 --server-response "${WGET_FETCH_FLAGS[@]}" -qO "$destination" "$url" 2>"$headers"
    download_rc=$?
    fae_http_status=$(awk '/^[[:space:]]*HTTP\/[0-9.]+[[:space:]]+[0-9][0-9][0-9]/ { code=$2 } END { print code }' "$headers")
    rm -f "$headers" 2>/dev/null || true
    fae_note http-status "${fae_http_status:-unavailable}"
    fae_note wget-exit "$download_rc"
    return "$download_rc"
}

QUERY_PARAMS="${EXEC_QUERY_PARAMS:-${YurunaCacheContent:+?nocache=${YurunaCacheContent}}}"
FETCH_REQUEST_PATH="$1"
FILE_PATH="${FETCH_REQUEST_PATH%%\?*}"
SCRIPT_ARGUMENTS=("${@:2}")

if [ -z "$FILE_PATH" ]; then
    echo "Usage: E_SHA=<sha256 of the file> $0 <file-path>"
    echo "  The file's SHA-256 is required. EXEC_ALLOW_UNVERIFIED=1 waives it for manual recovery."
    exit 1
fi

# Generated platform wrappers can delegate to another fetch in the same invocation.
# Keep its outer identity while the payload path follows the child being executed.
FAE_INVOCATION_SCRIPT="${FAE_INVOCATION_SCRIPT:-$FILE_PATH}"
fae_identity_error=0
if [[ ! "$FAE_INVOCATION_SCRIPT" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
   || [[ "/$FAE_INVOCATION_SCRIPT/" == *'/../'* ]]; then
    fae_identity_error=1
    FAE_INVOCATION_SCRIPT='invalid-invocation'
fi
export FAE_INVOCATION_SCRIPT

# Replace the previous invocation before any source probe or download can fail.
fae_log='/tmp/yuruna-last-fetch-and-execute.log'
fae_log_completed=0
{
    echo '# Yuruna fetch-and-execute log'
    printf '# script:    %s\n' "$FAE_INVOCATION_SCRIPT"
    printf '# payload-script: %s\n' "$FILE_PATH"
    printf '# started:   %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '# stepInvocationId: %s\n' "${E_SI:-}"
    printf '# sequenceInvocationId: %s\n' "${E_QI:-}"
    echo '# ---'
} > "$fae_log" 2>/dev/null || true
fae_note phase resolving-source
if [ "$fae_identity_error" = 1 ]; then
    >&2 echo '!! INVALID FETCH INVOCATION: FAE_INVOCATION_SCRIPT must be a relative repository path.'
    fae_note phase invalid-invocation
    exit 1
fi

clear

# See https://yuruna.link/42fa6f45-0009
# Avoid fetch/execute words that fuzzy OCR can match against the echoed command.
echo "About to download and run project code: $FILE_PATH"

# --- REGION: https://yuruna.link/42fa6f45-0008
# Wait for IPv4 before source resolution, sharing the budget with post-fetch recovery.
if [ -r /usr/local/lib/yuruna/yuruna-network.sh ]; then
    # shellcheck disable=SC1091
    . /usr/local/lib/yuruna/yuruna-network.sh
fi

# See https://yuruna.link/42fa6f45-0008
# Share one address-wait budget across both recovery points.
fae_ipv4_budget="${YURUNA_FETCH_IPV4_WAIT:-180}"

# See https://yuruna.link/42fa6f45-0008
# Nudge address-less clients partway through the shared wait; preserve healthy links.
fae_await_ipv4() {
    command -v yuruna_wait_ipv4 >/dev/null 2>&1 || return 1
    yuruna_has_ipv4 && return 0
    [ "$fae_ipv4_budget" -gt 0 ] || return 1
    local budget="$fae_ipv4_budget" nudge_at=60 start="$SECONDS" spent rc=1
    [ "$nudge_at" -gt "$budget" ] && nudge_at="$budget"
    echo "  no IPv4 address yet -- waiting up to ${budget}s for a lease before giving up"
    if yuruna_wait_ipv4 "$nudge_at"; then
        rc=0
    elif [ "$budget" -gt "$nudge_at" ]; then
        if command -v yuruna_net_repair_ipv4 >/dev/null 2>&1; then
            echo "  no lease after ${nudge_at}s -- re-kicking address acquisition before waiting out the rest"
            yuruna_net_repair_ipv4
        fi
        yuruna_wait_ipv4 "$((budget - nudge_at))" && rc=0
    fi
    spent=$((SECONDS - start))
    fae_ipv4_budget=$((fae_ipv4_budget - spent))
    [ "$fae_ipv4_budget" -lt 0 ] && fae_ipv4_budget=0
    [ "$rc" -eq 0 ] || echo "  still no IPv4 after ${spent}s -- the wait is exhausted, not skipped"
    return "$rc"
}

fae_await_ipv4
resolve_fetch_source
# See https://yuruna.link/42fa6f45-0003
# Only a verified host source can receive local performance checkpoints.
if [ "$FETCH_SOURCE" = 'host' ]; then BASE_SOURCE='host'; else BASE_SOURCE='github'; fi
fae_note source "$FETCH_SOURCE"

# See https://yuruna.link/42fa6f45-0003
# No reachable host and no repository pin means no valid fetch source.
if [ "$FETCH_SOURCE" = 'github' ] && ! github_fetch_coordinates "$FILE_PATH"; then
    fae_note phase source-unavailable
    case "$FILE_PATH" in
        project/*)
            fae_note reason 'project fallback requires E_PROJECT_REPO and E_PROJECT_REF'
            printf "\n    NONZERO SCRIPT EXIT:\n    %s (no pinned project fetch source)\n\n" "$FILE_PATH"
            exit 2
            ;;
    esac
    echo ""
    echo "!! NO FETCH SOURCE"
    echo "!!   The host status service is unreachable and no GitHub fallback was"
    echo "!!   supplied, so there is nowhere to fetch this file from."
    echo "!!   Wanted: E_FB_REPO + E_FB_REF (typed by the host),"
    echo "!!           or YURUNA_GITHUB_REPO + YURUNA_GITHUB_REF in /etc/yuruna/host.env."
    echo "!!   Refusing to guess at another repository."
    echo ""
    printf "\n    NONZERO SCRIPT EXIT:\n    %s (no fetch source)\n\n" "$FILE_PATH"
    fae_note reason 'no pinned framework fetch source'
    exit 2
fi
if [ "$FETCH_SOURCE" = 'github' ]; then
    fae_note repository "$GITHUB_FETCH_REPO"
    fae_note revision "$GITHUB_FETCH_REF"
fi

# See https://yuruna.link/42fa6f45-0003
# An unauthenticated fallback cannot read private repositories; explain this before requesting.
if [ "$FETCH_SOURCE" = 'github' ] && [ -z "${GH_TOKEN:-}" ]; then
    echo ""
    echo "!! GITHUB FALLBACK IS UNAUTHENTICATED"
    echo "!!   repo:   ${GITHUB_FETCH_REPO} at ${GITHUB_FETCH_REF}"
    case "$FILE_PATH" in project/*) echo '!!   project authentication: GH_TOKEN is absent; only public project content is readable.' ;; esac
    echo "!!   route:  raw.githubusercontent.com -- public repositories only"
    echo "!!   effect: if that repository is private this leg can only 404, so"
    echo "!!           there is no working alternative to the host right now."
    # See https://yuruna.link/42fa6f45-0008
    # Point to host credential evidence; the guest cannot prove project access.
    echo "!!   check:  a private project needs a guest GH_TOKEN with repository access."
    echo "!!           The host's git credential is separate; check its access too:"
    echo "!!           in a pool: Pool Control -> Hosts, the 'Project'"
    echo "!!           column for this host. DENIED means the credential cannot"
    echo "!!           read the project its pool assigned, and no retry fixes"
    echo "!!           that; unreachable means network rather than permission."
    echo "!!           standalone: run 'pwsh test/Test-Config.ps1' on the host."
    echo ""
fi

if ! wget_flags_for_source; then
    fae_note phase authentication-unavailable
    fae_note reason 'could not prepare a private wget credential configuration'
    >&2 echo '!! GITHUB AUTHENTICATION UNAVAILABLE: could not prepare a private wget credential configuration.'
    printf "\n    NONZERO SCRIPT EXIT:\n    %s (guest authentication unavailable)\n\n" "$FILE_PATH"
    exit 2
fi
FULL_URL="$(build_fetch_url "$FETCH_REQUEST_PATH")"
fae_display_url="$(fae_safe_url "$FULL_URL")"

# See https://yuruna.link/42fa6f45-0005
# Hash exact downloaded bytes; command substitution strips trailing newlines.
fetch_tmp="$(mktemp /tmp/yuruna-fae-payload.XXXXXX 2>/dev/null)"
if [ -z "$fetch_tmp" ]; then
    fae_note phase download-failed
    fae_note reason 'could not create payload temp file'
    printf "\n    NONZERO SCRIPT EXIT:\n    %s (could not create temp file)\n\n" "$FILE_PATH"
    exit 2
fi
# See https://yuruna.link/42fa6f45-0008
# Bound half-open downloads before they consume the entire step budget.
fae_download "$fetch_tmp" "$FULL_URL"
wget_rc=$?
byte_count=$(wc -c < "$fetch_tmp" 2>/dev/null | tr -d '[:space:]')
[ -z "$byte_count" ] && byte_count=0

echo "  url: $fae_display_url"
echo "  source: $BASE_SOURCE"

# --- REGION: https://yuruna.link/42fa6f45-0008
# Retry a lost address only within the remaining pre-resolution wait budget.
if { [ "$wget_rc" -ne 0 ] || [ "$byte_count" -eq 0 ]; } \
   && { [ "$wget_rc" -eq 4 ] || [ "$wget_rc" -eq 5 ] || [ "$wget_rc" -eq 7 ]; }; then
    if command -v yuruna_has_ipv4 >/dev/null 2>&1 && ! yuruna_has_ipv4; then
        if fae_await_ipv4; then
            echo "  retrying the fetch now that this guest holds an address"
            fae_download "$fetch_tmp" "$FULL_URL"
            wget_rc=$?
            byte_count=$(wc -c < "$fetch_tmp" 2>/dev/null | tr -d '[:space:]')
            [ -z "$byte_count" ] && byte_count=0
        fi
    fi
fi

if [ "$wget_rc" -ne 0 ] || [ "$byte_count" -eq 0 ]; then
    rm -f "$fetch_tmp" 2>/dev/null || true
    echo ""
    echo "!! FETCH FAILED"
    echo "!!   url:        $fae_display_url"
    echo "!!   wget exit:  $wget_rc -- $(classify_wget_rc "$wget_rc" "$FULL_URL")"
    echo "!!   HTTP:       ${fae_http_status:-unavailable}"
    echo "!!   bytes read: $byte_count"
    fae_note phase download-failed
    fae_note bytes "$byte_count"
    fae_note reason "fetch failed, wget exit $wget_rc, HTTP ${fae_http_status:-unavailable}"
    # See https://yuruna.link/42fa6f45-0008
    # Discuss repository access and commit pins only after the server actually answered.
    if [ "$FETCH_SOURCE" = 'github' ]; then
        echo "!!   repo:       ${GITHUB_FETCH_REPO} at ${GITHUB_FETCH_REF}"
        case "$wget_rc" in
            4|5|7)
                echo "!!   reached:    no -- the request never got to GitHub, so the repo,"
                echo "!!               the commit and the token are not implicated here."
                echo "!!               See the NETWORK DIAGNOSTIC below for the real fault."
                ;;
            *)
                if [ -n "${GH_TOKEN:-}" ]; then
                    echo "!!   auth:       GH_TOKEN present (Contents API)"
                    echo "!!               Check that this guest credential can read the named repository."
                else
                    echo "!!   auth:       no GH_TOKEN -- a private repository will 404 here"
                    echo "!!               A private project requires guest authentication; host git access alone is insufficient."
                    # See https://yuruna.link/42fa6f45-0008
                    # The host records credential access; report its evidence location after a server response.
                    echo "!!   access:     in a pool, Pool Control -> Hosts shows this host's"
                    echo "!!               'Project' column. DENIED means its credential"
                    echo "!!               cannot read the assigned project and no retry"
                    echo "!!               fixes that; unreachable means network instead."
                    echo "!!               Standalone: run 'pwsh test/Test-Config.ps1'."
                fi
                echo "!!   check:      is that commit pushed to the remote? a commit that"
                echo "!!               exists only on the host cannot be fetched from GitHub."
                ;;
        esac
    fi
    echo ""
    # See https://yuruna.link/42fa6f45-0008
    # Show connectivity after bounded recovery; an address wait cannot fix every transport fault.
    if [ -r /usr/local/lib/yuruna/yuruna-network.sh ]; then
        # shellcheck disable=SC1091
        . /usr/local/lib/yuruna/yuruna-network.sh
        command -v network_diag >/dev/null 2>&1 && network_diag
    fi
    # --- REGION: https://yuruna.link/42fa6f45-0008
    # See https://yuruna.link/42fa6f45-0009
    # NONZERO avoids fuzzy OCR matches against the echoed fetch-and-execute command.
    printf "\n    NONZERO SCRIPT EXIT:\n    %s (fetch failed, wget exit %d)\n\n" "$FILE_PATH" "$wget_rc"
    exit 2
fi

echo "  bytes: $byte_count"

# See https://yuruna.link/42fa6f45-0005
# Retry one digest mismatch to absorb a concurrent edit; still refuse unmatched bytes.
EXPECTED_SHA="${E_SHA:-${EXEC_SHA256:-}}"
fae_note phase verifying-integrity
if verify_sha256 "$fetch_tmp" "$EXPECTED_SHA" "$FILE_PATH"; then
    :
elif [ -n "$EXPECTED_SHA" ] \
     && fae_download "$fetch_tmp" "$FULL_URL" \
     && verify_sha256 "$fetch_tmp" "$EXPECTED_SHA" "$FILE_PATH"; then
    echo "  integrity: verified on re-fetch (absorbed a concurrent-edit race)"
else
    fae_note phase integrity-failed
    rm -f "$fetch_tmp" 2>/dev/null || true
    # Two refusals, two reasons. The host treats neither as a shortage worth a
    # retry, and the wording must not claim a mismatch when nothing was compared.
    if [ -z "$EXPECTED_SHA" ]; then
        printf "\n    NONZERO SCRIPT EXIT:\n    %s (no expected digest -- refusing to run)\n\n" "$FILE_PATH"
    else
        printf "\n    NONZERO SCRIPT EXIT:\n    %s (integrity mismatch -- refusing to run)\n\n" "$FILE_PATH"
    fi
    exit 3
fi
fae_unverified=''
if [ -z "$EXPECTED_SHA" ]; then fae_unverified=1; fi
fae_payload_sha256=$(sha256sum -- "$fetch_tmp" 2>/dev/null) || fae_payload_sha256=$(shasum -a 256 -- "$fetch_tmp" 2>/dev/null) || fae_payload_sha256=''
fae_payload_sha256=${fae_payload_sha256%% *}
script_content="$(cat "$fetch_tmp")"
if command -v sha256sum >/dev/null 2>&1; then
    fae_executed_sha256=$(printf '%s' "$script_content" | sha256sum)
else
    fae_executed_sha256=$(printf '%s' "$script_content" | shasum -a 256 2>/dev/null) || fae_executed_sha256=''
fi
fae_executed_sha256=${fae_executed_sha256%% *}
rm -f "$fetch_tmp" 2>/dev/null || true
echo ""

# --- REGION: https://yuruna.link/42d69dfa-003a
# Install a missing retry library only after network resolution and digest verification.
YURUNA_LIB_DIR=/usr/local/lib/yuruna
YURUNA_RETRY_LIB="$YURUNA_LIB_DIR/yuruna-retry.sh"
if [ ! -r "$YURUNA_RETRY_LIB" ]; then
    # See https://yuruna.link/42fa6f45-0005
    # Hash exact downloaded bytes; command substitution strips trailing newlines.
    lib_tmp="$(mktemp /tmp/yuruna-fae-retrylib.XXXXXX 2>/dev/null)"
    if [ -n "$lib_tmp" ] \
         && lib_url="$(build_fetch_url 'automation/yuruna-retry.sh')" \
         && fae_download "$lib_tmp" "$lib_url" \
         && [ -s "$lib_tmp" ] \
         && verify_sha256 "$lib_tmp" "${E_RETRY_SHA:-${EXEC_RETRY_SHA256:-}}" "automation/yuruna-retry.sh" E_RETRY_SHA; then
        sudo mkdir -p "$YURUNA_LIB_DIR" 2>/dev/null
        if sudo cp "$lib_tmp" "$YURUNA_RETRY_LIB" 2>/dev/null; then
            sudo chmod 0644 "$YURUNA_RETRY_LIB"
        fi
    fi
    [ -n "$lib_tmp" ] && rm -f "$lib_tmp" 2>/dev/null || true
fi
# shellcheck disable=SC1090
[ -r "$YURUNA_RETRY_LIB" ] && . "$YURUNA_RETRY_LIB"

# See https://yuruna.link/42fa6f45-0005
# Drop the manual waiver before the payload so nested downloads need their own digests.
unset EXEC_ALLOW_UNVERIFIED

# --- REGION: https://yuruna.link/4220a755-0015
# Repair stale bump trust at every payload boundary; failure remains nonfatal here.
if command -v yuruna_ca_selfheal >/dev/null 2>&1; then
    yuruna_ca_selfheal || true
fi

# --- REGION: Execute payload
# A recorder runs independently of SSH and of the payload's output pipeline.
# Its process names omit argv and environment; kernel text is filtered before
# it reaches either the bounded local ring or the host's existing upload route.
fae_recorder_redact() {
    local flags=()
    # mawk buffers input from pipes unless interactive mode is explicit; a
    # killed collector must retain even a short line written before its stall.
    if [[ $(awk -W version 2>&1) == mawk* ]]; then flags=(-W interactive); fi
    LC_ALL=C awk "${flags[@]}" -v byteCap="${FAE_RECORDER_BYTE_CAP:-0}" '
        function emit(text, remaining, size) {
            size=length(text)+1
            if (byteCap>0 && bytes+size>byteCap) {
                remaining=byteCap-bytes
                if (remaining>0) printf "%s",substr(text,1,remaining)
                fflush(); exit
            }
            print text; bytes+=size; fflush()
            if (byteCap>0 && bytes>=byteCap) exit
        }
        BEGIN {
            for (key in ENVIRON)
                if (toupper(key) ~ /(TOKEN|PASSWORD|PASSWD|SECRET|PRIVATE_KEY|CREDENTIAL)/ && length(ENVIRON[key]) >= 4)
                    { secret[++count] = ENVIRON[key]
                      parts=split(ENVIRON[key], part, /[\r\n]+/)
                      for (j=1;j<=parts;j++) if (length(part[j]) >= 4) secret[++count]=part[j]
                    }
        }
        /-----BEGIN .*PRIVATE KEY-----/ { privatekey=1 }
        privatekey { if (/-----END .*PRIVATE KEY-----/) privatekey=0; emit("[REDACTED PRIVATE KEY]"); next }
        {
            hidden=0
            for (i=1;i<=count;i++) if (index($0,secret[i])) hidden=1
            lower=tolower($0)
            if (hidden || lower ~ /(token|password|passwd|secret|credential|private_key)[a-z0-9_]*[[:space:]]*[:=]/ ||
                lower ~ /authorization[[:space:]]*:/ || $0 ~ /gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]+/)
                emit("[REDACTED SECRET]")
            else emit($0)
        }'
}

# --- REGION: Prearmed kernel evidence
# The kernel uploader owns its HTTP stream independently of SSH, the payload,
# and the slower process collector. Unchanged evidence uploads once per minute
# so a stalled process sample can be distinguished from a stalled uploader.
# shellcheck disable=SC2317 # Invoked in the exported collector child shell.
fae_kernel_collect() {
    local recorder_priv=()
    if [ "$(id -u)" != 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then recorder_priv=(sudo -n); fi
    "${recorder_priv[@]}" journalctl -k -b --no-pager -n 60 -o short-monotonic 2>&1
}

fae_kernel_upload() {
    local folder=$1 upload=not-configured path="$1/kernel-upload.$BASHPID.txt"
    {
        printf 'kernelUploadSchema=1\nsource=prearmed-kernel-and-execution-recorder\n'
        printf 'uploadCreatedUtc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
        if [ -r "$folder/evidence.txt" ]; then
            printf '\n--- cached execution evidence ---\n'
            head -c 1100000 -- "$folder/evidence.txt"
        else
            printf '\nexecutionEvidence=not-yet-available\n'
            if [ -r "$folder/metadata.txt" ]; then head -c 32768 -- "$folder/metadata.txt"; fi
        fi
        printf '\n--- independent kernel evidence ---\n'
        head -c 140000 -- "$folder/kernel.evidence.txt" 2>/dev/null || true
    } > "$path"
    if [ -n "${E_RECORDER_URL:-}" ]; then
        upload=failed
        if timeout --signal=TERM --kill-after=1 6 wget --no-proxy --quiet --timeout=5 --tries=1 \
            --header='Content-Type: text/plain' --post-file="$path" -O /dev/null "$E_RECORDER_URL" 2>/dev/null; then upload=complete; fi
    fi
    rm -f -- "$path"
    printf '%s' "$upload"
}

fae_kernel_loop() {
    local owner=$1 folder=$2 interval=${3:-5} limit=${4:-1440} producer=${5:-} heartbeat=${6:-60} index=0 started=$SECONDS before slot path
    local collector_pid sample_rc bytes truncated upload=not-configured signature previous_signature='' last_upload=$SECONDS
    export E_SI E_QI GH_TOKEN
    export -f fae_kernel_collect fae_recorder_redact
    while [ "$index" -lt "$limit" ] && [ "$((SECONDS-started))" -lt 7200 ] && \
        { [ "$index" -eq 0 ] || kill -0 "$owner" 2>/dev/null; } && \
        { [ "$index" -eq 0 ] || [ ! -e "$folder/stop" ]; }; do
        before=$SECONDS; slot=$((index % 4))
        timeout --signal=TERM --kill-after=1 2 bash -c \
            'set -o pipefail; fae_kernel_collect 2>&1 | FAE_RECORDER_BYTE_CAP=32768 fae_recorder_redact' \
            > "$folder/kernel.sample.$slot" 2>/dev/null &
        collector_pid=$!
        sample_rc=0; wait "$collector_pid" || sample_rc=$?
        kill -TERM -- "-$collector_pid" 2>/dev/null || true
        kill -KILL -- "-$collector_pid" 2>/dev/null || true
        bytes=$(wc -c < "$folder/kernel.sample.$slot")
        truncated=false; [ "$bytes" -ge 32768 ] && truncated=true
        {
            printf 'kernelRecorderSchema=1\nkernelRecorderState=running\n'
            printf 'stepInvocationId=%s\nsequenceInvocationId=%s\nkernelHeartbeatUtc=%s\n' "${E_SI:-}" "${E_QI:-}" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
            printf 'kernelSampleIndex=%s kernelSampleExitCode=%s kernelSampleBytes=%s kernelSampleTruncated=%s\n' "$index" "$sample_rc" "$bytes" "$truncated"
            printf 'kernelIntervalSeconds=%s kernelHeartbeatSeconds=%s kernelMaxSamples=%s kernelMaxSeconds=7200 kernelRetainedSamples=4 kernelSampleByteCap=32768\n' "$interval" "$heartbeat" "$limit"
            for path in "$folder"/kernel.sample.*; do [ -f "$path" ] && cat -- "$path"; done
        } > "$folder/kernel.evidence.next"
        mv -f -- "$folder/kernel.evidence.next" "$folder/kernel.evidence.txt"
        signature=$( { cksum < "$folder/kernel.sample.$slot"; printf 'exit=%s\n' "$sample_rc"; if [ -r "$folder/evidence.txt" ]; then cksum < "$folder/evidence.txt"; fi; } 2>/dev/null)
        if [ "$signature" != "$previous_signature" ] || [ "$((SECONDS-last_upload))" -ge "$heartbeat" ]; then
            upload=$(fae_kernel_upload "$folder")
            if [ "$upload" != failed ]; then previous_signature=$signature; last_upload=$SECONDS; fi
        fi
        printf 'state=running sampleIndex=%s upload=%s heartbeatUtc=%s\n' "$index" "$upload" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" > "$folder/kernel.status"
        index=$((index + 1))
        for ((before=0; before<interval; before++)); do
            [ -e "$folder/stop" ] && break
            [ "$index" -ge "$limit" ] && break
            [ "$((SECONDS-started))" -ge 7200 ] && break
            kill -0 "$owner" 2>/dev/null || break
            sleep 1
        done
    done
    # A payload can finish while the slower collector still owns a partial
    # sample. Its final atomic evidence update must precede our last upload.
    if [ -n "$producer" ]; then
        before=$SECONDS
        while [ ! -e "$folder/recorder.finalized" ] && kill -0 "$producer" 2>/dev/null && [ "$((SECONDS-before))" -lt 12 ]; do
            sleep 0.25
        done
    fi
    if [ -r "$folder/kernel.evidence.txt" ]; then
        sed 's/^kernelRecorderState=running$/kernelRecorderState=stopped/' "$folder/kernel.evidence.txt" > "$folder/kernel.evidence.next"
        printf '\nkernelRecorderEndedUtc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >> "$folder/kernel.evidence.next"
        mv -f -- "$folder/kernel.evidence.next" "$folder/kernel.evidence.txt"
        upload=$(fae_kernel_upload "$folder")
    fi
    printf 'state=stopped samples=%s upload=%s endedUtc=%s\n' "$index" "$upload" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" > "$folder/kernel.status"
}

fae_start_kernel_recorder() {
    local owner=$1 folder=$2 producer=$BASHPID
    [ "${EXEC_KERNEL_RECORDER:-1}" != 0 ] || return 1
    command -v journalctl >/dev/null 2>&1 || return 1
    command -v timeout >/dev/null 2>&1 || return 1
    fae_kernel_loop "$owner" "$folder" 5 1440 "$producer" >/dev/null 2>&1 &
    return 0
}

# --- REGION: guest_evidence_clock
# /proc/uptime uses BOOTTIME; label it separately from CLOCK_MONOTONIC.
guest_evidence_clock() {
    local uptime idle boot online ticks
    read -r uptime idle < /proc/uptime || true
    read -r boot < /proc/sys/kernel/random/boot_id || true
    read -r online < /sys/devices/system/cpu/online || true
    ticks=$(getconf CLK_TCK 2>/dev/null) || ticks=unavailable
    printf 'guestEvidenceSchema=2\nguestClockUtc=%s\nguestClockEpochSeconds=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" "$(date -u +%s.%N)"
    printf 'guestClockUptimeSeconds=%s\nguestClockIdleSeconds=%s\nguestClockUptimeClock=boottime\n' "${uptime:-unavailable}" "${idle:-unavailable}"
    printf 'guestClockTicksPerSecond=%s\nguestBootId=%s\nguestOnlineCpus=%s\n' "${ticks:-unavailable}" "${boot:-unavailable}" "${online:-unavailable}"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print("guestClockMonotonicSeconds=%.9f" % time.clock_gettime(time.CLOCK_MONOTONIC)); print("guestClockBoottimeSeconds=%.9f" % time.clock_gettime(time.CLOCK_BOOTTIME))' 2>/dev/null || printf 'guestClockMonotonicSeconds=unavailable\n'
    else
        printf 'guestClockMonotonicSeconds=unavailable\nguestClockBoottimeSeconds=%s\n' "${uptime:-unavailable}"
    fi
}

# --- REGION: guest_evidence_safe_path
# Refuse symlinked source paths rather than digesting files outside a checkout.
guest_evidence_safe_path() {
    local path=$1
    [[ $path == /* && $path != *'/../'* && $path != */.. ]] || return 1
    while [ "$path" != / ]; do
        [ ! -L "$path" ] || return 1
        path=${path%/*}; [ -n "$path" ] || path=/
    done
}

# --- REGION: guest_evidence_hash
# Bound both source bytes and labels; a digest never exposes source contents.
guest_evidence_hash() {
    local label=$1 path=$2 bytes digest
    if ! guest_evidence_safe_path "$path"; then printf 'guestProvenance.%s.sha256=unsafe-path\n' "$label"; return; fi
    if [ ! -f "$path" ]; then printf 'guestProvenance.%s.sha256=absent\n' "$label"; return; fi
    bytes=$(stat -c %s -- "$path" 2>/dev/null) || bytes=''
    if [[ ! $bytes =~ ^[0-9]+$ ]] || [ "$bytes" -gt 4194304 ]; then printf 'guestProvenance.%s.sha256=size-unavailable-or-over-4194304\n' "$label"; return; fi
    digest=$(sha256sum -- "$path" 2>/dev/null) || digest=''
    digest=${digest%% *}
    [[ $digest =~ ^[0-9a-f]{64}$ ]] || digest=unavailable
    printf 'guestProvenance.%s.sha256=%s\n' "$label" "$digest"
}

# --- REGION: guest_evidence_revision
# An archive nested inside another Git checkout must not inherit its parent's HEAD.
guest_evidence_revision() {
    local label=$1 root=$2 revision='' source=unavailable top bytes
    if ! guest_evidence_safe_path "$root"; then source=unsafe-path
    elif [ -e "$root/.git" ] || [ -L "$root/.git" ]; then
        source=invalid-git
        if guest_evidence_safe_path "$root/.git" && { [ -d "$root/.git" ] || [ -f "$root/.git" ]; } && command -v git >/dev/null 2>&1; then
            top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || top=''
            if [ "$top" = "$root" ]; then
                revision=$(git -C "$root" rev-parse --verify HEAD 2>/dev/null) || revision=''
                if [[ $revision =~ ^[0-9a-fA-F]{40}$ || $revision =~ ^[0-9a-fA-F]{64}$ ]]; then source=git; else revision=''; fi
            fi
        elif ! guest_evidence_safe_path "$root/.git"; then source=unsafe-path; fi
    elif [ -e "$root/.yuruna-revision" ] || [ -L "$root/.yuruna-revision" ]; then
        source=invalid-archive
        if guest_evidence_safe_path "$root/.yuruna-revision" && [ -f "$root/.yuruna-revision" ]; then
            bytes=$(stat -c %s -- "$root/.yuruna-revision" 2>/dev/null) || bytes=''
            if [[ $bytes =~ ^[0-9]+$ ]] && [ "$bytes" -le 256 ]; then
                revision=$(head -c 256 -- "$root/.yuruna-revision" 2>/dev/null)
                if [[ $revision =~ ^[0-9a-fA-F]{40}$ || $revision =~ ^[0-9a-fA-F]{64}$ ]]; then source=archive; else revision=''; fi
            fi
        else source=unsafe-path; fi
    fi
    printf 'guestProvenance.%s.revision=%s\nguestProvenance.%s.revisionSource=%s\n' "$label" "${revision:-unavailable}" "$label" "$source"
}
# --- REGION: guest_evidence_provenance
# Fixed source paths identify guest materialization independently of host status SHAs.
guest_evidence_provenance() {
    local user_home=${HOME:-} root path passwd
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && command -v getent >/dev/null 2>&1; then
        passwd=$(getent passwd "$SUDO_USER" 2>/dev/null) || passwd=''
        IFS=: read -r _ _ _ _ _ user_home _ <<< "$passwd"
    fi
    case "$user_home" in /*) ;; *) printf 'guestProvenance.state=home-unavailable\n'; return ;; esac
    root=${user_home%/}/yuruna
    guest_evidence_revision framework "$root"
    guest_evidence_revision project "$root/project"
    for path in automation/fetch-and-execute.sh automation/yuruna-retry.sh guest/shared/ubuntu.update.sh guest/ubuntu.server.24/ubuntu.server.24.k8s.sh guest/ubuntu.server.26/ubuntu.server.26.k8s.sh; do
        guest_evidence_hash "framework.$path" "$root/$path"
    done
    for path in tools/example-workload.sh tools/Example.Build.psm1 example/website/components/frontend/website/{Dockerfile,Example.Build.psm1} example/text-to-sql/components/frontend/text-to-sql-ui/{Dockerfile,Example.Build.psm1}; do
        guest_evidence_hash "project.$path" "$root/project/$path"
    done
    for path in fetch-and-execute.sh yuruna-retry.sh yuruna-fetch-context.sh; do
        guest_evidence_hash "installed.$path" "/usr/local/lib/yuruna/$path"
    done
    if [[ ${FILE_PATH:-} =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] && [[ /${FILE_PATH:-}/ != *'/../'* ]]; then
        guest_evidence_hash localPayload "$root/$FILE_PATH"
    fi
    printf 'fetchedPayloadSha256=%s\nexecutedPayloadSha256=%s\n' "${fae_payload_sha256:-unavailable}" "${fae_executed_sha256:-unavailable}"
}

# --- REGION: guest_evidence_boot_metadata
# Boot metadata is small and stable; the recorder retains it outside its sample ring.
guest_evidence_boot_metadata() {
    local path count=0
    printf '\n--- guest boot metadata ---\nguestKernel=%s\n' "$(uname -srmv 2>/dev/null)"
    for path in /sys/devices/system/clocksource/clocksource*/{current_clocksource,available_clocksource} /sys/devices/system/clockevents/clockevent*/current_device /sys/devices/system/clockevents/broadcast/current_device /sys/devices/system/cpu/{online,present,possible}; do
        [ -r "$path" ] || continue
        printf '\n--- %s ---\n' "$path"; head -c 256 -- "$path" 2>/dev/null
        count=$((count+1)); [ "$count" -ge 80 ] && break
    done
    count=0
    for path in /sys/devices/system/cpu/cpu*/topology/{physical_package_id,core_id,thread_siblings_list}; do
        [ -r "$path" ] || continue
        printf '\n--- %s ---\n' "$path"; head -c 128 -- "$path" 2>/dev/null
        count=$((count+1)); [ "$count" -ge 96 ] && break
    done
    printf '\nbootMetadataAttributes=%s cap=96\n' "$count"
}

# shellcheck disable=SC2317 # Invoked in the exported collector child shell.
fae_recorder_read() {
    local path=$1 cap=${2:-8192}
    printf '\n--- %s ---\n' "$path"
    if [ "${#recorder_priv[@]}" -gt 0 ]; then
        # The privileged shell tests accessibility as the reader, not its caller.
        # shellcheck disable=SC2016
        "${recorder_priv[@]}" sh -c '
            if [ ! -e "$1" ]; then printf "state=absent\n";
            elif [ ! -r "$1" ]; then printf "state=denied\n";
            else head -c "$2" -- "$1" 2>&1 || printf "state=read-error\n"; fi
        ' sh "$path" "$cap"
    elif [ ! -e "$path" ]; then printf 'state=absent\n'
    elif [ ! -r "$path" ]; then printf 'state=denied\n'
    else head -c "$cap" -- "$path" 2>&1 || printf 'state=read-error\n'; fi
}

# shellcheck disable=SC2317 # Invoked by timeout through bash -c.
fae_recorder_collect() {
    local pid tid cpu pcpu state name path cgroup count=0
    local -A sampled_process=()
    export LC_ALL=C
    local recorder_priv=()
    if [ "$(id -u)" != 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then recorder_priv=(sudo -n); fi
    printf 'sampleUtc=%s\nstepInvocationId=%s\nsequenceInvocationId=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" "${E_SI:-}" "${E_QI:-}"
    guest_evidence_clock
    for path in /proc/sys/kernel/random/boot_id /proc/uptime /proc/stat /proc/loadavg \
        /proc/pressure/{cpu,io,memory} /proc/{meminfo,vmstat,interrupts,softirqs,diskstats}; do
        fae_recorder_read "$path" 8192
    done
    for path in /sys/fs/cgroup/{memory.events,memory.events.local,memory.current,memory.max,memory.high,memory.swap.current,memory.swap.max,memory.stat,memory.pressure} /sys/fs/cgroup/memory/{memory.failcnt,memory.usage_in_bytes,memory.limit_in_bytes,memory.oom_control}; do
        [ -e "$path" ] && fae_recorder_read "$path" 4096
    done
    printf '\n--- per-thread CPU/state (no command arguments) ---\n'
    # Include a bounded CPU-ranked inventory as context even when the sampled
    # owner has stopped running by the instant its state is read.
    ps -eLo pid=,lwp=,psr=,pcpu=,stat=,comm= 2>&1 | sort -k4,4nr | head -n 64
    while read -r pid tid cpu pcpu state name; do
        case "$state" in R*|D*) ;; *) [ "${pcpu%.*}" -ge 20 ] 2>/dev/null || continue ;; esac
        printf '\nthread pid=%s tid=%s cpu=%s cpuLifetimePercent=%s state=%s comm=%s\n' "$pid" "$tid" "$cpu" "$pcpu" "$state" "$name"
        if [ -z "${sampled_process[$pid]:-}" ]; then
            sampled_process[$pid]=1
            fae_recorder_read "/proc/$pid/stat" 4096
            fae_recorder_read "/proc/$pid/cgroup" 4096
            cgroup=$(awk -F: '$1=="0" && $2=="" {print $3;exit}' "/proc/$pid/cgroup" 2>/dev/null)
            if [[ $cgroup == /* && $cgroup != *'/../'* && $cgroup != */.. ]]; then
                for path in memory.events memory.events.local memory.current memory.max memory.high memory.swap.current memory.stat memory.pressure; do
                    fae_recorder_read "/sys/fs/cgroup${cgroup%/}/$path" 2048
                done
            fi
        fi
        for path in stat schedstat wchan stack; do fae_recorder_read "/proc/$pid/task/$tid/$path" 4096; done
        count=$((count + 1))
        [ "$count" -ge 16 ] && break
    done < <(ps -eLo pid=,lwp=,psr=,pcpu=,stat=,comm= 2>/dev/null | sort -k4,4nr)
    printf '\nthreadStackSamples=%s cap=16; absent/denied stacks are reported above\n' "$count"
    count=0
    for path in /sys/bus/vmbus/devices/*/channels/*/{cpu,interrupts,events,latency}; do
        [ -e "$path" ] || continue
        fae_recorder_read "$path" 1024
        count=$((count + 1)); [ "$count" -ge 64 ] && break
    done
    printf '\nvmbusAttributeSamples=%s cap=64\n' "$count"
    if command -v journalctl >/dev/null 2>&1; then
        "${recorder_priv[@]}" journalctl -k -b --no-pager -n 30 -o short-monotonic 2>&1 | head -c 32768
    else printf 'kernelJournal=unavailable\n'; fi
    printf '\nsampleCompleteUtc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
}

fae_recorder_loop() {
    local owner=$1 folder=$2 interval=$3 limit=$4 index=0 sample_rc upload=not-configured before slot path started=$SECONDS bytes truncated collector_pid
    export E_SI E_QI GH_TOKEN FILE_PATH fae_payload_sha256 fae_executed_sha256
    export -f guest_evidence_clock guest_evidence_safe_path guest_evidence_hash guest_evidence_revision guest_evidence_provenance guest_evidence_boot_metadata
    export -f fae_recorder_read fae_recorder_collect fae_recorder_redact
    if [ -r "$folder/metadata.txt" ]; then :; else
        timeout --signal=TERM --kill-after=1 4 bash -c \
            'set -o pipefail; { guest_evidence_boot_metadata; guest_evidence_provenance; } 2>&1 | FAE_RECORDER_BYTE_CAP=32768 fae_recorder_redact' \
            > "$folder/metadata.txt" 2>/dev/null || true
    fi
    local kernel_uploader=false
    if fae_start_kernel_recorder "$owner" "$folder"; then kernel_uploader=true; upload=delegated-kernel; fi
    while [ "$index" -lt "$limit" ] && [ "$((SECONDS-started))" -lt 7200 ] && { [ "$index" -eq 0 ] || kill -0 "$owner" 2>/dev/null; } && { [ "$index" -eq 0 ] || [ ! -e "$folder/stop" ]; }; do
        before=$SECONDS; slot=$((index % 8))
        # Both the collection time and retained bytes are bounded. Timeout's
        # kill grace also handles a child that ignores its first signal.
        timeout --signal=TERM --kill-after=1 8 bash -c \
            'set -o pipefail; fae_recorder_collect 2>&1 | FAE_RECORDER_BYTE_CAP=131072 fae_recorder_redact' \
            > "$folder/sample.$slot" 2>/dev/null &
        collector_pid=$!
        sample_rc=0
        wait "$collector_pid" || sample_rc=$?
        # GNU timeout owns a process group. Terminate descendants that detached
        # their output before their direct parent exited successfully.
        kill -TERM -- "-$collector_pid" 2>/dev/null || true
        kill -KILL -- "-$collector_pid" 2>/dev/null || true
        bytes=$(wc -c < "$folder/sample.$slot")
        truncated=false; [ "$bytes" -ge 131072 ] && truncated=true
        {
            printf 'recorderSchema=1\nrecorderState=running\nrecorderPid=%s\nownerPid=%s\n' "$BASHPID" "$owner"
            printf 'stepInvocationId=%s\nsequenceInvocationId=%s\nheartbeatUtc=%s\n' "${E_SI:-}" "${E_QI:-}" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
            printf 'sampleIndex=%s\nsampleDurationSeconds=%s\nsampleExitCode=%s\nsampleBytes=%s\nsampleTruncated=%s\npreviousUpload=%s\n' "$index" "$((SECONDS-before))" "$sample_rc" "$bytes" "$truncated" "$upload"
            printf 'intervalSeconds=%s maxSamples=%s maxSeconds=7200 retainedSamples=8 sampleByteCap=131072\n' "$interval" "$limit"
            [ ! -r "$folder/metadata.txt" ] || cat -- "$folder/metadata.txt"
            for path in "$folder"/sample.*; do [ -f "$path" ] && cat -- "$path"; done
        } > "$folder/evidence.next"
        mv -f -- "$folder/evidence.next" "$folder/evidence.txt"
        if [ "$kernel_uploader" != true ] && [ -n "${E_RECORDER_URL:-}" ]; then
            upload=failed
            if timeout --signal=TERM --kill-after=1 6 wget --no-proxy --quiet --timeout=5 --tries=1 \
                --header='Content-Type: text/plain' --post-file="$folder/evidence.txt" -O /dev/null "$E_RECORDER_URL" 2>/dev/null; then upload=complete; fi
        fi
        printf 'state=running sampleIndex=%s upload=%s heartbeatUtc=%s\n' "$index" "$upload" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" > "$folder/status"
        index=$((index + 1))
        # A short interruptible wait bounds orphan lifetime if the invoking
        # shell dies without running its EXIT trap.
        for ((before=0; before<interval; before++)); do
            [ -e "$folder/stop" ] && break
            [ "$index" -ge "$limit" ] && break
            [ "$((SECONDS-started))" -ge 7200 ] && break
            kill -0 "$owner" 2>/dev/null || break
            sleep 1
        done
    done
    if [ -r "$folder/evidence.txt" ]; then
        sed 's/^recorderState=running$/recorderState=stopped/' "$folder/evidence.txt" > "$folder/evidence.next"
        printf '\nrecorderEndedUtc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >> "$folder/evidence.next"
        mv -f -- "$folder/evidence.next" "$folder/evidence.txt"
        if [ "$kernel_uploader" != true ] && [ -n "${E_RECORDER_URL:-}" ]; then
            upload=failed
            if timeout --signal=TERM --kill-after=1 6 wget --no-proxy --quiet --timeout=5 --tries=1 \
                --header='Content-Type: text/plain' --post-file="$folder/evidence.txt" -O /dev/null "$E_RECORDER_URL" 2>/dev/null; then upload=complete; fi
        fi
    fi
    : > "$folder/recorder.finalized"
    : > "$folder/stop"
    printf 'state=stopped samples=%s upload=%s endedUtc=%s\n' "$index" "$upload" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" > "$folder/status"
}

fae_recorder_folder=''
fae_start_recorder() {
    local interval=${EXEC_RECORDER_INTERVAL_SECONDS:-30} limit=${EXEC_RECORDER_MAX_SAMPLES:-240} owner=$BASHPID
    [ "${EXEC_RECORDER:-1}" != 0 ] && [ "${EXEC_PROFILE:-1}" != 0 ] || return 0
    [[ ${E_SI:-} =~ ^[A-Za-z0-9-]{1,64}$ ]] || return 0
    if ! command -v timeout >/dev/null 2>&1; then
        printf '# recorder: unavailable (timeout command absent)\n' >> "$fae_log"
        return 0
    fi
    [[ $interval =~ ^[0-9]+$ ]] && [ "$interval" -ge 1 ] && [ "$interval" -le 300 ] || interval=30
    [[ $limit =~ ^[0-9]+$ ]] && [ "$limit" -ge 1 ] && [ "$limit" -le 240 ] || limit=240
    interval=$((10#$interval))
    limit=$((10#$limit))
    # Reuse the host origin already resolved for this payload. If that host
    # failed its fetch probe, its trusted seed coordinates can recover later.
    if [ -n "${E_RECORDER_PATH:-}" ]; then
        unset E_RECORDER_URL
        if [[ $E_RECORDER_PATH =~ ^diagnostics/([A-Za-z0-9_.-]+/){1,4}[A-Za-z0-9_.-]+\.system\.diagnostic\.[A-Za-z0-9-]+\.txt$ ]] && [[ $E_RECORDER_PATH != *..* ]]; then
            if [[ ${HOST_BASE:-} =~ ^http://[A-Za-z0-9.:-]+/yuruna-repo/$ ]]; then
                E_RECORDER_URL="${HOST_BASE%/yuruna-repo/}/$E_RECORDER_PATH"
            elif [[ ${YURUNA_STATUS_SERVICE_IP:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] &&
                [[ ${YURUNA_STATUS_SERVICE_PORT:-} =~ ^[0-9]{1,5}$ ]] &&
                [ "$YURUNA_STATUS_SERVICE_PORT" -gt 0 ] && [ "$YURUNA_STATUS_SERVICE_PORT" -le 65535 ]; then
                E_RECORDER_URL="http://$YURUNA_STATUS_SERVICE_IP:$YURUNA_STATUS_SERVICE_PORT/$E_RECORDER_PATH"
            fi
        fi
    fi
    # Only the integrity-bound context can provide a usable diagnostic URL.
    if [[ -n ${E_RECORDER_URL:-} ]] && { [[ ! $E_RECORDER_URL =~ ^http://[A-Za-z0-9.:-]+/diagnostics/([A-Za-z0-9_.-]+/){1,4}[A-Za-z0-9_.-]+\.system\.diagnostic\.[A-Za-z0-9-]+\.txt$ ]] || [[ $E_RECORDER_URL == *..* ]]; }; then
        unset E_RECORDER_URL
    fi
    fae_recorder_folder=$(mktemp -d /tmp/yuruna-fae-recorder.XXXXXXXX) || return 0
    chmod 700 "$fae_recorder_folder"
    printf '# recorder: %s\n' "$fae_recorder_folder" >> "$fae_log"
    fae_recorder_loop "$owner" "$fae_recorder_folder" "$interval" "$limit" >/dev/null 2>&1 &
}

fae_stop_recorder() {
    [ -n "$fae_recorder_folder" ] && : > "$fae_recorder_folder/stop"
    return 0
}

# --- REGION: https://yuruna.link/42fa6f45-000a
# Profile Bash 5 payloads through a dedicated trace descriptor, keeping the console clean.
profile_enabled=0
if [ "${EXEC_PROFILE:-1}" != '0' ] && [ -n "${EPOCHREALTIME:-}" ]; then
    profile_enabled=1
fi
ckpt_file=''
profile_file=''
start_epoch=''
if [ "$profile_enabled" = '1' ]; then
    ckpt_file="$(mktemp /tmp/yuruna-fae-ckpts.XXXXXX 2>/dev/null)"      || ckpt_file=''
    profile_file="$(mktemp /tmp/yuruna-fae-profile.XXXXXX 2>/dev/null)" || profile_file=''
    if [ -z "$ckpt_file" ] || [ -z "$profile_file" ]; then profile_enabled=0; fi
fi

# --- REGION: https://yuruna.link/42fa6f45-000b
# Use integer microseconds for log timestamps without per-line subprocesses.
__fae_t0_us=''
if [ -n "${EPOCHREALTIME:-}" ]; then
    __fae_now=${EPOCHREALTIME/,/.}
    __fae_t0_us=$(( ${__fae_now%.*} * 1000000 + 10#${__fae_now#*.} ))
fi

# See https://yuruna.link/42fa6f45-000b
# Stamp only the saved log; console bytes must remain unchanged for OCR and checkpoints.
__fae_stamp_tee() {
    local __t0_us="$1" __log="$2" __line __now __us __el
    exec 3>>"$__log"
    while IFS= read -r __line || [ -n "$__line" ]; do
        printf '%s\n' "$__line"
        __now=${EPOCHREALTIME/,/.}
        __us=$(( ${__now%.*} * 1000000 + 10#${__now#*.} ))
        __el=$(( __us - __t0_us ))
        [ "$__el" -lt 0 ] && __el=0
        printf '[%4d.%03d] %s\n' $(( __el / 1000000 )) $(( (__el / 1000) % 1000 )) "$__line" >&3
    done
    exec 3>&-
}

# One sink for both run paths below. Degrades to a plain tee where the shell has
# no high-resolution clock, which is the same condition that disables profiling.
__fae_sink() {
    if [ -n "$__fae_t0_us" ]; then
        __fae_stamp_tee "$__fae_t0_us" "$fae_log"
    else
        tee -a "$fae_log"
    fi
}

export FILE_PATH fae_payload_sha256 fae_executed_sha256
export -f guest_evidence_safe_path guest_evidence_hash guest_evidence_revision guest_evidence_provenance
{
  echo '# phase: executing-payload'
  echo "# url:       ${fae_display_url:-$FULL_URL}"
  echo "# source:    $BASE_SOURCE"
  echo "# bytes:     $byte_count"
  [ -n "${fae_unverified:-}" ] && echo "# integrity: UNVERIFIED -- no expected digest, EXEC_ALLOW_UNVERIFIED=1 was set by the caller"
  [ "$profile_enabled" = '1' ] && echo "# profile:   $profile_file"
  [ -n "$__fae_t0_us" ] && echo "# stamps:    [seconds.millis] elapsed since 'started' (log only; the console copy is unstamped)"
  echo "# ---"
  timeout --signal=TERM --kill-after=1 4 bash -c \
      'guest_evidence_provenance' 2>/dev/null | FAE_RECORDER_BYTE_CAP=16384 fae_recorder_redact
} >> "$fae_log" 2>/dev/null || true
if [ -n "${E_SI:-}" ]; then
    printf 'YURUNA_EXECUTION stepInvocationId=%s sequenceInvocationId=%s\n' "$E_SI" "${E_QI:-}"
fi

fae_start_recorder

# See https://yuruna.link/42fa6f45-0009
# Capture the payload exit before completion output; save stdout and stderr together.
if [ "$profile_enabled" = '1' ]; then
    start_epoch="$EPOCHREALTIME"
    # Literal ESC, used by the checkpoint scanner below to peel a colorized
    # marker's leading ANSI escapes back off before the column-0 test.
    __esc=$'\033'
    # See https://yuruna.link/42fa6f45-000a
    # Keep xtrace on its dedicated descriptor, separate from visible payload output.
    profile_preamble="exec {__yfd}>'$profile_file'; export BASH_XTRACEFD=\$__yfd; export PS4='+ \${EPOCHREALTIME} '; set -x"
    /bin/bash -c "$profile_preamble"$'\n'"$script_content" "$FILE_PATH" "${SCRIPT_ARGUMENTS[@]}" 2>&1 \
      | while IFS= read -r __line || [ -n "$__line" ]; do
            printf '%s\n' "$__line"
            # See https://yuruna.link/42fa6f45-000a
            # Strip leading ANSI escapes before recognizing the visible four-equals checkpoint.
            case "$__line" in
                *'===='*)
                    __clean=$__line
                    while [ "$__clean" != "${__clean#"$__esc"\[*[a-zA-Z]}" ]; do
                        __clean=${__clean#"$__esc"\[*[a-zA-Z]}
                    done
                    case "$__clean" in
                        '===='*) printf '%s\t%s\n' "$EPOCHREALTIME" "$__clean" >> "$ckpt_file" ;;
                    esac
                    ;;
            esac
        done \
      | __fae_sink
    rc=${PIPESTATUS[0]}
else
    /bin/bash -c "$script_content" "$FILE_PATH" "${SCRIPT_ARGUMENTS[@]}" 2>&1 | __fae_sink
    rc=${PIPESTATUS[0]}
fi
{
  echo "# ---"
  echo "# exit code: $rc"
  echo "# ended:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$fae_log" 2>/dev/null || true
fae_log_completed=1

# --- REGION: https://yuruna.link/42fa6f45-0009
# Print completion beside the last payload line so the console capture still repaints.
if [ $rc -ne 0 ]; then
    echo ""
    echo "!! INNER SCRIPT FAILED"
    echo "!!   script:    $FILE_PATH"
    echo "!!   exit code: $rc"
    echo "!!   The failing command's output is above this block."
    echo "!!   Under 'set -euo pipefail', the first non-zero command"
    echo "!!   aborted the script."
    echo ""
fi

if [ $rc -eq 0 ]; then
    printf "\n    FETCHED AND EXECUTED:\n    %s\n\n" "$FILE_PATH"
else
    printf "\n    NONZERO SCRIPT EXIT:\n    %s (exit %d)\n\n" "$FILE_PATH" "$rc"
fi
printf '\n'%.0s {1..6}

fae_stop_recorder

# --- REGION: https://yuruna.link/42fa6f45-000a
# POST after the marker while its OCR window remains open; reporting never changes the verdict.
if [ "$profile_enabled" = '1' ] && [ "$BASE_SOURCE" = 'host' ] && [ -n "$ckpt_file" ] && [ -s "$ckpt_file" ]; then
    host_origin="${HOST_BASE%/yuruna-repo/}"
    ckpt_payload="$(mktemp /tmp/yuruna-fae-post.XXXXXX 2>/dev/null)" || ckpt_payload=''
    if [ -n "$ckpt_payload" ]; then
        # See https://yuruna.link/42fa6f45-000a
        # Emit JSON-escaped phase names and millisecond offsets from the same clock.
        # shellcheck disable=SC2016
        awk -F '\t' \
            -v script="$FILE_PATH" -v src="$BASE_SOURCE" \
            -v host="$(hostname 2>/dev/null)" -v rc="$rc" \
            -v stepid="${E_SI:-}" -v sequenceid="${E_QI:-}" \
            -v start="$start_epoch" -v endep="$EPOCHREALTIME" '
            function esc(s,    r) {
                r = s
                gsub(/\\/, "\\\\", r); gsub(/"/, "\\\"", r)
                gsub(/\t/, " ", r);    gsub(/\r/, "", r)
                return r
            }
            function phase(line,    n) {
                n = line
                gsub(/\033\[[0-9;:?]*[A-Za-z]/, "", n)  # strip ANSI CSI escapes
                sub(/^====/, "", n)     # drop leading marker
                sub(/====.*$/, "", n)   # drop trailing marker + remainder
                sub(/^[ \t]+/, "", n); sub(/[ \t]+$/, "", n)
                return n
            }
            BEGIN { n = 0 }
            {
                ts = $1
                rest = substr($0, index($0, "\t") + 1)
                nm = phase(rest)
                if (nm == "") next
                off = int((ts - start) * 1000)
                if (off < 0) off = 0
                names[n] = nm; offs[n] = off; n++
            }
            END {
                printf "{\"schema\":1,\"scriptPath\":\"%s\",\"source\":\"%s\",\"hostname\":\"%s\",\"stepInvocationId\":\"%s\",\"sequenceInvocationId\":\"%s\",\"exitCode\":%d,\"startEpoch\":%s,\"endEpoch\":%s,\"checkpoints\":[", esc(script), esc(src), esc(host), esc(stepid), esc(sequenceid), rc, start, endep
                for (i = 0; i < n; i++) {
                    if (i > 0) printf ","
                    printf "{\"name\":\"%s\",\"offsetMs\":%d}", esc(names[i]), offs[i]
                }
                printf "]}"
            }
        ' "$ckpt_file" > "$ckpt_payload" 2>/dev/null
        if [ -s "$ckpt_payload" ]; then
            wget --no-proxy --quiet --timeout=5 --tries=1 \
                 --header='Content-Type: application/json' \
                 --post-file="$ckpt_payload" -O /dev/null \
                 "${host_origin}/control/perf-checkpoints" 2>/dev/null || true
        fi
        rm -f "$ckpt_payload" 2>/dev/null || true
    fi
fi
# Drop the profiler temp files unless EXEC_KEEP_PROFILE=1 keeps the trace for
# debugging (its path is recorded in the log header above).
if [ "${EXEC_KEEP_PROFILE:-0}" != '1' ] && [ -n "$profile_file" ]; then
    rm -f "$profile_file" 2>/dev/null || true
fi
[ -n "$ckpt_file" ] && rm -f "$ckpt_file" 2>/dev/null || true

exit $rc
