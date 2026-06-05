# Failure record schema

When a sequence step fails (or the engine crashes mid-step), the runner
writes `$YURUNA_LOG_DIR/last_failure.json` and emits one `step_failure`
NDJSON line into `cycle.events.ndjson`. Both are produced from one
builder — [`New-SequenceFailureRecord`](../test/modules/Test.SequenceFailureState.psm1)
in the slot-owning module — so the on-disk record and the event stream
can never drift on classification or fields. The
[remediation dispatcher](remediation.md) routes on `failureClass`; the
class/severity/recovery vocabulary comes from each verb's registration
(see [handler schema](handler-schema.md)).

## `last_failure.json` (schema v2)

Top-level fields, in order:

| Field | Type | Notes |
|---|---|---|
| `schemaVersion` | int | `2`. Readers branch on this. |
| `stepNumber` | int | 1-based position of the failing step (the outer step for a retry-exhausted failure). `0` on a crash before any step. |
| `totalSteps` | int | Steps in the sequence. |
| `action` | string | Human failure label. For retry-exhausted, already wrapped `retry exhausted (N attempts): …`; for a crash with no label, `engine crash: <message>`. |
| `description` | string | The step's `description:`. |
| `vmName` / `guestKey` | string | Failing guest identity. |
| `timestamp` | string | UTC `yyyy-MM-dd HH:mm:ss`. |
| `failureClass` | enum | Machine-routable class from the failing verb's registration; `unknown` when the verb is unresolved; `pattern_matched_failure` when `Wait-ForText` short-circuited on a hard-block pattern. |
| `severity` | enum | `hard` / `soft` from the verb; `unknown` when unresolved. |
| `suggestedRecoveries` | string[] | Verb's `SuggestedRecoveries` (always a JSON array, never `null`). |
| `actionVerb` | string | The failing verb name (`script_error` for an unattributed crash). |

### Step-failure-only fields

These appear on a normal step failure (omitted on a crash record):

| Field | Type | Notes |
|---|---|---|
| `lastSucceededStepNumber` | int | Replay boundary — step N succeeded; the failure landed on N+1. A "what's safe to replay past" marker, not an auto-resume pointer. |
| `innerActionVerb` / `innerFailureClass` / `innerSeverity` / `innerSuggestedRecoveries` | string / string / string / string[] | Set only when the failure bubbled through an exhausted `retry`; carry the deepest inner verb's classification so a remediator routes on the inner cause rather than the outer `retry_exhausted`. `null` (array empty) otherwise. |

### `context`

| Field | Notes |
|---|---|
| `hostType` | e.g. `host.windows.hyper-v`. |
| `matchedFailurePattern` | The hard-block pattern `Wait-ForText` matched, or `null`. |
| `sequencePath` | Path of the failing sequence YAML. |
| `cycleFolder` | Cycle log dir (step failures only). |
| `failureScreenshotPath` / `failureOcrPath` | Cycle-dir-relative names (step failures only); may not exist (waitForText emits OCR text, non-OCR failures emit a screenshot) — presence is checked at deep-link time. |
| `crash` | Crash records only: `{ error, origin, stack }`. |

The write is atomic (temp-file + rename via `Write-YurunaStateFile`) so a
remediator or the status server never observes a truncated record.

## `step_failure` NDJSON event

Emitted alongside the file so a stream consumer (status server,
remediation loop, CI hook) sees the failure without reading the static
file. It carries the same values as the file, flattened (no nested
`context`), plus `event` = `step_failure`, `ok` = `false`, and
`durationMs` = `null` (mirrors the `step_end` shape so a consumer can
join the two on a single field). A crash event adds `crashError`.

## Related

- [Remediation dispatcher](remediation.md) — routes on `failureClass`.
- [Handler schema](handler-schema.md) — where the class / severity / recovery vocabulary is declared.
- [Per-step perf log](test-perf.md) — the `step_end` rows this shares a join shape with.

Back to [Test harness](test-harness.md) · [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
