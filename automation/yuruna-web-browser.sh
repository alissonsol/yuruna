#!/bin/bash
# Version: 2026.11.23
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42387708-a281-49f4-bf6d-285e844b7de7
#
# Start, hold and stop the headless browser of a web session in the guest. Never
# installed: the host sends this text inside its ssh command, so a guest restored
# from an old snapshot still runs the current launcher.
#
# --- REGION: Parse arguments
# start --id I [--browser P] [--ready-seconds N] [--window W,H]; hold --id I; stop --id I | --all.
# Each verb writes one result line, YURUNA_WEB_BROWSER <json>, on stdout; diagnostics go to stderr.
set -uo pipefail

yw_usage() {
    echo "yuruna-web-browser: $*" >&2
    exit 64
}

YW_VERB="${1:-}"
case "$YW_VERB" in
    start|hold|stop) shift ;;
    *) yw_usage "the first argument must be start, hold or stop" ;;
esac

YW_ID=''
YW_HAS_ID=0
YW_BROWSER=''
YW_HAS_BROWSER=0
YW_READY=30
YW_WINDOW='1280,800'
YW_ALL=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --id|--browser|--ready-seconds|--window)
            [ "$#" -ge 2 ] || yw_usage "$1 needs a value" ;;
    esac
    case "$YW_VERB:$1" in
        start:--id|hold:--id|stop:--id) YW_ID="$2"; YW_HAS_ID=1; shift 2 ;;
        start:--browser) YW_BROWSER="$2"; YW_HAS_BROWSER=1; shift 2 ;;
        start:--ready-seconds) YW_READY="$2"; shift 2 ;;
        start:--window) YW_WINDOW="$2"; shift 2 ;;
        stop:--all) YW_ALL=1; shift ;;
        *) yw_usage "unknown argument for $YW_VERB: $1" ;;
    esac
done

if [ "$YW_HAS_ID" = 1 ] && ! [[ "$YW_ID" =~ ^[A-Za-z0-9._-]{1,16}$ ]]; then
    yw_usage "--id must be 1 to 16 characters of A-Z, a-z, 0-9, '.', '_' or '-'"
fi
if ! [[ "$YW_READY" =~ ^[1-9][0-9]{0,2}$ ]]; then
    yw_usage "--ready-seconds must be a whole number from 1 to 999"
fi
if ! [[ "$YW_WINDOW" =~ ^[1-9][0-9]{0,4},[1-9][0-9]{0,4}$ ]]; then
    yw_usage "--window must be two whole numbers from 1 to 99999 joined by a comma"
fi
case "$YW_VERB" in
    start|hold)
        [ "$YW_HAS_ID" = 1 ] || yw_usage "$YW_VERB needs --id" ;;
    stop)
        [ "$YW_HAS_ID" = 1 ] || [ "$YW_ALL" = 1 ] || yw_usage "stop needs --id or --all"
        if [ "$YW_HAS_ID" = 1 ] && [ "$YW_ALL" = 1 ]; then
            yw_usage "stop takes --id or --all, not both"
        fi ;;
esac

# Every path below goes into a result line unescaped, so each one is limited to
# characters that need no escaping in JSON.
yw_emit() {
    printf 'YURUNA_WEB_BROWSER %s\n' "$1"
}

yw_detail() {
    local text
    text=$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9 ._:/=,-' '?')
    printf '%s' "${text:0:400}"
}

yw_refuse() {
    yw_emit "{\"ok\":false,\"kind\":\"$1\",\"detail\":\"$(yw_detail "$3")\"}"
    exit "$2"
}

# --- REGION: State folder
# The base never follows TMPDIR: a long socket path under it stops the browser at start.
YW_UID=$(id -u)
if [ -n "${YURUNA_WEB_BASE+set}" ]; then
    YW_BASE="$YURUNA_WEB_BASE"
    if ! [[ "$YW_BASE" =~ ^/[A-Za-z0-9._/-]*$ ]]; then
        yw_usage "YURUNA_WEB_BASE must be an absolute path of A-Z, a-z, 0-9, '.', '_', '/' or '-'"
    fi
    while [ "${#YW_BASE}" -gt 1 ] && [ "${YW_BASE%/}" != "$YW_BASE" ]; do
        YW_BASE="${YW_BASE%/}"
    done
