# Windows 11 guest on Windows Hyper-V host -- Nerd-Level Details

See [Hosts -- ...](../../README.md) for host prerequisites (Hyper-V, ADK
Deployment Tools for `oscdimg.exe`), VM sizing, and connectivity.

## 1) Get the image

The Windows 11 ISO has no stable direct download URL.
[`Get-Image.ps1`](./Get-Image.ps1) first tries an automated download; if that fails, it prints instructions to download from
[Microsoft](https://www.microsoft.com/software-download/windows11) into
the Hyper-V default VHDX folder; any `Win11*.iso` there is renamed
automatically. Microsoft publishes the two architectures on separate
pages under different edition labels, so on an ARM64 host the script
prints the ARM64 page and its choices instead -- the file name it saves
to is the same either way.

```
.\Get-Image.ps1
```

## 2) Create the VM

[`New-VM.ps1`](./New-VM.ps1) creates a Gen 2 VM (12 GB RAM, max(4, host
cores / 2) virtual processors (nested virtualization is opt-in), UEFI + Secure
Boot with the Microsoft Windows template, Yuruna-External vSwitch when
available -- falls back to Default Switch, virtual TPM), mounts the
Windows ISO and autounattend seed ISO as DVDs, sets DVD as first boot,
and enables Guest Service Interface. It then starts the VM and sends Space
directly to its virtual keyboard during the initial DVD boot prompt. No
manual keypress or test runner is required. Open VMConnect to view the install.

```
.\New-VM.ps1                   # default hostname windows11-01
.\New-VM.ps1 -VMName myhost
```

The autounattend sets locale `en-US`, keyboard `en-US`, UEFI/GPT, and
enables Remote Desktop. Default credentials: `ywuser1` / `password`
(auto-logon first boot only). Generic Windows 11 Pro key -- see
[Windows 11 ...](./vmconfig/README.md) for KMS keys and activation.

## Known limitations

- If automatic ISO download fails, download it manually.
- Remove the DVD drives after install.
- VM is unactivated until a key is provided.
- Enhanced Session Mode is disabled by Yuruna to force VMConnect basic mode, which prevents interactive resolution dialogs during automated testing.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.14

Back to [Yuruna](../../../README.md)
