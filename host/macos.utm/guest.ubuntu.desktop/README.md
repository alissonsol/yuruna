# Ubuntu Desktop guest on macOS UTM host

Minimal commands. Walk-through: [read.more.md](read.more.md). Cross-host
concepts: [../../CODE.md](../../CODE.md).

**Nested-virt requirements (Docker/KVM inside the VM)**: macOS 15+,
Apple **M3+**, UTM v4.6+ — verified by `New-VM.ps1`.

## One-time

From `yuruna/virtual/host.macos.utm/guest.ubuntu.desktop` (do not `sudo`):

```bash
pwsh ./Get-Image.ps1
```

## For each VM

```bash
pwsh ./New-VM.ps1                   # default hostname
pwsh ./New-VM.ps1 -VMName myhost
```

Double-click `HOSTNAME.utm` in `~/Desktop/Yuruna.VDE/<machinename>/` to
import and start. Autoinstall runs unattended (~15 min; screen may
stay dark — stop and restart if nothing after 15 min).

## Update

Default `ubuntu` / `password`; change forced on first login. In a guest
terminal:

```bash
/automation/fetch-and-execute.sh virtual/guest.ubuntu.desktop/ubuntu.desktop.update.sh
sudo reboot now
```

## Next

[Ubuntu Desktop workloads](../../guest.ubuntu.desktop/README.md) ·
[read.more.md](read.more.md)
