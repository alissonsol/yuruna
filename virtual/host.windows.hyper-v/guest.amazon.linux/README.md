# Amazon Linux guest on Windows Hyper-V host

Minimal commands. See [read.more.md](read.more.md) for the full
walk-through and [../../CODE.md](../../CODE.md) for cross-host concepts.

## One-time

From `yuruna\virtual\host.windows.hyper-v\guest.amazon.linux` in an
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

Default `ec2-user` / `amazonlinux` (unless changed in
[vmconfig/user-data](./vmconfig/user-data)):

```bash
sudo /automation/fetch-and-execute.sh virtual/guest.amazon.linux/amazon.linux.update.sh
sudo dnf groupinstall -y "Desktop"
sudo shutdown now
```

Good moment for a Hyper-V checkpoint.

## Next

Install workloads: [Amazon Linux guest](../../guest.amazon.linux/README.md) ·
Details: [read.more.md](read.more.md).
