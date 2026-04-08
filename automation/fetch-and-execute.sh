#!/bin/bash

# Configuration with environment overrides
BASE_URL="${EXEC_BASE_URL:-https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/}"
QUERY_PARAMS="${EXEC_QUERY_PARAMS:-?nocache=$(date +%s)}"
FILE_PATH="$1"

if [ -z "$FILE_PATH" ]; then
    echo "Usage: $0 <file-path>"
    exit 1
fi

# TODO: Remove the hack below. It is improving reliability to find the "prompt" when it was already present!
clear

# Construct and execute
FULL_URL="${BASE_URL}${FILE_PATH}${QUERY_PARAMS}"
/bin/bash -c "$(wget -qO- "$FULL_URL")"

# End tag
echo "Fetch and execute completed: $1"
echo ""