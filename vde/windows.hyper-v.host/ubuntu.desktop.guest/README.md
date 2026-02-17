# Ubuntu Desktop running in Windows Hyper-V

Copyright (c) 2019-2026 by Alisson Sol et al.

Minimal commands for creating the VM. Link to details at the end.

## One-time setup

**On the Windows host (Administrator PowerShell): Getting the base image**

Assuming you are in the `yuruna\vde\windows.hyper-v.host\ubuntu.desktop.guest` folder.

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

Start the VM from Hyper-V Manager. The Ubuntu installer will run automatically using autoinstall. **This step may take approximately 15 minutes.** The screen may not be shown. If not shown after 15 minutes, stop and restart the VM.

**On the VM (after setup): Updating**

You should be prompted to change the password on first login. You can change the password at any time with the `passwd` command. The default user is `ubuntu` and the initial password is `password`.

Open a terminal and enter the commands.

```bash
wget --no-cache -O ubuntu.desktop.update.bash https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/vde/scripts.guest/ubuntu.desktop/ubuntu.desktop.update.bash
chmod a+x ubuntu.desktop.update.bash
sudo ./ubuntu.desktop.update.bash
```

Confirm all installations finished correctly, and then reboot.

```bash
sudo reboot now
```

The Ubuntu Desktop guest is now ready!

## Next Steps

Proceed to the [Post-VDE Setup](../../scripts.guest/README.md) instructions to install additional tools and services.

Read more [here](read.more.md) about the details of the VM creation process.