else
    YW_BASE="/tmp/yuruna-web-$YW_UID"
fi

if [ "$YW_VERB" = start ] && [ ! -e "$YW_BASE" ] && [ ! -L "$YW_BASE" ]; then
    if ! mkdir -m 700 -- "$YW_BASE" 2>/dev/null && [ ! -d "$YW_BASE" ]; then
        yw_refuse state-dir-unavailable 73 "cannot create $YW_BASE"
    fi
fi
if [ -e "$YW_BASE" ] || [ -L "$YW_BASE" ]; then
    if [ -L "$YW_BASE" ] || [ ! -d "$YW_BASE" ] || [ ! -O "$YW_BASE" ]; then
        yw_refuse state-dir-unsafe 73 "$YW_BASE is a link, not a folder, or not owned by uid $YW_UID"
    fi
fi

YW_BOOT=$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null)
if ! [[ "$YW_BOOT" =~ ^[A-Za-z0-9-]{1,8}$ ]]; then
    YW_BOOT='noboot'
fi

shopt -s nullglob dotglob

# --- REGION: Ownership and stop
# A process is the session's browser only when its pid, its start time and its exact
# profile argument all agree; nothing is ever signaled by pid alone.
yw_stat_ticks() {
    local line rest fields
    line=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    rest="${line##*") "}"
    # IFS is named here: a trap that runs during `IFS= read` sees the empty IFS of that read.
    IFS=' ' read -r -a fields <<< "$rest"
    [ "${#fields[@]}" -ge 20 ] || return 1
    printf '%s\n' "${fields[19]}"
}

# Chrome rewrites its process title once it runs: /proc/<pid>/cmdline then holds every
# argument in one string joined by spaces. So the argument counts when it is a whole
# NUL-separated argument or a whole space-separated word; the base folder and the id
# allow no space, so a word is still the exact argument.
yw_has_arg() {
    grep -q -F -x -- "$2" < <(tr ' \0' '\n' 2>/dev/null < "/proc/$1/cmdline")
}

yw_owned_pid() {
    local dir="$1" pid ticks now
    pid=$(cat "$dir/pid" 2>/dev/null) || return 1
    ticks=$(cat "$dir/ticks" 2>/dev/null) || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] && [[ "$ticks" =~ ^[0-9]+$ ]] || return 1
    [ -d "/proc/$pid" ] || return 1
    now=$(yw_stat_ticks "$pid") || return 1
    [ "$now" = "$ticks" ] || return 1
    yw_has_arg "$pid" "--user-data-dir=$dir/profile" || return 1
    printf '%s\n' "$pid"
}

# procps reads a numeric -g list as session ids; setsid made the browser's session and
# process group the same number, so this also sees a child that left the group.
yw_session_alive() {
    [ -n "$(ps -o pid= -g "$1" 2>/dev/null)" ]
}

yw_wait_session_gone() {
    local steps=$(( $2 * 10 )) i=0
    while [ "$i" -lt "$steps" ] && yw_session_alive "$1"; do
        sleep 0.1
        i=$((i + 1))
    done
    ! yw_session_alive "$1"
}

# Prints 1 when a browser was running in the folder, else 0; fails when a browser or
# the folder is left.
yw_stop_dir() {
    local dir="$1" name pid was=0 other
    name="${dir#"$YW_BASE"/}"
    case "$dir" in
        "$YW_BASE"/?*) ;;
        *) echo "yuruna-web-browser: refusing $dir: outside $YW_BASE" >&2; return 1 ;;
    esac
    case "$name" in
        */*|.|..) echo "yuruna-web-browser: refusing $dir: not a session folder" >&2; return 1 ;;
    esac
    pid=$(yw_owned_pid "$dir")
    if [ -n "$pid" ]; then
        was=1
        kill -TERM -- "-$pid" 2>/dev/null
        if ! yw_wait_session_gone "$pid" 5; then
            kill -KILL -- "-$pid" 2>/dev/null
            if ! yw_wait_session_gone "$pid" 2; then
                echo "yuruna-web-browser: session $pid of $dir still has a process" >&2
                return 1
            fi
        fi
    fi
    while IFS= read -r other; do
        if [[ "$other" =~ ^[0-9]+$ ]] && yw_has_arg "$other" "--user-data-dir=$dir/profile"; then
            kill -KILL "$other" 2>/dev/null
        fi
    done < <(pgrep -u "$YW_UID" -f -- "--user-data-dir=$dir/profile")
    rm -rf -- "$dir" 2>/dev/null
    if [ -e "$dir" ]; then
        echo "yuruna-web-browser: $dir could not be removed" >&2
        return 1
    fi
    printf '%s\n' "$was"
}

# Applies the stop of one folder to every session folder of the id, or of every id.
# Prints the count of browsers that were running; fails when any stop failed.
yw_stop_matching() {
    local id="$1" dir name result total=0 failed=0
    [ -d "$YW_BASE" ] || { printf '0\n'; return 0; }
    for dir in "$YW_BASE"/*; do
        if [ ! -d "$dir" ] || [ -L "$dir" ]; then
            continue
        fi
        name="${dir##*/}"
        if [ -n "$id" ] && [ "${name%.*}" != "$id" ]; then
            continue
        fi
        if result=$(yw_stop_dir "$dir"); then
            total=$((total + result))
        else
            failed=1
        fi
    done
    printf '%s\n' "$total"
    [ "$failed" = 0 ]
}

