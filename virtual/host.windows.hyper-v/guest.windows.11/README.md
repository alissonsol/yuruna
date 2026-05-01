# Windows 11 guest on Windows Hyper-V host

Minimal commands. Walk-through: [read.more.md](read.more.md). Cross-host
concepts: [../../CODE.md](../../CODE.md).

## One-time

From `yuruna\virtual\host.windows.hyper-v\guest.windows.11` in an
elevated PowerShell:

```powershell
.\Get-Image.ps1
```

Automates the Windows 11 ISO download from
[Microsoft](https://www.microsoft.com/software-download/windows11);
prints manual instructions if blocked.

## For each VM

```powershell
.\New-VM.ps1                       # default hostname
.\New-VM.ps1 -VMName myhost
```

Start from Hyper-V Manager. Installer runs unattended via
`autounattend.xml` (~15 min).

## Update

Auto-logon to `User` / `password` on first boot (change forced next
login). Elevated PowerShell:

```powershell
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/virtual/guest.windows.11/windows.11.update.ps1$nc" | iex
Restart-Computer
```

`$env:YurunaCacheContent` / `setx`: see
[../../../docs/caching.md](../../../docs/caching.md).

## Next

[Windows 11 workloads](../../guest.windows.11/README.md) ·
[read.more.md](read.more.md)
