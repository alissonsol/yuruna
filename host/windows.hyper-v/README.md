# Windows Hyper-V Host Setup

One-time setup for a Windows host with Hyper-V. Cross-host concepts
(install-one-liner convention, post-install steps, optional Squid cache
VM, guest workload pattern) live in [Hosts -- ...](../README.md).

## Host architecture

AMD64 and ARM64 hosts are both supported. Each `Get-Image.ps1` reads the
host architecture and downloads the matching guest image; Hyper-V has no
cross-architecture emulation, so the host's architecture is also the
guest's and there is no flag to force the other one. The image lands
under the same file name either way, so `New-VM.ps1` is identical on both.

One guest needs an extra step on ARM64: Amazon Linux 2023 publishes no
ARM64 Hyper-V image, so its `Get-Image.ps1` pulls the ARM64 KVM cloud
image and converts it to VHDX with `qemu-img`. The QEMU tools below are
not optional on either architecture, though -- Hyper-V boots VHDX and the
Ubuntu cloud image the extension-service guests share ships as qcow2, so
those convert on AMD64 too.

## Quick install (one line)

From a fresh **Windows PowerShell** (or `pwsh`):

```
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1$nc" | iex
```

Installs PowerShell 7, Git, Windows ADK Deployment Tools (for
`oscdimg.exe`), QEMU tools (for `qemu-img`, used by every
extension-service `Get-Image.ps1` and on ARM64 also by
`guest.amazon.linux.2023/Get-Image.ps1`), and Tesseract OCR via `winget`;
enables **Microsoft-Hyper-V-All** via `dism.exe`; clones the repo to
`%USERPROFILE%\git\yuruna`; seeds `test\test.config.yml`. Idempotent;
elevation requested once. Disabling display timeout and screen lock
for unattended runs is a separate opt-in step -- run
[`Enable-TestAutomation.ps1`](Enable-TestAutomation.ps1) manually
after install, or let `pwsh install/setup.ps1` do it as one step of a
guided [standalone-host or lab setup](../../install/README.md#guided-setup).

Then follow [Hosts -- ...](../README.md#install-one-liner-convention). On
Windows: step 2's reboot applies only when Hyper-V was just enabled;
step 4's hypervisor UI is Hyper-V Manager:

```
Start-Process virtmgmt.msc
```

Not auto-launched: Hyper-V Manager personalizes per user on first run,
and enterprise-managed machines may need interactive acknowledgment.
Prefer `pwsh` over `powershell.exe` afterward.

Manual walk-through: [Windows Hyper-V Host Setup - Nerd-Level Details](read.more.md).

## Optional: Squid cache VM

See [Hosts -- ...](../README.md#optional-squid-cache-vm) and
[Caching](../../docs/caching.md). Once `caching-proxy-service` is
running, the Ubuntu Server `New-VM.ps1` scripts auto-detect it and
inject the proxy URL into the seed ISO.

## Next: Create a Guest VM

- [Amazon Linux 2023](guest.amazon.linux.2023/README.md)
- [Ubuntu Server 24.04](guest.ubuntu.server.24/README.md)
- [Ubuntu Server 26.04](guest.ubuntu.server.26/README.md)
- [Windows 11](guest.windows.11/README.md)

Read more: [Windows Hyper-V Host Setup - Nerd-Level Details](read.more.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.12

Back to [Yuruna](../../README.md)
