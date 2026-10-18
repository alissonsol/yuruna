#!/bin/bash
# Version: 2026.10.18.1
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Guest network helper for Ubuntu Server and Amazon Linux, deployed at
# /usr/local/lib/yuruna/yuruna-network.sh and shared by diagnostics and release.
# Probe the active network daemon; its presence alone does not establish ownership.
# --- REGION: Connectivity diagnosis
# See https://yuruna.link/4220a755-0010
# See https://yuruna.link/4220a755-0011
# Distinguish administratively down, carrier-down, and carrier-up/no-IPv4 links.
# Treat uncertain flags as carrier evidence, never as proof of a guest-side fault.
_yuruna_net_admin_down() {
    local f="$1"
    # See https://yuruna.link/4220a755-0011
    # Validate flags before arithmetic so malformed diagnostics cannot abort the report.
    case "$f" in
        '') return 1 ;;
        0x*)
            [ -n "${f#0x}" ] || return 1
            case "${f#0x}" in *[!0-9a-fA-F]*) return 1 ;; esac
            ;;
        *) case "$f" in *[!0-9]*) return 1 ;; esac ;;
    esac
    [ $(( f & 1 )) -eq 0 ]
}

# --- REGION: https://yuruna.link/4220a755-0011
# Use the same interface selection as network_diag without printing on every poll.
yuruna_has_ipv4() {
    local sysfs="${YURUNA_NET_SYSFS:-/sys/class/net}" ifc oper carrier
    for ifc in "$sysfs"/*; do
        ifc=$(basename "$ifc")
        [ -d "$sysfs/$ifc" ] || continue
        [ "$ifc" = "lo" ] && continue
        case "$ifc" in
            veth*|docker*|br-*|virbr*|cni*|flannel*|kube*|tap*|tun*) continue ;;
        esac
        oper=$(cat "$sysfs/$ifc/operstate" 2>/dev/null)
        carrier=$(cat "$sysfs/$ifc/carrier" 2>/dev/null)
        [ "$oper" != "up" ] && [ "$carrier" != "1" ] && continue
        if [ -n "$(ip -4 -o address show dev "$ifc" scope global 2>/dev/null)" ]; then
            return 0
        fi
    done
    return 1
}

# See https://yuruna.link/4220a755-000d
# Poll kernel IPv4 state across both network managers; return 1 when the budget expires.
yuruna_wait_ipv4() {
    local budget="${1:-120}" waited=0
    yuruna_has_ipv4 && return 0
    while [ "$waited" -lt "$budget" ]; do
        sleep 3
        waited=$((waited + 3))
        if yuruna_has_ipv4; then
            echo "   IPv4 address appeared after ${waited}s."
            return 0
        fi
    done
    return 1
}

# --- REGION: https://yuruna.link/4220a755-000d
# Keep bounded, ordered DHCP/address evidence and retry journal access without prompting.
_yuruna_net_journal_slice() {
    "$@" "${YURUNA_NET_JOURNAL:-journalctl}" -o short-precise --no-pager -n 200 \
        -u systemd-networkd -u NetworkManager 2>/dev/null |
        grep -iE 'dhcp|lease|carrier|address|not ready|could not set|refuse to configure|EEXIST' |
        sed -E 's/^([A-Za-z]{3}[ ]+[0-9]+[ ]+)?([0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]{3})[0-9]*[ ]+[^ ]+[ ]+[^:]+:[ ]/\2\3 /' |
        tail -7
}

# See https://yuruna.link/4220a755-000d
# Print a fixed-size client-state sample so the failure marker remains in the console frame.
_yuruna_net_client_state() {
    local ifc="$1" out=""
    [ -n "$ifc" ] || return 0
    echo "--- DHCP client state ($ifc) ---"
    if command -v networkctl >/dev/null 2>&1; then
        out=$(networkctl status --no-pager "$ifc" 2>/dev/null |
            grep -E '^ *(Network File|State|Online state|DHCP4 Client ID):' |
            sed 's/^ *//' | head -4)
    fi
    if [ -z "$out" ] && command -v nmcli >/dev/null 2>&1; then
        out=$(nmcli -t -f GENERAL.STATE,IP4.ADDRESS,DHCP4.OPTION device show "$ifc" 2>/dev/null | head -4)
    fi
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
    else
        echo "   (neither networkd nor NetworkManager answered for $ifc)"
    fi
    out=$(_yuruna_net_journal_slice)
    [ -z "$out" ] && out=$(_yuruna_net_journal_slice sudo -n)
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
    else
        echo "   (no DHCP line in the client journal, privileged or not)"
    fi
}

