#!/bin/bash
# Version: 2026.09.18
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# A small, read-only sample; the SSH caller supplies the overall 20-second budget.

set -u
export LC_ALL=C
snapshot_priv=()
if [ "$(id -u)" != 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    snapshot_priv=(sudo -n)
fi

snapshot_read() {
    local path=$1 limit=${2:-65536}
    printf '\n--- %s ---\n' "$path"
    # The privileged child shell expands its own positional arguments.
    # shellcheck disable=SC2016
    "${snapshot_priv[@]}" sh -c '
        if [ ! -e "$1" ]; then echo "state=absent";
        elif [ ! -r "$1" ]; then echo "state=denied";
        elif [ -f "$1" ]; then
            echo "state=read (bounded prefix)"
            head -c "$2" -- "$1" || echo "state=read-error"
        else echo "state=unavailable"; fi
    ' sh "$path" "$limit" 2>&1
}

# --- REGION: Clock correlation
printf 'snapshotUtc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
printf 'stepInvocationId=%s\nsequenceInvocationId=%s\n' "${E_SI:-}" "${E_QI:-}"
snapshot_read /proc/sys/kernel/random/boot_id 128
snapshot_read /proc/uptime 128

# --- REGION: CPU, memory, and storage pressure
for snapshot_path in /proc/stat /proc/loadavg /proc/pressure/cpu /proc/pressure/io /proc/pressure/memory /proc/interrupts /proc/softirqs /proc/diskstats; do
    snapshot_read "$snapshot_path"
done

# --- REGION: VMBus channels
snapshot_count=0
for snapshot_path in /sys/bus/vmbus/devices/*/channels/*/{cpu,interrupts,events,latency}; do
    [ -e "$snapshot_path" ] || continue
    snapshot_read "$snapshot_path" 2048
    snapshot_count=$((snapshot_count + 1))
    if [ "$snapshot_count" -ge 256 ]; then printf '\nVMBus attributes truncated at 256\n'; break; fi
done
[ "$snapshot_count" -gt 0 ] || printf 'VMBus attributes: state=absent\n'

# --- REGION: Blocked tasks
snapshot_count=0
while read -r snapshot_pid snapshot_state snapshot_command; do
    case "$snapshot_state" in D*) ;; *) continue ;; esac
    printf '\nblockedPid=%s state=%s command=%s\n' "$snapshot_pid" "$snapshot_state" "$snapshot_command"
    snapshot_read "/proc/$snapshot_pid/wchan" 2048
    snapshot_read "/proc/$snapshot_pid/stack" 8192
    snapshot_count=$((snapshot_count + 1))
    if [ "$snapshot_count" -ge 40 ]; then printf '\nBlocked tasks truncated at 40\n'; break; fi
done < <(ps -eo pid=,stat=,comm=)

# --- REGION: Kernel and installer logs
if command -v journalctl >/dev/null 2>&1; then
    "${snapshot_priv[@]}" journalctl -k -b --no-pager -n 60 -o short-monotonic 2>&1
else
    printf 'kernel journal: state=unavailable\n'
fi
for snapshot_path in /var/log/installer/{subiquity-server-debug.log,subiquity-curtin-install.log,curtin-install.log} /var/log/cloud-init-output.log; do
    printf '\n--- %s (tail, at most 16384 bytes) ---\n' "$snapshot_path"
    # shellcheck disable=SC2016
    "${snapshot_priv[@]}" sh -c '
        if [ ! -e "$1" ]; then echo "state=absent";
        elif [ ! -r "$1" ]; then echo "state=denied";
        else echo "state=read"; tail -c 16384 -- "$1" || echo "state=read-error"; fi
    ' sh "$snapshot_path" 2>&1
done
printf '\nsnapshotCompleteUtc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
