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
| **Backend** | QEMU + HVF (was Apple Virtualization; see below) |

`New-VM.ps1` checks these and exits with an error if unmet.

### Why QEMU instead of Apple Virtualization

Previously this guest used Apple VZ. VZ renders the VM framebuffer directly
into UTM's `NSWindow`, which forces the test harness into two constraints
the Hyper-V path doesn't have: the UTM window must stay visible (screen
capture via `screencapture -R` returns stale pixels when the window is
occluded or on another Space) and must stay focused (AppleScript/CGEvent
keystrokes go to whichever window is active). Under QEMU, `-vnc
127.0.0.1:0` exposes the framebuffer and input over a local TCP socket
that the harness drives directly (`test/extensions/Invoke-Sequence.psm1`
speaks RFB). That mirrors the Hyper-V synthetic-video-channel /
synthetic-keyboard model: the VM runs independently of any on-screen
window, so the operator can work in other apps while the test cycles.

HVF is the Apple-provided hypervisor QEMU uses on macOS, so aarch64
Linux still runs at near-native speed.

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
creates a 512 GB raw disk (sparse on APFS), generates an autoinstall
`seed.iso`, and writes `config.plist` from
[`config.plist.template`](./config.plist.template) — QEMU backend with
HVF, ARM64 `virt` machine, 4 vCPU, 16 GB RAM, UEFIBoot (edk2), shared
NAT via vmnet (same 192.168.64.0/24 as Apple VZ), clipboard, and a
loopback VNC server on `127.0.0.1:5900` for the test harness.

```bash
pwsh ./New-VM.ps1                  # default hostname ubuntu-desktop01
pwsh ./New-VM.ps1 -VMName myhost
```

Double-click `<hostname>.utm` to import into UTM and start.

Autoinstall sets locale `en_US.UTF-8`, keyboard `us`, LVM layout, and
SSH. Default credentials: `ubuntu` / `password` — required change on
first login. After install, the disk is first in UEFI boot order.

Back to [[Ubuntu Desktop guest (UTM)](README.md)]
