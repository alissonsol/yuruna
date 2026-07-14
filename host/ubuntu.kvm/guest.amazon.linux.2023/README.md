# Amazon Linux 2023 on Ubuntu KVM/libvirt

> Common setup pattern: see [Guest Image Setup](../../../docs/guest-image-setup.md).
> This file documents only what's HOST/GUEST-specific.

Boots the AL2023 KVM cloud image (`kvm` on x86_64, `kvm-arm64` on
aarch64) with a cloud-init NoCloud seed.

## Manual run

```
pwsh ./Get-Image.ps1                        # download / refresh base image
pwsh ./New-VM.ps1                           # default name: amazon-linux01
pwsh ./New-VM.ps1 -VMName myhost            # custom name
```

`New-VM.ps1` clones the qcow2 cloud image as a backing-file disk under
`~/yuruna/vms/<vmname>/`, builds a NoCloud seed ISO from `vmconfig/`,
and defines the VM via `virt-install --import` against `qemu:///system`.

## Defaults

| Knob | Default |
|------|---------|
| Name | `amazon-linux01` |
| RAM  | 4 GiB |
| vCPU | 2 |
| Disk | 16 G qcow2 backed by base |
| User | `yauser1` (test sequence target, see [test/sequences/gui/start.guest.amazon.linux.2023.yml](../../../test/sequences/gui/start.guest.amazon.linux.2023.yml)) and `ec2-user` (cloud-image default; SSH key-auth) |
| Net  | libvirt `default` (NAT 192.168.122.0/24) |

The password is managed by the authentication extension (per-cycle vault.yml at `test/status/extension/authentication/vault.yml`, code under [test/extension/authentication/](../../../test/extension/authentication/));
cloud-init's chpasswd default `expire: true` triggers the
Current/New/Retype rotation on first console login.

## Reaching the guest

```
virsh -c qemu:///system domifaddr <vmname>
ssh -i ../../../test/status/ssh/yuruna_ed25519 yauser1@<ip>
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.14

Back to [Yuruna](../../../README.md)
