# Ubuntu Server 26.04 on Ubuntu KVM/libvirt

> Common setup pattern: see [Guest Image Setup](../../../docs/guest-image-setup.md).
> This file documents only what's HOST/GUEST-specific.

Boots the Ubuntu Server 26.04 live-server ISO and runs subiquity
autoinstall against a CIDATA seed CD. Same boot sequence as the
Hyper-V and macOS UTM variants:
GRUB -> "Continue with autoinstall?" -> unattended install -> reboot
-> text-mode login at `yuuser26` / `<vault-managed>` (password expired on
first login). Architecture (amd64 / arm64) is picked from the host.

Cross-host concepts: [Hosts -- ...](../../README.md).

## One-time

```
pwsh ./Get-Image.ps1                        # download / refresh live-server ISO
```

## For each VM

```
pwsh ./New-VM.ps1                           # default name: ubuntu-server01
pwsh ./New-VM.ps1 -VMName myhost            # custom name
pwsh ./New-VM.ps1 -CachingProxyServiceUrl http://192.168.122.10:3128
```

`New-VM.ps1` renders the shared cloud-init base and overlay, builds a
CIDATA seed ISO, creates the install target, and defines the domain via
`virt-install`. Read the script for the steps and the defaults it applies:
restating them here only guarantees they drift, and the overrides that are
not parameters cannot be documented as anything but "edit the script".

The first-boot password is managed by the authentication extension
(code at [`test/extension/authentication/`](../../../test/extension/authentication/),
per-cycle vault.yml at `test/status/extension/authentication/vault.yml`;
see [Test Runner -- Nerd-Level Details](../../../test/read.more.md) for the
model). The autoinstall late-commands expire it, so the first
interactive login asks for current/new/retype before yielding a shell.
For ad-hoc dev runs outside a cycle, set `$env:YURUNA_GUEST_PASSWORD`
to bypass the vault and use a known plaintext value.

## Reaching the guest

```
virsh -c qemu:///system list                         # confirm running
virsh -c qemu:///system domifaddr <vmname>           # discover the IP
ssh -i ../../../test/status/ssh/yuruna_ed25519 yuuser26@<ip>
virt-viewer --connect qemu:///system <vmname>        # graphical console
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.19

Back to [Yuruna](../../../README.md)
