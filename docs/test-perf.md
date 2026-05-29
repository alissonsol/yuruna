# Per-step perf log

Append-only structured log of every step execution, designed for
cross-host / cross-cycle analytics — "did this commit slow down step
X?", "is sequence Y faster on macos.utm than ubuntu.kvm?", "should we
invest more in host platform Z?". One JSONL file per cycle, one JSON
row per step execution.

The goal is **facts, not classification**: each row records what
happened. "Yellow tile" / regression detection is a *read-time*
computation against a rolling baseline — never baked into the log.

Source: [`test/modules/Test.Perf.psm1`](../test/modules/Test.Perf.psm1).

---

## File layout

Everything lives under `$env:YURUNA_RUNTIME_DIR/perf/`:

```
perf/
  host.uuid                             # 42-prefixed, persisted on first cycle
  cycles/
    2026-05-21T18-42-11Z__7f3a.jsonl    # one row per step execution
    2026-05-21T19-05-44Z__a91e.jsonl
    ...
  hostinfo/
    sha256-3b4e....txt                  # full Get-SystemDiagnostic dump
  guestinfo/
    sha256-1c7a....json                 # small per-guest fingerprint
  sequences/
    sha256-a039....yml                  # snapshot of the sequence YAML body
```

**Why JSONL, one file per cycle.** Append-only writes (no
read-modify-write means no lock contention between writers and
collectors); partial-file recovery is trivial; DuckDB/jq/Loki/BigQuery
all consume it natively. CSV was rejected (rigid schema, no nesting);
SQLite was rejected (file-locking overhead for write-once data).

**Why not extend `status.json`.** `status.json` is the live-state doc
re-serialized on every step write. Appending the perf history to it
would re-serialize the entire growing document on every step. JSONL
appends one row in O(1) regardless of history depth.

---

## Identity strategy

| Entity        | Identity                                                    | Stability                                       |
|---------------|-------------------------------------------------------------|-------------------------------------------------|
| Sequence      | `sequenceName` (file stem) + `sequenceGuid` (`42`-prefixed) | Name is today's join key. GUID anchors history through renames. |
| Sequence body | `sequenceContentHash` (sha256 of the YAML body)             | Discriminates `gui/` vs `ssh/` variants of the same logical sequence (they intentionally share `sequenceGuid`). |
| Sequence shape| `sequenceRevision` (author-bumped int)                      | Bump when steps are added / removed / reordered. |
| Step          | `sequenceGuid` + `stepName` + `stepOccurrence`              | No per-step GUID by design. Step rename = accept the discontinuity. |
| Step position | `stepOrdinal` (as-of-execution snapshot)                    | Stored snapshot in time. Joins should go by `stepName`, not ordinal. |
| Host          | `hostUuid` (stable per machine) + `hostPlatform` enum       | UUID survives rename; platform is the cardinality knob (`host.macos.utm`, `host.ubuntu.kvm`, `host.windows.hyper-v`). |
| Guest         | `guestKey` (e.g. `guest.amazon.linux.2023`)                 | Already stable in the repo. |
| Code state    | `harnessCommit` + `projectCommit`                           | Two SHAs = the two repos that influence behavior. |
| Host capture  | `hostInfoHash` → content-addressed sidecar                  | Dedupes across hundreds of cycles. |
| Guest capture | `guestInfoHash` → content-addressed sidecar                 | Same. |

### Why a `42`-prefixed sequence GUID, but no step GUID

A sequence is a stable user-facing concept that occasionally gets
renamed. A GUID rescues you from that one rename. Steps don't deserve
the same treatment — step renames are rare; when they happen you
accept the discontinuity (old name's series ends, new name's begins).

GUID shape: `42xxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` — first two hex
chars are the literal `42` (visual filter in mixed-source logs;
recognizable at a glance), remaining 30 hex chars give ≈ 120 bits of
randomness — collision-free at any realistic scale. Not a strict
RFC-4122 UUIDv4 (the variant nibble can be anything), but no consumer
cares.

Mint a fresh one with PowerShell:

```
$r = [Guid]::NewGuid().ToString('N')
'42' + $r.Substring(2,6) + '-' + $r.Substring(8,4) + '-' + $r.Substring(12,4) + '-' + $r.Substring(16,4) + '-' + $r.Substring(20,12)
```

### Sequence frontmatter

Every sequence YAML carries two top-level keys (declared in
[`test/schemas/sequence.schema.yml`](../test/schemas/sequence.schema.yml)):

```
# Perf-log identity (see https://yuruna.link/test/perf). Bump revision on step add/remove.
sequenceGuid: 4224b44c-5e04-47e8-a61b-865d2a191b84
sequenceRevision: 1

description: "..."
baseline:
  ...
```

### gui/ and ssh/ variants share a GUID

The `gui/` and `ssh/` variants of the same logical sequence (e.g.
`start.guest.ubuntu.server.24`) are different YAML files driving the
same logical workflow with different keystroke mechanisms. They are
declared with the **same `sequenceGuid`** so analytics can:

