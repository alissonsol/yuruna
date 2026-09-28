#!/usr/bin/env bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# Seeded fetch context launcher. Values in the context are data, never shell code.
set -euo pipefail
caller_umask=$(umask)
umask 077

fail() { printf 'YFE_%s\n' "$1" >&2; exit 125; }
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
            id|cmd_sha|rel|E_SHA|E_RETRY_SHA|EXEC_REQUIRE_SHA256|E_FB_REPO|E_FB_REF|E_SI|E_QI|EXEC_PROFILE|EXEC_KEEP_PROFILE) ;;
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
}

if [[ ${1-} == --prepare ]]; then
    [[ $# == 4 ]] || fail ARGUMENTS
    id=$2 expected_bytes=$3 expected_sha=$4
    valid_id "$id" || fail ARGUMENTS
    [[ $expected_bytes =~ ^(0|[1-9][0-9]{0,3})$ ]] || fail ARGUMENTS
    (( expected_bytes <= 4096 )) || fail CONTEXT_SIZE
    valid_sha "$expected_sha" || fail ARGUMENTS
    dir=$(context_dir)
    tmp=$(mktemp "$dir/.prepare.XXXXXXXX") || fail CONTEXT_DIRECTORY
    trap 'rm -f -- "$tmp"' EXIT
    base64 -d > "$tmp" || fail CONTEXT_ENCODING
    [[ $(wc -c < "$tmp") -eq $expected_bytes ]] || fail CONTEXT_SIZE
    actual_sha=$(sha256sum -- "$tmp")
    [[ ${actual_sha%% *} == "$expected_sha" ]] || fail CONTEXT_DIGEST
    validate_context "$tmp" "$id"
    target="$dir/$id"
    if ! ln -- "$tmp" "$target" 2>/dev/null; then
        [[ -f $target && ! -L $target ]] || fail CONTEXT_COLLISION
        cmp -s -- "$tmp" "$target" || fail CONTEXT_COLLISION
    fi
    exit 0
fi

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
for key in E_SHA E_RETRY_SHA EXEC_REQUIRE_SHA256 E_FB_REPO E_FB_REF E_SI E_QI EXEC_PROFILE EXEC_KEEP_PROFILE; do
    if [[ -v values[$key] ]]; then
        printf -v "$key" '%s' "${values[$key]}"
    fi
done
export E_SHA E_RETRY_SHA EXEC_REQUIRE_SHA256 E_FB_REPO E_FB_REF E_SI E_QI EXEC_PROFILE EXEC_KEEP_PROFILE
rm -rf -- "$claim"
trap - EXIT
umask "$caller_umask"
exec bash -c "$command"
