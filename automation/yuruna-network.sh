#!/bin/bash
# Version: 2026.08.03
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Guest network helper. Sourced by fetch-and-execute.sh (for network_diag)
# and invoked by the `networkRelease` sequence action (for network_release).
# Targets Ubuntu Server and Amazon Linux 2023, which both ship `ip` and a
# systemd-networkd DHCP client. cloud-init deploys this file at
# /usr/local/lib/yuruna/yuruna-network.sh at install time.
#
# --- REGION: https://yuruna.link/network#defining-yuruna-network-lib

# --- REGION: https://yuruna.link/network#defining-network-diag
# Print a connectivity diagnostic for this machine. A carrier-up interface
# that holds no global IPv4 address has neither a static address nor a DHCP
# lease; on a bridged hypervisor the guest competes with every other LAN
# client for the router's finite lease pool, so a missing IPv4 lease points
# at DHCP pool exhaustion (a fast-booting guest that loses the lease race
# comes up with only an IPv6 SLAAC address and no IPv4). IPv6-via-RA needs no
# DHCP server, so its presence does not clear the flag.
#
# A link that is DOWN is a different fault and must not be reported as the
# lease-pool one: it never reaches DHCP at all, and the cause is outside this
# machine (the virtual switch the vNIC attaches to has no live uplink, the
# cable is out, or the port is administratively down). Reporting it as
# "carrier-up interfaces all hold an address" is vacuously true and sends the
# reader after the wrong subsystem, so the down state is a verdict of its own.
network_diag() {
    # Interface enumeration root. Overridable so a test can walk a fixture
    # tree; unset, it is the real sysfs path and behavior is identical. The
    # `ip` calls below are deliberately NOT redirected -- they report live
    # state and have no meaningful fixture form.
    local sysfs="${YURUNA_NET_SYSFS:-/sys/class/net}"
    echo ""
    echo "==== NETWORK DIAGNOSTIC ===="
    echo "--- addresses ---"
    ip -br address 2>/dev/null || ip address 2>/dev/null
    echo "--- routes (IPv4) ---"
    ip -4 route 2>/dev/null
    echo "--- routes (IPv6 default) ---"
    ip -6 route show default 2>/dev/null
    echo "--- DNS ---"
    grep -i '^nameserver' /etc/resolv.conf 2>/dev/null || echo "(no nameserver entries)"

    # Walk the real (non-loopback, non-virtual) interfaces; collect the ones
    # with no carrier, and the carrier-up ones holding no global IPv4 address.
    # Reading carrier on a down interface fails (EINVAL), so $carrier is empty
    # there rather than "0" -- hence the :-none default when it is named.
    # Only the first few down interfaces are named: this output is printed
    # immediately before the marker the host matches on a failing run, and the
    # capture surface holds a bounded number of trailing lines, so the report
    # has to stay a fixed size no matter how many interfaces exist.
    local addrless="" downlinks="" downcount=0 examined=0 ifc oper carrier v4 v6
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
        if [ "$oper" != "up" ] && [ "$carrier" != "1" ]; then
            downcount=$((downcount + 1))
            if [ "$downcount" -le 3 ]; then
                downlinks="$downlinks $ifc(operstate=${oper:-unknown},carrier=${carrier:-none})"
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
                echo "   $ifc: carrier up but NO IPv4 and NO IPv6 address"
            fi
            addrless="$addrless $ifc"
        fi
    done

    # Loudest true cause first: a down link explains everything below it, and a
    # lease-pool verdict printed over it would point at the wrong subsystem.
    if [ -n "$downlinks" ]; then
        echo ""
        echo "!! LINK DOWN on $downcount interface(s), first:$downlinks"
        echo "!!   No carrier, so DHCP is never attempted and lease-pool"
        echo "!!   questions do not apply. The cause is outside this machine:"
        echo "!!   the virtual switch this vNIC attaches to has no live uplink,"
        echo "!!   the cable is out, or the port is administratively down."
    elif [ -n "$addrless" ]; then
        echo ""
        echo "!! NO IPv4 ADDRESS on carrier-up interface(s):$addrless"
        echo "!!   Neither a static address nor a DHCP lease is present."
        echo "!!   DHCP POOL EXHAUSTION IS A POSSIBILITY -- the DHCP server may"
        echo "!!   have no free leases left to hand out. Other causes: the DHCP"
        echo "!!   server is down, a VLAN/cabling fault, or the link is not"
        echo "!!   forwarding yet."
    elif [ "$examined" -gt 0 ]; then
        echo ""
        echo "   All carrier-up interfaces hold an IPv4 address."
    else
        echo ""
        echo "   No non-loopback interface is carrier-up."
    fi
    echo "==== END NETWORK DIAGNOSTIC ===="
    echo ""
}

# --- REGION: https://yuruna.link/network#defining-network-release
# Release DHCP leases (and any other transient network resources) so the
# address returns to the pool immediately instead of lingering until lease
# expiry. Run at end-of-sequence teardown so a churning test fleet does not
# exhaust a shared LAN's DHCP pool. Best-effort across the DHCP clients a
# guest may run; a client that is not installed is simply skipped.
network_release() {
    echo ""
    echo "==== NETWORK RELEASE ===="
    local released=0 ifc

    # systemd-networkd (Ubuntu + Amazon Linux 2023): SendRelease defaults to
    # yes, so bringing a managed link down emits a DHCPRELEASE for its lease.
    if command -v networkctl >/dev/null 2>&1; then
        for ifc in /sys/class/net/*; do
            ifc=$(basename "$ifc")
            [ "$ifc" = "lo" ] && continue
            case "$ifc" in
                veth*|docker*|br-*|virbr*|cni*|flannel*|kube*|tap*|tun*) continue ;;
            esac
            if sudo networkctl down "$ifc" >/dev/null 2>&1; then
                echo "   networkctl down $ifc"
                released=1
            fi
        done
    fi
    # Classic dhclient stacks: explicit release of all held leases.
    if command -v dhclient >/dev/null 2>&1; then
        if sudo dhclient -r >/dev/null 2>&1; then echo "   dhclient -r"; released=1; fi
    fi
    # dhcpcd stacks.
    if command -v dhcpcd >/dev/null 2>&1; then
        if sudo dhcpcd -k >/dev/null 2>&1; then echo "   dhcpcd -k"; released=1; fi
    fi

    if [ "$released" = "1" ]; then
        echo "   DHCP lease(s) released."
    else
        echo "   No DHCP client release path available (nothing to do)."
    fi
    echo "==== END NETWORK RELEASE ===="
    echo ""
}

# --- REGION: https://yuruna.link/network#defining-yuruna-network-cli
# Dual-use: `source` this file to get the functions, or run it directly with
# a verb so the networkRelease sequence action can invoke it by path on the
# guest console (`bash /usr/local/lib/yuruna/yuruna-network.sh release`).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        diag)    network_diag ;;
        release) network_release ;;
        *) echo "usage: $0 {diag|release}" >&2; exit 2 ;;
    esac
fi
