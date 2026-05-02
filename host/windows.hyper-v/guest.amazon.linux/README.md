# Amazon Linux guest on Windows Hyper-V host

Minimal commands. Walk-through: [read.more.md](read.more.md). Cross-host
concepts: [../../CODE.md](../../CODE.md).

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

Default `ec2-user` / `amazonlinux` (override in
[vmconfig/user-data](./vmconfig/user-data)):

```bash
sudo /automation/fetch-and-execute.sh virtual/guest.amazon.linux/amazon.linux.update.sh
sudo dnf groupinstall -y "Desktop"
sudo shutdown now
```

Good moment for a Hyper-V checkpoint.

## Next

[Amazon Linux workloads](../../guest.amazon.linux/README.md) ·
[read.more.md](read.more.md)
