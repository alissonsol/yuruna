# Test Modules

Cross-host harness modules. Each is a `.psm1` imported by
[`../Invoke-TestRunner.ps1`](../Invoke-TestRunner.ps1) (and ad-hoc by
[`../Test-Sequence.ps1`](../Test-Sequence.ps1) for one-off
sequence runs). Module list and per-module purpose:
[Test harness — architecture](../../docs/test-harness.md#module-responsibilities).

This folder also holds [`Invoke-TestInnerRunner.ps1`](Invoke-TestInnerRunner.ps1) —
the single-cycle inner that the outer `Invoke-TestRunner.ps1` spawns
once per cycle. It lives here (not in `test/`) so the entry-point
folder contains only operator-facing scripts; the inner is an
implementation detail of the outer runner and should not be invoked
directly. The defensive single-instance guard inside it warns and
exits if it detects an outer already running.

## Sequence engine and cycle planner

The cycle no longer needs per-guest `.ps1` extensions. The runner walks
`project/test/test.sequence.yml` to derive an ordered execution plan,
and runs every sequence inline through
[`Invoke-Sequence.psm1`](Invoke-Sequence.psm1) — the engine that
implements the YAML `actions` (keystrokes, OCR waits, SSH pushes,
etc.). Action reference and per-host
[Yuruna.Host](../../host) contract notes:
[Sequence actions and host contracts](../../docs/test-sequences.md).

### Where the work lives

- **Cycle definition** — [`project/test/test.sequence.yml`](../../project/test/test.sequence.yml):
  top-level workload sequence names to drive each cycle.
- **Per-sequence baseline** — every sequence's `baseline` field
  declares which guest OSes it supports and which prerequisite
  sequences must complete first, keyed by OS:
  ```json
  "baseline": { "ubuntu.server.24": ["start.guest.ubuntu.server.24"] }
  ```
  Walking these recursively produces the dependency-ordered chain.
- **Sequence files** —
  - Generic per-OS sequences live under
    [`../sequences/{gui,ssh}/`](../sequences/) — e.g.
    `start.guest.<os>.yml`, `workload.guest.<os>.yml`.
  - Project-specific sequences live with the project itself, under
    `project/<...>/test/{gui,ssh}/` (e.g.
    `project/example/website/test/gui/workload.guest.ubuntu.server.24.k8s.website.yml`).
  - `Resolve-SequencePath` searches the project tree first, then the
    framework, with `gui/` fallback for missing `ssh/` variants.

### Cycle planner

[`Test.SequencePlanner.psm1`](Test.SequencePlanner.psm1) exposes:

| Function | Purpose |
|---|---|
| `Resolve-CyclePlan` | Reads `project/test/test.sequence.yml` and walks each top-level baseline to produce ordered `(topLevel, guestKey, fullChain)` entries. |
| `Get-CyclePlanGuestList` | Deduplicated guest list in plan order — used for pre-flight folder checks and image refresh. |
| `Get-CyclePlanSequencesForGuest` | Merged `startSequences` / `workloadSequences` for a single guest across all matching plan entries (current runner contract: one VM lifecycle per unique guest). |

Sequences whose name starts with `start.` route to the runner's
`Start-GuestOS` step; everything else routes to `Start-GuestWorkload`.

### Adding a new test

1. Drop a `<phase>.<guest-key>[.<suffix>].yml` sequence under either
   `test/sequences/<mode>/` (framework-generic) or
   `project/<...>/test/<mode>/` (project-specific).
2. Set `baseline` to the guest OS keys and prerequisite sequence
   names. An empty array terminates the chain (used by `start.guest.*`).
3. Reference the new sequence (or anything that depends on it) from
   `project/test/test.sequence.yml` `baseline`.

Back to [Test runner](../README.md) · [Test harness](../../docs/test-harness.md) · [Yuruna](../../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
