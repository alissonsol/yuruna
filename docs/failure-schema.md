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
| `repro` | object | Ready-to-run reproduction; see [repro](#repro). |

### `repro`

A reproduction an operator or autonomous remediator can run without reconstructing arguments.

| Field | Notes |
|---|---|
| `command` | `pwsh test/Debug-TestSequence.ps1 -SequenceName <name> [-GuestKey <k>] [-VMName <vm>] -logLevel Debug`. Re-runs the failing sequence (and its baseline chain) deterministically. It deliberately **omits** `-StartStep`: `stepNumber` / `resumeFromStep` are **file-local** (1-based within this sequence file), but `Debug-TestSequence -StartStep` is **chain-global**, so a naive `-StartStep` would mis-target a leaf that still has an unbuilt baseline. |
| `runnerScript` / `entrypoint` | `test/Debug-TestSequence.ps1` / `Debug-TestSequence`. |
| `sequenceName` | Same as the top-level field. |
| `resumeFromStep` | The file-local failing step. Safe to pass as `-StartStep` only when the sequence has no unbuilt baseline (the warm / `requiresSnapshot` path, or a baseline-less sequence). |

### Replay-boundary + inner-cause fields

These appear on **both** step and crash records (a crash after step N began still has a safe replay boundary and, if it bubbled through an exhausted `retry`, an inner cause worth routing on):

| Field | Type | Notes |
|---|---|---|
| `lastSucceededStepNumber` | int | Replay boundary -- step N succeeded; the failure landed on N+1. A "what's safe to replay past" marker, not an auto-resume pointer. |
| `innerActionVerb` / `innerFailureClass` / `innerSeverity` / `innerSuggestedRecoveries` | string / string / string / string[] | Set only when the failure bubbled through an exhausted `retry`; carry the deepest inner verb's classification so a remediator routes on the inner cause rather than the outer `retry_exhausted`. The [dispatcher](#remediation-dispatcher) routes on `innerFailureClass` when the outer class is `retry_exhausted` and an inner handler exists. `null` (array empty) otherwise. |

### `context`

| Field | Notes |
|---|---|
| `hostType` | e.g. `host.windows.hyper-v`. |
| `matchedFailurePattern` | The hard-block pattern `Wait-ForText` matched, or `null`. |
| `sequencePath` | Path of the failing sequence YAML. |
| `cycleFolder` | Cycle log dir (step failures only). |
| `failureScreenshotPath` / `failureOcrPath` | Cycle-dir-relative names (step failures only); may not exist (waitForText emits OCR text, non-OCR failures emit a screenshot) -- presence is checked at deep-link time. |
| `causeDetail` | Step records only: `{ ocrTail, patternsSought }` -- the freshest on-screen OCR text (bounded tail, <=1200 chars) and the patterns the wait was seeking at the failure site. Lets a consumer see the runtime cause behind a verb-static `failureClass`. Mirrored flat on the event as `causeOcrTail` / `causePatternsSought`. |
| `crash` | Crash records only: `{ error, origin, stack }`. |

The write is atomic (temp-file + rename via `Write-YurunaStateFile`) so a
remediator or the status service never observes a truncated record.

## `step_failure` NDJSON event

Emitted alongside the file so a stream consumer (status service,
remediation loop, CI hook) sees the failure without reading the file.
It carries the same values, flattened (no nested `context`), plus
`event` = `step_failure`, `ok` = `false`, and `durationMs` = `null`
(mirrors the `step_end` shape so a consumer can join the two on a single
field). It also carries `reason`, `classificationSource`, `sequenceName`,
`reproCommand` (the `repro.command` string), and `matchedFailurePattern`
(the nested-context field lifted flat). A crash event adds `crashError`.

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
no-BOM state-file primitive. Fields: `timestamp`, `failureClass`,
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

## Synthetic & infra records

Two record variants reuse the schema-v2 shape for failures outside a
normal step:

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

### Synthetic (watchdog-kill) record

When the outer watchdog SIGKILLs a wedged inner, the inner's failure path
cannot run, so the outer synthesizes a schema-v2 record: `reason` =
`watchdog_kill`, `classificationSource` = `synthetic`, `failureClass` =
`wait_timeout` (so the streak-capped auto-retry can end the pause early).
`stepNumber` (`0`) and `sequenceName` (`''`) are intentionally unresolved
-- the SIGKILL destroyed the only structured step location -- not omitted,
so the contract stays satisfied and a remediator stays null-safe.

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

## `warm_resume` event (checkpoint resume)

Warm-resume checkpointing (`Test.WarmResume.psm1`) turns a late-step transient
into an in-place retry instead of redoing the whole install. When a workload
sequence fails with a **transient** class (`network_timeout`, `wait_timeout`,
`instrumentation_failure`, `host_io_blocked`, `ip_not_discovered`,
`payload_unavailable` -- `Get-WarmResumeEligibleClass`), the runner re-runs the
*failed* sequence from `repro.resumeFromStep`
on the **same still-alive VM** (the teardown fires only on the final result),
up to `testCycle.warmResume.maxAttempts` (default 2), then continues any
remaining workload sequences. On exhaustion or an ineligible class it falls
through to the normal teardown + cold re-provision, so warm-resume is
safe-on-failure. Enabled by default; set `testCycle.warmResume.enabled: false`
to disable. Each attempt emits a `warm_resume` event: `event` = `warm_resume`,
`timestamp`, `guestKey`, `sequenceName`, `resumeFromStep`, `attempt`, plus
`failureClass` / `vmName` / `hostType` when known -- so a run that only passed
because it resumed stays queryable, never a silent pass.

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
restore to, so the checkpoint is used unchanged rather than refusing to resume:
declining would turn a recoverable transient back into the lost cycle warm resume
exists to prevent. A checkpoint already sitting on the boundary is not a rewind.

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

## `retry_attempt` / `retry_exhausted` events (retry telemetry)

The three retry stacks emit a structured attempt record so a flaky retry is
queryable in `cycle.events.ndjson`, not just buried in the human log:

- **`Yuruna.Retry`** (host-side pwsh: tofu init/plan/apply, helm/kubectl fetches)
  emits `retry_attempt` before each backoff and `retry_exhausted` on the final
  failure -- best-effort (`Send-CycleEventSafely` is Get-Command-guarded, so a
  standalone tofu run that never loaded `Test.Log` is unaffected).
- **The sequence `retry` verb** emits `retry_attempt` per failed inner pass and
  `retry_exhausted` on exhaustion, the latter carrying the deepest inner
  `failureClass` (the outer class collapses to `retry_exhausted`).
- **The guest bash lib** (`automation/yuruna-retry.sh`) can't reach the host
  stream, so it prints a `YURUNA_RETRY {stack,label,attempt,maxAttempts,rc,
  permanent}` marker to stderr; on the SSH verbs (`sshExec` /
  `sshFetchAndExecute`) the host parses those markers into `retry_attempt`
  events via `Publish-GuestRetryMarker`. The console/OCR fetch path keeps its
  log guest-local, so that path is not covered.

Fields (all additive; the schema is open): `event`, `timestamp`, `stack`
(`pwsh` / `sequence` / `bash`), `attempt`, `maxAttempts`, `exitCode`,
`description` (the label), and optionally `transient` / `permanent` /
`sleepSeconds` / `failureClass` / `guestKey` / `vmName`.

The cross-language fetch-and-execute failure sentinel `NONZERO SCRIPT EXIT:`
(the string the guest wrapper prints and the `fetchAndExecute` verb matches) is
a declared constant on each side (`Get-NonzeroScriptExitSentinel` + the bash
producer) with a drift-guard test, so the two sides can't silently diverge.

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

## Remediation dispatcher

The `failureClass` token on the record above is drawn from the enum in
[`Test.SequenceAction`](../test/modules/Test.SequenceAction.psm1). The
remediation dispatcher in
[`test/modules/Test.Remediation.psm1`](../test/modules/Test.Remediation.psm1)
maps that token to an actionable recommendation. Without it, an operator
(or a future autonomous loop) would have to grep the free-text error
message and guess; the dispatcher instead reads the failure record,
routes on `failureClass`, and returns what the caller should do.

The dispatcher is **advisory, and the loop is not closed**: it records a
decision and emits a recommendation, and applying that recommendation is
the caller's job. Nothing in the tree calls `Repair-Credential`, for
instance. Acting automatically needs a class allow-list and an attempt
cap first, so that a misclassified failure cannot drive a repair in a
loop -- which is why the detection half shipped ahead of the acting half.

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
  switch is still there, nothing it carries forwards, and each guest reports
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
  normally recovers, so this belongs in the transient fast-retry allow-lists. It
  stays ONE class rather than splitting on which leg failed: whether the payload
  arrives next time depends on the host becoming reachable again, not on the
  GitHub fallback, so a terminal 404 from that fallback does not make the
  failure permanent. Where the fallback IS the dead end -- a private repository
  with no token -- the recovery text names it.
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

### Public surface

| Function | Signature | Used by |
|---|---|---|
| `Register-RecoveryHandler` | `-FailureClass -Handler` | External modules add or override a handler |
| `Register-BuiltinRecoveryHandler` | (no args) | Installs the default handler set at module load |
| `Get-RecoveryHandler` | `-FailureClass` | Dispatcher; introspection |
| `Get-RegisteredFailureClass` | (no args) | Capability matrix on startup; introspection |
| `Get-RecoveryRecommendationName` | (no args) | Canonical recommendation vocabulary (shared with each verb's SuggestedRecoveries) |
| `Invoke-Remediation` | `-FailureRecord [-LastFailurePath]` | Operator / autonomous loop; returns the recommendation hashtable |
| `Clear-RecoveryHandler` | (no args) | Tests only |

### Recommendation taxonomy

Each handler returns a hashtable whose `Recommendation` field MUST be
one of the canonical values below, so a streaming consumer can pivot on
a small finite set instead of free-text matching:

| Recommendation | Meaning |
|---|---|
| `retry_immediately` | Transient; rerun the failing step now. |
| `retry_with_backoff` | Likely transient (network blip, rate limit); the caller picks the backoff. |
| `restart_from_snapshot` | Guest state went sideways; restore to the last good snapshot and replay from there. |
| `reconnect` | Transport-level (VNC dropped, SSH session died); rebuild the connection and continue. |
| `pause_and_inspect` | Repeating the step risks burning resources; surface and wait. |
| `operator_intervention_required` | The runner cannot self-recover (vault password wrong, image unsigned). |
| `escalate` | Reserved -- an external handler may return it to flag a novel case for the framework to learn. No built-in handler emits it; the no-handler / handler-error fallback is `operator_intervention_required`. |

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

### Advisory by design

Handlers return **what the caller should do**, not what they **did**. A
future iteration can flip individual handlers to act directly (call
`Repair-VncConnection`, `Wait-SshReady`, `Restore-VMDiskSnapshot`
themselves) once the autonomous loop's blast radius is bounded.

### Registry shape

The registry uses the shared
[`New-YurunaRegistry`](../test/modules/Test.Registry.psm1)
primitive, so it appears in `Get-YurunaRegistryDirectory` alongside
`SequenceAction`, `HostIO`, `OcrProvider`, and
[`HostCondition`](test-harness.md#host-condition-registry) -- autonomous
tooling enumerates every routing surface through one API.

### Event emission

Every dispatch emits a `remediation_recommended` NDJSON event
carrying `(failureClass, recommendation, severity, handledBy)` so a
streaming consumer follows what the dispatcher chose without parsing
the recommendation object. Schema lives in
[`Test.EventSchema`](../test/modules/Test.EventSchema.psm1) -- the same
validator that gates the cycle event stream.

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
   string-tests without a null guard), returning `@{ Recommendation =
   '<enum>'; Rationale = '<short>' }` (optional `Actions`, `HandledBy`,
   `AutoApply`). The dispatcher attaches severity from the failure
   record, not the handler.
4. The startup capability matrix picks up the registration
   automatically; the dispatcher cannot reach an unrouted class
   because the validator at module load throws if any enum value is
   missing a handler.

## Related

- [Handler contract](test-sequences.md#handler-contract) -- where the class / severity / recovery vocabulary is declared.
- [Test harness](test-harness.md) -- overall architecture.
- [Watchdog and heartbeat protocol](runner-outer-loop.md#watchdog-and-heartbeat-protocol) -- the kill side of self-healing.
- [Runner state machine](runner-outer-loop.md#runner-state-machine) -- the lifecycle that surfaces a fault transition.
- [Per-step perf log](test-perf.md) -- the `step_end` rows this shares a join shape with.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.20

Back to [Yuruna](../README.md)
