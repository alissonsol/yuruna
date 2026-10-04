#!/bin/bash
# Version: 2026.10.04
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
# Pin both GitHub routes; authenticated reads use the raw Contents API.
# --- REGION: https://yuruna.link/42fa6f45-0003
build_fetch_url() {
    _bu_path="$1"
    case "$FETCH_SOURCE" in
        host|base)
            printf '%s%s%s' "$HOST_BASE" "$_bu_path" "$QUERY_PARAMS"
            ;;
        github)
            if [ -n "${GH_TOKEN:-}" ]; then
                printf 'https://api.github.com/repos/%s/contents/%s?ref=%s' "$GH_REPO" "$_bu_path" "$GH_REF"
            else
                printf 'https://raw.githubusercontent.com/%s/%s/%s' "$GH_REPO" "$GH_REF" "$_bu_path"
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
    [ "$FETCH_SOURCE" = 'github' ] || return
    [ -z "${GH_TOKEN:-}" ] && return
    if [ -z "$AUTH_CONFIG" ]; then
        AUTH_CONFIG="$(mktemp /tmp/yuruna-fae-auth.XXXXXX 2>/dev/null)" || AUTH_CONFIG=''
        [ -z "$AUTH_CONFIG" ] && return
        chmod 600 "$AUTH_CONFIG" 2>/dev/null || true
        {
            echo "header = Authorization: Bearer ${GH_TOKEN}"
            echo "header = Accept: application/vnd.github.raw"
            echo "header = X-GitHub-Api-Version: 2022-11-28"
        } > "$AUTH_CONFIG"
    fi
    WGET_FETCH_FLAGS=(--config="$AUTH_CONFIG")
}

# The wgetrc holds a live credential; drop it however this script leaves.
cleanup_auth_config() {
    [ -n "$AUTH_CONFIG" ] && rm -f "$AUTH_CONFIG" 2>/dev/null
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
QUERY_PARAMS="${EXEC_QUERY_PARAMS:-${YurunaCacheContent:+?nocache=${YurunaCacheContent}}}"
FILE_PATH="$1"
SCRIPT_ARGUMENTS=("${@:2}")

if [ -z "$FILE_PATH" ]; then
    echo "Usage: E_SHA=<sha256 of the file> $0 <file-path>"
    echo "  The file's SHA-256 is required. EXEC_ALLOW_UNVERIFIED=1 waives it for manual recovery."
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

# See https://yuruna.link/42fa6f45-0003
# No reachable host and no repository pin means no valid fetch source.
if [ "$FETCH_SOURCE" = 'github' ] && { [ -z "$GH_REPO" ] || [ -z "$GH_REF" ]; }; then
    echo ""
    echo "!! NO FETCH SOURCE"
    echo "!!   The host status service is unreachable and no GitHub fallback was"
    echo "!!   supplied, so there is nowhere to fetch this file from."
    echo "!!   Wanted: E_FB_REPO + E_FB_REF (typed by the host),"
    echo "!!           or YURUNA_GITHUB_REPO + YURUNA_GITHUB_REF in /etc/yuruna/host.env."
    echo "!!   Refusing to guess at another repository."
    echo ""
    printf "\n    NONZERO SCRIPT EXIT:\n    %s (no fetch source)\n\n" "$FILE_PATH"
    exit 2
fi

# See https://yuruna.link/42fa6f45-0003
# An unauthenticated fallback cannot read private repositories; explain this before requesting.
if [ "$FETCH_SOURCE" = 'github' ] && [ -z "${GH_TOKEN:-}" ]; then
    echo ""
    echo "!! GITHUB FALLBACK IS UNAUTHENTICATED"
    echo "!!   repo:   ${GH_REPO} at ${GH_REF}"
    echo "!!   route:  raw.githubusercontent.com -- public repositories only"
    echo "!!   effect: if that repository is private this leg can only 404, so"
    echo "!!           there is no working alternative to the host right now."
    # See https://yuruna.link/42fa6f45-0008
    # Point to host credential evidence; the guest cannot prove project access.
    echo "!!   check:  is this host's git credential able to read the project?"
    echo "!!           in a pool: Pool Control -> Hosts, the 'Project'"
    echo "!!           column for this host. DENIED means the credential cannot"
    echo "!!           read the project its pool assigned, and no retry fixes"
    echo "!!           that; unreachable means network rather than permission."
    echo "!!           standalone: run 'pwsh test/Test-Config.ps1' on the host."
    echo ""
fi

wget_flags_for_source
FULL_URL="$(build_fetch_url "$FILE_PATH")"

# See https://yuruna.link/42fa6f45-0005
# Hash exact downloaded bytes; command substitution strips trailing newlines.
fetch_tmp="$(mktemp /tmp/yuruna-fae-payload.XXXXXX 2>/dev/null)"
if [ -z "$fetch_tmp" ]; then
    printf "\n    NONZERO SCRIPT EXIT:\n    %s (could not create temp file)\n\n" "$FILE_PATH"
    exit 2
fi
# See https://yuruna.link/42fa6f45-0008
# Bound half-open downloads before they consume the entire step budget.
wget --timeout=20 --tries=2 "${WGET_FETCH_FLAGS[@]}" -qO "$fetch_tmp" "$FULL_URL"
wget_rc=$?
byte_count=$(wc -c < "$fetch_tmp" 2>/dev/null | tr -d '[:space:]')
[ -z "$byte_count" ] && byte_count=0

echo "  url: $FULL_URL"
echo "  source: $BASE_SOURCE"

# --- REGION: https://yuruna.link/42fa6f45-0008
# Retry a lost address only within the remaining pre-resolution wait budget.
if { [ "$wget_rc" -ne 0 ] || [ "$byte_count" -eq 0 ]; } \
   && { [ "$wget_rc" -eq 4 ] || [ "$wget_rc" -eq 5 ] || [ "$wget_rc" -eq 7 ]; }; then
    if command -v yuruna_has_ipv4 >/dev/null 2>&1 && ! yuruna_has_ipv4; then
        if fae_await_ipv4; then
            echo "  retrying the fetch now that this guest holds an address"
            wget --timeout=20 --tries=2 "${WGET_FETCH_FLAGS[@]}" -qO "$fetch_tmp" "$FULL_URL"
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
    echo "!!   url:        $FULL_URL"
    echo "!!   wget exit:  $wget_rc -- $(classify_wget_rc "$wget_rc" "$FULL_URL")"
    echo "!!   bytes read: $byte_count"
    # See https://yuruna.link/42fa6f45-0008
    # Discuss repository access and commit pins only after the server actually answered.
    if [ "$FETCH_SOURCE" = 'github' ]; then
        echo "!!   repo:       ${GH_REPO} at ${GH_REF}"
        case "$wget_rc" in
            4|5|7)
                echo "!!   reached:    no -- the request never got to GitHub, so the repo,"
                echo "!!               the commit and the token are not implicated here."
                echo "!!               See the NETWORK DIAGNOSTIC below for the real fault."
                ;;
            *)
                if [ -n "${GH_TOKEN:-}" ]; then
                    echo "!!   auth:       GH_TOKEN present (Contents API)"
                else
                    echo "!!   auth:       no GH_TOKEN -- a private repository will 404 here"
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
if verify_sha256 "$fetch_tmp" "$EXPECTED_SHA" "$FILE_PATH"; then
    :
