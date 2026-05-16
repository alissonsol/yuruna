# Ubuntu Server guest on Windows Hyper-V

Boots the Ubuntu **Server** 24.04 live ISO for autoinstall. The Server
ISO ships `linux-generic` on the cdrom plus a network-configured
`/etc/apt/sources.list.d/ubuntu.sources`, so curtin's `install_kernel`
step always succeeds. First boot lands in a text-mode login.

Cross-host concepts: [../../README.md](../../README.md).

## One-time

From `yuruna\host\windows.hyper-v\guest.ubuntu.server` in
elevated PowerShell:

```powershell
.\Get-Image.ps1
```

## For each VM

```powershell
.\New-VM.ps1                       # default ubuntu-server01
.\New-VM.ps1 -VMName myhost
```

Start from Hyper-V Manager. Autoinstall is fully unattended
(`interactive-sections: []`). Keep the `guest.squid-cache` VM running
for dramatically faster rebuilds.

Default user is `yuuser1` (override with `-Username`; the same name is
declared in
[test/sequences/gui/start.guest.ubuntu.server.yml](../../../test/sequences/gui/start.guest.ubuntu.server.yml)).
Initial password
comes from the per-cycle authentication vault under
`test/extension/authentication/` and is **expired** on first login,
so the test sequence's Current/New/Retype rotation runs against the
OS prompt. See [test/read.more.md](../../../test/read.more.md) for the
vault model. Remove the DVD drives so the VM boots from disk on next
start:

```powershell
Get-VMDvdDrive -VMName 'ubuntu-server01' | Remove-VMDvdDrive
```

Back to [Windows Hyper-V](../README.md) · [Yuruna](../../../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
