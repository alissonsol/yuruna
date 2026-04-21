# Amazon Linux guest on macOS UTM host

Copyright (c) 2019-2026 by Alisson Sol et al.

Minimal commands for creating the VM. See [details](read.more.md) for full documentation.

## One-time setup

Do not run these scripts as root (`sudo`). Verify your identity with `whoami` first.

**On the macOS host: Getting the base image**

Assuming you are in the `yuruna/virtual/host.macos.utm/guest.amazon.linux` folder.

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

Double-click `HOSTNAME.utm` in `~/Desktop/Yuruna.VDE/<machinename>/` to import it into UTM and start the VM. Cloud-init will configure the VM on first boot (hostname, default user, and password).

**On the VM: First login and GUI install**

Amazon Linux is a headless cloud image, so the Display tab in UTM will show a text console until a graphical desktop is installed.

Unless you changed the defaults in the [vmconfig/user-data](./vmconfig/user-data) file, the user is `ec2-user` and the password is `amazonlinux`.

```bash
sudo /automation/fetch-and-execute.sh virtual/guest.amazon.linux/amazon.linux.update.sh
sudo dnf groupinstall -y "Desktop"
sudo shutdown now
```

The Amazon Linux guest is now ready! Good time to create a UTM clone and leave a stable copy resting aside.

## Next Steps

Proceed to the [Amazon Linux guest](../../guest.amazon.linux/README.md) instructions to install workloads.

Read more [here](read.more.md) about the VM creation process details.
