# Windows Hyper-V Host Setup - Nerd-Level Details

Copyright (c) 2019-2026 by Alisson Sol et al.

The one-line installer in [README.md](README.md) automates everything
below. This document walks through the same steps by hand, for those
who want to understand (or audit) what gets changed on their machine.

Every step here requires an **elevated** PowerShell session (Run as
Administrator). The Yuruna one-line installer self-relaunches
elevated via a single UAC prompt; when going manual, start an
Administrator PowerShell window up front.

## 1) Install PowerShell 7

Yuruna's scripts target PowerShell 7 (`pwsh`), not the legacy
`powershell.exe` that ships with Windows. See the official
[installation guide](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows)
or install via `winget`:

```powershell
winget install --id Microsoft.PowerShell --exact --silent `
    --accept-package-agreements --accept-source-agreements
```

- This documentation was tested with version 7.5.4.
- Check your version with `Get-Host | Select-Object Version`.

## 2) Install Git

```powershell
winget install --id Git.Git --exact --silent `
    --accept-package-agreements --accept-source-agreements
```

## 3) Install the Windows ADK Deployment Tools

The harness uses `oscdimg.exe` to build unattended-install seed ISOs
for guest VMs. `oscdimg.exe` ships only as part of the Windows
Assessment and Deployment Kit — you need the **Deployment Tools**
feature specifically.

Option A — `winget`:

```powershell
winget install --id Microsoft.WindowsADK --exact --silent `
    --accept-package-agreements --accept-source-agreements
```

Option B — manual:
Download and run the
[Windows ADK installer](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
and, when it asks which features to install, tick only
**Deployment Tools**.

## 4) Install Tesseract OCR

Tesseract is used by
[Test.Tesseract.psm1](../../test/modules/Test.Tesseract.psm1) for
OCR-based verification steps in some sequences.

```powershell
winget install --id UB-Mannheim.TesseractOCR --exact --silent `
    --accept-package-agreements --accept-source-agreements
```

## 5) Enable Hyper-V

```powershell
Enable-WindowsOptionalFeature -Online `
    -FeatureName Microsoft-Hyper-V-All -NoRestart
```

If Hyper-V was not already enabled, **restart Windows** before
continuing. Hyper-V cmdlets (`Get-VM`, `New-VM`, etc.) will fail
until the reboot completes.

Note: `Microsoft-Hyper-V-All` is not available on Windows Home
editions. Yuruna's Hyper-V harness requires Pro, Enterprise, or
Education.

## 6) Clone the Yuruna Repository

```powershell
New-Item -ItemType Directory -Path $HOME\git -Force | Out-Null
git clone https://github.com/alissonsol/yuruna.git $HOME\git\yuruna
```

## 7) Refresh PATH in the Current Shell

Freshly installed `winget` packages are added to the machine `PATH`,
but your current PowerShell session still has a copy of the old
environment. Either open a new PowerShell window, or patch the
current one:

```powershell
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')
```

Confirm everything is visible:

```powershell
pwsh -Version
git --version
oscdimg -h 2>&1 | Select-Object -First 1
```

## 8) Seed the Test Config

```powershell
cd $HOME\git\yuruna\test
Copy-Item .\test-config.json.template .\test-config.json
notepad .\test-config.json
```

Review the guests list and any host-specific paths before running
the test harness.

## 9) Disable Display Timeout and Screen Lock

When the display blanks, Hyper-V screen captures return a black
image and OCR verification fails. The repo ships a PowerShell
helper that disables display timeout (AC and DC), the machine
inactivity lock, and lock-screen-on-resume via `powercfg` and
registry edits:

```powershell
cd $HOME\git\yuruna\test
pwsh .\Set-WindowsHostConditionSet.ps1
```

Use `-WhatIf` first to preview changes. The script is idempotent
and requires Administrator elevation.

## 10) First Launch of Hyper-V Manager

Open Hyper-V Manager once by hand so it can register with your user
profile and surface any first-run dialogs:

```powershell
Start-Process virtmgmt.msc
```

## 11) Optional: Set up the local apt cache VM

Each Ubuntu Desktop install downloads ~900 MB of packages from
Ubuntu's CDN. When the test harness runs cycles back-to-back, the
CDN may rate-limit requests (HTTP 429), causing the install to fail.
A local `apt-cacher-ng` VM caches everything after the first
download, cutting subsequent installs to ~2 minutes and eliminating
rate-limit failures.

This step is optional — skip it if you prefer direct CDN downloads.

```powershell
cd $HOME\git\yuruna\vde\host.windows.hyper-v\guest.apt-cache
pwsh .\Get-Image.ps1    # downloads Ubuntu Server cloud image
pwsh .\New-VM.ps1        # creates + starts the cache VM
```

The Ubuntu Desktop `New-VM.ps1` detects the running cache VM
automatically. See
[guest.apt-cache/README.md](guest.apt-cache/README.md) for details.

## 12) Run the Test Harness

```powershell
cd $HOME\git\yuruna\test
pwsh .\Invoke-TestRunner.ps1
```

## Next: Create a Guest VM

After completing the host setup, follow the instructions for your
guest operating system:

- [Amazon Linux](guest.amazon.linux/README.md)
- [Ubuntu Desktop](guest.ubuntu.desktop/README.md)
- [Windows 11](guest.windows.11/README.md)

## Troubleshooting

If you run into problems, see [common issues and solutions](troubleshooting.md).

Back to [[Windows Hyper-V Host Setup](README.md)] · [[Yuruna](../../README.md)]
