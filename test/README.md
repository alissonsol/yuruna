# Yuruna Test Runner

Continuous test cycle across hosts and guests. For the internal
architecture (modules, directories, sequences, extension API) see
[Test harness](../docs/test-harness.md).

## What it does

Cycle summary in [Test harness](../docs/test-harness.md). On first failure the runner
copies debug artifacts to `test/status/log/`, sends a Resend
notification, and either preserves the VM or cleans it up depending on
`testCycle.shouldStopOnFailure`.

## Prerequisites

Same as the host setup — see
[macOS UTM ...](../host/macos.utm/README.md) or
[Windows Hyper-V ...](../host/windows.hyper-v/README.md).
Windows requires elevation; macOS does not.

## Configuration

Copy the template (it is git-ignored):

```
cp test/test.config.yml.template test/test.config.yml
```

Most operators only ever set `guestSequence`, `repositories.frameworkUrl`,
`repositories.projectUrl`, `statusService.port`, and `testCycle.shouldStopOnFailure`.
Notification credentials moved to
`test/status/extension/notification/transports.yml` -- see the
"Notifications (Resend)" section below.
Full key table, defaults, and behavioral notes:
[Test Runner](read.more.md).

`guestSequence` controls which guests run and in what order. Any
`guest.<name>` is valid as long as `host/<short-host>/<guestKey>/`
exists on the current host — the runner discovers guests by folder, not
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
   want validator runs to deliver mail. Full setup walkthrough:
   [Test Runner](read.more.md#notifications-resend--full-setup).

### Validate

```
pwsh test/Test-Config.ps1            # Live notification send
pwsh test/Test-Config.ps1 -SkipSend  # Skip the send
```

Each check prints `[PASS]`, `[WARN]`, or `[FAIL]`.

## Remote caching proxy

The runner auto-discovers a local `caching-proxy` VM. Point at a remote
proxy:

```
$Env:YURUNA_CACHING_PROXY_IP = '10.0.0.5'
pwsh test/Invoke-TestRunner.ps1
```

Setup, monitoring, SSL-bump, and offline replay:
[Caching](../docs/caching.md). Test-harness wrappers:
[Caching proxy](../docs/caching-proxy.md).

## Usage

```
pwsh test/Invoke-TestRunner.ps1                       # default
pwsh test/Invoke-TestRunner.ps1 -NoGitPull            # dev mode
pwsh test/Invoke-TestRunner.ps1 -NoServer             # headless
pwsh test/Invoke-TestRunner.ps1 -CycleDelaySeconds 60
pwsh test/Invoke-TestRunner.ps1 -logLevel Debug
```

`logLevel` (Error|Warning|Information|Verbose|Debug) controls which
PowerShell streams reach the console; each level cascades down (Error is
highest priority, default is `Information` so progress narration is
visible; only errors are shown if you set it to `Error`). See
[Test Runner](read.more.md). Status dashboard while the runner is
active: `http://localhost:8080/status/` (architecture in
[Test harness](../docs/test-harness.md)).

## Host pools

Run several hosts as one **pool** that share assigned test sequences and report
together. Default-off — a host with no `pool` config runs standalone. To create a pool
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

Each cycle writes `test/status/log/{cycleId}.{hostname}.{gitCommit}.html`
(git-ignored; linked from the status page). Exit codes:
[Test harness](../docs/test-harness.md#exit-codes).

Read more: [Test Runner](read.more.md).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.07

Back to [Yuruna](../README.md)
