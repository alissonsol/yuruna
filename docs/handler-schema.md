# Sequence-Action Handler Schema

> Contract for the verb-Handler registry that drives the YAML sequence
> engine in [`Invoke-Sequence.psm1`](../test/modules/Invoke-Sequence.psm1).

## Overview

A **Handler** is a PowerShell scriptblock registered against a verb
name (`waitForSeconds`, `pressKey`, `inputText`, ...) via
`Register-SequenceAction`. When the engine walks a YAML sequence and
hits a step with `action: <verb>`, it looks up the verb in
`$global:YurunaSequenceActions`. If the entry has a `Handler`, the
engine dispatches via `Invoke-SequenceActionHandler` and the handler
takes over; otherwise the engine falls back to the legacy `switch`
arm in `Invoke-Sequence` (a migration safety net).

Two modules carry the contract:

- **[`Test.SequenceAction.psm1`](../test/modules/Test.SequenceAction.psm1)** —
  registry primitives (`Register-`, `Get-`, `Invoke-`,
  `Test-...HasHandler`, `Clear-`). Owns the field shape and the
  `FailureClass` / `Severity` / `SuggestedRecoveries` value sets.
- **[`Test.SequenceHandler.psm1`](../test/modules/Test.SequenceHandler.psm1)** —
  the actual Handler bodies for built-in verbs. Adding a new verb is
  a local edit here, not a merge-conflict magnet on the engine.

## The `$Context` hashtable

Every Handler receives a single argument: a `[hashtable]` named
`$Context` (conventional alias `$c`). The engine populates it before
dispatch.

| Field                  | Type                          | Meaning                                                                    |
|------------------------|-------------------------------|----------------------------------------------------------------------------|
| `Step`                 | `IDictionary`                 | The parsed YAML step. Field access via dot (`$c.Step.name`) or `.Contains`.|
| `StepNum`              | `int` (1-based)               | Position of this step within the current sequence.                         |
| `StepCount`            | `int`                         | Total step count in the current sequence.                                  |
| `Steps`                | `IList`                       | Full parsed sequence; only `retry` typically inspects this.                |
| `Vars`                 | `hashtable` (writable)        | Variable scope. `Expand-Variable` reads from it; some verbs write back.    |
| `VMName`               | `string`                      | Target VM name on the current host.                                        |
| `GuestKey`             | `string`                      | Planner identity for the guest (e.g. `ubuntu.server.24`).                  |
| `HostType`             | `string`                      | Host platform (`windows.hyper-v`, `macos.utm`, `ubuntu.kvm`, ...).         |
| `LogDir`               | `string`                      | Per-cycle log directory.                                                   |
| `RuntimeDir`           | `string`                      | Per-cycle runtime/control-flag directory.                                  |
| `ScreenshotDir`        | `string`                      | Where OCR snapshots and screenshots go.                                    |
| `SequencePath`         | `string`                      | Path to the YAML sequence currently being executed.                        |
| `Description`          | `string`                      | Engine-expanded human description for this step.                           |
| `ShowSensitive`        | `bool`                        | When `$true`, masked text (passwords) may be logged literally.             |
| `ExpandVariable`       | `scriptblock` reference       | Live `Expand-Variable` function (Test.SequenceAction does not import it).  |
| `DefaultTimeoutSeconds`| `int`                         | Engine default for verbs that take a `timeoutSeconds:` field.              |
| `DefaultPollSeconds`   | `int`                         | Engine default for verbs that poll.                                        |
| `WriteCurrentAction`   | `scriptblock`                 | Engine callback for updating the "current action" status feed.             |
| `WaitWhilePaused`      | `scriptblock`                 | Engine callback that blocks until a pause flag clears.                     |
| `InvokeStepBlock`      | `scriptblock`                 | Recursive dispatcher for verbs that nest steps (`retry`, ...).             |

Handlers should treat `$Context` as read-mostly. The two fields that
are legitimately mutable are `$Context.Vars` (write a captured value
back for later steps to consume) and the screenshot/log directories
(side-effect writes are expected).

## Return-value contract

A Handler returns `[bool]`:

- `$true` — the step succeeded. The engine moves on.
- `$false` — the step failed, but in an *expected*, well-modelled way.
  The engine consults `FailureLabel`, `FailureClass`, `Severity`, and
  `SuggestedRecoveries` to fill out `last_failure.json` and routes to
  `retry` / `recoverFromSnapshot` if those wrap the failing step.
- **Throw** — the engine treats it as an unexpected handler bug. The
  exception message is captured in the failure record with
  `FailureClass = 'script_error'` regardless of the registered class.

A bare `return` (no value) is coerced to `$false`. Always be explicit.

## `Register-SequenceAction` parameters

