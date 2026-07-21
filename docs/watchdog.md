# Watchdog and heartbeat protocol

The test runner survives indefinitely under sustained guest, network,
and host-OS failures because every long-running activity emits a
heartbeat that an out-of-process watchdog reads. When the heartbeat
goes stale, the watchdog kills the wedged process and the outer
runner re-spawns the inner from a clean state.

This page covers the file-on-disk protocol and the PowerShell module
([Test.RunnerWatchdog](#module-testrunnerwatchdog)) that implements
the watchdog side. For the rationale on splitting outer / inner, see
[Outer-loop dispatcher](./runner-outer-loop.md).

## Layout under `$YURUNA_RUNTIME_DIR`

| File                     | Writer                  | Reader                | Purpose |
|--------------------------|-------------------------|-----------------------|---------|
| `runner.pid`             | outer runner            | next outer + status server | Single-instance guard; PID of the outer eternal-loop process. |
| `runner.start`           | outer runner            | next outer + status server | StartTime sidecar — used to confirm a recovered PID belongs to a still-live outer (forgery-resistant: PID reuse has a different StartTime). |
| `inner.pid`              | inner runner per cycle  | outer watchdog        | PID of the current inner cycle. Wiped by the outer before each spawn. |
| `runner.heartbeat`       | C# `System.Threading.Timer` inside inner | (legacy) | Liveness at the process level. Keeps ticking even when the runspace is wedged inside a non-terminating OCR / SSH loop — therefore **NOT a safe signal for "the cycle is making progress."** |
| `runner.stepHeartbeat`   | `Invoke-Sequence` at the top of each step | outer watchdog | Touched from the runspace itself. The signal the watchdog uses to detect a wedged step. |
| `outer.log`              | outer + inner           | post-mortem, status server | Append-only milestone log. Survives a `conhost` output wedge. |

## Why two heartbeats

`runner.heartbeat` is written by a `Yuruna.HeartbeatWriter`
`System.Threading.Timer` callback that fires on a threadpool thread.
This is robust to PowerShell pipeline blocks (the timer fires even
when the runspace is wedged) — which makes it useful as
"the inner process exists at all," but **blind to in-runspace hangs**.
A sequence step spinning forever in an OCR loop keeps the threadpool-
written heartbeat fresh.

`runner.stepHeartbeat` is touched from the runspace itself, at the
top of every step iteration inside `Invoke-Sequence`. A wedged step
stops touching it. The watchdog reads this file's mtime and kills the
inner when the mtime exceeds
`testCycle.stepTimeoutMinutes` (default 45).

The split was added after the trap recorded in repo memory
`feedback_threadpool_heartbeat_watchdog_blind.md`.

## Watchdog job

The outer's watchdog is a `Start-Job` (own pwsh) — heavier than an
in-runspace timer but independent of the outer's pipeline. The
outer's pipeline is blocked inside the call-operator that waits for
the inner; any in-runspace monitor (`Register-ObjectEvent`,
ThreadJob) cannot pump while the outer is in that wait. The Start-Job
child fires reliably even when the outer is completely wedged on
the spawn.

The watchdog:

1. Waits up to 60 s for `inner.pid` to appear. If it never does,
   logs a `[watchdog]` line to `outer.log` and exits without
   action — preferable to picking a PID blindly.
2. Reads `inner.pid`. If the value parses as a positive integer,
   arms; otherwise logs and exits.
3. Every `WatchdogPollSeconds` (default 30 s) checks both:
   - The inner process is still alive (`Get-Process`). If it is
     gone, logs "exited normally; watchdog disarming" and returns.
   - `runner.stepHeartbeat`'s mtime is younger than the threshold.
4. On a stale heartbeat: appends a `[watchdog]` line to `outer.log`
   with the observed age and threshold, then `Stop-Process -Force` on
   the inner.

## Detecting a watchdog kill after the fact

When the inner exits non-zero AND `runner.stepHeartbeat`'s mtime is
older than the threshold, the cause was almost certainly the watchdog
(the application-level failure path cannot run after a `SIGKILL` /
`TerminateProcess`). The outer prints:

```
[outer cycle N] inner exited non-zero AND runner.stepHeartbeat is
<age>s stale (threshold <thresh>s) -- watchdog likely killed the
inner. See runtime/outer.log for the kill line.
```

This stops operators from chasing an application-level bug that
never happened.

## Tuning `testCycle.stepTimeoutMinutes`

Default 45 minutes. Hot-reloaded on every cycle's spawn, so an
operator can edit `test.config.yml` between cycles without restarting
the outer. Tightening helps on hosts where genuine slow steps complete
under, say, 20 min; loosening protects against a known-slow first-run
image-build step.

## Module: Test.RunnerWatchdog

[`test/modules/Test.RunnerWatchdog.psm1`](../test/modules/Test.RunnerWatchdog.psm1)
holds the two functions that arm and tear down the watchdog:
`Start-Watchdog` and `Stop-Watchdog`. Keeping them in their own
module — rather than inline in
[`test/Invoke-TestRunner.ps1`](../test/Invoke-TestRunner.ps1) —
makes the heartbeat-kill logic testable in isolation: a unit test can
`Start-Watchdog`, write a stale `runner.stepHeartbeat`, and observe
the kill without spinning up an inner runner.

| Function | Used by |
|---|---|
| `Start-Watchdog -StepTimeoutMinutes -RuntimeDir -PollSeconds` | [Outer-loop dispatcher](runner-outer-loop.md) per cycle |
| `Stop-Watchdog -Job` | Outer-loop dispatcher on cycle end / spawn failure |

`Start-Watchdog` returns a `System.Management.Automation.Job` whose
own child pwsh runs the polling scriptblock. `Stop-Watchdog` is
safe with `$null` and safe after the watchdog has already exited
(both `Stop-Job` and `Remove-Job` are `SilentlyContinue`).

### `$using:` scope discipline

The scriptblock passed to `Start-Job` reads `$RuntimeDir`,
`$thresholdSec`, and `$PollSeconds` via `$using:` rather than
`-ArgumentList`. The `$using:` form pulls each variable straight from
the enclosing function's scope at job-dispatch time — cleaner than
threading them through a positional argument list, and dodges a
PSScriptAnalyzer false positive on
`PSUseUsingScopeModifierInNewRunspaces` when the scriptblock has its
own `param()` declaration.

The function carries an explicit
`[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PollSeconds')]`
because PSSA's static analyzer does not follow `$using:` references
back to the enclosing function's param block.

## Related

- [Outer-loop dispatcher](runner-outer-loop.md) — the caller that
  arms and disarms the watchdog each cycle.
- [Runner state machine](runner-state.md) — what state the outer
  transitions through around the watchdog arm/disarm.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.21

Back to [Yuruna](../README.md)
