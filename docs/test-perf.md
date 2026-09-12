<a id="42185285-0001"></a>

# Per-step perf log

Append-only structured log of every step execution, designed for
cross-host / cross-cycle analytics -- "did this commit slow down step
X?", "is sequence Y faster on macos.utm than ubuntu.kvm?", "should we
invest more in host platform Z?". One JSONL file per cycle, one JSON
row per step execution.

The goal is **facts, not classification**: each row records what
happened. "Yellow tile" / regression detection is a *read-time*
computation against a rolling baseline -- never baked into the log.

Source: [`test/modules/Test.Perf.psm1`](../test/modules/Test.Perf.psm1).

---

<a id="42185285-0002"></a>

## File layout

Everything lives under `test/status/perf/`:

```
perf/
  cycles/
    2026-05-21T18-42-11Z__7f3a.jsonl    # one row per step execution
    2026-05-21T19-05-44Z__a91e.jsonl
    ...
  hostinfo/
    sha256-3b4e....txt                  # full Get-SystemDiagnostic dump
  guestinfo/                            # runtime-created by Set-PerfGuestContext; absent until a guest runs
    sha256-1c7a....json                 # small per-guest fingerprint
  checkpoints/                          # guest-pushed fetch-and-execute phase timings (control/perf-checkpoints)
    ...
  sequences/
    sha256-a039....yml                  # snapshot of the sequence YAML body
```

`host.uuid` is **not** under `perf/`; it lives in the sibling
`$env:YURUNA_RUNTIME_DIR/host.uuid` (`status/runtime/host.uuid`) because it is a
per-machine identity consulted by non-perf code paths.

**Why JSONL, one file per cycle.** Append-only writes (no
read-modify-write means no lock contention between writers and
collectors); partial-file recovery is trivial; DuckDB/jq/Loki/BigQuery
all consume it natively. CSV was rejected (rigid schema, no nesting),
SQLite too (file-locking overhead for write-once data).

**Why not extend `status.json`.** It is the live-state doc, re-serialized
on every step write; appending perf history would re-serialize the whole
growing document each time, where JSONL appends one row in O(1)
regardless of history depth.

---

<a id="42185285-0003"></a>

## Identity strategy

| Entity        | Identity                                                    | Stability                                       |
|---------------|-------------------------------------------------------------|-------------------------------------------------|
| Sequence      | `sequenceName` (file stem) + `sequenceGuid` (`42`-prefixed) | Name is today's join key. GUID anchors history through renames. |
| Invocation | `sequenceInvocationId` (fresh GUID per sequence entry) | Distinguishes repeated executions even when a temporary VM name is reused. |
| Step execution | `stepInvocationId` (fresh GUID per step/attempt) | Correlates a specific execution with guest checkpoints. |
| Sequence body | `sequenceContentHash` (sha256 of the YAML body)             | Identifies the exact YAML body, so analytics can tell edits of a sequence apart between `sequenceRevision` bumps. |
| Sequence shape| `sequenceRevision` (author-bumped int)                      | Bump when steps are added / removed / reordered. |
| Step          | `sequenceGuid` + `stepName` + `stepOccurrence`              | No per-step GUID by design. Step rename = accept the discontinuity. |
| Step position | `stepOrdinal` (as-of-execution snapshot)                    | Stored snapshot in time. Joins should go by `stepName`, not ordinal. |
| Host          | `hostUuid` (stable per machine) + `hostPlatform` enum       | UUID survives rename; platform is the cardinality knob (`host.macos.utm`, `host.ubuntu.kvm`, `host.windows.hyper-v`). |
| Guest         | `guestKey` (e.g. `guest.amazon.linux.2023`)                 | Already stable in the repo. |
| Code state    | `harnessCommit` + `projectCommit`                           | Two SHAs = the two repos that influence behavior. |
| Host capture  | `hostInfoHash` -> content-addressed sidecar                  | Dedupes across hundreds of cycles. |
| Guest capture | `guestInfoHash` -> content-addressed sidecar                 | Same. |

<a id="42185285-0004"></a>

### Why a `42`-prefixed sequence GUID, but no step GUID

A sequence is a stable user-facing concept that occasionally gets
renamed. A GUID rescues you from that one rename. Steps don't deserve
the same treatment -- renames are rare, and you accept the
discontinuity.

