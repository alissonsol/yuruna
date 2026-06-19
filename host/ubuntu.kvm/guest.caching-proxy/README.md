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
2. Builds a Linux bridge (`yuruna-br0`) and moves the NIC onto it via
   NetworkManager (`nmcli`) or netplan, whichever is active on the host.
3. Defines and starts the `yuruna-external` libvirt network pointing at
   that bridge, and sets autostart.

The helper is idempotent — re-running `Start-CachingProxy.ps1` after
the bridge already exists is a no-op for host networking. The bridge
build does cause a brief network outage (typically 1–5 s) while DHCP
migrates the IP from the bare NIC onto the bridge; SSH sessions over
the NIC will reconnect once the lease arrives.

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

If the bridge causes networking problems and you want to revert:

```
# Remove the libvirt network
sudo virsh net-destroy yuruna-external
sudo virsh net-undefine yuruna-external

# Remove the bridge (NetworkManager path)
sudo nmcli connection delete yuruna-br0
sudo nmcli connection delete yuruna-br0-slave-eno1   # substitute your NIC
sudo nmcli connection modify eno1 connection.autoconnect yes
sudo nmcli connection up eno1

# Remove the bridge (netplan path)
sudo rm /etc/netplan/99-yuruna-external.yaml
sudo netplan apply
```

If the cache is created without the bridge in place, New-VM.ps1 falls
back to libvirt's NAT `default` network. The cache still works for
guests on the same host, but remote LAN clients can't reach it at its
libvirt IP without a host-side port forwarder (Start-CachingProxy.ps1
will set one up automatically for ports 80 / 3000 / 9302 / 3128 /
3129).

## Cross-host state

The cache VM's `yuruna` password is persisted (so reboots and rebuilds
keep the same credentials) at
`test/status/runtime/yuruna-caching-proxy.yml` — the same file written
by the Hyper-V and macOS UTM caching-proxy hosts. This is host-agnostic
state managed by `test/modules/Test.CachingProxy.psm1`.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.19

Back to [Yuruna](../../../README.md)
