# Amazon Linux 2023 guest on macOS UTM host — Nerd-Level Details

See [Hosts — ...](../../README.md) for host prerequisites, VM sizing,
and connectivity. macOS counterpart of
[Hyper-V version](../../windows.hyper-v/guest.amazon.linux.2023/).
Tested with Amazon Linux 2023 (not AL1/AL2). AWS
[supported configurations](https://docs.aws.amazon.com/linux/al2023/ug/hyperv-supported-configurations.html).

## 1) Get the image

Prerequisites: `brew install --cask utm`, `brew install powershell`,
`brew install qemu` (`qemu-img` for disk resize).

[`Get-Image.ps1`](./Get-Image.ps1) fetches the Amazon Linux 2023 KVM
ARM64 qcow2 image into `~/yuruna/image/amazon.linux.2023/`.

```
pwsh ./Get-Image.ps1
```

## 2) Create the VM

[`New-VM.ps1`](./New-VM.ps1) assembles a UTM bundle under
`~/yuruna/guest.nosync/`. Copies the qcow2 directly (the QEMU backend
reads qcow2 natively; no raw conversion), resizes to 128 GB (thin),
generates a cloud-init `seed.iso`, and writes `config.plist` from
[`config.plist.template`](./config.plist.template) — QEMU (HVF)
ARM64, core-count-policy vCPUs (min 4), 12 GB RAM, UEFI, shared NAT,
clipboard.

```
pwsh ./New-VM.ps1                   # default hostname amazon-linux01
pwsh ./New-VM.ps1 -VMName myhost
```

Double-click `<hostname>.utm` to import and start. Cloud-init applies
config on first boot. Default credentials: `yauser1` / vault-managed
(per-cycle authentication vault; expired on first login).
Install the GUI with `sudo dnf groupinstall -y "Desktop"`.

## Key differences from the Hyper-V version

- Amazon Linux ships pre-built qcow2 KVM ARM64 images — no installer
  ISO; the VM boots directly from the copied qcow2 disk.
- `seed.iso` uses cloud-init (not autoinstall).
- `hdiutil makehybrid` replaces `Oscdimg.exe`.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.22

Back to [Yuruna](../../../README.md)
