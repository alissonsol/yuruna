#!/bin/bash
# Version: 2026.09.30
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# Shared local service provisioning primitives; sourcing performs no mutations.

yuruna_service_find_repo() {
    local module="$1" candidate
    for candidate in "$HOME/yuruna" "/home/$SERVICE_USER/yuruna" /home/*/yuruna; do
        if [ -f "$candidate/$module/go.mod" ]; then printf '%s' "$candidate"; return 0; fi
    done
    return 1
}

yuruna_service_packages() {
    if command -v apt_retry >/dev/null 2>&1; then
        apt_retry sudo apt-get update -y
        apt_retry sudo apt-get install -y "$@"
    else
        sudo env DEBIAN_FRONTEND=noninteractive apt-get update -y
        sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    fi
}

yuruna_service_stage() {
    local server="$1" name="$2" stage sdk
    sdk="$(cd "$server/../.." && pwd)/extension-sdk"
    [ -f "$sdk/go.mod" ] || { echo "Missing extension SDK: $sdk" >&2; return 1; }
    stage="$(mktemp -d "/tmp/$name-build.XXXXXXXX")" || return 1
    if ! cp -r -- "$server" "$stage/server" || ! cp -r -- "$sdk" "$stage/extension-sdk"; then
        rm -rf -- "$stage"; return 1
    fi
    printf '%s' "$stage"
}

yuruna_service_build() {
    local stage="$1" name="$2" version="$3" tags="${4:-}" attempt delay=10
    local flags=()
    [ -z "$tags" ] || flags+=( -tags "$tags" )
    # Build the checked-in module graph without go mod tidy: tidy could rewrite
    # it in the staged tree. Retry transient module fetch and compiler failures
    # with bounded backoff; a persistent error still fails the bring-up.
    for attempt in 1 2 3; do
        if (cd "$stage/server" && go build "${flags[@]}" -ldflags "-X main.version=$version" -o "$name" .); then return 0; fi
        if [ "$attempt" -eq 3 ]; then echo "go build failed after $attempt attempts" >&2; return 1; fi
        echo "go build attempt $attempt/3 failed; retrying in ${delay}s..." >&2
        sleep "$delay"
        delay=$((delay * 2))
    done
}

yuruna_service_install() {
    local source="$1" destination="$2"
    sudo install -m 0755 -o root -g root "$source" "$destination" || return 1
    # Ambient capabilities in the unit are authoritative; this grants direct launches.
    sudo setcap 'cap_net_bind_service=+ep' "$destination" || true
}

yuruna_service_wait_active() {
    local unit="$1" attempts="${2:-6}" health="${3:-}" attempt
    # systemd can report active before the Go server has bound its health route;
    # give the runtime a few short probes to settle before declaring failure.
    for ((attempt=0; attempt<attempts; attempt++)); do
        if sudo systemctl is-active --quiet "$unit" &&
           { [ -z "$health" ] || curl -fsS --max-time 2 "$health" >/dev/null; }; then return 0; fi
        sleep 1
    done
    return 1
}
