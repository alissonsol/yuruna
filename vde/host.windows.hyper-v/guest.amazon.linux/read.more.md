# Amazon Linux guest on Windows Hyper-V host - Nerd-Level Details

Copyright (c) 2019-2026 by Alisson Sol et al.

## 1) Get all in!

What can you do during [The Long Dark Tea-Time of the Soul](https://en.wikipedia.org/wiki/The_Long_Dark_Tea-Time_of_the_Soul)?

This uses Hyper-V to run Amazon Linux 2023 on Windows. See [requirements and limitations](https://docs.aws.amazon.com/linux/al2023/ug/hyperv-supported-configurations.html). Commands are PowerShell unless noted otherwise.

### 1.1) Downloading the latest files

Check that the PowerShell version is a recent one (> 7.5) and that you run from an Administrator window.

```powershell
> $PSVersionTable.PSVersion

Major  Minor  Patch  PreReleaseLabel BuildLabel
-----  -----  -----  --------------- ----------
7      5      4
```

**Run the PowerShell script [`Get-Image.ps1`](./Get-Image.ps1).**

## 2) Creating the VM(s)

One-time steps per host machine:
- Download and install the latest [Windows Assessment and Deployment Kit (Windows ADK)](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install). During installation, select only "Deployment Tools" (provides `oscdimg.exe`).
- Confirm the path to `oscdimg.exe` is correct at the top of `../VM.common.psm1`.
- Run `Get-Image.ps1` at least once.

For each VM:
- Run `New-VM.ps1 <vmname>` (e.g., `New-VM.ps1 amazon-linux01`). This creates the VM, generates a `seed.iso` from the `vmconfig` folder, and places it in a per-VM folder under `$localVhdxPath`.
- Start the VM from Hyper-V Manager. Default credentials: `ec2-user` / `amazonlinux` (unless changed in [vmconfig/user-data](./vmconfig/user-data)). If prompted for `/usr/bin/dnf check-release-update`, upgrade before continuing.
- Run `sudo bash /amazon.linux.update.sh` (the `runcmd` in `user-data` pre-downloads this file to `/`). This installs the GUI and tools.
- Run `sudo reboot now`. The VM reboots into the GUI.

### 2.1) Changing memory allocation

The VM is created with 16 GB of RAM by default. To change the memory allocation for an existing VM (the VM must be stopped first):

```powershell
# Stop the VM if running
Stop-VM -Name "amazon-linux01" -Force
# Set memory to desired value (e.g., 32 GB)
Set-VM -Name "amazon-linux01" -MemoryStartupBytes 32768MB -MemoryMinimumBytes 32768MB -MemoryMaximumBytes 32768MB
# Start the VM again
Start-VM -Name "amazon-linux01"
```

To change the default for new VMs, edit the `New-VM.ps1` script and replace `16384MB` with the desired value in megabytes (e.g., `32768MB` for 32 GB).

**CHECKPOINT:** Good time to create a Hyper-V checkpoint `VM Configured`.

Test VM connectivity — find IP addresses of running guests:

```powershell
Get-VM | Where-Object {$_.State -eq "Running"} | Get-VMNetworkAdapter | Select-Object VMName, IPAddresses
```

## 3) Optional

- Install PowerShell: `sudo dnf install powershell -y`

## 4) TODO

### 4.1) GUI resolution improvement

This is a good contribution opportunity, since it is still a "TODO". The following path was tested, but instructions didn't work.
- Instructions for server from the [Tutorial: Configure TigerVNC server on AL2023](https://docs.aws.amazon.com/linux/al2023/ug/vnc-configuration-al2023.html).
- Client tested from: [Download TightVNC](https://www.tightvnc.com/download.php).

Tried changing the resolution to 1920x1080, and still got 1024x768. For now, since working with multiple VMs, not a roadblock, and just an inconvenience.

Back to [[Amazon Linux guest on Windows Hyper-V host](README.md)]
