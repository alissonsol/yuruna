# Windows Hyper-V Host Setup - Nerd-Level Details

The one-line installer in [Windows Hyper-V ...](README.md) automates the steps
below. This walk-through reproduces them by hand for audit / learning.
Every step needs an **elevated** PowerShell (Run as Administrator).

## 1) Install PowerShell 7

Yuruna scripts target PowerShell 7 (`pwsh`), not the legacy
`powershell.exe`. See the
[installation guide](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows)
or install via `winget`:

```
winget install --id Microsoft.PowerShell --exact --silent `
    --accept-package-agreements --accept-source-agreements
```

Verify: `Get-Host | Select-Object Version`.

## 2) Install Git

```
winget install --id Git.Git --exact --silent `
    --accept-package-agreements --accept-source-agreements
```

## 3) Install the Windows ADK Deployment Tools

The harness uses `oscdimg.exe` (from the Windows ADK **Deployment
Tools** feature) to build unattended-install seed ISOs.

Option A -- `winget`:

```
winget install --id Microsoft.WindowsADK --exact --silent `
    --accept-package-agreements --accept-source-agreements
```

Option B -- run the
[Windows ADK installer](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
and select only **Deployment Tools**.

## 4) Install QEMU tools

Hyper-V boots VHDX and the Ubuntu Server cloud image ships as qcow2, so every
extension-service `Get-Image.ps1` -- `guest.caching-proxy-service`,
`guest.stash-service`, `guest.pool-control-service`,
`guest.download-agent-service` -- uses `qemu-img.exe` to convert the shared base
image, on AMD64 and ARM64 alike. On an ARM64 host
`guest.amazon.linux.2023/Get-Image.ps1` uses it too: the publisher offers no
ARM64 Hyper-V image, so that guest starts from the ARM64 KVM cloud image and
is converted here. The Ubuntu Server and Windows 11 guests install from vendor
ISOs and need no conversion.

```
winget install --id SoftwareFreedomConservancy.QEMU --exact --silent `
    --accept-package-agreements --accept-source-agreements
```

## 5) Install Tesseract OCR

OCR for [Test.Tesseract.psm1](../../test/modules/Test.Tesseract.psm1):

```
winget install --id UB-Mannheim.TesseractOCR --exact --silent `
    --accept-package-agreements --accept-source-agreements
```

## 6) Enable Hyper-V

```
Enable-WindowsOptionalFeature -Online `
    -FeatureName Microsoft-Hyper-V-All -NoRestart
```

If Hyper-V was just enabled, **restart Windows** before continuing --
`Get-VM`/`New-VM` and friends fail until the reboot completes.
`Microsoft-Hyper-V-All` is unavailable on Windows Home; the harness
requires Pro, Enterprise, or Education.

## 7) Clone the Yuruna Repository

```
New-Item -ItemType Directory -Path $HOME\git -Force | Out-Null
git clone https://github.com/alissonsol/yuruna.git $HOME\git\yuruna
```

## 8) Refresh PATH in the Current Shell

`winget` updates machine `PATH`, but the current session keeps the old
copy. Open a new PowerShell window, or patch this one:

```
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')
```

Confirm:

```
pwsh -Version
git --version
```

Neither `oscdimg` nor `qemu-img` joins `PATH` -- the ADK ships a
`DandISetEnv.bat` to set one up on demand, and the QEMU installer registers
nothing at all. Both are resolved by absolute path, so a by-name check reports
them missing on a correctly provisioned machine. Confirm them the way the
harness finds them:

```
Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\*\Oscdimg\Oscdimg.exe"
Test-Path "$env:ProgramFiles\qemu\qemu-img.exe"
```

The ADK installs Oscdimg once per architecture (`amd64`, `arm64`, `x86`);
the harness picks the one native to this host.

## 9) Seed the Test Config

```
cd $HOME\git\yuruna\test
Copy-Item .\test.config.yml.template .\test.config.yml
notepad .\test.config.yml
```

## 10) Disable Display Timeout and Screen Lock

When the display blanks, Hyper-V captures return black and OCR fails.
The helper disables display timeout (AC and DC), inactivity lock, and
lock-screen-on-resume via `powercfg` and registry edits:

```
cd $HOME\git\yuruna\host\windows.hyper-v
pwsh .\Enable-TestAutomation.ps1
```

`-WhatIf` previews changes. Idempotent; requires elevation.

## 11) First Launch of Hyper-V Manager

```
Start-Process virtmgmt.msc      # registers with the user profile
```

## 12) Optional: Squid cache VM

See [Hosts -- ...](../README.md#optional-squid-cache-vm) and
[Caching](../../docs/caching.md).

## 13) Run the Test Harness

```
pwsh $HOME\git\yuruna\test\Start-TestRunner.ps1
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.01

Back to [Yuruna](../../README.md)
