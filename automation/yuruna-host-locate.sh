#!/bin/bash
# Version: 2026.09.12
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
# The three files that carry the host's address into the guest's runtime.
# Overridable so a test can drive the persistence against a fixture tree;
# unset, these are the real paths and behavior is identical.
YURUNA_HOST_ENV_FILE="${YURUNA_HOST_ENV_FILE:-/etc/yuruna/host.env}"
YURUNA_HOSTS_FILE="${YURUNA_HOSTS_FILE:-/etc/hosts}"
YURUNA_WGETRC_FILE="${YURUNA_WGETRC_FILE:-/etc/wgetrc}"

# Wall-clock caps. These are BACKSTOPS for an unreachable peer, not
# normal-path budgets: every one of these requests is a LAN round trip that
# completes in milliseconds when the peer is up. The livecheck cap is the
# tightest because it is paid on EVERY call including the happy path, where
# it is pure overhead; the directory caps are paid only when the host has
# actually moved and a second of latency is cheaper than a failed cycle.
YURUNA_LOCATE_PROBE_TIMEOUT="${YURUNA_LOCATE_PROBE_TIMEOUT:-2}"
YURUNA_LOCATE_QUERY_TIMEOUT="${YURUNA_LOCATE_QUERY_TIMEOUT:-3}"

# How hard to press the directory once the baked coordinate is dead. The
# directory learns the host's new address from the host itself, so a guest
# that starts resolving at the moment of a renumber can be told the address
# that just died -- both ends are racing the same change. Spacing a few
# re-asks over roughly ten seconds covers that gap, against a cycle that
# otherwise ends. Overridable so a test can drive the retry without paying
# the wall clock.
YURUNA_LOCATE_RETRY_ATTEMPTS="${YURUNA_LOCATE_RETRY_ATTEMPTS:-4}"
YURUNA_LOCATE_RETRY_DELAY="${YURUNA_LOCATE_RETRY_DELAY:-3}"

# The aggregator's port. Fixed rather than derived: it is a property of the
# pool-aggregator-service unit, not of this guest's provisioning, so a guest
# that was seeded before a port change still asks the right place.
YURUNA_LOCATE_DIRECTORY_PORT="${YURUNA_LOCATE_DIRECTORY_PORT:-9400}"

# Response-size cap for a directory read, in bytes. The pool view grows with
# the member count and this parse runs during bootstrap on a guest with no
# tooling installed; a bounded read keeps a pathological (or hostile) body
# from becoming this guest's problem.
YURUNA_LOCATE_MAX_BYTES="${YURUNA_LOCATE_MAX_BYTES:-262144}"

__yhl_note() {
    >&2 echo "$1"
}

# --- REGION: https://yuruna.link/4220a755-002f
# One bounded, proxy-free GET to stdout; non-zero when the peer did not
# answer. --no-proxy/-x '' matter: the caching proxy and the host are both
# on the LAN and both sit in the guest's no_proxy list, but a project script
# that exported its own http_proxy would otherwise route this through squid
# and cache an address lookup, which must never be cached.
#
# wget first because it is what the rest of the fetch path uses, curl second
# because Amazon Linux ships it and not always wget. Neither being present
# is a resolvable state, not an error to report: the caller degrades.
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
# Refuse an address that is wrong on its face, before spending a probe on
# it. A directory answer is a claim from another machine about where a third
# machine lives; loopback and link-local are the two forms that would
# resolve locally and appear to work while pointing at nothing -- loopback
# at this guest itself, link-local at whatever answers first on the segment.
__yhl_plausible() {
    local url="$1" hostpart
    case "$url" in
        http://*|https://*) ;;
        *) return 1 ;;
    esac
    hostpart="${url#*://}"
    hostpart="${hostpart%%/*}"
    hostpart="${hostpart%%:*}"
    [ -n "$hostpart" ] || return 1
    case "$hostpart" in
        127.*|localhost|::1|0.0.0.0) return 1 ;;
        169.254.*) return 1 ;;
        22[4-9].*|23[0-9].*) return 1 ;;
    esac
    return 0
}

# --- REGION: https://yuruna.link/4220a755-0031
# Ask the pool aggregator where this hostId is now.
#
# Deliberately NOT /go/host, which answers the same question in one 302 and
# is the wrong route for a guest to call: it mints a short-lived control
# proof into the redirect fragment, and a guest holding a control proof for
# its own host is exactly the capability the status service's control-route
# authentication exists to deny. The read routes used here mint nothing.
#
# Two routes tried in order. /api/v1/host-address answers one host in a body
# small enough to parse with certainty. /api/v1/pool-status predates it and
# is the compatibility leg: a guest carrying this file still resolves
# against an aggregator that has never heard of the narrow route, which is
# what lets the two sides of this change ship independently.
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

    # No jq: this runs during bootstrap, before anything is installed. Split
    # the payload on '{' so each fragment is one flat object -- a nested
    # object ends its parent's fragment, which is what keeps the per-host
    # hostId from being confused with the one inside that host's `status`.
    #
    # Both keys must land on the SAME fragment for the match to mean
    # anything, so require the hostId and take the baseUrl from that line
    # alone. If the aggregator ever emits baseUrl before hostId, or puts a
    # nested object between them, this finds nothing and the caller degrades
    # to today's behavior -- a wrong address is the one outcome that must not
    # be possible here, and silence is the safe failure.
    base=$(printf '%s' "$body" | tr '{' '\n' \
        | grep -F "\"hostId\":\"${host_id}\"" \
        | sed -n 's/.*"baseUrl":"\([^"]*\)".*/\1/p' \
        | head -n 1)
    [ -n "$base" ] || return 1
    printf '%s' "$base"
}

