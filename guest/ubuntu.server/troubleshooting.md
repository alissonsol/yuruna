# Ubuntu Server Troubleshooting

## Boot issues

- Check `/var/log/installer/installer-journal.txt` for hints.
- If the text-mode installer appears stuck:
  - `Ctrl+Alt+F2` (or `F3`) to switch to a TTY.
  - Check `/var/log/installer` or `/var/log/cloud-init.log` for `Error` or `Failed to load` — these usually point at the offending config line.

## Console Login Not Accepting the Password

- `Ctrl+Alt+F3` for an alternate TTY.
- `sudo bash /ubuntu.server.update.sh` (run two or three times until no updates or cleanup remain).
- `sudo reboot now`.

## Time Zone Incorrect

Auto-detected at install via IP geolocation (cloud-init). To set
manually:

```bash
timedatectl list-timezones | grep <region>
sudo timedatectl set-timezone America/Los_Angeles
timedatectl                       # verify
```

Back to [[Ubuntu Server Guest - Workloads](README.md)]
