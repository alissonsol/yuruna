# macOS UTM Host Setup

One-time setup for a macOS host with UTM. Cross-host concepts
(install-one-liner convention, post-install steps, optional Squid cache
VM, guest workload pattern) live in [Hosts — ...](../README.md).

## Quick install (one line)

From a fresh **Terminal**:

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos.utm.sh)"
```

Installs Xcode CLI Tools, Homebrew, `git`, `pwsh`, `tesseract`, and UTM;
clones the repo to `~/git/yuruna`; seeds `test/test.config.yml`.
Idempotent; prompts for your macOS password once. Disabling display
sleep and screen-saver lock for unattended runs is a separate opt-in
step — run [`Enable-TestAutomation.ps1`](Enable-TestAutomation.ps1)
manually after install.

After the script finishes, follow the steps in
[Hosts — ...](../README.md#install-one-liner-convention). macOS notes:

- Step 1 (new shell): Apple Silicon — `eval "$(/opt/homebrew/bin/brew shellenv)"`;
  Intel — `/usr/local`.
- Step 4 (launch hypervisor): `open -a UTM`.
- Step 5 — both TCC grants (Accessibility, Screen Recording) covered in
  [Hosts — ...](../README.md#install-one-liner-convention).

  `Enable-TestAutomation.ps1` also flips `AppleSpacesSwitchOnActivation`
  to `false` so UTM activation during an AVF-guest keystroke doesn't
  yank you off another Space. One manual step the script doesn't
  automate (Dock plist edits are fragile): right-click UTM in the Dock
  → Options → Assign To → All Desktops. With both, you can leave a
  long `Invoke-TestRunner` running on Space 1 and debug in VS Code on
  Space 2 without disruption. See
  [macOS UTM Host Setup - Nerd-Level Details](read.more.md#running-across-macos-spaces-desktops).

Manual walk-through of the installer: [macOS UTM Host Setup - Nerd-Level Details](read.more.md).

## System requirements

The installer's tested baseline is **macOS 26+ (Sequoia)**, **Apple
Silicon (arm64)**, **16+ physical cores**, **32 GB+ RAM**, and
**512 GB+ free disk**. A preflight check warns and prompts for
confirmation if any of these is not met; continuing is permitted but
UNTESTED. See [Installation — system-requirements preflight](../../docs/install.md#system-requirements-preflight).

## Optional: Squid cache VM

See [Hosts — ...](../README.md#optional-squid-cache-vm) and
[Caching](../../docs/caching.md).

The cache VM uses Apple Virtualization **bridged networking**
(`VZBridgedNetworkDeviceAttachment`) — it gets its own DHCP-assigned
IP on the host's LAN, identical in shape to the Hyper-V Yuruna-External
vSwitch path. Squid sees real client IPs at TCP level; no host-side
TCP forwarder layer.

- **Local install VMs** on VZ shared-NAT reach the cache through VMnet's
  outbound NAT to the LAN IP. `guest.ubuntu.server.24/New-VM.ps1` delegates
  to `Test-CachingProxyAvailable` and injects e.g.
  `http://192.168.7.150:3128` into the autoinstall seed ISO.
- **Remote LAN hosts** set `YURUNA_CACHING_PROXY_IP=<cache-lan-ip>`
  before `Invoke-TestRunner.ps1` and reach the cache directly. The
  cache's LAN IP is printed in the summary line of
  `test/Start-CachingProxy.ps1`.
- **If the cache VM is `started` but no `:3128` answer is found on the
  host's LAN `/24`**, `New-VM.ps1` exits 1 rather than silently falling
  back — typically a Wi-Fi AP that filters the cache's locally-
  administered MAC. Switch to Ethernet or rebuild on a network that
  allows it.

`test/Repair-CachingProxyForwarder.ps1` survives as a thin "verify
reachable + refresh state file" tool; there is no forwarder layer to
repair anymore. `test/Stop-CachingProxy.ps1` still tears down any
legacy forwarders left over from before the bridged-mode upgrade.

## Next: Create a Guest VM

- [Amazon Linux 2023](guest.amazon.linux.2023/README.md)
- [macOS 26](guest.macos.26/README.md)
- [Ubuntu Server 24.04](guest.ubuntu.server.24/README.md)
- [Ubuntu Server 26.04](guest.ubuntu.server.26/README.md)
- [Windows 11](guest.windows.11/README.md)

Read more: [macOS UTM Host Setup - Nerd-Level Details](read.more.md).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.10

Back to [Yuruna](../../README.md)
