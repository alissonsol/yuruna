# Windows 11 guest — troubleshooting

## winget Not Available

After a fresh install, update **App Installer** in Microsoft Store and restart the terminal. Alternatively:

```
Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
```

## Scripts Blocked by Execution Policy

```
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

```
slmgr /ipk XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
slmgr /ato
```

Product keys: [Windows 11 ...](../host/windows.hyper-v/guest.windows.11/vmconfig/README.md).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.26

Back to [Yuruna](../README.md)
