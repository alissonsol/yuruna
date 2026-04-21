# Windows 11 guest on Windows Hyper-V host

Copyright (c) 2019-2026 by Alisson Sol et al.

Minimal commands for creating the VM. See [details](read.more.md) for full documentation.

## One-time setup

**On the Windows host (Administrator PowerShell): Getting the base image**

From the `yuruna\vde\host.windows.hyper-v\guest.windows.11` folder:

```powershell
.\Get-Image.ps1
```

The script automates the Windows 11 ISO download from [Microsoft](https://www.microsoft.com/software-download/windows11). It may fail due to network and automation filters set by Microsoft, and it will then present instructions to perform the steps manually.

## For each VM

**On the Windows host (Administrator PowerShell): Create VM**

```powershell
.\New-VM.ps1
```

Or with a custom hostname:

```powershell
.\New-VM.ps1 -VMName myhostname
```

Start the VM from Hyper-V Manager. The Windows installer will run automatically using the autounattend.xml answer file. **This step may take approximately 15 minutes.** The installation is fully unattended.

**On the VM (after setup): Updating**

You should be logged in automatically on first boot. The default user is `User` and the initial password is `password`. You will be prompted to change the password on the next login after the first boot. Open an elevated PowerShell terminal and run:

```powershell
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/guest.windows.11/windows.11.update.ps1$nc" | iex
```

> Set `$env:YurunaCacheContent` (or `setx YurunaCacheContent ...`) to a unique
> string — typically a datetime — when you want to bypass a caching proxy and
> force a fresh fetch. Leave it unset to let caches serve the stored copy. See
> [docs/caching.md](../../../docs/caching.md) for details.

Restart after updates complete.

```powershell
Restart-Computer
```

The Windows 11 guest is now ready!

## Next Steps

Proceed to the [Windows 11 guest](../../guest.windows.11/README.md) instructions to install workloads.

Read more [here](read.more.md) about the VM creation process details.
