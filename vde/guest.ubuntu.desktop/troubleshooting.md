# Ubuntu Desktop Troubleshooting

## Boot issues

- Check the logs under `/var/log/installer`. Usually, `installer-journal.txt` has good hints toward the problem.

## GUI Locks and Does Not Accept the Password

- Update the system:
  - Press `Ctrl+Alt+T` (or `Ctrl+Alt+F3`). This brings up a terminal.
  - Run the command: `sudo bash /ubuntu.desktop.update.sh`
    - Run two or three times, until there are no updates or cleanup remaining.
  - Run `sudo reboot now`.
- Usually, this solves the issue.
- In a few cases, the following was also needed:
  - `sudo apt update`
  - `sudo apt install --reinstall xserver-xorg-input-all`
  - `sudo reboot now`

## Settings Not Available in the GUI

- This happens at times and requires installing the control center from the command line:

```bash
sudo apt update && sudo apt install --reinstall -y gnome-control-center
```

## Time Zone Incorrect

- The timezone is auto-detected during installation via IP geolocation and GNOME's "Automatic Time Zone" is enabled via dconf defaults.
- If the timezone is still incorrect after boot, GNOME's geolocation service may not be working (e.g., no network or geolocation API unavailable). To fix manually:
  - Bring up the Settings control center.
    - An easy way is to right-click on any open area on the desktop and select "Display Settings".
  - Navigate to "System" (you may need to scroll down in the left pane) and then select "Date & Time".
  - Select the correct time zone, or verify "Automatic Time Zone" is enabled.

Back to [[Ubuntu Desktop Guest - Workloads](README.md)]
