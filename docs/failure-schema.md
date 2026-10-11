<a id="42820e91-0001"></a>

# Failure record schema

When a sequence step fails (or the engine crashes mid-step), the runner
writes `$YURUNA_LOG_DIR/last_failure.json` and emits one `step_failure`
NDJSON line into `cycle.events.ndjson`. Both come from one builder --
[`New-SequenceFailureRecord`](../test/modules/Test.SequenceFailureState.psm1)
in the slot-owning module -- so the record and the event stream cannot
drift on classification or fields. The
[remediation dispatcher](#remediation-dispatcher) routes on `failureClass`; the
class/severity/recovery vocabulary comes from each verb's registration
(see [handler contract](test-sequences.md#handler-contract)).

The slots that record lands in are a **shared, cross-module store**, not a
per-module `$script:` variable. The engine's verb handlers and the SSH/OCR
handlers in `Test.SequenceHandler` must read and write the same failure
slots, but a PowerShell `$script:` variable resolves to the module that
*defined* it -- a handler in `Test.SequenceHandler` writing
`$script:WaitForTextMatchedFailurePattern` would land in a scope the engine
(`Invoke-Sequence`) never reads, and the signal would silently vanish, with
an installer crash then mis-classified as a plain timeout. Anchoring the
slots in one `New-YurunaRegistry`-backed store instead (an eviction-safe
`$global:` ordered hashtable, surviving `-Force` re-imports) lets every
module share one object: each does `$script:Fail = Get-SequenceFailureState`
once and then reads and writes `$script:Fail.<slot>`. This is also the
prerequisite that lets verbs like `retry` and `recoverFromSnapshot` migrate
out of the engine without losing their failure-state coupling.

The record is written to the shared log root, and every sequence start clears
it there so one sequence's step location can never be reported as the next
one's. Each writer therefore also mirrors it under the running cycle's folder
(`Copy-CycleFailureRecord`) the instant the failure is classified: on a host
that runs several guests per cycle and does not stop at the first failure,
that clear falls between a failing guest's record and the end of the cycle,
so the root copy is routinely gone before the notifier, the warm-resume
checkpoint or the remediation dispatcher ever reads it.

Two copies are written, not one. `<cycleFolder>/last_failure.json` describes
the cycle. `<cycleFolder>/<vmName>/last_failure.json` describes one guest, and
is written whenever the record names a VM; the guest identity comes from the
record's own `vmName`, so a bootstrap, planner or host-stage failure that names
no guest writes the cycle copy alone. Two guests failing in one cycle keep
separate records, and a consumer that names its guest (`Get-FailureEventData
-VMName`) reads that guest's copy first and refuses a shared copy that names a
different guest -- so a guest whose own failure produced no record is reported
as `unknown` rather than inheriting its predecessor's cause. A record naming no
guest is host-level and is still offered to everyone. The manifest catalogs the
cycle copy as kind `failure` and each guest copy as `failure-guest`.

`Stop-LogFile` refreshes the mirrors from the root on a non-pass outcome -- the
root carries any enrichment written after the record first landed -- and removes
every copy on a pass, since a cycle recovered by a warm resume has no failure of
its own. A root copy older than a mirror is never copied over it: it belongs to
an earlier run.

<a id="42820e91-0002"></a>

## `last_failure.json` (schema v2)

Top-level fields, in order:

| Field | Type | Notes |
|---|---|---|
| `schemaVersion` | int | `2`. Readers branch on this. |
| `stepNumber` | int | 1-based position of the failing step (the outer step for a retry-exhausted failure). `0` on a crash before any step. |
| `totalSteps` | int | Steps in the sequence. |
| `action` | string | Human failure label. For retry-exhausted, already wrapped `retry exhausted (N attempts): ...`; for a crash with no label, `engine crash: <message>`. |
| `description` | string | The step's `description:`. |
| `vmName` / `guestKey` | string | Failing guest identity. |
| `timestamp` | string | UTC `yyyy-MM-dd HH:mm:ss`. |
| `failureClass` | enum | Machine-routable class. The canonical set lives in [`Test.FailureTaxonomy`](../test/modules/Test.FailureTaxonomy.psm1) (one source of truth for the verb `ValidateSet` and the event-schema validator). Guest/sequence classes come from the failing verb's registration; `unknown` when the verb is unresolved; `pattern_matched_failure` when `Wait-ForText` short-circuited on a hard-block pattern; the host infra classes `provisioning_failure` / `bootstrap_sync` / `plan_invalid` / `network_timeout` come from the runner's infra stages (see [Infra-stage records](#infra-stage-records)). |
| `severity` | enum | `hard` / `soft` from the verb; `unknown` when unresolved. |
| `suggestedRecoveries` | string[] | Verb's `SuggestedRecoveries` (always a JSON array, never `null`). |
| `actionVerb` | string | The failing verb name (`script_error` for an unattributed crash; the stage name for an infra record). |
| `reason` | enum | `step` (a step failed), `crash` (engine crashed mid-step), `infra` (a host stage failed outside the sequence engine), or `watchdog_kill` (the outer watchdog SIGKILLed a wedged inner; see [Synthetic records](#synthetic--infra-records)). |
| `classificationSource` | enum | How `failureClass` was derived: `verb-registry`, `pattern-match` (a hard-block OCR pattern reclassified the step), `unresolved-verb` (`unknown` only because the verb carries no registration -- register it, don't escalate), `crash`, `infra-stage` (a runner infra stage), or `synthetic` (a watchdog-synthesized record). Lets a consumer distinguish a genuinely-novel cause from missing metadata. |
| `sequenceName` | string | Failing sequence's base name (no `.yml`) -- first-class identity for routing and repro (the path is still under `context.sequencePath`). |
| `stepInvocationId` / `sequenceInvocationId` | string | Failed outer invocation identities, shared with that step's events. A failed retry retains its wrapper's IDs. Empty when a crash or infrastructure failure occurred before an invocation existed. |
| `originatingStepInvocationId` / `originatingSequenceInvocationId` | string | Failed leaf identities when a retry propagates an inner failure, joining its fetch evidence and progress advisory. Otherwise the failed invocation's own IDs, including when an outer handler throws a distinct error. |
| `repro` | object | Ready-to-run reproduction; see [repro](#repro). |

<a id="42820e91-0003"></a>

### `repro`

A reproduction an operator or autonomous remediator can run without reconstructing arguments.

| Field | Notes |
|---|---|
| `command` | `pwsh test/Debug-TestSequence.ps1 -SequenceName <name> [-GuestKey <k>] [-VMName <vm>] -logLevel Debug`. Re-runs the failing sequence (and its baseline chain) deterministically. It deliberately **omits** `-StartStep`: `stepNumber` / `resumeFromStep` are **file-local** (1-based within this sequence file), but `Debug-TestSequence -StartStep` is **chain-global**, so a naive `-StartStep` would mis-target a leaf that still has an unbuilt baseline. |
| `runnerScript` / `entrypoint` | `test/Debug-TestSequence.ps1` / `Debug-TestSequence`. |
| `sequenceName` | Same as the top-level field. |
| `resumeFromStep` | The file-local failing step. Safe to pass as `-StartStep` only when the sequence has no unbuilt baseline (the warm / `requiresSnapshot` path, or a baseline-less sequence). |

<a id="42820e91-0004"></a>

### Replay-boundary + inner-cause fields

These appear on **both** step and crash records (a crash after step N began still has a safe replay boundary and, if it bubbled through an exhausted `retry`, an inner cause worth routing on):

| Field | Type | Notes |
|---|---|---|
| `lastSucceededStepNumber` | int | Replay boundary -- step N succeeded; the failure landed on N+1. A "what's safe to replay past" marker, not an auto-resume pointer. |
| `innerActionVerb` / `innerFailureClass` / `innerSeverity` / `innerSuggestedRecoveries` | string / string / string / string[] | Set only when the failure bubbled through an exhausted `retry`; carry the deepest inner verb's classification so a remediator routes on the inner cause rather than the outer `retry_exhausted`. The [dispatcher](#remediation-dispatcher) routes on `innerFailureClass` when the outer class is `retry_exhausted` and an inner handler exists. `null` (array empty) otherwise. |

<a id="42820e91-0005"></a>

### `context`

| Field | Notes |
|---|---|
| `hostType` | e.g. `host.windows.hyper-v`. |
| `matchedFailurePattern` | The hard-block pattern `Wait-ForText` matched, or `null`. |
| `sequencePath` | Path of the failing sequence YAML. |
| `cycleFolder` | The cycle's stable identity (step failures only) -- the same value the NDJSON stream stamps, so this file joins to the event stream and resolves to the folder on disk. |
| `failureScreenshotPath` / `failureOcrPath` | Cycle-dir-relative names of this failure's screen evidence (step failures only). **Absent** unless the artifact exists and was last written after the failing step began: both are sticky per-VM files that only the screen-reading verbs rewrite, so a failure in a verb that reads no text would otherwise point at an earlier step's screen. A reader follows these; nothing audits them, so a present name is a claim the record has to be able to keep. |
| `staleEvidence` | Each artifact dropped from the two pointers above, named with how many seconds before the failing step it was last written; `[]` when none was. The file is still in the cycle folder under that name, so evidence belonging to an earlier step stays findable while the pointers stay trustworthy -- and an absent pointer is never read as "no screen evidence exists at all", which is a different fact with a different next step. |
| `causeDetail` | Step records only: `{ ocrTail, patternsSought }` -- the freshest on-screen OCR text (bounded tail, <=1200 chars) and the patterns the wait was seeking at the failure site. Lets a consumer see the runtime cause behind a verb-static `failureClass`. Mirrored flat on the event as `causeOcrTail` / `causePatternsSought`. `patternsSought` is recorded on every timed-out wait, including one whose console never showed readable text. Also carries `freshWindowNearMiss`, `closestOnScreen`, `consoleFlood`, `consoleStaticSeconds`, `blankScreenSeconds`, `guestLivelock`, `installerStage`, `installerStageUnchangedSeconds`, `pauseBeforeStepSeconds` and `pauseReleasedAtUtc` (below). |
| `crash` | Crash records only: `{ error, origin, stack }`. |
| `hostMemory` | Infra records only, and only when the host driver could measure the machine: `{ availableMb, committedBytes, commitLimitBytes, commitAvailableBytes, source }`. A VM's startup memory is charged against the system commit limit -- physical memory plus the current page-file size -- and not against free physical memory, so a provisioning refusal is explained by the commit figures while free physical memory can be at its highest in the same instant. **Absent** when nothing measured, never zeroed: a zeroed block reads as a machine that was measured and found empty, which is a different fact with a different next step. Mirrored flat on the event as `hostAvailableMb` / `hostCommittedBytes` / `hostCommitLimitBytes` / `hostCommitAvailableBytes`. |

<a id="42820e91-0006"></a>

#### `causeDetail` fields that describe the screen

| Field | Notes |
|---|---|
| `freshWindowNearMiss` | Set when a `freshMatch` wait timed out on text the OCR engines DID read but that had scrolled above the tail window; names the engine, the pattern and how many lines above. `[]` covers three unrelated screens -- no window was in force, the window covered the whole frame, or the text was genuinely nowhere on it -- so it is never on its own evidence that nothing resembled the pattern. Read it with `closestOnScreen`. |
| `closestOnScreen` | For each OCR engine and each pattern the wait sought, the line on the final frame that came closest and how close, as the percentage of normalized pattern characters that lined up (a match needs 85%, measured on the same canonical form the matcher uses, so OCR character confusion costs nothing). A high percentage means the text printed and the read of it fell short -- look at the capture or the matching tolerance; a low one means the screen was showing something else, so the guest never printed it. Three states, on the same discipline as `consoleFlood`: the lines, when the scan ran and found some; `[]` when it ran and nothing on the frame resembled the pattern; `null` when it never ran -- a wait that ends on a failure pattern returns the moment the pattern matches, and a failure outside a wait has no frame of its own. An empty list is a reading of the screen; `null` is the absence of one, and only the first supports a conclusion. |
| `consoleFlood` | Set when the console filled with one repeating line while the wait was seeking its pattern; carries the dominant line and its share of the screen. `''` when the screen was not repetitive. `null` when the wait confined its match to the console tail (`freshMatch`): that path reads the same frames but runs no flood check, so the field says "not looked at" rather than "not repetitive". |
| `consoleStaticSeconds` | The longest run, in seconds, that the console CONTENT did not change during the wait. Repetition is counted within a single frame, so a wall of text that scrolled by earlier and then stopped reads as a flood -- this is what tells the two apart. A high value means a guest that is waiting, not one that is working, and a guest that is waiting can often be unblocked by answering it. `0` when the screen kept moving, and `null` when the wait confined its match to the console tail (`freshMatch`) and never measured it -- `0` is a reading, `null` is the absence of one, and only the first supports a conclusion about the guest. For a `freshMatch` timeout the screen evidence is `freshWindowNearMiss` and `ocrTail` instead. |
| `blankScreenSeconds` | Seconds the console had read blank -- no OCR engine found any text -- when the wait ended; `0` when its last frame carried text. A blank console leaves `ocrTail` empty and `consoleStaticSeconds` unmeasured, since both read text, so this is the field that says the screen went black rather than that nothing was compared. Mirrored on the event as `causeBlankScreenSeconds`. |
| `guestLivelock` | The hypervisor's view of the guest when the wait ended, from the host sampler's recording: `{ verdict, livelockedSeconds, minimumSeconds, virtualProcessors, guestRunPercent, hypervisorRunPercent, interceptsPerSecond, dominantIntercept, interceptBreakdown, sampleCount, newestSampleUtc, reason }`. `verdict` is `livelocked` when every virtual processor sat at least 80% busy with the hypervisor holding at least 88% of that time for `minimumSeconds` (300), `not-livelocked` otherwise, and `unavailable` when the recording had no recent readings for the VM. `interceptBreakdown` averages the per-cause intercept rates over the run, highest first, and `dominantIntercept` names the top one. `null` when the host keeps no recording (every host but Windows, or sampling turned off): not measured, which is not the same reading as measured and found running. Mirrored on the event as `causeGuestLivelocked` / `causeGuestLivelockedSeconds`. |
| `installerStage` / `installerStageUnchangedSeconds` | The last `start:` or `finish:` marker for a substantive Subiquity Install or Mirror stage visible during this wait, and seconds since that marker changed. Network update chatter is excluded. This records the last observed marker, not proof that its command is still running. `''` / `0` when no stage was seen. Mirrored on the event as `causeInstallerStage` / `causeInstallerStageUnchangedSeconds`. |
| `progressAdvisory` | Independent observations: `outputStaticSeconds`, `heartbeatAgeSeconds`, SSH responsiveness and an advisory verdict. At least two sustained signals yield `progress-suspect`; absent measurements stay null/unavailable. Output is observed during tail-confined waits too, without enabling their disabled recovery signals. `automaticRecoveryAllowed` is always false. |
| `pauseBeforeStepSeconds` | Seconds an operator hold ran, when one was released before the failing step. The pause gate holds the runner and not the guest, so a prompt the guest printed once during the hold is off the screen the resumed step then has to read -- which looks identical to a prompt that never printed. `0` when there was no hold. |
| `pauseReleasedAtUtc` | When that hold ended, so it can be placed against the step's own start. `''` when there was no hold. |

The write is atomic (temp-file + rename via `Write-YurunaStateFile`) so a
remediator or the status service never observes a truncated record.

`guestLivelock.processorWindow` retains individual processor counters and
availability even when the all-processor livelock predicate does not hold.
The event carries it as `guestProcessorWindow`. Per-counter averages use their
own valid sample counts; missing or invalid readings do not become zeros.
Residuals require paired measurements of every supported named counter and
remain estimates because categories may overlap.

Heartbeat age describes recorder and guest sampling liveness; a fresh heartbeat
does not prove the application made progress.

Fetch step-end events include `executionEvidence` with capture outcome, reason,
artifact path and retained recorder status. Failure cleanup emits a
`failure_diagnostic` event carrying independent host/guest snapshot outcomes,
including capture exceptions. For an exhausted retry, its diagnostic manifest
and event use the originating leaf IDs so they join the fetch recorder; the
failure event retains the outer wrapper IDs and publishes both pairs. A
distinct outer crash uses its own IDs. Failed retry wrappers retain the leaf's
progress advisory rather than replacing its SSH and heartbeat observations
with unavailable measurements.

<a id="42820e91-0007"></a>

## `step_failure` NDJSON event

Emitted alongside the file so a stream consumer (status service,
remediation loop, CI hook) sees the failure without reading the file.
It carries the same values, flattened (no nested `context`), plus
`event` = `step_failure`, `ok` = `false`, and `durationMs` = `null`
(mirrors the `step_end` shape so a consumer can join the two on a single
field). It also carries `reason`, `classificationSource`, `sequenceName`,
`reproCommand` (the `repro.command` string), and `matchedFailurePattern`
(the nested-context field lifted flat). A crash event adds `crashError`. An
infra event whose stage measured the host adds `hostAvailableMb`,
`hostCommittedBytes`, `hostCommitLimitBytes` and `hostCommitAvailableBytes`
(the nested `context.hostMemory` block lifted flat); the four are present or
absent together.

`failureClass`, `severity` and `suggestedRecoveries` on this event are the
classification of the failure that happened. A failed `step_end` row carries
the failing verb's registration under `verbDefaultFailureClass`,
`verbDefaultSeverity` and `verbDefaultSuggestedRecoveries`: those say what
the verb WOULD call a failure of itself, and a matched failure pattern or an
unreachable guest moves the real class off the registration -- so a join
across the two rows never compares a measurement with a constant under one
key.

<a id="42820e91-0008"></a>

## `last_remediation.json` (the dispatcher's decision, persisted)

When the [remediation dispatcher](#remediation-dispatcher) routes a failure it
writes `$YURUNA_LOG_DIR/last_remediation.json` beside `last_failure.json`.
Three easily-confused signals describe a failure; this file keeps the
authoritative one durable:

- the verb's `suggestedRecoveries` is a **hint** (what the failing action
  thinks might help),
- the `remediation_recommended` NDJSON event is a **transient breadcrumb**
  on the stream, and
- `last_remediation.json` is the dispatcher's **decision** -- the single
  recommendation a consumer should act on -- written as a self-contained file
  so a filesystem-polling consumer (dashboard, pool-aggregator service, a
  future autonomous loop) never has to tail the event stream or re-run the
  dispatcher to recover it.

Schema-versioned (`schemaVersion` = `1`), written through the atomic,
no-BOM state-file primitive. Fields: `timestamp`, `runId` (the run that produced it), `failureClass`,
`severity`, `recommendation` (from the canonical recovery vocabulary),
`rationale`, `actions` (string[]), `handledBy`, `autoApply`, `source`, plus
`outerFailureClass` when the dispatcher routed past a `retry_exhausted`
wrapper, and the correlation fields (`vmName`, `guestKey`, `hostType`,
`stepNumber`, `actionVerb`, `sequenceName`) the failure carried.

`autoApply` is **always `false` today**: the dispatcher records what should
happen; it never performs the action. Acting on the recommendation is a
separate, default-off capability gated behind a per-cycle attempt cap, a
class allow-list, and enough human review of these records first -- which is
why the decision is persisted ahead of any actor that consumes it.

`Stop-LogFile` archives the file into the per-cycle folder on a non-pass
outcome (same path as `last_failure.json`), `Write-CycleManifest` catalogs
it as `kind` = `remediation`, and the pool replication copies the whole
cycle folder -- so the recommendation travels with the failure to the pool
without a dedicated push.

<a id="42820e91-0009"></a>

## Synthetic & infra records

Two record variants reuse the schema-v2 shape for failures outside a
normal step:

<a id="42820e91-000a"></a>

### Infra-stage records

Host stages that fail outside the sequence engine (GitPull, ProjectClone,
Resolve-CyclePlan, capability gate, folder-check, GetImage, New-VM,
Start-VM, New-VM.Resource) write a schema-v2 `last_failure.json` +
`step_failure` event via `New-InfraFailureRecord`, so the remediation
loop can route on them like any other failure. They carry `reason` =
`infra`, `classificationSource` = `infra-stage`, `stepNumber` = `0`, and
`actionVerb` = the stage name. The class maps the stage to a routable
recovery: `provisioning_failure` (New-VM/Start-VM -- `retry_with_backoff`),
`network_timeout` (GetImage, and a git failure whose DNS/TCP probe failed
-- `retry_with_backoff`), `bootstrap_sync` (ProjectClone, or a non-network
git divergence -- `operator_intervention_required`), `plan_invalid`
(Resolve-CyclePlan / capability gate / folder-check --
`operator_intervention_required`), and `pool_storage_full`
(PoolStorageSpaceCheck / PoolStorageMove -- `operator_intervention_required`;
written by the OUTER loop rather than the sequence engine, since a share that
cannot hold the results is discovered either before the cycle spawns or after it
finishes). The runner never clobbers a richer
engine-written record and the write is fully guarded so telemetry cannot
fail the cycle.

A stage whose host driver can measure the machine also carries
[`context.hostMemory`](#context) -- the physical memory available and the system
commit position at the instant of the failing call. Only the driver making that
call can take the reading: by the time the record is filed the guest has been
torn down and the numbers that explain the refusal are gone. Drivers that cannot
measure their host omit the block rather than filling it with zeros, so its
presence always means a real measurement.

<a id="42820e91-000b"></a>

### Synthetic (watchdog-kill) record

When the outer watchdog SIGKILLs a wedged inner, the inner's failure path
cannot run, so the outer synthesizes a schema-v2 record: `reason` =
`watchdog_kill`, `classificationSource` = `synthetic`, `failureClass` =
`wait_timeout` (so the streak-capped auto-retry can end the pause early).
`stepNumber` (`0`) and `sequenceName` (`''`) are intentionally unresolved
-- the SIGKILL destroyed the only structured step location -- not omitted,
so the contract stays satisfied and a remediator stays null-safe.

The same kill also reaches `status.json`. `Complete-Run` is what normally
appends a cycle to `history[]`, and a killed inner never gets there, so the
outer writes the row itself: `overallStatus` = `fail`, a `finishedAt` of its
own (the cycle never recorded one), and `cycleFolderUrl` still carrying its
`.incomplete/` suffix, because only the completion path renames that folder
and the partial results are under the suffixed name. The row is keyed on
`cycleStartUtc`, so the `fault` -> `paused` pair one kill produces writes one
row, and a cycle that did reach `Complete-Run` keeps its own richer row. The
record's `failureClass` is copied onto the live `lastFailure` when the inner
left none, which is what stops a killed cycle from reaching the pool
dashboard's class breakdown as `unknown`.

<a id="42820e91-000c"></a>

## `degradation` event (non-failure observability)

The same `cycle.events.ndjson` stream also carries `degradation` events --
emitted by `Send-YurunaDegradation` (`Test.Log.psm1`) when the harness falls
back from a primary mechanism to a lesser alternative and **continues** the
cycle degraded. It is deliberately distinct from the `*_failed` /
`*_unavailable` events (a capability that broke): a degradation reports a
capability that was unavailable and *worked around*, so a
degraded-but-passing cycle is queryable instead of reading as a clean pass.
Fields:
`event` = `degradation`, `timestamp`, `dependency` (the subsystem, e.g.
`keystroke-mechanism`), `primary` (preferred mechanism), `fallback`
(alternative taken), `reason`, and `severity` (`soft` by nature). The emit is
best-effort (`Send-CycleEventSafely`) and never fails the cycle. A stream
consumer that counts only failures should skip this event type.

<a id="42820e91-001e"></a>

## `cycle.events.delivery.json` (is the event stream complete?)

Emission is best-effort by design -- a cycle never fails because an event could
not be written -- and on its own that makes a lost event invisible. A consumer
reading a quiet stream cannot tell "nothing happened" from "the writer broke",
and a writer that was never loaded leaves no trace at all. Every emission is
therefore counted, and every loss is recorded with its reason beside the stream:

| Field | Meaning |
|---|---|
| `attempted` / `delivered` / `dropped` | Emissions since the cycle opened, and how they ended. |
| `lastDroppedEvent` | The `event` name of the most recent loss. |
| `lastDropReason` | `writer-unavailable` (the writer was not loaded in that scope), `writer-threw: <message>`, or `write-failed: <message>` (the append failed: open-handle race, disk full). |
| `lastDropAtUtc` | When it happened. |

The file is written when an event is lost, not for every event, and a clean cycle
has none; the manifest catalogs it as kind `ndjson-delivery`. The first loss in a
cycle is also a warning, and later ones are counted rather than repeated.
`cycle.events.gaps` still carries one line per failed append (with the dropped
event's name and action), which is the per-event detail the ledger summarizes.

An event emitted while no cycle is open is counted as dropped with the reason
`no-cycle-folder` but is not warned about and writes no file: with no cycle there
is no stream to be incomplete, and tools and tests emit in that state routinely.
None of this changes what a failed write does to the cycle -- the failure being
reported keeps its own class and reason; the ledger only says how much of the
evidence around it reached disk.

<a id="42820e91-000d"></a>

## `guest_quarantined` event (circuit breaker)

The guest-quarantine circuit breaker (`Test.GuestQuarantine.psm1`) tracks a
per-guest consecutive-failure count keyed by `failureClass` in
`runner.quarantine.json` (sibling of `runner.gating.json` in the runtime dir,
surviving the single-cycle inner respawn). After `failuresToQuarantine`
failures of the **same** class (default 3), the guest is skipped for up to
`skipCycles` cycles (default 5) or until a framework/project commit changes --
whichever comes first -- so a deterministically-broken guest stops costing a
full provision+deploy every cycle, while a guest that fails a *different* way
each time is never trapped. Enabled by default; set
`testCycle.guestQuarantine.enabled: false` to disable. Tripping the threshold
emits one `guest_quarantined` event: `event` = `guest_quarantined`,
`timestamp`, `guestKey`, `failureClass`, `consecutiveFailures`, `skipCycles`,
`quarantinedUntilCommit` (and `vmName` / `hostType` /
`quarantinedUntilProjectCommit` when known). The skipped guest is also
flagged on `status.json` (`guests[].quarantined` +
`quarantinedUntilCommit`) so the dashboard shows a **quarantined** pill -- the
skip is loud, never a silent pass. The emit is best-effort
(`Send-CycleEventSafely`) and never fails the cycle.

<a id="42820e91-000e"></a>

## The lab-health gate (`lab_health_*` events)

A cycle step needs the lab's services -- the stash it uploads binaries to, the
caching-proxy-service its guests fetch through -- and a service being rebuilt is away for
minutes to tens of minutes. Long enough that the preflight retry windows sized
for a DHCP renew cannot cover it, and short enough that failing the cycle throws
away a pass for a condition that cures itself.

So the gate (`Test.LabHealth.psm1`) **holds** instead. Ahead of each chain entry
and each sequence step it checks the services this lab declares, and when one
that *was* answering has stopped, the cycle parks exactly as the operator's
*Pause after the next step* parks it -- re-probing on the same 59 s-capped
backoff the pause loop polls with, and resuming on its own when the service
returns.

**The probe set is derived, never configured.** Every extension area already
declares `healthPort`/`healthPath` in its `service:` block
([extensions-api.md](extensions-api.md)), so an area that ships tomorrow is gated
the day it lands. An area exporting the contract verb `Test-<Area>Host` is probed
through it instead: the caching-proxy-service's `healthPort` is Squid's 3128 while its
daemon answers `/healthz` on 9310, and a manifest-driven probe there would report
a dead daemon on every healthy proxy in the lab.

**A hold needs a change of condition, not an absent service.** An area arms only
when this host reached it inside `testCycle.labHealth.armWindowHours` (default
24), and that record -- `runtime/lab-health.json` -- is read **across cycles**. A
service stopped for a rebuild is already gone when the next cycle starts, so a
baseline captured at cycle start would never see the transition the gate exists
to catch. A service this host has *never* reached is deliberately never a hold:
holding would park a fresh host on its first cycle, where a preflight gives a
faster and more accurate "there is no stash here".

**Cost.** An armed area is probed at its last known address first, with no
discovery at all -- one HTTP call per armed area, no pool round-trip -- and its
verdict is reused for `minIntervalSeconds` (default 30). An area the gate is not
watching is re-asked only every `discoveryIntervalSeconds` (default 600), because
its lookup is the expensive one and its answer is the one that almost never
changes.

**Ending a hold.** Recovery clears it. `POST /control/lab-hold-release`
([control-routes.md](control-routes.md)) is the operator judging the outage
permanent: the gate drops the hold and lets the step run so it fails on its own
terms. `/control/start-cycle` clears it too. And at `maxHoldAttempts` -- clamped
to a compiled **999**, about sixteen hours at the backoff cap -- the gate records
`lab_dependency_down` and the cycle ends the way any hard infra failure ends.

Three events ride the NDJSON stream: `lab_health_change` (with `fromVerdict` /
`toVerdict` / `areas` / `armed`, and `attempts` + `heldSeconds` on the way back
up), `lab_health_released`, and `lab_health_exhausted`. `status.json` carries
`labHold` and `labHoldAreas`, mirrored from the flag file on every flush, which
is what the status page's banner renders.

The hold's flag (`control.lab-hold`) is deliberately **not** the operator's
`control.step-pause`. The auto-release deletes the flag it raised; if that were
the operator's flag, a service coming back would un-pause a cycle its operator
had parked and walked away from.

<a id="42820e91-000f"></a>

## `warm_resume` event (checkpoint resume)

Warm-resume checkpointing (`Test.WarmResume.psm1`) turns a late-step transient
into an in-place retry instead of redoing the whole install. When a workload
sequence fails with a **transient** class (`network_timeout`, `wait_timeout`,
`instrumentation_failure`, `host_io_blocked`, `ip_not_discovered`,
`payload_unavailable`, `input_lost` -- `Get-WarmResumeEligibleClass`), the runner re-runs the
*failed* sequence from `repro.resumeFromStep`
on the **same still-alive VM** (the teardown fires only on the final result),
up to `testCycle.warmResume.maxAttempts` (default 2), then continues any
remaining workload sequences. On exhaustion or an ineligible class it falls
through to the normal teardown + cold re-provision, so warm resume is
safe-on-failure. Enabled by default; set `testCycle.warmResume.enabled: false`
to disable. Each attempt emits a `warm_resume` event: `event` = `warm_resume`,
`timestamp`, `guestKey`, `sequenceName`, `resumeFromStep`, `attempt`, plus
`failureClass` / `vmName` / `hostType` when known -- so a run that only passed
because it resumed stays queryable, never a silent pass.

<a id="42820e91-0010"></a>

### Rewind to a restore boundary

`repro.resumeFromStep` names the step that **failed**, and a transient class says
why that step stopped, not how much of its work landed first -- an install that
unpacked before its network call died leaves the guest changed. Restarting there
would replay the step onto its own residue, which is not the run the sequence
describes. `loadDiskSnapshot` is the one action that makes guest state known
again, so the resume point is pulled back to the nearest one **at or before** the
checkpoint, and every replayed step then runs against the state it was written
for. The cost is redoing the steps in between -- the same trade warm resume
already makes against a full cold rebuild.

A sequence with no `loadDiskSnapshot` at or before the checkpoint has nothing to
restore to. The checkpoint step is then replayed in place only when it merely
observes -- waits, reads the screen, captures evidence -- and that is judged over
the whole step: a `retry` block that leads with a wait and then types is a typing
step. A step that types, clicks, or changes guest, host or external state would
run onto its own residue, so the resume is declined and the original failure
stands. Each verb declares its class when it registers (`ReplaySafety`:
`observe`, `input`, `state-changing`, `restore-point` or `composite`); a verb that
declared none, an unregistered name, an unreadable sequence and a missing safety
check all count as unsafe. A restore point whose snapshot the host definitely
lacks counts as no boundary, so it cannot license a replay. A checkpoint already
sitting on the boundary is not a rewind.

A resume that was eligible and declined says so with a `warm_resume_declined`
event: `timestamp`, `event`, `guestKey`, `sequenceName`, `resumeFromStep` and a
`reason` token -- `no-restore-point`, `restore-point-missing` or
`safety-check-unavailable` -- plus `replayClass` (what made the step unsafe),
`failureClass`, `vmName` and `hostType` when known. Without it a declined
recovery is invisible: the cycle fails with its original class.

When a rewind happens the event carries `checkpointStep` (the step that failed)
and `rewoundSteps` (how many were replayed) alongside `resumeFromStep` (where the
run actually restarted); all three are absent when nothing was rewound, so a
replay is never inferred from step numbers that merely disagree. The console line
says the same thing in words, naming the count of replayed steps -- a resumed pass
that redid work is loud in both places.

Step numbers are positions in the sequence's flat step list -- `component:` then
`workload:`, after snippet expansion -- which is the same list `-StartStep` counts
against.

Soundness rests on the runner running each workload sequence as a **single
file** (`Invoke-SequenceByName` -> `Invoke-Sequence`), so `resumeFromStep`
(file-local) maps directly onto `Invoke-Sequence -StartStep` (file-local). This is
the "warm / no unbuilt baseline" case the [`repro`](#repro) note calls out --
Debug-TestSequence's chain runner concatenates baselines and is *not* this
case, which is why `repro.command` still omits `-StartStep`.

<a id="42820e91-0011"></a>

## `retry_attempt` / `retry_exhausted` events (retry telemetry)

The three retry stacks emit a structured attempt record so a flaky retry is
queryable in `cycle.events.ndjson`, not just buried in the human log:

- **`Yuruna.Retry`** (host-side pwsh: tofu init/plan/apply, helm/kubectl fetches)
  emits `retry_attempt` before each backoff and `retry_exhausted` on the final
  failure -- best-effort (`Send-CycleEventSafely` is Get-Command-guarded, so a
  standalone tofu run that never loaded `Test.Log` is unaffected).
- **The sequence `retry` verb** emits `retry_attempt` per failed inner pass and
  `retry_exhausted` on exhaustion, the latter carrying the deepest inner
  `failureClass` (the outer class collapses to `retry_exhausted`). The ARM64
  installer boot guard also emits `retry_suppressed` when it declines a
  planned native ARM64 restart, with `reason`, `attempt`, `maxAttempts`,
  `permittedMaxAttempts`, and `configuredMaxAttempts`. Its terminal record carries
  `retrySuppressionReason` so the cause remains visible without joining events.
  Each sequence `retry_attempt` also carries `guestLivelocked` and
  `guestLivelockedSeconds`, the host livelock verdict when the attempt failed,
  so restarts that verdict justified can be counted.
- **The guest bash lib** (`automation/yuruna-retry.sh`) can't reach the host
  stream, so it prints a `YURUNA_RETRY {stack,label,attempt,maxAttempts,rc,
  permanent}` marker to stderr; on the SSH verbs (`sshExec` /
  `sshFetchAndExecute`) the host parses those markers into `retry_attempt`
  events via `Publish-GuestRetryMarker`. The console/OCR fetch path keeps its
  log guest-local, so that path is not covered.

Fields (all additive; the schema is open): `event`, `timestamp`, `stack`
(`pwsh` / `sequence` / `bash`), `attempt`, `maxAttempts`, `exitCode`,
`description` (the label), and optionally `transient` / `permanent` /
`sleepSeconds` / `failureClass` / `severity` / `guestKey` / `vmName` /
`evidencePath`.

`evidencePath` (sequence stack) is the cycle-relative folder holding the screen
frames and OCR text the failed attempt produced, copied aside before the next
attempt recycles them. It is present only when the failed inner verb is
`hard`-severity and there was something to capture. It is the only durable
record of an attempt that a later retry recovers: such a cycle ends `pass`, and
every other artifact-gathering path runs on cycle failure.

The cross-language fetch-and-execute failure sentinel `NONZERO SCRIPT EXIT:`
(the string the guest wrapper prints and the `fetchAndExecute` verb matches) is
a declared constant on each side (`Get-NonzeroScriptExitSentinel` + the bash
producer) with a drift-guard test, so the two sides can't silently diverge.

<a id="42820e91-0012"></a>

## `sequence_paused` / `sequence_resumed` events (operator holds)

Both pause gates report both ends of a hold, so a cycle that spent most of its
wall-clock parked reads as parked rather than as slow, and a failure that
follows a hold can be read against it.

| Field | Notes |
|---|---|
| `pauseScope` | `step` (the sequence gate, from `control.step-pause`) or `cycle` (the cycle-boundary gate, from `control.cycle-pause`). |
| `label` | Where the gate fired: `[sequence start]`, `[3/9]`, or `[cycle boundary]`. |
| `requestedAtUtc` | When the operator armed the hold, read from the flag file the status service stamps. `''` when unreadable. |
| `heldSeconds` | Release event only. An open hold has no duration yet, and an unpaired `sequence_paused` is the only record that a runner died while parked rather than while stuck. |
| `guestKey` / `vmName` / `sequenceName` | Step scope only: what was parked. |

The two scopes differ in what a hold costs, and the distinction is the reason
the scope is on the event at all:

- **`cycle`** holds after teardown, with no guest running. Nothing can expire
  underneath it; the pair is duration reporting.
- **`step`** holds the runner while the guest keeps running. A guest prints on
  its own schedule, so anything it prints once and does not reprint -- a
  boot-time confirmation prompt above all -- can scroll away unanswered during
  the hold. The step that resumes then reads a screen the prompt has left, which
  is indistinguishable from a prompt that never printed. That is why a released
  hold is also carried into the failure record as
  `causeDetail.pauseBeforeStepSeconds`.

<a id="42820e91-0013"></a>

## status.json `lastFailure` summary

For the live dashboard, `Set-LastFailureSummary` records a denormalized
top-level `lastFailure` object on `status.json` at failure time:
`{ failureClass, severity, stepNumber, sequenceName, guestKey, stepName,
errorMessage, reproCommand, relPath, vmName, recordedAt }` -- `null` on a
passing cycle. `relPath` points at the per-guest cycle-folder
`last_failure.json` (the dashboard resolves it against the per-guest
folder URL). `Complete-Run` snapshots it into the history row (alongside
per-guest `failureClass` / `errorMessage` in `guestSummary`) so a row is
self-describing. `status.json`'s own `schemaVersion` stays `1`; the field
is additive (old readers ignore it).

<a id="42820e91-0014"></a>

## Remediation dispatcher

The `failureClass` token on the record above is drawn from the enum in
[`Test.SequenceAction`](../test/modules/Test.SequenceAction.psm1). The
remediation dispatcher in
[`test/modules/Test.Remediation.psm1`](../test/modules/Test.Remediation.psm1)
maps that token to an actionable recommendation. Without it, an operator
(or a future autonomous loop) would have to grep the free-text error
message and guess; the dispatcher instead reads the failure record,
routes on `failureClass`, and returns what the caller should do.

The dispatcher is **advisory**: it records a decision and emits a
recommendation, and applying that recommendation is someone else's job. Nothing
in the tree calls `Repair-Credential`, for instance. The only code that acts on a
failure is the set of bounded repairs described under
[Recovery result and ledger](#recovery-result-and-ledger): they are off by
default, limited to a short allow-list, and capped per failure fingerprint in a
ledger that survives a runner restart, so that a misclassified failure cannot
drive a repair in a loop.

<a id="42820e91-0015"></a>

### Why each infra failure class exists

A token earns its own class only where the retry policy, or the person who can
fix it, differs from every class already in the enum. The infra classes are
where that line is easiest to get wrong -- they all look like "the environment
broke" from a distance -- so each one's reason is recorded here.

- **`elevation_required`** -- the host asked for a sudo password with no operator
  present. Its own class because it is the one failure that is provably
  unfixable from anywhere but the console: retrying it, on this cycle or any
  later one, can only reproduce it, so remediation routes it straight to
  `operator_intervention_required` rather than burning the backoff.
- **`project_access_denied`** -- a pool assigned this host a `projectUrl` its
  credential cannot read. Distinct from `bootstrap_sync` (this host's own
  project failing to clone) because the fix belongs to a different person -- the
  pool admin who made the assignment, not the host owner -- and distinct from
  `network_timeout` because no retry can ever succeed.
- **`host_network_degraded`** -- the HOST's own guest-network path is broken, so
  every network-touching guest on it fails identically for a reason no
  guest-level retry can influence. It needs its own class because a
  virtual-switch object outlives its uplink binding across a host reboot: the
  switch is still there but forwards no traffic, and each guest reports
  only its own symptom (`network_timeout` / `provisioning_failure`). It is
  deliberately absent from the transient fast-retry allow-lists -- retrying
  against a bridge with no carrier can only spend the cycle budget -- so it
  routes to the operator the way `elevation_required` does.
- **`ip_not_discovered`** -- no host-side probe could name an address for the
  guest, so the step never reached it. Distinct from `network_timeout`, which
  means a real address was found and the path to it failed, and from
  `host_network_degraded`, which is unrecoverable. This is the recoverable
  lateness class: hypervisor address discovery rests on caches that age out and
  daemons that publish late, so the same call usually answers seconds later. It
  therefore belongs in the transient fast-retry allow-lists, and must never be
  reported as `script_error` -- the guest script never ran, and sending a reader
  to debug it wastes the cycle.
- **`payload_unavailable`** -- the guest was reached and ran the fetch wrapper,
  but no source served the script, so the payload never executed. Distinct from
  `ip_not_discovered`, where the HOST could not name the guest: here the guest
  is up and talking, and it is the host that it cannot reach. Distinct from
  `script_error` for the reason that matters most -- nothing ran, so there is no
  script to debug and no guest state to distrust, which is what makes replaying
  the step sound. The usual cause is a host that renumbered under DHCP while the
  guest still held its old address; the guest re-asks the pool directory and
  normally recovers, so this belongs in the warm-resume allow-list, though not in auto-remediation's. It
  stays ONE class rather than splitting on which leg failed: whether the payload
  arrives next time depends on the host becoming reachable again, not on the
  GitHub fallback, so a terminal 404 from that fallback does not make the
  failure permanent. Where the fallback IS the dead end -- a private repository
  with no token -- the recovery text names it.
- **`input_lost`** -- a GUI fetch typed its command into the guest shell, the
  wait ran to its timeout with the staged subshell still open on screen, and the
  guest confirmed that the guard never ran: no prepared context exists for the
  command and no fetch process is running. Distinct from `wait_timeout`, where a
  script was running and stalled, and from `script_error`, where a script exited
  non-zero: nothing ran here, so there is no script to debug. A screen that
  shows an open subshell is not enough on its own, because a payload that ran
  and went quiet can look the same, so the guest decides. Because nothing
  executed, replaying the step repeats no work, which is why it belongs in the
  warm-resume and auto-remediation allow-lists, and its recovery leads with
  `retry_with_backoff`.
- **`pool_storage_full`** -- the pool share has no room for this cycle's results.
  Like `elevation_required`, retrying is provably useless: the runner has
  nothing of its own to delete, and nothing about the next cycle makes the share
  emptier, so it routes straight to `operator_intervention_required` instead of
  burning the backoff. Deliberately absent from auto-remediation's transient
  list for the same reason -- an early retry would only re-fill the same wall.
- **`dhcp_identity_unbounded`** -- a guest was rebuilt under the identity it is
  supposed to keep for life and the DHCP server handed it a *different* address.
  Its own class because the remedy belongs to nobody else: the guest is healthy,
  the host is healthy, and what is broken is the property that makes a long lease
  survivable -- that the number of addresses a client ever requests is bounded by
  identity count rather than by elapsed time. Every address left behind stays
  allocated for the whole lease, so the pool drains at a rate the lease time sets
  rather than the machine count, and the eventual symptom is guests booting with
  no IPv4 at all -- arriving as `pattern_matched_failure` on whatever step first
  needed the network, on hosts with nothing else in common. Absent from the
  transient retry allow-lists on purpose: the next build asks the same question
  and is handed another new address, so retrying spends more of the pool. A first
  sighting of an identity is never this class, and a guest whose address could
  not be resolved is recorded as unchecked rather than as passing.
- **`lab_dependency_down`** -- a lab service this host had been reaching stopped
  answering, and the cycle already **held** for it: the lab-health gate re-probed
  on backoff for up to sixteen hours before recording this. That history is the
  reason it is a class of its own. Automated retry has provably been tried at the
  only scale that could have worked, so the class stays out of the transient
  fast-retry allow-lists and out of auto-remediation's transient list, and routes
  to `operator_intervention_required` -- the next cycle would spend the same
  hours reaching the same answer. Distinct from `payload_unavailable`, where a
  live guest cannot fetch from its host: here nothing is running yet and no
  address for the service exists at all. Distinct from `network_timeout`, which
  means an address WAS found and the path to it failed. And distinct from every
  host-scoped class because the service need not live on this host -- under a
  pool it is normally a VM somebody else owns, which is also why the recovery
  text names the service and its last known address rather than sending the
  reader to this host's own network.
- **`console_flooded`** -- a wait spent its whole budget against a console that
  was overwriting itself with one repeating line, so the pattern could not be
  read off the screen whether or not it was ever printed. Its own class because
  it is the one wait failure a replay cannot help, which is exactly what
  `ocr_timeout` recommends: that class assumes the screen diverged from the
  recorded path and a clean run will follow it again, whereas here the screen was
  never readable and a replay refills it at the same rate. It is also invisible
  to both capture self-heals -- the no-text counter sees a screen full of text and
  the frozen-frame check sees a feed changing on every frame, so the transport is
  healthy and only the content is useless. The dominant line and its share of the
  surface ride along in `causeDetail.consoleFlood`, because the thing that is
  repeating is what names the cause. Absent from the transient retry allow-lists:
  a longer timeout cannot make a self-overwriting surface readable.

<a id="42820e91-0016"></a>

### Public surface

| Function | Signature | Used by |
|---|---|---|
| `Register-RecoveryHandler` | `-FailureClass -Handler` | External modules add or override a handler |
| `Register-BuiltinRecoveryHandler` | (no args) | Installs the default handler set at module load |
| `Get-RecoveryHandler` | `-FailureClass` | Dispatcher; introspection |
| `Get-RegisteredFailureClass` | (no args) | Suites that check handler coverage; introspection |
| `Get-RecoveryRecommendationName` | (no args) | Canonical recommendation vocabulary (shared with each verb's SuggestedRecoveries) |
| `Invoke-Remediation` | `-FailureRecord [-LastFailurePath]` | Operator / autonomous loop; returns the recommendation hashtable |
| `Clear-RecoveryHandler` | (no args) | Tests only |

<a id="42820e91-0017"></a>

### Recommendation taxonomy

Each handler returns a hashtable whose `Recommendation` field MUST be
one of the canonical values below, so a streaming consumer can pivot on
a small finite set instead of free-text matching:

| Recommendation | Meaning |
|---|---|
| `retry_immediately` | Transient; re-run the failing step now. |
| `retry_with_backoff` | Likely transient (network blip, rate limit); the caller picks the backoff. |
| `restart_from_snapshot` | Guest state went sideways; restore to the last good snapshot and replay from there. |
| `reconnect` | Transport-level (VNC dropped, SSH session died); rebuild the connection and continue. |
| `pause_and_inspect` | Repeating the step risks burning resources; surface and wait. |
| `operator_intervention_required` | The runner cannot self-recover (vault password wrong, image unsigned). |
| `escalate` | Reserved -- an external handler may return it to flag a novel case for the framework to learn. No built-in handler emits it; the no-handler / handler-error fallback is `operator_intervention_required`. |

<a id="42820e91-0018"></a>

### Inner-cause routing past `retry_exhausted`

An exhausted `retry` reports the outer class `retry_exhausted`, which
masks the deepest verb's actionable cause. The failure record preserves
that cause in `innerFailureClass`; when the outer class is
`retry_exhausted` and the inner class has its own registered handler, the
dispatcher routes on the **inner** class so the recommendation targets
the real failure, not the retry wrapper. `severity` and
`suggestedRecoveries` follow the routed class; the outer class stays
visible as `RoutedFromFailureClass` on the result and `outerFailureClass`
on the `remediation_recommended` event. With no inner class (or no inner
handler) the dispatcher routes on the outer class unchanged.

<a id="42820e91-0019"></a>

### Advisory by design

Handlers return **what the caller should do**, not what they **did**, and a
handler never acts. Acting is the recovery module's job: a repair registers a
precondition, a bounded action, a postcondition probe and a rollback, and the
[ledger](#recovery-result-and-ledger) decides whether it may run again. Wiring
`Repair-VncConnection`, `Wait-SshReady` or `Restore-VMDiskSnapshot` in the same way
is how a handler's advice would become an action, one repair at a time.

<a id="42820e91-001a"></a>

### Registry shape

The registry uses the shared
[`New-YurunaRegistry`](../test/modules/Test.Registry.psm1)
primitive, so it appears in `Get-YurunaRegistryDirectory` alongside
`SequenceAction`, `HostIO`, `OcrProvider`, and
[`HostCondition`](test-harness.md#host-condition-registry) -- autonomous
tooling enumerates every routing surface through one API.

<a id="42820e91-001b"></a>

### Event emission

Every dispatch emits a `remediation_recommended` NDJSON event
carrying `(failureClass, recommendation, severity, handledBy)` so a
streaming consumer follows what the dispatcher chose without parsing
the recommendation object. Schema lives in
[`Test.EventSchema`](../test/modules/Test.EventSchema.psm1) -- the same
validator that gates the cycle event stream.

<a id="42820e91-001c"></a>

### Adding a new failure class

1. Add the new value to the canonical `FailureClass` list in
   [`Test.FailureTaxonomy`](../test/modules/Test.FailureTaxonomy.psm1)
   AND to the literal `ValidateSet` in
   [`Test.SequenceAction`](../test/modules/Test.SequenceAction.psm1)
   (a `ValidateSet` attribute argument must be a constant expression, so
   it can't read the shared array; an `Assert-FailureTaxonomyInSync` call
   at module load warns if the two ever drift). The event-schema
   validator derives its enum from the taxonomy module automatically.
   Built-in infra classes already added this way: `provisioning_failure`,
   `bootstrap_sync`, `plan_invalid`.
2. Register a handler in
   [`Test.Remediation`](../test/modules/Test.Remediation.psm1)'s
   built-in block, or from an external module via
   `Register-RecoveryHandler`.
3. The handler is a `param([hashtable]$c)` scriptblock that reads
   `$c.Failure` (the parsed last_failure.json) and `$c.Context`
   (`vmName`, `guestKey`, `hostType`, `stepNumber`, `actionVerb`,
   `severity`, `suggestedRecoveries`, `failureClass`, plus the
   actionability fields `sequenceName`, `sequencePath`,
   `matchedFailurePattern`, `innerFailureClass`, `outerFailureClass`,
   and `reproCommand` -- each an empty string when absent, so a handler
   string-tests without a null guard -- and the `causeDetail` readings
   `consoleStaticSeconds`, `consoleStaticMeasured` and
   `pauseBeforeStepSeconds`, which read `0`, `true` and `0` when absent),
   returning `@{ Recommendation =
   '<enum>'; Rationale = '<short>' }` (optional `Actions`, `HandledBy`,
   `AutoApply`). The dispatcher attaches severity from the failure
   record, not the handler.
4. `Test.Remediation.Tests.ps1` fails if any enum value is missing a
   handler; at run time the dispatcher routes a class with no handler
   to the `unknown` handler.

<a id="42820e91-001f"></a>

## Recovery result and ledger

The runner, the project run and the sequence runner used to say how a cycle went
in three shapes: a Boolean from the sequence engine, a clone result plus an exit
code, a cycle object plus a sidecar file. They now also record one typed result,
and a durable ledger bounds what the runner may repair on its own. Nothing that
existed changed: every exit code, `status.json`, `last_failure.json`,
`last_remediation.json` and the required fields of `runner.cycle.outcome.json`
are as they were. The new data is added beside them.

The code is in [`Test.RecoveryContract`](../test/modules/Test.RecoveryContract.psm1)
(the result, the shared steps), [`Test.RecoveryLedger`](../test/modules/Test.RecoveryLedger.psm1)
(the ledger and the repair protocol) and
[`Test.RecoveryActions`](../test/modules/Test.RecoveryActions.psm1) (the repairs).

<a id="42820e91-0020"></a>

### `recovery.result.json` (the typed result)

Written under `$YURUNA_RUNTIME_DIR` by every entry point when a run ends, and
replaced each time; `recovery.results.ndjson` beside it keeps one compact line per
result, trimmed to the newest 200. A failed write is a warning and never changes
how the run ends.

| Field | Meaning |
|---|---|
| `schemaVersion` | `1`. |
| `resultId` | A new GUID (N format) per result. |
| `entryPoint` | `runner`, `project` or `sequence`. |
| `cycleGeneration` | `<runnerInstanceId>:<cycle>` for the runner. A one-shot entry point mints `<new guid>:1`, exports it as `YURUNA_CYCLE_GENERATION`, and everything it starts shares it. |
| `outcome` | `passed`; `failed` (the tests ran and failed); `infrastructure-fault` (the machinery around the tests failed); `cannot-run` (a precondition such as VM admission refused the cycle); `aborted` (a child died before it could run a cycle). |
| `exitCode` | The exit code the entry point (or, for the runner, the cycle) ended with. |
| `failureClass` | Empty, a [failure class](#why-each-infra-failure-class-exists) of the shared taxonomy, or a runner fault class (below). |
| `fingerprint` | `fp1-` plus 16 hex characters: the SHA-256 of failure class, stage, sequence name and action verb, each trimmed and lowercased. Counts, timestamps, VM names and addresses are never inputs, so the same failure has the same fingerprint on the next cycle and after a restart. Empty for a pass or a failure without a class. |
| `stage` | The stage of an infrastructure failure (`ProjectClone`, `FrameworkPull`, `VmAdmission`, `CycleOutcome`, `CycleStart`, `CycleSpawn`, `PoolStorage`) or empty. |
| `reason` | Short text, redacted (credentials in URLs, `password=` style pairs, long opaque tokens) and cut at 300 characters. |
| `evidence` | Pointers: `{ kind: file\|record\|event\|command, ref, note }`, for example the `last_failure.json` path or the rejected outcome record. |
| `steps` | The shared steps the run took (`checkout`, `admission`, `replay`, `cycle`), each `{ step, ok, failureClass, reason }`. |
| `recovery` | `{ state, action, attempt, ledgerId, advised }`; see the states below. |

`recovery.state`: `none` (nothing to recover); `advised` (repairs apply but
automatic repair is off, and `advised` names them); `declined` (a repair applied
and its precondition did not hold); `applied` (a repair ran and its postcondition
held, and the next cycle is the proof); `failed` (a repair ran, its postcondition
failed, and rollback ran); `exhausted` (the attempt budget for this fingerprint
and repair is spent). `escalated` is reserved: the ledger records the hand-off to
the operator as an `escalated` line after a failed attempt, and the result reports
that attempt as `failed`. After `failed` and `exhausted` alike the runner takes the
normal failure pause, which is where an operator comes in.

<a id="42820e91-0021"></a>

### Runner fault classes

Six classes describe the runner rather than a sequence step. They are not in the
shared taxonomy and have no dispatcher handler: `outcome_unrecorded` (a cycle left
no usable outcome record), `vm_admission_occupied` and `vm_admission_unknown` (the
cycle-start check refused), `preamble_stall` and `cycle_killed` (the watchdog
killed the inner), and `cycle_spawn_failed` (the cycle process could not be
started). They appear in `status.json`'s `lastFailure.failureClass` and in a
result's `failureClass`.

<a id="42820e91-0022"></a>

### The shared steps

The pieces that decide whether a cycle may run, be replayed or count as a pass are
step functions in the contract module, and all three entry points call the same
ones. Each returns the same shape: `Step`, `Ok`, `Skipped`, `FailureClass`,
`Reason`, `Evidence`, plus fields of its own.

| Step | Wraps | Fails as |
|---|---|---|
| `Invoke-CycleCheckoutStep` | `Update-ProjectClone` (clone beside, verify, swap) | `bootstrap_sync`, stage `ProjectClone` |
| `Invoke-CycleAdmissionStep` | `Invoke-HostVmAdmission` | `vm_admission_occupied` (exit 1) or `vm_admission_unknown` (exit 2) |
| `Resolve-CycleReplayStep` | `Resolve-WarmResumeReplayPlan` | not a failure: `Ok` is false with a reason (`no-restore-point`, `restore-point-missing`, `safety-check-unavailable`) and the original failure stands |
| `Publish-CycleOutcomeRecord` / `Read-CycleOutcomeRecord` | the cycle outcome record | `outcome_unrecorded` |

The outcome record may also carry `failureClass` and `detail` (redacted, at most
300 characters), written only when the cycle knows them. They never decide whether
a record is valid. The framework pull is the case that needs them: it runs in the
cycle process, and the runner has to tell a stale git lock from a network failure.

<a id="42820e91-0023"></a>

### `recovery.ledger.ndjson` (what the runner may repair, and how often)

An append-only file under `$YURUNA_RUNTIME_DIR`, one JSON object per line. The
attempt budget used to be a counter in the outer loop's memory, which a runner
restart reset; a deterministic fault that outlived a restart was retried without
bound. The ledger keeps the count where a restart does not erase it, and every
decision is derived from the file, so a new process reading it reaches the same
answer.

| `kind` | Lines |
|---|---|
| `attempt` | `phase`: `started` (written and flushed before the action runs), then one of `succeeded`, `failed`, `declined`, `exhausted`, `rolled-back`, `rollback-failed`, `abandoned`, `escalated`. Carries `attemptId`, `fingerprint`, `failureClass`, `action`, `attempt`, `generation`, `reason`, `evidence`. |
| `resolved` | `scope` `all` or `fingerprint`: a passing cycle re-arms every budget. |

Rules:

1. **No durable record, no repair.** If the `started` line cannot be written, the
   action does not run. A ledger that exists but cannot be read counts as a spent
   budget, not an empty one.
2. **The budget** for a fingerprint and a repair is the number of `started` lines
   after the latest covering `resolved` line and within the last 24 hours. It is
   spent when that number reaches the repair's cap (`testCycle.autoRemediation.
   maxAttemptsPerCycle`, default 2; a repair may lower it).
3. **A crash is an attempt.** A `started` line with no terminal line younger than
   10 minutes is another process still working: the repair declines
   (`attempt-in-progress`). Older, it is abandoned: one `abandoned` line is
   appended, it counts as used, and it is never silently re-run.
4. Text is redacted before it is written, and lines that do not parse (a torn
   write) are skipped and counted.
5. Two runner processes can append at the same moment, and .NET appends do not
   serialize across processes: without a guard, lines were lost silently. Every
   append and every compaction therefore holds the companion file
   `recovery.ledger.guard`, opened exclusively; the operating system releases it
   when its holder dies. A writer that cannot get the guard within about two
   seconds treats the line as not written, which means no repair.
6. The file is compacted past 256 KB, keeping seven days, every unfinished attempt
   and the latest `resolved` line of each scope.

<a id="42820e91-0024"></a>

### The repairs

Automatic repair is off by default (`testCycle.autoRemediation.enabled`, see
[test-config.md](test-config.md#testcycleautoremediation)). With it off, nothing
is written to the ledger and a result carries `recovery.state` `advised` with the
names of the repairs that would have applied. With it on, the runner tries the
repairs that apply, in this order, and stops at the first that was applied. Each is
idempotent, takes no hypervisor action, and runs only a bounded git command at
most. None has been exercised against a live host; the tests use temporary
repositories and stand-in functions.

| Repair | Applies to | Precondition | Action | Postcondition | Rollback |
|---|---|---|---|---|---|
| `clear_stale_git_lock` | a `bootstrap_sync` failure at stage `FrameworkPull` or `ProjectClone` whose reason names a `.lock` file | a `*.lock` file directly under a repository's `.git` (or under `.git/refs`, three levels deep) is older than 10 minutes, and no `git` process is running on the machine (a process list that cannot be read counts as running, and so does a resident file-system-monitor daemon) | moves each lock into `runtime/recovery.quarantine/<attemptId>/<framework or project>/<path inside the repository>` (never deletes; nothing prunes the folder afterwards) | `git --no-optional-locks status --porcelain` (read-only, so it cannot recreate the lock) exits 0 within 30 seconds in every repository touched | moves the locks back, and never over a lock that has reappeared |
| `reclone_project` | a `bootstrap_sync` failure at stage `ProjectClone` | a project URL resolves (a pool assignment in `project.access.json` that is not `denied`, else `repositories.projectUrl`), and the current `project/` is not already healthy | `Update-ProjectClone`: clone beside, verify, swap; the previous checkout is kept when it fails | the checkout passes the health check | restores an interrupted swap |
| `end_failure_pause_early` | a failure class the dispatcher maps to a clearly safe retry (`wait_timeout`, `network_timeout`, `ip_not_discovered`, `input_lost`, `instrumentation_failure`, `host_io_blocked`) | the class is on that list | none: the effect is that the pause ends | always | none |

`clear_stale_git_lock` and `reclone_project` run before the failure pause (and
`clear_stale_git_lock` also before the hold that follows a failed framework pull);
`end_failure_pause_early` runs inside the pause, after its first poll interval, as
it always did. A repair that applied replaces the pause, and the next cycle is its
proof: a pass re-arms every budget, and a repeat of the same fingerprint spends it.
When a budget is spent the result says `exhausted` and the normal failure pause
applies.

Every ledger line also emits a `recovery_action` event (`action`, `decision`,
`phase`, `fingerprint`, `failureClass`, `attempt`, `attemptId`, `generation`,
`reason`). `failureClass` is left out when the result has none and when it is a
runner fault class, because the event schema checks the field against the shared
taxonomy; the ledger line keeps it. The older `auto_remediation_applied` event is
still emitted for the early pause end, now with the `attemptId`.

<a id="42820e91-001d"></a>

## Related

- [Handler contract](test-sequences.md#handler-contract) -- where the class / severity / recovery vocabulary is declared.
- [Test harness](test-harness.md) -- overall architecture.
- [Watchdog and heartbeat protocol](runner-outer-loop.md#watchdog-and-heartbeat-protocol) -- the kill side of self-healing.
- [Runner state machine](runner-outer-loop.md#runner-state-machine) -- the lifecycle that surfaces a fault transition.
- [Per-step perf log](test-perf.md) -- the `step_end` rows this shares a join shape with.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.11

Back to [Yuruna](../README.md)
