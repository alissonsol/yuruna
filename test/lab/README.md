# Lab setup

Standing a lab up on a machine, and the host-level settings a test host
needs to run unattended. These act on *this* host; the pool configuration that
ties hosts together lives in [`../pool/`](../pool/).

## Host-neutral entry points

Four dispatchers. Each detects the host type and runs that host's copy of
the script from `host/<host type>/`, so the same command works everywhere:

```
pwsh test/lab/Enable-TestAutomation.ps1                        # prepare this host for unattended runs
pwsh test/lab/Disable-TestAutomation.ps1                       # ... and put those host settings back
pwsh test/lab/Sync-HostConfiguration.ps1 -ReferenceHost <host> # copy another pool host's test.config.yml
pwsh test/lab/Remove-OrphanedVMFiles.ps1                       # delete files left by VMs that are already gone
```

Arguments (`-WhatIf` among them) are forwarded to the per-host script,
which owns the behavior and documents it:
[macOS UTM](../../host/macos.utm/README.md),
[Windows Hyper-V](../../host/windows.hyper-v/README.md),
[Ubuntu KVM](../../host/ubuntu.kvm/README.md). On Windows,
`Enable-TestAutomation` and `Sync-HostConfiguration` need an elevated
PowerShell.

These four reach `automation/Yuruna.HostRedirect.psm1` through
`Split-Path -Parent (Split-Path -Parent $PSScriptRoot)` -- two levels up,
because they sit one below `test/`. The redirect module resolves the
per-host script from its own location, so it is unaffected by where the
dispatcher lives.

`Remove-OrphanedVMFiles` only sweeps files whose VM is already gone. To
stop and unregister the test VMs *and* sweep, use
[`../Remove-TestVMFiles.ps1`](../Remove-TestVMFiles.ps1).

## Lab creation and storage