| Parameter            | Type / values                                                                                                                                                                                                                                                                                  | Notes                                                                                                                                                       |
|----------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Name`               | `[string]` (mandatory)                                                                                                                                                                                                                                                                         | Verb as it appears in YAML `action:` fields. Case-sensitive on read, OrdinalIgnoreCase on registry lookup.                                                  |
| `FailureLabel`       | `[scriptblock]` `param($Context)` → `[string]`                                                                                                                                                                                                                                                 | Builds the human-readable failure label. Defaults to the verb name when omitted.                                                                            |
| `HostIORequirement`  | `[string[]]` from `Send-Key`, `Send-Text`, `Send-Click`                                                                                                                                                                                                                                        | Consumed by `Test-CyclePlanCapability` to refuse cycles on hosts that can't drive the needed I/O.                                                           |
| `OcrRequired`        | `[bool]`                                                                                                                                                                                                                                                                                       | `$true` when the verb needs at least one enabled OCR provider.                                                                                              |
| `Description`        | `[string]`                                                                                                                                                                                                                                                                                     | Free-form note. Surfaces in the capability matrix and future docs page.                                                                                     |
| `Aliases`            | `[string[]]`                                                                                                                                                                                                                                                                                   | Alternate YAML names that resolve to the same entry (legacy renames).                                                                                       |
| `Handler`            | `[scriptblock]` `param([hashtable]$c)` → `[bool]`                                                                                                                                                                                                                                              | The body that runs when the verb dispatches. Optional during migration; without it, the engine falls back to its legacy switch arm.                       |
| `FailureClass`       | `ValidateSet`: `ocr_timeout`, `network_timeout`, `credential_expired`, `host_io_blocked`, `pattern_matched_failure`, `retry_exhausted`, `snapshot_restore_failed`, `script_error`, `wait_timeout`, `extension_error`, `instrumentation_failure`, `provisioning_failure`, `bootstrap_sync`, `plan_invalid`, `unknown`                                       | Machine-readable failure category for downstream routing (no regex-on-label needed).                                                                        |
| `Severity`           | `ValidateSet`: `hard`, `soft`, `unknown`                                                                                                                                                                                                                                                       | `soft` = retry is plausible; `hard` = retry won't help (e.g. snapshot restore failed); `unknown` = no claim either way.                                     |
| `SuggestedRecoveries`| `[string[]]` — free-form, ordered                                                                                                                                                                                                                                                              | Hints for an autonomous remediation loop. Common values: `retry_immediately`, `wait_and_retry`, `restore_snapshot`, `notify_operator`. Not validated.       |

## Example registration: `waitForSeconds`

```
Register-SequenceAction -Name 'waitForSeconds' `
    -HostIORequirement @() -OcrRequired $false `
    -FailureClass 'wait_timeout' -Severity 'soft' `
    -SuggestedRecoveries @('retry_immediately') `
    -Description 'Sleep N seconds with progress ticks.' `
    -Handler {
        param([hashtable]$c)
        $secs = [int]$c.Step.seconds
        for ($r = $secs; $r -gt 0; $r--) {
            $pct = [math]::Round((($secs - $r) / [math]::Max($secs,1)) * 100)
            Write-ProgressTick -Activity 'waitForSeconds' -Status "${r}s remaining" -PercentComplete $pct
            Start-Sleep -Seconds 1
        }
        Write-ProgressTick -Activity 'waitForSeconds' -Completed
        return $true
    }
```

A verb that drives host I/O (`pressKey`) adds the `HostIORequirement`
plus a `FailureLabel` so the rendered failure includes the key name:

```
Register-SequenceAction -Name 'pressKey' `
    -HostIORequirement @('Send-Key') -OcrRequired $false `
    -FailureClass 'host_io_blocked' -Severity 'soft' `
    -SuggestedRecoveries @('retry_immediately') `
    -Description 'Send a single named keystroke.' `
    -FailureLabel { param($c) "pressKey: $($c.Step.name)" } `
    -Handler {
        param([hashtable]$c)
        return [bool](Invoke-Sequence\Send-Key `
            -HostType $c.HostType -VMName $c.VMName `
            -KeyName $c.Step.name)
    }
```

Note the `Invoke-Sequence\Send-Key` qualified call: `Send-Key` is also
a platform cmdlet name in some host modules, so qualified resolution
is mandatory in Handlers that talk to host I/O. The same rule applies
to `New-VM` / `Start-VM` / `Stop-VM` / `Remove-VM` and any other
contract export whose unqualified name collides with a platform
cmdlet (notably Hyper-V on Windows).

## How a new verb gets added

1. Pick a Name (camelCase, present-tense imperative) and decide which
   `HostIORequirement` items it needs (`@()` if pure-PowerShell with
   no host I/O).
2. Add a `Register-SequenceAction ...` block to
   [`Test.SequenceHandler.psm1`](../test/modules/Test.SequenceHandler.psm1).
3. Fill in the metadata: `FailureClass` (pick from the ValidateSet —
   if none fits, prefer `unknown` over inventing a new class without
   updating the ValidateSet in `Test.SequenceAction.psm1`), `Severity`,
   ordered `SuggestedRecoveries`.
4. Write the Handler body. Use `$c.ExpandVariable` for any
   user-supplied string fields; `$c.Vars` for variable expansion
   context. Return `[bool]`.
5. If the verb has a non-trivial failure label (e.g. the YAML field
   names the target), add a `FailureLabel` scriptblock.
6. If the verb takes user-supplied YAML field names that overlap with
   a deprecated spelling, add the deprecated spelling to `Aliases`.

No edit to `Invoke-Sequence.psm1` is required for the registry path —
the engine discovers the registration via `$global:YurunaSequenceActions`.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.07

Back to [Yuruna](../README.md)
