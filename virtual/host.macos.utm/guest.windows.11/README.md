# Windows 11 guest on macOS UTM host

Copyright (c) 2019-2026 by Alisson Sol et al.

Minimal commands for creating the VM. See [details](read.more.md) for full documentation.

**Requirements:** macOS 12 Monterey or later, Apple Silicon (M1 or later), UTM v4.0+. The `New-VM.ps1` script verifies these automatically.

## One-time setup

Do not run these scripts as root (`sudo`). Verify your identity with `whoami` first.

**On the macOS host: Getting the base image**

Assuming you are in the `yuruna/virtual/host.macos.utm/guest.windows.11` folder.

```bash
pwsh ./Get-Image.ps1
```

The script downloads both the Windows 11 ARM64 ISO and the UTM Guest Tools ISO (SPICE + VirtIO drivers) into `~/virtual/windows.env/`. It will provide manual download instructions for any image that cannot be downloaded automatically. See [details](read.more.md) for ISO sources.

## For each VM

**On the macOS host (Terminal): Create VM**

```bash
pwsh ./New-VM.ps1
```

Or with a custom hostname:

```bash
pwsh ./New-VM.ps1 -VMName myhostname
```

Double-click `HOSTNAME.utm` in `~/Desktop/Yuruna.VDE/<machinename>/` to import it into UTM and start the VM. When the VM first starts, **press any key** when you see `Press any key to boot from CD or DVD`. The Windows installer will then run automatically using the autounattend.xml answer file. **This step may take approximately 15 minutes.**

After Windows installation completes (~15 min):

1. Stop the VM. In UTM settings → **Drives**, remove `HOSTNAME.iso` and `seed.iso`.
2. Add a new USB CD drive pointing to `~/virtual/windows.env/host.macos.utm.guest.windows.11.spice.iso`.
3. Start the VM. Open File Explorer, navigate to the CD drive, and run the **UTM Guest Tools** installer (installs SPICE and the VirtIO network driver — network is unavailable until this step).
4. After the installer reboots the VM, stop it, remove the `spice.iso` drive in UTM settings, and start normally.

> **Note:** The SPICE ISO must not be attached during the initial Windows installation — it contains its own `autounattend.xml` that interrupts unattended setup. Attach it only after Windows is fully installed.

**On the VM (after setup): Updating**

You should be logged in automatically on first boot. The default user is `User` and the initial password is `password`. You will be prompted to change the password on the next login after the first boot. Open an elevated PowerShell terminal and run:

```powershell
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/virtual/guest.windows.11/windows.11.update.ps1$nc" | iex
```

> Set `$env:YurunaCacheContent` (in the guest) to a unique string — typically a
> datetime — when you want to bypass a caching proxy and force a fresh fetch.
> Leave it unset to let caches serve the stored copy. On the macOS host the
> equivalent is `export YurunaCacheContent=$(date +%Y%m%d%H%M%S)`.

Restart after updates complete.

```powershell
Restart-Computer
```

The Windows 11 guest is now ready!

## Next Steps

Proceed to the [Windows 11 guest](../../guest.windows.11/README.md) instructions to install workloads. See [details](read.more.md) for network options, memory, and troubleshooting.
