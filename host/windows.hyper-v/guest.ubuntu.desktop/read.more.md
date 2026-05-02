# Ubuntu Desktop guest on Windows Hyper-V host — Nerd-Level Details

See [../../README.md](../../README.md) for host prerequisites (Hyper-V, ADK
Deployment Tools for `oscdimg.exe`), VM sizing, and connectivity.

## 1) Get the image

[`Get-Image.ps1`](./Get-Image.ps1) fetches the Ubuntu Desktop amd64
ISO into the Hyper-V default VHDX folder.

```powershell
.\Get-Image.ps1
```

## 2) Create the VM

[`New-VM.ps1`](./New-VM.ps1) creates a Gen 2 VM (16 GB RAM, half host
CPU cores, UEFI, Secure Boot off, Default Switch), mounts the Ubuntu
ISO and a cloud-init `seed.iso` as DVDs, sets DVD as first boot.

```powershell
.\New-VM.ps1                       # default hostname ubuntu-desktop01
.\New-VM.ps1 -VMName myhost
```

Autoinstall sets locale `en_US.UTF-8`, keyboard `us`, LVM layout, and
SSH. Default credentials: `ubuntu` / `password` — change forced on
first login.

## Known limitations

- Autoinstall takes ~15 min; screen can appear blank during install.
- Remove the DVD drives after install.
- Enhanced Session Mode (xrdp) is not configured.

Back to [[Ubuntu Desktop guest (Hyper-V)](README.md)]