GUID shape: `42xxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` -- first two hex
chars are the literal `42` (a visual filter in mixed-source logs),
remaining 30 hex chars give ~120 bits of randomness, collision-free
at any realistic scale. Nothing reads the version or variant nibbles, so
neither is part of the contract -- uniqueness and the `42` prefix are.
The recipe below rewrites only `time_low`, leaving both nibbles as
`NewGuid` set them, so what it mints is also a well-formed RFC-4122
UUIDv4. Durable definition GUIDs use this prefix. Runtime sequence and step
invocation IDs use ordinary GUIDs written as 32 hex digits.

Mint a fresh one with PowerShell:

```
$r = [Guid]::NewGuid().ToString('N')
'42' + $r.Substring(2,6) + '-' + $r.Substring(8,4) + '-' + $r.Substring(12,4) + '-' + $r.Substring(16,4) + '-' + $r.Substring(20,12)
```

<a id="42185285-0005"></a>

### Sequence frontmatter

Every sequence YAML carries two top-level keys (declared in
[`test/schemas/sequence.schema.yml`](../test/schemas/sequence.schema.yml)):

```
# Perf-log identity (see https://yuruna.link/42185285). Bump revision on step add/remove.
sequenceGuid: 4224b44c-5e04-47e8-a61b-865d2a191b84
sequenceRevision: 1

description: "..."
resource:
  ...
```

<a id="42185285-0006"></a>

### GUI and SSH variants carry their own GUIDs

The GUI (`<name>.yml`) and SSH (`<name>.ssh.yml`) variants of the same
logical workflow are separate sequences: each declares its **own
`sequenceGuid`**, so each variant's history stands alone through
renames. To compare the two paths, join on the shared `sequenceName`
stem (strip the `.ssh` suffix) at query time.

If you split a logical sequence into two genuinely different ones,
mint a fresh GUID for the new file.

<a id="42185285-0007"></a>

### Step naming

`stepName` is the **raw, pre-expansion** `description:` string from
the YAML -- variables like `${vmName}` are intentionally NOT expanded
so the value is stable across cycles. Falls back to `step.action` when
no description is set.

`stepOccurrence` increments automatically when the same `stepName`
appears more than once in one sequence run (handles loops, repeated
prompts).

It counts the **name**, not the retry attempt. Two differently named
steps inside one retry attempt are both occurrence 1, and a step that
runs once per attempt reaches occurrence 2 only on the second attempt --
so a step first reached in a later attempt still reports occurrence 1
beside the earlier attempt's failure. Read `parentAttempt` for the
attempt.

`stepOrdinal` is the step's position in the executing `steps:` array
at the time it ran -- a snapshot. If a step is inserted at position
5, old position-5 rows keep their ordinal; new rows show ordinal 6.
**Cross-cycle joins go on `stepName`, never on `stepOrdinal`.**

<a id="42185285-0008"></a>

### Retry blocks

A `retry` wrapper emits its own row with the full enclosing duration and
final outcome. Each executed child also emits a row, including unsuccessful
attempts. These intervals overlap: sum only `parentStepOrdinal = 0` for
sequence work, step counts and final failures. Keep child failures as retry
history; a failed child followed by a passing retry must not mark the
invocation as failed.

Inner rows carry `parentStepOrdinal` = the immediate outer retry's position,
`parentAction = "retry"`, and `parentAttempt` = the 1-based attempt. Nested
wrappers themselves have a nonzero parent ordinal. Order by `startedAtUtc`
within `sequenceInvocationId`; ordinals repeat within retry blocks and do
not describe execution order. A wrapper that is killed before its end may
leave only child rows; the aggregate marks that incomplete record rather
than inventing a final outcome.

---

<a id="42185285-0009"></a>

## The row schema

Schema version: `2`, carried in every row's `schema:` field.

