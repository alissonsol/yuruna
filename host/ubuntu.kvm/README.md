# Ubuntu KVM/libvirt Host Setup

One-time setup for an Ubuntu host running KVM via libvirt. Cross-host
concepts (install-one-liner convention, post-install steps, optional
Squid cache VM, guest workload pattern) live in
[Hosts — ...](../README.md).

## Quick install (one line)

From a fresh **terminal** on Ubuntu 22.04+:

```
bash <(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh)
```

(Process substitution rather than `bash -c "$(curl ...)"`. Both reach the
same script, but `bash <(curl ...)` passes it as a real file argument,
sidestepping a stdin/sudo-prompt edge case some Ubuntu terminals trip
on.)

Installs `qemu-system-x86` / `qemu-system-arm` (per arch) + `qemu-utils`,
`libvirt-daemon-system`, `virtinst`, `swtpm`,
`ovmf` (or `qemu-efi-aarch64`), `genisoimage`, `whois`, `git`, `pwsh`,
`tesseract-ocr`, and `virt-manager`; clones the repo to `~/git/yuruna`; enables
`libvirtd` + `virtlogd`; sets the libvirt `default` network to
autostart; adds `$USER` to the `libvirt` and `kvm` groups; seeds
`test/test.config.yml`. Idempotent; prompts for your sudo password
once.

After the group membership change, log out and back in (or
`newgrp libvirt`) before `virsh` and `virt-install` work without sudo.

Disabling display sleep / screen lock for unattended runs is a
separate opt-in step — run
[`Enable-TestAutomation.ps1`](Enable-TestAutomation.ps1) manually after
install, or let `pwsh install/setup.ps1` do it as one step of a guided
[standalone-host or lab setup](../../install/README.md#guided-setup).

## Architecture support

| Guest          | x86_64 | aarch64 |
|----------------|--------|---------|
| Ubuntu Server 24.04 | Yes    | Yes |
| Ubuntu Server 26.04 | Yes    | Yes |
| Amazon Linux 2023   | Yes    | Yes |
| Windows 11     | Yes    | No (use macOS UTM) |

## Next: Create a Guest VM

- [Amazon Linux 2023](guest.amazon.linux.2023/README.md)
- [Ubuntu Server 24.04](guest.ubuntu.server.24/README.md)
- [Ubuntu Server 26.04](guest.ubuntu.server.26/README.md)
- [Windows 11](guest.windows.11/README.md)

## Installing the Ubuntu Host

The really short guide. A self-serving memory!

- Download the latest [Ubuntu Server](https://ubuntu.com/download/server).
- Create a bootable USB, with tools like [Rufus](https://rufus.ie).
- Install Ubuntu Server. Create a "test account" as the local admin, not a real person's account.
- Log in and update.
  - `sudo apt update`
  - `sudo apt upgrade -y`
- Install the desktop.
  - `sudo apt install -y ubuntu-desktop`
  - `sudo reboot now`

Run the update commands again now that the desktop packages are in place.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.05

Back to [Yuruna](../../README.md)
