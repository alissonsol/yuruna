#!/usr/bin/env bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# Seeded fetch context launcher. Values in the context are data, never shell code.
# --- REGION: Initialize environment
set -euo pipefail
caller_umask=$(umask)
umask 077

# --- REGION: Context validation
gui_failure=0
fail() {
    if (( gui_failure )); then printf 'NONZERO SCRIPT EXIT: YFE_%s\n' "$1" >&2
    else printf 'YFE_%s\n' "$1" >&2; fi
    exit 125
}
valid_id() { [[ ${1-} =~ ^[0-9a-f]{11}$ ]]; }
valid_sha() { [[ ${1-} =~ ^[0-9a-f]{64}$ ]]; }
context_dir() {
    [[ -n ${HOME-} ]] || fail HOME_MISSING
    local dir="$HOME/.local/state/yuruna/fetch-context"
    [[ ! -L $dir ]] || fail CONTEXT_DIRECTORY
    mkdir -p -- "$dir" || fail CONTEXT_DIRECTORY
    chmod 700 -- "$dir" || fail CONTEXT_DIRECTORY
    printf '%s' "$dir"
}

if [[ ${1-} == --gui-capability ]]; then
    [[ $# == 1 ]] || fail ARGUMENTS
    for tool in base64 gzip head dd tr sha256sum wc mktemp ln cmp; do
        command -v "$tool" >/dev/null 2>&1 || fail GUI_DEPENDENCY
    done
    printf 'YFE_GUI_1\n'
    exit 0
fi

declare -A values=()
validate_context() {
    local file=$1 expected_id=$2 line key encoded decoded
    values=()
    IFS= read -r line < "$file" || fail CONTEXT_FORMAT
    [[ $line == YFE1 ]] || fail CONTEXT_FORMAT
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == *=* ]] || fail CONTEXT_FORMAT
        key=${line%%=*}
        encoded=${line#*=}
        case $key in
            id|cmd_sha|rel|E_SHA|E_RETRY_SHA|EXEC_REQUIRE_SHA256|E_FB_REPO|E_FB_REF|E_PROJECT_REPO|E_PROJECT_REF|E_SI|E_QI|EXEC_PROFILE|EXEC_KEEP_PROFILE|EXEC_RECORDER|E_RECORDER_URL|E_RECORDER_PATH) ;;
            *) fail CONTEXT_FIELD ;;
        esac
        [[ ! -v values[$key] && $encoded =~ ^[A-Za-z0-9+/]*={0,2}$ ]] || fail CONTEXT_FIELD
        decoded=$(printf '%s' "$encoded" | base64 -d) || fail CONTEXT_ENCODING
        [[ $(printf '%s' "$decoded" | base64 -w0) == "$encoded" ]] || fail CONTEXT_ENCODING
        [[ $decoded != *$'\n'* && $decoded != *$'\r'* ]] || fail CONTEXT_FIELD
        values[$key]=$decoded
    done < <(tail -n +2 -- "$file")
    [[ ${values[id]-} == "$expected_id" ]] || fail CONTEXT_ID
    valid_sha "${values[cmd_sha]-}" || fail COMMAND_DIGEST
    [[ ${values[EXEC_KEEP_PROFILE]-} =~ ^[01]$ ]] || fail CONTEXT_FIELD
    if [[ -v values[EXEC_PROFILE] ]]; then
        [[ ${values[EXEC_PROFILE]} == 0 ]] || fail CONTEXT_FIELD
    fi
    if [[ -v values[EXEC_RECORDER] ]]; then
        [[ ${values[EXEC_RECORDER]} == 0 ]] || fail CONTEXT_FIELD
    fi
    if [[ -v values[E_RECORDER_URL] ]]; then
        [[ ${values[E_RECORDER_URL]} =~ ^http://[A-Za-z0-9.:-]+/diagnostics/([A-Za-z0-9_.-]+/){1,4}[A-Za-z0-9_.-]+\.system\.diagnostic\.[A-Za-z0-9-]+\.txt$ ]] || fail CONTEXT_FIELD
        [[ ${values[E_RECORDER_URL]} != *..* ]] || fail CONTEXT_FIELD
    fi
    if [[ -v values[E_RECORDER_PATH] ]]; then
        [[ ${values[E_RECORDER_PATH]} =~ ^diagnostics/([A-Za-z0-9_.-]+/){1,4}[A-Za-z0-9_.-]+\.system\.diagnostic\.[A-Za-z0-9-]+\.txt$ ]] || fail CONTEXT_FIELD
        [[ ${values[E_RECORDER_PATH]} != *..* ]] || fail CONTEXT_FIELD
    fi
    for key in E_SI E_QI; do
        if [[ -v values[$key] ]]; then
            [[ ${values[$key]} =~ ^[A-Za-z0-9-]{1,64}$ ]] || fail CONTEXT_FIELD
        fi
    done
    if [[ -v values[EXEC_REQUIRE_SHA256] ]]; then
        [[ ${values[EXEC_REQUIRE_SHA256]} == 1 ]] || fail CONTEXT_FIELD
        valid_sha "${values[E_SHA]-}" || fail CONTEXT_DIGEST
        valid_sha "${values[E_RETRY_SHA]-}" || fail CONTEXT_DIGEST
        [[ ${values[rel]-} =~ ^[A-Za-z0-9_./-]+$ && ${values[rel]} != /* ]] || fail CONTEXT_PATH
        [[ ! ${values[rel]} =~ (^|/)\.\.?(/|$) ]] || fail CONTEXT_PATH
    else
        [[ ! -v values[E_SHA] && ! -v values[E_RETRY_SHA] && ! -v values[rel] ]] || fail CONTEXT_FIELD
    fi
    if [[ -v values[E_FB_REPO] || -v values[E_FB_REF] ]]; then
        [[ ${values[E_FB_REPO]-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail CONTEXT_SOURCE
        [[ ${values[E_FB_REF]-} =~ ^[0-9a-f]{40}$ ]] || fail CONTEXT_SOURCE
    fi
    if [[ -v values[E_PROJECT_REPO] || -v values[E_PROJECT_REF] ]]; then
        [[ ${values[E_PROJECT_REPO]-} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail CONTEXT_SOURCE
        [[ ${values[E_PROJECT_REF]-} =~ ^[0-9a-f]{40}$ ]] || fail CONTEXT_SOURCE
        [[ ${values[rel]-} == project/?* ]] || fail CONTEXT_SOURCE
    fi
}

# --- REGION: Prepare context
prepare_context() {
    local source=$1 id=$2 expected_bytes=$3 expected_sha=$4 dir tmp actual_sha target
    valid_id "$id" || fail ARGUMENTS
    [[ $expected_bytes =~ ^(0|[1-9][0-9]{0,3})$ ]] || fail ARGUMENTS
    (( expected_bytes <= 4096 )) || fail CONTEXT_SIZE
    valid_sha "$expected_sha" || fail ARGUMENTS
    dir=$(context_dir)
    tmp=$(mktemp "$dir/.prepare.XXXXXXXX") || fail CONTEXT_DIRECTORY
    prepare_tmp=$tmp
    if [[ $source == - ]]; then base64 -d > "$tmp" || fail CONTEXT_ENCODING
    else cat -- "$source" > "$tmp" || fail CONTEXT_ENCODING; fi
    [[ $(wc -c < "$tmp") -eq $expected_bytes ]] || fail CONTEXT_SIZE
    actual_sha=$(sha256sum -- "$tmp")
    [[ ${actual_sha%% *} == "$expected_sha" ]] || fail CONTEXT_DIGEST
    validate_context "$tmp" "$id"
    target="$dir/$id"
    if ! ln -- "$tmp" "$target" 2>/dev/null; then
        [[ -f $target && ! -L $target ]] || fail CONTEXT_COLLISION
        cmp -s -- "$tmp" "$target" || fail CONTEXT_COLLISION
    fi
    rm -f -- "$tmp"
    prepare_tmp=
}

prepare_tmp=
gui_tmp=
trap 'rm -f -- "${prepare_tmp:-}"; [[ -z ${gui_tmp:-} ]] || rm -rf -- "$gui_tmp"' EXIT
if [[ ${1-} == --prepare ]]; then
    [[ $# == 4 ]] || fail ARGUMENTS
    prepare_context - "$2" "$3" "$4"
    exit 0
fi

# --- REGION: Compact GUI envelope
if [[ ${1-} == --gui ]]; then
    gui_failure=1
    [[ $# == 3 ]] || fail ARGUMENTS
    expected_gui_sha=$2 encoded_gui=$3
    valid_sha "$expected_gui_sha" || fail ARGUMENTS
    [[ ${#encoded_gui} -le 131072 && $encoded_gui =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || fail GUI_ENCODING
    gui_tmp=$(mktemp -d) || fail CONTEXT_DIRECTORY
    # The cap applies while inflating, before retaining or parsing any data.
    # pipefail also preserves CRC/footer failures after gzip emitted all bytes.
    if ! printf '%s' "$encoded_gui" | base64 -d | gzip -dc | head -c 65537 > "$gui_tmp/envelope"; then
        fail GUI_ENCODING
    fi
    (( $(wc -c < "$gui_tmp/envelope") <= 65536 )) || fail GUI_SIZE
    actual_gui_sha=$(sha256sum -- "$gui_tmp/envelope")
    [[ ${actual_gui_sha%% *} == "$expected_gui_sha" ]] || fail GUI_DIGEST
    exec 3< "$gui_tmp/envelope"
    IFS= read -r magic <&3 || fail GUI_FORMAT
    IFS= read -r id <&3 || fail GUI_FORMAT
    IFS= read -r context_bytes <&3 || fail GUI_FORMAT
    IFS= read -r context_sha <&3 || fail GUI_FORMAT
    IFS= read -r command_bytes <&3 || fail GUI_FORMAT
    [[ $magic == YFEG1 ]] || fail GUI_FORMAT
    [[ $context_bytes =~ ^(0|[1-9][0-9]{0,3})$ && $command_bytes =~ ^(0|[1-9][0-9]{0,4})$ ]] || fail GUI_SIZE
    (( context_bytes <= 4096 && command_bytes <= 65536 )) || fail GUI_SIZE
    dd bs=1 count="$context_bytes" status=none <&3 > "$gui_tmp/context" || fail GUI_FORMAT
    head -c 65537 <&3 > "$gui_tmp/command" || fail GUI_FORMAT
    exec 3<&-
    [[ $(wc -c < "$gui_tmp/command") -eq $command_bytes ]] || fail GUI_SIZE
    # Bash arguments cannot carry NUL. Checking the file before reading also
    # catches a NUL which read would silently discard, preserving exact bytes.
    [[ $(tr -d '\000' < "$gui_tmp/command" | wc -c) -eq $command_bytes ]] || fail GUI_ENCODING
    command=
    IFS= read -r -d '' command < "$gui_tmp/command" || true
    prepare_context "$gui_tmp/context" "$id" "$context_bytes" "$context_sha"
    rm -rf -- "$gui_tmp"
    gui_tmp=
    set -- "$id" bash -c "$command"
fi

# --- REGION: Consume context
[[ $# == 4 && ${2-} == bash && ${3-} == -c ]] || fail ARGUMENTS
id=$1 command=$4
valid_id "$id" || fail ARGUMENTS
dir=$(context_dir)
claim=$(mktemp -d "$dir/.claim.XXXXXXXX") || fail CONTEXT_DIRECTORY
trap 'rm -rf -- "$claim"' EXIT
mv -- "$dir/$id" "$claim/context" 2>/dev/null || fail CONTEXT_MISSING
[[ -f $claim/context && ! -L $claim/context ]] || fail CONTEXT_FIELD
validate_context "$claim/context" "$id"
actual_sha=$(printf '%s' "$command" | sha256sum)
[[ ${actual_sha%% *} == "${values[cmd_sha]}" ]] || fail COMMAND_DIGEST
unset FAE_INVOCATION_SCRIPT
for key in E_SHA E_RETRY_SHA EXEC_REQUIRE_SHA256 E_FB_REPO E_FB_REF E_PROJECT_REPO E_PROJECT_REF E_SI E_QI EXEC_PROFILE EXEC_KEEP_PROFILE EXEC_RECORDER E_RECORDER_URL E_RECORDER_PATH; do
    # An absent field must not inherit a previous invocation's source pin.
    unset "$key"
    if [[ -v values[$key] ]]; then
        printf -v "$key" '%s' "${values[$key]}"
    fi
done
export E_SHA E_RETRY_SHA EXEC_REQUIRE_SHA256 E_FB_REPO E_FB_REF E_PROJECT_REPO E_PROJECT_REF E_SI E_QI EXEC_PROFILE EXEC_KEEP_PROFILE EXEC_RECORDER E_RECORDER_URL E_RECORDER_PATH
rm -rf -- "$claim"
trap - EXIT
umask "$caller_umask"
# --- REGION: Execute payload
exec bash -c "$command"
