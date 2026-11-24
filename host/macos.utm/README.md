# macOS UTM Host Setup

One-time setup for a macOS host with UTM. Cross-host concepts
(install-one-liner convention, post-install steps, optional Squid cache
VM, guest workload pattern) live in [Hosts -- ...](../README.md).

## Quick install (one line)

From a fresh **Terminal**:

```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos.utm.sh)"
```

Installs Xcode Command Line Tools, Homebrew, `git`, `pwsh`, `tesseract`, `tmux`, and UTM;
clones the repo to `~/git/yuruna`; seeds `test/test.config.yml`.
Idempotent; prompts for your macOS password once. Disabling display
sleep and screen-saver lock for unattended runs is a separate opt-in
step -- run [`Enable-TestAutomation.ps1`](Enable-TestAutomation.ps1)
manually after install, or let `pwsh install/setup.ps1` do it as one step
of a guided [standalone-host or lab setup](../../install/README.md#guided-setup).

After the script finishes, follow the steps in
[Hosts -- ...](../README.md#install-one-liner-convention). macOS notes:

- Step 1 (new shell): Apple Silicon -- `eval "$(/opt/homebrew/bin/brew shellenv)"`;
  Intel -- `/usr/local`.
- Step 4 (launch hypervisor): `open -a UTM`.
- Step 5 -- both TCC grants (Accessibility, Screen Recording) covered in
  [Hosts -- ...](../README.md#install-one-liner-convention).

  `Enable-TestAutomation.ps1` also flips `AppleSpacesSwitchOnActivation`
  to `false` so UTM activation during an AVF-guest keystroke doesn't
  yank you off another Space. One manual step the script doesn't
  automate (Dock plist edits are fragile): right-click UTM in the Dock
  -> Options -> Assign To -> All Desktops. With both, a long
  `Start-TestRunner` can run on Space 1 while you debug in VS Code on
  Space 2. See
  [macOS UTM Host Setup - Nerd-Level Details](read.more.md#running-across-macos-spaces-desktops).

Manual walk-through of the installer: [macOS UTM Host Setup - Nerd-Level Details](read.more.md).

## System requirements

The installer's tested baseline is **macOS 26+ (Tahoe)**, **Apple
Silicon (arm64)**, **16+ physical cores**, **32 GB+ RAM**, and
**512 GB+ free disk**. A preflight check warns and prompts for
confirmation if any is unmet; continuing is permitted but UNTESTED.
See [Installation -- system-requirements preflight](../../docs/install.md#system-requirements-preflight).

## The host controller

A host update (the Diagnostics page's **Update host**, or
`pwsh test/lab/Invoke-HostUpdate.ps1`) is carried out by the host controller, a process
that outlives the runner and the listener it stops and starts. macOS registers no job for
it. `Enable-TestAutomation.ps1`, run by you at the machine:

- deploys `~/.yuruna/host-repair/host-controller/shim` (a copy of
  [`test/lab/yuruna-host-controller-shim.sh`](../../test/lab/yuruna-host-controller-shim.sh))
  and a first snapshot of the controller's code (`versions/<hash>/`, named in `current`);
- installs the sudoers entry `/etc/sudoers.d/yuruna-host-update-access`, with the password
  it already asks for, checked by `visudo -cf` and replaced when its text differs. It lets
  the test account run, without a password, exactly two commands:
  `/usr/bin/tee /etc/sudoers.d/yuruna-host-update` and
  `/bin/rm -f /etc/sudoers.d/yuruna-host-update`. A failure to install it counts as not met
  (exit 2), and the host then offers only the `restart` scope;
- when the shim changed and no host update is claimed, ends the controller's session, so
  the next runner start starts the new shim. A session whose controller runs an update, or
  may run one because the request journal cannot be read, is left to finish it: the file
  `session-restart-pending` beside the shim keeps the pending end, and a later run of the
  script ends the session once the journal reads with no update claimed. Run it again
  after the update ends.

An ordinary `pwsh test/Start-TestRunner.ps1` from a terminal of the desktop session (not
over SSH) then starts the controller when none holds its lock: in a detached `tmux` session
of its own, or a `screen` session on a host without `tmux`, named `yuruna-controller`. The
start prints one `Host controller:` line saying what it found or did. The session gets the
start's environment without its other `YURUNA_*` variables, but the `YURUNA_SKIP_*`
overrides you set stay, for the controller and for the runner it starts. A runner that is
already running never starts a controller by itself, and a second start next to it takes
it over and ends its cycle mid-test. So when a runner runs, arm **Pause after cycle** on
the status page (or wait for its cycle to end), stop it with Ctrl+C, and start it again
from a terminal of the desktop session: that start starts the controller. Until then the
Diagnostics page says `controller_absent`. Read the controller with:

```
tmux -L yuruna-controller attach -t yuruna-controller
screen -r yuruna-controller
```

`Ctrl+B`, `D` (or `Ctrl+A`, `D` under `screen`) leaves it running. Ctrl+C in the runner's
own terminal does not reach it, but a logout or a restart of the Mac ends it, and nothing
starts it again until you start the runner again; meanwhile the Diagnostics page says
`controller_absent`. The controller and the runner it starts are meant to hold the privacy
grants of the terminal application you started that first runner from, so start it from the
terminal that holds them. When the controller reads its session as unusable (an SSH login, not the
desktop session, or a grant read as denied), a host update is refused with
`session_unusable`: end the session with
`tmux -L yuruna-controller kill-session -t yuruna-controller` (under `screen`,
`screen -S <pid>.yuruna-controller -X quit` with the id `screen -ls` lists), stop a running
runner after its cycle, and start the runner again from a granted terminal. The console of a runner the controller started is another `tmux`
session: `tmux -S ~/.yuruna/host-repair/host-controller/runner-console.sock attach`. A host
without `tmux` starts that runner without a console and says so in the update's remarks.

If a host update is interrupted by a logout or a restart, start the runner once more from
a terminal of the desktop session: the start refuses at the closed runner gate, starts the
controller first, and the controller continues the update. From a remote login, end the
update instead with `pwsh test/lab/Invoke-HostUpdate.ps1 -Release <id>`. When no controller
holds its lock at the gate, the refusal takes one of three forms. Usually no controller
runs: it repeats the `Host controller:` line and names both ways on, a start from a terminal
of the desktop session or `-Release`. When the start's step found a controller running or
started one, and the lock now reads free, that controller is between two runs and its shim
starts it again shortly, so the refusal names only `-Release`. When the step found or
started one and the lock now cannot be read, the refusal says it is not known whether a
controller continues the update, and names both ways on.

`Disable-TestAutomation.ps1` refuses, changing nothing, while a host update is running or
recovering, or while the request journal cannot be read, which could hide one; a queued one
does not block it. Otherwise it ends the `yuruna-controller` session (refusing, and keeping
every file, when the controller claimed an update meanwhile or the journal can no longer be
read), waits up to 30 seconds for the controller's lock to be free, removes the controller
folder, and then removes a temporary sudo rule a `full` host update may have left and the
sudoers entry. It does all of this whether or not a captured state exists, and keeps the rule and
the entry while a controller may still run.

### The full scope

A host update with the scope `full` also runs the installer of the checkout
(`install/macos.utm.sh --unattended`) and `Enable-TestAutomation.ps1 -SkipPoolStorage
-NoOperatorPrompt`, after the source update and before the listener and the runner start
again. The Diagnostics page offers it while the controller's own probe passes: it writes a file
holding only a comment to `/etc/sudoers.d/yuruna-host-update` through the entry and removes
it, with `sudo -n -k`. The controller probes when it starts, every ten minutes while the
probe fails, and immediately before it claims a `full` request, so an entry installed while
the controller runs is found without a restart. Before a claim it probes one request at most
once a minute (a refused claim leaves the request queued, and it is tried again), and it
never probes while an update is claimed or the request journal cannot be read. For each of the two phases the controller
writes the temporary rule `/etc/sudoers.d/yuruna-host-update`,
`<account> ALL=(ALL:ALL) NOTAFTER=<UTC time>Z NOPASSWD: ALL`, checked by `visudo -cf` and
confirmed with `sudo -n -k true`. Its own date ends it at the phase's bound (40 minutes for
the install, 10 for the settings) plus two minutes, which is what ends it after a logout,
when no controller runs; the step removes it as soon as the work ends, and so do restore,
`-Release` and `Disable-TestAutomation.ps1`. The installer and the settings run as the test
account with standard input closed, and none of their `sudo` calls can ask for a password:
the installer's own carry `-n`, and both run with `NONINTERACTIVE=1` and
`SUDO_ASKPASS=/usr/bin/false`, so a `sudo` that Homebrew starts by itself, without `-n`,
fails at once. The step ends their process tree at the bound, root members with
`sudo -n /bin/kill` while the rule is in force.

Unattended, the installer asks nothing, runs no `git` command on the checkout, stops and
quits nothing (UTM and the service VMs keep running; a runner still running fails it with
`runner_present`), leaves `test/status` and the test VMs alone, and runs no Command Line
Tools dialog and no Homebrew bootstrap. It refuses a host where `sudo -n true` fails
(`not_elevated`), where the checkout, PowerShell, Homebrew at `/opt/homebrew` or
`/usr/local`, or `/Applications/UTM.app` is missing (`not_provisioned`), or where the Command
Line Tools are missing (`clt_missing`). It
does not upgrade the UTM cask (remark `utm_upgrade_deferred`; an attended run upgrades it),
records a failed `brew update` as the remark `brew_update_failed`, does not lift Homebrew
pins, and keeps the previous PowerShell keg (`HOMEBREW_NO_INSTALL_CLEANUP=1`, no
`brew cleanup`) until the next attended run, because the listener and the controller still
run from it. When it moved PowerShell to a new version, the controller stops the listener
and starts again on the new PowerShell before the settings phase.

## Optional: Squid cache VM

See [Hosts -- ...](../README.md#optional-squid-cache-vm) and
[Caching](../../docs/caching.md).

The cache VM uses UTM's QEMU **bridged networking** on an Ethernet
default route -- it gets its own DHCP-assigned IP on the host's LAN,
identical in shape to the Hyper-V Yuruna-External vSwitch path, and
Squid sees real client IPs at TCP level with no host-side TCP
forwarder layer. On a Wi-Fi-only default route `New-VM.ps1` builds it
on UTM Shared NAT instead, and `Start-CachingProxyServiceVM.ps1` forwards host
ports to it.

- **Local install VMs** on VZ Shared NAT reach the cache through VMnet's
  outbound NAT to the LAN IP. `guest.ubuntu.server.24/New-VM.ps1` delegates
  to `Test-CachingProxyServiceAvailable` and injects e.g.
  `http://192.168.7.150:3128` into the autoinstall seed ISO.
- **Remote LAN hosts** set `vmStart.cachingProxyIp: <cache-lan-ip>` in
  their `test/test.config.yml` (probed first at cycle start) -- or
  `YURUNA_CACHING_PROXY_SERVICE_IP=<cache-lan-ip>` before `Start-TestRunner.ps1`
  on hosts whose config key is empty; a populated, reachable config
  value outranks the env var. The cache's LAN IP is printed in the
  summary line of `test/service/Start-CachingProxyServiceVM.ps1`.
- **If the cache VM is `started` but no `:3128` answer is found on the
  host's LAN `/24`**, `New-VM.ps1` exits 1 rather than silently falling
  back -- typically a Wi-Fi AP that filters the cache's
  locally-administered MAC. Switch to Ethernet or rebuild on a network
  that allows it.

`test/service/Repair-CachingProxyServiceForwarder.ps1` is a thin "verify reachable +
refresh state file" tool; forwarders are created only for the Wi-Fi
Shared NAT build. `test/service/Stop-CachingProxyServiceVM.ps1` tears them down.

## Next: Create a Guest VM

- [Amazon Linux 2023](guest.amazon.linux.2023/README.md)
- [macOS 26](guest.macos.26/README.md)
- [Ubuntu Server 24.04](guest.ubuntu.server.24/README.md)
- [Ubuntu Server 26.04](guest.ubuntu.server.26/README.md)
- [Windows 11](guest.windows.11/README.md)

Read more: [macOS UTM Host Setup - Nerd-Level Details](read.more.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.11.23

Back to [Yuruna](../../README.md)
