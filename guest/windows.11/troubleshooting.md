# Windows 11 Troubleshooting

## winget Not Available

After a fresh install, update **App Installer** in Microsoft Store and restart the terminal. Alternatively:

```powershell
Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
```

## Scripts Blocked by Execution Policy

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

## Docker Desktop Requires Restart

If `docker` commands fail after install: restart the computer, launch Docker Desktop, wait for the systray icon to stop animating.

## Kubernetes Not Available in Docker Desktop

Docker Desktop → **Settings** → **Kubernetes** → check **Enable Kubernetes** → **Apply & restart**.

## Time Zone Incorrect

**Settings** → **Time & Language** → **Date & time**. Enable **Set time zone automatically** or pick one manually.

## Windows Activation

The VM is installed with a generic key (unactivated). Activate:

```powershell
slmgr /ipk XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
slmgr /ato
```

Product keys: [vmconfig/README.md](../host.windows.hyper-v/guest.windows.11/vmconfig/README.md).

Back to [[Windows 11 Guest - Workloads](README.md)]