elif [ -n "$EXPECTED_SHA" ] \
     && wget --timeout=20 --tries=2 "${WGET_FETCH_FLAGS[@]}" -qO "$fetch_tmp" "$FULL_URL" 2>/dev/null \
     && verify_sha256 "$fetch_tmp" "$EXPECTED_SHA" "$FILE_PATH"; then
    echo "  integrity: verified on re-fetch (absorbed a concurrent-edit race)"
else
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
script_content="$(cat "$fetch_tmp")"
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
         && wget --timeout=20 --tries=2 "${WGET_FETCH_FLAGS[@]}" -qO "$lib_tmp" "$(build_fetch_url 'automation/yuruna-retry.sh')" 2>/dev/null \
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

# --- REGION: https://yuruna.link/42d69dfa-0039
fae_log='/tmp/yuruna-last-fetch-and-execute.log'

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

{
  echo "# Yuruna fetch-and-execute log"
  echo "# script:    $FILE_PATH"
  echo "# url:       $FULL_URL"
  echo "# source:    $BASE_SOURCE"
  echo "# bytes:     $byte_count"
  [ -n "${fae_unverified:-}" ] && echo "# integrity: UNVERIFIED -- no expected digest, EXEC_ALLOW_UNVERIFIED=1 was set by the caller"
  echo "# started:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# stepInvocationId: ${E_SI:-}"
  echo "# sequenceInvocationId: ${E_QI:-}"
  [ "$profile_enabled" = '1' ] && echo "# profile:   $profile_file"
  [ -n "$__fae_t0_us" ] && echo "# stamps:    [seconds.millis] elapsed since 'started' (log only; the console copy is unstamped)"
  echo "# ---"
} > "$fae_log" 2>/dev/null || true
if [ -n "${E_SI:-}" ]; then
    printf 'YURUNA_EXECUTION stepInvocationId=%s sequenceInvocationId=%s\n' "$E_SI" "${E_QI:-}"
fi

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
