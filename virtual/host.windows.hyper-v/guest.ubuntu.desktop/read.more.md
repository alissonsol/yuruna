# Ubuntu Desktop guest on Windows Hyper-V host — Nerd-Level Details

See [../../CODE.md](../../CODE.md) for host prerequisites (Hyper-V, ADK
Deployment Tools for `oscdimg.exe`), VM sizing, and connectivity.

## 1) Get the image

[`Get-Image.ps1`](./Get-Image.ps1) fetches the Ubuntu Desktop amd64
ISO into the Hyper-V default VHDX folder.

```powershell
.\Get-Image.ps1
```

## 2) Create the VM

[`New-VM.ps1`](./New-VM.ps1) creates a Generation 2 VM (16 GB RAM, half
the host CPU cores, UEFI, Secure Boot off, Default Switch), mounts the
Ubuntu ISO and a cloud-init `seed.iso` as DVD drives, and sets DVD as
first boot.

```powershell
.\New-VM.ps1                       # default hostname ubuntu-desktop01
.\New-VM.ps1 -VMName myhost
```

Autoinstall sets locale `en_US.UTF-8`, keyboard `us`, LVM layout, and
enables SSH. Default credentials: `ubuntu` / `password` — required
change on first login.

## Known limitations

- Autoinstall may take ~15 min depending on hardware; the screen can
  appear blank during installation.
- After installation, remove DVD drives to avoid booting back into the
  installer.
- Enhanced Session Mode (xrdp) is not configured — install manually if
  desired.

Back to [[Ubuntu Desktop guest (Hyper-V)](README.md)]