| Script | Purpose |
|---|---|
| `Start-Syzygy.ps1` | start the caching proxy, stash, pool control, and download agent service VMs in that order, with pseudo locales enabled; the caching proxy uses MAC address `42:42:42:42:42:42` |
| `Stop-Syzygy.ps1` | run the service VM stop scripts in reverse order: download agent, pool control, stash, caching proxy |
| `Update-Syzygy.ps1` | wait for a new commit on the upstream of the current branch, pull it, then run `Start-Syzygy.ps1`; it asks for the optional GitHub token and the sudo password before the wait, so the start needs nobody at the keyboard |
| `New-Lab.ps1` | create a lab: its storage layout, config and identity |
| `New-LocalLabStorage.ps1` | publish this machine's own pool/stash SMB shares and the accounts scoped to them |
| `Clear-LocalLabStorage.ps1` | withdraw those shares and accounts (leaves the data) |
| `Set-LabToken.ps1` | enroll this host: redeem the dashboard's 6-character Lab token for the internal authentication key |
| `Lab-Diag.ps1` | show where a Lab token exchange stops, step by step, when `Set-LabToken.ps1` fails |
| `Receive-Netconsole.ps1` | receive kernel messages over UDP from a host in deep diagnostics mode (`host/ubuntu.kvm/Enable-DeepDiagnostics.ps1 -NetconsoleTarget`): one log per sender and UTC day under `~/yuruna/netconsole`, each line stamped with its UTC arrival time; runs in the foreground until Ctrl+C or `-DurationSeconds`; this machine's firewall must accept the UDP port, because one that drops it gives no sign ([how to open and check it](../../host/ubuntu.kvm/README.md#run-the-receiver)) -- see [Ubuntu KVM deep diagnostics mode](../../host/ubuntu.kvm/README.md#deep-diagnostics-mode) |
| `Invoke-HostRepair.ps1` | repair a wedged hypervisor within a bounded budget: probe and reclaim owned runner processes on all three hosts, and start a stopped hypervisor on Hyper-V or KVM when the rung is available, then restore the service VMs and runner it disrupted. It never reclaims the runner that called it. `-WhatIf` previews with no lock, request or mutation; `-Resume` finishes an interrupted repair; `-DisposeObligation` records that the operator took over one it could not finish. Exit `0` healthy or repaired, `1` refused or failed before changing anything, `2` needs attention |
| `Invoke-HostUpdate.ps1` | ask for a host update from this host's shell, the same request the Diagnostics page's **Update host** queues; it sends nothing over HTTP and writes one queued row for the host controller. `-Scope restart` (the default) or `full`, `-DrainSeconds`, `-ExpectCommit`, and `-Drain now`, which ends the running cycle instead of waiting for it and exists only here; it never preempts another update. Refused, with nothing queued, when no controller holds its lock, for a scope the controller does not run, or while another host operation holds the host. It prints the request id, the progress file (`runtime/host-update.state.json`) and the command that attaches to the runner's console. `-Release <id>` ends a claimed update: refused, naming the controller's process id, while a controller runs one that is not recovering; marks a recovering one and reports the verdict the controller writes within 60 seconds; with no controller, takes both locks, refuses while a step child of the update is alive (on Windows also while the shim's PowerShell upgrade may still run), ends the `full` scope's transient units (on macOS the process tree of its installer or `Enable-TestAutomation`) and removes its temporary sudo rule, opens the runner gate, starts nothing and writes `released` with what was still owed. Exit `0` queued or released, `1` refused, `2` could not run |
| `Invoke-HostUpdateController.ps1` | the host controller, started by the shim from a private snapshot under `~/.yuruna/host-repair/host-controller/versions/` (on Windows `%ProgramData%\yuruna\host-controller\versions\`), never from the checkout; it claims queued host updates and runs their phases, continuing from the journal after any interruption -- see [Host update and the runner's console](../../docs/runner-outer-loop.md#host-update-and-the-runners-console). Exit `75` start again on the current snapshot, `76` another controller holds the lock, `77` run the PowerShell 7 upgrade (Windows), `1` anything else |
| `Invoke-HostUpdateStep.ps1` | one phase of a host update (`preflight`, `stop_runner`, `update_source`, `install`, `enable`, `start_listener`, `start_runner`), started detached by the controller. It reads the request journal and never writes it; its outcome is a result file in `<controller root>/work/<request id>/` (`schemaVersion`, `step`, `requestId`, `attempt`, `outcome`, `reason`, `remarks`, `operatorAction`, `protocol`, `commit`, `runnerConsole`, `reclaimed`, `detail`), written last, and a path outside that folder is refused. Exit `0` done, `2` done with remarks, `3` skipped, `1` failed or no result |
| `yuruna-host-controller-shim.sh` | the POSIX `sh` supervisor of the controller that `Enable-TestAutomation` deploys as `<controller root>/shim`; on KVM the system unit `yuruna-host-controller.service` runs it, and on macOS, which registers no job, an ordinary runner start from the desktop session starts it in a detached session of its own. It starts the controller from the snapshot `current` names, restarts it with a backoff, rejects a snapshot that dies three times without starting, and passes a stop on without ever killing the controller |
| `yuruna-host-controller-shim.ps1` | the Windows supervisor of the controller that `Enable-TestAutomation` deploys as `%ProgramData%\yuruna\host-controller\shim.ps1` and the scheduled task "Yuruna Host Controller" runs under Windows PowerShell 5.1: it starts the controller from the snapshot `current` names, restarts it with a backoff, rejects a snapshot that dies three times without starting, runs the PowerShell 7 upgrade the controller asks for with exit `77`, and ends only the controller process on a stop |
| `Set-HostRepairCredential.ps1` | provision remote host-repair secrets: `-NewAuthority` creates the signing authority and operator credential for pool-control's `/etc/yuruna/host-repair/`, `-ExportHostKey -HostId -OutputPath` writes one host's verifier key, `-InstallHostKey -KeyPath` (or `-AuthorityDirectory`) installs it on that host, `-RemoveHostKey` withdraws it, and no switch reports the state; never prompts and never prints a secret -- see [remote host repair](../../docs/pool-admin.md#remote-host-repair) |

```
pwsh test/lab/Set-LabToken.ps1 -LabToken <code from the dashboard's Lab token tile>
```

`New-LocalLabStorage.ps1` calls `New-Lab.ps1` directly (same folder), and
is itself invoked by `install/setup.ps1`. `Clear-LocalLabStorage.ps1` is
run for you by [`../pool/Convert-ToPoolWorker.ps1`](../pool/Convert-ToPoolWorker.ps1)
when a standalone machine joins a lab.

`Start-Syzygy.ps1` and `Stop-Syzygy.ps1` resolve their sibling `../service`
directory from their own location, so an absolute invocation works from any
working directory. Common parameters such as `-WhatIf` and `-Confirm` are
passed to each service script.

A caching-proxy rebuild enrolls its verified signing key on discovered pool
hosts through authenticated host control. To repair existing hosts through the
same lab entry point, run `pwsh test/lab/Start-Syzygy.ps1`.
The proxy launcher enables recovery by default: it rebuilds the cache and
reports pending hosts without blocking the remaining service starts. Invalid
CA statements still stop startup. Existing CA pins remain in place until a
signed rotation verifies.

To restart the services when the next commit lands, run
`pwsh test/lab/Update-Syzygy.ps1` and answer its questions; `-IntervalSeconds`
sets how often it checks (default 5). Everything `Start-Syzygy.ps1` would ask
at its start is asked first: the optional GitHub token, and the sudo password
on macOS and Linux, which is then kept valid for the length of the wait. On
Windows it needs an elevated session, as the start does. The start then runs in
a new PowerShell process with `YURUNA_NONINTERACTIVE=1`, so it loads the pulled
code and asks nothing. A fetch or pull that fails ends the script without
starting anything; its exit code is otherwise the one `Start-Syzygy.ps1`
returned.

Walk-through: [Lab operator](../../docs/lab-operator.md).

## Path base

Scripts here that load harness modules resolve their roots through
`Initialize-YurunaEntryPoint -ScriptRoot $PSScriptRoot -InsideSubfolder`,
which walks one level up to `test/`. Pre-prelude imports use
`Join-Path $PSScriptRoot '../modules/<name>.psm1'`.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.11.23

Back to [Yuruna](../../README.md)
