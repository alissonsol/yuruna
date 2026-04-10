# macOS UTM Host Setup

One-time setup instructions for preparing a macOS host with UTM.

## Install Homebrew

Check latest instructions for `brew` from [brew.sh](https://brew.sh/)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After installing `brew`, you may need to open another terminal.

## Install Required Tools

```bash
brew install --cask utm
brew install git
brew install powershell
brew install openssl qemu wget
```

## macOS Permissions for the Test Harness

The automated test harness sends keystrokes to UTM VMs without requiring window focus. This uses the macOS Accessibility API (`AXUIElementPostKeyboardEvent`), which requires explicit permission.

Grant **Accessibility** access to your terminal app (Terminal.app, iTerm2, etc.):

**System Settings > Privacy & Security > Accessibility** — add and enable your terminal application.

Without this permission, the harness falls back to AppleScript/CGEvent keystroke delivery, which requires UTM to be the focused application and is fragile when other windows steal focus.

For QEMU-backend guests (Windows 11), an additional VNC transport is available that sends keystrokes over TCP to the VM's built-in VNC server, bypassing the GUI entirely.

## Next: Create a Guest VM

After completing the host setup, follow the instructions for your guest operating system:

- [Amazon Linux](guest.amazon.linux/README.md)
- [Ubuntu Desktop](guest.ubuntu.desktop/README.md)
- [Windows 11](guest.windows.11/README.md)

## Troubleshooting

If you run into problems, see [common issues and solutions](troubleshooting.md).

Back to [[Yuruna](../../README.md)]
