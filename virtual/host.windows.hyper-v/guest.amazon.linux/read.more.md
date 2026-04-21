# Amazon Linux guest on Windows Hyper-V host — Nerd-Level Details

See [../../CODE.md](../../CODE.md) for host prerequisites (Hyper-V, ADK
Deployment Tools for `oscdimg.exe`), VM sizing, and connectivity.
Amazon Linux 2023 —
[AL supported configurations](https://docs.aws.amazon.com/linux/al2023/ug/hyperv-supported-configurations.html).

## 1) Get the image

From an elevated PowerShell 7.5+ (`$PSVersionTable.PSVersion`):

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
  `amazonlinux` (unless overridden in
  [vmconfig/user-data](./vmconfig/user-data)). Upgrade if prompted by
  `/usr/bin/dnf check-release-update`.
- `/automation/fetch-and-execute.sh virtual/guest.amazon.linux/amazon.linux.update.sh`
  (cloud-init pre-downloads `fetch-and-execute.sh` into `/automation/`;
  the workload script is pulled from GitHub on demand). This installs
  the GUI and tools.
- `sudo reboot now` → the VM reboots into the GUI.

**CHECKPOINT**: a good moment for a Hyper-V checkpoint named
`VM Configured`.

Optional: `sudo dnf install powershell -y`.

## TODO — GUI resolution

Good contribution opportunity. The
[AL2023 TigerVNC tutorial](https://docs.aws.amazon.com/linux/al2023/ug/vnc-configuration-al2023.html)
path was tested ([TightVNC](https://www.tightvnc.com/download.php)
client) but setting 1920×1080 still produced 1024×768.

Back to [[Amazon Linux guest (Hyper-V)](README.md)]
