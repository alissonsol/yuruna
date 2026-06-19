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
| `failureClass` | enum | Machine-routable class. The canonical set lives in [`Test.FailureTaxonomy`](../test/modules/Test.FailureTaxonomy.psm1) (one source of truth for the verb `ValidateSet` and the event-schema validator). Guest/sequence classes come from the failing verb's registration; `unknown` when the verb is unresolved; `pattern_matched_failure` when `Wait-ForText` short-circuited on a hard-block pattern; the host infra classes `provisioning_failure` / `bootstrap_sync` / `plan_invalid` / `network_timeout` come from the runner's infra stages (see [Infra-stage records](#infra-stage-records)). |
| `severity` | enum | `hard` / `soft` from the verb; `unknown` when unresolved. |
| `suggestedRecoveries` | string[] | Verb's `SuggestedRecoveries` (always a JSON array, never `null`). |
| `actionVerb` | string | The failing verb name (`script_error` for an unattributed crash; the stage name for an infra record). |
| `reason` | enum | `step` (a step failed), `crash` (engine crashed mid-step), `infra` (a host stage failed outside the sequence engine), or `watchdog_kill` (the outer watchdog SIGKILLed a wedged inner; see [Synthetic records](#synthetic--infra-records)). |
| `classificationSource` | enum | How `failureClass` was derived: `verb-registry`, `pattern-match` (a hard-block OCR pattern reclassified the step), `unresolved-verb` (`unknown` only because the verb carries no registration — register it, don't escalate), `crash`, `infra-stage` (a runner infra stage), or `synthetic` (a watchdog-synthesized record). Lets a consumer distinguish a genuinely-novel cause from missing metadata. |
| `sequenceName` | string | Failing sequence's base name (no `.yml`) — first-class identity for routing and repro (the path is still under `context.sequencePath`). |
| `repro` | object | Ready-to-run reproduction; see [repro](#repro). |

### `repro`

A reproduction an operator or autonomous remediator can run without reconstructing arguments.

| Field | Notes |
|---|---|
| `command` | `pwsh test/Test-Sequence.ps1 -SequenceName <name> [-GuestKey <k>] [-VMName <vm>] -logLevel Debug`. Re-runs the failing sequence (and its baseline chain) to reproduce deterministically. It deliberately **omits** `-StartStep`: `stepNumber` / `resumeFromStep` are **file-local** (1-based within this sequence file), but `Test-Sequence -StartStep` is **chain-global**, so a naive `-StartStep` would mis-target a leaf that still has an unbuilt baseline. |
| `runnerScript` / `entrypoint` | `test/Test-Sequence.ps1` / `Test-Sequence`. |
| `sequenceName` | Same as the top-level field. |
| `resumeFromStep` | The file-local failing step. Safe to pass as `-StartStep` only when the sequence has no unbuilt baseline (the warm / `requiresSnapshot` path, or a baseline-less sequence). |

### Replay-boundary + inner-cause fields

These appear on **both** step and crash records (a crash after step N began still has a safe replay boundary and, if it bubbled through an exhausted `retry`, an inner cause worth routing on):

| Field | Type | Notes |
|---|---|---|
| `lastSucceededStepNumber` | int | Replay boundary — step N succeeded; the failure landed on N+1. A "what's safe to replay past" marker, not an auto-resume pointer. |
| `innerActionVerb` / `innerFailureClass` / `innerSeverity` / `innerSuggestedRecoveries` | string / string / string / string[] | Set only when the failure bubbled through an exhausted `retry`; carry the deepest inner verb's classification so a remediator routes on the inner cause rather than the outer `retry_exhausted`. The [dispatcher](remediation.md) routes on `innerFailureClass` when the outer class is `retry_exhausted` and an inner handler exists. `null` (array empty) otherwise. |

### `context`

| Field | Notes |
|---|---|
| `hostType` | e.g. `host.windows.hyper-v`. |
| `matchedFailurePattern` | The hard-block pattern `Wait-ForText` matched, or `null`. |
| `sequencePath` | Path of the failing sequence YAML. |
| `cycleFolder` | Cycle log dir (step failures only). |
| `failureScreenshotPath` / `failureOcrPath` | Cycle-dir-relative names (step failures only); may not exist (waitForText emits OCR text, non-OCR failures emit a screenshot) — presence is checked at deep-link time. |
| `causeDetail` | Step records only: `{ ocrTail, patternsSought }` — the freshest on-screen OCR text (bounded tail, ≤1200 chars) and the patterns the wait was seeking at the failure site. Lets a consumer see the runtime cause behind a verb-static `failureClass`. Mirrored flat on the event as `causeOcrTail` / `causePatternsSought`. |
| `crash` | Crash records only: `{ error, origin, stack }`. |

The write is atomic (temp-file + rename via `Write-YurunaStateFile`) so a
remediator or the status server never observes a truncated record.

## `step_failure` NDJSON event

Emitted alongside the file so a stream consumer (status server,
remediation loop, CI hook) sees the failure without reading the static
file. It carries the same values as the file, flattened (no nested
`context`), plus `event` = `step_failure`, `ok` = `false`, and
`durationMs` = `null` (mirrors the `step_end` shape so a consumer can
join the two on a single field). The flattened event also carries
`reason`, `classificationSource`, `sequenceName`, `reproCommand` (the
`repro.command` string), and `matchedFailurePattern` (the nested-context
field lifted flat). A crash event adds `crashError`.

## `last_remediation.json` (the dispatcher's decision, persisted)

When the [remediation dispatcher](remediation.md) routes a failure it
writes `$YURUNA_LOG_DIR/last_remediation.json` beside `last_failure.json`.
Three signals describe a failure and it is easy to confuse them; this file
exists to keep the authoritative one durable:

- the verb's `suggestedRecoveries` is a **hint** (what the failing action
  thinks might help),
- the `remediation_recommended` NDJSON event is a **transient breadcrumb**
  on the stream, and
- `last_remediation.json` is the dispatcher's **decision** — the single
  recommendation a consumer should act on — written as a self-contained file
  so a consumer that polls the filesystem (dashboard, pool aggregator, a
  future autonomous loop) never has to tail the event stream or re-run the
  dispatcher to recover it.

Schema-versioned (`schemaVersion` = `1`), written through the atomic,
no-BOM state-file primitive. Fields: `timestamp`, `failureClass`,
`severity`, `recommendation` (one of the canonical recovery vocabulary),
`rationale`, `actions` (string[]), `handledBy`, `autoApply`, `source`, plus
`outerFailureClass` when the dispatcher routed past a `retry_exhausted`
wrapper, and the correlation fields (`vmName`, `guestKey`, `hostType`,
`stepNumber`, `actionVerb`, `sequenceName`) the failure carried.

`autoApply` is **always `false` today**: the dispatcher records what should
happen, it never performs the action. Acting on the recommendation is a
separate, default-off capability that stays gated behind a per-cycle attempt
cap, a class allow-list, and enough human review of these records first —
which is exactly why the decision is persisted now, ahead of any actor that
consumes it.

`Stop-LogFile` archives the file into the per-cycle folder on a non-pass
outcome (same path as `last_failure.json`), `Write-CycleManifest` catalogs
it as `kind` = `remediation`, and the pool replication copies the whole
cycle folder — so the recommendation travels with the failure to the pool
without a dedicated push.

## Synthetic & infra records

Two record variants reuse the schema-v2 shape for failures that happen
outside a normal step:

### Infra-stage records

Host stages that fail outside the sequence engine (GitPull, ProjectClone,
Resolve-CyclePlan, capability gate, folder-check, GetImage, New-VM,
Start-VM, New-VM.Resource) now write a schema-v2 `last_failure.json` +
`step_failure` event via `New-InfraFailureRecord`, where before they left
none and the remediation loop was blind to them. They carry `reason` =
`infra`, `classificationSource` = `infra-stage`, `stepNumber` = `0`, and
`actionVerb` = the stage name. The class maps the stage to a routable
recovery: `provisioning_failure` (New-VM/Start-VM — `retry_with_backoff`),
`network_timeout` (GetImage, and a git failure whose DNS/TCP probe failed
— `retry_with_backoff`), `bootstrap_sync` (ProjectClone, or a non-network
git divergence — `operator_intervention_required`), and `plan_invalid`
(Resolve-CyclePlan / capability gate / folder-check —
`operator_intervention_required`). The runner never clobbers a richer
engine-written record and the write is fully guarded so telemetry cannot
fail the cycle.

### Synthetic (watchdog-kill) record

When the outer watchdog SIGKILLs a wedged inner, the inner's failure path
cannot run, so the outer synthesizes a schema-v2 record: `reason` =
`watchdog_kill`, `classificationSource` = `synthetic`, `failureClass` =
`wait_timeout` (so the streak-capped auto-retry can end the pause early).
`stepNumber` (`0`) and `sequenceName` (`''`) are intentionally unresolved
— the SIGKILL destroyed the only structured step location — not omitted,
so the contract stays satisfied and a remediator stays null-safe.

## `degradation` event (non-failure observability)

The same `cycle.events.ndjson` stream also carries `degradation` events —
emitted by `Send-YurunaDegradation` (Test.Log.psm1) when the harness falls
back from a primary mechanism to a lesser alternative and **continues** the
cycle in a degraded mode. It is deliberately distinct from the `*_failed` /
`*_unavailable` events (a capability that broke): a degradation reports a
capability that was unavailable and was *worked around*, so a degraded-but-
passing cycle is queryable instead of reading as a clean pass. Fields:
`event` = `degradation`, `timestamp`, `dependency` (the subsystem, e.g.
`keystroke-mechanism`), `primary` (preferred mechanism), `fallback`
(alternative taken), `reason`, and `severity` (`soft` by nature). The emit is
best-effort (`Send-CycleEventSafely`) and never fails the cycle. A stream
consumer that counts only failures should skip this event type.

## status.json `lastFailure` summary

For the live dashboard, `Set-LastFailureSummary` records a denormalized
top-level `lastFailure` object on `status.json` at failure time:
`{ failureClass, severity, stepNumber, sequenceName, guestKey, stepName,
errorMessage, reproCommand, relPath, vmName, recordedAt }` — `null` on a
passing cycle. `relPath` points at the per-guest cycle-folder
`last_failure.json` (the dashboard resolves it against the per-guest
folder URL). `Complete-Run` snapshots it into the history row (alongside
per-guest `failureClass` / `errorMessage` in `guestSummary`) so a row is
self-describing. `status.json`'s own `schemaVersion` stays `1`; the field
is additive (old readers ignore it).

## Related

- [Remediation dispatcher](remediation.md) — routes on `failureClass`.
- [Handler schema](handler-schema.md) — where the class / severity / recovery vocabulary is declared.
- [Per-step perf log](test-perf.md) — the `step_end` rows this shares a join shape with.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.19

Back to [Yuruna](../README.md)
