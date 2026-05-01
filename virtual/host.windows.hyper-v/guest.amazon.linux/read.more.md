# Amazon Linux guest on Windows Hyper-V host — Nerd-Level Details

See [../../CODE.md](../../CODE.md) for host prerequisites (Hyper-V, ADK
Deployment Tools for `oscdimg.exe`), VM sizing, and connectivity.
Amazon Linux 2023 —
[AL supported configurations](https://docs.aws.amazon.com/linux/al2023/ug/hyperv-supported-configurations.html).

## 1) Get the image

From an elevated PowerShell 7.5+:

```powershell
.\Get-Image.ps1
```

One-time per host: install the ADK Deployment Tools (for
`oscdimg.exe`); confirm the path at the top of
[`../VM.common.psm1`](../VM.common.psm1).

## 2) Create the VM(s)

```powershell
.\New-VM.ps1 amazon-linux01
```

Generates a cloud-init `seed.iso` from `vmconfig/`, creates a per-VM
folder under `$localVhdxPath`, and places seed + VHDX there.

- Start from Hyper-V Manager. Default credentials: `ec2-user` /
  `amazonlinux` (override in
  [vmconfig/user-data](./vmconfig/user-data)). Upgrade if prompted by
  `dnf check-release-update`.
- `/automation/fetch-and-execute.sh virtual/guest.amazon.linux/amazon.linux.update.sh`
  installs the GUI and tools (cloud-init seeded `fetch-and-execute.sh`
  into `/automation/`; workloads pull from GitHub on demand).
- `sudo reboot now` — boots into the GUI.

**CHECKPOINT**: good moment for a Hyper-V checkpoint
named `VM Configured`. Optional: `sudo dnf install powershell -y`.

## TODO — GUI resolution

Contribution opportunity. The
[AL2023 TigerVNC tutorial](https://docs.aws.amazon.com/linux/al2023/ug/vnc-configuration-al2023.html)
path was tested ([TightVNC](https://www.tightvnc.com/download.php) client)
but 1920×1080 settings produced 1024×768.

Back to [[Amazon Linux guest (Hyper-V)](README.md)]
