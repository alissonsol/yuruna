#!/bin/bash
# Version: 2026.08.20
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2019-2026 by Alisson Sol et al.
#
# Guest network helper. Sourced by fetch-and-execute.sh (for network_diag)
# and invoked by the `networkRelease` sequence action (for network_release).
# Targets Ubuntu Server and Amazon Linux 2023. Both ship `ip`, but which
# daemon owns the link is a per-image fact, not a per-family one: Ubuntu
# Server runs systemd-networkd behind netplan, and Amazon Linux 2023 images
# have shipped both networkd-managed and NetworkManager-managed builds.
# `networkctl` exists wherever systemd does, so its presence proves nothing
# about which daemon owns the link -- every path below has to be probed for,
# not inferred. cloud-init deploys this file at
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
# lease-pool one: it never reaches DHCP at all. Reporting it as "carrier-up
# interfaces all hold an address" is vacuously true and sends the reader after
# the wrong subsystem, so the down state is a verdict of its own.
#
# DOWN is itself two faults with opposite causes, and they must not share one
# verdict either. IFF_UP is set by whoever manages the link INSIDE this machine;
# carrier is driven by the far end. A link with IFF_UP clear cannot have been
# downed by a switch, a cable or a DHCP server, so naming those for it sends the
# reader to a machine that is not able to be at fault -- the expensive kind of
# wrong answer, because the host it accuses is usually healthy and provably so.
# Carrier alone cannot tell the two apart: reading carrier on a down interface
# fails (EINVAL), so the same empty value stands for "no carrier" and "could not
# ask", which is why the flags word has to be read as well.
# Phrased as POSITIVE PROOF that IFF_UP is clear, never as its negation. Every
# uncertain input -- empty, unparseable, or this helper not being defined at all
# (a non-zero "command not found" reads as false) -- therefore falls through to
# the carrier verdict, which is the one that does not accuse this machine. An
# uncertain flags word must not be what turns a link into a guest-side fault.
_yuruna_net_admin_down() {
    local f="$1"
    # Validate before any arithmetic: `$(( ))` on a malformed word is a shell
    # error, and this runs inside a diagnostic whose whole job is to still
    # produce output when everything else has gone wrong.
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

# --- REGION: https://yuruna.link/network#defining-network-diag
# Does any carrier-up interface hold a global IPv4 address right now?
#
# Same interface selection network_diag reports on, so the predicate and the
# report can never disagree about what "this guest has no IPv4" means. Kept
# separate from network_diag because a caller deciding whether to WAIT must be
# able to ask without printing a diagnostic on every poll.
yuruna_has_ipv4() {
    local sysfs=/sys/class/net ifc oper carrier
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

# Wait up to $1 seconds for an IPv4 address to appear. 0 = it is there (or
# arrived), 1 = the budget ran out without one.
#
# The wait exists because a lost DHCP DISCOVER puts the client into exponential
# backoff, so "no IPv4 at this instant" is routinely a lease that has not landed
# yet rather than one that never will. IPv6 is no evidence either way: SLAAC
# rides unsolicited router advertisements that keep repeating, so it comes up on
# its own schedule while DHCPv4 is still backing off.
#
# Polls rather than subscribing to netlink: this has to behave identically under
# systemd-networkd and NetworkManager, and the one thing both agree on is the
# address being visible in the kernel once it is assigned.
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
    # The flag list is the only place the two down states are visible to a
    # human: an admin-down link prints without UP, a carrier-loss link prints
    # <NO-CARRIER,...,UP>. Without this the verdict below cannot be checked by
    # the person reading the report.
    echo "--- links (flags) ---"
    ip -br link 2>/dev/null
    echo "--- routes (IPv4) ---"
    ip -4 route 2>/dev/null
    echo "--- routes (IPv6 default) ---"
    ip -6 route show default 2>/dev/null
    echo "--- DNS ---"
    grep -i '^nameserver' /etc/resolv.conf 2>/dev/null || echo "(no nameserver entries)"

    # Walk the real (non-loopback, non-virtual) interfaces; collect the ones
    # held down from inside, the ones with no carrier, and the carrier-up ones
    # holding no global IPv4 address.
    # Reading carrier on a down interface fails (EINVAL), so $carrier is empty
    # there rather than "0" -- hence the :-none default when it is named.
    # Only the first few of each are named: this output is printed
    # immediately before the marker the host matches on a failing run, and the
    # capture surface holds a bounded number of trailing lines, so the report
    # has to stay a fixed size no matter how many interfaces exist.
    local addrless="" downlinks="" downcount=0 adminlinks="" admincount=0
    local examined=0 ifc oper carrier flags v4 v6
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
                echo "   $ifc: carrier up but NO IPv4 and NO IPv6 address"
            fi
            addrless="$addrless $ifc"
        fi
    done

    # Loudest true cause first: a down link explains everything below it, and a
    # lease-pool verdict printed over it would point at the wrong subsystem.
    # Both down verdicts print when both are present -- they are separate
    # faults on separate interfaces, and suppressing one would hide a real
    # cause rather than shorten the report.
    if [ -n "$adminlinks" ]; then
        echo ""
        echo "!! DOWN INSIDE THIS GUEST on $admincount interface(s), first:$adminlinks"
        echo "!!   IFF_UP is clear, which only something on this machine can do,"
        echo "!!   so no switch, cable or DHCP server explains it. Two shapes:"
        echo "!!   1. NOTHING CLAIMED IT -- no profile matched this device. A"
        echo "!!      seeded network config resolving to no interface does this,"
        echo "!!      and it REPLACES the default rather than adding to it, so a"
        echo "!!      config matching nothing is worse than none. Check with"
        echo "!!      'nmcli device status' / 'networkctl status <if>'."
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
            echo "!!   1. The lease has not landed YET. A lost DISCOVER puts the"
            echo "!!      client into backoff, and SLAAC keeps succeeding on its"
            echo "!!      own repeating RAs, so IPv6-only for minutes is normal"
            echo "!!      here and is not evidence of a refusal. Ask the client:"
            echo "!!      'networkctl status <if>' or 'nmcli device show <if>'."
            echo "!!   2. The request or its reply is not getting through: a"
            echo "!!      bridge port not forwarding yet, VLAN/cabling, or a"
            echo "!!      DHCP server that is down."
            echo "!!   3. The server had no free lease. ONLY the DHCP server can"
            echo "!!      show this -- it is not observable from here. Read its"
            echo "!!      free-lease count before concluding it."
        elif [ "$examined" -gt 0 ]; then
            echo ""
            echo "   All carrier-up interfaces hold an IPv4 address."
        else
            echo ""
            echo "   No non-loopback interface is carrier-up."
        fi
    fi
    echo "==== END NETWORK DIAGNOSTIC ===="
    echo ""
}

# Elevate only when there is something to elevate from. The release also runs
# from a systemd shutdown unit, which is already root at a point where the
# authentication stack it would consult is being torn down: sudo there can fail
# on a machine where it works perfectly from a login shell, and the release is
# the last chance the address has to go back before the guest disappears.
_yuruna_net_sudo() {
    if [ "$(id -u)" = "0" ]; then "$@"; else sudo "$@"; fi
}

# Which interfaces a release may take down. An ALLOW-list, deliberately, where
# network_diag uses a deny-list -- the two have opposite safe defaults. The diag
# only reports, so an interface it does not recognize is worth naming. A release
# ACTS, so an interface it does not recognize must be left alone: the names a
# CNI invents are open-ended (cali<hex>, vxlan.calico, tunl0, cilium_host, lxc*,
# nodelocaldns, kube-ipvs0), and a deny-list that misses one tears down a
# cluster's data plane while trying to return a DHCP lease. Physical NIC names
# are the closed set, so name those instead.
#
# The prefix is necessary but not sufficient -- a virtual device can borrow it --
# so the kernel has to agree there is real hardware behind the name. Only a
# physical device gets a `device` link in sysfs; veth, bridge, dummy and CNI
# devices do not.
# Reads through the same YURUNA_NET_SYSFS seam network_diag walks, so the
# predicate a release depends on can be exercised against a fixture tree rather
# than only against whatever interfaces the machine running the suite happens
# to have. Unset, the path is the real one and behavior is identical.
_yuruna_net_is_physical() {
    local sysfs="${YURUNA_NET_SYSFS:-/sys/class/net}"
    case "$1" in
        en*|eth*|wl*) ;;
        *) return 1 ;;
    esac
    [ -e "$sysfs/$1/device" ]
}

