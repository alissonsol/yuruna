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
cd ~/git/yuruna/virtual/host.macos.utm
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

## 8) Optional: Squid cache VM

See [../CODE.md](../CODE.md#optional-squid-cache-vm) and
[../../docs/caching.md](../../docs/caching.md):

```bash
cd ~/git/yuruna/virtual/host.macos.utm/guest.squid-cache
pwsh ./Get-Image.ps1
pwsh ./New-VM.ps1
```

Then double-click
`~/Desktop/Yuruna.VDE/<hostname>.nosync/squid-cache.utm` to register
the bundle with UTM and start the VM.

## 9) Run the Test Harness

```bash
cd ~/git/yuruna/test
pwsh ./Invoke-TestRunner.ps1
```

[Guest VMs](README.md#next-create-a-guest-vm) ·
[Troubleshooting](troubleshooting.md) ·
Back to [[UTM setup](README.md)] · [[Yuruna](../../README.md)]
