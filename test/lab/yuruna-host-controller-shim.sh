#!/bin/sh
# Version: 2026.11.23
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 428cdad4-4a57-490f-85af-e49d42b2179d
#
# Deployed by Enable-TestAutomation as <controller root>/shim and run by the
# host's job supervisor, or on macOS in the multiplexer session a runner start
# creates. It starts the host controller from a private snapshot
# and starts it again when it ends. It is the one layer that no installer and
# no host update replaces, so it is written for the system's own shell and
# reads nothing but the controller root:
#   current   current=<hash>, previous=<hash>, checkout=<path>
#   rejected  hashes given up on, one per line
#   versions/<hash>/ok  created by a controller of that snapshot that started
#
# Controller exits:
#   75        start the current snapshot again at once
#   76        another controller holds the lock: wait 30 s, not a death; on
#             macOS, from the first controller this shim started: exit, since
#             another shim owns the controller (screen accepts two sessions
#             of one name, and two runner starts can create both)
#   anything  start again after 10 s, doubling to 60 s, back to 10 s after a
#             run of five minutes; three deaths in a row of a snapshot that
#             never created ok reject that snapshot
# A stop of the shim is passed on to the controller, which gets 30 s to end;
# it is never killed, so a step child it leaves runs on to its own bound.

case $0 in
    */*) ROOT=${0%/*} ;;
    *) ROOT=. ;;
esac
ROOT=$(cd "$ROOT" && pwd -P) || exit 1

child=
pause_pid=
checkout=
delay=10
deaths=0
death_hash=
starts=0
system=$(uname -s 2>/dev/null)

log() {
    printf 'yuruna-host-controller: %s\n' "$*" >&2
}

# Waits in the background so a stop signal is handled at once, not after the
# whole wait.
pause() {
    sleep "$1" &
    pause_pid=$!
    wait "$pause_pid"
    pause_pid=
}

on_stop() {
    trap '' TERM INT HUP
    if [ -n "$pause_pid" ]; then
        kill -TERM "$pause_pid" 2>/dev/null
    fi
    if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
        log "stop: passing the stop to controller $child"
        kill -TERM "$child" 2>/dev/null
        waited=0
        while [ "$waited" -lt 30 ] && kill -0 "$child" 2>/dev/null; do
            sleep 1
            waited=$((waited + 1))
        done
        if kill -0 "$child" 2>/dev/null; then
            log "stop: controller $child still running after 30 s; leaving it"
        fi
    fi
    exit 0
}

trap on_stop TERM INT HUP

valid_hash() {
    [ "${#1}" -eq 16 ] || return 1
    case $1 in
        *[!0-9a-f]*) return 1 ;;
    esac
    return 0
}

is_rejected() {
    [ -f "$ROOT/rejected" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        if [ "$line" = "$1" ]; then
            return 0
        fi
    done < "$ROOT/rejected"
    return 1
}

read_current() {
    cur=
    prev=
    if [ -f "$ROOT/current" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case $line in
                current=*) cur=${line#current=} ;;
                previous=*) prev=${line#previous=} ;;
                checkout=*) checkout=${line#checkout=} ;;
            esac
        done < "$ROOT/current"
    fi
}

write_current() {
    tmp="$ROOT/current.tmp.$$"
    if printf 'current=%s\nprevious=%s\ncheckout=%s\n' "$1" "$2" "$checkout" > "$tmp" && mv -f "$tmp" "$ROOT/current"; then
        return 0
    fi
    rm -f "$tmp"
    log "could not rewrite $ROOT/current"
    return 1
}

usable() {
    valid_hash "$1" && ! is_rejected "$1" && [ -d "$ROOT/versions/$1" ]
}

# The newest snapshot that has started once and was not rejected.
newest_ok() {
    best=
    best_ok=
    for ok in "$ROOT"/versions/*/ok; do
        [ -f "$ok" ] || continue
        dir=${ok%/ok}
        candidate=${dir##*/}
        usable "$candidate" || continue
        if [ -z "$best_ok" ] || [ -n "$(find "$ok" -prune -newer "$best_ok")" ]; then
            best=$candidate
            best_ok=$ok
        fi
    done
    printf '%s' "$best"
}

reject() {
    printf '%s\n' "$1" >> "$ROOT/rejected"
    if [ -n "$prev" ] && [ "$prev" != "$1" ] && usable "$prev"; then
        write_current "$prev" ""
        log "snapshot $1 died three times without starting; rejected, back to $prev"
    else
        write_current "" ""
        log "snapshot $1 died three times without starting; rejected, no previous snapshot"
    fi
}

while :; do
    read_current
    h=$cur
    if ! usable "$h"; then
        h=$(newest_ok)
        if [ -z "$h" ]; then
            log "no snapshot to start; looking again in 60 s"
            pause 60
            continue
        fi
        log "current snapshot unusable; starting $h"
    fi
    if [ -z "$checkout" ]; then
        log "no checkout recorded in $ROOT/current; looking again in 60 s"
        pause 60
        continue
    fi
    PWSH=$(command -v pwsh)
    if [ -z "$PWSH" ]; then
        log "pwsh not found on PATH; looking again in 60 s"
        pause 60
        continue
    fi
    "$PWSH" -NoLogo -NoProfile -NonInteractive -File "$ROOT/versions/$h/test/lab/Invoke-HostUpdateController.ps1" \
        -ControllerRoot "$ROOT" -Snapshot "$h" -Checkout "$checkout" &
    child=$!
    starts=$((starts + 1))
    start=$(date +%s)
    wait "$child"
    code=$?
    child=
    case $code in
        75)
            delay=10
            deaths=0
            continue
            ;;
        76)
            if [ "$system" = Darwin ] && [ "$starts" -eq 1 ]; then
                log "another controller holds the lock at this shim's first start; leaving it to the shim that owns it"
                exit 0
            fi
            log "another controller holds the lock; trying again in 30 s"
            pause 30
            continue
            ;;
    esac
    now=$(date +%s)
    if [ $((now - start)) -ge 300 ]; then
        delay=10
        deaths=0
    fi
    if [ -f "$ROOT/versions/$h/ok" ]; then
        deaths=0
    else
        if [ "$h" != "$death_hash" ]; then
            death_hash=$h
            deaths=0
        fi
        deaths=$((deaths + 1))
        if [ "$deaths" -ge 3 ]; then
            read_current
            reject "$h"
            deaths=0
        fi
    fi
    log "controller of snapshot $h exited with $code; starting again in $delay s"
    pause "$delay"
    delay=$((delay * 2))
    if [ "$delay" -gt 60 ]; then
        delay=60
    fi
done
