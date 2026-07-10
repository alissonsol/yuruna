# Runner watchdog module

[`test/modules/Test.RunnerWatchdog.psm1`](../test/modules/Test.RunnerWatchdog.psm1)
holds the two functions that arm and tear down the out-of-process
step-heartbeat watchdog: `Start-Watchdog` and `Stop-Watchdog`. The
file-on-disk heartbeat protocol the watchdog observes is documented in
[Watchdog and heartbeat protocol](watchdog.md); this page covers the
PowerShell-side contract.

Keeping these functions in their own module — rather than inline in
[`test/Invoke-TestRunner.ps1`](../test/Invoke-TestRunner.ps1) —
makes the heartbeat-kill logic testable in
isolation: a unit test can `Start-Watchdog`, write a stale
`runner.stepHeartbeat`, and observe the kill without spinning up an
inner runner.

## Public surface

| Function | Used by |
|---|---|
| `Start-Watchdog -StepTimeoutMinutes -RuntimeDir -PollSeconds` | [Outer-loop dispatcher](runner-outer-loop.md) per cycle |
| `Stop-Watchdog -Job` | Outer-loop dispatcher on cycle end / spawn failure |

`Start-Watchdog` returns a `System.Management.Automation.Job` whose
own child pwsh runs the polling scriptblock. `Stop-Watchdog` is
safe with `$null` and safe after the watchdog has already exited
(both `Stop-Job` and `Remove-Job` are `SilentlyContinue`).

## Why `Start-Job`, and why `runner.stepHeartbeat`

Both design rationales — why the watchdog is a `Start-Job` child pwsh
rather than an in-runspace timer, and why it observes
`runner.stepHeartbeat` (runspace-written) instead of the threadpool-
written `runner.heartbeat` — live in the protocol doc:
[why two heartbeats](watchdog.md#why-two-heartbeats) and
[the watchdog job](watchdog.md#watchdog-job). This page keeps only the
PowerShell-side contract.

## Polling sequence

1. Wait up to 60 s for `inner.pid` to appear. If it does not
   appear, log a `[watchdog]` line to `outer.log` and exit without
   action — preferable to picking a PID blindly.
2. Read `inner.pid`. If the value parses as a positive integer,
   arm; otherwise log and exit.
3. Every `PollSeconds` (default 30 s) check both:
   - The inner process is still alive (`Get-Process`). If it is
     gone, log "exited normally; watchdog disarming" and return.
   - `runner.stepHeartbeat` exists AND its mtime is younger than
     `StepTimeoutMinutes * 60`. If it is stale, log the observed
     age + threshold, `Stop-Process -Force` the inner, and return.

The outer detects a watchdog kill after the fact by comparing the
inner's non-zero exit code against the same staleness threshold —
see [Watchdog and heartbeat protocol](watchdog.md#detecting-a-watchdog-kill-after-the-fact).

## `$using:` scope discipline

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

- [Watchdog and heartbeat protocol](watchdog.md) — files-on-disk side.
- [Outer-loop dispatcher](runner-outer-loop.md) — the caller.
- [Runner state machine](runner-state.md) — what state the outer transitions through around the watchdog arm/disarm.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.10

Back to [Yuruna](../README.md)
