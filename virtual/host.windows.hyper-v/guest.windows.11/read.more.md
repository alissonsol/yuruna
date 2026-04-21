# Windows 11 guest on Windows Hyper-V host - Nerd-Level Details

Copyright (c) 2019-2026 by Alisson Sol et al.

## 1) Get all in!

What can you do during [The Long Dark Tea-Time of the Soul](https://en.wikipedia.org/wiki/The_Long_Dark_Tea-Time_of_the_Soul)?

This is the Windows 11 counterpart of the [Ubuntu Desktop](../guest.ubuntu.desktop/) and [Amazon Linux](../guest.amazon.linux/) guests. It uses [Hyper-V](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/) to run a Windows 11 VM on a Windows host.

### 1.1) Prerequisites

**Hyper-V** must be enabled. In an elevated PowerShell:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
```

Restart Windows after enabling Hyper-V.

**Windows ADK Deployment Tools** are required for `Oscdimg.exe` (used to create the autounattend seed ISO). Download and install from [Windows ADK](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install). During installation, select only "Deployment Tools".

### 1.2) Downloading the Windows 11 image

Unlike Ubuntu, the Windows 11 ISO cannot be downloaded via direct URL. The script [`Get-Image.ps1`](./Get-Image.ps1) provides instructions for downloading the ISO from [Microsoft](https://www.microsoft.com/software-download/windows11) and placing it in the Hyper-V default virtual hard disk path.

```powershell
.\Get-Image.ps1
```

If a file matching `Win11*.iso` is found in the Hyper-V VHDX folder, it will be renamed automatically.

## 2) Creating the VM

The script [`New-VM.ps1`](./New-VM.ps1) creates a Hyper-V Generation 2 VM. It accepts an optional `-VMName` parameter (default: `windows11-01`) and:

- Creates a 512GB dynamically expanding VHDX for installation.
- Generates an `autounattend.xml` seed ISO that automatically configures the Windows installation with the given hostname.
- Creates a Generation 2 Hyper-V VM (16 GB RAM, half of host CPU cores, UEFI boot, Secure Boot with Microsoft Windows template, Default Switch networking).
- Adds a virtual TPM (required for Windows 11).
- Mounts the Windows ISO and seed ISO as DVD drives.
- Sets the DVD drive as the first boot device for installation.
- Enables the Guest Service Interface for Hyper-V integration.

```powershell
.\New-VM.ps1
# Or with a custom hostname:
.\New-VM.ps1 -VMName myhostname
```

After the script completes, start the VM from Hyper-V Manager. The Windows installer will run automatically via the autounattend.xml answer file.

- Default credentials: username `User`, password `password`. Auto-logon is enabled for the first boot only.
- The autounattend sets the computer name, locale (`en-US`), keyboard (`en-US`), UEFI/GPT disk layout, and enables Remote Desktop.
- The installation uses a **generic Windows 11 Pro key** that does not require activation. See [vmconfig/README.md](./vmconfig/README.md) for KMS keys and activation instructions.

### 2.1) Changing memory allocation

The VM is created with 16 GB of RAM by default. To change the memory allocation for an existing VM (the VM must be stopped first):

```powershell
# Stop the VM if running
Stop-VM -Name "windows11-01" -Force
# Set memory to desired value (e.g., 32 GB)
Set-VM -Name "windows11-01" -MemoryStartupBytes 32768MB -MemoryMinimumBytes 32768MB -MemoryMaximumBytes 32768MB
# Start the VM again
Start-VM -Name "windows11-01"
```

To change the default for new VMs, edit the `New-VM.ps1` script and replace `16384MB` with the desired value in megabytes (e.g., `32768MB` for 32 GB).

### 2.2) Testing connectivity

Once the VM is running, you can find its IP address:

```powershell
Get-VM -Name "windows11-01" | Select-Object -ExpandProperty NetworkAdapters | Select-Object IPAddresses
```

Then connect via Remote Desktop:

```powershell
mstsc /v:<ip-address>
```

Or SSH (if OpenSSH is enabled):

```powershell
ssh User@<ip-address>
```

## 3) Known limitations

- The Windows 11 ISO must be downloaded manually from Microsoft.
- After installation, DVD drives must be manually removed to prevent booting into the installer again.
- The VM will be unactivated. Use a purchased key or KMS for activation (see [vmconfig/README.md](./vmconfig/README.md)).
- Enhanced Session Mode is available by default in Hyper-V for Windows guests.

Back to [[Windows 11 guest on Windows Hyper-V host](README.md)]
