# Squid Cache VM (Ubuntu KVM)

Canonical documentation (setup, configuration, monitoring, credentials,
management): **[Caching](../../../docs/caching.md)**.
Test-harness wrappers (`Start-CachingProxy.ps1`,
`Test-CachingProxy.ps1`, `YURUNA_CACHING_PROXY_IP`):
**[Caching proxy — test-harness operator reference](../../../docs/caching-proxy.md)**.

Scripts and config in this folder:

- [Get-Image.ps1](Get-Image.ps1) — base Ubuntu Server cloud image
  (amd64 on x86_64, arm64 on aarch64, qcow2, resized to 512 GB sparse).
- [New-VM.ps1](New-VM.ps1) — defines the libvirt domain
  (12 GB RAM / 4 vCPU) and seeds via cloud-init. Dedicated cache box
  sized so squid's `cache_mem` can take 75 % of RAM.
- [host/vmconfig/caching-proxy.base.user-data](../../vmconfig/caching-proxy.base.user-data) — shared
  cloud-init base (+ per-host overlay): squid, Prometheus + Grafana + squid-exporter,
  qemu-guest-agent, snapshot-cache tuning, `offline_mode` flip after prewarm.
- [host/vmconfig/caching-proxy.meta-data](../../vmconfig/caching-proxy.meta-data) — shared
  cloud-init instance metadata.

## LAN-bridged network (recommended)

The cache VM is most useful when other hosts on the same LAN can point
their guests at it directly. New-VM.ps1 picks a libvirt network in this
order:

1. `$env:YURUNA_EXTERNAL_NETWORK` if set.
2. `yuruna-external` if defined.
3. `default` (NAT, 192.168.122.0/24, **host-only**).

### Automatic provisioning

`test/Start-CachingProxy.ps1` auto-creates `yuruna-external` for you.
On first invocation it:

1. Resolves the host's default-route NIC (refuses Wi-Fi).
2. Sweeps any half-built leftovers from previous attempts (stale
   NetworkManager profiles, a stale
   `/etc/netplan/99-yuruna-external.yaml`, a stale `yuruna-br0`
   device — each makes a fresh build fail in its own way).
3. Builds a Linux bridge (`yuruna-br0`) and moves the NIC onto it via
   NetworkManager (`nmcli`) or netplan — picked by which backend
   manages the NIC. The bridge clones the NIC's MAC, so the DHCP
   server normally re-issues the same IP the NIC held.
4. Verifies the NIC actually enslaved to the bridge before defining
   and starting the `yuruna-external` libvirt network pointing at it
   (autostart on). A bridge that never got its uplink is rolled back
   instead of being handed to libvirt.

The helper is idempotent — re-running `Start-CachingProxy.ps1` after
the bridge already exists is a no-op for host networking, and if the
bridge exists but lost its LAN uplink the helper heals it (or rebuilds
it from scratch). The bridge build does cause a brief network outage
(typically 1–5 s) while DHCP migrates the IP from the bare NIC onto
the bridge; SSH sessions over the NIC will reconnect once the lease
arrives.

Set `YURUNA_EXTERNAL_BRIDGE_SKIP=1` before `Start-CachingProxy.ps1` if
you intend to keep the cache VM host-only (libvirt's NAT `default`
network).

### Manual provisioning

If you'd rather build the bridge yourself, or the auto-create path
doesn't fit (custom routing, multi-NIC bond, VLAN trunk, etc.):

```
# 1. Build the bridge. Substitute eno1 for `ip -br link` output.
sudo nmcli connection add type bridge ifname yuruna-br0 con-name yuruna-br0 \
    bridge.stp no
sudo nmcli connection add type bridge-slave ifname eno1 master yuruna-br0
sudo nmcli connection up yuruna-br0

# 2. Define the libvirt network.
cat > /tmp/yuruna-external.xml <<'EOF'
<network>
  <name>yuruna-external</name>
  <forward mode="bridge"/>
  <bridge name="yuruna-br0"/>
</network>
EOF
sudo virsh net-define /tmp/yuruna-external.xml
sudo virsh net-autostart yuruna-external
sudo virsh net-start yuruna-external

# 3. Verify
sudo virsh net-list --all
# yuruna-external   active   yes   yes
```

### Rollback

If the bridge causes networking problems and you want to revert, run
ALL of the blocks below **in this order** — connectivity is restored
FIRST so an SSH session survives the teardown steps. A previous run may
have left artifacts from either backend; each command is a no-op when
its artifact is absent.

```
# 1. Restore the NIC's own connection BEFORE tearing anything down.
#    NOTE: the NIC's profile is usually NOT named after the device --
#    find the real name with `nmcli -f NAME,DEVICE connection show`
#    (e.g. "Wired connection 1", "netplan-eno1").
sudo nmcli device set eno1 managed yes                         # substitute your NIC
sudo nmcli connection modify '<nic-profile-name>' connection.autoconnect yes
sudo nmcli connection up '<nic-profile-name>'   # detaches the NIC from the bridge

# 2. Remove the libvirt network
sudo virsh net-destroy yuruna-external
sudo virsh net-undefine yuruna-external

# 3. Remove the bridge (NetworkManager path)
sudo nmcli connection delete yuruna-br0 yuruna-br0-slave-eno1  # substitute your NIC

# 4. Remove the bridge (netplan path)
sudo rm -f /etc/netplan/99-yuruna-external.yaml
sudo netplan apply

# 5. Remove a leftover bridge device (neither netplan apply nor deleting
#    NM profiles removes an already-created kernel device)
sudo ip link delete yuruna-br0
```

If the cache is created without the bridge in place, New-VM.ps1 falls
back to libvirt's NAT `default` network. The cache still works for
guests on the same host, but remote LAN clients can't reach it at its
libvirt IP without a host-side port forwarder (Start-CachingProxy.ps1
will set one up automatically for ports 80 / 3000 / 9302 / 9400 / 3128 /
3129).

**The multi-host pool dashboard requires the bridge.** On the NAT
fallback the forwarder is `systemd-socket-proxyd`, a userspace TCP proxy
that re-originates every connection from the host — so squid records a
single client IP (the NAT gateway `192.168.122.1`) for the whole LAN.
The pool-aggregator discovers hosts by their real client IP in squid's
log, so on NAT it discovers none and `…/d/yuruna-pool/yuruna-hosts`
shows "No data" no matter how many hosts point at the proxy. Bridging is
the only reliable fix (the macOS UTM and Hyper-V cache VMs are bridged,
which is why their pool dashboards populate); forwarding `:9400` exposes
the aggregator API but cannot recover the client IPs the forwarder
already erased.

## Cross-host state

The cache VM's `yuruna` password is persisted (so reboots and rebuilds
keep the same credentials) at
`test/status/runtime/yuruna-caching-proxy.yml` — the same file written
by the Hyper-V and macOS UTM caching-proxy hosts. This is host-agnostic
state managed by `test/modules/Test.CachingProxy.psm1`.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.17

Back to [Yuruna](../../../README.md)