```
{
  "schema": 2,
  "cycleStartUtc": "2026-05-21T18:42:11Z",
  "cycleStartedAtUtc": "2026-05-21T18:42:11.003Z",

  "hostUuid": "428f1b6a2e7d4c80a14b9c2d3e4f0011",
  "hostname": "lenovo-y540",
  "hostPlatform": "host.ubuntu.kvm",
  "hostInfoHash": "sha256-3b4e...",

  "harnessCommit": "9d916894a1b8c2...",
  "projectCommit": "4f8b1c2d99e07a...",

  "sequenceName": "start.guest.amazon.linux.2023",
  "sequenceInvocationId": "9acf77a7eecd4030bbfa26f9870f92b6",
  "sequenceGuid": "4224b44c-5e04-47e8-a61b-865d2a191b84",
  "sequenceRevision": 1,
  "sequenceContentHash": "sha256-a039...",

  "guestKey": "guest.amazon.linux.2023",
  "vmName": "test-amazon-linux-2023-1748023331",
  "guestInfoHash": "sha256-1c7a...",

  "stepOrdinal": 6,
  "stepInvocationId": "1218f659979840bfb019d75d0370fa72",
  "stepOccurrence": 1,
  "stepName": "${vmName} login:",
  "stepKind": "passwdPrompt",
  "parentStepOrdinal": 0,
  "parentAction": "",
  "parentAttempt": 0,

  "startedAtUtc": "2026-05-21T18:47:02.412Z",
  "endedAtUtc":   "2026-05-21T18:47:09.871Z",
  "durationMs": 7459,
  "outcome": "pass",
  "attempts": 1,
  "retryCount": 0
}
```

Field reference:

| Field | Type | Notes |
|---|---|---|
| `schema` | int | Wire-format version. Readers branch on this. |
| `cycleStartUtc` | string | ISO-8601-Z UTC at cycle start. Same value as the `status.json` cycle id; joinable across logs. |
| `cycleStartedAtUtc` | string | `Start-PerfCycle` invocation time. May differ from `cycleStartUtc` by ms. |
| `hostUuid` | string | `42`-prefixed 32-hex, persisted in `status/runtime/host.uuid`. Stable per machine. |
| `hostname` | string | OS hostname. Can change; UUID is the durable id. |
| `hostPlatform` | enum | `host.macos.utm`, `host.ubuntu.kvm`, `host.windows.hyper-v`. |
| `hostInfoHash` | string\|null | sha256 of `host.diagnostic.txt` captured at cycle start. |
| `harnessCommit` | string | yuruna repo SHA at cycle start. |
| `projectCommit` | string\|null | yuruna-project repo SHA at cycle start. `null` for in-tree fallback. |
| `sequenceName` | string | File stem (no path, no extension). Primary join key. |
| `sequenceInvocationId` | string | Fresh GUID (32 hex digits) minted by `Set-PerfSequenceContext` for this invocation. Stable across its retry children; different on the next invocation, including child-process entries. Schema 1 rows omit it. |
| `stepInvocationId` | string\|null | Fresh GUID for the executed step/attempt. Checkpoint sidecars carry this and `sequenceInvocationId` for exact joins. |
| `sequenceGuid` | string\|null | `42`-prefixed GUID from sequence YAML frontmatter. |
| `sequenceRevision` | int | Author-bumped integer from sequence YAML frontmatter. |
| `sequenceContentHash` | string\|null | sha256 of the YAML body that ran. |
| `guestKey` | string\|null | e.g. `guest.amazon.linux.2023`. |
| `vmName` | string\|null | VM name captured for the invocation. Names can be reused or renamed; this is not an invocation key. |
| `guestInfoHash` | string\|null | sha256 of a small JSON fingerprint (base image, ...). |
| `stepOrdinal` | int | 1-based position in the executing `steps:` array. Snapshot in time. |
| `stepOccurrence` | int | 1-based occurrence count of `stepName` in this sequence run. |
| `stepName` | string | Raw (pre-expansion) `description:`, falls back to `step.action`. |
| `stepKind` | string | The `step.action` verb (`waitForText`, `sshExec`, ...). Lets you slice by action type. |
| `parentStepOrdinal` | int | Outer retry's ordinal when this row is inside a retry block; `0` otherwise. |
| `parentAction` | string | `"retry"` when inside a retry block; `""` otherwise. |
| `parentAttempt` | int | 1-based retry attempt this row ran in; `0` outside a retry, and on any row that does not carry the field. The only field that separates one attempt's rows from another's -- `stepOccurrence` counts names, not attempts. |
| `startedAtUtc` | string | ISO-8601-Z UTC start. |
| `endedAtUtc` | string | ISO-8601-Z UTC end. |
| `durationMs` | int | Explicit even though derivable -- saves every consumer from parsing two timestamps. |
| `outcome` | enum | `pass`, `fail`, `skipped`, `timeout`. The enclosing retry reports its final result. |
| `diagnosticOutcome` | enum, optional | `complete`, `partial`, `timeout`, `unavailable` for a diagnostic action; separate from its soft-failing workload outcome. |
| `evidenceCaptureDurationMs` | int, optional | Time spent copying execution evidence inside this step. Included in `durationMs`, not subtracted from elapsed time. |
| `checkpointSourceStepInvocationId` | string, optional | Original execution ID when SSH reattaches to work begun by an earlier step. Original phase offsets are not rescaled into the new observer interval. |
| `attempts` | int | Number of attempts this row represents (>=1). |
| `retryCount` | int | Number of failures before the recorded outcome. |

