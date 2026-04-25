#!/bin/bash

# Base URL resolution (in priority order):
#   1. $EXEC_BASE_URL — explicit override, used verbatim. Highest priority
#      so a per-call override always wins over auto-discovery.
#   2. /etc/yuruna/host.env — written by New-VM.ps1 at provision time.
#      Holds YURUNA_HOST_IP / YURUNA_HOST_PORT for the dev iteration loop.
#      We probe /livecheck with a short timeout; on success the host
#      status server takes precedence over GitHub. On failure we fall
#      through silently — no /etc/yuruna/host.env (CI, fresh demo) or a
#      stopped server lands transparently on GitHub.
#   3. https://raw.githubusercontent.com/... — final fallback.
#
# Cache-busting via environment variables (priority order):
#   1. $EXEC_QUERY_PARAMS — explicit override, used verbatim (include '?').
#   2. YurunaCacheContent — systemwide cache-buster. Leave unset so caching
#      proxies (e.g. the optional squid VM) serve stored copies; set it to
#      force a fresh fetch: export YurunaCacheContent="$(date +%Y%m%d%H%M%S)"
# Both unset/empty → empty suffix, URL stays cacheable.
resolve_base_url() {
    if [ -n "${EXEC_BASE_URL:-}" ]; then
        echo "$EXEC_BASE_URL"
        return
    fi
    if [ -r /etc/yuruna/host.env ]; then
        # shellcheck disable=SC1091
        . /etc/yuruna/host.env
        if [ -n "${YURUNA_HOST_IP:-}" ] && [ -n "${YURUNA_HOST_PORT:-}" ]; then
            if wget -q --spider --timeout=2 \
                "http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/livecheck" 2>/dev/null; then
                echo "http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/yuruna-repo/"
                return
            fi
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

# Reset the visible screen so host-side OCR "wait for prompt" doesn't match
# a stale prompt left from the previous command.
clear

FULL_URL="${BASE_URL}${FILE_PATH}${QUERY_PARAMS}"
echo "fetch-and-execute: $FILE_PATH"
echo "  url: $FULL_URL"
echo "  source: $BASE_SOURCE"

# Fetch first, execute second. Separating the steps reports fetch failures
# (network, 404, empty file) distinctly from inner-script failures.
script_content=$(wget -qO- "$FULL_URL")
wget_rc=$?
byte_count=${#script_content}

if [ $wget_rc -ne 0 ] || [ $byte_count -eq 0 ]; then
    echo ""
    echo "!! FETCH FAILED"
    echo "!!   url:        $FULL_URL"
    echo "!!   wget exit:  $wget_rc"
    echo "!!   bytes read: $byte_count"
    echo ""
    # Keystroke harness matches on this exact marker. Print it even on
    # failure so the harness doesn't hang; the FETCH FAILED block above
    # is what humans and log scrapers read.
    printf "\n    FETCHED AND EXECUTED:\n    %s\n\n" "$FILE_PATH"
    exit 2
fi

echo "  bytes: $byte_count"
echo ""

# Run the fetched script and capture its exit code before any further output
# so the FETCHED AND EXECUTED marker is always the final line.
/bin/bash -c "$script_content"
rc=$?

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

# End tag — always printed so the keystroke harness's OCR "wait for text"
# confirms return. SSH harness uses the exit code below.
printf "\n    FETCHED AND EXECUTED:\n    %s\n\n" "$FILE_PATH"
exit $rc
