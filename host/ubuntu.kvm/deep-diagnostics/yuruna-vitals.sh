#!/bin/bash
# Version: 2026.11.05
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42834dc8-8fdf-4964-97e0-30c4bf519e54
#
# Writes one compact line of host vitals into the kernel log every 10 seconds,
# at KERN_NOTICE, so it lands in the journal and, with kernel.printk at 6, on
# netconsole as well. A hard freeze leaves nothing behind locally, and the
# last lines before it show what the host was doing: load, memory and I/O
# pressure, dirty pages, temperatures, fan speeds and how many VMs ran.
# Each sample reads /proc and /sys with shell builtins and starts two short
# processes, so the cost is negligible.
#
# Usage: yuruna-vitals.sh [--once]
#   --once prints one line to standard output and exits.

# --- REGION: Initialize environment
set -u
export LC_ALL=C
# A sensor directory without temperature or fan inputs is the common case, and
# an unmatched pattern must expand to nothing rather than to itself.
shopt -s nullglob
vitals_interval=10
vitals_max_fans=8

# --- REGION: vitals_meminfo
# MemAvailable, SwapFree, Dirty and Writeback, in MiB.
vitals_meminfo() {
    local file=$1 key value avail='?' swap='?' dirty='?' writeback='?'
    while read -r key value _; do
        case $key in
            MemAvailable:) avail=$((value / 1024)) ;;
            SwapFree:) swap=$((value / 1024)) ;;
            Dirty:) dirty=$((value / 1024)) ;;
            Writeback:) writeback=$((value / 1024)) ;;
        esac
    done < "$file"
    printf 'mem=%sM swap=%sM dirty=%sM wb=%sM' "$avail" "$swap" "$dirty" "$writeback"
}

# --- REGION: vitals_pressure
# The "some avg10" figure for cpu, memory and io, when the kernel has PSI.
vitals_pressure() {
    local root=$1 kind line out=''
    [ -d "$root" ] || return 0
    for kind in cpu memory io; do
        line=''
        read -r line 2>/dev/null < "$root/$kind"
        line=${line#*avg10=}
        line=${line%% *}
        out+="${out:+,}${kind:0:3}:${line:-?}"
    done
    printf ' psi=%s' "$out"
}

# --- REGION: vitals_hwmon
# CPU package and hottest core temperature (coretemp on Intel, k10temp on
# AMD), the hottest NVMe composite temperature and the fan speeds, in whole
# degrees Celsius and RPM.
vitals_hwmon() {
    local root=$1 dir name input label value package='' core='' nvme='' fans='' count=0
    for dir in "$root"/hwmon*; do
        name=''
        read -r name 2>/dev/null < "$dir/name" || continue
        case $name in
            coretemp | k10temp | nvme) ;;
            *) name='' ;;
        esac
        for input in "$dir"/temp*_input; do
            if [ -z "$name" ] || [ ! -r "$input" ]; then
                continue
            fi
            value=''
            label=''
            read -r value 2>/dev/null < "$input"
            [[ $value =~ ^-?[0-9]+$ ]] || continue
            value=$((value / 1000))
            read -r label 2>/dev/null < "${input%_input}_label"
            case $name:$label in
                nvme:Composite)
                    if [ -z "$nvme" ] || [ "$value" -gt "$nvme" ]; then nvme=$value; fi ;;
                nvme:*) ;;
                *:'Package id'* | *:Tctl | *:Tdie)
                    if [ -z "$package" ] || [ "$value" -gt "$package" ]; then package=$value; fi ;;
                *)
                    if [ -z "$core" ] || [ "$value" -gt "$core" ]; then core=$value; fi ;;
            esac
        done
        for input in "$dir"/fan*_input; do
            [ "$count" -lt "$vitals_max_fans" ] || break
            value=''
            read -r value 2>/dev/null < "$input"
            [[ $value =~ ^[0-9]+$ ]] || continue
            fans+="${fans:+,}$value"
            count=$((count + 1))
        done
    done
    printf ' cpu=%s/%sC nvme=%sC fans=%s' "${package:-?}" "${core:-?}" "${nvme:-?}" "${fans:--}"
}

# --- REGION: vitals_line
vitals_line() {
    local load1='?' load5='?' load15='?' qemu
    read -r load1 load5 load15 _ < /proc/loadavg
    qemu=$(pgrep -c '^qemu' 2>/dev/null) || qemu=0
    printf 'yuruna-vitals: load=%s,%s,%s %s%s%s qemu=%s' "$load1" "$load5" "$load15" \
        "$(vitals_meminfo /proc/meminfo)" "$(vitals_pressure /proc/pressure)" "$(vitals_hwmon /sys/class/hwmon)" "$qemu"
}

# --- REGION: Main
if [ "${1:-}" = --once ]; then
    printf '%s\n' "$(vitals_line)"
    exit 0
fi
# One open descriptor, one write per line: /dev/kmsg turns each write into one
# kernel log record.
exec 3> /dev/kmsg || exit 1
while :; do
    printf '<5>%s\n' "$(vitals_line)" >&3
    sleep "$vitals_interval"
done
