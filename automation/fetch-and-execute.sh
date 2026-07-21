#!/bin/bash
# Version: 2026.07.21
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.

# --- REGION: https://yuruna.link/definition#defining-fetch-and-execute-base-url-resolution
# Two fetch sources, tried in order: the host status server, then GitHub. The
# GitHub fallback is a repo slug + pinned commit supplied by the host, never a
# fixed public URL -- the linked section explains why the integrity gate depends
# on that, and why no repo+ref means no fallback at all.
FETCH_SOURCE=''   # 'host' | 'base' | 'github'
HOST_BASE=''      # http://<ip>:<port>/yuruna-repo/  (host), or the EXEC_BASE_URL override
GH_REPO=''        # owner/repo
GH_REF=''         # exact commit sha

resolve_fetch_source() {
    if [ -r /etc/yuruna/host.env ]; then
        # shellcheck disable=SC1091
        . /etc/yuruna/host.env
    fi
    # Typed values win: they describe the commit the host is serving right now,
    # while host.env holds whatever was current when this VM was provisioned.
    GH_REPO="${EXEC_FALLBACK_REPO:-${YURUNA_GITHUB_REPO:-}}"
    GH_REF="${EXEC_FALLBACK_REF:-${YURUNA_GITHUB_REF:-}}"

    # EXEC_BASE_URL is the operator's manual override (CONTRIBUTING documents it
    # pointing at a raw GitHub URL for a work-in-progress branch). Classify it by
    # scheme, not by the fact that it was set: only a real http:// status server
    # is on the LAN, so only it may be fetched --no-proxy and POSTed perf
    # checkpoints. An https:// override is somewhere on the internet and gets
    # neither -- 'base' exists to keep those two behaviours apart.
    if [ -n "${EXEC_BASE_URL:-}" ]; then
        HOST_BASE="$EXEC_BASE_URL"
        case "$EXEC_BASE_URL" in
            http://*) FETCH_SOURCE='host' ;;
            *)        FETCH_SOURCE='base' ;;
        esac
        return
    fi
    if [ -n "${YURUNA_HOST_IP:-}" ] && [ -n "${YURUNA_HOST_PORT:-}" ]; then
        # --- REGION: https://yuruna.link/definition#defining-fetch-and-execute-host-environment-variables
        if wget -q --no-proxy --timeout=2 -O /dev/null \
            "http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/livecheck" 2>/dev/null; then
            FETCH_SOURCE='host'
            HOST_BASE="http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/yuruna-repo/"
            return
        fi
        # --- REGION: https://yuruna.link/definition#defining-fetch-and-execute-host-unreachable-warning
        >&2 echo ""
        >&2 echo "!! HOST UNREACHABLE"
        >&2 echo "!!   url:     http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/livecheck"
        >&2 echo "!!   source:  /etc/yuruna/host.env (provisioned at New-VM time)"
        >&2 echo "!!   probe:   wget --no-proxy --timeout=2 -O /dev/null -> no response"
        >&2 echo "!!   common:  the host's IP changed since this VM was provisioned (DHCP"
        >&2 echo "!!            lease renewed across a reboot, or Wi-Fi roamed to another"
        >&2 echo "!!            subnet), or the status server is down, or the host firewall"
        >&2 echo "!!            changed."
        if [ -n "$GH_REPO" ] && [ -n "$GH_REF" ]; then
            >&2 echo "!!   action:  falling back to GitHub -- ${GH_REPO} at ${GH_REF}"
        fi
        >&2 echo ""
    fi
    FETCH_SOURCE='github'
}

# The URL $FETCH_SOURCE serves the repo-relative path "$1" from.
#
# GitHub needs two shapes because raw.githubusercontent.com cannot read a PRIVATE
# repository at all: with a token we go through the Contents API, which returns
# the file body verbatim under the raw media type whether the repo is public or
# private; without one we use raw.githubusercontent.com, which only ever works
# for a public repo. Both pin $GH_REF, so neither can drift with `main`.
#
# $QUERY_PARAMS (the host's cache-buster) is appended only on the host route: it
# is a property of the host's served-repo handler, and the Contents API URL
# already carries a ?ref= that a second '?' would corrupt.
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

