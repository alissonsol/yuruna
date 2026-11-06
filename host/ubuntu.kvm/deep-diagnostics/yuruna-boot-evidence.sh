#!/bin/bash
# Version: 2026.11.05
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42fc5df4-0209-487a-b39c-fe071ce51bbf
#
# Once per boot, after systemd-pstore has archived any crash records and the
# journal is on disk, writes one bounded text bundle about how the previous
# boot ended, plus this boot's hardware-error lines, to
# /var/log/yuruna/deep-diagnostics/boot-<yyyyMMddTHHmmssZ>-<boot id prefix>.txt
# (directory 0750 and file 0640, group systemd-journal). A host that froze
# wrote nothing about it at the time; this bundle is where the evidence
# surfaces afterwards, and the runner's boot recovery copies it from here.
#
# Usage: yuruna-boot-evidence.sh [--output <file>]
#   --output writes the bundle to that file, even when this boot has one.

# --- REGION: Initialize environment
set -u
export LC_ALL=C
umask 027
evidence_dir=/var/log/yuruna/deep-diagnostics
evidence_max_bytes=2097152
evidence_section_bytes=262144
evidence_previous_id=''
evidence_previous_last=''
evidence_boot_start=''

# --- REGION: evidence_target
# Prints the bundle path for this boot, or nothing when the directory already
# holds one: the service runs at every boot and again whenever Enable starts
# it, and the contract is one bundle per boot.
evidence_target() {
    local dir=$1 boot_id=$2 stamp=$3 short existing
    short=${boot_id:0:8}
    for existing in "$dir"/boot-*-"$short".txt; do
        [ -e "$existing" ] && return 0
    done
    printf '%s/boot-%s-%s.txt\n' "$dir" "$stamp" "$short"
}

# --- REGION: evidence_previous_boot
# Reads the previous boot's id and the time of its last journal entry, which
# is the closest record of when that boot stopped. The journal writes a boot
# id as 32 hex digits; it is given in the dashed form of
# /proc/sys/kernel/random/boot_id, the form bootId has, so the two compare.
evidence_previous_boot() {
    local line value id
    while IFS= read -r line; do
        case $line in
            _BOOT_ID=*) evidence_previous_id=${line#_BOOT_ID=} ;;
            __REALTIME_TIMESTAMP=*)
                value=${line#__REALTIME_TIMESTAMP=}
                if [[ $value =~ ^[0-9]+$ ]]; then
                    evidence_previous_last=$((value / 1000000))
                fi
                ;;
        esac
    done < <(journalctl -q -b -1 -n 1 -o export --no-pager 2>/dev/null)
    id=$evidence_previous_id
    if [[ $id =~ ^[0-9a-f]{32}$ ]]; then
        evidence_previous_id=${id:0:8}-${id:8:4}-${id:12:4}-${id:16:4}-${id:20:12}
    fi
}

# --- REGION: evidence_section
# Prints a titled section with at most evidence_section_bytes of what the
# command prints, so one large source cannot crowd the others out of the
# bundle.
evidence_section() {
    local title=$1
    shift
    printf '\n===== %s =====\n' "$title"
    "$@" 2>&1 | head -c "$evidence_section_bytes"
    printf '\n'
}

# --- REGION: evidence_summary
evidence_summary() {
    local boot_id=''
    read -r boot_id 2>/dev/null < /proc/sys/kernel/random/boot_id
    printf 'schema=yuruna.deep-diagnostics-boot/v1\n'
    printf 'generatedUtc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'host=%s\n' "$(uname -n)"
    printf 'kernel=%s\n' "$(uname -r)"
    printf 'bootId=%s\n' "${boot_id:-unavailable}"
    if [ -n "$evidence_boot_start" ]; then
        printf 'bootStartUtc=%s\n' "$(date -u -d "@$evidence_boot_start" +%Y-%m-%dT%H:%M:%SZ)"
    fi
    printf 'previousBootId=%s\n' "${evidence_previous_id:-unavailable}"
    if [ -n "$evidence_previous_last" ]; then
        printf 'previousBootLastEntryUtc=%s\n' "$(date -u -d "@$evidence_previous_last" +%Y-%m-%dT%H:%M:%SZ)"
    else
        printf 'previousBootLastEntryUtc=unavailable\n'
    fi
}

# --- REGION: evidence_vitals
# The previous boot's yuruna-vitals lines from its last ten minutes.
evidence_vitals() {
    if [ -n "$evidence_previous_last" ]; then
        journalctl -q -b -1 --since "@$((evidence_previous_last - 600))" --no-pager -o short-iso-precise | grep -F 'yuruna-vitals:'
    else
        journalctl -q -b -1 -n 5000 --no-pager -o short-iso-precise | grep -F 'yuruna-vitals:' | tail -n 60
    fi
}

# --- REGION: evidence_pstore
# Crash records: the ones systemd-pstore archived during this boot, and any
# still in the pstore file system. Older archives are listed by name only.
evidence_pstore() {
    local file found=0
    while IFS= read -r file; do
        found=1
        printf -- '--- %s\n' "$file"
        head -c 65536 -- "$file"
        printf '\n'
    done < <({
        if [ -n "$evidence_boot_start" ]; then
            find /var/lib/systemd/pstore -type f -newermt "@$evidence_boot_start" 2>/dev/null
        fi
        find /sys/fs/pstore -type f 2>/dev/null
    } | sort)
    [ "$found" = 1 ] || printf 'no pstore record from the previous boot\n'
    printf -- '--- archived records\n'
    find /var/lib/systemd/pstore -type f 2>/dev/null | sort | tail -n 100
}

