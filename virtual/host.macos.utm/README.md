# macOS UTM Host Setup

One-time setup for a macOS host with UTM. Cross-host concepts
(install-one-liner convention, post-install steps, optional Squid cache
VM, guest workload pattern) live in [../CODE.md](../CODE.md).

## Quick install (one line)

From a fresh **Terminal**:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos-install.sh)"
```

Installs Xcode CLI Tools, Homebrew, `git`, `pwsh`, `tesseract`, and UTM;
clones the repo to `~/git/yuruna`; seeds `test/test-config.json`; runs
[`Enable-TestAutomation.ps1`](Enable-TestAutomation.ps1) to disable
display sleep and screen-saver lock. Idempotent; prompts for your macOS
password once.

After the script finishes, follow the steps in
[../CODE.md](../CODE.md#install-one-liner-convention). macOS notes:

- Step 1 (new shell): Apple Silicon — `eval "$(/opt/homebrew/bin/brew shellenv)"`;
  Intel — `/usr/local`.
- Step 4 (launch hypervisor): `open -a UTM`.
- Step 5 — both TCC grants (Accessibility, Screen Recording) covered in
  [../CODE.md](../CODE.md#install-one-liner-convention).

  `Enable-TestAutomation.ps1` also flips `AppleSpacesSwitchOnActivation`
  to `false` so UTM activation during an AVF-guest keystroke doesn't
  yank you off another Space. One manual step the script doesn't
  automate (Dock plist edits are fragile): right-click UTM in the Dock
  → Options → Assign To → All Desktops. With both, you can leave a
  long `Invoke-TestRunner` running on Space 1 and debug in VS Code on
  Space 2 without disruption. See
  [read.more.md](read.more.md#running-across-macos-spaces-desktops).

Manual walk-through of the installer: [read.more.md](read.more.md).

## Optional: Squid cache VM

See [../CODE.md](../CODE.md#optional-squid-cache-vm) and
[../../docs/caching.md](../../docs/caching.md). Rate-limiting bites
macOS faster than Hyper-V: Apple Virtualization's Shared NAT egresses
every UTM VM through the host's single public IP.

Once the cache VM is running, Ubuntu Desktop `New-VM.ps1` probes the
host-side forwarder on `:3128` (launched by
`test/Start-CachingProxy.ps1`) and injects `http://192.168.64.1:3128`
into the autoinstall seed ISO. **If the VM is `started` but the
forwarder is not running**, `New-VM.ps1` exits 1 rather than silently
falling back — re-run `test/Start-CachingProxy.ps1`.

## Next: Create a Guest VM

- [Amazon Linux](guest.amazon.linux/README.md)
- [Ubuntu Desktop](guest.ubuntu.desktop/README.md)
- [Windows 11](guest.windows.11/README.md)

[Troubleshooting](troubleshooting.md) · Back to [[Yuruna](../../README.md)]
