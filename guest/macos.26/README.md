# macOS 26 guest

Generic, host-agnostic scripts for a macOS 26 guest. Currently only
[host.macos.utm](../../host/macos.utm/guest.macos.26/) ships an
implementation — macOS guests on Apple Silicon require the Apple
Virtualization framework, so Hyper-V (Windows) and KVM (Linux) hosts
cannot run them.

Hardware floor (enforced by `host/macos.utm/guest.macos.26/New-VM.ps1`):

* Host macOS 15 Sequoia or later (Virtualization.framework macOS-guest
  surface keeps moving — pinning to 15 keeps this script aligned with
  the same `VZMacOSRestoreImage` / `VZMacOSInstaller` API the other
  guests' host scripts already depend on).
* Apple Silicon **M4** or later. macOS guests technically run on M1+,
  but Yuruna pins to M4+ to keep one chip floor across the macos.utm
  guest set — `guest.ubuntu.server.24` and friends already require M3+
  for nested virt, and aligning at M4+ avoids "works for OS guest X but
  not OS guest Y on the same host" support matrices.
* UTM 4.6 or later (Apple backend, `ConfigurationVersion 4`).

## Setup Assistant is not automated yet

macOS has no cloud-init/autoinstall equivalent. After
`New-VM.ps1` restores the IPSW the first boot lands in Setup
Assistant (region, keyboard, Wi-Fi, Apple ID, etc.). Driving that
flow from the test harness needs OCR templates and a sequence under
`test/sequences/gui/start.guest.macos.26.yml` — neither exists yet.

For now the supported workflow is:

1. `pwsh host/macos.utm/guest.macos.26/Get-Image.ps1` (downloads the
   latest macOS 26 IPSW once).
2. `pwsh host/macos.utm/guest.macos.26/New-VM.ps1` (creates a UTM
   bundle and restores the IPSW into it — ~15-25 min).
3. Open `~/yuruna/guest.nosync/<VMName>.utm` in UTM, walk through
   Setup Assistant manually.

`macos.26.update.sh` runs `softwareupdate -i -a` and is intended for
the eventual workload step that runs *after* an operator-provisioned
guest is online; it is not invoked by `New-VM.ps1`.

The `code`, `k8s`, `n8n`, `openclaw`, and `postgresql` workloads are
intentionally out of scope for the macOS 26 guest; use the Ubuntu Server
or Amazon Linux 2023 guests for those workloads.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.30

Back to [Yuruna](../../README.md)
