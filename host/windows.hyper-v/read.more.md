# Windows Hyper-V Host Setup - Nerd-Level Details

The one-line installer in [README.md](README.md) automates the steps
below. This walk-through reproduces them by hand for audit / learning.
Every step needs an **elevated** PowerShell (Run as Administrator).

## 1) Install PowerShell 7

Yuruna scripts target PowerShell 7 (`pwsh`), not the legacy
`powershell.exe`. See the official
[installation guide](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows)
or install via `winget`:

```powershell
winget install --id Microsoft.PowerShell --exact --silent `
    --accept-package-agreements --accept-source-agreements
```

Tested with 7.5.4. Verify: `Get-Host | Select-Object Version`.

## 2) Install Git

```powershell
winget install --id Git.Git --exact --silent `
    --accept-package-agreements --accept-source-agreements
```

## 3) Install the Windows ADK Deployment Tools

The harness uses `oscdimg.exe` (from the Windows ADK **Deployment
Tools** feature) to build unattended-install seed ISOs.

Option A — `winget`:

```powershell
winget install --id Microsoft.WindowsADK --exact --silent `
    --accept-package-agreements --accept-source-agreements
```

Option B — run the
[Windows ADK installer](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install)
and select only **Deployment Tools**.

## 4) Install Tesseract OCR

OCR for [Test.Tesseract.psm1](../../test/modules/Test.Tesseract.psm1):

```powershell
winget install --id UB-Mannheim.TesseractOCR --exact --silent `
    --accept-package-agreements --accept-source-agreements
```

## 5) Enable Hyper-V

```powershell
Enable-WindowsOptionalFeature -Online `
    -FeatureName Microsoft-Hyper-V-All -NoRestart
```

If Hyper-V was just enabled, **restart Windows** before continuing —
`Get-VM`/`New-VM` and friends fail until the reboot completes.
`Microsoft-Hyper-V-All` is unavailable on Windows Home; the harness
requires Pro, Enterprise, or Education.

## 6) Clone the Yuruna Repository

```powershell
New-Item -ItemType Directory -Path $HOME\git -Force | Out-Null
git clone https://github.com/alissonsol/yuruna.git $HOME\git\yuruna
```

## 7) Refresh PATH in the Current Shell

`winget` updates machine `PATH`, but the current session keeps the old
copy. Open a new PowerShell window, or patch the current one:

```powershell
$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path','User')
```

Confirm:

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

## 9) Disable Display Timeout and Screen Lock

When the display blanks, Hyper-V captures return black and OCR fails.
The helper disables display timeout (AC and DC), inactivity lock, and
lock-screen-on-resume via `powercfg` and registry edits:

```powershell
cd $HOME\git\yuruna\host\windows.hyper-v
pwsh .\Enable-TestAutomation.ps1
```

`-WhatIf` previews changes. Idempotent; requires elevation.

## 10) First Launch of Hyper-V Manager

```powershell
Start-Process virtmgmt.msc      # registers with the user profile
```

## 11) Optional: Squid cache VM

See [../README.md](../README.md#optional-squid-cache-vm) and
[../../docs/caching.md](../../docs/caching.md).

## 12) Run the Test Harness

```powershell
pwsh $HOME\git\yuruna\test\Invoke-TestRunner.ps1
```

[Guest VMs](README.md#next-create-a-guest-vm) ·
[Troubleshooting](troubleshooting.md) ·
Back to [[Hyper-V setup](README.md)] · [[Yuruna](../../README.md)]