# --- REGION: Stop
if [ "$YW_VERB" = stop ]; then
    if [ "$YW_ALL" = 1 ]; then
        YW_STOPPED=$(yw_stop_matching '')
    else
        YW_STOPPED=$(yw_stop_matching "$YW_ID")
    fi || yw_refuse stop-incomplete 71 "a browser or a session folder is left under $YW_BASE"
    yw_emit "{\"ok\":true,\"event\":\"stopped\",\"stopped\":$YW_STOPPED}"
    exit 0
fi

YW_DIR="$YW_BASE/$YW_ID.$YW_BOOT"

# --- REGION: Hold
# The browser lives while the caller's input lasts: an owner that dies, a dropped
# connection and an orderly close all end the input, and each ends the browser.
yw_hold_end() {
    local event="$1" code="$2" stopped
    stopped=$(yw_stop_dir "$YW_DIR") \
        || yw_refuse stop-incomplete 71 "the browser or the folder of $YW_ID is left"
    yw_emit "{\"ok\":true,\"event\":\"$event\",\"id\":\"$YW_ID\",\"stopped\":$stopped}"
    exit "$code"
}

if [ "$YW_VERB" = hold ]; then
    YW_PID=''
    if [ -d "$YW_BASE" ]; then
        YW_PID=$(yw_owned_pid "$YW_DIR")
    fi
    [ -n "$YW_PID" ] || yw_refuse session-not-found 66 "no browser of this account for id $YW_ID"
    trap 'yw_hold_end signaled 0' HUP TERM INT
    yw_emit "{\"ok\":true,\"event\":\"holding\",\"id\":\"$YW_ID\",\"pid\":$YW_PID}"
    while :; do
        IFS= read -r -t 2 _
        YW_READ=$?
        if [ "$YW_READ" -eq 0 ]; then
            continue
        elif [ "$YW_READ" -gt 128 ]; then
            if [ -n "$(yw_owned_pid "$YW_DIR")" ]; then
                continue
            fi
            yw_hold_end browser-exited 70
        else
            break
        fi
    done
    yw_hold_end released 0
fi

# --- REGION: Start
command -v setsid >/dev/null 2>&1 || yw_refuse setsid-missing 69 "setsid is not on PATH"
# One browser per guest account: a browser left by an owner that died ends here.
yw_stop_matching '' >/dev/null \
    || yw_refuse stale-session-not-stopped 71 "an earlier browser under $YW_BASE would not end"

if [ "$YW_HAS_BROWSER" = 0 ]; then
    for YW_CANDIDATE in google-chrome-stable google-chrome chromium chromium-browser microsoft-edge-stable; do
        if YW_BROWSER=$(command -v "$YW_CANDIDATE" 2>/dev/null); then
            break
        fi
        YW_BROWSER=''
    done
    [ -n "$YW_BROWSER" ] || yw_refuse browser-not-found 127 "no browser on PATH"
