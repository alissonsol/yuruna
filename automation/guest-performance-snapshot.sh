#!/bin/bash
# Version: 2026.10.11.1
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# A small, read-only sample; the SSH caller supplies the overall 20-second budget.

# --- REGION: Initialize environment
set -u
export LC_ALL=C
snapshot_priv=()
if [ "$(id -u)" != 0 ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    snapshot_priv=(sudo -n)
fi

# --- REGION: snapshot_read
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

# --- REGION: guest_evidence_clock
# /proc/uptime uses BOOTTIME; label it separately from CLOCK_MONOTONIC.
guest_evidence_clock() {
    local uptime idle boot online ticks
    read -r uptime idle < /proc/uptime || true
    read -r boot < /proc/sys/kernel/random/boot_id || true
    read -r online < /sys/devices/system/cpu/online || true
    ticks=$(getconf CLK_TCK 2>/dev/null) || ticks=unavailable
    printf 'guestEvidenceSchema=2\nguestClockUtc=%s\nguestClockEpochSeconds=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" "$(date -u +%s.%N)"
    printf 'guestClockUptimeSeconds=%s\nguestClockIdleSeconds=%s\nguestClockUptimeClock=boottime\n' "${uptime:-unavailable}" "${idle:-unavailable}"
    printf 'guestClockTicksPerSecond=%s\nguestBootId=%s\nguestOnlineCpus=%s\n' "${ticks:-unavailable}" "${boot:-unavailable}" "${online:-unavailable}"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import time; print("guestClockMonotonicSeconds=%.9f" % time.clock_gettime(time.CLOCK_MONOTONIC)); print("guestClockBoottimeSeconds=%.9f" % time.clock_gettime(time.CLOCK_BOOTTIME))' 2>/dev/null || printf 'guestClockMonotonicSeconds=unavailable\n'
    else
        printf 'guestClockMonotonicSeconds=unavailable\nguestClockBoottimeSeconds=%s\n' "${uptime:-unavailable}"
    fi
}

# --- REGION: guest_evidence_safe_path
# Refuse symlinked source paths rather than digesting files outside a checkout.
guest_evidence_safe_path() {
    local path=$1
    [[ $path == /* && $path != *'/../'* && $path != */.. ]] || return 1
    while [ "$path" != / ]; do
        [ ! -L "$path" ] || return 1
        path=${path%/*}; [ -n "$path" ] || path=/
    done
}

# --- REGION: guest_evidence_hash
# Bound both source bytes and labels; a digest never exposes source contents.
guest_evidence_hash() {
    local label=$1 path=$2 bytes digest
    if ! guest_evidence_safe_path "$path"; then printf 'guestProvenance.%s.sha256=unsafe-path\n' "$label"; return; fi
    if [ ! -f "$path" ]; then printf 'guestProvenance.%s.sha256=absent\n' "$label"; return; fi
    bytes=$(stat -c %s -- "$path" 2>/dev/null) || bytes=''
    if [[ ! $bytes =~ ^[0-9]+$ ]] || [ "$bytes" -gt 4194304 ]; then printf 'guestProvenance.%s.sha256=size-unavailable-or-over-4194304\n' "$label"; return; fi
    digest=$(sha256sum -- "$path" 2>/dev/null) || digest=''
    digest=${digest%% *}
    [[ $digest =~ ^[0-9a-f]{64}$ ]] || digest=unavailable
    printf 'guestProvenance.%s.sha256=%s\n' "$label" "$digest"
}

# --- REGION: guest_evidence_revision
# An archive nested inside another Git checkout must not inherit its parent's HEAD.
guest_evidence_revision() {
    local label=$1 root=$2 revision='' source=unavailable top bytes
    if ! guest_evidence_safe_path "$root"; then source=unsafe-path
    elif [ -e "$root/.git" ] || [ -L "$root/.git" ]; then
        source=invalid-git
        if guest_evidence_safe_path "$root/.git" && { [ -d "$root/.git" ] || [ -f "$root/.git" ]; } && command -v git >/dev/null 2>&1; then
            top=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || top=''
            if [ "$top" = "$root" ]; then
                revision=$(git -C "$root" rev-parse --verify HEAD 2>/dev/null) || revision=''
                if [[ $revision =~ ^[0-9a-fA-F]{40}$ || $revision =~ ^[0-9a-fA-F]{64}$ ]]; then source=git; else revision=''; fi
            fi
        elif ! guest_evidence_safe_path "$root/.git"; then source=unsafe-path; fi
    elif [ -e "$root/.yuruna-revision" ] || [ -L "$root/.yuruna-revision" ]; then
        source=invalid-archive
        if guest_evidence_safe_path "$root/.yuruna-revision" && [ -f "$root/.yuruna-revision" ]; then
            bytes=$(stat -c %s -- "$root/.yuruna-revision" 2>/dev/null) || bytes=''
            if [[ $bytes =~ ^[0-9]+$ ]] && [ "$bytes" -le 256 ]; then
                revision=$(head -c 256 -- "$root/.yuruna-revision" 2>/dev/null)
                if [[ $revision =~ ^[0-9a-fA-F]{40}$ || $revision =~ ^[0-9a-fA-F]{64}$ ]]; then source=archive; else revision=''; fi
            fi
        else source=unsafe-path; fi
    fi
    printf 'guestProvenance.%s.revision=%s\nguestProvenance.%s.revisionSource=%s\n' "$label" "${revision:-unavailable}" "$label" "$source"
}
# --- REGION: guest_evidence_provenance
# Fixed source paths identify guest materialization independently of host status SHAs.
guest_evidence_provenance() {
    local user_home=${HOME:-} root path passwd
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] && command -v getent >/dev/null 2>&1; then
        passwd=$(getent passwd "$SUDO_USER" 2>/dev/null) || passwd=''
        IFS=: read -r _ _ _ _ _ user_home _ <<< "$passwd"
    fi
    case "$user_home" in /*) ;; *) printf 'guestProvenance.state=home-unavailable\n'; return ;; esac
    root=${user_home%/}/yuruna
    guest_evidence_revision framework "$root"
    guest_evidence_revision project "$root/project"
    for path in automation/fetch-and-execute.sh automation/yuruna-retry.sh guest/shared/ubuntu.update.sh guest/ubuntu.server.24/ubuntu.server.24.k8s.sh guest/ubuntu.server.26/ubuntu.server.26.k8s.sh; do
        guest_evidence_hash "framework.$path" "$root/$path"
    done
    for path in tools/example-workload.sh tools/Example.Build.psm1 example/website/components/frontend/website/{Dockerfile,Example.Build.psm1} example/text-to-sql/components/frontend/text-to-sql-ui/{Dockerfile,Example.Build.psm1}; do
        guest_evidence_hash "project.$path" "$root/project/$path"
    done
    for path in fetch-and-execute.sh yuruna-retry.sh yuruna-fetch-context.sh; do
        guest_evidence_hash "installed.$path" "/usr/local/lib/yuruna/$path"
    done
    if [[ ${FILE_PATH:-} =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] && [[ /${FILE_PATH:-}/ != *'/../'* ]]; then
        guest_evidence_hash localPayload "$root/$FILE_PATH"
    fi
    printf 'fetchedPayloadSha256=%s\nexecutedPayloadSha256=%s\n' "${fae_payload_sha256:-unavailable}" "${fae_executed_sha256:-unavailable}"
}

# --- REGION: guest_evidence_boot_metadata
# Boot metadata is small and stable; the recorder retains it outside its sample ring.
guest_evidence_boot_metadata() {
    local path count=0
    printf '\n--- guest boot metadata ---\nguestKernel=%s\n' "$(uname -srmv 2>/dev/null)"
    for path in /sys/devices/system/clocksource/clocksource*/{current_clocksource,available_clocksource} /sys/devices/system/clockevents/clockevent*/current_device /sys/devices/system/clockevents/broadcast/current_device /sys/devices/system/cpu/{online,present,possible}; do
        [ -r "$path" ] || continue
        printf '\n--- %s ---\n' "$path"; head -c 256 -- "$path" 2>/dev/null
        count=$((count+1)); [ "$count" -ge 80 ] && break
    done
    count=0
    for path in /sys/devices/system/cpu/cpu*/topology/{physical_package_id,core_id,thread_siblings_list}; do
        [ -r "$path" ] || continue
        printf '\n--- %s ---\n' "$path"; head -c 128 -- "$path" 2>/dev/null
        count=$((count+1)); [ "$count" -ge 96 ] && break
    done
    printf '\nbootMetadataAttributes=%s cap=96\n' "$count"
}

# --- REGION: Clock correlation
if [ "${E_CLOCK_ONLY:-0}" = 1 ]; then
    guest_evidence_boot_metadata
    for snapshot_index in 1 2; do
        printf '\n--- YURUNA CLOCK SAMPLE ---\n'
        guest_evidence_clock
        snapshot_read /proc/uptime 128
        snapshot_read /proc/stat 65536
        [ "$snapshot_index" -eq 2 ] || sleep 1
    done
    printf '\nsnapshotCompleteUtc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
    exit 0
fi
guest_evidence_boot_metadata
guest_evidence_provenance
guest_evidence_clock
printf 'snapshotUtc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
printf 'stepInvocationId=%s\nsequenceInvocationId=%s\n' "${E_SI:-}" "${E_QI:-}"
snapshot_read /proc/sys/kernel/random/boot_id 128
snapshot_read /proc/uptime 128

# --- REGION: CPU, memory, and storage pressure
for snapshot_path in /proc/stat /proc/loadavg /proc/pressure/cpu /proc/pressure/io /proc/pressure/memory /proc/meminfo /proc/vmstat /proc/interrupts /proc/softirqs /proc/diskstats; do
    snapshot_read "$snapshot_path"
done

for snapshot_path in /sys/fs/cgroup/{memory.events,memory.events.local,memory.current,memory.max,memory.high,memory.swap.current,memory.swap.max,memory.stat,memory.pressure} /sys/fs/cgroup/memory/{memory.failcnt,memory.usage_in_bytes,memory.limit_in_bytes,memory.oom_control}; do
    [ ! -e "$snapshot_path" ] || snapshot_read "$snapshot_path" 4096
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

# --- REGION: Thread CPU, runnable, and blocked tasks
printf '\n--- per-thread CPU/state (no command arguments) ---\n'
ps -eLo pid=,lwp=,psr=,pcpu=,stat=,comm= 2>&1 | sort -k4,4nr | head -n 64
snapshot_count=0
declare -A snapshot_process=()
while read -r snapshot_pid snapshot_tid snapshot_cpu snapshot_pcpu snapshot_state snapshot_command; do
    case "$snapshot_state" in R*|D*) ;; *) [ "${snapshot_pcpu%.*}" -ge 20 ] 2>/dev/null || continue ;; esac
    printf '\nthreadPid=%s tid=%s cpu=%s cpuLifetimePercent=%s state=%s command=%s\n' "$snapshot_pid" "$snapshot_tid" "$snapshot_cpu" "$snapshot_pcpu" "$snapshot_state" "$snapshot_command"
    if [ -z "${snapshot_process[$snapshot_pid]:-}" ]; then
        snapshot_process[$snapshot_pid]=1
        snapshot_read "/proc/$snapshot_pid/stat" 8192
        snapshot_read "/proc/$snapshot_pid/cgroup" 4096
        snapshot_cgroup=$(awk -F: '$1=="0" && $2=="" {print $3;exit}' "/proc/$snapshot_pid/cgroup" 2>/dev/null)
        if [[ $snapshot_cgroup == /* && $snapshot_cgroup != *'/../'* && $snapshot_cgroup != */.. ]]; then
            for snapshot_path in memory.events memory.events.local memory.current memory.max memory.high memory.swap.current memory.stat memory.pressure; do
                snapshot_read "/sys/fs/cgroup${snapshot_cgroup%/}/$snapshot_path" 2048
            done
        fi
    fi
    snapshot_read "/proc/$snapshot_pid/task/$snapshot_tid/stat" 8192
    snapshot_read "/proc/$snapshot_pid/task/$snapshot_tid/schedstat" 2048
    snapshot_read "/proc/$snapshot_pid/task/$snapshot_tid/wchan" 2048
    snapshot_read "/proc/$snapshot_pid/task/$snapshot_tid/stack" 8192
    snapshot_count=$((snapshot_count + 1))
    if [ "$snapshot_count" -ge 40 ]; then printf '\nThread stacks truncated at 40\n'; break; fi
done < <(ps -eLo pid=,lwp=,psr=,pcpu=,stat=,comm= 2>/dev/null | sort -k4,4nr)
[ "$snapshot_count" -gt 0 ] || printf 'Thread stacks: no runnable or D-state thread in this sample\n'

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