# wget flags for the resolved source, in WGET_FETCH_FLAGS.
#
# The token goes into a 0600 wgetrc passed with --config, never into --header:
# an --header argument is visible in the process list to every user on the box,
# and any `ps` snapshot a diagnostic dump takes would carry the token into the
# published run log. --config replaces the system wgetrc, which on this route
# only holds the host's no_proxy entry -- irrelevant when talking to GitHub.
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
        >&2 echo "!! integrity: no host digest for $_vf_label -- running UNVERIFIED (set EXEC_SHA256 to enforce)"
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

# --- REGION: https://yuruna.link/definition#defining-fetch-and-execute-failure-modes
# Resolve the base URL once (host status server, else the GitHub fallback) and
# do a single fetch. A failed fetch on a bridged guest is most often the guest
# having no IPv4 DHCP lease -- DHCP pool exhaustion, which retrying cannot fix --
# so on failure run network_diag (sourced from yuruna-network.sh) to surface the
# connectivity state and flag the exhaustion case, instead of re-probing in a
# loop. resolve_fetch_source prefers the fast --no-proxy host path when reachable.
resolve_fetch_source
# Two-valued for the log line and the perf-checkpoint POST below: 'host' means a
# reachable status server that can receive the POST, so an https:// EXEC_BASE_URL
# override reports (and behaves) as remote.
if [ "$FETCH_SOURCE" = 'host' ]; then BASE_SOURCE='host'; else BASE_SOURCE='github'; fi

# No host and no pinned repo+ref means there is nowhere legitimate to fetch
# from. Say so, instead of guessing at a repository whose bytes could not
# match the host's digest anyway.
if [ "$FETCH_SOURCE" = 'github' ] && { [ -z "$GH_REPO" ] || [ -z "$GH_REF" ]; }; then
    echo ""
    echo "!! NO FETCH SOURCE"
    echo "!!   The host status server is unreachable and no GitHub fallback was"
    echo "!!   supplied, so there is nowhere to fetch this file from."
    echo "!!   Wanted: EXEC_FALLBACK_REPO + EXEC_FALLBACK_REF (typed by the host),"
    echo "!!           or YURUNA_GITHUB_REPO + YURUNA_GITHUB_REF in /etc/yuruna/host.env."
    echo "!!   Refusing to guess at another repository."
    echo ""
    printf "\n    NONZERO SCRIPT EXIT:\n    %s (no fetch source)\n\n" "$FILE_PATH"
    exit 2
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
wget "${WGET_FETCH_FLAGS[@]}" -qO "$fetch_tmp" "$FULL_URL"
wget_rc=$?
byte_count=$(wc -c < "$fetch_tmp" 2>/dev/null | tr -d '[:space:]')
[ -z "$byte_count" ] && byte_count=0

echo "  url: $FULL_URL"
echo "  source: $BASE_SOURCE"

if [ "$wget_rc" -ne 0 ] || [ "$byte_count" -eq 0 ]; then
    rm -f "$fetch_tmp" 2>/dev/null || true
    echo ""
    echo "!! FETCH FAILED"
    echo "!!   url:        $FULL_URL"
    echo "!!   wget exit:  $wget_rc"
    echo "!!   bytes read: $byte_count"
    # A GitHub fetch of an exact commit fails for reasons a network probe cannot
    # see, so name them: the commit has to be ON the remote (a host-only commit
    # 404s), and a private repository has to be opened with a token.
    if [ "$FETCH_SOURCE" = 'github' ]; then
        echo "!!   repo:       ${GH_REPO} at ${GH_REF}"
        if [ -n "${GH_TOKEN:-}" ]; then
            echo "!!   auth:       GH_TOKEN present (Contents API)"
        else
            echo "!!   auth:       no GH_TOKEN -- a private repository will 404 here"
        fi
        echo "!!   check:      is that commit pushed to the remote? a commit that"
        echo "!!               exists only on the host cannot be fetched from GitHub."
    fi
    echo ""
    # Diagnose rather than retry: show whether the guest even holds an IPv4
    # address (the DHCP-pool-exhaustion case) before giving up.
    if [ -r /usr/local/lib/yuruna/yuruna-network.sh ]; then
        # shellcheck disable=SC1091
        . /usr/local/lib/yuruna/yuruna-network.sh
        command -v network_diag >/dev/null 2>&1 && network_diag
    fi
    # --- REGION: https://yuruna.link/definition#defining-fetch-and-execute-failure-modes
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
if verify_sha256 "$fetch_tmp" "${EXEC_SHA256:-}" "$FILE_PATH"; then
    :
