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
