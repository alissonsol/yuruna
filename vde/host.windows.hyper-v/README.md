# Windows Hyper-V Host Setup

One-time setup instructions for preparing a Windows host with Hyper-V.

## Install Required Tools

- Install [PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell-on-windows) if not already installed. 
  - This documentation was tested with version 7.5.4.
  - Check your version with the command `Get-Host | Select-Object Version`.

- Install [Windows ADK Deployment Tools](https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install) for `Oscdimg.exe` (needed to create seed ISO).
  - During installation, select only "Deployment Tools".

## Enable Hyper-V

Enable Hyper-V from Windows Features or run in an elevated PowerShell:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -NoRestart
```

If it was not enabled already, it is recommended to restart Windows after enabling Hyper-V.

## Install Selenium (for Windows 11 ISO Download)

The Windows 11 guest requires an automated browser to download the ISO from Microsoft. Run this once (and re-run to update after Edge updates):

```powershell
.\Get-Selenium.ps1
```

This installs the Selenium PowerShell module and downloads the Edge WebDriver matching your installed Edge version.

## Next: Create a Guest VM

After completing the host setup, follow the instructions for your guest operating system:

- [Amazon Linux](guest.amazon.linux/README.md)
- [Ubuntu Desktop](guest.ubuntu.desktop/README.md)
- [Windows 11](guest.windows.11/README.md)

## Troubleshooting

If you run into problems, see [common issues and solutions](troubleshooting.md).

Back to [[Yuruna](../../README.md)]
