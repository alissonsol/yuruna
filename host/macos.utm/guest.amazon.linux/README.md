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

Double-click `HOSTNAME.utm` in `~/Desktop/Yuruna.VDE/<machinename>/` to
import and start. Cloud-init sets hostname, default user, and password
on first boot. The Display tab shows a text console until a GUI is
installed.

## First login and GUI install

Default `ec2-user` / `amazonlinux` (override in
[vmconfig/user-data](./vmconfig/user-data)):

```bash
sudo /automation/fetch-and-execute.sh guest/amazon.linux/amazon.linux.update.sh
sudo dnf groupinstall -y "Desktop"
sudo shutdown now
```

Good moment to clone the VM in UTM and keep a stable copy aside.

## Next

[Amazon Linux workloads](../../../guest/amazon.linux/README.md) ·
[read.more.md](read.more.md)
