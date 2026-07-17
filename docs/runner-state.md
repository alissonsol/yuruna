# Runner state machine

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

## States

| State | Meaning |
|---|---|
| `idle` | The runner is alive and ready for the next cycle. |
| `cycle-start` | A new cycle is starting; pre-spawn work (git pull, cleanup) is in flight. |
| `in-cycle` | The inner runner is executing sequence steps. |
| `cycle-end` | The inner exited 0; the outer is in post-cycle cleanup. |
| `fault` | The inner exited non-zero or crashed before exit. |
| `paused` | The failure-pause loop is waiting for a new commit, a config edit, or the cap. |

## Valid transitions

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

## Public surface

| Function | Used by |
|---|---|
| `Initialize-RunnerState` | Outer runner startup; reads the prior state file and synthesizes a crash recovery if a stale runId is found. |
| `Set-RunnerState -To <state> -Reason <text>` | The [outer-loop dispatcher](runner-outer-loop.md) at every cycle boundary. |
| `Get-RunnerStateName` | Capability matrix; dashboard. |
| `Test-RunnerStateTransition -From <state> -To <state>` | Predicate validator; checks whether a `(From, To)` pair is an allowed transition. |

## Files on disk

| File | Writer | Reader | Purpose |
|---|---|---|---|
| `runner.state.json` | `Set-RunnerState` (atomic) | Status server, next outer's `Initialize-RunnerState`, post-mortem | Last 20 transitions + the current state, runId, cycleId. |
| NDJSON event stream | `Set-RunnerState` via [`Test.Log`](../test/modules/Test.Log.psm1) | Off-host log shipper | One event per transition: `runner_state_transition` with `(from, to, reason, runId, cycleId)`. |

## Boot recovery

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

## History depth

`runner.state.json` keeps the last 20 transitions inline as a cheap
"what just happened" cache for `/control/runner-status` and similar
quick lookups. The NDJSON stream is the canonical history; the
in-file slice is a convenience.

## Related

- [Watchdog and heartbeat protocol](watchdog.md) — the kill side that drives transitions into `fault`.
- [Remediation dispatcher](remediation.md) — what to do AFTER a `fault`.
- [Outer-loop dispatcher](runner-outer-loop.md) — the caller that emits every transition.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.17

Back to [Yuruna](../README.md)
