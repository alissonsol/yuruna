# Ubuntu Server 26.04 guest on macOS UTM host

> Common setup pattern: see [Guest Image Setup](../../../docs/guest-image-setup.md).
> This file documents only what's HOST/GUEST-specific.

Boots the Ubuntu **Server** 26.04 live ISO for autoinstall. The Server
ISO ships `linux-generic` on the cdrom plus a network-configured
`/etc/apt/sources.list.d/ubuntu.sources`, so curtin's `install_kernel`
step always succeeds. First boot lands in a text-mode login.

**Nested-virt requirements (Docker/KVM inside the VM)**: macOS 15+,
Apple **M3+**, UTM v4.6+ with the Apple Virtualization backend. This
guest runs on the QEMU+HVF backend, which does not expose nested
virtualization. These requirements are not checked by `New-VM.ps1`
(it validates only baseline compatibility — macOS 12+, any M-series,
UTM 4.0+); verify manually if nested virtualization is required.
Cross-host concepts: [Hosts — ...](../../README.md).

## One-time

From `yuruna/host/macos.utm/guest.ubuntu.server.26` (do not `sudo`):

```
pwsh ./Get-Image.ps1
```

## For each VM

```
pwsh ./New-VM.ps1                   # default ubuntu-server01
pwsh ./New-VM.ps1 -VMName myhost
```

Double-click `HOSTNAME.utm` in `~/yuruna/guest.nosync/` to import and
start. Autoinstall is fully unattended. Keep the `guest.caching-proxy`
VM running for dramatically faster rebuilds.

Default user is `yuuser26` (override with `-Username`; the same name is
declared in
[test/sequences/start.guest.ubuntu.server.26.yml](../../../test/sequences/start.guest.ubuntu.server.26.yml)).
Initial password
comes from the per-cycle authentication vault managed by the authentication extension at `test/extension/authentication/` and is **expired** on first login,
so the test sequence's Current/New/Retype rotation runs against the
OS prompt. See [Test Runner — Nerd-Level Details](../../../test/read.more.md) for the
vault model.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.22

Back to [Yuruna](../../../README.md)
