# Ubuntu Desktop running in Windows Hyper-V - Nerd-Level Details

Copyright (c) 2019-2026 by Alisson Sol et al.

## 1) Get all in!

What can you do during [The Long Dark Tea-Time of the Soul](https://en.wikipedia.org/wiki/The_Long_Dark_Tea-Time_of_the_Soul)?

This is the Windows Hyper-V counterpart of the [macOS UTM version](../../macos.utm.host/ubuntu.desktop.guest/). It uses [Hyper-V](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/) to run an Ubuntu Desktop VM on Windows.

### 1.1) Prerequisites

**Hyper-V** must be enabled. In an elevated PowerShell:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
```

Restart Windows after enabling Hyper-V.

**Windows ADK Deployment Tools** are required for `Oscdimg.exe` (used to create the cloud-init seed ISO). Download and install from [Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install). During installation, select only "Deployment Tools".

### 1.2) Downloading the Ubuntu image

The script [`Get-Image.ps1`](./Get-Image.ps1) fetches the Ubuntu Desktop amd64 ISO. The image is saved to the Hyper-V default virtual hard disk path.

```powershell
.\Get-Image.ps1
```

## 2) Creating the VM

The script [`New-VM.ps1`](./New-VM.ps1) creates a Hyper-V Generation 2 VM. It accepts an optional `-VMName` parameter (default: `ubuntu-desktop01`) and:

- Creates a 512GB dynamically expanding VHDX for installation.
- Generates an autoinstall `seed.iso` that automatically configures the Ubuntu installation with the given hostname.
- Creates a Generation 2 Hyper-V VM (8 GB RAM, half of host CPU cores, UEFI boot, Secure Boot off, Default Switch networking).
- Mounts the Ubuntu ISO and seed ISO as DVD drives.
- Sets the DVD drive as the first boot device for installation.

```powershell
.\New-VM.ps1
# Or with a custom hostname:
.\New-VM.ps1 -VMName myhostname
```

After the script completes, start the VM from Hyper-V Manager. The Ubuntu installer will run automatically via autoinstall.

- Default credentials: username `ubuntu`, password `password`. You will be required to change the password on first login.
- The autoinstall sets the hostname, locale (`en_US.UTF-8`), keyboard (`us`), LVM storage layout, and enables SSH.

### 2.1) Testing connectivity

Once the VM is running, you can find its IP address:

```powershell
Get-VM -Name "ubuntu-desktop01" | Select-Object -ExpandProperty NetworkAdapters | Select-Object IPAddresses
```

Then SSH into the VM:

```powershell
ssh ubuntu@<ip-address>
```

## 3) Known limitations

- Ubuntu Desktop autoinstall may take approximately 15 minutes depending on hardware.
- The screen may appear blank during installation. Wait for the installation to complete.
- After installation, DVD drives must be manually removed to prevent booting into the installer again.
- Enhanced Session Mode (xrdp) is not configured by default. You can install it manually for better remote desktop experience.
