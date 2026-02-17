# Amazon Linux running in Windows Hyper-V

Copyright (c) 2019-2026 by Alisson Sol et al.

Minimal commands for creating the VM. Link to details at the end.

## One-time setup

**On the Windows host (Administrator PowerShell): Getting the base image**

Assuming you are in the `yuruna\vde\windows.hyper-v.host\amazon.linux.guest` folder.

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
sudo bash /amazon.linux.update.bash
sudo dnf groupinstall "Desktop" -y
sudo reboot now
```

The machine is now ready!

## Next Steps

Proceed to the [Post-VDE Setup](../../scripts.guest/README.md) instructions to install additional tools and services.

Read more [here](read.more.md) about the details of the VM creation process.

