# Hosts — VM provisioning per hypervisor

Each subfolder owns VM provisioning (image download, VM creation) for
every supported guest on one hypervisor.

- [macOS UTM](macos.utm/README.md)
- [Windows Hyper-V](windows.hyper-v/README.md)
- [Ubuntu KVM/libvirt](ubuntu.kvm/README.md)

Project-wide architecture: [Yuruna Architecture](../docs/architecture.md). Guest-side
workloads installed inside a running VM:
[Guests — ...](../guest/README.md).

## What lives where

The host area splits documentation between two files per scope:

- **`README.md`** (this file) — the happy path. Folder layout, install
  one-liner, the steps an operator follows when nothing surprises
  them. Decisions and policy that everyone needs to know once
  (VM sizing, `Enable-TestAutomation.ps1` purpose, optional cache VM).
- **`read.more.md`** — the gotcha catalogue and command reference.
  TCC grant details, VM resize commands, IP discovery cascades,
  per-platform first-run subtleties. Reach for it when the README's
  one-liner did not deliver.

The same split applies recursively under each platform folder
([`macos.utm/README.md`](macos.utm/README.md) vs
[`macos.utm/read.more.md`](macos.utm/read.more.md), etc.). README
entries link into the matching `read.more.md` section when a topic
is summarised here and detailed there — the README never duplicates
content already in `read.more.md`, only links to it.

## Folder layout

```
host/
├── macos.utm/         Host setup for macOS + UTM
│   ├── guest.<name>/  Per-guest Get-Image.ps1 + New-VM.ps1
│   └── guest.caching-proxy/  Optional caching proxy VM
├── windows.hyper-v/   Host setup for Windows + Hyper-V
│   ├── guest.<name>/
│   └── guest.caching-proxy/
└── ubuntu.kvm/        Host setup for Ubuntu + KVM/libvirt
    ├── guest.<name>/  Per-guest Get-Image.ps1 + New-VM.ps1
    └── guest.caching-proxy/  Optional caching proxy VM
```

The cross-host workload scripts that run **inside** a guest live under
[../guest/](../guest/), separate from these per-host provisioners.

## Guest × host coverage

Most guests are supported on all three hosts. The exception is
**macOS 26**, which can only run as a guest on a macOS host (Apple's
licensing forbids macOS-on-non-Apple virtualization), so it is
available only under `host/macos.utm/guest.macos.26/`.

## Install one-liner convention

Host setup starts with a single `irm … | iex` (Windows),
`curl … | bash` (macOS), or `bash <(curl ...)` (Ubuntu) line. Each
host's installer reads `YurunaCacheContent` — see
[Caching](../docs/caching.md) for scope, persistence, and
the optional Squid VM. All installers are idempotent and request
elevation once with an up-front banner. Enabling the host as a test
host with `Enable-TestAutomation.ps1` (which keeps the display on
during screenshots) is a separate, manual opt-in step — the installers
only print it as a next-step hint, they do not run it automatically.

After the installer finishes:

1. Open a **new** shell so PATH updates apply.
2. Windows only: reboot if `Microsoft-Hyper-V-All` was just enabled.
3. Edit `test/test.config.yml` for your environment.
4. Launch the hypervisor UI once (Hyper-V Manager / UTM) to surface
   first-run dialogs.
5. macOS only: grant the terminal app Accessibility **and** Screen
   Recording at **System Settings → Privacy & Security**. Both
   required; both prompted by `Enable-TestAutomation.ps1`. Dismissed a
   dialog? Toggle manually, then **fully quit and relaunch the
   terminal** — TCC grants don't apply to a running process. Detail:
   [Hosts — Nerd-Level Details](read.more.md#macos-tcc-grants).
6. Run `pwsh test/Invoke-TestRunner.ps1`.

Manual walk-throughs:
[macOS UTM Host Setup - Nerd-Level Details](macos.utm/read.more.md),
[Windows Hyper-V Host Setup - Nerd-Level Details](windows.hyper-v/read.more.md). Ubuntu
KVM's host-side guidance lives directly in
[Ubuntu KVM/libvirt ...](ubuntu.kvm/README.md).

## Optional Squid cache VM

Each host has a `guest.caching-proxy/` folder that creates a small
Ubuntu Server VM running Squid. Run `Get-Image.ps1` then `New-VM.ps1`
once;
later guest installs pull cacheable content (kernels, firmware, `.deb`)
from LAN instead of Ubuntu's CDN, cutting install times from ~30 min to
~2 min and eliminating the `429 Too Many Requests` failures that hit
back-to-back cycles. The harness works without it.

Full setup, monitoring (Grafana on :3000), HTTPS/SSL-bump, and offline
replay live in [Caching](../docs/caching.md). Test-harness
wrappers (`Start-CachingProxy.ps1`, `Test-CachingProxy.ps1`,
`YURUNA_CACHING_PROXY_IP`):
[Caching proxy — test-harness operator reference](../docs/caching-proxy.md).

## VM sizing and connectivity

VM size varies by guest and hypervisor; all disks are dynamic/thin
(qcow2 sparse or Dynamic VHDX). Most guests get **12 GB RAM, 4 vCPU**;
the exceptions are macOS 26 (defaults to 8 GB RAM, configurable via
`-MemoryMb`), the stash-service guest (8 GB RAM), and the KVM guests,
which are sized down to the minimum that carries the workload (8 GB,
or 4 GB for Amazon Linux 2023). Disk sizes:
Ubuntu Server 24/26 are **64 GB** on every host; Windows 11 is
**512 GB** on macOS UTM and Hyper-V but **64 GB** on KVM; Amazon
Linux 2023 is **128 GB** on macOS UTM and sized to the base image
(≥16 GB) on KVM; macOS 26 defaults to **128 GB** (configurable via
`-DiskSizeGb`). Resize
new VMs by editing `New-VM.ps1`; resize an existing VM via the
hypervisor UI or `Set-VM` cmdlet. Find a guest's IP with `Get-VM` on
Hyper-V, by reading `/var/db/dhcpd_leases` on macOS, or with
`virsh -c qemu:///system domifaddr --source agent <vm>` on Ubuntu KVM
(see `Get-VMIp` in `host/ubuntu.kvm/modules/Yuruna.Host.psm1` for the
full lease/agent/arp cascade). Full commands:
[Hosts — Nerd-Level Details](read.more.md#vm-sizing-and-connectivity).

## Troubleshooting themes

Per-guest troubleshooting docs cover guest-specific issues. Two
patterns recur across guests:

- **Time zone** — auto-detected at install; if wrong, fix in the
  guest's date/time settings.
- **GUI locks or missing settings panel** — re-run the
  `<name>.<name>.update.sh` workload until clean, then reboot.

Host-side troubleshooting:
[macOS UTM host — troubleshooting](../docs/host-macos.md),
[Windows Hyper-V host — troubleshooting](../docs/host-hyperv.md).

Read more: [Hosts — Nerd-Level Details](read.more.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.17

Back to [Yuruna](../README.md)
