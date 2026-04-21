# macOS UTM Host Setup - Nerd-Level Details

Copyright (c) 2019-2026 by Alisson Sol et al.

The one-line installer in [README.md](README.md) automates everything
below. This document walks through the same steps by hand, for those
who want to understand (or audit) what gets changed on their machine.

## 1) Install Homebrew

Check latest instructions for `brew` from [brew.sh](https://brew.sh/).

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After installing `brew`, you may need to open another terminal so that
`brew shellenv` is picked up on your `PATH`. On Apple Silicon Homebrew
lives at `/opt/homebrew`; on Intel Macs at `/usr/local`.

Homebrew itself depends on the Xcode Command Line Tools. If they are
not already installed, macOS will prompt you; you can also trigger it
explicitly:

```bash
xcode-select --install
```

## 2) Install Required Tools

```bash
brew install --cask utm
brew install git
brew install powershell
brew install tesseract
brew install openssl qemu wget
```

- `utm` is the [UTM](https://mac.getutm.app/) VM host, built on QEMU.
- `git` is needed to clone this repository.
- `powershell` provides `pwsh`, which runs every script under `test/`.
- `tesseract` is used by [Test.Tesseract.psm1](../../test/modules/Test.Tesseract.psm1)
  for OCR-based verification steps.
- `qemu` provides `qemu-img` for disk image resizing used by the
  per-guest `Get-Image.ps1` scripts.
- `openssl` and `wget` are used by several image-fetch / cloud-init
  preparation steps.

## 3) Clone the Yuruna Repository

```bash
mkdir -p ~/git
git clone https://github.com/alissonsol/yuruna.git ~/git/yuruna
```

## 4) macOS Permissions for the Test Harness

The test harness sends keystrokes to UTM VMs without requiring
window focus via the macOS Accessibility API
(`AXUIElementPostKeyboardEvent`), which needs explicit permission.

Grant **Accessibility** access to your terminal app (Terminal.app,
iTerm2, etc.) at **System Settings > Privacy & Security >
Accessibility**.

Without this permission, the harness falls back to
AppleScript/CGEvent keystroke delivery, which requires UTM to be
focused and is fragile when other windows steal focus.

For QEMU-backend guests (Windows 11), an additional VNC transport
sends keystrokes over TCP to the VM's built-in VNC server,
bypassing the GUI entirely.

## 5) Disable Display Sleep and Screen Lock

When the display blanks, UTM screen captures return black and OCR
verification fails. The PowerShell helper disables display sleep,
the screen-saver idle trigger, and the screen-lock password
requirement via `pmset` and `defaults`:

```bash
cd ~/git/yuruna/vde/host.macos.utm
pwsh ./Enable-TestAutomation.ps1
```

Use `-WhatIf` first to preview changes. The script is idempotent and
requires `sudo` for `pmset`.

## 6) Seed the Test Config

```bash
cd ~/git/yuruna/test
cp test-config.json.template test-config.json
$EDITOR test-config.json
```

Review the guests list and any host-specific paths before running the
test harness.

## 7) First Launch of UTM

Open UTM once by hand so macOS can present any first-run dialogs
(network permission, screen recording, etc.):

```bash
open -a UTM
```

## 8) Optional: Set up the local HTTP cache VM (squid)

Each Ubuntu Desktop install downloads ~900 MB from Ubuntu's CDN.
Back-to-back cycles can get HTTP 429 rate-limits. This bites harder
on UTM than on Hyper-V: all Apple Virtualization Shared-mode VMs
egress through the host's single public IP, so every parallel install
adds to the *same* per-source rate limit. A local **squid** VM caches
every HTTP response — including the installer's own kernel and
linux-firmware fetches — so subsequent installs drop to ~2 minutes
and rate-limit failures stop. (Squid replaces the older apt-cacher-ng
cache, which only caught .deb URLs and missed the pre-install kernel
step where the 429 originated.)

This step is optional — skip it if you prefer direct CDN downloads.

```bash
cd ~/git/yuruna/vde/host.macos.utm/guest.squid-cache
pwsh ./Get-Image.ps1    # downloads + converts Ubuntu Server cloud image (arm64)
pwsh ./New-VM.ps1        # assembles the UTM bundle
```

Then double-click `~/Desktop/Yuruna.VDE/<hostname>.nosync/squid-cache.utm`
to register the bundle with UTM, and start the VM. The Ubuntu Desktop
`New-VM.ps1` detects the running cache automatically. See
[docs/caching.md](../../docs/caching.md) for details, including the
Grafana dashboard and the cachemgr.cgi fallback.

## 9) Run the Test Harness

```bash
cd ~/git/yuruna/test
pwsh ./Invoke-TestRunner.ps1
```

## Next: Create a Guest VM

After completing the host setup, follow the instructions for your
guest operating system:

- [Amazon Linux](guest.amazon.linux/README.md)
- [Ubuntu Desktop](guest.ubuntu.desktop/README.md)
- [Windows 11](guest.windows.11/README.md)

## Troubleshooting

If you run into problems, see [common issues and solutions](troubleshooting.md).

Back to [[macOS UTM Host Setup](README.md)] · [[Yuruna](../../README.md)]
