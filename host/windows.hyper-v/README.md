# Windows Hyper-V Host Setup

One-time setup for a Windows host with Hyper-V. Cross-host concepts
(install-one-liner convention, post-install steps, optional Squid cache
VM, guest workload pattern) live in [../README.md](../README.md).

## Quick install (one line)

From a fresh **Windows PowerShell** (or `pwsh`):

```powershell
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows-install.ps1$nc" | iex
```

Installs PowerShell 7, Git, Windows ADK Deployment Tools (for
`oscdimg.exe`), and Tesseract OCR via `winget`; enables
**Microsoft-Hyper-V-All**; clones the repo to `%USERPROFILE%\git\yuruna`;
seeds `test\test-config.json`; runs
[`Enable-TestAutomation.ps1`](Enable-TestAutomation.ps1). Idempotent;
elevation requested once.

Then follow [../README.md](../README.md#install-one-liner-convention). On
Windows: step 2's reboot only applies when Hyper-V was just enabled;
step 4's hypervisor UI is Hyper-V Manager:

```powershell
Start-Process virtmgmt.msc
```

Not auto-launched: Hyper-V Manager personalizes per user on first run
and enterprise-managed machines may need interactive acknowledgement.
Prefer `pwsh` over `powershell.exe` afterwards.

Manual walk-through: [read.more.md](read.more.md).

## Optional: Squid cache VM

See [../README.md](../README.md#optional-squid-cache-vm) and
[../../docs/caching.md](../../docs/caching.md). Once `squid-cache` is
running, Ubuntu Desktop `New-VM.ps1` auto-detects it and injects the
proxy URL into the seed ISO.

## Next: Create a Guest VM

- [Amazon Linux](guest.amazon.linux/README.md)
- [Ubuntu Desktop](guest.ubuntu.desktop/README.md)
- [Windows 11](guest.windows.11/README.md)

[Troubleshooting](troubleshooting.md) · Back to [[Yuruna](../../README.md)]
