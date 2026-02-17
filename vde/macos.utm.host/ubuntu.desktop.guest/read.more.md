# Ubuntu Desktop running in macOS UTM - Nerd-Level Details

Copyright (c) 2019-2026 by Alisson Sol et al.

## 1) Get all in!

What can you do during [The Long Dark Tea-Time of the Soul](https://en.wikipedia.org/wiki/The_Long_Dark_Tea-Time_of_the_Soul)?

This is the macOS counterpart of the [Hyper-V version](../../windows.hyper-v.host/ubuntu.desktop.guest/). It uses [UTM](https://mac.getutm.app/) to run an Ubuntu ARM64 VM on Apple Silicon Macs.

### 1.1) Installing UTM

[UTM](https://mac.getutm.app/) is a full-featured virtual machine host for macOS based on QEMU. Install it using [Homebrew](https://brew.sh/):

```bash
brew install --cask utm
```

The scripts in this folder use PowerShell. Install it with:

```bash
brew install powershell/tap/powershell
```

### 1.2) Downloading the Ubuntu image

The script [`Get-Image.ps1`](./Get-Image.ps1) fetches the Ubuntu Desktop 25.10 ARM64 ISO. The image is saved to `~/virtual/ubuntu.env/`.

```bash
pwsh ./Get-Image.ps1
```

## 2) Creating the VM

The script [`New-VM.ps1`](./New-VM.ps1) creates a UTM VM bundle on your Desktop. It accepts an optional `-VMName` parameter (default: `ubuntu-desktop01`) and:

- Copies the downloaded Ubuntu ISO into the bundle (named `<hostname>.iso`).
- Creates a 512GB blank qcow2 disk for installation.
- Generates an autoinstall `seed.iso` that automatically configures the Ubuntu installation with the given hostname.
- Generates a `config.plist` from [`config.plist.template`](./config.plist.template) for a QEMU ARM64 VM (4 CPUs, 8 GB RAM, VirtIO disk, UEFI boot, shared networking, sound, clipboard sharing).

```bash
pwsh ./New-VM.ps1
# Or with a custom hostname:
pwsh ./New-VM.ps1 -VMName myhostname
```

**Prerequisites:** `brew install openssl qemu` (for password hashing and disk image creation).

After the script completes, double-click `<hostname>.utm` on your Desktop to import it into UTM. Start the VM and the Ubuntu installer will run automatically via autoinstall.

- Default credentials: username `ubuntu`, password `password`. You will be required to change the password on first login.
- The autoinstall sets the hostname, locale (`en_US.UTF-8`), keyboard (`us`), LVM storage layout, and enables SSH.
- After installation, the VM boots from the hard disk by default (the disk drive is first in the UEFI boot order).
