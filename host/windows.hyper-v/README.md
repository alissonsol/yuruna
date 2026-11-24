# Windows Hyper-V Host Setup

One-time setup for a Windows host with Hyper-V. Cross-host concepts
(install-one-liner convention, post-install steps, optional Squid cache
VM, guest workload pattern) live in [Hosts -- ...](../README.md).

## Host architecture

AMD64 and ARM64 hosts are both supported. Each `Get-Image.ps1` reads the
host architecture and downloads the matching guest image; Hyper-V has no
cross-architecture emulation, so the host's architecture is also the
guest's and there is no flag to force the other one. The image lands
under the same file name either way, so `New-VM.ps1` is identical on both.

One guest needs an extra step on ARM64: Amazon Linux 2023 publishes no
ARM64 Hyper-V image, so its `Get-Image.ps1` pulls the ARM64 KVM cloud
image and converts it to VHDX with `qemu-img`. The QEMU tools below are
not optional on either architecture, though -- Hyper-V boots VHDX and the
Ubuntu cloud image the extension-service guests share ships as qcow2, so
those convert on AMD64 too.

## Quick install (one line)

From a fresh **Windows PowerShell** (or `pwsh`):

```
$nc = if ($env:YurunaCacheContent) { "?nocache=$env:YurunaCacheContent" } else { "" }
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1$nc" | iex
```

