#!/bin/bash
# Version: 2026.09.18
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.

# --- REGION: https://yuruna.link/42fa6f45-0005
# The host prepends a small env "envelope" to the command it TYPES into this
# guest (VM console or SSH): E_SHA / E_RETRY_SHA carry the sha256 of the payload
# and of the retry lib, E_FB_REPO / E_FB_REF carry the GitHub fallback repo and
# an abbreviated commit. The names are terse because every character of that
# line is an individual key event on the console path, where long sends have
# corrupted mid-flight. Both name generations stay live so host and guest can
# skew in either direction: EXEC_REQUIRE_SHA256 deliberately keeps its long name
# because an older guest image still recognizes only that spelling and refuses
# to run bytes it has no digest for -- meeting an old guest fails CLOSED instead
# of silently running unverified code -- and the legacy EXEC_* spellings are
# still read below, so a current guest also works under an older host.

# --- REGION: https://yuruna.link/42fa6f45-0003
# Two fetch sources, tried in order: the host status service, then GitHub. The
# GitHub fallback is a repo slug + pinned commit supplied by the host, never a
# fixed public URL -- the linked section explains why the integrity gate depends
# on that, and why no repo+ref means no fallback at all.
FETCH_SOURCE=''   # 'host' | 'base' | 'github'
HOST_BASE=''      # http://<ip>:<port>/yuruna-repo/  (host), or the EXEC_BASE_URL override
GH_REPO=''        # owner/repo
GH_REF=''         # exact commit sha

# Budget for the status-service probe below. Rounds are spaced rather than
# stacked back to back: what most often makes the host look dead to a guest
# this young is a path that is still coming up -- a bridge that has not
# learned the guest's MAC, an ARP entry not yet exchanged -- and that clears
# on the order of seconds, so a probe that spends its whole budget inside one
# dead second learns nothing a single attempt would not have. Worst case here
# is HOST_PROBE_ROUNDS * 2s of connect timeout plus the gaps between them,
# and it is spent only when the first attempt has already failed.
HOST_PROBE_ROUNDS=4
HOST_PROBE_GAP_SECONDS=3

