# Amazon Linux running in macOS UTM

Copyright (c) 2019-2026 by Alisson Sol et al.

Minimal commands for creating the VM. Link to details at the end.

## One-time setup

Careful not to execute the PowerShell scripts in the macOS terminal as a superuser, or that could create files that will not be accessible to processes started as the normal user later. Check `whoami` before executing the scripts.

**On the macOS host: Getting the base image**

Assuming you are in the `yuruna/vde/macos.utm.host/amazon.linux.guest` folder.

```bash
pwsh ./Get-Image.ps1
```

## For each VM

**On the macOS host (Terminal): Create VM**

```bash
pwsh ./New-VM.ps1
```

Or with a custom hostname:

```bash
pwsh ./New-VM.ps1 -VMName myhostname
```

Double-click `HOSTNAME.utm` on your Desktop to import it into UTM and start the VM. Cloud-init will configure the VM on first boot (hostname, default user, and password).

**On the VM: First login and GUI install**

Amazon Linux is a headless cloud image, so the Display tab in UTM will show "Display output is not active" until a graphical desktop is installed. Use the **Terminal** tab (serial console) in UTM for the initial login and setup.

Unless you changed the defaults in the [vmconfig/user-data](./vmconfig/user-data) file, the user is `ec2-user` and the password is `amazonlinux`.

```bash
sudo bash /amazon.linux.update.bash
sudo dnf groupinstall "Desktop" -y
sudo reboot now
```

The Amazon Linux guest is now ready!

## Next Steps

Proceed to the [Post-VDE Setup](../../scripts.guest/README.md) instructions to install additional tools and services.

Read more [here](read.more.md) about the details of the VM creation process.
