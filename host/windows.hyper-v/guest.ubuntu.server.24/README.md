# Ubuntu Server 24.04 guest on Windows Hyper-V host

> Common setup pattern: see [Guest Image Setup](../../../docs/guest-image-setup.md).
> This file documents only what's HOST/GUEST-specific.

Boots the Ubuntu **Server** 24.04 live ISO for autoinstall. The Server
ISO ships `linux-generic` on the cdrom plus a network-configured
`/etc/apt/sources.list.d/ubuntu.sources`, so curtin's `install_kernel`
step always succeeds. First boot lands in a text-mode login.

Cross-host concepts: [Hosts — ...](../../README.md).

## One-time

From `yuruna\host\windows.hyper-v\guest.ubuntu.server.24` in
elevated PowerShell:

```
.\Get-Image.ps1
```

## For each VM

```
.\New-VM.ps1                       # default ubuntu-server01
.\New-VM.ps1 -VMName myhost
```

Start from Hyper-V Manager. Autoinstall is fully unattended
(`interactive-sections: []`). Keep the `guest.caching-proxy` VM running
for dramatically faster rebuilds.

Default user is `yuuser24` (override with `-Username`; the same name is
declared in
[test/sequences/start.guest.ubuntu.server.24.yml](../../../test/sequences/start.guest.ubuntu.server.24.yml)).
Initial password
comes from the per-cycle authentication vault managed by the authentication extension at `test/extension/authentication/` and is **expired** on first login,
so the test sequence's Current/New/Retype rotation runs against the
OS prompt. See [Test Runner — Nerd-Level Details](../../../test/read.more.md) for the
vault model. Remove the DVD drives so the VM boots from disk on next
start:

```
Get-VMDvdDrive -VMName 'ubuntu-server01' | Remove-VMDvdDrive
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.22

Back to [Yuruna](../../../README.md)
