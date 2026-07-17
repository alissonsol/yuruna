# Guest troubleshooting

Per-guest-OS troubleshooting notes. Host-side issues live in the host
docs: [Windows Hyper-V](host-hyperv.md) · [macOS UTM](host-macos.md).

## Amazon Linux 2023

### "Display Output Is Not Active"

- Confirm a GUI is installed.
- Amazon Linux's first boot (especially on macOS UTM) has only an attached terminal — switch to that window to log in.

## Ubuntu Server

Shared troubleshooting for the Ubuntu Server guests (24.04, 26.04, …).
Substitute your release (`24`, `26`, …) for `<release>` in the paths
below — e.g. the 24.04 fetch-and-execute paths use
`guest/ubuntu.server.24/…` (`ubuntu.server.24.update.sh`).

### Boot Issues

- Check `/var/log/installer/installer-journal.txt` for hints.
- If the text-mode installer appears stuck:
  - `Ctrl+Alt+F2` (or `F3`) to switch to a TTY.
  - Check `/var/log/installer` or `/var/log/cloud-init.log` for `Error` or `Failed to load` — these usually point at the offending config line.

### Console Login Not Accepting the Password

- `Ctrl+Alt+F3` for an alternate TTY.
- `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.<release>/ubuntu.server.<release>.update.sh` (run two or three times until no updates or cleanup remain).
- `sudo reboot now`.

### Time Zone Incorrect

Auto-detected at install via IP geolocation (cloud-init). To set
manually:

```
timedatectl list-timezones | grep <region>
sudo timedatectl set-timezone America/Los_Angeles
timedatectl                       # verify
```

## Windows 11

### winget Not Available

After a fresh install, update **App Installer** in Microsoft Store and restart the terminal. Alternatively:

```
Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
```

### Scripts Blocked by Execution Policy

```
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

### Docker Desktop Requires Restart

If `docker` commands fail after install: restart the computer, launch Docker Desktop, wait for the systray icon to stop animating.

### Kubernetes Not Available in Docker Desktop

Docker Desktop → **Settings** → **Kubernetes** → check **Enable Kubernetes** → **Apply & restart**.

### Time Zone Incorrect

**Settings** → **Time & Language** → **Date & time**. Enable **Set time zone automatically** or pick one manually.

### Windows Activation

The VM is installed with a generic key (unactivated). Activate:

```
slmgr /ipk XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
slmgr /ato
```

Product keys: [Windows 11 ...](../host/windows.hyper-v/guest.windows.11/vmconfig/README.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.17

Back to [Yuruna](../README.md)
