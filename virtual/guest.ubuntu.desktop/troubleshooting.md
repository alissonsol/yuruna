# Ubuntu Desktop Troubleshooting

## Boot issues

- Check `/var/log/installer/installer-journal.txt` for hints.
- If the "Install Ubuntu" screen appears stuck:
  - `Ctrl+Alt+F2` (or `F3`) to switch to a TTY.
  - Check `/var/log/installer` or `/var/log/cloud-init.log` for `Error` or `Failed to load` — these usually point at the offending config line.

## GUI Locks and Does Not Accept the Password

- Update the system:
  - `Ctrl+Alt+T` (or `Ctrl+Alt+F3`) for a terminal.
  - `sudo bash /ubuntu.desktop.update.sh` (run two or three times until no updates or cleanup remain).
  - `sudo reboot now`.
- If still stuck:
  - `sudo apt update && sudo apt install --reinstall xserver-xorg-input-all && sudo reboot now`

## Settings Not Available in the GUI

```bash
sudo apt update && sudo apt install --reinstall -y gnome-control-center
```

## Time Zone Incorrect

Auto-detected at install via IP geolocation; "Automatic Time Zone"
enabled via dconf defaults. If still wrong (no network or geolocation
API unavailable), open Settings (right-click desktop → Display Settings)
→ System → Date & Time → set the zone or confirm "Automatic Time Zone".

Back to [[Ubuntu Desktop Guest - Workloads](README.md)]
