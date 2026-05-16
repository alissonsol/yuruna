# Ubuntu Server guest on macOS UTM

Boots the Ubuntu **Server** 24.04 live ISO for autoinstall. The Server
ISO ships `linux-generic` on the cdrom plus a network-configured
`/etc/apt/sources.list.d/ubuntu.sources`, so curtin's `install_kernel`
step always succeeds. First boot lands in a text-mode login.

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

Double-click `HOSTNAME.utm` in `~/yuruna/guest.nosync/` to import and
start. Autoinstall is fully unattended. Keep the `guest.squid-cache`
VM running for dramatically faster rebuilds.

Default user is `yuuser1` (override with `-Username`; the same name is
declared in
[test/sequences/gui/start.guest.ubuntu.server.yml](../../../test/sequences/gui/start.guest.ubuntu.server.yml)).
Initial password
is vault-managed (see
[test/extension/authentication/](../../../test/extension/authentication/))
and **expired** on first login so the test sequence's Current/New/Retype
rotation runs against the OS prompt.

Back to [macOS UTM](../README.md) · [Yuruna](../../../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
