# Ubuntu Server Troubleshooting

## Boot issues

- Check the logs under `/var/log/installer`. Usually, `installer-journal.txt` has good hints toward the problem.
- If the text-mode installer appears stuck:
  - Press `Ctrl+Alt+F2` (or `F3`) to switch to a TTY terminal.
  - Check the logs at `/var/log/installer` or `/var/log/cloud-init.log`.
  - Look for `Error` or `Failed to load` messages—they will usually tell you exactly which line of your config file it didn't like.

## Console Login Not Accepting the Password

- Update the system:
  - Press `Ctrl+Alt+F3` to bring up an alternate TTY.
  - Run the command: `sudo bash /ubuntu.server.update.sh`
    - Run two or three times, until there are no updates or cleanup remaining.
  - Run `sudo reboot now`.
- Usually, this solves the issue.

## Time Zone Incorrect

- The time zone is auto-detected during installation via IP geolocation (cloud-init).
- If the time zone is still incorrect after boot, set it manually with `timedatectl`:
  - List available zones: `timedatectl list-timezones | grep <region>`
  - Set the zone: `sudo timedatectl set-timezone America/Los_Angeles`
  - Verify: `timedatectl`

Back to [[Ubuntu Server Guest - Workloads](README.md)]
