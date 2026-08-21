#!/bin/bash
# Version: 2026.08.21
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Start-or-attach supervisor for a guest-side payload, so the work outlives the
# ssh session that started it.
#
# --- REGION: https://yuruna.link/network#defining-yuruna-run-supervisor
# Contract:
#   yuruna-run.sh --token T --from-line N --budget S --cmd-b64 B
#   yuruna-run.sh --token T --cancel
# Idempotent on T: starts the run if T is not running, attaches if it is. Streams
# out.log from line N+1 on stdout and exits with the payload's status.
#
# stdout carries payload bytes ONLY -- the host counts stdout lines to know where
# to resume, so every diagnostic this script emits goes to stderr.
set -uo pipefail

YR_TOKEN=''
YR_FROM_LINE=0
YR_BUDGET=3600
YR_CMD_B64=''
YR_CANCEL=0

while [ "$#" -gt 0 ]; do
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

# --- REGION: https://yuruna.link/network#why-the-run-directory-is-scoped-to-the-boot-id
# The run directory is scoped to the boot, not just to the token. Guests in this
# harness are restored from disk snapshots ten times a cycle, and a snapshot
# taken while a run was in flight carries that run's directory -- pid file,
# out.log and all -- back onto a machine where the process it names does not
# exist and the pid may since belong to something else. Scoping on boot_id makes
# a restored corpse simply invisible: the attach cannot find it, so it starts a
# clean run instead of streaming a dead file forever.
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
    echo "YURUNA_RUN_CANCELLED token=${YR_TOKEN}" >&2
    exit 0
fi

mkdir -p "$YR_BASE" 2>/dev/null

# --- REGION: https://yuruna.link/network#why-mkdir-is-the-claim
# `mkdir` of the run directory is the claim, and it is the whole concurrency
# story: it either creates the directory or fails, atomically, with no window in
# which two callers both believe they are the starter. A test-then-create would
# have that window, and two supervisors running the same payload against the
# same output file is precisely the double-execution this script exists to stop.
# --- REGION: https://yuruna.link/network#why-a-run-directory-is-never-removed
# Nothing below ever removes a run directory. It is created once and from then
# on only gains files, so the mkdir claim is monotonic: no later invocation can
# ever win a token that has already been claimed, whatever it concludes about
# the state of the run. A supervisor that tore the directory down on a bad
# verdict -- an empty payload, an unreadable command, a run it judged dead --
# would hand the token back, and the next attach would START A SECOND COPY of a
# payload that may still be running. For a payload that seeds records and then
# asserts counts over them, that is the exact double-execution this whole
# mechanism exists to prevent, arrived at from the other direction. So a
# terminal verdict is recorded as a status instead, which every later attach
# reads and reports without running anything.
yr_terminate() {
    printf '%s' "$1" > "${YR_STATUS}.tmp" 2>/dev/null && mv "${YR_STATUS}.tmp" "$YR_STATUS" 2>/dev/null
}

# --- REGION: https://yuruna.link/network#why-the-claim-is-confirmed-before-it-is-used
# `mkdir` is the claim, and on any POSIX filesystem it is decided by exactly one
# caller. The tiebreak below is the belt to that brace: every winner appends its
# pid and only the FIRST line proceeds to start the payload, so even a directory
# creation that somehow admitted two winners still yields one runner. It costs
# one append and a short settle on the start path only, which is paid once per
# step, and it buys the guarantee the whole mechanism rests on -- a payload that
# seeds records and asserts counts over them must run once or not at all, and
# "the filesystem promised" is a thin thing to rest that on when the check is
# this cheap. It is also what makes the guarantee testable on a filesystem whose
# mkdir is not atomic.
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

    # The runner writes its OWN pid before starting anything, which is what makes
    # "directory exists but pid does not" decidable: it means the payload
    # provably never started, so an attacher may clear the claim and retry
    # instead of waiting out the budget on a run that will never produce output.
    #
    # --- REGION: https://yuruna.link/network#why-the-payload-gets-its-own-process-group
    # `set -m` puts the payload in a process group of its own, with $! as the
    # group id. Two things depend on that. The budget watchdog signals the whole
    # GROUP, so a payload that backgrounds helm/kubectl/cargo does not leave
    # those running into the next step -- timeout(1), and any kill aimed at the
    # payload's pid alone, reach only the direct child. And the runner is
    # OUTSIDE that group, so the same signal does not take down the very process
    # whose job is to record the exit status; a budget kill is reported as 124
    # instead of looking like a run that vanished.
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

    # setsid puts the runner in its own session, so the ssh session ending does
    # not SIGHUP it. nohup is the fallback for an image without util-linux: it
    # blocks the HUP rather than escaping it, which detaches the runner just as
    # effectively here. The payload's own process group -- the thing the budget
    # watchdog signals -- comes from `set -m` inside the runner either way, so
    # neither path changes how the payload is bounded or reaped.
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

# Wait for the runner to record its pid. Absent both pid and status after this
# grace period, the starter died between claiming the directory and exec'ing --
# rare, but indistinguishable from a live run to every later attach, so it is
# reported rather than waited on.
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

# --- REGION: https://yuruna.link/network#why-the-replay-counts-only-complete-lines
# Replay is by COMPLETE lines only, on both ends. `wc -l` counts newlines, so a
# half-written trailing line is never emitted here and never counted by the host
# that is tracking where to resume from. Emitting a partial line would put the
# two ends permanently out of step: the host would count it as delivered and ask
# to resume past it, and the rest of that line would be lost from the transcript
# the failure-pattern matcher and the retry-marker parser read.
yr_next=$((YR_FROM_LINE + 1))

yr_drain() {
    local total
    total="$(wc -l < "$YR_OUT" 2>/dev/null || echo 0)"
    if [ "$total" -ge "$yr_next" ]; then
        sed -n "${yr_next},\$p" "$YR_OUT"
        yr_next=$((total + 1))
    fi
}

while [ ! -f "$YR_STATUS" ]; do
    yr_drain
    # A live pid file whose process is gone, with no status written, means the
    # payload's shell was killed outright (OOM, a stray group kill, a host
    # reboot). Waiting out the budget on that would spend the step's whole
    # timeout on a run that can never finish.
    if [ -r "$YR_PID" ]; then
        yr_pid="$(cat "$YR_PID" 2>/dev/null)"
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

# The payload has exited, so nothing more can be appended. A final byte that is
# not a newline is a complete line the payload simply did not terminate; give it
# one so the last line is delivered rather than held back forever by the
# complete-lines rule above.
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