resolve_fetch_source() {
    if [ -r /etc/yuruna/host.env ]; then
        # shellcheck disable=SC1091
        . /etc/yuruna/host.env
    fi
    # Typed values win: they describe the commit the host is serving right now,
    # while host.env holds whatever was current when this VM was provisioned.
    GH_REPO="${E_FB_REPO:-${EXEC_FALLBACK_REPO:-${YURUNA_GITHUB_REPO:-}}}"
    GH_REF="${E_FB_REF:-${EXEC_FALLBACK_REF:-${YURUNA_GITHUB_REF:-}}}"

    # EXEC_BASE_URL is the operator's manual override (CONTRIBUTING documents it
    # pointing at a raw GitHub URL for a work-in-progress branch). Classify it by
    # scheme, not by the fact that it was set: only a real http:// status service
    # is on the LAN, so only it may be fetched --no-proxy and POSTed perf
    # checkpoints. An https:// override is somewhere on the internet and gets
    # neither -- 'base' exists to keep those two behaviors apart.
    if [ -n "${EXEC_BASE_URL:-}" ]; then
        HOST_BASE="$EXEC_BASE_URL"
        case "$EXEC_BASE_URL" in
            http://*) FETCH_SOURCE='host' ;;
            *)        FETCH_SOURCE='base' ;;
        esac
        return
    fi
    # --- REGION: https://yuruna.link/42fa6f45-0007
    # A guest holding no global IPv4 cannot reach the host status service OR
    # GitHub, and none of the host-side causes named further down can be true
    # of it -- the host may be perfectly healthy and still unreachable. Say
    # that here instead, and skip a probe whose only possible answer is "no".
    # The predicate is the address, not the default route: a status service on
    # the same L2 segment is reachable with no default route at all. Skipped
    # when `ip` is absent so a guest without iproute2 keeps the probe path.
    if command -v ip >/dev/null 2>&1 && [ -z "$(ip -4 -o address show scope global 2>/dev/null)" ]; then
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
    # The coordinates in host.env were written when this VM was provisioned.
    # A host that renumbers under DHCP -- the norm wherever the site router
    # is the DHCP server and hands out short, non-sticky leases -- leaves
    # every guest it provisioned aimed at an address nobody answers, and the
    # GitHub leg below cannot stand in for the host when the framework
    # repository is private.
    #
    # yuruna-host-locate probes the coordinate this guest already holds and
    # consults the pool directory only once that has gone dead, so the
    # common path costs a single LAN round trip -- which is what makes it
    # affordable in front of every fetch. It is seeded by cloud-init and
    # never fetched over the network, so unlike the retry lib it needs no
    # digest of its own; where it is absent (a guest imaged before it
    # existed) resolution below proceeds exactly as it always did.
    #
    # A success here is the same evidence the probe below would gather --
    # locate has just made that call -- so it is taken directly rather than
    # spending a second round trip to re-learn it. A failure deliberately
    # falls through instead of short-circuiting, so the unreachable
    # diagnostic stays the single place that explains a dead host.
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
        # Several spaced attempts, not one. This probe decides between the only
        # source that can serve a private framework repository and one that
        # then cannot serve it at all, and the caller may have reached here on
        # an address that arrived seconds ago -- with bridge learning and ARP
        # still settling, a single 2s exchange is thin evidence for a verdict
        # that cannot be revisited. Where the framework repository is private
        # the alternative this falls through to cannot answer at all, so the
        # seconds spent here are strictly cheaper than the cycle they save.
        #
        # The bounds are defaulted at the point of use rather than read from
        # the file scope alone: this function is lifted out and driven on its
        # own, and a bound it can only get from its surroundings arrives empty
        # there -- which reads as a loop bound of zero, so the probe would
        # silently stop probing wherever it is exercised in isolation.
        _probe_rounds="${HOST_PROBE_ROUNDS:-4}"
        _probe_gap="${HOST_PROBE_GAP_SECONDS:-3}"
        _livecheck_url="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/livecheck"
        _probe_round=1
        while [ "$_probe_round" -le "$_probe_rounds" ]; do
            if wget -q --no-proxy --timeout=2 --tries=1 -O /dev/null "$_livecheck_url" 2>/dev/null; then
                if [ "$_probe_round" -gt 1 ]; then
                    # Worth saying out loud: the host was reachable, but not
                    # on the first ask. That is the signature of a guest path
                    # that comes up late, and it is invisible once the fetch
                    # below succeeds and the run goes green.
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
        # Name what the directory was asked and what came back. A renumbered
        # host is the first cause a reader reaches for, and it is the one
        # cause the lookup above already tried to repair -- saying so turns
        # "the host moved" from the leading hypothesis into a ruled-out one,
        # and points at whichever coordinate of the indirection is missing.
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

# The URL $FETCH_SOURCE serves the repo-relative path "$1" from. With a token,
# GitHub reads go through the Contents API (works for private repos); without
# one, raw.githubusercontent.com (public only). Both pin $GH_REF. $QUERY_PARAMS
# rides only the host route (a second '?' would corrupt the API URL's ?ref=).
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

# wget flags for the resolved source, in WGET_FETCH_FLAGS. The token rides a
# 0600 wgetrc via --config, never --header (argv is world-readable and a `ps`
# snapshot in a diagnostic dump would publish it); the replaced system wgetrc
# only holds the host's no_proxy entry, irrelevant when talking to GitHub.
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
# Name what a wget exit code means, at the point the code is reported. wget
# collapses DNS failure, "network is unreachable" and "connection refused"
# into a single exit 4, which is the one code a reader most needs separated,
# so that case is resolved from local state: no global IPv4 means the link
# never came up, a missing default route means nothing can leave this subnet,
# and a name that will not resolve points at DNS. The retry library's
# classifier cannot answer here -- it is installed and sourced only once a
# payload has landed, and it reports retry-worthiness, not a cause.
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
    if [ -z "$(ip -4 -o address show scope global 2>/dev/null)" ]; then
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

