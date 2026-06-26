# Ubuntu Server 24.04 on Ubuntu KVM/libvirt

> Common setup pattern: see [Guest Image Setup](../../../docs/guest-image-setup.md).
> This file documents only what's HOST/GUEST-specific.

Boots the Ubuntu Server 24.04 live-server ISO and runs subiquity
autoinstall against a CIDATA seed CD. Same boot sequence as the
Hyper-V and macOS UTM variants:
GRUB -> "Continue with autoinstall?" -> unattended install -> reboot
-> text-mode login at `yuuser24` / `<vault-managed>` (password expired on
first login). Architecture (amd64 / arm64) is picked from the host.

## Manual run

```
pwsh ./Get-Image.ps1                        # download / refresh live-server ISO
pwsh ./New-VM.ps1                           # default name: ubuntu-server01
pwsh ./New-VM.ps1 -VMName myhost            # custom name
pwsh ./New-VM.ps1 -CachingProxyUrl http://192.168.122.10:3128
```

`New-VM.ps1`:

1. Renders the shared `host/vmconfig/ubuntu.server.base.user-data` (+ KVM overlay)
   and `host/vmconfig/ubuntu.server.meta-data` with hostname,
   harness SSH public key (auto-generated under
   `test/status/ssh/yuruna_ed25519` if missing), password hash, optional
   `CachingProxyUrl`, and the host's coordinates for the dev iteration
   loop.
2. Builds a CIDATA seed ISO with `genisoimage`.
3. Creates an empty 32 G qcow2 install target.
4. Defines + starts the VM via `virt-install` against `qemu:///system`,
   booting from the live-server ISO with the seed CD attached. After
   subiquity finishes the install, the VM reboots and lands at the
   text-mode login prompt.

## Defaults

| Knob | Default | Override |
|------|---------|----------|
| Name | `ubuntu-server01` | `-VMName` |
| RAM  | 4 GiB | (edit script) |
| vCPU | 2     | (edit script) |
| Disk | 32 G qcow2 (empty install target) | (edit script) |
| User | `yuuser24` / `<vault-managed>` | `-Username` / `$env:YURUNA_GUEST_PASSWORD` |
| Net  | libvirt `default` (NAT 192.168.122.0/24) | (edit script) |

The first-boot password is managed by the authentication extension
(code at [`test/extension/authentication/`](../../../test/extension/authentication/);
the per-cycle vault.yml is at `test/status/extension/authentication/vault.yml`)
(see [Test Runner — Nerd-Level Details](../../../test/read.more.md) for the model)
and is **expired** by the autoinstall late-commands, so the first
interactive login asks for current/new/retype before yielding a shell.
For ad-hoc dev runs outside a cycle, set `$env:YURUNA_GUEST_PASSWORD`
to bypass the vault and use a known plaintext value.

## Reaching the guest

```
virsh -c qemu:///system list                         # confirm running
virsh -c qemu:///system domifaddr <vmname>           # discover the IP
ssh -i ../../../test/status/ssh/yuruna_ed25519 yuuser24@<ip>
virt-viewer --connect qemu:///system <vmname>        # graphical console
```

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.26

Back to [Yuruna](../../../README.md)
