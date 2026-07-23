# Windows 11 on Ubuntu KVM/libvirt

> Common setup pattern: see [Guest Image Setup](../../../docs/guest-image-setup.md).
> This file documents only what's HOST/GUEST-specific.

Boots Windows 11 Pro (multi-edition x64) unattended on KVM/QEMU with
TPM 2.0 emulation, OVMF Secure Boot, and virtio-scsi/virtio-net for
performance.

## Manual run

```
pwsh ./Get-Image.ps1                        # stage Win11 ISO + virtio-win ISO
pwsh ./New-VM.ps1                           # default name: windows-11-01
pwsh ./New-VM.ps1 -VMName myhost            # custom name
```

`Get-Image.ps1` cannot auto-fetch the Windows 11 ISO -- Microsoft serves
it through a JavaScript-driven download page that issues short-lived
signed URLs. The script prints download instructions; drop the ISO at
`~/yuruna/image/windows.11/host.ubuntu.kvm.guest.windows.11.iso` (or any
`Win11*.iso` in that directory and the script renames it on the next
run). The virtio-win driver ISO IS auto-fetched from Fedora's hosted
bundle (signed).

`New-VM.ps1`:

1. Creates a fresh 64 G qcow2 disk under `~/yuruna/vms/<vmname>/`.
2. Renders `vmconfig/autounattend.xml` (substitutes the hostname) and
   wraps it in an autounattend.iso (Setup auto-detects this on any
   attached CD).
3. Defines + starts the VM with three CDs (Windows 11 install,
   virtio-win drivers, autounattend), q35 + UEFI Secure Boot (OVMF),
   swtpm 2.0 emulator, virtio-scsi disk, virtio-net NIC.

The Setup pass loads the virtio-scsi storage driver from the virtio-win
ISO via the `<DriverPaths>` block in autounattend.xml -- without this,
Setup hangs at "Where do you want to install Windows" because it can't
see the qcow2 disk.

## Defaults

| Knob   | Default |
|--------|---------|
| Name   | `windows-11-01` |
| RAM    | 8 GiB |
| vCPU   | min(host threads − 1, max(2, host threads ÷ 2)) |
| Disk   | 64 G qcow2 |
| User   | `ywuser1` / `password` (auto-logon on first boot) |
| Net    | libvirt `default` (NAT 192.168.122.0/24) |
| Access | OpenSSH Server enabled on first boot (port 22) + RDP |

The `ywuser1` / `password` credentials match the macOS UTM and Hyper-V
variants of `guest.windows.11`, so a single test sequence can target
the same account across all supported hosts.

## Reaching the guest

Once Setup completes (the FirstLogonCommands enable sshd):

```
virsh -c qemu:///system domifaddr <vmname>
ssh ywuser1@<ip>
# Or graphically:
virt-viewer --connect qemu:///system <vmname>
```

## Architecture support

x86_64 only. Windows 11 ARM64 on KVM aarch64 is technically possible
(via UUP-dump-assembled ISOs) but out of scope for the initial
scaffold. Use the macOS UTM guest for ARM64 Windows 11.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.22

Back to [Yuruna](../../../README.md)
