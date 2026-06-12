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
`project/test/test.runner.yml` to derive an ordered execution plan,
and runs every sequence inline through
[`Invoke-Sequence.psm1`](Invoke-Sequence.psm1) — the engine that
implements the YAML `actions` (keystrokes, OCR waits, SSH pushes,
etc.). Action reference and per-host
[Yuruna.Host](../../host) contract notes:
[Sequence actions and host contracts](../../docs/test-sequences.md).

### Where the work lives

- **Runner definition** — [`project/test/test.runner.yml`](../../project/test/test.runner.yml):
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
| `Resolve-CyclePlan` | Reads `project/test/test.runner.yml` and walks each top-level sequence's baseline chain to produce ordered `(topLevel, guestKey, fullChain)` entries. |
| `Get-CyclePlanGuestList` | Deduplicated guest list in plan order — used for pre-flight folder checks and image refresh. |
| `Get-CyclePlanSequencesForGuest` | Merged `startSequences` / `workloadSequences` for a single guest across all matching plan entries (current runner contract: one VM lifecycle per unique guest). |

Sequences whose name starts with `start.` route to the runner's
`Start-GuestOS` step; everything else routes to `Start-GuestWorkload`.

## Three loggers, three jobs

Three modules in this tree carry "Log" or `Write-*` helpers in their
exports. The names look interchangeable from a distance; in practice
they own three disjoint responsibilities, and a contributor who adds
helpers to the wrong one introduces silent shadowing. Pick one with
this decision tree:

- **Want every console `Write-*` to also land in the cycle HTML?**
  Use [`automation/Yuruna.Log.psm1`](../../automation/Yuruna.Log.psm1)
  (it's already loaded for you via `Initialize-YurunaEntryPointModuleSet`).
- **Need cycle-folder paths, NDJSON event lines, or the per-cycle
  `manifest.json`?** Use [`Test.Log.psm1`](Test.Log.psm1).
- **Writing a one-shot `Test-*` check script that needs a PASS/FAIL
  tally + a 0/1 exit code at the end?** Use [`Test.Output.psm1`](Test.Output.psm1).
- **None of the above?** Don't add a fourth logger — open an issue and
  describe the gap. The three modules below cover the framework's
  documented logging contract; a new one almost certainly belongs as
  a function inside one of them.

### Niches

| Module | Path | Job | Doesn't do |
|---|---|---|---|
| `Yuruna.Log` | [`automation/Yuruna.Log.psm1`](../../automation/Yuruna.Log.psm1) | **Stream interceptor.** Shadows `Write-Output`, `Write-Error`, `Write-Warning`, `Write-Debug`, `Write-Verbose`, `Write-Information` so every framework call that goes to the operator's console also gets teed into `$global:__YurunaLogFile`. | Doesn't manage filesystem layout; doesn't tally PASS/FAIL. |
| `Test.Log` | [`Test.Log.psm1`](Test.Log.psm1) | **Cycle-filesystem owner.** Creates `test/status/log/<cycleFolder>/`, manages per-guest subfolders (`Get-CycleGuestDataFolder`, `Get-CycleScreenDir`), appends to `cycle.events.ndjson` (`Write-CycleNdjsonEvent`), writes `manifest.json` at cycle close (`Write-CycleManifest`). | Doesn't wrap any `Write-*` cmdlet; doesn't print to the console directly. |
| `Test.Output` | [`Test.Output.psm1`](Test.Output.psm1) | **Per-script PASS/FAIL tally.** `Write-Pass` / `Write-Fail` / `Write-Warn` / `Write-Info` / `Write-Section` increment counters in a script-scope state object; `Write-Summary` prints a banner + final pass/fail count; `Exit-WithSummary` exits 0/1 accordingly. Used by `Test-Config.ps1`, `Test-Configuration.ps1`, `Test-Requirement.ps1`. | Doesn't touch the cycle folder; doesn't shadow standard cmdlets. |

### Drift scenarios this section prevents

- A `Write-Pass` added to `Test.Log` would silently shadow `Test.Output`'s
  `Write-Pass` whenever both modules are imported, and the cycle's
  pass/fail tally would stop incrementing without any error.
- A `Start-Log` added to `Yuruna.Log` would compete with `Test.Log`'s
  `Start-LogFile` and create two cycle folders per cycle.
- A fourth logger ("just a small one") that nobody noticed already
  existed in one of the three above.

If you find an existing function that doesn't fit any of the three
niches, that's the surface this section is protecting against; either
move it into the correct module or update this table.

### Adding a new test

1. Drop a `<phase>.<guest-key>[.<suffix>].yml` sequence under either
   `test/sequences/<mode>/` (framework-generic) or
   `project/<...>/test/<mode>/` (project-specific).
2. Set `baseline` to the guest OS keys and prerequisite sequence
   names. An empty array terminates the chain (used by `start.guest.*`).
3. Reference the new sequence (or anything that depends on it) from
   the `project/test/test.runner.yml` `sequences` list.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.12

Back to [Yuruna](../../README.md)
