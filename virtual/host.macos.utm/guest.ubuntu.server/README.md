# Ubuntu Server guest on macOS UTM host (with ubuntu-desktop)

Copyright (c) 2019-2026 by Alisson Sol et al.

Server-first sister of [guest.ubuntu.desktop](../guest.ubuntu.desktop/). Boots the Ubuntu **Server** 24.04 live ISO for autoinstall and adds `ubuntu-desktop` during the same subiquity pass, so the first boot lands in GDM.

Prefer this over `guest.ubuntu.desktop` when the Desktop ISO's `ubuntu-desktop-bootstrap` installer fails with `E: Unable to locate package linux-generic[-hwe-24.04]` — the Server ISO ships `linux-generic` on the cdrom and a network-configured `/etc/apt/sources.list.d/ubuntu.sources`, which the Desktop ISO does not.

**Nested virtualization requirements:** macOS 15 Sequoia or later, Apple M3+ chip, UTM v4.6+. The `New-VM.ps1` script checks these automatically.

## One-time setup

Do not run these scripts as root (`sudo`). Verify your identity with `whoami` first.

**On the macOS host: Getting the base image**

Assuming you are in the `yuruna/vde/host.macos.utm/guest.ubuntu.server` folder.

```bash
pwsh ./Get-Image.ps1
```

## For each VM

**On the macOS host (Terminal): Create VM**

```bash
pwsh ./New-VM.ps1
```

Or with a custom hostname (default: `ubuntu-server01`):

```bash
pwsh ./New-VM.ps1 -VMName myhostname
```

Double-click `HOSTNAME.utm` in `~/Desktop/Yuruna.VDE/<machinename>/` to import it into UTM and start the VM. The Ubuntu installer runs unattended via autoinstall (`interactive-sections: []`). **This step may take approximately 20-30 minutes** — subiquity fetches `ubuntu-desktop` (~2 GB) through squid-cache during the install. Keep the `guest.squid-cache` VM running to make this dramatically faster on rebuilds.

**On the VM (after setup): Updating**

You should be prompted to change the password on first login. The default user is `ubuntu` and the initial password is `password`.
