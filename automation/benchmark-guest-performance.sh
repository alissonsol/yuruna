#!/bin/bash
# Version: 2026.09.12
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# --- REGION: https://yuruna.link/42dc5bb9-0010
set -uo pipefail
export LC_ALL=C
umask 077

benchmark_size=256
benchmark_timeout=45
while [ "$#" -gt 0 ]; do
    case "$1" in
        --size-mib) benchmark_size=${2:-}; shift 2 || exit 2 ;;
        --timeout-seconds) benchmark_timeout=${2:-}; shift 2 || exit 2 ;;
        --help)
            printf '%s\n' 'Usage: bash benchmark-guest-performance.sh [--size-mib 1..1024] [--timeout-seconds 5..120]'
            printf '%s\n' 'Measures SHA-256 throughput and synchronous/buffered writes in a disposable file; each phase has a deadline.'
            exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done
if ! [[ "$benchmark_size" =~ ^[0-9]{1,4}$ && "$benchmark_timeout" =~ ^[0-9]{1,3}$ ]]; then
    printf 'Sizes and deadlines must be positive integers.\n' >&2; exit 2
fi
benchmark_size=$((10#$benchmark_size))
benchmark_timeout=$((10#$benchmark_timeout))
if [ "$benchmark_size" -lt 1 ] || [ "$benchmark_size" -gt 1024 ] || [ "$benchmark_timeout" -lt 5 ] || [ "$benchmark_timeout" -gt 120 ]; then
    printf 'Requested size or deadline is outside its bounded range.\n' >&2; exit 2
fi
for benchmark_tool in timeout openssl dd sync mktemp; do
    command -v "$benchmark_tool" >/dev/null 2>&1 || { printf 'state=unavailable missing=%s\n' "$benchmark_tool"; exit 2; }
done
benchmark_dir=$(mktemp -d "${TMPDIR:-/var/tmp}/yuruna-benchmark.XXXXXXXX") || exit 2
benchmark_file="$benchmark_dir/io.bin"
trap 'rm -f -- "$benchmark_file"; rmdir -- "$benchmark_dir"' EXIT

# --- REGION: Clock correlation
printf 'benchmarkUtc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
printf 'architecture=%s\n' "$(uname -m)"
printf 'kernel=%s\n' "$(uname -r)"
printf 'sizeMiB=%s phaseDeadlineSeconds=%s\n' "$benchmark_size" "$benchmark_timeout"
printf 'bootId='; cat /proc/sys/kernel/random/boot_id
printf 'uptime='; cat /proc/uptime
openssl version
benchmark_failed=0

benchmark_phase() {
    local phase=$1 code
    shift
    printf '\nphase=%s utc=%s\n' "$phase" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
    printf 'beforeUptime='; cat /proc/uptime
    TIMEFORMAT='elapsedSeconds=%3R userSeconds=%3U systemSeconds=%3S'
    { time timeout --foreground --kill-after=5 "$benchmark_timeout" "$@"; } 2>&1
    code=$?
    printf 'afterUptime='; cat /proc/uptime
    printf 'phase=%s exitCode=%s\n' "$phase" "$code"
    if [ "$code" -ne 0 ]; then benchmark_failed=1; fi
}

# --- REGION: User-mode throughput
benchmark_phase sha256 openssl speed -elapsed -seconds 5 -bytes 8192 sha256

# --- REGION: Storage synchronization
# The child shell expands its own positional arguments.
# shellcheck disable=SC2016
benchmark_phase synchronous-write bash -c 'sync && dd if=/dev/zero of="$1" bs=1M count="$2" oflag=dsync && sync' bash "$benchmark_file" "$benchmark_size"
rm -f -- "$benchmark_file"
# shellcheck disable=SC2016
benchmark_phase buffered-write bash -c 'sync && dd if=/dev/zero of="$1" bs=1M count="$2" && sync' bash "$benchmark_file" "$benchmark_size"
printf '\nbenchmarkCompleteUtc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
exit "$benchmark_failed"