- Join them by default — "how long does it take to start Ubuntu 24?".
- Split them when needed — `GROUP BY sequenceContentHash` to compare
  the keystroke-driven path vs the SSH-driven path.

If you split a logical sequence into two genuinely different ones,
mint a fresh GUID for the new file.

### Step naming

`stepName` is the **raw, pre-expansion** `description:` string from
the YAML — variables like `${vmName}` are intentionally NOT expanded
so the value is stable across cycles. Falls back to `step.action` when
no description is set.

`stepOccurrence` increments automatically when the same `stepName`
appears more than once in one sequence run (handles loops, repeated
prompts).

`stepOrdinal` is the step's position in the executing `steps:` array
at the time it ran — a snapshot. If a step gets inserted at position
5, old position-5 rows keep their ordinal; new rows show ordinal 6.
**Cross-cycle joins go on `stepName`, never on `stepOrdinal`.**

### Retry blocks

When a `retry` block re-runs its inner steps, each inner attempt emits
its own row. The retry-wrapper itself does NOT emit a row (its
duration is the sum of inner durations). Inner rows carry
`parentStepOrdinal` = outer retry's position and `parentAction =
"retry"` so the wrapper is reconstructible at query time.

---

## The row schema

Schema version: `1` (carried in every row's `schema:` field; readers
branch on it).

```
{
  "schema": 1,
  "cycleId": "2026-05-21T18:42:11Z",
  "cycleStartedAtUtc": "2026-05-21T18:42:11.003Z",

  "hostUuid": "428f1b6a2e7d4c80a14b9c2d3e4f0011",
  "hostname": "lenovo-y540",
  "hostPlatform": "host.ubuntu.kvm",
  "hostInfoHash": "sha256-3b4e...",

  "harnessCommit": "9d916894a1b8c2...",
  "projectCommit": "4f8b1c2d99e07a...",

  "sequenceName": "start.guest.amazon.linux.2023",
  "sequenceGuid": "4224b44c-5e04-47e8-a61b-865d2a191b84",
  "sequenceRevision": 1,
  "sequenceContentHash": "sha256-a039...",

  "guestKey": "guest.amazon.linux.2023",
  "vmName": "test-amazon-linux-2023-1748023331",
  "guestInfoHash": "sha256-1c7a...",

  "stepOrdinal": 6,
  "stepOccurrence": 1,
  "stepName": "${vmName} login:",
  "stepKind": "passwdPrompt",
  "parentStepOrdinal": 0,
  "parentAction": "",

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
| `cycleId` | string | ISO-8601-Z UTC at cycle start. Same value as the `status.json` cycle id; joinable across logs. |
| `cycleStartedAtUtc` | string | `Start-PerfCycle` invocation time. May differ from `cycleId` by ms. |
| `hostUuid` | string | `42`-prefixed 32-hex, persisted in `perf/host.uuid`. Stable per machine. |
| `hostname` | string | OS hostname. Can change; UUID is the durable id. |
| `hostPlatform` | enum | `host.macos.utm`, `host.ubuntu.kvm`, `host.windows.hyper-v`. |
| `hostInfoHash` | string\|null | sha256 of `host.diagnostic.txt` captured at cycle start. |
| `harnessCommit` | string | yuruna repo SHA at cycle start. |
| `projectCommit` | string\|null | yuruna-project repo SHA at cycle start. `null` for in-tree fallback. |
| `sequenceName` | string | File stem (no path, no extension). Primary join key. |
| `sequenceGuid` | string\|null | `42`-prefixed GUID from sequence YAML frontmatter. |
| `sequenceRevision` | int | Author-bumped integer from sequence YAML frontmatter. |
| `sequenceContentHash` | string\|null | sha256 of the YAML body that ran. |
| `guestKey` | string\|null | e.g. `guest.amazon.linux.2023`. |
| `vmName` | string\|null | VM name including the per-cycle timestamp suffix. |
| `guestInfoHash` | string\|null | sha256 of a small JSON fingerprint (base image, ...). |
| `stepOrdinal` | int | 1-based position in the executing `steps:` array. Snapshot in time. |
| `stepOccurrence` | int | 1-based occurrence count of `stepName` in this sequence run. |
| `stepName` | string | Raw (pre-expansion) `description:`, falls back to `step.action`. |
| `stepKind` | string | The `step.action` verb (`waitForText`, `sshExec`, ...). Lets you slice by action type. |
| `parentStepOrdinal` | int | Outer retry's ordinal when this row is inside a retry block; `0` otherwise. |
| `parentAction` | string | `"retry"` when inside a retry block; `""` otherwise. |
| `startedAtUtc` | string | ISO-8601-Z UTC start. |
| `endedAtUtc` | string | ISO-8601-Z UTC end. |
| `durationMs` | int | Explicit even though derivable — saves every consumer from parsing two timestamps. |
| `outcome` | enum | `pass`, `fail`, `skipped`, `timeout`. |
| `attempts` | int | Number of attempts this row represents (≥1). |
| `retryCount` | int | Number of failures before the recorded outcome. |

What is **not** in the row (intentional):

- **No yellow / threshold classification.** Computed at read time against
  a rolling baseline keyed on
  `(sequenceName, stepName, hostPlatform, guestKey, sequenceRevision)`.
- **No full host/guest dump text.** That's what the `*InfoHash` sidecars
  exist for. 10 kB of diagnostic on every row of every cycle = a
  self-inflicted bandwidth wound.
- **No human descriptions.** Belong in the sequence YAML (snapshotted
  under `perf/sequences/<hash>.yml`), not in every row.

---

## Content-addressed sidecars

`hostinfo/<sha256>.txt` is the full `Get-SystemDiagnostic` text, named
by its hash. Same for `guestinfo/` (small JSON fingerprint) and
`sequences/` (the YAML body). The emitter:

1. Captures (or receives) the body.
2. Hashes it with sha256.
3. Writes the sidecar file only if `<hash>.<ext>` doesn't already exist.
4. Embeds the hash in every step row.

A host whose hardware doesn't change emits **one** ~10 KB file per
machine for the lifetime of that machine. The same hash collapses
across thousands of cycle files at query time (`JOIN` on hash, render
once). This is what lets the schema honor "hostinfo is assumed to be
stable" without bloating per-step rows.

---

## Query model

JSONL files are queryable straight from DuckDB — no ETL needed:

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
SELECT r.cycleId, r.sequenceName, r.stepName,
       (r.durationMs - b.mu) / NULLIF(b.sigma,0) AS z
FROM   read_json_auto('perf/cycles/2026-05-21*.jsonl') r
JOIN   baseline b USING (sequenceName, stepName, hostPlatform, guestKey, sequenceRevision)
WHERE  ABS((r.durationMs - b.mu) / NULLIF(b.sigma,0)) > 2;
```

A cycle tile turns yellow when `|z| > 2` on any passing step. Today
the dashboard only renders green / red — this is the data plumbing
for tomorrow's yellow tier.

---

## What changes when

- **A sequence is renamed.** GUID stays; `sequenceName` changes; joins on
  GUID continue to work across the rename. Joins on name see a clean
  break.
- **A step is added / removed / reordered.** Bump `sequenceRevision`
  in the sequence YAML. Future rows carry the new revision; baseline
  queries naturally segment by revision.
- **A step is renamed.** Accept the discontinuity (old name's series
  ends, new name's begins). If it ever matters, add a manual
  `step_aliases.yml` and join through it at query time.
- **A new host is added.** First cycle on that machine mints
  `perf/host.uuid` (`42`-prefixed). Persists across cycles.
- **A host's diagnostic changes** (kernel upgrade, hardware swap).
  `hostInfoHash` changes; cycles before / after group naturally on
  the hash.

---

## Lifecycle hooks

The emitter is wired into the runner at three points:

1. **`Invoke-TestInnerRunner.ps1`** calls `Start-PerfCycle` once per
   cycle, right after the cycle-start host diagnostic is captured —
   hash-stores the diagnostic, opens the cycle's JSONL file, stamps
   the two commit SHAs.
2. **`Invoke-Sequence.psm1`** calls `Set-PerfSequenceContext` +
   `Set-PerfGuestContext` once per sequence after `Read-SequenceFile`
   — snapshots the YAML body and pins guest identity for the rows
   that follow.
3. **`Invoke-Sequence.psm1`**, inside `$invokeStepBlock`, calls
   `Write-PerfStepRow` at the end of every non-retry step iteration
   — one atomic `AppendAllText` per step.

Every entry point is defensive: a missing module, missing
`YURUNA_RUNTIME_DIR`, or a sequence with no frontmatter all degrade to
"silent no-op" rather than failing the cycle. **Facts only, never
crashes a cycle.**

---

## Phase plan

- **Phase 1 (current).** Emit rows. Nothing reads them yet. Two weeks
  of cycles produce baseline data; without it, yellow-tile thresholds
  have no signal to use.
- **Phase 2.** A status-page `perf-summary.html` running DuckDB-WASM
  queries against `/perf/cycles/*.jsonl` served by
  `Start-StatusService.ps1`. Read-only summary tables.
- **Phase 3.** Wire the yellow-tile classifier into `status/index.html`
  cycle tiles.
- **Phase 4.** Central collector rsyncs each host's `perf/` into a
  shared store; cross-host queries become free without code change.

## Explicit non-goals

- **Not** extending `status.json`. The doc is rewritten on every step
  write; piling history on it makes the perf cost worse.
- **Not** Prometheus / Loki for the canonical store. Prometheus is for
  high-frequency gauges; perf-step durations are sparse rich events.
  (Promtail still tails `outer.log` for human debugging — orthogonal.)
- **No daemon or DB process.** Append-only files only.

---

Back to [Yuruna](https://yuruna.com).

---

Copyright (c) 2019-2026 by Alisson Sol et al.
