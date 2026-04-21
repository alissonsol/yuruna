# Windows Hyper-V Host Setup

One-time setup for a Windows host with Hyper-V. Cross-host concepts
(install-one-liner convention, post-install steps, optional Squid cache
VM, guest workload pattern) live in [../CODE.md](../CODE.md).

## Quick install (one line)

From a fresh **Windows PowerShell** (or `pwsh`):

```powershell
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows-install.ps1$nc" | iex
```

Installs PowerShell 7, Git, Windows ADK Deployment Tools (for
`oscdimg.exe`), and Tesseract OCR via `winget`; enables the
**Microsoft-Hyper-V-All** feature; clones the repo to
`%USERPROFILE%\git\yuruna`; seeds `test\test-config.json`; runs
[`Enable-TestAutomation.ps1`](Enable-TestAutomation.ps1) to keep the
display active during screen captures. Idempotent; elevation requested
once with an up-front banner.

After the script finishes, follow the steps in
[../CODE.md](../CODE.md#install-one-liner-convention). On Windows, the
reboot in step 2 is required only if Hyper-V was just enabled.
"Launch hypervisor UI" in step 4 is Hyper-V Manager:

```powershell
Start-Process virtmgmt.msc
```

It's not automated because Hyper-V Manager personalizes per user on
first launch and some enterprise-managed machines require interactive
acknowledgement. Prefer `pwsh` over the legacy `powershell.exe`
afterwards.

Manual walk-through of the installer: [read.more.md](read.more.md).

## Optional: Squid cache VM

See [../CODE.md](../CODE.md#optional-squid-cache-vm) and
[../../docs/caching.md](../../docs/caching.md). Setup:

```powershell
cd $HOME\git\yuruna\virtual\host.windows.hyper-v\guest.squid-cache
pwsh .\Get-Image.ps1
pwsh .\New-VM.ps1
```

Once `squid-cache` is running the Ubuntu Desktop `New-VM.ps1`
auto-detects it and injects the proxy URL into the seed ISO.

## Next: Create a Guest VM

- [Amazon Linux](guest.amazon.linux/README.md)
- [Ubuntu Desktop](guest.ubuntu.desktop/README.md)
- [Windows 11](guest.windows.11/README.md)

[Troubleshooting](troubleshooting.md) · Back to [[Yuruna](../../README.md)]
