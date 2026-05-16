# Amazon Linux guest on macOS UTM host

Minimal commands. Walk-through: [read.more.md](read.more.md). Cross-host
concepts: [../../README.md](../../README.md).

## One-time

From `yuruna/host/macos.utm/guest.amazon.linux` (do not `sudo`):

```bash
pwsh ./Get-Image.ps1
```

## For each VM

```bash
pwsh ./New-VM.ps1                   # default hostname
pwsh ./New-VM.ps1 -VMName myhost
```

Double-click `HOSTNAME.utm` in `~/yuruna/guest.nosync/` to
import and start. Cloud-init sets hostname, default user, and password
on first boot. The Display tab shows a text console until a GUI is
installed.

## First login and GUI install

Test sequences log in as the per-guest test user (`yauser1` for
amazon.linux; the name is set in
[test/sequences/gui/start.guest.amazon.linux.yml](../../../test/sequences/gui/start.guest.amazon.linux.yml)
and mirrored as the `-Username` default of `New-VM.ps1`). cloud-init
creates it on top of the cloud-image default `ec2-user`. The password
is vault-managed under
[test/extension/authentication/](../../../test/extension/authentication/);
cloud-init's chpasswd default `expire: true` triggers the
Current/New/Retype rotation on first console login.

```bash
sudo /automation/fetch-and-execute.sh guest/amazon.linux/amazon.linux.update.sh
sudo dnf groupinstall -y "Desktop"
sudo shutdown now
```

Good moment to clone the VM in UTM and keep a stable copy aside.

## Next

[Amazon Linux workloads](../../../guest/amazon.linux/README.md)

Read more: [read.more.md](read.more.md).

Back to [macOS UTM](../README.md) · [Yuruna](../../../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
