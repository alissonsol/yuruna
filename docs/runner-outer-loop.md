# Outer-loop dispatcher

The eternal cycle loop in
[`test/modules/Test.RunnerOuterLoop.psm1`](../test/modules/Test.RunnerOuterLoop.psm1)
is what makes the test runner resilient. It does five things in
sequence, then loops:

1. `git pull` the framework repo.
2. Wipe last cycle's `inner.pid` / `runner.stepHeartbeat` /
   `last_failure.json` / `break-active.json`.
3. Arm the [watchdog](runner-watchdog.md).
4. Spawn the inner runner via the call operator.
5. On `exitCode == 0`, loop immediately. On non-zero, pause until
   one of four break-out triggers fires.

The function was carved out of
[`test/Invoke-TestRunner.ps1`](../test/Invoke-TestRunner.ps1) so the
loop body is unit-testable independent of the entry-point script —
mocking the call-op + `Set-RunnerState` lets a test exercise the
state-transition sequence without spawning a real inner pwsh.

## Public surface

| Function | Purpose |
|---|---|
| `Invoke-RunnerOuterLoop -State <hashtable>` | The main dispatcher. Returns when `State.ShutdownState['Requested']` flips. |
| `Get-OuterCommitSha -RepoRoot` | Framework HEAD SHA. |
| `Test-OuterNewCommitsAvailable -RepoRoot -BaselineSha` | `git fetch` + compare against `@{u}`. |
| `Invoke-OuterGitPull -RepoRoot` | `git pull --ff-only --quiet`. |
| `Get-OuterRemoteSha -RemoteUrl` | `git ls-remote HEAD` (project repo, no local clone needed). |
| `Get-OuterConfigMtime -ConfigPath` | `Get-Item.LastWriteTimeUtc` (or `$null`). |
| `Get-OuterStepTimeoutMinute -ConfigPath -DefaultMinutes` | `testCycle.stepTimeoutMinutes` from config (hot-read each cycle). |
| `Get-OuterProjectUrl -ConfigPath` | `repositories.projectUrl` from config. |
| `Sync-ForwardEnv -ForwardEnvSnapshot` | Re-assert YURUNA_* env vars from a launch-time snapshot. |
| `Write-OuterLog -Message` | Append-only timestamped line to `runtime/outer.log`. |

Helpers are exported so a future test fixture or alternate driver
(`Invoke-CITestRunner`, a one-shot variant) can reuse them.

## State hashtable

`Invoke-RunnerOuterLoop` reads no caller-scope variables implicitly.
Every value the loop needs is threaded through `-State`. The 14
required keys, validated at entry:

| Key | Type | Purpose |
|---|---|---|
| `RepoRoot` | `[string]` | Framework repo root for the `git pull` calls. |
| `ConfigPath` | `[string]` | Resolved `test.config.yml` path. |
| `InnerScript` | `[string]` | Absolute path to `Invoke-TestInnerRunner.ps1`. |
| `PwshExe` | `[string]` | `pwsh` binary to invoke (operator's choice). |
| `ArgList` | `[string[]]` | Argv built by `Test.InnerSpawn\New-InnerRunnerArgList`. |
| `ForwardEnvSnapshot` | `[hashtable]` | Launch-time `YURUNA_*` env-var snapshot. |
| `ShutdownState` | `[hashtable]` | Reference-shared with the caller's Ctrl+C handler. Flipping `['Requested']` ends the loop. |
| `NoGitPull` | `[bool]` | Skip the framework pull (operator's `-NoGitPull` switch). |
| `FailurePauseMaxSeconds` | `[int]` | Failure-pause cap (default 60 min). |
| `FailureCommitPollSeconds` | `[int]` | Trigger-poll cadence inside the pause (default 5 min). |
| `OuterPullErrorSleepSec` | `[int]` | Short retry sleep when the outer's own `git pull` fails. |
| `InnerSpawnErrorSleepSec` | `[int]` | Short retry sleep when `Start-Process` itself fails. |
| `StepTimeoutMinutesDefault` | `[int]` | Watchdog default (overridden per-cycle by `testCycle.stepTimeoutMinutes`). |
| `WatchdogPollSeconds` | `[int]` | Watchdog poll cadence (default 30 s). |

A missing key throws `Invoke-RunnerOuterLoop: -State is missing
required key '<name>'.` at entry, catching wiring bugs at the
entry-point edit site rather than mid-cycle.

## Failure-pause break-out triggers

After the inner exits non-zero, the loop captures four baselines and
polls them every `FailureCommitPollSeconds` until the cap or one
trigger fires. The 5-second slice sleep inside the poll loop keeps
Ctrl+C responsive (`Start-Sleep` cannot be interrupted by our event
handler in long sweeps).

| Trigger | Baseline | Probe |
|---|---|---|
| Framework commit | `git rev-parse HEAD` | `git fetch` + `rev-parse @{u}` |
| Project commit | `git ls-remote <projectUrl> HEAD` | Same `ls-remote` at poll time |
| Local config edit | `Get-OuterConfigMtime` | Same call at poll time; `-ne` comparison handles changed / created / deleted in one shot |
| Status-UI start request | (none) | Existence of `$YURUNA_RUNTIME_DIR/control.cycle-restart` |

Network / IO failure on any individual probe is treated as "no
change for now" (return `$null` / unchanged baseline) so a flaky
network can't cut a pause short and a missing config file can't
crash the loop.

## State transitions emitted

The dispatcher calls `Set-RunnerState` at every cycle boundary so a
streaming consumer sees the lifecycle explicitly. Full enum and
transition table live in [Runner state machine](runner-state.md).

| Cycle phase | Transition |
|---|---|
| Top of `while` | `idle -> cycle-start` |
| Watchdog armed | `cycle-start -> in-cycle` |
| Inner exited 0 | `in-cycle -> cycle-end -> idle` |
| Inner exited non-zero | `in-cycle -> fault` |
| Entering failure-pause | `fault -> paused` |
| Pause broke out | `paused -> idle` |

Each `Set-RunnerState` call is `Get-Command`-guarded so a stripped-
down test fixture that did not import `Test.RunnerState` still runs
the loop body.

## Pre-spawn cleanup ordering

Order matters: `Remove-Item` first, then a "force-fresh"
`WriteAllText` on `runner.stepHeartbeat`. If `Remove-Item` fails on
the heartbeat (locked file, AV mid-scan, anything), the watchdog
about to arm would read the stale mtime and kill the new inner
within one poll. The unconditional `WriteAllText` defends against
that — the new inner overwrites it again immediately at startup, so
the force-touch is harmless when the wipe succeeded.

## Related

- [Watchdog protocol](watchdog.md) — files-on-disk side.
- [Watchdog module](runner-watchdog.md) — the PowerShell-side contract for `Start-Watchdog`/`Stop-Watchdog`.
- [Runner state machine](runner-state.md) — enum + transition table.
- [Remediation dispatcher](remediation.md) — what runs *after* a `fault`.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.26

Back to [Yuruna](../README.md)
