# Yuruna Test Runner

Continuous test cycle across hosts and guests. For the internal
architecture (modules, directories, sequences, extension API) see
[Test harness](../docs/test-harness.md).

## What it does

Cycle summary in [Test harness](../docs/test-harness.md). On first failure the runner
copies debug artifacts to `test/status/log/`, sends a Resend
notification, and either preserves the VM or cleans it up depending on
`testCycle.stopOnFailure`.

## Where the scripts are

`test/` itself holds only the seven commands reached for daily --
`Start-TestRunner.ps1`, `Invoke-TestProject.ps1`, `Debug-TestSequence.ps1`,
`Test-Config.ps1`, `Test-CachingProxyService.ps1`,
`New-LocalTestUser.ps1`, `Remove-TestVMFiles.ps1`. Everything else is grouped
by what it acts on:

| Folder | Holds |
|---|---|
| [`lab/`](lab/) | standing a lab up on this host: the four host-neutral entry points, lab creation, local storage, token enrollment |
| [`pool/`](pool/) | the pool-admin CLI -- everything that reads or writes a lab's pool intent -- and the sample intent files |
| [`service/`](service/) | start/stop pairs for the service VMs and the host config/status services (`Start-StatusService.ps1` among them), plus the caching-proxy-service operations |
| [`check/`](check/) | standalone host-capability checks (OCR engines) |
| [`modules/`](modules/) | harness modules and the two per-cycle children; not invoked directly |

Each folder has its own README. The repo-wide encoding gate lives outside
`test/` at [`tools/Test-AsciiNoBom.ps1`](../tools/Test-AsciiNoBom.ps1), because
it gates commits and releases rather than a host.

## Prerequisites

Same as the host setup -- see
[macOS UTM ...](../host/macos.utm/README.md) or
[Windows Hyper-V ...](../host/windows.hyper-v/README.md).
Windows requires elevation; macOS does not.

## Host setup

Four host-neutral entry points. Each detects the host and runs that host's
copy of the script from `host/<host type>/`, so the same command works on
every host:

```
pwsh test/lab/Enable-TestAutomation.ps1                        # prepare this host for unattended runs
pwsh test/lab/Disable-TestAutomation.ps1                       # ... and put those host settings back
pwsh test/lab/Sync-HostConfiguration.ps1 -ReferenceHost <host> # copy another pool host's test.config.yml
pwsh test/lab/Remove-OrphanedVMFiles.ps1                       # delete files left by VMs that are already gone
```

Arguments (`-WhatIf` among them) are forwarded to the per-host script, which
owns the behavior and documents it:
[macOS UTM](../host/macos.utm/README.md),
[Windows Hyper-V](../host/windows.hyper-v/README.md),
[Ubuntu KVM](../host/ubuntu.kvm/README.md). On Windows,
`Enable-TestAutomation` and `Sync-HostConfiguration` must be run from an
elevated PowerShell.

`Remove-OrphanedVMFiles` only sweeps files whose VM is already gone. To stop
and unregister the test VMs *and* sweep, use `pwsh test/Remove-TestVMFiles.ps1`.

## Configuration

Copy the template (it is gitignored):

```
cp test/test.config.yml.template test/test.config.yml
```

Most operators only set `guestSequence`, `repositories.frameworkUrl`,
`repositories.projectUrl`, `statusService.port`, and `testCycle.stopOnFailure`.
Notification credentials live in
`test/status/extension/notification/transports.yml` -- see the
"Notifications (Resend)" section below.
Full key table, defaults, and behavioral notes:
[Test Runner](read.more.md).

`guestSequence` controls which guests run and in what order. Any
`guest.<name>` is valid as long as `host/<short-host>/<guestKey>/`
exists on the current host -- the runner discovers guests by folder, not
a hardcoded list. Adding a new guest = creating the folder with
`Get-Image.ps1` + `New-VM.ps1`; no harness code change.

### Notifications (Resend)

1. Create a free account at [resend.com](https://resend.com) and an
   [API key](https://resend.com/api-keys).
2. Copy
   `test/extension/notification/transports.yml.template` to
   `test/status/extension/notification/transports.yml` (gitignored). Fill
   `transports.resend.apiKey` and `transports.resend.fromEmail`, then
   add subscribers under `subscribers["cycle.failure"]` (one entry per
   recipient). Leave `subscribers["config.smoke"]` empty unless you
   want validator runs to deliver mail. Full setup walk-through:
   [Test Runner](read.more.md#notifications-resend--full-setup).

### Validate

```
pwsh test/Test-Config.ps1            # Live notification send
pwsh test/Test-Config.ps1 -SkipSend  # Skip the send
```

Each check prints `[PASS]`, `[WARN]`, or `[FAIL]`.

## Remote caching-proxy-service

The runner auto-discovers a local `caching-proxy-service` VM. Point at a remote
proxy by setting `vmStart.cachingProxyIp` in `test/test.config.yml`
(or on the status page) -- it is probed first at cycle start and wins
when its `:3128` answers. The session-scope alternative is the env
var, consulted only when the config key is empty or unreachable:

```
$Env:YURUNA_CACHING_PROXY_SERVICE_IP = '10.0.0.5'
pwsh test/Start-TestRunner.ps1
```

Setup, monitoring, SSL-bump, and offline replay:
[Caching](../docs/caching.md). Test-harness wrappers:
[Caching-proxy service](../docs/caching.md#caching-proxy-service--test-harness-operator-reference).

## Usage

```
pwsh test/Start-TestRunner.ps1                       # default
pwsh test/Start-TestRunner.ps1 -NoGitPull            # dev mode
pwsh test/Start-TestRunner.ps1 -NoStatusService      # headless
pwsh test/Start-TestRunner.ps1 -CycleDelaySeconds 60
pwsh test/Start-TestRunner.ps1 -logLevel Debug
```

`logLevel` (Error|Warning|Information|Verbose|Debug) controls which
PowerShell streams reach the console; each level cascades down from Error
(highest priority). The default `Information` keeps progress narration
visible; `Error` shows only errors. See
[Test Runner](read.more.md). Status dashboard while the runner is
active: `http://localhost:8080/status/` (architecture in
[Test harness](../docs/test-harness.md)).

## Host pools

Run several hosts as one **pool** that shares assigned test sequences and reports
together. Default-off -- a host with no `pool` config runs standalone. To create a pool
and assign already-developed test sequences to it, see the operator guide
[Pool admin](../docs/pool-admin.md).

## Sequences and screenshots

- Test sequences are YAML under `test/sequences/` (framework-generic)
  or `project/<...>/test/` (project-specific), dispatched via the
  cycle planner. Full architecture: [Test Modules](modules/README.md).
  Action reference + per-host
  [Yuruna.Host](../host) contract notes (snapshot + rename behavior,
  screen I/O divergence): [Sequence actions](../docs/test-sequences.md).

## Logging

Each cycle writes `test/status/log/{cycleStartUtc}.{hostname}.{gitCommit}.html`
(gitignored; linked from the status page). Exit codes:
[Test harness](../docs/test-harness.md#exit-codes).

Read more: [Test Runner](read.more.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.25

Back to [Yuruna](../README.md)
