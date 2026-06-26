#!/bin/bash
# Version: 2026.06.26
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.

# --- See https://yuruna.link/definition#defining-fetch-and-execute-base-url-resolution
resolve_base_url() {
    if [ -n "${EXEC_BASE_URL:-}" ]; then
        echo "$EXEC_BASE_URL"
        return
    fi
    if [ -r /etc/yuruna/host.env ]; then
        # shellcheck disable=SC1091
        . /etc/yuruna/host.env
        if [ -n "${YURUNA_HOST_IP:-}" ] && [ -n "${YURUNA_HOST_PORT:-}" ]; then
            # --- See https://yuruna.link/definition#defining-fetch-and-execute-host-environment-variables
            if wget -q --no-proxy --timeout=2 -O /dev/null \
                "http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/livecheck" 2>/dev/null; then
                echo "http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/yuruna-repo/"
                return
            fi
            # --- See https://yuruna.link/definition#defining-fetch-and-execute-host-unreachable-warning
            >&2 echo ""
            >&2 echo "!! HOST UNREACHABLE"
            >&2 echo "!!   url:     http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/livecheck"
            >&2 echo "!!   source:  /etc/yuruna/host.env (provisioned at New-VM time)"
            >&2 echo "!!   probe:   wget --no-proxy --timeout=2 -O /dev/null → no response"
            >&2 echo "!!   action:  falling back to GitHub for this fetch"
            >&2 echo "!!   common:  host Wi-Fi roamed to a different SSID/subnet, or"
            >&2 echo "!!            host status server is down, or host firewall changed."
            >&2 echo ""
        fi
    fi
    echo "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/"
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

# --- See https://yuruna.link/definition#defining-fetch-and-execute-failure-modes
# Resolve the base URL once (host status server, else the GitHub fallback) and
# do a single fetch. A failed fetch on a bridged guest is most often the guest
# having no IPv4 DHCP lease -- DHCP pool exhaustion, which retrying cannot fix --
# so on failure run network_diag (sourced from yuruna-network.sh) to surface the
# connectivity state and flag the exhaustion case, instead of re-probing in a
# loop. resolve_base_url prefers the fast --no-proxy host path when reachable.
BASE_URL="$(resolve_base_url)"
case "$BASE_URL" in
    http://*) BASE_SOURCE='host' ;;
    *)        BASE_SOURCE='github' ;;
esac
WGET_FETCH_FLAGS=()
[ "$BASE_SOURCE" = 'host' ] && WGET_FETCH_FLAGS=(--no-proxy)
FULL_URL="${BASE_URL}${FILE_PATH}${QUERY_PARAMS}"

script_content=$(wget "${WGET_FETCH_FLAGS[@]}" -qO- "$FULL_URL")
wget_rc=$?
byte_count=${#script_content}

echo "  url: $FULL_URL"
echo "  source: $BASE_SOURCE"

if [ "$wget_rc" -ne 0 ] || [ "$byte_count" -eq 0 ]; then
    echo ""
    echo "!! FETCH FAILED"
    echo "!!   url:        $FULL_URL"
    echo "!!   wget exit:  $wget_rc"
    echo "!!   bytes read: $byte_count"
    echo ""
    # Diagnose rather than retry: show whether the guest even holds an IPv4
    # address (the DHCP-pool-exhaustion case) before giving up.
    if [ -r /usr/local/lib/yuruna/yuruna-network.sh ]; then
        # shellcheck disable=SC1091
        . /usr/local/lib/yuruna/yuruna-network.sh
        command -v network_diag >/dev/null 2>&1 && network_diag
    fi
    # --- See https://yuruna.link/definition#defining-fetch-and-execute-failure-modes
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
echo ""

# --- See https://yuruna.link/memory#why-fetch-and-execute-self-heals-the-yuruna_retry-library
# The fetched scripts source this lib unconditionally under `set -e`, so the file
# must exist before the script runs. Cloud-init bakes it into the image, so this
# is a fallback for guests that lack it; run it only after the fetch above has
# confirmed the network is up, reusing that resolution so a host-path guest pulls
# the lib --no-proxy too.
YURUNA_LIB_DIR=/usr/local/lib/yuruna
YURUNA_RETRY_LIB="$YURUNA_LIB_DIR/yuruna-retry.sh"
if [ ! -r "$YURUNA_RETRY_LIB" ]; then
    LIB_WGET_FLAGS=()
    [ "$BASE_SOURCE" = 'host' ] && LIB_WGET_FLAGS=(--no-proxy)
    sudo mkdir -p "$YURUNA_LIB_DIR" 2>/dev/null
    if wget "${LIB_WGET_FLAGS[@]}" -qO- "${BASE_URL}automation/yuruna-retry.sh" 2>/dev/null \
         | sudo tee "$YURUNA_RETRY_LIB" >/dev/null 2>&1; then
        sudo chmod 0644 "$YURUNA_RETRY_LIB"
    fi
fi
# shellcheck disable=SC1090
[ -r "$YURUNA_RETRY_LIB" ] && . "$YURUNA_RETRY_LIB"

# --- See https://yuruna.link/memory#why-fetch-and-execute-tees-into-a-well-known-per-run-log
fae_log='/tmp/yuruna-last-fetch-and-execute.log'

# --- See https://yuruna.link/definition#defining-fetch-and-execute-checkpoints
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

# --- See https://yuruna.link/definition#defining-fetch-and-execute-end-tags
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

# --- See https://yuruna.link/definition#defining-fetch-and-execute-checkpoints
# Ship the collected checkpoints to the host AFTER the marker above. The host
# joins a checkpoint sidecar to this step by its host-stamped arrival time
# falling inside the step's [start,end] window, and that window stays open until
# the host OCR-matches the marker (several poll-seconds away), so a POST issued
# right after printing the marker still lands inside the window. Best-effort: a
# failed or skipped POST never changes rc or the marker above. Only meaningful
# when the script came from the host -- the GitHub fallback has no host to talk to.
if [ "$profile_enabled" = '1' ] && [ "$BASE_SOURCE" = 'host' ] && [ -n "$ckpt_file" ] && [ -s "$ckpt_file" ]; then
    host_origin="${BASE_URL%/yuruna-repo/}"
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
