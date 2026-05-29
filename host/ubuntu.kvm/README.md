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
same script, but `bash <(curl ...)` keeps the script as a real file
argument for bash, which sidesteps a stdin/sudo-prompt edge case some
Ubuntu terminals trip on.)

Installs `qemu-kvm`, `libvirt-daemon-system`, `virtinst`, `swtpm`,
`ovmf` (or `qemu-efi-aarch64`), `genisoimage`, `whois`, `git`, `pwsh`,
and `tesseract-ocr`; clones the repo to `~/git/yuruna`; enables
`libvirtd` + `virtlogd`; sets the libvirt `default` network to
autostart; adds `$USER` to the `libvirt` and `kvm` groups; seeds
`test/test.config.yml`. Idempotent; prompts for your sudo password
once.

After group membership changes the operator must log out and back in
(or `newgrp libvirt`) before `virsh` and `virt-install` work without
sudo.

Disabling display sleep / screen lock for unattended runs is a
separate opt-in step — run
[`Enable-TestAutomation.ps1`](Enable-TestAutomation.ps1) manually after
install.

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

Back to [Hosts](../README.md) · [Yuruna](../../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