elif [ -n "${EXEC_SHA256:-}" ] \
     && wget "${WGET_FETCH_FLAGS[@]}" -qO "$fetch_tmp" "$FULL_URL" 2>/dev/null \
     && verify_sha256 "$fetch_tmp" "${EXEC_SHA256:-}" "$FILE_PATH"; then
    echo "  integrity: verified on re-fetch (absorbed a concurrent-edit race)"
else
    rm -f "$fetch_tmp" 2>/dev/null || true
    printf "\n    NONZERO SCRIPT EXIT:\n    %s (integrity mismatch -- refusing to run)\n\n" "$FILE_PATH"
    exit 3
fi
script_content="$(cat "$fetch_tmp")"
rm -f "$fetch_tmp" 2>/dev/null || true
echo ""

# --- REGION: https://yuruna.link/memory#why-fetch-and-execute-self-heals-the-yuruna_retry-library
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
         && verify_sha256 "$lib_tmp" "${EXEC_RETRY_SHA256:-}" "automation/yuruna-retry.sh"; then
        sudo mkdir -p "$YURUNA_LIB_DIR" 2>/dev/null
        if sudo cp "$lib_tmp" "$YURUNA_RETRY_LIB" 2>/dev/null; then
            sudo chmod 0644 "$YURUNA_RETRY_LIB"
        fi
    fi
    [ -n "$lib_tmp" ] && rm -f "$lib_tmp" 2>/dev/null || true
fi
# shellcheck disable=SC1090
[ -r "$YURUNA_RETRY_LIB" ] && . "$YURUNA_RETRY_LIB"

# --- REGION: https://yuruna.link/memory#why-fetch-and-execute-tees-into-a-well-known-per-run-log
fae_log='/tmp/yuruna-last-fetch-and-execute.log'

# --- REGION: https://yuruna.link/definition#defining-fetch-and-execute-checkpoints
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

{
  echo "# Yuruna fetch-and-execute log"
  echo "# script:    $FILE_PATH"
  echo "# url:       $FULL_URL"
  echo "# source:    $BASE_SOURCE"
  echo "# bytes:     $byte_count"
  echo "# started:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ "$profile_enabled" = '1' ] && echo "# profile:   $profile_file"
  echo "# ---"
} > "$fae_log" 2>/dev/null || true

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
      | tee -a "$fae_log"
    rc=${PIPESTATUS[0]}
else
    /bin/bash -c "$script_content" 2>&1 | tee -a "$fae_log"
    rc=${PIPESTATUS[0]}
fi
{
  echo "# ---"
  echo "# exit code: $rc"
  echo "# ended:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$fae_log" 2>/dev/null || true

# --- REGION: https://yuruna.link/definition#defining-fetch-and-execute-end-tags
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

# --- REGION: https://yuruna.link/definition#defining-fetch-and-execute-checkpoints
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
                printf "{\"schema\":1,\"scriptPath\":\"%s\",\"source\":\"%s\",\"hostname\":\"%s\",\"exitCode\":%d,\"startEpoch\":%s,\"endEpoch\":%s,\"checkpoints\":[", esc(script), esc(src), esc(host), rc, start, endep
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
