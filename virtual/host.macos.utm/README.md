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
[../CODE.md](../CODE.md#install-one-liner-convention). macOS-specific
notes for each step:

- Step 1 (new shell): Apple Silicon — `eval "$(/opt/homebrew/bin/brew shellenv)"`;
  Intel — `/usr/local` instead.
- Step 4 (launch hypervisor): `open -a UTM`.
- Step 5 requires **both** TCC permissions (separate buckets):
  - **Accessibility** — the harness drives UTM VMs via
    `AXUIElementPostKeyboardEvent` so they stay driven when unfocused.
  - **Screen Recording** — needed so `CGWindowListCopyWindowInfo`
    returns window titles (the harness matches UTM's per-VM window by
    title) and so `screencapture -l <windowId>` can capture a specific
    VM window. Without this, `waitForAndClickButton` loops on "UTM
    window for `<vm>` not found".

  `Enable-TestAutomation.ps1` fires the first-run dialog for each.
  TCC forbids automating the toggle itself; if you dismiss a dialog,
  toggle the switch manually and **fully quit and relaunch the
  terminal** (Cmd-Q) — macOS won't honor the grant for the running
  process.

Manual walk-through of the installer: [read.more.md](read.more.md).

## Optional: Squid cache VM

See [../CODE.md](../CODE.md#optional-squid-cache-vm) and
[../../docs/caching.md](../../docs/caching.md). Setup:

```bash
cd ~/git/yuruna/virtual/host.macos.utm/guest.squid-cache
pwsh ./Get-Image.ps1
pwsh ./New-VM.ps1
```

Rate-limiting bites macOS faster than Hyper-V because Apple
Virtualization's Shared NAT egresses every UTM VM through the host's
single public IP.

Once the cache VM is running, the Ubuntu Desktop `New-VM.ps1` probes
the host-side forwarder on `:3128` (launched by
`test/Start-CachingProxy.ps1`) and injects `http://192.168.64.1:3128`
into the autoinstall seed ISO. **If the VM is `started` but the
forwarder is not running**, `New-VM.ps1` exits 1 rather than silently
falling back — re-run `test/Start-CachingProxy.ps1`.

## Next: Create a Guest VM

- [Amazon Linux](guest.amazon.linux/README.md)
- [Ubuntu Desktop](guest.ubuntu.desktop/README.md)
- [Windows 11](guest.windows.11/README.md)

[Troubleshooting](troubleshooting.md) · Back to [[Yuruna](../../README.md)]
