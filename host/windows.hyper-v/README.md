# Windows Hyper-V Host Setup

One-time setup for a Windows host with Hyper-V. Cross-host concepts
(install-one-liner convention, post-install steps, optional Squid cache
VM, guest workload pattern) live in [Hosts — ...](../README.md).

## Quick install (one line)

From a fresh **Windows PowerShell** (or `pwsh`):

```powershell
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1$nc" | iex
```

Installs PowerShell 7, Git, Windows ADK Deployment Tools (for
`oscdimg.exe`), QEMU tools (for `qemu-img` used by
`guest.squid-cache/Get-Image.ps1`), and Tesseract OCR via `winget`;
enables **Microsoft-Hyper-V-All** via `dism.exe`; clones the repo to
`%USERPROFILE%\git\yuruna`; seeds `test\test.config.yml`. Idempotent;
elevation requested once. Disabling display timeout and screen lock
for unattended runs is a separate opt-in step — run
[`Enable-TestAutomation.ps1`](Enable-TestAutomation.ps1) manually
after install.

Then follow [Hosts — ...](../README.md#install-one-liner-convention). On
Windows: step 2's reboot only applies when Hyper-V was just enabled;
step 4's hypervisor UI is Hyper-V Manager:

```powershell
Start-Process virtmgmt.msc
```

Not auto-launched: Hyper-V Manager personalizes per user on first run
and enterprise-managed machines may need interactive acknowledgement.
Prefer `pwsh` over `powershell.exe` afterwards.

Manual walk-through: [Windows Hyper-V Host Setup - Nerd-Level Details](read.more.md).

## Optional: Squid cache VM

See [Hosts — ...](../README.md#optional-squid-cache-vm) and
[Caching](../../docs/caching.md). Once `squid-cache` is
running, the Ubuntu Server `New-VM.ps1` scripts auto-detect it and
inject the proxy URL into the seed ISO.

## Next: Create a Guest VM

- [Amazon Linux 2023](guest.amazon.linux.2023/README.md)
- [Ubuntu Server 24.04](guest.ubuntu.server.24/README.md)
- [Ubuntu Server 26.04](guest.ubuntu.server.26/README.md)
- [Windows 11](guest.windows.11/README.md)

Read more: [Windows Hyper-V Host Setup - Nerd-Level Details](read.more.md).

[Troubleshooting](../../docs/host-hyperv.md) · Back to [Hosts](../README.md) · [Yuruna](../../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