What is **not** in the row (intentional):

- **No yellow / threshold classification.** Computed at read time against
  a rolling baseline keyed on
  `(sequenceName, stepName, hostPlatform, guestKey, sequenceRevision)`.
- **No full host/guest dump text.** That's what the `*InfoHash` sidecars
  exist for. 10 KB of diagnostic on every row of every cycle = a
  self-inflicted bandwidth wound.
- **No human descriptions.** Belong in the sequence YAML (snapshotted
  under `perf/sequences/<hash>.yml`), not in every row.

---

<a id="42185285-000a"></a>

## Content-addressed sidecars

`hostinfo/<sha256>.txt` is the full `Get-SystemDiagnostic` text, named
by its hash. Same for `guestinfo/` (small JSON fingerprint) and
`sequences/` (the YAML body). The emitter:

1. Captures (or receives) the body.
2. Hashes it with sha256.
3. Writes the sidecar file only if `<hash>.<ext>` doesn't already exist.
4. Embeds the hash in every step row.

A host whose hardware doesn't change emits **one** ~10 KB file for the
lifetime of that machine. The same hash collapses across thousands of
cycle files at query time (`JOIN` on hash, render once), honoring
"hostinfo is assumed to be stable" without bloating per-step rows.

---

<a id="42185285-000b"></a>

## Query model

The status service's `/control/perf-aggregates` route reads schema 1 and 2
rows and returns one entry per invocation under `sequences[sequenceName]`.
`durationMs` is the sum of top-level work; `elapsedMs` is the first-to-last step
span, or null if timing is incomplete. Gaps and overlap make these different
quantities. `stepCount` and `failCount` count top-level rows only;
`retryFailureCount` preserves unsuccessful nested rows. Diagnostic incompleteness
and missing enclosing rows are reported separately. The performance page draws
one icicle per invocation, using elapsed time and retaining retry children.

Schema 1 has no invocation ID. When chronological top-level ordinals restart,
the reader separates the runs and labels `invocationIdentitySource` as
`legacy-inferred`; the resulting `legacy-N` ID is local to the host, cycle and
sequence. Concurrent or truncated old executions cannot always be separated.
Schema 2 uses the recorded ID, which is independent of VM name and ordinal.
No historical JSONL files are rewritten.

Guest checkpoint sidecars join by both execution IDs when present, for console
and SSH fetch actions. Legacy sidecars fall back to their host reception time
inside the step interval. An identified but unmatched sidecar does not fall
back to another step's time window. Reattached execution provenance remains
visible without pretending earlier phase offsets measure the new observer.

The route caches its response until a POST request triggers recalculation. The generated
status-service process must be restarted after updating its source.

JSONL files are queryable straight from DuckDB -- no ETL needed:

```
-- Is step [seqX][passwdPrompt] faster on macos.utm than ubuntu.kvm?
SELECT hostPlatform, guestKey, COUNT(*) n,
       AVG(durationMs) avg_ms, MEDIAN(durationMs) p50, QUANTILE(durationMs,0.95) p95
FROM read_json_auto('perf/cycles/*.jsonl')
WHERE outcome='pass'
  AND sequenceName='start.guest.amazon.linux.2023'
  AND stepName='${vmName} login:'
  AND sequenceRevision=1
GROUP BY 1,2 ORDER BY p50;
```

```
-- Which harness commit slowed step X?
SELECT harnessCommit, AVG(durationMs) avg_ms, COUNT(*) n
FROM read_json_auto('perf/cycles/*.jsonl')
WHERE sequenceName=? AND stepName=? AND outcome='pass'
GROUP BY harnessCommit
ORDER BY MIN(cycleStartedAtUtc);
```

