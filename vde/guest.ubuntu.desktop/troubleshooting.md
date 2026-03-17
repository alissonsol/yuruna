# Ubuntu Desktop Troubleshooting

## GUI Locks and Does Not Accept the Password

- Update the system:
  - Press `Ctrl+Alt+T` (or `Ctrl+Alt+F3`). This brings up a terminal.
  - Run the command: `sudo bash /ubuntu.desktop.update.bash`
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

- Bring up the Settings control center.
  - An easy way is to right-click on any open area on the desktop and select "Display Settings".
- Navigate to "System" (you may need to scroll down in the left pane) and then select "Date & Time".
- Select the correct time zone, or enable "Automatic Time Zone" (which may not work depending on the network configuration).
