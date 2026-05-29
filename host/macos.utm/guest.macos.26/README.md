# macOS 26 guest on macOS UTM

Boots a macOS **26** guest via the Apple Virtualization framework. The
restore image is an `.ipsw` rather than an ISO; the disk has no
autoinstall seed (macOS has no cloud-init equivalent) so first boot
lands at Setup Assistant.

**Host requirements** (verified by `New-VM.ps1`):

* macOS **15** Sequoia or later (host).
* Apple Silicon **M4** or later. M1/M2/M3 are explicitly rejected.
* UTM **v4.6** or later (Apple backend, `ConfigurationVersion 4`).
* Xcode command line tools — `swift` is on PATH; the embedded VZ
  helpers in `Get-Image.ps1` / `New-VM.ps1` need it.

Cross-host concepts: [Hosts — ...](../../README.md).

## One-time

From `yuruna/host/macos.utm/guest.macos.26` (do not `sudo`):

```
pwsh ./Get-Image.ps1
```

Apple does not publish a stable IPSW URL, so the script asks
`VZMacOSRestoreImage.fetchLatestSupported` (Virtualization framework)
for the latest macOS 26 build for this host's hardware bucket and
downloads it (~15-20 GB) into `~/yuruna/image/macos.env/`. The skip-
if-same-source guard prevents re-downloading the same build on a
repeat run.

## For each VM

```
pwsh ./New-VM.ps1                       # default macos-26-01
pwsh ./New-VM.ps1 -VMName myhost
pwsh ./New-VM.ps1 -CpuCount 6 -MemoryMb 12288 -DiskSizeGb 256
```

`New-VM.ps1` drives `VZMacOSInstaller.install` from an embedded Swift
helper: it picks the most-featureful supported configuration for this
host, allocates `Data/aux.img` and a sparse `Data/disk.img`, restores
the IPSW (~15-25 min on M4 Pro), and writes the resulting
`hardwareModel` / `machineIdentifier` base64 blobs into the UTM
`config.plist` (`System.MacPlatform.{hardwareModel,machineIdentifier}`).

After the script returns, double-click the `.utm` bundle in Finder to
import it into UTM and start the VM.

## Test harness integration (TBD)

The Setup Assistant flow is not automated yet. Until OCR templates and
a `start.guest.macos.26.yml` sequence land, the harness can create the
bundle and start the VM (`Test-VMRunning` succeeds because the VM
process exists) but every interactive step that follows must be driven
by hand. Treat this guest as "scaffolding-ready, sequence-pending".

When the test sequence lands it will live under
`test/sequences/gui/start.guest.macos.26.yml` and follow the same
contract as `start.guest.ubuntu.server.24.yml` — a `baseline: { macos.26: [] }`
entry plus the GUI steps that walk Setup Assistant to a logged-in
desktop and rotate the operator-chosen initial password.

Back to [macOS UTM](../README.md) · [Yuruna](../../../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