```
-- Should I invest more in ubuntu.kvm hosts?
SELECT hostPlatform,
       SUM(durationMs)/3600000.0 host_hours,
       AVG(CASE outcome WHEN 'pass' THEN 1.0 ELSE 0 END) pass_rate
FROM read_json_auto('perf/cycles/*.jsonl')
WHERE cycleStartedAtUtc > now() - INTERVAL 30 DAY
  AND COALESCE(parentStepOrdinal, 0) = 0
GROUP BY 1;
```

Yellow-tile classification (read-time, never stored):

```
WITH baseline AS (
  SELECT sequenceName, stepName, hostPlatform, guestKey, sequenceRevision,
         AVG(durationMs) mu, STDDEV(durationMs) sigma
  FROM read_json_auto('perf/cycles/*.jsonl')
  WHERE outcome='pass' AND cycleStartedAtUtc > now() - INTERVAL 14 DAY
  GROUP BY 1,2,3,4,5)
SELECT r.cycleStartUtc, r.sequenceName, r.stepName,
       (r.durationMs - b.mu) / NULLIF(b.sigma,0) AS z
FROM   read_json_auto('perf/cycles/2026-05-21*.jsonl') r
JOIN   baseline b USING (sequenceName, stepName, hostPlatform, guestKey, sequenceRevision)
WHERE  ABS((r.durationMs - b.mu) / NULLIF(b.sigma,0)) > 2;
```

A cycle tile turns yellow when `|z| > 2` on any passing step. Today
the dashboard only renders green / red -- this is the data plumbing
for tomorrow's yellow tier.

---

<a id="42185285-000c"></a>

## What changes when

- **A sequence is renamed.** GUID stays; `sequenceName` changes; joins on
  GUID keep working across the rename, joins on name see a clean break.
- **A step is added / removed / reordered.** Bump `sequenceRevision`
  in the sequence YAML. Future rows carry the new revision; baseline
  queries naturally segment by revision.
- **A step is renamed.** Accept the discontinuity (old name's series
  ends, new name's begins). If it ever matters, add a manual
  `step_aliases.yml` and join through it at query time.
- **A new host is added.** First cycle on that machine mints
  `status/runtime/host.uuid` (`42`-prefixed). Persists across cycles.
- **A host's diagnostic changes** (kernel upgrade, hardware swap).
  `hostInfoHash` changes; cycles before / after group naturally on
  the hash.

---

<a id="42185285-000d"></a>

## Lifecycle hooks

The emitter is wired into the runner at three points:

1. **`Test.RunnerInnerLoop.psm1`** calls `Start-PerfCycle` once per
   cycle, right after the cycle-start host diagnostic is captured --
   hash-stores the diagnostic, opens the cycle's JSONL file, stamps
   the two commit SHAs.
2. **`Test.SequenceEngine.psm1`** calls `Set-PerfSequenceContext` +
   `Set-PerfGuestContext` once per sequence after `Read-SequenceFile`
   -- mints the invocation ID, snapshots the YAML body and pins guest identity for the rows
   that follow.
3. **`Test.SequenceEngine.psm1`**, inside `$invokeStepBlock`, calls
   `Write-PerfStepRow` at the end of every step iteration, including retry wrappers
   -- one atomic `AppendAllText` per step.

Every entry point is defensive: a missing module, missing
`YURUNA_RUNTIME_DIR`, or a sequence with no frontmatter all degrade to
"silent no-op" rather than failing the cycle.

---

<a id="42185285-000e"></a>

## Phase plan

The emitter and `performance.html` are active. The status service aggregates
recent cycles and renders invocation timelines; no DuckDB browser runtime is
required. Statistical regression classification and centralized cross-host
queries remain future work. JSONL remains the canonical per-step record.

<a id="42185285-000f"></a>

## Explicit non-goals

- **Not** extending `status.json` -- rewritten on every step write, so piling history on it makes that cost worse.
- **Not** Prometheus / Loki for the canonical store. Prometheus is for
  high-frequency gauges; perf-step durations are sparse rich events.
  (Promtail still tails `outer.log` for human debugging -- orthogonal.)
- **No daemon or DB process.** Append-only files only.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.12

Back to [Yuruna](../README.md)
