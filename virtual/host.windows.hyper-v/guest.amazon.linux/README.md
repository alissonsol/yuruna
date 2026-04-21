# Amazon Linux guest on Windows Hyper-V host

Copyright (c) 2019-2026 by Alisson Sol et al.

Minimal commands for creating the VM. See [details](read.more.md) for full documentation.

## One-time setup

**On the Windows host (Administrator PowerShell): Getting the base image**

Assuming you are in the `yuruna\virtual\host.windows.hyper-v\guest.amazon.linux` folder.

```powershell
.\Get-Image.ps1
```

## For each VM

**On the Windows host (Administrator PowerShell): Create VM**

```powershell
.\New-VM.ps1
```

Or with a custom hostname:

```powershell
.\New-VM.ps1 -VMName myhostname
```

**On the VM: First login and GUI install**

Unless you changed the defaults in the [vmconfig/user-data](./vmconfig/user-data) file, the user is `ec2-user` and the password is `amazonlinux`.

```bash
sudo /automation/fetch-and-execute.sh virtual/guest.amazon.linux/amazon.linux.update.sh
sudo dnf groupinstall -y "Desktop"
sudo shutdown now
```

The Amazon Linux guest is now ready! Good time for a checkpoint.

## Next Steps

Proceed to the [Amazon Linux guest](../../guest.amazon.linux/README.md) instructions to install workloads.

Read more [here](read.more.md) about the VM creation process details.

