# Ubuntu Server guest — troubleshooting

Shared troubleshooting for the Ubuntu Server guests. The release-specific
pages — [24.04](guest-ubuntu-24.md) and [26.04](guest-ubuntu-26.md) —
point here; substitute your release (`24`, `26`, …) for `<release>` in the
paths below.

## Boot issues

- Check `/var/log/installer/installer-journal.txt` for hints.
- If the text-mode installer appears stuck:
  - `Ctrl+Alt+F2` (or `F3`) to switch to a TTY.
  - Check `/var/log/installer` or `/var/log/cloud-init.log` for `Error` or `Failed to load` — these usually point at the offending config line.

## Console Login Not Accepting the Password

- `Ctrl+Alt+F3` for an alternate TTY.
- `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.<release>/ubuntu.server.<release>.update.sh` (run two or three times until no updates or cleanup remain).
- `sudo reboot now`.

## Time Zone Incorrect

Auto-detected at install via IP geolocation (cloud-init). To set
manually:

```
timedatectl list-timezones | grep <region>
sudo timedatectl set-timezone America/Los_Angeles
timedatectl                       # verify
```

Back to [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
