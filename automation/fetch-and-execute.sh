#!/bin/bash

# Cache-busting via environment variables, in priority order:
#   1. EXEC_QUERY_PARAMS — explicit override, used verbatim (include '?').
#   2. YurunaCacheContent — systemwide cache-buster. Leave unset so caching
#      proxies (e.g. the optional squid VM) serve stored copies; set it to
#      force a fresh fetch: export YurunaCacheContent="$(date +%Y%m%d%H%M%S)"
# Both unset/empty → empty suffix, URL stays cacheable.
BASE_URL="${EXEC_BASE_URL:-https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/}"
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