Installs PowerShell 7, Git, Windows ADK Deployment Tools (for
`oscdimg.exe`), QEMU tools (for `qemu-img`, used by every
extension-service `Get-Image.ps1` and on ARM64 also by
`guest.amazon.linux.2023/Get-Image.ps1`), and Tesseract OCR via `winget`;
enables **Microsoft-Hyper-V-All** via `dism.exe`; clones the repo to
`%USERPROFILE%\git\yuruna`; seeds `test\test.config.yml`. Idempotent;
elevation requested once. Disabling display timeout and screen lock
for unattended runs is a separate opt-in step -- run
[`Enable-TestAutomation.ps1`](Enable-TestAutomation.ps1) manually
after install, or let `pwsh install/setup.ps1` do it as one step of a
guided [standalone-host or lab setup](../../install/README.md#guided-setup).

Then follow [Hosts -- ...](../README.md#install-one-liner-convention). On
Windows: step 2's reboot applies only when Hyper-V was just enabled;
step 4's hypervisor UI is Hyper-V Manager:

```
Start-Process virtmgmt.msc
```

Not auto-launched: Hyper-V Manager personalizes per user on first run,
and enterprise-managed machines may need interactive acknowledgment.
Prefer `pwsh` over `powershell.exe` afterward.

Manual walk-through: [Windows Hyper-V Host Setup - Nerd-Level Details](read.more.md).

## The host controller

A host update (the Diagnostics page's **Update host**, or
`pwsh test/lab/Invoke-HostUpdate.ps1`) is carried out by the host controller, which runs
under the scheduled task **Yuruna Host Controller** so that it outlives the runner and the
listener it stops and starts. `Enable-TestAutomation.ps1`, run as Administrator, registers
it on every run:

- it deploys `%ProgramData%\yuruna\host-controller\shim.ps1` (a copy of
  [`test/lab/yuruna-host-controller-shim.ps1`](../../test/lab/yuruna-host-controller-shim.ps1))
  and a first snapshot of the controller's code (`versions\<hash>\`, named in `current`).
  The folder is owned by Administrators and only Administrators and SYSTEM can write it,
  because the task starts the shim from there elevated; a folder of that name with any
  other access list is refused, not repaired;
- it renders the task from
  [`host-controller/yuruna-host-controller.task.xml`](host-controller/yuruna-host-controller.task.xml):
  started at each logon of the account that runs the script, run only while that account
  is logged on, with its highest privileges, at normal priority, on battery too, with no
  time limit, one instance, and a restart every minute after a failure (the largest count
  the scheduler accepts). The action is Windows PowerShell, hidden, on the shim;
- it registers the task again only when its definition differs from the one it last
  registered (kept as `task.xml` in the controller folder), restarts a running task when
  the definition or the shim changed, starts it otherwise, and waits up to 15 seconds for
  the controller to take its lock; a task it could not register or start, or a controller
  that does not take its lock, is reported as not met (exit 2).

The task starts at logon, so after a restart of Windows a host update continues only once
the test account logs on again; nothing here configures automatic logon. The controller
and every phase it runs hold the account's Administrator token, as a runner an operator
starts does. Read the shim and the controller in `shim.log` and `controller.log` in the
controller folder.

The shim restarts the controller by the same rules as on KVM (at once after exit 75, 30
seconds after 76, otherwise after 10 seconds doubling to 60, and three deaths of a
snapshot that never started reject it). On exit 77 it runs the PowerShell 7 upgrade the
controller asked for in `pwsh-upgrade.request`, an installer copy that must lie under
`%ProgramData%\yuruna`, bounded at 20 minutes, writes `pwsh-upgrade.result`, and starts the
controller again. A `stop` file in the controller folder makes it end its controller alone
and exit; that is how Enable restarts the task and Disable removes it without ending the
runner, the listener or the console the controller started.

The console of a runner the controller started is a window of its own on the desktop of
the test account: open it at the machine, or over a remote desktop connection to that
session. Ctrl+C there stops the runner as it stops one started by hand.

A host update with the scope `full` also runs the installer of the checkout and
`Enable-TestAutomation.ps1 -SkipPoolStorage -NoOperatorPrompt` after the source update.
The controller copies `install\windows.hyper-v.ps1` into a new folder,
`%ProgramData%\yuruna\host-update-<request id>-<attempt>`, that only Administrators and
SYSTEM can write, checks the copy by hash, and runs it under PowerShell 7 with `-Unattended
-YurunaDir <checkout>`; the copies go when the update ends. Unattended, the installer asks
nothing, runs no `git` command on the checkout, stops nothing (a runner still running fails
it with `runner_present`), leaves `test\status` and the test VMs alone, opens no window,
editor or shell, and does not wait before it exits. When winget offers a newer PowerShell 7,
the installer only records it; the controller then stops the listener and exits with 77,
and the shim runs `windows.hyper-v.ps1 -Unattended -UpgradePowerShell` from that copy under
Windows PowerShell. A failed upgrade is a remark: the old PowerShell keeps running. When the
installer had to enable Hyper-V, the update ends as `reboot_required` once the runner's start
is refused: restart Windows, then start the runner.
`Enable-TestAutomation.ps1 -NoOperatorPrompt` installs no module and verifies the scheduled
task instead of registering or restarting it.

`Disable-TestAutomation.ps1` refuses, changing nothing, while a host update is running or
recovering, or while the request journal cannot be read, which could hide one. An update the
controller claims while the task is being stopped (or a journal that can no longer be read)
is found when the task has stopped: the task is started again to continue it, and the
script refuses the same way. When that start fails, it keeps the task and the controller
folder, says so in the list of what it left, and goes on with the rest. Otherwise it stops
and removes the task and, once no controller holds its lock, the controller folder.

## Optional: Squid cache VM

See [Hosts -- ...](../README.md#optional-squid-cache-vm) and
[Caching](../../docs/caching.md). Once `caching-proxy-service` is
running, the Ubuntu Server `New-VM.ps1` scripts auto-detect it and
inject the proxy URL into the seed ISO.

## Next: Create a Guest VM

- [Amazon Linux 2023](guest.amazon.linux.2023/README.md)
- [Ubuntu Server 24.04](guest.ubuntu.server.24/README.md)
- [Ubuntu Server 26.04](guest.ubuntu.server.26/README.md)
- [Windows 11](guest.windows.11/README.md)

Read more: [Windows Hyper-V Host Setup - Nerd-Level Details](read.more.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.11.23

Back to [Yuruna](../../README.md)