# Verify fetched bytes against a host-provided sha256 before they reach bash.
# The expected digest arrives over the trusted channel that TYPED this command
# (SSH / the VM console) -- never over the HTTP the bytes came from -- so a LAN
# man-in-the-middle, or the moving-`main` GitHub fallback, cannot forge bytes
# that match a digest it never controlled. That is what closes the fetch-to-bash
# RCE class on both the host and fallback sources. An empty expected digest
# means the host did not supply one (an older host, or a hand run): warn and
# proceed so availability is preserved -- the automated path always supplies it,
# so the exposed surface stays closed there. Returns non-zero only on a real
# mismatch. Hashes the file directly (not a "$(...)" capture) so trailing
# newlines are included and the digest equals the host's hash of the on-disk file.
verify_sha256() {
    _vf_file="$1"; _vf_expected="$2"; _vf_label="$3"
    if [ -z "${_vf_expected:-}" ]; then
        # EXEC_REQUIRE_SHA256=1 means the host intended to enforce (the automated
        # path always sets it): a missing digest here is a host-side served-root
        # drift or a bad path, so fail CLOSED rather than run unverified bytes.
        if [ "${EXEC_REQUIRE_SHA256:-}" = "1" ]; then
            >&2 echo "!! integrity: host requires a digest (EXEC_REQUIRE_SHA256=1) but none was supplied for $_vf_label -- refusing"
            return 1
        fi
        >&2 echo "!! integrity: no host digest for $_vf_label -- running UNVERIFIED (set E_SHA to enforce)"
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
    >&2 echo "!!   refusing to run code that does not match the host-provided digest."
    >&2 echo ""
    return 1
}
QUERY_PARAMS="${EXEC_QUERY_PARAMS:-${YurunaCacheContent:+?nocache=${YurunaCacheContent}}}"
FILE_PATH="$1"

if [ -z "$FILE_PATH" ]; then
    echo "Usage: $0 <file-path>"
    exit 1
fi

clear

# Heads-up before the download. Worded WITHOUT "fetch"/"execute": the host OCR
# FailurePattern matcher is fuzzy and those words also appear in the typed
# command line, so a message carrying them would widen the false-match surface
# -- the same reason the failure marker below avoids them.
echo "About to download and run project code: $FILE_PATH"

# --- REGION: https://yuruna.link/42fa6f45-0008
# Hold an address BEFORE choosing a source, then resolve once and fetch.
#
# Source resolution probes the host status service, and a guest holding no
# IPv4 fails that probe for a reason that says nothing about the host: the
# probe could not have succeeded whether the host was up or down. Resolving
# in that state does not pick a fallback, it discards the host route on
# evidence that was never gathered -- and where the framework repository is
# private, the GitHub leg it lands on can only answer 404, so a lease that
# arrives moments later cannot rescue the fetch no matter how long anything
# waits afterwards. Waiting first is what makes the resolution below mean
# what it says: 'github' then describes a host that was asked and did not
# answer, which is a fact worth acting on.
#
# Free on the normal path: a guest that already holds a lease answers
# yuruna_has_ipv4 immediately and never enters the wait. A late lease is
# still waited for exactly once -- the budget is shared with the post-fetch
# second chance below, so the two cannot each spend the full allowance and
# double this guest's worst-case boot.
#
# Every other failure runs network_diag (from the same library) to surface
# the connectivity state rather than re-probing in a loop. Whether a lease is
# late or refused is not decidable from inside the guest, so the wait is
# bounded and its outcome is reported either way.
if [ -r /usr/local/lib/yuruna/yuruna-network.sh ]; then
    # shellcheck disable=SC1091
    . /usr/local/lib/yuruna/yuruna-network.sh
fi

# Seconds this run may still spend waiting for an address, across both call
# sites. Reaching 0 makes the second call return immediately rather than
# waiting the allowance a second time.
fae_ipv4_budget="${YURUNA_FETCH_IPV4_WAIT:-180}"

