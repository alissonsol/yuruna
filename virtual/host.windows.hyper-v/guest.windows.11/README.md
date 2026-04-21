# Windows 11 guest on Windows Hyper-V host

Minimal commands. See [read.more.md](read.more.md) for the full
walk-through and [../../CODE.md](../../CODE.md) for cross-host concepts.

## One-time

From `yuruna\virtual\host.windows.hyper-v\guest.windows.11` in an
elevated PowerShell:

```powershell
.\Get-Image.ps1
```

Automates the Windows 11 ISO download from
[Microsoft](https://www.microsoft.com/software-download/windows11).
Network/automation filters can block it; the script then prints manual
instructions.

## For each VM

```powershell
.\New-VM.ps1                       # default hostname
.\New-VM.ps1 -VMName myhost
```

Start from Hyper-V Manager. The Windows installer runs unattended via
`autounattend.xml` (~15 min).

## Update

Auto-logon to `User` / `password` on first boot (forced change next
login). Elevated PowerShell:

```powershell
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/virtual/guest.windows.11/windows.11.update.ps1$nc" | iex
Restart-Computer
```

`$env:YurunaCacheContent` / `setx YurunaCacheContent …`: see
[../../../docs/caching.md](../../../docs/caching.md).

## Next

Install workloads: [Windows 11 guest](../../guest.windows.11/README.md) ·
Details: [read.more.md](read.more.md).
