#!/bin/bash

# Configuration with environment overrides
BASE_URL="${EXEC_BASE_URL:-https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/}"
QUERY_PARAMS="${EXEC_QUERY_PARAMS:-?nocache=$(date +%s)}"
FILE_PATH="$1"

if [ -z "$FILE_PATH" ]; then
    echo "Usage: $0 <file-path>"
    exit 1
fi

# Reset the visible screen so OCR-based "wait for prompt" on the host side
# doesn't match a prompt left over from the previous command.
clear

FULL_URL="${BASE_URL}${FILE_PATH}${QUERY_PARAMS}"
echo "fetch-and-execute: $FILE_PATH"
echo "  url: $FULL_URL"

# Fetch first, execute second. Separating the steps lets us report fetch
# failures (network, 404, empty file) distinctly from inner-script failures.
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
    # The keystroke harness waits for this exact marker to know fetch-and-execute
    # has returned control. Print it even on failure so the harness does not hang;
    # the FETCH FAILED block above is what a human (or a log scraper) reads.
    printf "\n    FETCHED AND EXECUTED:\n    %s\n\n" "$FILE_PATH"
    exit 2
fi

echo "  bytes: $byte_count"
echo ""

# Run the fetched script and capture its exit code before printing anything else,
# so the FETCHED AND EXECUTED marker is always the final line regardless of outcome.
/bin/bash -c "$script_content"
rc=$?

if [ $rc -ne 0 ]; then
    echo ""
    echo "!! INNER SCRIPT FAILED"
    echo "!!   script:    $FILE_PATH"
    echo "!!   exit code: $rc"
    echo "!!   The failing command's output is in the lines above this block."
    echo "!!   If this ran under 'set -euo pipefail', the first non-zero command"
    echo "!!   aborted the script."
    echo ""
fi

# End tag — always printed so the keystroke harness's OCR "wait for text" can
# confirm the wrapper returned. The SSH harness uses the exit code below.
printf "\n    FETCHED AND EXECUTED:\n    %s\n\n" "$FILE_PATH"
exit $rc
