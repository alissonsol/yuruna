#!/bin/bash
# Version: 2026.10.11
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Start-or-attach supervisor for a guest-side payload, so the work outlives the
# ssh session that started it.
#
# --- REGION: https://yuruna.link/4220a755-0035
# Start/attach: --token T --from-line N --budget S --cmd-b64 B; cancel: --token T --cancel.
# Keep diagnostics on stderr so the host's stdout resume cursor counts only payload lines.
set -uo pipefail

YR_TOKEN=''
YR_FROM_LINE=0
YR_BUDGET=3600
YR_CMD_B64=''
YR_CANCEL=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --token|--from-line|--budget|--cmd-b64)
            if [ "$#" -lt 2 ]; then
                echo "yuruna-run: $1 needs a value" >&2
                exit 64
            fi ;;
    esac
    case "$1" in
        --token)     YR_TOKEN="${2:-}"; shift 2 ;;
        --from-line) YR_FROM_LINE="${2:-0}"; shift 2 ;;
        --budget)    YR_BUDGET="${2:-3600}"; shift 2 ;;
        --cmd-b64)   YR_CMD_B64="${2:-}"; shift 2 ;;
        --cancel)    YR_CANCEL=1; shift ;;
        *) echo "yuruna-run: unknown argument '$1'" >&2; exit 64 ;;
    esac
done

if [ -z "$YR_TOKEN" ]; then
    echo "yuruna-run: --token is required" >&2
    exit 64
fi
case "$YR_TOKEN" in
    *[!A-Za-z0-9._-]*) echo "yuruna-run: --token may only contain A-Za-z0-9._-" >&2; exit 64 ;;
esac
case "$YR_FROM_LINE" in
    ''|*[!0-9]*) echo "yuruna-run: --from-line must be a whole number" >&2; exit 64 ;;
esac
case "$YR_BUDGET" in
    ''|*[!0-9]*) echo "yuruna-run: --budget must be a whole number of seconds" >&2; exit 64 ;;
esac

# --- REGION: https://yuruna.link/4220a755-0036
# Scope runs to the boot so restored snapshots cannot attach to obsolete processes.
YR_BOOT=''
if [ -r /proc/sys/kernel/random/boot_id ]; then
    YR_BOOT="$(cut -c1-8 /proc/sys/kernel/random/boot_id 2>/dev/null)"
fi
[ -n "$YR_BOOT" ] || YR_BOOT='noboot'

YR_BASE="${TMPDIR:-/tmp}/yuruna-run"
YR_DIR="${YR_BASE}/${YR_TOKEN}.${YR_BOOT}"
YR_OUT="${YR_DIR}/out.log"
YR_PID="${YR_DIR}/pid"
YR_STATUS="${YR_DIR}/status"

if [ "$YR_CANCEL" = '1' ]; then
    if [ -r "${YR_DIR}/payload_pgid" ]; then
        yr_pgid="$(cat "${YR_DIR}/payload_pgid" 2>/dev/null)"
        [ -n "$yr_pgid" ] && kill -TERM "-${yr_pgid}" 2>/dev/null
        sleep 1
        [ -n "$yr_pgid" ] && kill -KILL "-${yr_pgid}" 2>/dev/null
    fi
    printf '%s' '143' > "${YR_STATUS}.tmp" 2>/dev/null && mv "${YR_STATUS}.tmp" "$YR_STATUS" 2>/dev/null
    echo "YURUNA_RUN_CANCELED token=${YR_TOKEN}" >&2
    exit 0
fi

mkdir -p "$YR_BASE" 2>/dev/null

# --- REGION: https://yuruna.link/4220a755-0037
# Atomic mkdir prevents two callers from starting the same payload.
# --- REGION: https://yuruna.link/4220a755-0038
# Record terminal status without deleting the claim; later attaches must not rerun payloads.
# --- REGION: yr_terminate
yr_terminate() {
    printf '%s' "$1" > "${YR_STATUS}.tmp" 2>/dev/null && mv "${YR_STATUS}.tmp" "$YR_STATUS" 2>/dev/null
}

# --- REGION: https://yuruna.link/4220a755-0039
# Confirm the first claimant before starting a payload, including on unusual filesystems.
yr_claimed=0
if mkdir "$YR_DIR" 2>/dev/null; then
    echo "$$" >> "${YR_DIR}/claim" 2>/dev/null
    sleep 0.2
    if [ "$(head -n 1 "${YR_DIR}/claim" 2>/dev/null)" = "$$" ]; then
        yr_claimed=1
    else
        echo "YURUNA_RUN_CLAIM_YIELD token=${YR_TOKEN} pid=$$ winner=$(head -n 1 "${YR_DIR}/claim" 2>/dev/null)" >&2
    fi
fi

if [ "$yr_claimed" = '1' ]; then
    if [ -z "$YR_CMD_B64" ]; then
        echo "yuruna-run: --cmd-b64 is required to start a run" >&2
        yr_terminate 64
        exit 64
    fi
    : > "$YR_OUT"
    if ! printf '%s' "$YR_CMD_B64" | base64 -d > "${YR_DIR}/cmd.sh" 2>/dev/null; then
        echo "yuruna-run: --cmd-b64 is not valid base64" >&2
        yr_terminate 64
        exit 64
    fi

    # See https://yuruna.link/4220a755-0038
    # Record the runner PID before starting the payload so an absent starter is diagnosable.
    # --- REGION: https://yuruna.link/4220a755-003a
    # Give the payload its own process group so cancellation reaches its children.
    cat > "${YR_DIR}/run.sh" <<'YR_RUNNER'