# --- REGION: evidence_optional
# Runs a command only when it is installed, and says so when it is not.
evidence_optional() {
    if command -v "$1" >/dev/null 2>&1; then
        "$@"
    else
        printf '%s is not installed\n' "$1"
    fi
}

# --- REGION: evidence_kernel_warnings
evidence_kernel_warnings() {
    journalctl -q -b -1 -k -p warning --no-pager -o short-iso-precise | tail -n 400
}

# --- REGION: evidence_previous_watchdog
# The previous boot's systemd (PID 1) lines about the hardware watchdog, which
# tell whether the boot that ended had it armed. This boot's state, read when
# the bundle is written, comes before PID 1 opens the device in most boots.
# While PID 1 re-executes (which is how Enable arms the watchdog) or shuts
# down, it logs through /dev/kmsg, and the journal keeps those lines under
# SYSLOG_PID=1 with no _PID, so both matches are needed.
evidence_previous_watchdog() {
    journalctl -q -b -1 _PID=1 + SYSLOG_PID=1 --no-pager -o short-iso-precise | grep -i watchdog | tail -n 20
}

# --- REGION: evidence_boot_list
# The journal's last boots with their first and last entries, in UTC like the
# rest of the bundle, which date the restarts where 'last' is not installed
# (Ubuntu 26.04 ships without it).
evidence_boot_list() {
    journalctl -q --utc --list-boots --no-pager | tail -n 20
}

# --- REGION: evidence_hardware_errors
# This boot's kernel lines about hardware errors: firmware reports the errors
# of the boot that failed (BERT) during the next one. The match is broad on
# purpose and keeps the startup banners of the same subsystems ("AER: enabled
# with IRQ", "EDAC MC: Ver") as context; the section title says they are not
# errors.
evidence_hardware_errors() {
    journalctl -q -b 0 -k --no-pager -o short-iso-precise | grep -E 'BERT|Hardware Error|mce|MCE|EDAC|AER|watchdog' | tail -n 300
}

# --- REGION: evidence_collect
evidence_collect() {
    evidence_summary
    evidence_section 'previous boot: journal tail' journalctl -q -b -1 -n 300 --no-pager -o short-iso-precise
    evidence_section 'previous boot: kernel warnings and worse' evidence_kernel_warnings
    evidence_section 'previous boot: yuruna-vitals, last 10 minutes' evidence_vitals
    evidence_section 'previous boot: systemd (PID 1) watchdog lines' evidence_previous_watchdog
    evidence_section 'this boot: hardware error and watchdog kernel lines, startup banners included (a banner such as "AER: enabled" or "EDAC MC: Ver" is not an error)' evidence_hardware_errors
    evidence_section 'pstore' evidence_pstore
    evidence_section 'journalctl --list-boots, last 20' evidence_boot_list
    evidence_section 'last -x -F' evidence_optional last -x -F -n 40
    evidence_section 'ras-mc-ctl --summary' evidence_optional ras-mc-ctl --summary
    evidence_section 'ras-mc-ctl --errors' evidence_optional ras-mc-ctl --errors
    evidence_section 'wdctl' evidence_optional wdctl
    evidence_section 'this boot: systemd watchdog when this bundle was written, usually before PID 1 arms it' systemctl show -p WatchdogDevice -p RuntimeWatchdogUSec -p WatchdogLastPingTimestamp
}

# --- REGION: Main
evidence_out=''
if [ "${1:-}" = --output ]; then
    evidence_out=${2:-}
    if [ -z "$evidence_out" ]; then
        printf 'usage: %s [--output <file>]\n' "$0" >&2
        exit 2
    fi
fi
uptime_seconds=''
read -r uptime_seconds _ 2>/dev/null < /proc/uptime
if [[ ${uptime_seconds%.*} =~ ^[0-9]+$ ]]; then
    evidence_boot_start=$(($(date -u +%s) - ${uptime_seconds%.*}))
fi
if [ -z "$evidence_out" ]; then
    boot_id=''
    read -r boot_id 2>/dev/null < /proc/sys/kernel/random/boot_id
    [ -n "$boot_id" ] || exit 1
    install -d -m 0750 -o root -g systemd-journal "$evidence_dir" || exit 1
    evidence_out=$(evidence_target "$evidence_dir" "$boot_id" "$(date -u +%Y%m%dT%H%M%SZ)")
    [ -n "$evidence_out" ] || exit 0
fi
evidence_previous_boot
evidence_tmp=$(mktemp "$evidence_out.XXXXXX") || exit 1
evidence_collect | head -c "$evidence_max_bytes" > "$evidence_tmp"
if [ "$(stat -c %s "$evidence_tmp")" -ge "$evidence_max_bytes" ]; then
    printf '\n[bundle truncated at %s bytes]\n' "$evidence_max_bytes" >> "$evidence_tmp"
fi
chmod 0640 "$evidence_tmp"
if [ "$(id -u)" = 0 ]; then
    chgrp systemd-journal "$evidence_tmp"
fi
mv -f "$evidence_tmp" "$evidence_out"
