# Amazon Linux guest on macOS UTM host

Minimal commands. See [read.more.md](read.more.md) for the full
walk-through and [../../CODE.md](../../CODE.md) for cross-host concepts.

## One-time

From `yuruna/virtual/host.macos.utm/guest.amazon.linux` (do not `sudo`):

```bash
pwsh ./Get-Image.ps1
```

## For each VM

```bash
pwsh ./New-VM.ps1                   # default hostname
pwsh ./New-VM.ps1 -VMName myhost
```

Double-click `HOSTNAME.utm` in `~/Desktop/Yuruna.VDE/<machinename>/` to
import into UTM and start. Cloud-init sets hostname, default user, and
password on first boot. The Display tab shows a text console until a
GUI is installed.

## First login and GUI install

Default `ec2-user` / `amazonlinux` (unless changed in
[vmconfig/user-data](./vmconfig/user-data)):

```bash
sudo /automation/fetch-and-execute.sh virtual/guest.amazon.linux/amazon.linux.update.sh
sudo dnf groupinstall -y "Desktop"
sudo shutdown now
```

Good moment to clone the VM in UTM and keep a stable copy aside.

## Next

Install workloads:
[Amazon Linux guest](../../guest.amazon.linux/README.md) ·
Details: [read.more.md](read.more.md).