# 0 = this guest holds an IPv4 (already, or one arrived within the budget);
# 1 = it does not, because the budget is spent or the network library is
# absent (a guest imaged before it existed keeps the pre-existing behavior).
#
# The nudge partway through exists because waiting alone only rescues the
# lease that is merely late: a client stuck in lost-DISCOVER backoff, or a
# NIC that no profile claimed, waits forever, and both answer to
# yuruna_net_repair_ipv4 (reload + reconfigure, never taking a link down).
# Nudging partway leaves the client's own early retransmits undisturbed,
# then spends what is left on the fresh transaction the repair started.
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
# Two-valued for the log line and the perf-checkpoint POST below: 'host' means a
# reachable status service that can receive the POST, so an https:// EXEC_BASE_URL
# override reports (and behaves) as remote.
if [ "$FETCH_SOURCE" = 'host' ]; then BASE_SOURCE='host'; else BASE_SOURCE='github'; fi

# No host and no pinned repo+ref means there is nowhere legitimate to fetch
# from. Say so, instead of guessing at a repository whose bytes could not
# match the host's digest anyway.
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

# The unauthenticated GitHub leg reads raw.githubusercontent.com, which serves
# public repositories only. When the framework repository is private this leg
# can only answer 404, so it is not a fallback at all -- the host status
# service is the sole working source. Say so before the attempt: an
# unannounced 404 reads as a bad commit pin and sends the reader after the
# wrong thing. No token is delivered to guests over this path.
if [ "$FETCH_SOURCE" = 'github' ] && [ -z "${GH_TOKEN:-}" ]; then
    echo ""
    echo "!! GITHUB FALLBACK IS UNAUTHENTICATED"
    echo "!!   repo:   ${GH_REPO} at ${GH_REF}"
    echo "!!   route:  raw.githubusercontent.com -- public repositories only"
    echo "!!   effect: if that repository is private this leg can only 404, so"
    echo "!!           there is no working alternative to the host right now."
    # Whether the credential can read the project is a question about the HOST,
    # answerable there and not from inside this guest -- so name where the
    # answer lives rather than guess at it here. The pool route is listed first
    # for a pooled host because it reports the probe the pool already ran; the
    # local script is the answer for a host running on its own.
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

# Fetch to a temp file (not a "$(...)" capture) so the integrity digest is taken
# over the EXACT served bytes: command substitution strips trailing newlines,
# which would then never match the host's Get-FileHash of the on-disk file.
fetch_tmp="$(mktemp /tmp/yuruna-fae-payload.XXXXXX 2>/dev/null)"
if [ -z "$fetch_tmp" ]; then
    printf "\n    NONZERO SCRIPT EXIT:\n    %s (could not create temp file)\n\n" "$FILE_PATH"
    exit 2
fi
# --timeout/--tries bound the attempt without turning it into a retry ladder.
# A hard-down link fails instantly, but a half-open path -- a SYN blackhole, a
# stalled body, an origin that accepts and never answers -- has no bound of its
# own, so a single guest can otherwise burn the whole step budget on one fetch.
wget --timeout=20 --tries=2 "${WGET_FETCH_FLAGS[@]}" -qO "$fetch_tmp" "$FULL_URL"
wget_rc=$?
byte_count=$(wc -c < "$fetch_tmp" 2>/dev/null | tr -d '[:space:]')
[ -z "$byte_count" ] && byte_count=0

echo "  url: $FULL_URL"
echo "  source: $BASE_SOURCE"