#!/bin/bash
YR_DIR="$1"
YR_BUDGET="$2"
echo $$ > "${YR_DIR}/pid"
set -m
bash "${YR_DIR}/cmd.sh" >> "${YR_DIR}/out.log" 2>&1 &
YR_PAY=$!
set +m
printf '%s' "$YR_PAY" > "${YR_DIR}/payload_pgid"
( sleep "$YR_BUDGET"
  kill -TERM "-${YR_PAY}" 2>/dev/null
  sleep 30
  kill -KILL "-${YR_PAY}" 2>/dev/null ) &
YR_WD=$!
wait "$YR_PAY"
YR_RC=$?
kill "$YR_WD" 2>/dev/null
kill -KILL "-${YR_PAY}" 2>/dev/null
printf '%s' "$YR_RC" > "${YR_DIR}/status.tmp"
mv "${YR_DIR}/status.tmp" "${YR_DIR}/status"
YR_RUNNER

    # See https://yuruna.link/4220a755-003a
    # Detach the runner from SSH hangup; payload grouping still comes from set -m.
    if command -v setsid >/dev/null 2>&1; then
        setsid bash "${YR_DIR}/run.sh" "$YR_DIR" "$YR_BUDGET" </dev/null >/dev/null 2>&1 &
    else
        nohup bash "${YR_DIR}/run.sh" "$YR_DIR" "$YR_BUDGET" </dev/null >/dev/null 2>&1 &
    fi
    echo "YURUNA_RUN_START token=${YR_TOKEN} boot=${YR_BOOT}" >&2
else
    if [ ! -d "$YR_DIR" ]; then
        echo "yuruna-run: could not create or find the run directory '${YR_DIR}'" >&2
        exit 74
    fi
    echo "YURUNA_RUN_ATTACH token=${YR_TOKEN} boot=${YR_BOOT} from=${YR_FROM_LINE}" >&2
fi

# See https://yuruna.link/4220a755-0038
# Bound startup grace; missing PID and status means the starter vanished.
yr_wait=0
while [ ! -r "$YR_PID" ] && [ ! -f "$YR_STATUS" ] && [ "$yr_wait" -lt 100 ]; do
    sleep 0.1
    yr_wait=$((yr_wait + 1))
done
if [ ! -r "$YR_PID" ] && [ ! -f "$YR_STATUS" ]; then
    echo "!! DETACHED RUN VANISHED token=${YR_TOKEN}: the run directory was claimed but no process ever recorded itself. The payload did not start." >&2
    yr_terminate 250
    echo "YURUNA_RUN_EXIT rc=250 lines=${YR_FROM_LINE}" >&2
    exit 250
fi

# --- REGION: https://yuruna.link/4220a755-003b
# Advance replay only by complete lines, matching the host resume cursor.
yr_next=$((YR_FROM_LINE + 1))

# --- REGION: yr_drain
# Replay reads through one descriptor that stays open, so a tick starts
# no process and costs only the new output: counting lines with wc and
# printing a range with sed would rescan the whole log every half second.
yr_read=0
yr_partial=''
yr_out_open=0
yr_drain() {
    local line
    if [ "$yr_out_open" != 1 ]; then
        [ -r "$YR_OUT" ] || return 0
        exec 7<"$YR_OUT" || return 0
        yr_out_open=1
    fi
    while IFS= read -r line <&7; do
        line="${yr_partial}${line}"
        yr_partial=''
        yr_read=$((yr_read + 1))
        if [ "$yr_read" -ge "$yr_next" ]; then
            printf '%s\n' "$line"
            yr_next=$((yr_read + 1))
        fi
    done
    # read returns false at end of file; what it read is an unfinished line.
    yr_partial="${yr_partial}${line}"
}

while [ ! -f "$YR_STATUS" ]; do
    yr_drain
    # See https://yuruna.link/4220a755-0038
    # Report vanished runners promptly when no exit status was recorded.
    if [ -r "$YR_PID" ]; then
        yr_pid=''; read -r yr_pid < "$YR_PID" 2>/dev/null || :
        if [ -n "$yr_pid" ] && ! kill -0 "$yr_pid" 2>/dev/null; then
            sleep 1
            if [ ! -f "$YR_STATUS" ]; then
                yr_drain
                yr_terminate 250
                echo "!! DETACHED RUN VANISHED token=${YR_TOKEN}: the payload's process is gone and no exit status was recorded." >&2
                echo "YURUNA_RUN_EXIT rc=250 lines=$((yr_next - 1))" >&2
                exit 250
            fi
        fi
    fi
    sleep 0.5
done

# See https://yuruna.link/4220a755-003b
# Terminate a final partial line only after payload completion.
if [ -s "$YR_OUT" ] && [ "$(tail -c 1 "$YR_OUT" 2>/dev/null | od -An -c 2>/dev/null | tr -d ' ')" != '\n' ]; then
    printf '\n' >> "$YR_OUT"
fi
yr_drain

yr_rc="$(cat "$YR_STATUS" 2>/dev/null)"
case "$yr_rc" in
    ''|*[!0-9]*) yr_rc=250 ;;
esac
echo "YURUNA_RUN_EXIT rc=${yr_rc} lines=$((yr_next - 1))" >&2
exit "$yr_rc"
