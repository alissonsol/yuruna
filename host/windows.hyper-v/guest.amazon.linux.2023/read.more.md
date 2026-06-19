# Amazon Linux 2023 guest on Windows Hyper-V host — Nerd-Level Details

See [Hosts — ...](../../README.md) for host prerequisites (Hyper-V, ADK
Deployment Tools for `oscdimg.exe`), VM sizing, and connectivity.
Amazon Linux 2023 —
[AL supported configurations](https://docs.aws.amazon.com/linux/al2023/ug/hyperv-supported-configurations.html).

## 1) Get the image

From an elevated PowerShell 7.5+:

```
.\Get-Image.ps1
```

One-time per host: install the ADK Deployment Tools (for
`oscdimg.exe`); confirm the path at the top of
[`../modules/Yuruna.Host.psm1`](../modules/Yuruna.Host.psm1).

## 2) Create the VM(s)

```
.\New-VM.ps1 amazon-linux01
```

Generates a cloud-init `seed.iso` from `vmconfig/`, creates a per-VM
folder under the Hyper-V default VHDX path (`(Get-VMHost).VirtualHardDiskPath`),
and places seed + VHDX there.

- Start from Hyper-V Manager. Default credentials: `ec2-user` /
  `amazonlinux` (override in
  [host/vmconfig/amazon.linux.2023.base.user-data](../../vmconfig/amazon.linux.2023.base.user-data)). Upgrade if prompted by
  `dnf check-release-update`.
- `/usr/local/lib/yuruna/fetch-and-execute.sh guest/amazon.linux.2023/amazon.linux.2023.update.sh`
  installs the GUI and tools (cloud-init seeded `fetch-and-execute.sh`
  into `/automation/`; workloads pull from GitHub on demand).
- `sudo reboot now` — boots into the GUI.

**CHECKPOINT**: good moment for a Hyper-V checkpoint
named `VM Configured`. Optional: `sudo dnf install powershell -y`.

## Open issue — GUI resolution

Contribution opportunity. The
[AL2023 TigerVNC tutorial](https://docs.aws.amazon.com/linux/al2023/ug/vnc-configuration-al2023.html)
path was tested ([TightVNC](https://www.tightvnc.com/download.php) client)
but 1920×1080 settings produced 1024×768.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.19

Back to [Yuruna](../../../README.md)
