# Windows 11 guest on Windows Hyper-V host — Nerd-Level Details

See [../../README.md](../../README.md) for host prerequisites (Hyper-V, ADK
Deployment Tools for `oscdimg.exe`), VM sizing, and connectivity.

## 1) Get the image

The Windows 11 ISO has no direct download URL.
[`Get-Image.ps1`](./Get-Image.ps1) prints instructions to download from
[Microsoft](https://www.microsoft.com/software-download/windows11) into
the Hyper-V default VHDX folder; any `Win11*.iso` there is renamed
automatically.

```powershell
.\Get-Image.ps1
```

## 2) Create the VM

[`New-VM.ps1`](./New-VM.ps1) creates a Gen 2 VM (16 GB RAM, half the
host CPU cores, UEFI + Secure Boot with the Microsoft Windows template,
Default Switch, virtual TPM), mounts the Windows ISO and autounattend
seed ISO as DVDs, sets DVD as first boot, and enables Guest Service
Interface.

```powershell
.\New-VM.ps1                   # default hostname windows11-01
.\New-VM.ps1 -VMName myhost
```

The autounattend sets locale `en-US`, keyboard `en-US`, UEFI/GPT, and
enables Remote Desktop. Default credentials: `User` / `password`
(auto-logon first boot only). Generic Windows 11 Pro key — see
[vmconfig/README.md](./vmconfig/README.md) for KMS keys and activation.

## Known limitations

- ISO must be downloaded manually.
- Remove the DVD drives after install.
- VM is unactivated until a key is provided.
- Enhanced Session Mode is available by default for Windows guests.

Back to [[Windows 11 guest (Hyper-V)](README.md)]
