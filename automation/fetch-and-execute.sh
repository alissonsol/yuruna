#!/bin/bash
# Version: 2026.05.22
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
BASE_URL="$(resolve_base_url)"
case "$BASE_URL" in
    http://*) BASE_SOURCE='host' ;;
    *)        BASE_SOURCE='github' ;;
esac
QUERY_PARAMS="${EXEC_QUERY_PARAMS:-${YurunaCacheContent:+?nocache=${YurunaCacheContent}}}"
FILE_PATH="$1"

if [ -z "$FILE_PATH" ]; then
    echo "Usage: $0 <file-path>"
    exit 1
fi

clear

FULL_URL="${BASE_URL}${FILE_PATH}${QUERY_PARAMS}"
echo "fetch-and-execute: $FILE_PATH"
echo "  url: $FULL_URL"
echo "  source: $BASE_SOURCE"

# --- See https://yuruna.link/definition#defining-fetch-and-execute-failure-modes
WGET_FETCH_FLAGS=()
if [ "$BASE_SOURCE" = 'host' ]; then
    WGET_FETCH_FLAGS=(--no-proxy)
fi
script_content=$(wget "${WGET_FETCH_FLAGS[@]}" -qO- "$FULL_URL")
wget_rc=$?
byte_count=${#script_content}

if [ $wget_rc -ne 0 ] || [ $byte_count -eq 0 ]; then
    echo ""
    echo "!! FETCH FAILED"
    echo "!!   url:        $FULL_URL"
    echo "!!   wget exit:  $wget_rc"
    echo "!!   bytes read: $byte_count"
    echo ""
    # --- See https://yuruna.link/definition#defining-fetch-and-execute-failure-modes
    printf "\n    FETCH AND EXECUTE FAILED:\n    %s (fetch failed, wget exit %d)\n\n" "$FILE_PATH" "$wget_rc"
    exit 2
fi

echo "  bytes: $byte_count"
echo ""

# Tee a copy of the inner script's output into a well-known per-run log
# file so the harness can `scp` it back on failure
# (Copy-FailureArtifactsToStatusLog → Save-GuestFetchAndExecuteLog). The
# file is truncated at every fetch-and-execute call so it always holds
# the LAST script's output, which is the most useful artifact for
# post-mortem of a sequence that ended on a fetchAndExecute step. Without
# the tee, when a workload wrapper exits 0 but produces no useful output,
# the wrapper's console output is already scrolled off-screen by the
# test-localhost.sh poll loop and the OCR screenshot only captures the
# polling, not the wrapper itself.
#
# Header records WHICH script was fetched so a reader of the file alone
# can tell whether the last fetch was the workload wrapper or a smaller
# helper (test-localhost.sh, etc.). The tee runs inside a subshell so
# the inner script still sees a "regular" stdout/stderr (some tools
# behave differently under a pipe -- e.g. docker build's progress UI).
fae_log='/tmp/yuruna-last-fetch-and-execute.log'
{
  echo "# Yuruna fetch-and-execute log"
  echo "# script:    $FILE_PATH"
  echo "# url:       $FULL_URL"
  echo "# source:    $BASE_SOURCE"
  echo "# bytes:     $byte_count"
  echo "# started:   $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# ---"
} > "$fae_log" 2>/dev/null || true

# Run the fetched script and capture its exit code before any further output
# so the FETCHED AND EXECUTED marker is always the final line. `2>&1` merges
# stderr into the tee so the log captures the full picture; `tee -a`
# appends after the header above.
/bin/bash -c "$script_content" 2>&1 | tee -a "$fae_log"
rc=${PIPESTATUS[0]}
{
  echo "# ---"
  echo "# exit code: $rc"
  echo "# ended:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> "$fae_log" 2>/dev/null || true

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

# --- See https://yuruna.link/definition#defining-fetch-and-execute-end-tags
if [ $rc -eq 0 ]; then
    printf "\n    FETCHED AND EXECUTED:\n    %s\n\n" "$FILE_PATH"
else
    printf "\n    FETCH AND EXECUTE FAILED:\n    %s (exit %d)\n\n" "$FILE_PATH" "$rc"
fi
exit $rc
