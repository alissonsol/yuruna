# Ubuntu Desktop guest on Windows Hyper-V host

Minimal commands. See [read.more.md](read.more.md) for the full
walk-through and [../../CODE.md](../../CODE.md) for cross-host concepts.

## One-time

From `yuruna\virtual\host.windows.hyper-v\guest.ubuntu.desktop` in an
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
screen may stay dark — if nothing after 15 min, stop and restart).

## Update

Default `ubuntu` / `password`; autoinstall expires the password so a
change is forced on first login (`passwd` thereafter).

```bash
/automation/fetch-and-execute.sh virtual/guest.ubuntu.desktop/ubuntu.desktop.update.sh
sudo reboot now
```

## Next

Install workloads: [Ubuntu Desktop guest](../../guest.ubuntu.desktop/README.md) ·
Details: [read.more.md](read.more.md).
