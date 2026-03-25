# Windows 11 Troubleshooting

## winget Not Available

If `winget` is not available after a fresh Windows 11 install, it may need to be updated from the Microsoft Store:

1. Open **Microsoft Store** from the Start menu.
2. Search for **App Installer** and update it.
3. Restart the terminal.

Alternatively, install it manually:

```powershell
Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
```

## Scripts Blocked by Execution Policy

If PowerShell scripts are blocked, set the execution policy:

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

## Docker Desktop Requires Restart

Docker Desktop requires a system restart after installation. If `docker` commands fail:

1. Restart the computer.
2. Launch Docker Desktop from the Start menu.
3. Wait for Docker to finish starting (systray icon stops animating).

## Kubernetes Not Available in Docker Desktop

1. Open Docker Desktop.
2. Go to **Settings** > **Kubernetes**.
3. Check **Enable Kubernetes**.
4. Click **Apply & restart**.

## Time Zone Incorrect

1. Open **Settings** > **Time & Language** > **Date & time**.
2. Enable **Set time zone automatically** or select the correct time zone manually.

## Windows Activation

The VM is installed with a generic key and will be in an unactivated state. To activate:

```powershell
# Install your purchased key
slmgr /ipk XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
# Activate online
slmgr /ato
```

See [vmconfig/README.md](../host.windows.hyper-v/guest.windows.11/vmconfig/README.md) for more details on product keys.

Back to [[Windows 11 Guest - Workloads](README.md)]
