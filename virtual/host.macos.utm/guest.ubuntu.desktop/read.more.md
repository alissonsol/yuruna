# Ubuntu Desktop guest on macOS UTM host — Nerd-Level Details

See [../../CODE.md](../../CODE.md) for host prerequisites, VM sizing,
and connectivity. macOS counterpart of
[Hyper-V version](../../host.windows.hyper-v/guest.ubuntu.desktop/).

## Nested virtualization requirements

Docker Desktop inside the guest needs `/dev/kvm`, which depends on
nested virtualization. Required:

| Requirement | Detail |
|---|---|
| **macOS** | 15.0 Sequoia or later |
| **Chip**  | Apple **M3**, M4, or later (M1/M2 not supported) |
| **UTM**   | v4.6.0 or later |
| **Backend** | Apple Virtualization (not QEMU) |

`New-VM.ps1` checks these and exits with an error if unmet.

## 1) Get the image

[`Get-Image.ps1`](./Get-Image.ps1) fetches Ubuntu Desktop 24.04 LTS
ARM64 into `~/virtual/ubuntu.env/`.

```bash
pwsh ./Get-Image.ps1
```

Prerequisites: `brew install --cask utm`, `brew install powershell`,
`brew install openssl qemu` (password hashing + disk image conversion).

## 2) Create the VM

[`New-VM.ps1`](./New-VM.ps1) assembles a UTM bundle under
`~/Desktop/Yuruna.VDE/<machinename>/`. Copies the ISO into the bundle,
creates a 512 GB raw disk (Apple Virtualization requires raw), generates
an autoinstall `seed.iso`, and writes `config.plist` from
[`config.plist.template`](./config.plist.template) — Apple Virtualization
ARM64, 4 vCPU, 16 GB RAM, UEFI, shared NAT, clipboard, nested virt via
`GenericPlatform`.

```bash
pwsh ./New-VM.ps1                  # default hostname ubuntu-desktop01
pwsh ./New-VM.ps1 -VMName myhost
```

Double-click `<hostname>.utm` to import into UTM and start.

Autoinstall sets locale `en_US.UTF-8`, keyboard `us`, LVM layout, and
SSH. Default credentials: `ubuntu` / `password` — required change on
first login. After install, the disk is first in UEFI boot order.

Back to [[Ubuntu Desktop guest (UTM)](README.md)]