# --- REGION: https://yuruna.link/42fa6f45-0008
# Second chance for the one failure shape a second chance can fix: this guest
# lost the address it had. The boot that STARTS without one is already handled
# before source resolution above, which is the only place that repair is worth
# anything -- a lease acquired after the source was chosen cannot undo a host
# route discarded for the want of it.
#
# wget rc 4/5/7 mean the request never left the guest. With no IPv4 route that
# verdict is reached in milliseconds, so --tries=2 buys nothing -- both attempts
# fail before the DHCP client has even finished its first backoff. A guest whose
# lease simply has not landed is therefore indistinguishable, at this instant,
# from one that will never get an address, and failing here turns the recoverable
# case into a failed cycle.
#
# Gated on there being no IPv4 at all, so a guest that HAS an address and still
# cannot fetch falls straight through to the diagnosis below: that fault is not
# a lease and waiting on one would only delay the report. fae_await_ipv4 draws
# on the budget the pre-resolution wait already spent from, so a guest that has
# waited its allowance reports the exhaustion it already printed instead of
# waiting the whole allowance a second time.
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
    # A GitHub fetch of an exact commit fails for reasons a network probe cannot
    # see, so name them: the commit has to be ON the remote (a host-only commit
    # 404s), and a private repository has to be opened with a token. Both are
    # server-side answers, so they may only be offered when a server actually
    # answered. wget rc 4/5/7 mean the request never left this guest, and
    # printing "a private repository will 404 here" under a dead link sends the
    # reader hunting a repo, a commit and a token that are not implicated --
    # past the link-down verdict the NETWORK DIAGNOSTIC below is about to give.
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
                    # Only reachable once GitHub actually answered, so the
                    # credential really is the open question. Whether it can
                    # read the project is a fact about the host, so point at
                    # where that fact is already recorded rather than asking a
                    # guest to infer it.
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
    # Diagnose before giving up: show the connectivity state this failure was
    # reached in. Anything a wait could have fixed was already waited on above,
    # so reaching here means the address never arrived or the fault was never
    # about an address.
    if [ -r /usr/local/lib/yuruna/yuruna-network.sh ]; then
        # shellcheck disable=SC1091
        . /usr/local/lib/yuruna/yuruna-network.sh
        command -v network_diag >/dev/null 2>&1 && network_diag
    fi
    # --- REGION: https://yuruna.link/42fa6f45-0008
    # The failure marker deliberately avoids the words "fetch"/"execute": the
    # host-side OCR FailurePattern matcher is fuzzy, and a marker containing
    # those words fuzzy-matches the echoed 'fetch-and-execute.sh ...' command
    # line on the very first poll -- aborting a healthy run before any script
    # output appears (the false-failure class). The rare token "NONZERO" can't
    # collide with a command or normal script output.
    printf "\n    NONZERO SCRIPT EXIT:\n    %s (fetch failed, wget exit %d)\n\n" "$FILE_PATH" "$wget_rc"
    exit 2
fi

echo "  bytes: $byte_count"

# Integrity gate: verify the fetched bytes against the host-provided digest
# BEFORE any content is handed to bash. On a non-empty-digest mismatch, re-fetch
# once and re-verify: a host process can rewrite the served working-tree file
# during the ~3s type-to-fetch window, and that narrow race should self-heal; a
# genuine man-in-the-middle cannot produce matching bytes on the retry. Refuse
# in every other case (mismatch after retry, or an enforced-but-absent digest).
EXPECTED_SHA="${E_SHA:-${EXEC_SHA256:-}}"
if verify_sha256 "$fetch_tmp" "$EXPECTED_SHA" "$FILE_PATH"; then
    :
elif [ -n "$EXPECTED_SHA" ] \
     && wget "${WGET_FETCH_FLAGS[@]}" -qO "$fetch_tmp" "$FULL_URL" 2>/dev/null \
     && verify_sha256 "$fetch_tmp" "$EXPECTED_SHA" "$FILE_PATH"; then
    echo "  integrity: verified on re-fetch (absorbed a concurrent-edit race)"
else
    rm -f "$fetch_tmp" 2>/dev/null || true
    printf "\n    NONZERO SCRIPT EXIT:\n    %s (integrity mismatch -- refusing to run)\n\n" "$FILE_PATH"
    exit 3
fi
script_content="$(cat "$fetch_tmp")"
rm -f "$fetch_tmp" 2>/dev/null || true
echo ""

