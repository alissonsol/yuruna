# Windows 11 guest on macOS UTM host

Minimal commands. See [read.more.md](read.more.md) for the full
walk-through and [../../CODE.md](../../CODE.md) for cross-host concepts.

**Requirements**: macOS 12+, Apple Silicon (M1+), UTM v4.0+ — verified
by `New-VM.ps1`.

## One-time

From `yuruna/virtual/host.macos.utm/guest.windows.11` (do not `sudo`):

```bash
pwsh ./Get-Image.ps1
```

Downloads the Windows 11 ARM64 ISO and UTM Guest Tools (SPICE + VirtIO)
into `~/virtual/windows.env/`. For ISOs that can't be fetched
automatically, prints manual instructions — see
[read.more.md](read.more.md) for sources.

## For each VM

```bash
pwsh ./New-VM.ps1                   # default hostname
pwsh ./New-VM.ps1 -VMName myhost
```

Double-click `HOSTNAME.utm` in `~/Desktop/Yuruna.VDE/<machinename>/` to
import into UTM and start. When you see `Press any key to boot from CD
or DVD`, press one. Installer runs unattended (~15 min).

After install completes:

1. Stop the VM. In UTM → Drives, remove `HOSTNAME.iso` and `seed.iso`.
2. Add a USB CD drive for
   `~/virtual/windows.env/host.macos.utm.guest.windows.11.spice.iso`.
3. Start, open File Explorer → CD drive, run **UTM Guest Tools**
   (installs SPICE + VirtIO network driver — no network until now).
4. After the installer reboots: stop, remove the `spice.iso` drive,
   start.

> SPICE ISO must **not** be attached during the initial install — it
> carries its own `autounattend.xml` that interrupts unattended setup.

## Update

Auto-logon to `User` / `password` on first boot (forced change next
login). Elevated PowerShell:

```powershell
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/virtual/guest.windows.11/windows.11.update.ps1$nc" | iex
Restart-Computer
```

`$env:YurunaCacheContent` and equivalents: see
[../../../docs/caching.md](../../../docs/caching.md).

## Next

Install workloads: [Windows 11 guest](../../guest.windows.11/README.md).
Network options, memory, troubleshooting: [read.more.md](read.more.md).
