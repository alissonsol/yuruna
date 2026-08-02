# Outer-loop dispatcher and runner state machine

The eternal cycle loop in
[`test/modules/Test.RunnerOuterLoop.psm1`](../test/modules/Test.RunnerOuterLoop.psm1)
is what makes the test runner resilient. It does five things in
sequence, then loops:

1. `git pull` the framework repo.
2. Wipe last cycle's `inner.pid` / `runner.stepHeartbeat` /
   `last_failure.json` / `break-active.json`.
3. Arm the [watchdog](watchdog.md).
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
| `Get-OuterStepTimeoutSeconds -ConfigPath -DefaultSeconds` | `testCycle.stepTimeoutSeconds` from config (hot-read each cycle). |
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
| `InnerScript` | `[string]` | Absolute path to `Invoke-TestRunnerInnerLoop.ps1`. |
| `PwshExe` | `[string]` | `pwsh` binary to invoke (operator's choice). |
| `ArgList` | `[string[]]` | Argv built by `Test.InnerSpawn\New-InnerRunnerArgList`. |
| `ForwardEnvSnapshot` | `[hashtable]` | Launch-time `YURUNA_*` env-var snapshot. |
| `ShutdownState` | `[hashtable]` | Reference-shared with the caller's Ctrl+C handler. Flipping `['Requested']` ends the loop. |
| `NoGitPull` | `[bool]` | Skip the framework pull (operator's `-NoGitPull` switch). |
| `FailurePauseMaxSeconds` | `[int]` | Failure-pause cap (default 60 min). |
| `FailureCommitPollSeconds` | `[int]` | Trigger-poll cadence inside the pause (default 5 min). |
| `OuterPullErrorSleepSeconds` | `[int]` | Short retry sleep when the outer's own `git pull` fails. |
| `InnerSpawnErrorSleepSeconds` | `[int]` | Short retry sleep when `Start-Process` itself fails. |
| `StepTimeoutSecondsDefault` | `[int]` | Watchdog default (overridden per-cycle by `testCycle.stepTimeoutSeconds`). |
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
transition table live in the
[Runner state machine](#runner-state-machine) section below.

| Cycle phase | Transition |
|---|---|
| Top of `while` | `idle -> cycle-start` |
| Watchdog armed | `cycle-start -> in-cycle` |
| Inner exited 0 | `in-cycle -> cycle-end -> idle` |
| Inner exited non-zero | `in-cycle -> fault` |
| Pool `desiredState=paused` (hold) | `cycle-start -> paused`, then `paused -> cycle-start` on the ~30s intent re-poll |
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

## Runner state machine

The outer test runner's lifecycle is an explicit six-state machine in
[`test/modules/Test.RunnerState.psm1`](../test/modules/Test.RunnerState.psm1).
Every transition writes `$YURUNA_RUNTIME_DIR/runner.state.json`
atomically and emits a `runner_state_transition` NDJSON event so a
dashboard or off-host consumer can follow the runner without
reconstructing what it is doing from heartbeat mtimes and pidfile
presence.

This module makes the lifecycle explicit. Without it, a watchdog or
dashboard has to guess: "if `inner.pid` exists and
`runner.stepHeartbeat` is fresh then a cycle is running, unless the
inner just exited and we're between cycles, unless..." — every
consumer reconstructing the state machine for itself from incomplete
signals. The explicit machine gives the lifecycle a single observable
shape.

### States

| State | Meaning |
|---|---|
| `idle` | The runner is alive and ready for the next cycle. |
| `cycle-start` | A new cycle is starting; pre-spawn work (git pull, cleanup) is in flight. |
| `in-cycle` | The inner runner is executing sequence steps. |
| `cycle-end` | The inner exited 0; the outer is in post-cycle cleanup. |
| `fault` | The inner exited non-zero or crashed before exit. |
| `paused` | The failure-pause loop is waiting for a new commit, a config edit, or the cap. |

### Valid transitions

```
idle         -> cycle-start, fault   (fault when boot recovery sees a stale prior state)
cycle-start  -> in-cycle, fault, paused
in-cycle     -> cycle-end, fault
cycle-end    -> idle
fault        -> paused, idle
paused       -> idle, cycle-start
```

The `cycle-start <-> paused` pair is the healthy pool-hold loop: when a
pulled pool intent has `desiredState=paused`, a started cycle moves to
`paused`, and each ~30s intent re-poll re-enters `cycle-start`.

The validator never rejects — an unrecognized pair logs a
`Write-Warning` and writes the new state anyway. Same contract as the
event-schema validator: catch drift loudly, never lose telemetry.

### Public surface

| Function | Used by |
|---|---|
| `Initialize-RunnerState` | Outer runner startup; reads the prior state file and synthesizes a crash recovery if a stale runId is found. |
| `Set-RunnerState -To <state> -Reason <text>` | The outer-loop dispatcher above, at every cycle boundary. |
| `Get-RunnerStateName` | Capability matrix; dashboard. |
| `Test-RunnerStateTransition -From <state> -To <state>` | Predicate validator; checks whether a `(From, To)` pair is an allowed transition. |

### Files on disk

| File | Writer | Reader | Purpose |
|---|---|---|---|
| `runner.state.json` | `Set-RunnerState` (atomic) | Status service, next outer's `Initialize-RunnerState`, post-mortem | Last 20 transitions + the current state, runId, cycleStartUtc. |
| NDJSON event stream | `Set-RunnerState` via [`Test.Log`](../test/modules/Test.Log.psm1) | Off-host log shipper | One event per transition: `runner_state_transition` with `(from, to, reason, runId, cycleStartUtc)`. |

### Boot recovery

On outer startup, `Initialize-RunnerState` reads the prior
`runner.state.json`. If it shows a runId other than ours AND a state
that isn't `idle`, the previous outer crashed mid-lifecycle. The
function synthesizes a `<stale-state> -> fault -> idle` transition
pair so a downstream consumer sees the crash explicitly, not as a
silent gap in the stream. Then it writes a fresh `idle` state under
the new runId.

This pairs with [`Test.Recovery`](../test/modules/Test.Recovery.psm1)'s
boot sweep, which clears stale `.incomplete` cycle folders, stale
`inner.pid`, and stale `break-active.json`. The state machine
synthesizes the *narrative*; `Test.Recovery` cleans the *state*.

### History depth

`runner.state.json` keeps the last 20 transitions inline as a cheap
"what just happened" cache for `/control/runner-status` and similar
quick lookups. The NDJSON stream is the canonical history; the
in-file slice is a convenience.

## Related

- [Watchdog protocol and module](watchdog.md) — the files-on-disk side plus the PowerShell contract for `Start-Watchdog`/`Stop-Watchdog`; the kill side that drives transitions into `fault`.
- [Remediation dispatcher](failure-schema.md#remediation-dispatcher) — what runs *after* a `fault`.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.02

Back to [Yuruna](../README.md)
