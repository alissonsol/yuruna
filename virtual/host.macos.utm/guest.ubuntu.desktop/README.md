# Ubuntu Desktop guest on macOS UTM host

Minimal commands. See [read.more.md](read.more.md) for the full
walk-through and [../../CODE.md](../../CODE.md) for cross-host concepts.

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
import into UTM and start. Autoinstall runs unattended (~15 min; screen
may stay dark — if nothing after 15 min, stop and restart the VM).

## Update

Default `ubuntu` / `password`; forced change on first login (or any
time via `passwd`). In a guest terminal:

```bash
/automation/fetch-and-execute.sh virtual/guest.ubuntu.desktop/ubuntu.desktop.update.sh
sudo reboot now
```

## Next

Install workloads:
[Ubuntu Desktop guest](../../guest.ubuntu.desktop/README.md) ·
Details: [read.more.md](read.more.md).
