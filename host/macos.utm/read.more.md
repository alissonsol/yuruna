# macOS UTM Host Setup - Nerd-Level Details

The one-line installer in [README.md](README.md) automates the steps
below. This walk-through reproduces them by hand for audit / learning.

## 1) Install Homebrew

Latest instructions at [brew.sh](https://brew.sh/):

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

Open a new terminal so `brew shellenv` lands on `PATH`. Apple Silicon →
`/opt/homebrew`; Intel → `/usr/local`. Homebrew depends on the Xcode CLI
tools — macOS prompts when missing, or trigger explicitly:

```bash
xcode-select --install
```

## 2) Install Required Tools

```bash
brew install --cask utm
brew install git powershell tesseract openssl qemu wget
```

- `utm` — [UTM](https://mac.getutm.app/) VM host, built on QEMU.
- `git` — clone the repo.
- `powershell` — `pwsh` runs every script under `test/`.
- `tesseract` — OCR for [Test.Tesseract.psm1](../../test/modules/Test.Tesseract.psm1).
- `qemu` — `qemu-img` for disk image resizing in `Get-Image.ps1`.
- `openssl` / `wget` — image-fetch and cloud-init preparation.

## 3) Clone the Yuruna Repository

```bash
mkdir -p ~/git
git clone https://github.com/alissonsol/yuruna.git ~/git/yuruna
```

## 4) macOS Permissions for the Test Harness

The harness sends keystrokes to UTM VMs without requiring focus via the
Accessibility API (`AXUIElementPostKeyboardEvent`), which needs explicit
permission.

Grant **Accessibility** to your terminal app at **System Settings >
Privacy & Security > Accessibility**. Without it, the harness falls
back to AppleScript/CGEvent — which needs UTM to be focused and breaks
when other windows steal focus.

QEMU-backend guests with a `-vnc` argument in `AdditionalArguments`
(today: `guest.ubuntu.desktop`) get an additional VNC transport that
sends keystrokes and reads the framebuffer over TCP, bypassing AppKit:
no focus, no Space-pinning, no Accessibility prompt. `guest.windows.11`
uses QEMU too but ships with empty `AdditionalArguments` — to opt in,
follow the comment in its `config.plist.template`.

### Per-VM VNC port architecture

A hardcoded `-vnc 127.0.0.1:0` (TCP 5900) on every VM let the capture
path silently grab whichever QEMU bound 5900 first, so a stale Ubuntu
Desktop VM could hijack a screenshot meant for Ubuntu Server. The
harness now derives a unique display number from the VM name:

- Producer: [`New-VM.ps1`](guest.ubuntu.desktop/New-VM.ps1) imports
  `Get-VncDisplayForVm` and substitutes `__VNC_DISPLAY__` (10..89, port
  5910..5989) into
  [`config.plist.template`](guest.ubuntu.desktop/config.plist.template).
- Consumers: `Get-UtmScreenshot` and `Connect-VNC` (in
  [`Test.Screenshot.psm1`](../../test/modules/Test.Screenshot.psm1)
  and [`Invoke-Sequence.psm1`](../../test/extensions/Invoke-Sequence.psm1))
  call the same helper.

Adding a new QEMU+VNC guest = copy the `-vnc 127.0.0.1:__VNC_DISPLAY__`
template line; producer and consumer pick up the port automatically.

### Running across macOS Spaces (desktops)

QEMU+VNC guests are Space-independent end-to-end: capture and
keystrokes flow through TCP. AVF guests (`guest.ubuntu.server`,
`guest.amazon.linux`) capture via `screencapture -l <windowID>`; the
windowID lookup uses `kCGWindowListOptionAll` to find UTM windows on
other Spaces, and `Enable-TestAutomation.ps1` flips
`AppleSpacesSwitchOnActivation` so UTM activation doesn't yank the
view across Spaces. AVF keystrokes still take focus — for the cleanest
cross-Space behavior, right-click UTM in the Dock → Options → Assign
To → All Desktops.

## 5) Disable Display Sleep and Screen Lock

When the display blanks, UTM captures return black and OCR fails. The
helper disables display sleep, screen-saver idle, and the screen-lock
password requirement via `pmset` and `defaults`:

```bash
cd ~/git/yuruna/host/macos.utm
pwsh ./Enable-TestAutomation.ps1
```

`-WhatIf` previews changes. Idempotent; requires `sudo` for `pmset`.

## 6) Seed the Test Config

```bash
cd ~/git/yuruna/test
cp test-config.json.template test-config.json
$EDITOR test-config.json
```

## 7) First Launch of UTM

```bash
open -a UTM      # surfaces any first-run dialogs
```

## 8) Optional: Squid cache VM

See [../README.md](../README.md#optional-squid-cache-vm) and
[../../docs/caching.md](../../docs/caching.md). After provision,
double-click
`~/Desktop/Yuruna.VDE/<hostname>.nosync/squid-cache.utm` to register
the bundle with UTM and start the VM.

## 9) Run the Test Harness

```bash
pwsh ~/git/yuruna/test/Invoke-TestRunner.ps1
```

[Guest VMs](README.md#next-create-a-guest-vm) ·
[Troubleshooting](troubleshooting.md) ·
Back to [[UTM setup](README.md)] · [[Yuruna](../../README.md)]