# --- REGION: https://yuruna.link/4220a755-0032
# Write the resolved address into the three files that carry it, each write
# independent and best-effort.
#
# Best-effort is the point, not a shortcut: a guest with a read-only /etc,
# or one whose sudo is gone, has still resolved the address correctly in
# memory, and the export the caller receives is what unblocks the step it is
# running right now. Failing the resolve because a file could not be written
# would trade a working step for a tidy filesystem.

# Move a staged temp file over a destination, direct first and elevated
# second. Direct first because the elevation is not always needed and a
# process that can already write the file should not shell out to ask;
# `sudo -n` second because this runs unattended -- on the bootstrap path
# behind a console the host is watching, and on a timer with no console at
# all. A prompting `sudo` there would not fail, it would HANG, holding the
# step open until the watchdog kills the cycle. Refusing to ask is the only
# safe form of asking here.
__yhl_install_file() {
    local tmp="$1" dest="$2"
    cp "$tmp" "$dest" 2>/dev/null && return 0
    sudo -n cp "$tmp" "$dest" 2>/dev/null
}

__yhl_persist() {
    local ip="$1" port="$2" tmp

    # host.env: the coordinate the framework's fetch path and every project
    # script read. Rewritten in place so the file keeps whatever else it
    # carries (repo, ref, hostId, cache address).
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

    # /etc/hosts: the `yuruna-host` alias. Removal is LINE-based, matching
    # Set-HostAlias on the host side -- a line mapping the name is dropped
    # whole, including any aliases that shared it -- so the two
    # implementations cannot disagree about what "replace the mapping" means.
    tmp=$(mktemp 2>/dev/null) || tmp=''
    if [ -n "$tmp" ]; then
        { grep -v -E "[[:space:]]yuruna-host([[:space:]]|\$)" "$YURUNA_HOSTS_FILE" 2>/dev/null || true; } > "$tmp"
        printf '%s\tyuruna-host\n' "$ip" >> "$tmp"
        __yhl_install_file "$tmp" "$YURUNA_HOSTS_FILE" || true
        rm -f "$tmp" 2>/dev/null
    fi

    # wgetrc no_proxy: a single stale literal here sends a plain `wget` at
    # the host through squid, which then caches a status-service response.
    # The environment's no_proxy already covers the RFC1918 ranges, so this
    # is belt-and-braces for the one file that names an address.
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
# Resolve this guest's host coordinates, refreshing them if they have gone
# stale. Exports YURUNA_STATUS_SERVICE_IP / _PORT and returns 0 when they
# are known-good; returns 1 when they could not be established, which the
# caller must treat as "behave as though this file did not exist".
#
# Probe-first ordering is what keeps this affordable. On the overwhelmingly
# common path the baked coordinate is still correct, the directory is never
# consulted, nothing is written, and the whole call costs one LAN round trip
# -- which is why it is safe to put in front of every fetch and on a
# one-minute timer.
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

    # Both coordinates of the indirection are required. A guest imaged
    # before this file existed carries neither, and a lab with no
    # caching-proxy machine has no directory to ask -- in both cases the
    # honest answer is that this guest cannot re-resolve, and the caller's
    # existing unreachable path is the right one.
    if [ -z "${YURUNA_HOST_ID:-}" ] || [ -z "${YURUNA_CACHING_PROXY_SERVICE_IP:-}" ]; then
        return 1
    fi

    # The directory learns a new address from the host, so asking the instant
    # the host renumbers returns the address that just died -- the guest and
    # the directory are racing the same change. One shot loses that race and
    # sends the caller to a fallback that cannot help it. Re-ask a few times
    # instead, spaced so the directory has time to catch up. This costs
    # nothing on the common path: the baked coordinate answered its livecheck
    # above and returned before reaching here, so the only callers that pay
    # are the ones already out of other options.
    new_base=''
    attempt=1
    while [ "$attempt" -le "$YURUNA_LOCATE_RETRY_ATTEMPTS" ]; do
        if [ "$attempt" -gt 1 ]; then sleep "$YURUNA_LOCATE_RETRY_DELAY"; fi
        attempt=$((attempt + 1))
        new_base=$(__yhl_query_directory "$YURUNA_CACHING_PROXY_SERVICE_IP" "$YURUNA_HOST_ID") || continue
        [ -n "$new_base" ] || continue
        __yhl_plausible "$new_base" || continue
        # The directory reports where IT reached the host. This guest may sit
        # on a different segment, so the answer is confirmed from here before
        # it is adopted -- an address that does not serve this guest is not an
        # improvement on the stale one it would replace. A stale answer fails
        # this check too, which is what makes re-asking worthwhile.
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

    __yhl_note "yuruna-host-locate: host moved to ${ip}:${port} (was ${YURUNA_STATUS_SERVICE_IP:-unset}:${YURUNA_STATUS_SERVICE_PORT:-unset}), resolved via ${YURUNA_CACHING_PROXY_SERVICE_IP}"
    __yhl_persist "$ip" "$port"

    YURUNA_STATUS_SERVICE_IP="$ip"
    YURUNA_STATUS_SERVICE_PORT="$port"
    export YURUNA_STATUS_SERVICE_IP YURUNA_STATUS_SERVICE_PORT
    return 0
}

# Executed rather than sourced -- the refresh timer's entry point. Sourcing
# defines the function and does nothing else, which is what fetch-and-execute
# needs.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    yuruna_host_locate
fi
