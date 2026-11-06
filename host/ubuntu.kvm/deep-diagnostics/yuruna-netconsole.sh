#!/bin/bash
# Version: 2026.11.05
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
# GUID: 42c2a0b9-0c0c-4daf-85f4-2ae933afa367
#
# Points the kernel's netconsole at the receiver named in
# /etc/yuruna/deep-diagnostics/netconsole.conf, through configfs. Runs as root
# from yuruna-netconsole.service at boot and from the NetworkManager dispatcher
# hook when an address changes. A netconsole target sends from the source
# address and to the next-hop MAC address it was given when it was enabled, so
# a host that takes a new address at every boot and lease strands the target
# until this script runs again.
#
# Usage: yuruna-netconsole.sh apply
# Disable-DeepDiagnostics.ps1 removes the target with rmdir, which needs no
# script.

# --- REGION: Initialize environment
set -u
export LC_ALL=C
# A dispatcher hook inherits a minimal environment, and ip, ping and modprobe
# live in the sbin directories.
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
netconsole_conf=/etc/yuruna/deep-diagnostics/netconsole.conf
netconsole_dir=/sys/kernel/config/netconsole/yuruna

# --- REGION: netconsole_log
netconsole_log() {
    logger -t yuruna-netconsole -- "$*" 2>/dev/null
    printf 'yuruna-netconsole: %s\n' "$*" >&2
}

# --- REGION: netconsole_read_target
# Prints "address port" from a TARGET=<IPv4>[:port] line; the port defaults to
# 6666, the receiver's default.
netconsole_read_target() {
    local file=$1 line value='' address port=6666
    [ -r "$file" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
            TARGET=*) value=${line#TARGET=} ;;
        esac
    done < "$file"
    address=${value%%:*}
    [ "$value" = "$address" ] || port=${value#*:}
    [[ $address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    [[ $port =~ ^[0-9]{1,5}$ ]] || return 1
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    printf '%s %s\n' "$address" "$port"
}

# --- REGION: netconsole_route
# Prints "device source next-hop" for the route the kernel would use to reach
# the address. The next hop is the gateway for an address off this subnet,
# because that is whose MAC address the frames must carry.
netconsole_route() {
    local address=$1 dev='' src='' via='' i
    local -a words
    read -r -a words <<< "$(ip -4 -o route get "$address" 2>/dev/null)"
    for ((i = 0; i < ${#words[@]}; i++)); do
        case ${words[i]} in
            dev) dev=${words[i + 1]:-} ;;
            src) src=${words[i + 1]:-} ;;
            via) via=${words[i + 1]:-} ;;
        esac
    done
    if [ -z "$dev" ] || [ -z "$src" ]; then
        return 1
    fi
    printf '%s %s %s\n' "$dev" "$src" "${via:-$address}"
}

# --- REGION: netconsole_mac
# Prints the next hop's MAC address from the neighbor table. One ping first
# makes the kernel resolve it; a firewall that drops the echo still answers
# the address resolution, which is all this needs.
netconsole_mac() {
    local hop=$1 dev=$2 i
    local -a words
    ping -c 1 -W 1 -I "$dev" "$hop" >/dev/null 2>&1
    read -r -a words <<< "$(ip -4 neigh show "$hop" dev "$dev" 2>/dev/null)"
    for ((i = 0; i < ${#words[@]}; i++)); do
        if [ "${words[i]}" = lladdr ] && [ -n "${words[i + 1]:-}" ]; then
            printf '%s\n' "${words[i + 1]}"
            return 0
        fi
    done
    return 1
}

# --- REGION: netconsole_matches
# Whether the target directory already sends to these values. Re-applying an
# unchanged target would disable it for a moment, and the dispatcher hook runs
# on every interface event, including the ones each VM start raises.
netconsole_matches() {
    local dir=$1 dev=$2 local_ip=$3 remote_ip=$4 port=$5 mac=$6 name expected value
    for name in enabled dev_name local_ip remote_ip remote_port remote_mac; do
        case $name in
            enabled) expected=1 ;;
            dev_name) expected=$dev ;;
            local_ip) expected=$local_ip ;;
            remote_ip) expected=$remote_ip ;;
            remote_port) expected=$port ;;
            remote_mac) expected=$mac ;;
        esac
        value=''
        read -r value 2>/dev/null < "$dir/$name"
        [ "$value" = "$expected" ] || return 1
    done
}

# --- REGION: netconsole_configure
# Writes one target's settings into its configfs directory. The kernel refuses
# changes to an enabled target, so it is disabled first and enabled last.
# extended=1, where the kernel offers it, adds each record's level, sequence
# number and timestamp, which the receiver decodes.
netconsole_configure() {
    local dir=$1 dev=$2 local_ip=$3 remote_ip=$4 port=$5 mac=$6 value=''
    read -r value 2>/dev/null < "$dir/enabled"
    if [ "$value" = 1 ]; then
        echo 0 > "$dir/enabled" || return 1
    fi
    echo "$dev" > "$dir/dev_name" || return 1
    echo "$local_ip" > "$dir/local_ip" || return 1
    echo "$remote_ip" > "$dir/remote_ip" || return 1
    echo "$port" > "$dir/remote_port" || return 1
    echo "$mac" > "$dir/remote_mac" || return 1
    if [ -e "$dir/extended" ]; then
        echo 1 > "$dir/extended" || return 1
    fi
    echo 1 > "$dir/enabled"
}

# --- REGION: netconsole_apply
netconsole_apply() {
    local target route address port dev src hop mac
    target=$(netconsole_read_target "$netconsole_conf") || {
        netconsole_log "no valid TARGET=<IPv4>[:port] line in $netconsole_conf"
        return 1
    }
    read -r address port <<< "$target"
    route=$(netconsole_route "$address") || {
        netconsole_log "no IPv4 route to $address"
        return 1
    }
    read -r dev src hop <<< "$route"
    if ! mac=$(netconsole_mac "$hop" "$dev"); then
        if [ "$hop" != "$address" ]; then
            netconsole_log "gateway $hop did not resolve on $dev"
            return 1
        fi
        # On the same subnet, the broadcast address still reaches the receiver
        # once it is up; the next address event replaces it with its own MAC.
        mac=ff:ff:ff:ff:ff:ff
        netconsole_log "$address did not resolve on $dev; sending to the broadcast MAC address"
    fi
    if [ ! -d "${netconsole_dir%/*}" ]; then
        modprobe netconsole || return 1
    fi
    mkdir -p "$netconsole_dir" || return 1
    if netconsole_matches "$netconsole_dir" "$dev" "$src" "$address" "$port" "$mac"; then
        return 0
    fi
    if ! netconsole_configure "$netconsole_dir" "$dev" "$src" "$address" "$port" "$mac"; then
        netconsole_log "the kernel refused the target $address:$port on $dev"
        return 1
    fi
    netconsole_log "kernel messages go from $src on $dev to $address:$port through $mac"
}

# --- REGION: Main
case ${1:-} in
    apply) netconsole_apply ;;
    *)
        printf 'usage: %s apply\n' "$0" >&2
        exit 2
        ;;
esac
