# Ubuntu Desktop guest on Windows Hyper-V host

Minimal commands. Walk-through: [read.more.md](read.more.md). Cross-host
concepts: [../../README.md](../../README.md).

## One-time

From `yuruna\host\windows.hyper-v\guest.ubuntu.desktop` in an
elevated PowerShell:

```powershell
.\Get-Image.ps1
```

## For each VM

```powershell
.\New-VM.ps1                       # default hostname
.\New-VM.ps1 -VMName myhost
```

Start from Hyper-V Manager. Autoinstall runs unattended (~15 min;
screen may stay dark — stop and restart if nothing after 15 min).

## Update

Default `ubuntu` / `password`; change forced on first login.

```bash
/automation/fetch-and-execute.sh guest/ubuntu.desktop/ubuntu.desktop.update.sh
sudo reboot now
```

## Next

[Ubuntu Desktop workloads](../../../guest/ubuntu.desktop/README.md) ·
[read.more.md](read.more.md)
