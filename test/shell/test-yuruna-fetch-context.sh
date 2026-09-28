#!/usr/bin/env bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
launcher="$root/automation/yuruna-fetch-context.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"

encode() { printf '%s' "$1" | base64 -w0; }
hash() { local result; result=$(printf '%s' "$1" | sha256sum); printf '%s' "${result%% *}"; }
context() {
    local id=$1 command=$2 extra=${3-}
    printf 'YFE1\nid=%s\ncmd_sha=%s\nEXEC_KEEP_PROFILE=%s\n%s' \
        "$(encode "$id")" "$(encode "$(hash "$command")")" "$(encode 1)" "$extra"
}
prepare() {
    local id=$1 body=$2 digest
    digest=$(hash "$body")
    printf '%s' "$body" | base64 -w0 | "$launcher" --prepare "$id" "${#body}" "$digest"
}
rejected() {
    local expected=$1; shift
    local output status=0
    output=$("$@" 2>&1) || status=$?
    [[ $status == 125 && $output == *"YFE_$expected"* ]] || {
        printf 'Expected YFE_%s/125, got %s/%s\n' "$expected" "$status" "$output" >&2
        exit 1
    }
}

id=0123456789a
command="printf '\342\234\223' >> '$tmp/marker'"
body=$(context "$id" "$command")
prepare "$id" "$body"
prepare "$id" "$body"  # identical preparation is idempotent before use
rejected CONTEXT_COLLISION prepare "$id" "$(context "$id" 'true')"
"$launcher" "$id" bash -c "$command"
[[ $(cat "$tmp/marker") == $'\342\234\223' ]]
rejected CONTEXT_MISSING "$launcher" "$id" bash -c "$command"

id=0123456789b
prepare "$id" "$(context "$id" "$command")"
rejected COMMAND_DIGEST "$launcher" "$id" bash -c 'echo wrong'
[[ $(cat "$tmp/marker") == $'\342\234\223' ]]

id=0123456789c
duplicate="id=$(encode "$id")"$'\n'
rejected CONTEXT_FIELD prepare "$id" "$(context "$id" true "$duplicate")"
rejected CONTEXT_SIZE "$launcher" --prepare "$id" 4097 "$(hash oversized)"
rejected CONTEXT_SIZE prepare "$id" "$(printf 'x%.0s' {1..4097})"
rejected CONTEXT_FIELD prepare "$id" "$(context "$id" true "unknown=$(encode value)")"
rejected CONTEXT_FIELD prepare "$id" "$(context "$id" true 'E_SI=???')"
rejected CONTEXT_MISSING "$launcher" "$id" bash -c true

id=0123456789a
rejected ARGUMENTS "$launcher" --prepare "$id" 0008 "$(hash true)"
body=$(context "$id" true)
rejected CONTEXT_DIGEST bash -c 'printf "%s" "$1" | base64 -w0 | "$2" --prepare "$3" "$4" "$5"' \
    _ "$body" "$launcher" "$id" "${#body}" "$(hash wrong)"
path_fields="rel=$(encode ../escape)"$'\n'
path_fields+="EXEC_REQUIRE_SHA256=$(encode 1)"$'\n'
path_fields+="E_SHA=$(encode "$(printf 'a%.0s' {1..64})")"$'\n'
path_fields+="E_RETRY_SHA=$(encode "$(printf 'b%.0s' {1..64})")"$'\n'
rejected CONTEXT_PATH prepare "$id" "$(context "$id" true "$path_fields")"

# The decoded 4 KiB ceiling is inclusive, even when a valid source slug fills it.
id=0123456789a
extra_ref="E_FB_REF=$(encode "$(printf 'a%.0s' {1..40})")"$'\n'"E_SI=$(encode x)"$'\n'
seed="$(context "$id" true "E_FB_REPO=$(encode o/r)"$'\n'"$extra_ref")"$'\n'
approx=$(( (4096 - ${#seed}) * 3 / 4 ))
exact=''
for ((n=approx-8; n<=approx+8; n++)); do
    printf -v padding '%*s' "$n" ''
    padding=${padding// /a}
    candidate="$(context "$id" true "E_FB_REPO=$(encode "o/$padding")"$'\n'"$extra_ref")"$'\n'
    if (( ${#candidate} == 4096 )); then exact=$candidate; break; fi
done
[[ ${#exact} == 4096 ]]
prepare "$id" "$exact"
"$launcher" "$id" bash -c true

id=0123456789f
prepare "$id" "$(context "$id" true)"
rejected CONTEXT_MISSING "$launcher" 0123456789e bash -c true
"$launcher" "$id" bash -c true

id=0123456789d
command="printf 'x' >> '$tmp/concurrent'"
prepare "$id" "$(context "$id" "$command")"
"$launcher" "$id" bash -c "$command" > "$tmp/first.out" 2>&1 & first=$!
"$launcher" "$id" bash -c "$command" > "$tmp/second.out" 2>&1 & second=$!
wait "$first" || true
wait "$second" || true
[[ $(cat "$tmp/concurrent") == x ]]

id=0123456789e
command='[[ "$E_SHA" == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" && "$E_RETRY_SHA" == "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" && "$EXEC_REQUIRE_SHA256" == 1 ]]'
extra="rel=$(encode guest/example.sh)"$'\n'
extra+="EXEC_REQUIRE_SHA256=$(encode 1)"$'\n'
extra+="E_SHA=$(encode "$(printf 'a%.0s' {1..64})")"$'\n'
extra+="E_RETRY_SHA=$(encode "$(printf 'b%.0s' {1..64})")"$'\n'
prepare "$id" "$(context "$id" "$command" "$extra")"
"$launcher" "$id" bash -c "$command"

printf 'yuruna-fetch-context: all checks passed\n'
