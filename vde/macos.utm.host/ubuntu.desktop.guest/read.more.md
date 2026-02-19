# Ubuntu Desktop running in macOS UTM - Nerd-Level Details

Copyright (c) 2019-2026 by Alisson Sol et al.

## 1) Get all in!

What can you do during [The Long Dark Tea-Time of the Soul](https://en.wikipedia.org/wiki/The_Long_Dark_Tea-Time_of_the_Soul)?

This is the macOS counterpart of the [Hyper-V version](../../windows.hyper-v.host/ubuntu.desktop.guest/). It uses [UTM](https://mac.getutm.app/) with the Apple Virtualization framework to run an Ubuntu ARM64 VM on Apple Silicon Macs.

### Nested virtualization requirements

Docker Desktop inside the VM requires KVM (`/dev/kvm`), which depends on nested virtualization. This is only supported with:

| Requirement | Detail |
|---|---|
| **macOS** | 15.0 Sequoia or later |
| **Chip** | Apple M3, M4, or later (M1 and M2 are **not** supported) |
| **UTM** | v4.6.0 or later |
| **Backend** | Apple Virtualization (not QEMU) |

The `New-VM.ps1` script checks these requirements automatically and exits with an error if they are not met.

### 1.1) Installing UTM

[UTM](https://mac.getutm.app/) is a full-featured virtual machine host for macOS. Install it using [Homebrew](https://brew.sh/):

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
- Creates a 512GB blank raw disk for installation (Apple Virtualization requires raw format).
- Generates an autoinstall `seed.iso` that automatically configures the Ubuntu installation with the given hostname.
- Generates a `config.plist` from [`config.plist.template`](./config.plist.template) for an Apple Virtualization ARM64 VM (4 CPUs, 16 GB RAM, VirtIO disk, UEFI boot, shared networking, clipboard sharing, nested virtualization via GenericPlatform).

```bash
pwsh ./New-VM.ps1
# Or with a custom hostname:
pwsh ./New-VM.ps1 -VMName myhostname
```

**Prerequisites:** `brew install openssl qemu` (for password hashing and disk image creation).

After the script completes, double-click `<hostname>.utm` on your Desktop to import it into UTM. Start the VM and the Ubuntu installer will run automatically via autoinstall.

### 2.1) Changing memory allocation

The VM is created with 16 GB of RAM by default. To change the memory allocation:

- **For new VMs:** Edit the `New-VM.ps1` script and replace `16384` in the `__MEMORY_SIZE__` substitution with the desired value in megabytes (e.g., `32768` for 32 GB).
- **For existing VMs:** Open UTM, select the VM, click the settings icon, go to **System**, and change the **Memory** value to the desired amount.

- Default credentials: username `ubuntu`, password `password`. You will be required to change the password on first login.
- The autoinstall sets the hostname, locale (`en_US.UTF-8`), keyboard (`us`), LVM storage layout, and enables SSH.
- After installation, the VM boots from the hard disk by default (the disk drive is first in the UEFI boot order).
