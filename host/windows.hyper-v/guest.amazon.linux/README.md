# Amazon Linux guest on Windows Hyper-V host

Minimal commands. Walk-through: [read.more.md](read.more.md). Cross-host
concepts: [../../README.md](../../README.md).

## One-time

From `yuruna\host\windows.hyper-v\guest.amazon.linux` in an
elevated PowerShell:

```powershell
.\Get-Image.ps1
```

## For each VM

```powershell
.\New-VM.ps1                       # default hostname
.\New-VM.ps1 -VMName myhost
```

## First login and GUI install

Test sequences log in as the per-guest test user (`yauser1` for
amazon.linux; the name is set in
[test/sequences/gui/start.guest.amazon.linux.yml](../../../test/sequences/gui/start.guest.amazon.linux.yml)
and mirrored as the `-Username` default of `New-VM.ps1`). cloud-init
creates it on top of the cloud-image default `ec2-user`. The password
is sourced from the per-cycle authentication vault under
[test/extension/authentication/](../../../test/extension/authentication/);
cloud-init's chpasswd default `expire: true` triggers the
Current/New/Retype rotation on first console login.

```bash
sudo /automation/fetch-and-execute.sh guest/amazon.linux/amazon.linux.update.sh
sudo dnf groupinstall -y "Desktop"
sudo shutdown now
```

Good moment for a Hyper-V checkpoint.

## Next

[Amazon Linux workloads](../../../guest/amazon.linux/README.md)

Read more: [read.more.md](read.more.md).

Back to [Windows Hyper-V](../README.md) · [Yuruna](../../../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
