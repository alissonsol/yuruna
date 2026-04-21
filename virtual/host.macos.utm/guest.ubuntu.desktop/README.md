# Ubuntu Desktop guest on macOS UTM host

Copyright (c) 2019-2026 by Alisson Sol et al.

Minimal commands for creating the VM. See [details](read.more.md) for full documentation.

**Nested virtualization requirements (for Docker Desktop / KVM inside the VM):** macOS 15 Sequoia or later, Apple M3+ chip, UTM v4.6+. The `New-VM.ps1` script checks these automatically.

## One-time setup

Do not run these scripts as root (`sudo`). Verify your identity with `whoami` first.

**On the macOS host: Getting the base image**

Assuming you are in the `yuruna/vde/host.macos.utm/guest.ubuntu.desktop` folder.

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

Double-click `HOSTNAME.utm` in `~/Desktop/Yuruna.VDE/<machinename>/` to import it into UTM and start the VM. The Ubuntu installer will run automatically using autoinstall. **This step may take approximately 15 minutes.** The screen may not be shown. If not shown after 15 minutes, stop and restart the VM.

**On the VM (after setup): Updating**

You should be prompted to change the password on first login. You can change the password at any time with the `passwd` command. The default user is `ubuntu` and the initial password is `password`.

Open a terminal and run the following command.

```bash
/automation/fetch-and-execute.sh vde/guest.ubuntu.desktop/ubuntu.desktop.update.sh
```

Confirm all installations finished correctly, and then reboot.

```bash
sudo reboot now
```

The Ubuntu Desktop guest is now ready!

## Next Steps

Proceed to the [Ubuntu Desktop guest](../../guest.ubuntu.desktop/README.md) instructions to install workloads.

Read more [here](read.more.md) about the VM creation process details.

