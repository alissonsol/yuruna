# Ubuntu Server guest on macOS UTM (with `ubuntu-desktop`)

Server-first sister of
[guest.ubuntu.desktop](../guest.ubuntu.desktop/). Boots the Ubuntu
**Server** 24.04 live ISO for autoinstall and adds `ubuntu-desktop`
during the same subiquity pass — first boot lands in GDM.

Use this when the Desktop ISO's `ubuntu-desktop-bootstrap` fails with
`E: Unable to locate package linux-generic[-hwe-24.04]`: the Server ISO
ships `linux-generic` on the cdrom plus a network-configured
`/etc/apt/sources.list.d/ubuntu.sources`; the Desktop ISO does not.

**Nested-virt requirements (Docker/KVM inside the VM)**: macOS 15+,
Apple **M3+**, UTM v4.6+ — verified by `New-VM.ps1`. Cross-host
concepts: [../../README.md](../../README.md).

## One-time

From `yuruna/host/macos.utm/guest.ubuntu.server` (do not `sudo`):

```bash
pwsh ./Get-Image.ps1
```

## For each VM

```bash
pwsh ./New-VM.ps1                   # default ubuntu-server01
pwsh ./New-VM.ps1 -VMName myhost
```

Double-click `HOSTNAME.utm` to import and start. Autoinstall is fully
unattended. **Install takes ~20–30 min** — subiquity fetches
`ubuntu-desktop` (~2 GB) through squid-cache; keep the
`guest.squid-cache` VM running for dramatically faster rebuilds.

Default `ubuntu` / `password`, change forced on first login.
