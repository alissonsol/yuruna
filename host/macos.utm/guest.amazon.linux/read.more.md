# Amazon Linux guest on macOS UTM host — Nerd-Level Details

See [../../CODE.md](../../CODE.md) for host prerequisites, VM sizing,
and connectivity. macOS counterpart of
[Hyper-V version](../../host.windows.hyper-v/guest.amazon.linux/).
Tested with Amazon Linux 2023 (not AL1/AL2). AWS
[supported configurations](https://docs.aws.amazon.com/linux/al2023/ug/hyperv-supported-configurations.html).

## 1) Get the image

Prerequisites: `brew install --cask utm`, `brew install powershell`,
`brew install qemu` (`qemu-img` for disk resize).

[`Get-Image.ps1`](./Get-Image.ps1) fetches the Amazon Linux 2023 KVM
ARM64 qcow2 image into `~/virtual/amazon.linux/`.

```bash
pwsh ./Get-Image.ps1
```

## 2) Create the VM

[`New-VM.ps1`](./New-VM.ps1) assembles a UTM bundle under
`~/Desktop/Yuruna.VDE/<machinename>/`. Converts qcow2 → raw (required
by Apple Virtualization), resizes to 128 GB (thin), creates an EFI
variable store, generates a cloud-init `seed.iso`, and writes
`config.plist` from
[`config.plist.template`](./config.plist.template) — Apple
Virtualization ARM64, 4 vCPU, 16 GB RAM, UEFI, shared NAT, clipboard.

```bash
pwsh ./New-VM.ps1                   # default hostname amazon-linux01
pwsh ./New-VM.ps1 -VMName myhost
```

Double-click `<hostname>.utm` to import and start. Cloud-init applies
config on first boot. Default credentials: `ec2-user` / `amazonlinux`.
Install the GUI with `sudo dnf groupinstall -y "Desktop"`.

## Key differences from the Hyper-V version

- Amazon Linux ships pre-built qcow2 KVM ARM64 images — no installer
  ISO; the VM boots from the converted raw disk.
- `seed.iso` uses cloud-init (not autoinstall).
- `hdiutil makehybrid` replaces `Oscdimg.exe`.
- Apple Virtualization gives better clock sync and EFI persistence
  than QEMU.

Back to [[Amazon Linux guest (UTM)](README.md)]
