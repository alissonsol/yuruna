# Ubuntu Server guest on Windows Hyper-V host (with ubuntu-desktop)

Copyright (c) 2019-2026 by Alisson Sol et al.

Server-first sister of [guest.ubuntu.desktop](../guest.ubuntu.desktop/). Boots the Ubuntu **Server** 24.04 live ISO for autoinstall and adds `ubuntu-desktop` during the same subiquity pass, so the first boot lands in GDM.

Prefer this over `guest.ubuntu.desktop` when the Desktop ISO's `ubuntu-desktop-bootstrap` installer fails with `E: Unable to locate package linux-generic[-hwe-24.04]` — the Server ISO ships `linux-generic` on the cdrom and a network-configured `/etc/apt/sources.list.d/ubuntu.sources`, which the Desktop ISO does not.

## One-time setup

**On the Windows host (Administrator PowerShell): Getting the base image**

Assuming you are in the `yuruna\virtual\host.windows.hyper-v\guest.ubuntu.server` folder.

```powershell
.\Get-Image.ps1
```

## For each VM

**On the Windows host (Administrator PowerShell): Create VM**

```powershell
.\New-VM.ps1
```

Or with a custom hostname (default: `ubuntu-server01`):

```powershell
.\New-VM.ps1 -VMName myhostname
```

Start the VM from Hyper-V Manager. The Ubuntu installer runs unattended via autoinstall (`interactive-sections: []`) — no "Install" button to click. **This step may take approximately 20-30 minutes** — subiquity fetches `ubuntu-desktop` (~2 GB) through squid-cache during the install. Keep the `guest.squid-cache` VM running to make this dramatically faster on rebuilds.

**On the VM (after setup): Updating**

The default user is `ubuntu` and the initial password is `password`. Autoinstall expires the password, so you will be forced to change it on first interactive login; you can also change it later with `passwd`.

After installation completes, remove the DVD drives so the VM boots from disk on next start:

```powershell
Get-VMDvdDrive -VMName 'ubuntu-server01' | Remove-VMDvdDrive
```
