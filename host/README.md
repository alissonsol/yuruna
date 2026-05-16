# Hosts — VM provisioning per hypervisor

Each subfolder owns VM provisioning (image download, VM creation) for
every supported guest on one hypervisor.

- [macOS UTM](macos.utm/README.md)
- [Windows Hyper-V](windows.hyper-v/README.md)
- [Ubuntu KVM/libvirt](ubuntu.kvm/README.md)

Project-wide architecture: [../docs/architecture.md](../docs/architecture.md). Guest-side
workloads installed inside a running VM:
[../guest/README.md](../guest/README.md).

## Folder layout

```
host/
├── macos.utm/         Host setup for macOS + UTM
│   ├── guest.<name>/  Per-guest Get-Image.ps1 + New-VM.ps1
│   └── guest.squid-cache/  Optional caching proxy VM
├── windows.hyper-v/   Host setup for Windows + Hyper-V
│   ├── guest.<name>/
│   └── guest.squid-cache/
└── ubuntu.kvm/        Host setup for Ubuntu + KVM/libvirt
    ├── guest.<name>/  Windows 11 / Ubuntu Server / Amazon Linux
    └── guest.squid-cache/  Optional caching proxy VM
```

The cross-host workload scripts that run **inside** a guest live under
[../guest/](../guest/), separate from these per-host provisioners.

## Install one-liner convention

Host setup starts with a single `irm … | iex` (Windows),
`curl … | bash` (macOS), or `bash <(curl ...)` (Ubuntu) line. Each
host's installer reads `YurunaCacheContent` — see
[../docs/caching.md](../docs/caching.md) for scope, persistence, and
the optional Squid VM. Both installers are idempotent, request
elevation once with an up-front banner, and run
`Enable-TestAutomation.ps1` to keep the display on during screenshots.

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
   [read.more.md](read.more.md#macos-tcc-grants).
6. Run `pwsh test/Invoke-TestRunner.ps1`.

Manual walk-throughs:
[macos.utm/read.more.md](macos.utm/read.more.md),
[windows.hyper-v/read.more.md](windows.hyper-v/read.more.md). Ubuntu
KVM's host-side guidance lives directly in
[ubuntu.kvm/README.md](ubuntu.kvm/README.md).

## Optional Squid cache VM

Each host has a `guest.squid-cache/` folder that creates a small
Ubuntu Server VM running Squid. Run `Get-Image.ps1` then `New-VM.ps1`
once;
later guest installs pull cacheable content (kernels, firmware, `.deb`)
from LAN instead of Ubuntu's CDN, cutting install times from ~30 min to
~2 min and eliminating the `429 Too Many Requests` failures that hit
back-to-back cycles. The harness works without it.

Full setup, monitoring (Grafana on :3000), HTTPS/SSL-bump, and offline
replay live in [../docs/caching.md](../docs/caching.md). Test-harness
wrappers (`Start-CachingProxy.ps1`, `Test-CachingProxy.ps1`,
`YURUNA_CACHING_PROXY_IP`):
[../test/CachingProxy.md](../test/CachingProxy.md).

## VM sizing and connectivity

Every VM is **16 GB RAM, 4 vCPU, 512 GB disk (dynamic/thin)**. Resize
new VMs by editing `New-VM.ps1`; resize an existing VM via the
hypervisor UI or `Set-VM` cmdlet. Find a guest's IP with `Get-VM` on
Hyper-V, by reading `/var/db/dhcpd_leases` on macOS, or with
`virsh -c qemu:///system domifaddr --source agent <vm>` on Ubuntu KVM
(see `Get-VMIp` in `host/ubuntu.kvm/modules/Yuruna.Host.psm1` for the
full lease/agent/arp cascade). Full commands:
[read.more.md](read.more.md#vm-sizing-and-connectivity).

## Troubleshooting themes

Per-guest `troubleshooting.md` files cover guest-specific issues. Two
patterns recur across guests:

- **Time zone** — auto-detected at install; if wrong, fix in the
  guest's date/time settings.
- **GUI locks or missing settings panel** — re-run the
  `<name>.<name>.update.sh` workload until clean, then reboot.

Host-side troubleshooting:
[macos.utm/troubleshooting.md](macos.utm/troubleshooting.md),
[windows.hyper-v/troubleshooting.md](windows.hyper-v/troubleshooting.md).

Read more: [read.more.md](read.more.md).

Back to [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
