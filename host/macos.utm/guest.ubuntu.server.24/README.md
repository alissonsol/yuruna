# Ubuntu Server 24.04 guest on macOS UTM host

> Common setup pattern: see [Guest Image Setup](../../../docs/guest-image-setup.md).
> This file documents only what's HOST/GUEST-specific.

Boots the Ubuntu **Server** 24.04 live ISO for autoinstall. The Server
ISO ships `linux-generic` on the cdrom plus a network-configured
`/etc/apt/sources.list.d/ubuntu.sources`, so curtin's `install_kernel`
step always succeeds. The install ends by powering the VM off; the
next start boots the installed system to a text-mode login.

**Nested-virt requirements (Docker/KVM inside the VM)**: macOS 15+,
Apple **M3+**, UTM v4.6+. `New-VM.ps1` validates only baseline
compatibility (macOS 12+, any M-series, UTM 4.0+); the nested-virt
floor is not checked -- verify it separately before use.
Cross-host concepts: [Hosts -- ...](../../README.md).

## One-time

From `yuruna/host/macos.utm/guest.ubuntu.server.24` (do not `sudo`):

```
pwsh ./Get-Image.ps1
```

## For each VM

```
pwsh ./New-VM.ps1                   # default ubuntu-server01
pwsh ./New-VM.ps1 -VMName myhost
```

Double-click `HOSTNAME.utm` in `~/yuruna/guest.nosync/` to import and
start. Autoinstall is fully unattended. When the VM stops at the end of
the install, start it again; see
[Ubuntu installs end with a power-off and a cold start](../../../docs/host-macos.md#42885ada-0014).
Keep the `guest.caching-proxy-service` VM running for much faster
rebuilds.

Default user is `yuuser24` (override with `-Username`; the same name is
declared in
[test/sequences/start.guest.ubuntu.server.24.macos.utm.yml](../../../test/sequences/start.guest.ubuntu.server.24.macos.utm.yml),
the start sequence this host runs).
Initial password comes from the per-cycle vault of the authentication
extension (`test/extension/authentication/`) and is **expired** on
first login, so the test sequence's Current/New/Retype rotation runs
against the OS prompt. See
[Test Runner -- Nerd-Level Details](../../../test/read.more.md) for the
vault model.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.11.05

Back to [Yuruna](../../../README.md)
