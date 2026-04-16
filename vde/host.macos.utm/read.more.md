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

The automated test harness sends keystrokes to UTM VMs without
requiring window focus. This uses the macOS Accessibility API
(`AXUIElementPostKeyboardEvent`), which requires explicit permission.

Grant **Accessibility** access to your terminal app (Terminal.app,
iTerm2, etc.):

**System Settings > Privacy & Security > Accessibility** — add and
enable your terminal application.

Without this permission, the harness falls back to AppleScript /
CGEvent keystroke delivery, which requires UTM to be the focused
application and is fragile when other windows steal focus.

For QEMU-backend guests (Windows 11), an additional VNC transport is
available that sends keystrokes over TCP to the VM's built-in VNC
server, bypassing the GUI entirely.

## 5) Disable Display Sleep and Screen Lock

When the display blanks, UTM screen captures return a black image and
OCR verification fails. The repo ships a PowerShell helper that
disables display sleep, the screen saver idle trigger, and the screen
lock password requirement via `pmset` and `defaults`:

```bash
cd ~/git/yuruna/test
pwsh ./Set-MacHostConditionSet.ps1
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

## 8) Optional: Set up the local apt cache VM

Each Ubuntu Desktop install downloads ~900 MB of packages from
Ubuntu's CDN. When the test harness runs cycles back-to-back, the
CDN may rate-limit requests (HTTP 429), causing the install to fail.
A local `apt-cacher-ng` VM caches everything after the first
download, cutting subsequent installs to ~2 minutes and eliminating
rate-limit failures.

This step is optional — skip it if you prefer direct CDN downloads.

```bash
cd ~/git/yuruna/vde/host.macos.utm/guest.apt-cache
pwsh ./Get-Image.ps1    # downloads Ubuntu Server cloud image (ARM64)
pwsh ./New-VM.ps1        # creates + starts the cache VM
```

The Ubuntu Desktop `New-VM.ps1` detects the running cache VM
automatically. See
[guest.apt-cache/README.md](guest.apt-cache/README.md) for details.

> **Note**: The macOS UTM `New-VM.ps1` for the cache VM has not been
> implemented yet. See the README for manual setup instructions.

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