# --- REGION: https://yuruna.link/42d69dfa-003a
# The fetched scripts source this lib unconditionally under `set -e`, so the file
# must exist before the script runs. Cloud-init bakes it into the image, so this
# is a fallback for guests that lack it; run it only after the fetch above has
# confirmed the network is up, reusing that resolution so a host-path guest pulls
# the lib --no-proxy too.
YURUNA_LIB_DIR=/usr/local/lib/yuruna
YURUNA_RETRY_LIB="$YURUNA_LIB_DIR/yuruna-retry.sh"
if [ ! -r "$YURUNA_RETRY_LIB" ]; then
    # Fetch to a temp file and run it through the SAME trusted-digest gate as the
    # main payload before the sudo-install: this copy is sourced under `set -e`
    # by every fetched script, so an unverified or partial body would become
    # root-installed library code. The explicit wget-success + non-empty + digest
    # checks below ensure only a complete, verified body is ever written.
    lib_tmp="$(mktemp /tmp/yuruna-fae-retrylib.XXXXXX 2>/dev/null)"
    if [ -n "$lib_tmp" ] \
         && wget "${WGET_FETCH_FLAGS[@]}" -qO "$lib_tmp" "$(build_fetch_url 'automation/yuruna-retry.sh')" 2>/dev/null \
         && [ -s "$lib_tmp" ] \
         && verify_sha256 "$lib_tmp" "${E_RETRY_SHA:-${EXEC_RETRY_SHA256:-}}" "automation/yuruna-retry.sh"; then
        sudo mkdir -p "$YURUNA_LIB_DIR" 2>/dev/null
        if sudo cp "$lib_tmp" "$YURUNA_RETRY_LIB" 2>/dev/null; then
            sudo chmod 0644 "$YURUNA_RETRY_LIB"
        fi
    fi
    [ -n "$lib_tmp" ] && rm -f "$lib_tmp" 2>/dev/null || true
fi
# shellcheck disable=SC1090
[ -r "$YURUNA_RETRY_LIB" ] && . "$YURUNA_RETRY_LIB"

# --- REGION: https://yuruna.link/4220a755-0015
# Re-anchor the ssl-bump CA before handing control to the payload. The guest's
# copy of that CA is only as current as the cache that minted it, and a cache
# rebuilt from a blank disk between two steps of the same run mints a fresh one:
# every step that already passed stays passed, and the next bumped HTTPS fails
# certificate verification. Checking here rather than inside any one script is
# what makes the repair survive that boundary -- a run resumed mid-way re-enters
# through this file and nowhere else, so a script's own first HTTPS is never the
# thing that discovers a trust anchor that went stale while it was not looking.
# Non-fatal by contract: a guest with no bump in front of it is a hard no-op,
# and a repair that cannot complete leaves the payload to fail with its own
# diagnosis rather than being preempted by a less specific one here.
if command -v yuruna_ca_selfheal >/dev/null 2>&1; then
    yuruna_ca_selfheal || true
fi

# --- REGION: https://yuruna.link/42d69dfa-0039
fae_log='/tmp/yuruna-last-fetch-and-execute.log'