fi
if ! [[ "$YW_BROWSER" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    yw_refuse browser-path-unsupported 64 "the browser path has a character outside A-Za-z0-9._/-"
fi
if [ ! -f "$YW_BROWSER" ] || [ ! -x "$YW_BROWSER" ]; then
    yw_refuse browser-not-found 127 "$YW_BROWSER is not an executable file"
fi

if ! mkdir -m 700 -- "$YW_DIR" 2>/dev/null; then
    yw_refuse session-exists 73 "cannot create $YW_DIR"
fi
if ! mkdir -- "$YW_DIR/profile" "$YW_DIR/t" "$YW_DIR/home" 2>/dev/null; then
    rm -rf -- "$YW_DIR" 2>/dev/null
    yw_refuse session-exists 73 "cannot create the folders of $YW_DIR"
fi

# The redirections let the ssh command that runs start end while the browser lives.
HOME="$YW_DIR/home" TMPDIR="$YW_DIR/t" LANGUAGE=en_US \
    setsid "$YW_BROWSER" --headless=new "--user-data-dir=$YW_DIR/profile" --remote-debugging-port=0 \
    --no-first-run --no-default-browser-check --disable-gpu "--window-size=$YW_WINDOW" \
    --disable-background-networking --disable-component-update --disable-sync --disable-default-apps \
    --disable-breakpad --no-pings --password-store=basic --disable-extensions \
    --disable-component-extensions-with-background-pages about:blank \
    </dev/null >"$YW_DIR/browser.log" 2>&1 &
YW_PID=$!
disown "$YW_PID" 2>/dev/null
printf '%s\n' "$YW_PID" > "$YW_DIR/pid"

yw_abort() {
    local kind="$1" code="$2" log="$YW_DIR/browser.log" detail
    if grep -q 'Socket path too long' "$log" 2>/dev/null; then
        kind='socket-path-too-long'
    elif grep -q 'No usable sandbox' "$log" 2>/dev/null; then
        kind='sandbox-unavailable'
    fi
    detail=$(grep -m 1 'FATAL' "$log" 2>/dev/null)
    if [ -z "$detail" ]; then
        detail=$(tail -c 300 "$log" 2>/dev/null)
    fi
    kill -KILL -- "-$YW_PID" 2>/dev/null
    yw_wait_session_gone "$YW_PID" 2 >/dev/null
    rm -rf -- "$YW_DIR" 2>/dev/null
    yw_refuse "$kind" "$code" "$detail"
}

YW_PORT=''
YW_WS=''
YW_TICKS=''
YW_TRIES=0
YW_READY_SEEN=0
while [ "$YW_TRIES" -lt $(( YW_READY * 10 )) ]; do
    kill -0 "$YW_PID" 2>/dev/null || yw_abort browser-exited 70
    if [ -z "$YW_TICKS" ] && yw_has_arg "$YW_PID" "--user-data-dir=$YW_DIR/profile"; then
        if YW_TICKS=$(yw_stat_ticks "$YW_PID"); then
            printf '%s\n' "$YW_TICKS" > "$YW_DIR/ticks"
        else
            YW_TICKS=''
        fi
    fi
    if [ -n "$YW_TICKS" ] && [ -r "$YW_DIR/profile/DevToolsActivePort" ]; then
        YW_PORT=$(sed -n '1p' "$YW_DIR/profile/DevToolsActivePort" 2>/dev/null)
        YW_WS=$(sed -n '2p' "$YW_DIR/profile/DevToolsActivePort" 2>/dev/null)
        if [[ "$YW_PORT" =~ ^[0-9]{1,5}$ ]] && [[ "$YW_WS" =~ ^/devtools/browser/[A-Za-z0-9/-]*$ ]] \
                && [ "${#YW_WS}" -ge 19 ] && (exec 3<>"/dev/tcp/127.0.0.1/$((10#$YW_PORT))") 2>/dev/null; then
            YW_READY_SEEN=1
            break
        fi
    fi
    sleep 0.1
    YW_TRIES=$((YW_TRIES + 1))
done
[ "$YW_READY_SEEN" = 1 ] || yw_abort not-ready 75

yw_emit "{\"ok\":true,\"event\":\"started\",\"id\":\"$YW_ID\",\"port\":$((10#$YW_PORT)),\"wsPath\":\"$YW_WS\",\"pid\":$YW_PID,\"startTicks\":$YW_TICKS,\"bootId\":\"$YW_BOOT\",\"dir\":\"$YW_DIR\",\"profile\":\"$YW_DIR/profile\",\"browser\":\"$YW_BROWSER\",\"window\":\"$YW_WINDOW\"}"
exit 0
