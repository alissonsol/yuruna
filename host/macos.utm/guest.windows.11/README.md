# Windows 11 guest on macOS UTM host

> Common setup pattern: see [Guest Image Setup](../../../docs/guest-image-setup.md).
> This file documents only what's HOST/GUEST-specific.

Minimal commands. Walk-through: [Windows 11 guest on macOS UTM host — Nerd-Level Details](read.more.md). Cross-host
concepts: [Hosts — ...](../../README.md).

**Requirements**: macOS 12+, Apple Silicon (M1+), UTM v4.0+ — verified
by `New-VM.ps1`.

## One-time

From `yuruna/host/macos.utm/guest.windows.11` (do not `sudo`):

```
pwsh ./Get-Image.ps1
```

Downloads the Windows 11 ARM64 ISO and UTM Guest Tools (SPICE + VirtIO)
into `~/yuruna/image/windows.env/`. Prints manual instructions for ISOs that
can't be fetched automatically — see [Windows 11 guest on macOS UTM host — Nerd-Level Details](read.more.md).

## For each VM

```
pwsh ./New-VM.ps1                   # default hostname
pwsh ./New-VM.ps1 -VMName myhost
```

Double-click `HOSTNAME.utm` in `~/yuruna/guest.nosync/` to
import and start. At `Press any key to boot from CD or DVD`, press one.
Installer runs unattended (~15 min).

After install:

1. Stop the VM. In UTM → Drives, remove `HOSTNAME.iso` and `seed.iso`.
2. Add a USB CD drive for
   `~/yuruna/image/windows.env/host.macos.utm.guest.windows.11.spice.iso`.
3. Start, open File Explorer → CD, run **UTM Guest Tools** (SPICE +
   VirtIO network — no network before now).
4. After reboot: stop, remove the `spice.iso` drive, start.

> SPICE ISO must **not** be attached during the initial install — its
> own `autounattend.xml` interrupts unattended setup.

## Update

Auto-logon to `ywuser1` / `password` on first boot (change forced next
login). Elevated PowerShell:

```
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/guest/windows.11/windows.11.update.ps1$nc" | iex
Restart-Computer
```

`$env:YurunaCacheContent`: see
[Caching](../../../docs/caching.md).

## Next

[Windows 11 workloads](../../../guest/windows.11/README.md)

Read more: [Windows 11 guest on macOS UTM host — Nerd-Level Details](read.more.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.22

Back to [Yuruna](../../../README.md)
