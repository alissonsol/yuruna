# Amazon Linux 2023 guest on macOS UTM host

> Common setup pattern: see [Guest Image Setup](../../../docs/guest-image-setup.md).
> This file documents only what's HOST/GUEST-specific.

Minimal commands. Walk-through: [Amazon Linux 2023 guest on macOS UTM host — Nerd-Level Details](read.more.md). Cross-host
concepts: [Hosts — ...](../../README.md).

## One-time

From `yuruna/host/macos.utm/guest.amazon.linux.2023` (do not `sudo`):

```
pwsh ./Get-Image.ps1
```

## For each VM

```
pwsh ./New-VM.ps1                   # default hostname
pwsh ./New-VM.ps1 -VMName myhost
```

Double-click `HOSTNAME.utm` in `~/yuruna/guest.nosync/` to
import and start. Cloud-init sets hostname, default user, and password
on first boot. The Display tab shows a text console until a GUI is
installed.

## First login and GUI install

Test sequences log in as the per-guest test user (`yauser1` for
amazon.linux.2023; the name is set in
[test/sequences/start.guest.amazon.linux.2023.yml](../../../test/sequences/start.guest.amazon.linux.2023.yml)
and mirrored as the `-Username` default of `New-VM.ps1`). cloud-init
creates it on top of the cloud-image default `ec2-user`. The password
is managed by the authentication extension (per-cycle vault.yml at
`test/status/extension/authentication/vault.yml`, code under
[test/extension/authentication/](../../../test/extension/authentication/));
cloud-init's chpasswd default `expire: true` triggers the
Current/New/Retype rotation on first console login.

```
sudo /usr/local/lib/yuruna/fetch-and-execute.sh guest/amazon.linux.2023/amazon.linux.2023.update.sh
sudo dnf groupinstall -y "Desktop"
sudo shutdown now
```

Good moment to clone the VM in UTM and keep a stable copy aside.

## Next

[Amazon Linux 2023 workloads](../../../guest/amazon.linux.2023/README.md)

Read more: [Amazon Linux 2023 guest on macOS UTM host — Nerd-Level Details](read.more.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.22

Back to [Yuruna](../../../README.md)