network_diag() {
    # See https://yuruna.link/4220a755-0011
    # Override sysfs only for fixtures; ip still reports the live address state.
    local sysfs="${YURUNA_NET_SYSFS:-/sys/class/net}"
    echo ""
    echo "==== NETWORK DIAGNOSTIC ===="
    echo "--- addresses ---"
    ip -br address 2>/dev/null || ip address 2>/dev/null
    # See https://yuruna.link/4220a755-0011
    # Show flags so administrative-down and carrier-loss verdicts can be checked.
    echo "--- links (flags) ---"
    ip -br link 2>/dev/null
    echo "--- routes (IPv4) ---"
    ip -4 route 2>/dev/null
    echo "--- routes (IPv6 default) ---"
    ip -6 route show default 2>/dev/null
    echo "--- DNS ---"
    grep -i '^nameserver' /etc/resolv.conf 2>/dev/null || echo "(no nameserver entries)"

    # See https://yuruna.link/4220a755-0011
    # Classify physical link states; bound named interfaces to the console frame.
    local addrless="" downlinks="" downcount=0 adminlinks="" admincount=0
    local examined=0 ifc oper carrier flags v4 v6
    # See https://yuruna.link/4220a755-0011
    # Probe one candidate; address-less links take precedence within the output budget.
    local probe_ifc="" probe_admin=""
    for ifc in "$sysfs"/*; do
        ifc=$(basename "$ifc")
        # An unmatched glob leaves the pattern itself as the only "entry".
        [ -d "$sysfs/$ifc" ] || continue
        [ "$ifc" = "lo" ] && continue
        case "$ifc" in
            veth*|docker*|br-*|virbr*|cni*|flannel*|kube*|tap*|tun*) continue ;;
        esac
        oper=$(cat "$sysfs/$ifc/operstate" 2>/dev/null)
        carrier=$(cat "$sysfs/$ifc/carrier" 2>/dev/null)
        flags=$(cat "$sysfs/$ifc/flags" 2>/dev/null)
        if [ "$oper" != "up" ] && [ "$carrier" != "1" ]; then
            if _yuruna_net_admin_down "$flags"; then
                admincount=$((admincount + 1))
                [ -z "$probe_admin" ] && probe_admin="$ifc"
                if [ "$admincount" -le 3 ]; then
                    adminlinks="$adminlinks $ifc(operstate=${oper:-unknown},flags=${flags:-unknown})"
                fi
            else
                downcount=$((downcount + 1))
                if [ "$downcount" -le 3 ]; then
                    downlinks="$downlinks $ifc(operstate=${oper:-unknown},carrier=${carrier:-none})"
                fi
            fi
            continue
        fi
        examined=$((examined + 1))
        v4=$(ip -4 -o address show dev "$ifc" scope global 2>/dev/null)
        v6=$(ip -6 -o address show dev "$ifc" scope global 2>/dev/null)
        if [ -z "$v4" ]; then
            if [ -n "$v6" ]; then
                echo "   $ifc: carrier up, has IPv6 (SLAAC) but NO IPv4 (no DHCP lease / no static)"
            else
                echo "   $ifc: carrier up, NO IPv4 and no global IPv6 (link-local may be above)"
            fi
            addrless="$addrless $ifc"
            [ -z "$probe_ifc" ] && probe_ifc="$ifc"
        fi
    done

    # See https://yuruna.link/4220a755-0011
    # Report both down states before lease theories; each can be a separate fault.
    if [ -n "$adminlinks" ]; then
        echo ""
        echo "!! DOWN INSIDE THIS GUEST on $admincount interface(s), first:$adminlinks"
        echo "!!   IFF_UP is clear, which only something on this machine can do,"
        echo "!!   so no switch, cable or DHCP server explains it. Two shapes:"
        echo "!!   1. NOTHING CLAIMED IT -- no profile matched this device. A"
        echo "!!      seeded network config resolving to no interface does this,"
        echo "!!      and it REPLACES the default rather than adding to it, so a"
        echo "!!      config matching nothing is worse than none. The client"
        echo "!!      state below reports n/a for a NIC nothing claimed."
        echo "!!   2. SOMETHING DOWNED IT and never restored it -- a lease"
        echo "!!      release, 'ip link set down', or 'nmcli networking off'"
        echo "!!      (persists in NetworkManager.state, outlives reboots)."
        echo "!!   DHCP is never attempted while down, so lease-pool causes do"
        echo "!!   not apply."
    fi
    if [ -n "$downlinks" ]; then
        echo ""
        echo "!! LINK DOWN on $downcount interface(s), first:$downlinks"
        echo "!!   No carrier, so DHCP is never attempted and lease-pool"
        echo "!!   questions do not apply. IFF_UP is set here, so the link is up"
        echo "!!   as far as this machine is concerned and the cause is outside"
        echo "!!   it: the virtual switch this vNIC attaches to has no live"
        echo "!!   uplink, the cable is out, or the switch port is disabled."
    fi
    if [ -z "$adminlinks" ] && [ -z "$downlinks" ]; then
        if [ -n "$addrless" ]; then
            echo ""
            echo "!! NO IPv4 ADDRESS on carrier-up interface(s):$addrless"
            echo "!!   Neither a static address nor a DHCP lease is present. The"
            echo "!!   link is up, so the fault is between here and the DHCP"
            echo "!!   server -- which cannot be seen from inside this guest."
            echo "!!   Ordered by how often each is the answer, NOT by certainty:"
            echo "!!   1. The lease has not landed YET: a lost DISCOVER backs the"
            echo "!!      client off while SLAAC keeps winning on its own RAs, so"
            echo "!!      IPv6-only for minutes is normal and is not a refusal."
            echo "!!   2. Request or reply not getting through: a bridge port not"
            echo "!!      forwarding, VLAN/cabling, or a DHCP server that is down."
            echo "!!   3. The server had no free lease -- not observable from here."
            echo "!!   4. ACKed and never installed: an acquired line in the client"
            echo "!!      state below, with no address here, is that shape."
        elif [ "$examined" -gt 0 ]; then
            echo ""
            echo "   All carrier-up interfaces hold an IPv4 address."
        else
            echo ""
            echo "   No non-loopback interface is carrier-up."
        fi
    fi
    _yuruna_net_client_state "${probe_ifc:-$probe_admin}"
    echo "==== END NETWORK DIAGNOSTIC ===="
    echo ""
}

# The IPv4 literal for one peer. A name is resolved under a bound, so a dead
# resolver cannot park the verdict below for the resolver's own retry ladder;
# a literal passes through. Empty output means the name got no answer.
_yuruna_net_addr_of() {
    case "$1" in
        '') return 1 ;;
        *[!0-9.]*)
            if command -v timeout >/dev/null 2>&1; then
                timeout 2 getent ahostsv4 "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'
            else
                getent ahostsv4 "$1" 2>/dev/null | awk 'NR == 1 { print $1 }'
            fi
            ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# One line naming what this guest can see of its own path to HOST:PORT, and
# status 0 only when a TCP connection succeeded. curl prints the same "could
# not connect" text for a refused port, a missing address, a missing route and
# an unanswered ARP, so the address, the route and the next hop's neighbor
# state are read here first, and only then does a bounded connect separate
# refused from unreachable from lost. Never more than one line, never longer
# than the connect bound plus the resolver bound.
yuruna_net_tcp_verdict() {
    local host="$1" port="${2:-5000}" addr="" route="" nexthop="" state="" err="" rc=0
    if [ -z "$host" ]; then
        echo "no peer address to test"
        return 1
    fi
    if ! yuruna_has_ipv4; then
        echo "no IPv4 address on this guest (the lease is gone or never landed)"
        return 1
    fi
    addr=$(_yuruna_net_addr_of "$host") || addr=""
    if [ -z "$addr" ]; then
        echo "the name $host does not resolve (DNS)"
        return 1
    fi
    if ! route=$(ip -4 route get "$addr" 2>/dev/null); then
        if [ -z "$(ip -4 route show default 2>/dev/null)" ]; then
            echo "no default route (and $host is not on a connected subnet)"
        else
            echo "no route to $host"
        fi
        return 1
    fi
    nexthop=$(printf '%s\n' "$route" | awk '{ for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit } }')
    [ -n "$nexthop" ] || nexthop="$addr"
    state=$(ip -4 neigh show to "$nexthop" 2>/dev/null | awk 'NR == 1 { print $NF }') || state=""
    case "$state" in
        FAILED|INCOMPLETE)
            echo "no ARP reply from $nexthop (neighbor $state)"
            return 1
            ;;
    esac
    # The bound is what makes a lost packet a verdict instead of a hang: the
    # kernel's own connect retry runs for minutes.
    if command -v timeout >/dev/null 2>&1; then
        err=$(timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$addr" "$port" 2>&1) && rc=0 || rc=$?
    else
        err=$(bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$addr" "$port" 2>&1) && rc=0 || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        echo "connected to $host:$port"
        return 0
    fi
    case "$rc:$err" in
        124:*|*"timed out"*)
            echo "connection to $host:$port timed out (packets lost between this guest and $host)"
            ;;
        *"Connection refused"*)
            echo "connection refused by $host:$port (host up, nothing listening)"
            ;;
        *"No route to host"*)
            # EHOSTUNREACH on a LAN is the ARP that went unanswered; the
            # connect just created the neighbor entry that records it.
            state=$(ip -4 neigh show to "$nexthop" 2>/dev/null | awk 'NR == 1 { print $NF }') || state=""
            case "$state" in
                FAILED|INCOMPLETE) echo "no ARP reply from $nexthop (neighbor $state)" ;;
                *) echo "no route to host $host (the kernel rejected the connect)" ;;
            esac
            ;;
        *"Network is unreachable"*)
            echo "no route to $host (network unreachable)"
            ;;
        *)
            echo "connect to $host:$port failed: ${err##*: }"
            ;;
    esac
    return 1
}

# A fixed-size view of this guest's own network state beside one peer, for
# the moment a script gives up on that peer. It is printed where the console
# frame the host reads back is about to end, so every field is capped: the
# line count never grows with the interface count, and the verdict line is
# last so the bounded tail the host keeps carries it.
yuruna_net_self_report() {
    local host="$1" port="${2:-5000}" sysfs="${YURUNA_NET_SYSFS:-/sys/class/net}"
    local ifc first="" count=0 line="" first_line="" second_line="" addr=""
    echo "==== THIS GUEST'S PATH TO ${host} ===="
    # Two address lines at most; any further NIC is a count on the second line,
    # so the block is the same height on a 2-NIC guest and a 30-NIC one.
    for ifc in "$sysfs"/*; do
        ifc=$(basename "$ifc")
        _yuruna_net_is_physical "$ifc" || continue
        count=$((count + 1))
        [ -n "$first" ] || first="$ifc"
        if [ "$count" -le 2 ]; then
            line=$(ip -4 -br address show dev "$ifc" 2>/dev/null | tr -s ' ') || line=""
            line="${line:-$ifc (no IPv4 address)}"
            if [ "$count" -eq 1 ]; then first_line="$line"; else second_line="$line"; fi
        fi
    done
    if [ "$count" -eq 0 ]; then
        echo "   address: no physical NIC in sysfs"
    else
        echo "   address: $first_line"
    fi
    if [ "$count" -gt 2 ]; then
        echo "   address: $second_line (+$((count - 2)) more physical NIC(s))"
    elif [ "$count" -eq 2 ]; then
        echo "   address: $second_line"
    fi
    line=$(ip -4 route show default 2>/dev/null | head -1) || line=""
    echo "   default route: ${line:-none}"
    addr=$(_yuruna_net_addr_of "$host") || addr=""
    if [ -n "$addr" ]; then
        line=$(ip -4 neigh show to "$addr" 2>/dev/null | head -1) || line=""
        echo "   neighbor: ${line:-no neighbor entry for $host}"
    else
        echo "   neighbor: $host did not resolve to an address"
    fi
    if [ -n "$first" ]; then
        echo "   link: $first operstate=$(cat "$sysfs/$first/operstate" 2>/dev/null || echo unknown) carrier=$(cat "$sysfs/$first/carrier" 2>/dev/null || echo none)"
    fi
    echo "   clock: $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown) uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null || echo unknown)s"
    echo "   verdict: $(yuruna_net_tcp_verdict "$host" "$port" 2>/dev/null || true)"
    echo "==== END OF THIS GUEST'S PATH ===="
}

# See https://yuruna.link/4220a755-0012
# Avoid sudo when already root, including while the shutdown authentication stack exits.
_yuruna_net_sudo() {
    if [ "$(id -u)" = "0" ]; then "$@"; else sudo "$@"; fi
}

# See https://yuruna.link/4220a755-0012
# Allow only physical NIC names with a sysfs device link; leave CNI devices alone.
_yuruna_net_is_physical() {
    local sysfs="${YURUNA_NET_SYSFS:-/sys/class/net}"
    case "$1" in
        en*|eth*|wl*) ;;
        *) return 1 ;;
    esac
    [ -e "$sysfs/$1/device" ]
}

# See https://yuruna.link/4220a755-000d
# Repair only address-less physical NICs without taking links down.
yuruna_net_repair_ipv4() {
    local sysfs="${YURUNA_NET_SYSFS:-/sys/class/net}" ifc waited
    local settle="${YURUNA_NET_RELOAD_SETTLE_SECONDS:-10}"
    if command -v networkctl >/dev/null 2>&1; then
        # See https://yuruna.link/4220a755-000d
        # Apply changed profiles before asking a NIC to reconfigure.
        _yuruna_net_sudo networkctl reload >/dev/null 2>&1 || true
        for ifc in "$sysfs"/*; do
            ifc=$(basename "$ifc")
            _yuruna_net_is_physical "$ifc" || continue
            # See https://yuruna.link/4220a755-000d
            # Let reload-triggered DHCP settle before reconfigure can restart that transaction.
            waited=0
            while [ "$waited" -lt "$settle" ] && \
                  [ -z "$(ip -4 -o address show dev "$ifc" scope global 2>/dev/null)" ]; do
                waited=$((waited + 1))
                sleep 1
            done
            if [ -n "$(ip -4 -o address show dev "$ifc" scope global 2>/dev/null)" ]; then
                if [ "$waited" -gt 0 ]; then
                    echo "   $ifc: address landed ${waited}s after the reload; no reconfigure needed"
                fi
                continue
            fi
            # See https://yuruna.link/4220a755-000d
            # Record client state before the nudge destroys that evidence.
            if command -v _yuruna_net_client_state >/dev/null 2>&1; then
                _yuruna_net_client_state "$ifc"
            fi
            if _yuruna_net_sudo networkctl reconfigure "$ifc" >/dev/null 2>&1; then
                echo "   networkctl reconfigure $ifc"
            fi
        done
    fi
    if command -v nmcli >/dev/null 2>&1 && \
       [ "$(nmcli -t -f RUNNING general 2>/dev/null)" = "running" ]; then
        for ifc in "$sysfs"/*; do
            ifc=$(basename "$ifc")
            _yuruna_net_is_physical "$ifc" || continue
            [ -n "$(ip -4 -o address show dev "$ifc" scope global 2>/dev/null)" ] && continue
            if _yuruna_net_sudo nmcli device connect "$ifc" >/dev/null 2>&1; then
                echo "   nmcli device connect $ifc"
            fi
        done
    fi
    return 0
}

# --- REGION: https://yuruna.link/4220a755-0012
# Return leases best-effort before guest teardown; skip unavailable clients.
network_release() {
    echo ""
    echo "==== NETWORK RELEASE ===="
    local released=0 ifc cname ctype cdev

    # systemd-networkd (Ubuntu Server): SendRelease defaults to yes, so
    # bringing a managed link down emits a DHCPRELEASE for its lease.
    if command -v networkctl >/dev/null 2>&1; then
        for ifc in "${YURUNA_NET_SYSFS:-/sys/class/net}"/*; do
            ifc=$(basename "$ifc")
            _yuruna_net_is_physical "$ifc" || continue
            if _yuruna_net_sudo networkctl down "$ifc" >/dev/null 2>&1; then
                echo "   networkctl down $ifc"
                released=1
            fi
        done
    fi
    # See https://yuruna.link/4220a755-0012
    # Enable per-connection DHCP release; never persist a global networking-off state.
    if command -v nmcli >/dev/null 2>&1 && \
       [ "$(nmcli -t -f RUNNING general 2>/dev/null)" = "running" ]; then
        # Process substitution, not a pipe: a `while` on the right of a pipe
        # runs in a subshell, where $released would be set and then discarded.
        while IFS=: read -r cname ctype cdev; do
            [ -n "$cname" ] || continue
            case "$ctype" in
                802-3-ethernet|ethernet|802-11-wireless|wifi|bridge|bond|vlan) : ;;
                *) continue ;;
            esac
            _yuruna_net_sudo nmcli connection modify "$cname" ipv4.dhcp-send-release yes >/dev/null 2>&1 || true
            if _yuruna_net_sudo nmcli connection down "$cname" >/dev/null 2>&1; then
                echo "   nmcli connection down $cname (device ${cdev:-unknown})"
                released=1
            fi
        done < <(nmcli -t -f NAME,TYPE,DEVICE connection show --active 2>/dev/null)
    fi
    # Classic dhclient stacks: explicit release of all held leases.
    if command -v dhclient >/dev/null 2>&1; then
        if _yuruna_net_sudo dhclient -r >/dev/null 2>&1; then echo "   dhclient -r"; released=1; fi
    fi
    # dhcpcd stacks.
    if command -v dhcpcd >/dev/null 2>&1; then
        if _yuruna_net_sudo dhcpcd -k >/dev/null 2>&1; then echo "   dhcpcd -k"; released=1; fi
    fi

    if [ "$released" = "1" ]; then
        echo "   DHCP lease(s) released."
    else
        echo "   No DHCP client release path available (nothing to do)."
    fi
    echo "==== END NETWORK RELEASE ===="
    echo ""
}

# --- REGION: https://yuruna.link/4220a755-0013
# Support both sourced helpers and direct console verbs.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        diag)    network_diag ;;
        release) network_release ;;
        repair)  yuruna_net_repair_ipv4 ;;
        *) echo "usage: $0 {diag|release|repair}" >&2; exit 2 ;;
    esac
fi