# --- REGION: https://yuruna.link/42fa6f45-000a
# Optional per-phase profiling. A fetched script marks phase boundaries with a
# line that starts with four equals signs:  ==== phase name ====  . Each such
# line is captured with bash's high-resolution EPOCHREALTIME clock and later
# POSTed to the host so the perf graph can split this step's bar into per-phase
# sub-segments. xtrace is enabled to a dedicated fd (BASH_XTRACEFD) so a full
# timed command trace becomes a guest-local artifact without polluting the
# visible console. Needs EPOCHREALTIME (bash >= 5); EXEC_PROFILE=0 opts out.
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
# Elapsed-time origin for the per-line stamps written into the log below. Kept
# as microseconds so the arithmetic stays integer -- the shell has no floats,
# and a fork per output line to get one would be its own kind of slow.
__fae_t0_us=''
if [ -n "${EPOCHREALTIME:-}" ]; then
    __fae_now=${EPOCHREALTIME/,/.}
    __fae_t0_us=$(( ${__fae_now%.*} * 1000000 + 10#${__fae_now#*.} ))
fi

# Mirror stdin to stdout unchanged while appending a stamped copy of each line
# to the log.
#
# The console copy MUST stay byte-identical: the host matches OCR patterns
# against what is on screen, and the checkpoint scanner tests for the four-equals
# marker at column 0 -- a prefix on the visible stream would silently break both.
# The log is the only copy anyone can ask "where did the time go" of, and with no
# stamp a script that spent two minutes blocked on one command is indistinguish-
# able from one that ran fast and then waited. Stamps are relative to the start
# recorded in the header above, so an absolute time is a sum away and no
# timezone assumption is baked into the format.
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

# Run the fetched script and capture its exit code before any further output
# so the FETCHED AND EXECUTED marker is always the final line. `2>&1` merges
# stderr into the tee so the log captures the full picture; `tee -a`
# appends after the header above.
if [ "$profile_enabled" = '1' ]; then
    start_epoch="$EPOCHREALTIME"
    # Literal ESC, used by the checkpoint scanner below to peel a colorized
    # marker's leading ANSI escapes back off before the column-0 test.
    __esc=$'\033'
    # The preamble runs inside the fetched-script shell: open the trace fd, point
    # xtrace at it, timestamp every traced command via PS4, then enable tracing.
    # `$script_content` follows on its own line so a leading shebang/`set` in the
    # fetched script is simply the next statement. xtrace lands on BASH_XTRACEFD
    # (the profile file), not fd 2, so `2>&1` below keeps the console clean.
    profile_preamble="exec {__yfd}>'$profile_file'; export BASH_XTRACEFD=\$__yfd; export PS4='+ \${EPOCHREALTIME} '; set -x"
    /bin/bash -c "$profile_preamble"$'\n'"$script_content" 2>&1 \
      | while IFS= read -r __line || [ -n "$__line" ]; do
            printf '%s\n' "$__line"
            # A checkpoint is an output line whose first visible characters are
            # the four-equals marker; stamp it with EPOCHREALTIME (same clock as
            # PS4) at emit. A colorized marker -- e.g. echo -e "\e[1;36m==== x" --
            # leads with one or more ANSI CSI escapes, so strip the leading run of
            # them before the column-0 test. The candidate filter keeps that cost
            # off the lines that can't be markers; the host-side awk strips any
            # trailing/embedded escapes back out of the captured name.
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
    /bin/bash -c "$script_content" 2>&1 | __fae_sink
    rc=${PIPESTATUS[0]}
fi
{
  echo "# ---"
  echo "# exit code: $rc"
  echo "# ended:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$fae_log" 2>/dev/null || true

# --- REGION: https://yuruna.link/42fa6f45-0009
# Emit the end-tag marker as a contiguous continuation of the script's output,
# BEFORE the console-silent perf-checkpoint POST and temp-file cleanup below. On
# a headless Hyper-V host the screen-capture surface stops repainting within a
# moment of the guest console going idle; a marker printed after a silent gap
# lands on a frozen frame the host's waitForText never OCRs, so the step times
# out on a stale pre-marker screen even though the guest actually finished.
# Keeping the marker adjacent to the script's last line puts it in the same
# repaint. See feedback_frozen_capture_feed_idle_tail.
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
# Ship the collected checkpoints to the host AFTER the marker above. The host
# joins a checkpoint sidecar to this step by its host-stamped arrival time
# falling inside the step's [start,end] window, and that window stays open until
# the host OCR-matches the marker (several poll-seconds away), so a POST issued
# right after printing the marker still lands inside the window. Best-effort: a
# failed or skipped POST never changes rc or the marker above. Only meaningful
# when the script came from the host -- the GitHub fallback has no host to talk to.
if [ "$profile_enabled" = '1' ] && [ "$BASE_SOURCE" = 'host' ] && [ -n "$ckpt_file" ] && [ -s "$ckpt_file" ]; then
    host_origin="${HOST_BASE%/yuruna-repo/}"
    ckpt_payload="$(mktemp /tmp/yuruna-fae-post.XXXXXX 2>/dev/null)" || ckpt_payload=''
    if [ -n "$ckpt_payload" ]; then
        # awk pass: offsetMs = (epoch - start) * 1000, JSON-escape each phase
        # name, drop the leading/trailing ==== marker. `start`/`endep` print as
        # bare JSON numbers (EPOCHREALTIME is already a decimal literal).
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