# Re-kick IPv4 address acquisition without taking any link down. The two
# shapes that strand a guest IPv4-less both answer to the same nudge: a DHCP
# client deep in lost-DISCOVER backoff abandons the backoff and starts a fresh
# transaction, and a NIC that no profile claimed (IFF_UP clear, DHCP never
# attempted) gets claimed once its manager re-reads configuration that now
# matches it. Links are never downed here: a down that fails to pair with its
# up outlives the boot that issued it (see network_release's scoping), and
# nothing about re-asking for a lease needs one. Interfaces that already hold
# a global IPv4 are left untouched -- the repair is for the ones with nothing
# to lose, and re-kicking a healthy sibling would trade its live lease for a
# fresh transaction.
yuruna_net_repair_ipv4() {
    local sysfs="${YURUNA_NET_SYSFS:-/sys/class/net}" ifc
    if command -v networkctl >/dev/null 2>&1; then
        # Reload first, so a .network file or drop-in written after the daemon
        # started is in force before any link is asked to reconfigure
        # against it.
        _yuruna_net_sudo networkctl reload >/dev/null 2>&1 || true
        for ifc in "$sysfs"/*; do
            ifc=$(basename "$ifc")
            _yuruna_net_is_physical "$ifc" || continue
            [ -n "$(ip -4 -o address show dev "$ifc" scope global 2>/dev/null)" ] && continue
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

# --- REGION: https://yuruna.link/network#defining-network-release
# Release DHCP leases (and any other transient network resources) so the
# address returns to the pool immediately instead of lingering until lease
# expiry. Run at end-of-sequence teardown so a churning test fleet does not
# exhaust a shared LAN's DHCP pool. Best-effort across the DHCP clients a
# guest may run; a client that is not installed is simply skipped.
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
    # NetworkManager (where NM owns the link). The networkctl pass above
    # releases nothing on an NM-managed guest -- networkctl is present there
    # but owns no links -- so without this branch such a guest reaches the end
    # of this function having released nothing while reporting that there was
    # nothing to release -- the lease then sits until expiry, which is the
    # whole condition this function exists to avoid.
    #
    # Deactivation alone does not return the address: NM's dhcp-send-release
    # defaults to off, so ask for the release first, per connection. Scoped to
    # ACTIVE connections of link-carrying types, and never `nmcli networking
    # off` -- that flag lives in /var/lib/NetworkManager/NetworkManager.state
    # and would outlive this teardown and every reboot after it.
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

# --- REGION: https://yuruna.link/network#defining-yuruna-network-cli
# Dual-use: `source` this file to get the functions, or run it directly with
# a verb so the networkRelease sequence action can invoke it by path on the
# guest console (`bash /usr/local/lib/yuruna/yuruna-network.sh release`).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        diag)    network_diag ;;
        release) network_release ;;
        repair)  yuruna_net_repair_ipv4 ;;
        *) echo "usage: $0 {diag|release|repair}" >&2; exit 2 ;;
    esac
fi
