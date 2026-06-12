# Windows 11 guest on Windows Hyper-V host

> Common setup pattern: see [Guest Image Setup](../../../docs/guest-image-setup.md).
> This file documents only what's HOST/GUEST-specific.

Minimal commands. Walk-through: [Windows 11 guest on Windows Hyper-V host — Nerd-Level Details](read.more.md). Cross-host
concepts: [Hosts — ...](../../README.md).

## One-time

From `yuruna\host\windows.hyper-v\guest.windows.11` in an
elevated PowerShell:

```
.\Get-Image.ps1
```

Automates the Windows 11 ISO download from
[Microsoft](https://www.microsoft.com/software-download/windows11);
prints manual instructions if blocked.

## For each VM

```
.\New-VM.ps1                       # default hostname
.\New-VM.ps1 -VMName myhost
```

Start from Hyper-V Manager. Installer runs unattended via
`autounattend.xml` (~15 min).

## Update

Auto-logon to `User` / `password` on first boot (change forced next
login). Elevated PowerShell:

```
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/guest/windows.11/windows.11.update.ps1$nc" | iex
Restart-Computer
```

`$env:YurunaCacheContent` / `setx`: see
[Caching](../../../docs/caching.md).

## Next

[Windows 11 workloads](../../../guest/windows.11/README.md)

Read more: [Windows 11 guest on Windows Hyper-V host — Nerd-Level Details](read.more.md).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.12

Back to [Yuruna](../../../README.md)
