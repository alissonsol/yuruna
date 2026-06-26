# Multi-host pool harness — design (for review)

**Goal.** Evolve the single-host continuous test runner into a **multi-host,
pool-based** harness:

- **Pools** of execution hosts (mixed architectures allowed in a pool).
- **Test sets** assigned to pools (named groups of guests + sequences),
  replacing the implicit per-host sequence list.
- **Cycle strategies**: run a pool's test sets sequentially in one VM
  lifecycle, or as separate cycles per test set.
- **Aggregated status page** (status.openai.com style): 24h pool health with
  **Pool → Host → Cycle → Guest → Step → Error** drill-down.

**Why.** Today one machine runs all tests with its own local status. Scaling to
multiple machines (different OS/hypervisor combos) with centralized visibility
needs a coordination + aggregation layer the single-host design never had.

This is a **starting design for review**, grounded in a code survey of the
*current* harness (the prior plan in `project_pool_test_harness` is ~72 days old
and substantially stale).

## Decisions locked (2026-06-09)

1. **Coordinator = thin-aggregator hybrid** (§3): decentralized self-driving
   runners that PULL pool intent and PUSH/expose telemetry to a read-side
   aggregator — **not** a central command-master.
2. **Store = split:**
   - **Slow-changing intent → git**, hosted on the LAN and **replicated across
     the pool** (each node pulls from a LAN-local git remote, not GitHub).
   - **High-volume telemetry → a DB/file store.**
3. **Pool services run on the Yuruna-Caching-Proxy machine.** It is already the
   LAN service host. Confirmed stack on `host/vmconfig/caching-proxy.base.user-data`:
   **Squid** (squid-openssl) · **Apache2** · **Prometheus** + squid-exporter
   (`:9301`) · **Loki** (`:3100`) · **Promtail** · **Grafana** (`:3000`,
   anonymous Viewer) · plus the **caching-proxy-parser** custom Go systemd
   service — the precedent for adding a pool service here. The aggregator,
   telemetry store, and intent git remote are added to this machine.

The machine *already* runs a log store (Loki), a metrics store (Prometheus), and
a dashboard tool (Grafana), so the follow-on decisions all resolved toward reuse:

4. **Telemetry + dashboard = reuse the existing stack.** NDJSON events → **Loki**;
   numeric pool metrics → **Prometheus**; the 24h pool heatmap / timeline /
   incident view → **Grafana**; deep drill-down to per-step artifacts
   **deep-links back to each host's existing status server** (artifacts stay on
   the host). No custom store, no custom pool dashboard.
5. **Intent git store = a bare git repo on the proxy machine.** Pool nodes clone
   once and **pull over the LAN**; the admin CLI pushes to it. No git server, no
   extra service.
6. **Auth/TLS = trusted-LAN posture** (matches the existing anonymous-Viewer Grafana on
   the LAN). Phase 6 added proxy-CA-leaf TLS on `:9400` + a bearer-gated `/ingest` push
   route (both default-off); the open read endpoints stay unauthenticated.
7. **Test-set config UX = YAML-in-git via the admin CLI** (consistent with the
   git intent store + the existing `POST /control/test-config` validation).

## Status — done vs remaining (updated 2026-06-10)

A running ledger of what is **shipped + live** on the caching-proxy vs what is
**open**. The phased plan (§6) and the Phase-0/MVP plan (§10) carry the design
detail; this is the at-a-glance split.

### ✅ Done (shipped, deployed live)

- **Phase 0 — host identity + capability record.** Stable `hostId`
  (`runtime/host.uuid`); `(hostId, runId, cycleId)` stamped on `status.json` and
  every NDJSON event; host registration record. (§10 Phase 0.)
- **Phase 1 (MVP) — read-only pool view.** Self-discovering collector under
  `test/extension/pool-aggregator/`: discovers members from the squid access
  log, probes `:8080/runtime/status.json`, keys on `hostId` (DHCP-resilient),
  pushes transitions to Loki + Prometheus counters, serves `:9400`
  (`/healthz`, `/metrics`, `/api/v1/pool-status`). (§10 MVP.)
- **Local-repo deploy.** Collector + parser build from the deploying host's
  **local working tree** (`/yuruna-repo/`), not the public mirror; host IP is
  topology-aware (bridged → host LAN IP); `Start-CachingProxy.ps1` brings the
  status server up before the cache VM boots.
- **Dashboard — operator pool view** (`grafana-pool-dashboard.json`): summary
  tiles, per-host **table** (status · last cycle · last seen · pass/fail, with
  deep-links to each host's status page + cycle folder), host×time
  **state-timeline**, and a drill-down row. Status-page state colors
  (running = blue); per-panel info (i) icons.
- **Restart-survival.** Cycle counts rehydrate from Loki on startup, so a
  collector restart resumes its counters instead of resetting to zero.
- **Phase 2 — per-step NDJSON tail (incident drill-down).** The collector tails
  each host's `cycle.events.ndjson` into Loki (`{pool,hostId,src=event}`); the
  drill-down row surfaces **which step failed** (step_failure), the full cycle
  event stream, and status transitions.
- **Phase 2 — incident correlation.** Per-host N-failures-in-M-minutes **and**
  cross-host / pool-wide (K hosts failing within a short window) detection in the
  collector: `yuruna_pool_host_incident` / `_incidents_active` / `_wide_incident`
  / `_wide_incident_hosts` gauges, per-host + pool-wide open/resolve events to
  Loki (`{pool,src=incident[,scope=pool]}`), "Hosts in incident" + "Pool-wide
  incident" tiles, an incidents panel + a failure-class/severity breakdown panel.
  Open incidents (per-host + pool-wide) restore from the incident feed on
  restart with their original id/startedAt. (§6 Phase 2.) Deferred: failure-class
  histogram attached to the incident *object*; same-class cross-host requirement.

- **Phase 3 — schemas + intent store + pool-sync + admin CLI.** v1 schemas
  (`pools.yml`, `test-sets/<name>.yml`, `guests.compatibility.yml`, the extended
  `host.registration.json`) in `test/schemas/`; the runner pool-sync shim
  (`Test.PoolSync.psm1`, default-off, bounded, prompt-proof) PULLs intent each
  cycle + reconciles `desiredState`; the host advertises its derived `poolId` and
  the aggregator labels per-host telemetry by it; the bare intent repo is seeded
  on the proxy + served read-only over HTTP; admin CLI (`New-Pool` / `Add-HostToPool`
  / `Remove-HostFromPool` / `Set-PoolTestSet` / `Set-PoolDesiredState` /
  `Get-PoolStatus` / `Test-PoolIntent`). Strictly additive: a no-pool host is
  byte-identical to single-host. Test-set EXECUTION, gating ACTIONS, and
  compatibility ENFORCEMENT are authored-only (the schemas) and deferred to
  Phase 4/5. (§6 Phase 3; operator guide: [pool-admin.md](pool-admin.md).)
- **Phase 4 — test-set execution + per-guest overrides.** A pooled host drives its
  cycle from its pool's assigned test-sets (`runtime/pool.manifest.json`, written
  by the outer's pool-sync; read by the fresh inner) instead of `test.runner.yml`.
  New `Test.PoolPlanner.psm1` is the per-host FILTER (each runner keeps only guests
  it can run -- folder present + capability supported + guest↔hypervisor compatible
  per `guests.compatibility.yml`, advisory-permissive; decentralized, no dispatch).
  `Test.SequencePlanner` gains `Resolve-TestSetCyclePlan` (shares one entry-builder
  with `Resolve-CyclePlan`) applying `perGuestOverrides` -- per-guest
  `keystrokeMechanism` (lifted global→per-guest via `Set-EngineKeystrokeMechanism`,
  reset between guests), `username`, `variables`. HostId-scoped VM names
  (`Get-TestVMName -HostId`) avoid shared-store collisions. `cycleStrategy: all` +
  `provisioning.betweenSets: none` are runtime-active; round-robin/single +
  snapshot-revert/reprovision are parsed+validated then run as all/none (Phase 5).
  Strictly additive: no pool / no test-set / no runnable guest → byte-identical
  single-host `test.runner.yml`. (§6 Phase 4; operator guide: [pool-admin.md](pool-admin.md).)
- **Phase 5 — pool gating (advisory), alerting, first-engage remediation.** The
  aggregator computes an advisory `degraded` flag per pool (healthy-member fraction
  below the quorum threshold, sustained for `degradedAfterMinutes`) and a
  hysteresis-latched alert (`failuresBeforeAlert` / `successesBeforeRearm` poll
  counts), exposed as new `yuruna_pool_degraded` / `_alert_active` /
  `_healthy_fraction` / `_members_*` gauges + `pool_alert_fired`/`_rearmed` Loki
  events. **Advisory only** — no host reads it to gate a cycle. Gating policy rides
  the already-polled `host.registration.json` (so the Go binary stays stdlib-only,
  no pools.yml parse); only pools that authored a `gating` block are paged. **Alert
  delivery** is a file-spool on the pool's `networkStorage` NAS
  (`networkStorage.poolNetworkPath`): the host-side notifier
  (`Test.PoolNotifier.psm1`, a self-electing bounded cycle-end hook on the host where
  the `pool.alert` transport is configured) reads the latched gauge, enqueues rising
  edges to `notifications/outgoing/`, delivers via the existing notification
  extension, and moves to `delivered/` on a ledger-confirmed send. **First-engage
  remediation:** a per-pool `config.testCycle` override-WINS merge lets a pool engage
  the dormant auto-remediation (or tighten the step timeout) fleet-wide without
  editing each host (default-off preserved; existing per-streak caps unchanged).
  Quorum-gated failure-pause break stays deferred (advisory boundary). (§6 Phase 5.)
- **Phase 6 — push telemetry + security hardening (TLS + auth).** The aggregator's
  `:9400` serves TLS from a proxy-CA-signed leaf minted in cloud-init (reusing the squid
  CA; default-off — plain HTTP when the leaf is absent), and gains a bearer-gated
  `POST /ingest` push route that SUPPLEMENTS pull (Loki dedups the overlap by event
  timestamp; pull stays discovery + backfill authority). A detached per-cycle runner
  forwarder (`Invoke-PoolPushForwarder.ps1` + `Test.PoolPush.psm1`) ships each cycle's
  NDJSON events over CA-PINNED HTTPS (compiled C# validation delegate, not a scriptblock)
  with a shared operator-supplied bearer token (vault `pool-auth-token`, never
  auto-generated, baked 0640 root:proxy via New-VM). `/ingest` is identity-bound: the
  `{pool,hostId}` Loki labels come from the request SOURCE IP matched against the
  pull-discovered view (not the body), so a shared-token holder can push only as itself;
  it mirrors the pull-side redaction + size/line caps and stays telemetry-only. The local
  Prometheus scrape (https + skip-verify on loopback) and the Phase-5 notifier (https +
  http fallback) were co-edited in lockstep. Default-off end-to-end: with no token + no
  leaf, behavior is byte-identical to Phase 5; `/metrics` + `/healthz` +
  `/api/v1/pool-status` stay open. (§6 Phase 6.)

### ⬜ Remaining

- **Retention — persistent-volume durability** — time-series tiering shipped
  (Loki 30d for `src=cycle`/`src=incident` + 7d for `src=event`; Prometheus
  30d/2GB), so the 30-vs-~2880 history gap is closed in the store. Residual:
  `/var/lib/{loki,prometheus}` sit on the VM root fs, so a VM rebuild still
  resets history — surviving rebuilds needs a persistent data volume. → §10 M.4, §9.
- **Write-side control spine (beyond intent).** The git intent STORE + pull shim
  + admin CLI shipped in Phase 3 (`New-Pool` / `Add-HostToPool` /
  `Remove-HostFromPool` / `Set-PoolTestSet` / `Set-PoolDesiredState` /
  `Get-PoolStatus` / `Test-PoolIntent` over the bare repo; `Test.PoolSync.psm1`
  PULLs + reconciles `desiredState`). Residual: any broader write-side control
  beyond polled desired-state intent. → §3, §7.
- **Horizon B (F1/F2/F4)** — pool-gated resilience, now unblocked. → §7,
  `docs/opportunities-resilience.md`.

## 1. Where we stand — the single-host layer is far more mature than the old plan assumed

The original gap analysis predates the failure-taxonomy / auto-remediation /
sequence-engine era. Refreshed against current code:

| Area | Status | Detail |
|---|---|---|
| Runner topology | **single-host CLOSED** | Outer eternal loop + fresh-pwsh inner per cycle + watchdog `Start-Job` + threadpool heartbeat + state machine + boot recovery. **Not** "exits on first failure" — a 60-min failure-pause loop with 5 breakout triggers. |
| Failure handling | **single-host CLOSED, pool OPEN** | Structured 15-class taxonomy, schema-v2 `last_failure.json` (now archived per-cycle), retry (`Invoke-WithYurunaRetry` + `retry` verb), auto-remediation (**built but dormant** — `remediation_recommended`=0 across 860 cycles, defaults off). OPEN: incident concept, pool-wide health/quorum, cross-host alerting. |
| Schemas | **per-host CLOSED, pool OPEN** | `status.json` (guests/sequences/history/lastFailure) + per-cycle NDJSON **already stamped with `(cycleId, runId, hostname, sequenceGuid, sequenceRevision)`** — multi-host-joinable today. OPEN: the three pool wrappers (pool def, test-set manifest, host registration). |
| Control plane | **CLOSED, not fanned-out** | Status server already exposes `POST /control/test-config` (validate+persist), `/control/start-cycle`, `/control/runner-status`, pause flags. OPEN: no pool-level fan-out, no test-set→pool assignment. |
| Host capability | **per-host CLOSED, instance-identity OPEN** | `Get-HostType` (3 platforms), `Get-HostCapabilityMatrix` (hostIO/ocr/vnc/screenshot/extensions/supportedGuests), `Test-CyclePlanCapability`. OPEN: no host-**instance** identity (can't tell `hv-01` from `hv-02`), no guest↔hypervisor compatibility rules file, VM names not host-scoped (collision risk on a shared store). |
| Status-page primitives | **CLOSED, aggregation OPEN** | `aggregateStatus` rank, history pills, `HostInfo` builder, visibility-aware polling. OPEN: no multi-host aggregation, no 24h timeline (history capped at 30 vs **~2880 points/24h** — the retention gap is real and unchanged), no drill-down nav. |
| Dev-investigation UX | **PARTIAL** | Full drill-down DATA exists single-host (history → cycleFolderUrl → artifacts → schema-v2 repro), served over HTTP. "Error messages are single strings" is **CLOSED**. OPEN: cross-host aggregation, central failure sink/dedup, diff-against-last-good, targeted re-run. |

**Takeaway:** the genuine remaining gaps are *all multi-host* (pool/test-set/host
schemas, aggregation, incident concept, 24h retention, host-instance identity,
guest↔hypervisor compatibility). The per-host foundation is solid and largely
reusable.

## 2. The pull spine already exists

Three facts about the built model drive the architecture decision:

1. **Code is already distributed by pull.** Guests fetch framework via
   `fetch-and-execute.sh` from the host status server's `/yuruna-repo/`
   working-tree route (deny-list protected) with GitHub-raw fallback; the
   caching proxy fronts package/image pulls; runners `git pull` each cycle and
   re-import modules.
2. **Each runner is already autonomous.** The outer loop self-drives; the
   failure-pause loop wakes itself on framework/project commit, local config
   mtime, or a `/control/start-cycle` flag. No external scheduler tells it to run.
3. **Per-host state is already atomic + crash-safe.** `Write-YurunaStateFile`
   (temp+rename); boot recovery synthesizes crash transitions from stale
   `.incomplete` / `runner.pid`.

## 3. Architecture decision — thin-aggregator hybrid (DECIDED 2026-06-09)

> **Decided: decentralized self-driving runners + a THIN coordinator that is an
> aggregator and intent store, NOT a command-dispatch master.** The aggregator +
> stores are hosted on the Yuruna-Caching-Proxy machine (see Decisions locked).

A central command-master would fight all three facts above and add a single
point of failure the current design deliberately avoids. Instead:

- **Runners stay decentralized** and authoritative for their own lifecycle.
- They **PULL pool intent** (pool membership, assigned test-sets, per-pool
  config, desired-state/pause) from a shared store — **git is the natural fit**
  (it is already the pull spine; the caching proxy + status server `/yuruna-repo`
  is the LAN distribution edge).
- They **PUSH/expose telemetry** (status.json snapshot + NDJSON tail + heartbeat
  + capability declaration) to a **thin aggregator** that owns *only the
  read-side*: the 24h pool view, incident correlation, and alert gating.
- **Control = intent, not RPC.** Pause/start-cycle/drain are expressed as
  desired-state the runner polls and reconciles (exactly like today's
  `control.cycle-restart` flag), not imperative commands.

**Graceful failure mode:** if the aggregator is down you lose the pool *view*
and pool-level alerting — but every runner keeps testing and self-healing.

## 4. Schemas (sketches)

- **Pool definition** (`pools.yml` in the pulled store): `poolId`, `displayName`,
  `members:[hostId]`, `testSets:[{name, order, cycleStrategy:
  separate-cycle|shared-vm-lifecycle}]`, `config:{…per-pool overrides of
  testCycle.* knobs}`, `gating:{failuresBeforeAlert, successesBeforeRearm,
  quorum:{healthyThreshold, degradedAfterMinutes}}`, `desiredState:
  run|paused|drain` (the pulled intent flag, mirroring `control.cycle-restart`).
  Reuses `Test.ConfigSync` template-overlay so per-pool config merges over global
  defaults.
- **Test-set manifest** (`test-sets/<name>.yml` in the **project** repo):
  `name`, `sequences:[<top-level name>]` (same shape `Resolve-CyclePlan` already
  consumes), `requiredGuests:[guestKey]`, `perGuestOverrides:{<guestKey>:
  {keystrokeMechanism, username, variables}}` — **lifts `keystrokeMechanism`
  from global-per-cycle to per-guest** (the survey's #1 single-host assumption),
  `provisioning:{betweenSets: reprovision|reuse}`.
- **Host registration record** (pushed by each runner / written to
  `hosts/<hostId>.json`): `hostId` (stable, distinct from hostname — survives
  rename), `hostname`, `hostType`, `hypervisor`, `poolId`, `capabilities`
  (= `Get-HostCapabilityMatrix` + `supportedGuests` from `Test-GuestFolder`),
  `conditionState:{elevationAvailable, displayReady, kvmLoaded}`, `runner:{pid,
  runId, state, heartbeatUtc, stepHeartbeatUtc}`, `capabilityVersion/timestamp`,
  `ipAddresses`, `cachingProxyUrl`. **Reserve `capacity`/`ipPool`/`disk` fields
  now** (even unused) so Horizon B (§7) is a data-population exercise, not a
  re-architecture.
- **Pool status wrapper** (aggregator read-side): `poolId`,
  `aggregatedOverallStatus` (rolled via the existing `aggregateStatus` rank),
  `poolHosts:[<per-host status.json> + hostId]`, `timeline:[{bucketUtc, hostId,
  cycleId, overallStatus, failCount}]` (24h sliding window for the heatmap),
  `incidents:[{incidentId, startedUtc, resolvedUtc, affectedHostIds,
  failureClassHistogram, severity}]`.

## 5. Components (new, reconciled against what to reuse)

> **Locked-decision reframe (decided 2026-06-09: reuse).** The aggregator runs
> on the caching-proxy machine and reuses its existing Loki/Prometheus/Grafana
> stack, which collapses several "new service" components into **reuse**: the
> **telemetry store = Loki** (NDJSON events) **+ Prometheus** (numeric pool
> metrics); the **24h pool dashboard = Grafana** dashboards (heatmap/timeline/
> incident strip) with **drill-down deep-linking back to each host's existing
> status server** for artifacts (keeps the byte-heavy screenshots on the host —
> see Risks); the **pool-aggregator / incident-correlator** shrinks to a **thin
> service** (Go systemd unit, per the `caching-proxy-parser` precedent, or even
> just Grafana/LogQL queries) doing only cross-host join + incident bucketing
> that Loki/Grafana can't express. The bullets below describe the *logic* needed;
> map each to "Loki/Prometheus/Grafana + thin glue". The PULL-based MVP is
> unchanged in intent — Promtail/Loki already embody "pull + ship".

- **pool-aggregator** (new HTTP service, modeled on `Start-StatusService.ps1`'s
  HttpListener + dispatch + **deny-list** pattern): ingests pushed/pulled
  telemetry, joins on `(runId, cycleId, hostId)`, maintains the 24h timeline +
  incident correlation, serves the pool API. Reuses `Test.Status` doc model,
  `Test.EventSchema` validator, `aggregateStatus` rank.
- **runner pool-sync shim** (`Test.PoolSync.psm1`): folds into the outer loop —
  PULLs pool intent (one more source alongside the existing config-mtime /
  control-flag polling) and PUSHes the host registration record on the existing
  threadpool heartbeat. **No new process.**
- **telemetry forwarder** — leanest first cut is **pull-based**: the aggregator
  polls each host's *already-serving* `status.json` + NDJSON endpoints (**zero
  new runner code for MVP**). Push is a later volume optimization.
- **pool-planner** (`Test.PoolPlanner.psm1`): given a test-set + guest, select a
  host where the guest folder is present + required HostIO/OCR available +
  guest↔hypervisor compatible. Reuses `Test-CyclePlanCapability`; adds
  `guests.compatibility.yml` + **HostId-scoped VM naming** (collision safety).
- **test-set resolver** (extend `Test.SequencePlanner.psm1`): iterate test-set
  manifests instead of the single `test.runner.yml sequences[]`; apply
  `perGuestOverrides`.
- **pool dashboard** (extend `status/index.html` + `yuruna.common.js`): 24h
  heatmap/Gantt + incident strip + drill-down, repointing `HostInfo` to the
  aggregator.
- **pool admin CLI**: `New-Pool.ps1`, `Set-PoolTestSet.ps1`, `Add-HostToPool.ps1`,
  `Remove-HostFromPool.ps1` (drain = set `desiredState:drain`, wait for the
  runner to finish + release its pidfile), `Get-PoolStatus.ps1`. These edit the
  pulled store (git/shared file), **not a live master**.
- **incident correlator** (inside aggregator): groups
  `step_failure`/`ssh_handshake_failed`/crash events within a window across hosts
  into incidents; gates pool-level notifications. Reuses the 15-class taxonomy +
  a pool-scoped fork of `Test.Notify`.

## 6. Phased roadmap

- **Phase 0 — prereqs (additive, no behavior change):** stable `hostId` distinct
  from hostname (seed from `runtime/host.uuid`), stamped onto NDJSON + status.json
  alongside `hostname`; externalize `Get-HostCapabilityMatrix` as a host
  registration record written to `runtime/` and served by the existing status
  server.
- **Phase 1 — MVP SLICE (read-only pool visibility), on the caching-proxy
  machine:** ship each host's NDJSON/status telemetry to the proxy machine's
  store and surface a 24h heatmap + drill-down — Promtail/pull → **Loki**, a
  **Grafana** pool dashboard, and drill-down deep-links back to each host's
  existing status server — minimal new code on
  both the runner (only Phase 0) and the aggregator. **No runner changes beyond
  Phase 0.** Delivers the headline aggregated-24h-pool-health view and validates
  the join keys on real data. ⟵ **MVP**
- **Phase 2 — retention + incident concept:** fix the 30-vs-~2880 retention
  mismatch in the aggregator store (24h timeline central; per-host rotation
  unchanged); add incident correlation (N-failures-in-M-minutes).
- **Phase 3 — schemas + intent store + admin CLI:** `pools.yml`, test-set
  manifests, `guests.compatibility.yml`; the admin CLI; the runner pool-sync
  shim that PULLs intent. Decentralized control plane, no master.
- **Phase 4 — test-set execution + per-guest overrides:** iterate test-set
  manifests; honor `perGuestOverrides` (per-guest `keystrokeMechanism`);
  implement `cycleStrategy` + `provisioning.betweenSets`; pool-planner host
  selection with HostId-aware VM naming + compatibility enforcement.
- **Phase 5 — pool gating (advisory), alerting, first-engage remediation:** ✅ shipped.
  Aggregator-computed advisory `degraded` flag + hysteresis-latched alert from the
  pool's `gating` quorum (carried via `host.registration.json`); file-spool alert
  delivery on the pool's `networkStorage` NAS (`networkStorage.poolNetworkPath`)
  through the existing notification extension
  (self-electing host-side notifier); per-pool `config.testCycle` override-WINS merge
  that engages the dormant auto-remediation fleet-wide. Quorum-gated failure-pause
  break stays **deferred** (advisory boundary — no host reads `degraded` to gate a
  cycle). See the ✅ Done ledger above for the component breakdown.
- **Phase 6 — push telemetry + security hardening (TLS + auth):** ✅ shipped.
  Proxy-CA-leaf TLS on `:9400` (default-off), a bearer-gated identity-bound `POST /ingest`
  push route that SUPPLEMENTS pull, a CA-pinned detached runner forwarder, and the
  lockstep Prometheus + notifier TLS co-edits. Default-off end-to-end (byte-identical to
  Phase 5 until a token + leaf exist). See the ✅ Done ledger above for the breakdown.

## 7. This unlocks Horizon B (forward-resilience F1/F2/F4)

The deferred [resilience](opportunities-resilience.md) items — **F1**
IP/capacity admission gate, **F2** caching-proxy circuit breaker, **F4**
disk-headroom gate — address failure classes the 860-cycle single-host corpus
shows at **~zero** occurrences (DHCP/IP 0, proxy-5xx 0, disk 0). Their premise is
a multi-host pool, and this design creates the shared resources they govern:

- **F1**: N runners on a shared subnet/DHCP scope or shared hypervisor RAM make
  IP-pool + capacity a shared resource — the **pool-planner's host selection** is
  the natural admission-gate hook (using the reserved `capacity`/`ipPool` fields).
- **F2**: many runners pulling through the **same caching proxy** turn transient
  5xx into shared saturation — the aggregator's cross-host network-timeout
  histogram is the breaker signal (a pool-scoped decision F2 couldn't make alone).
- **F4**: shared-storage pools make disk-headroom a pool resource fed by the host
  registration `conditionState` + disk metric.

Building the host registration record + pool-planner with those fields reserved
makes F1/F2/F4 a later data-population step, not a re-architecture.

## 8. Decisions

**Resolved (2026-06-09)** — see *Decisions locked* for the canonical list:
- ✅ Coordinator = **thin-aggregator hybrid**.
- ✅ Store = **split** (git intent + DB/file telemetry), both on the proxy machine.
- ✅ Telemetry + dashboard = **reuse Loki + Prometheus + Grafana** (artifact
  drill-down deep-links to each host's status server).
- ✅ Intent git = **bare repo on the proxy machine, LAN clone+pull**.
- ✅ Auth/TLS = **trusted-LAN posture**; Phase 6 added default-off proxy-CA-leaf TLS on `:9400` + a bearer-gated `/ingest`.
- ✅ Test-set config UX = **YAML-in-git via the admin CLI**.

**Remaining (tuning, not blocking the MVP):**
1. **Cycle-strategy default** — separate-cycle-per-test-set (more isolation,
   slower) vs shared-VM-lifecycle (faster, state carries over). Per-set override
   exists either way; only the *default* is needed, and only at Phase 4
   (test-set execution).
2. **Retention specifics** — now a Loki/Prometheus retention config (24h hot +
   downsampled history vs a per-pool quota with full fidelity reserved for
   recent/failed cycles). Settle at Phase 2. Per-host rotation (1000/30) stays
   underneath.

## 9. Risks

> The locked design already **adopts** two of the biggest mitigations below:
> artifacts stay on the generating host with the dashboard deep-linking to its
> status server (so only status.json + NDJSON + manifests cross the network), and
> retention/downsampling is delegated to Loki/Prometheus rather than a single
> ever-growing status doc. The residual risks remain noted for the build.

- **Clock + identity** — `cycleId` is an ISO-UTC timestamp; host clock skew can
  misorder the 24h timeline + corrupt incident windows. The aggregator must order
  by **ingest-time receive clock**, not the emitted `cycleId`. `hostId` must be
  stable across hostname changes (today only `hostname` is stamped).
- **Partial-pool health / quorum** — the hardest item. "Pool degraded" /
  quorum-gated failure-pause break implies cross-host consensus, which the atomic
  single-instance model deliberately avoids. **Start with an aggregator-computed
  advisory `degraded` flag; defer any consensus-gated control. Not in the MVP.**
- **Log + artifact shipping volume** — screenshots/OCR rings are large and
  deliberately un-hashed; × N hosts, naive central shipping is a
  bandwidth/storage problem (the UTM host's ~1 MB/s LAN egress would choke).
  **Keep artifacts on the generating host (already served over HTTP); ship only
  status.json + NDJSON + manifests; deep-link the dashboard back to each host.**
  This is also why pull-collection is the right MVP.
- **Security** — the existing `/yuruna-repo` deny-list (vault.yml, transports.yml,
  ssh keys, password files, caching-proxy config, `.git`, test.config.yml) must be
  replicated **exactly** on the aggregator and any new route; one missed pattern
  leaks secrets pool-wide. SSH-key distribution to pool nodes is an unsolved
  provisioning question. Per `feedback_no_unauthorized_security_changes`, do not
  alter any security posture (deny-list, key handling) while building this without
  explicit authorization.
- **Status retention scale** — ~2880 points/host/24h × N hosts ≫ the current
  30-deep history; a naive single status.json becomes multi-MB and the 2s-polling
  dashboard would re-fetch it (UI DoS). The 24h view must be a downsampled
  read-model; full fidelity only for recent + failed cycles.
- **Capability staleness** — a runner that crashes or git-pulls mid-cycle can
  advertise stale capabilities; the planner must treat advertisements older than
  N minutes as untrusted and re-probe (and survive the `-Force` re-import /
  `$script:` reset traps).
- **Built-but-dormant remediation** — auto-remediation fired 0× in 860 cycles;
  its first pool deployment (Phase 5) is an unproven code path — gate behind the
  per-pool `autoRemediationEnabled` flag with conservative caps.

## 10. Phase 0 + MVP implementation plan (for review, before any code)

Concrete first-build plan for the two phases that deliver the headline value.
Everything here honors the locked decisions; nothing else is built yet.

### Phase 0 — host identity + capability record (runner-side, additive, zero behavior change)

| # | Task | Touch point | Notes |
|---|---|---|---|
| P0.1 | **Stable `hostId`** | runner startup (`Invoke-TestRunner` / `Initialize-RunnerState`) + `Test.YurunaDir` | Ensure `$env:YURUNA_RUNTIME_DIR/host.uuid` exists (generate a GUID once, persist), load into `$global:__YurunaHostId`. `runtime/` persists across cycles (holds status.json/pids; the pre-spawn wipe clears only inner.pid/stepHeartbeat/last_failure.json), so the UUID survives — distinct from `hostname`, survives a rename. |
| P0.2 | **Stamp `hostId` on NDJSON** | `Write-CycleNdjsonEvent` (`Test.Log.psm1:~693`) | Add a `hostId` auto-stamp block **mirroring the existing `runId` block** (`if (-not $EventRecord.Contains('hostId') -and $global:__YurunaHostId) {…}`). One-for-one with the proven pattern. |
| P0.3 | **Stamp `hostId` + `hostType` on status.json** | `Test.Status` init | Alongside the existing `hostname`, so the pull-collector joins per-host docs on `hostId`. |
| P0.4 | **Host registration record** | new writer on the existing heartbeat; served by the status server | Write `runtime/host.registration.json` = `Get-HostCapabilityMatrix` + `hostId`/`hostType`/`hypervisor`/`supportedGuests`/`conditionState` + live runner state + `capabilityVersion`/timestamp. Already served at `/runtime/host.registration.json` (runtime/ is served); confirm the deny-list does not block it (it carries no secrets). |

**Acceptance:** NDJSON + status.json carry `hostId`; `GET
/runtime/host.registration.json` returns the capability record; cycles behave
identically. Unit tests: the `hostId` stamp (mirror the existing NDJSON tests)
and the registration-record builder. Phase 0 is independently shippable and even
improves single-host identity hygiene.

### MVP (Phase 1) — read-only pool view, all on the caching-proxy machine

A thin **pull-collector** polls each pool host's *already-served* endpoints and
ships to Loki; Grafana renders the 24h view; drill-down deep-links back to each
host. **No per-host install, no runner changes beyond Phase 0.**

| # | Task | Where | Notes |
|---|---|---|---|
| M.1 | **Auto-discovery (no host list)** | the collector reads the squid access log on the proxy machine | The proxy already sees every host that pulls through it. Discover candidate client IPs from `/var/log/squid/yuruna_access.log` (recent tail, ~one DHCP lease), probe each `:8080/runtime/status.json`, keep responders, and **identify on the stable `hostId`** (Phase 0). DHCP-resilient: changing/reused IPs and a host across many short-lease IPs all collapse to one `hostId`; **no DNS dependency**, no hand-maintained list. (`pools.yml` membership + per-pool grouping is Phase 3, layered on top of discovery — it labels/assigns discovered `hostId`s, it does not list IPs.) |
| M.2 | **Pull-collector service** | proxy machine, per the `caching-proxy-parser` Go-service precedent | On a timer, per host: GET `/runtime/host.registration.json` + `/runtime/status.json` + the latest `/log/<cycle>/cycle.events.ndjson` tail; **push** the NDJSON to **Loki** (push API) with labels `{pool, hostId, cycleId}`; derive a few **Prometheus** counters (pass/fail/running, cycle duration). **Order by ingest-receive clock**, not the emitted `cycleId` (clock-skew risk §9). |
| M.3 | **Grafana `yuruna-pool` dashboard** | alongside the existing `yuruna-squid` dashboard provisioning on the proxy machine | 24h heatmap/timeline (host × time, colored by `overallStatus`), per-host status table, drill-down panels whose links **deep-link** to `http://<host>:<port>/…` (the host's existing status UI + cycle-folder artifacts). Incident strip arrives in Phase 2. |
| M.4 | **Retention** | Loki/Prometheus config on the proxy machine | 24h hot + downsampled history (settles the §8 retention item). Per-host rotation (1000/30) unchanged underneath. |

**Acceptance:** with ≥2 hosts running, the Grafana `yuruna-pool` dashboard shows
a 24h cross-host heatmap; clicking a failed cell deep-links to that host's cycle
artifacts. Kill the collector → every runner keeps testing (graceful-degradation
check). Validates the `(hostId, runId, cycleId)` join keys on real data.

### Small implementation choices (for the plan review)

- **Collector language:** **Go** (recommended) — matches the existing
  `caching-proxy-parser` service, ships as one static binary, no pwsh dependency
  on the proxy VM. (Alternative: PowerShell, matching the rest of the harness.)
- **Ship mechanism:** central **pull** (the collector reads each host's already
  served NDJSON/status over HTTP, pushes to Loki). Chosen over per-host Promtail
  because it needs **no install on the runner hosts** — the MVP's whole point.
- **Sequencing:** Phase 0 → MVP. Deferred to later phases: `pools.yml` /
  test-set manifests / admin CLI (P3), test-set execution + per-guest
  `keystrokeMechanism` (P4), incident correlation (P2), pool gating/alerting +
  first auto-remediation under fan-out (P5), TLS/auth + push telemetry (P6).

### Phase 1 implementation status (built, static-verified, pending live validation)

The MVP is implemented under **`test/extension/pool-aggregator/`** (mirroring
the `caching-proxy-parser` extension):

- **Collector** (`main.go`, stdlib-only, cross-platform): **auto-discovers** pool
  members — reads recent client IPs from the squid access log, probes each
  `:8080/runtime/status.json`, and keys everything on the stable **`hostId`**
  (DHCP-resilient: changing/reused IPs and a host across many short-lease IPs all
  collapse to one member; no DNS). Idle hosts stay live via a last-known-IP
  re-probe within `hostTTL` (24h). On a transition it pushes to Loki
  (`{pool,hostId,cycleId}`, ingest-clock-stamped, line carries the current
  `baseUrl` for drill-down), bumps Prometheus
  `yuruna_pool_cycles_{pass,fail}_total{pool,hostId}`, and serves `/healthz`,
  `/metrics`, `/api/v1/pool-status` on `:9400`. Bounded concurrent probes,
  ~25h seen-eviction, graceful SIGTERM. `gofmt`/`go vet`/Linux+host build clean.
- **`pool-aggregator.service`** (`User=proxy`, hardened,
  `ReadOnlyPaths=/var/log/squid`), `default.psm1` (`Get-PoolAggregatorManifest`),
  `config.yml`/`contract.yml`, `go.mod`, `grafana-pool-dashboard.json` (uid
  `yuruna-pool`: summary tiles + a per-host **table** with deep-links + a
  host×time **state-timeline** + a collapsed Loki transitions log). The collector
  exposes per-host `yuruna_pool_host_info` / `_host_status` / `_host_last_seen_seconds`
  series to drive the table/timeline. **No static host-list file.**
- **Deploy** (`caching-proxy.base.user-data`, YAML-validated): a Prometheus
  `pool-aggregator` scrape job; the **dashboard ships inline** via `write_files`
  into Grafana's provisioning dir (so it is present from first boot, independent
  of the build); and a runcmd block that fetches + `go build`s the **collector
  binary** + parser + `systemctl enable --now pool-aggregator`. The fetch reads
  the source from the **LOCAL host working tree** (`/yuruna-repo/` served by the
  deploying host's status server) — same base-URL resolution as
  `fetch-and-execute.sh` (host IP+port baked into the seed via `/etc/yuruna/
  host.env`, probe `/livecheck`, else github fallback) — so the build **never
  depends on the public mirror**: the host serves whatever is checked out.
  `Start-CachingProxy.ps1` brings the status server up before creating the VM.
  Each source file is validated non-empty with a loud diagnostic on failure. A
  build failure leaves the dashboard in place (it just shows "No data" until the
  collector is up).

**MVP first cut vs §M:** the dashboard ships summary tiles + a per-host table
(deep-links to each host's status page/cycle folder) + a host×time state-timeline
+ a collapsed Loki transitions log (M.3 satisfied via a state-timeline rather
than a heatmap — discrete pass/fail/running states render better as bands than a
density heatmap). The collector now **tails each host's per-cycle
`cycle.events.ndjson` into Loki** (`{pool,hostId,src=event}`, event-timestamped
so a restart re-ships idempotently) and the drill-down row surfaces recent
**step failures** + the full **cycle event stream** + status transitions — the
which-step-failed view (the incident-drill-down half of Phase 2). Still open:
automated incident correlation (N-failures-in-M-minutes) and persistent-volume
durability (M.4 + the Phase-2 retention item); time-series retention is now
tiered (Loki 30d for transitions/incidents + 7d for per-step events, Prometheus
30d/2GB), with VM-rebuild durability the residual. **Live validation** (the only part not
statically checkable): with the host status service up (`Start-CachingProxy.ps1`
starts it; no public mirror needed — the collector builds from the local working
tree), boot the caching-proxy VM, run a cycle or two so hosts pull through the
proxy, then
confirm `:9400/healthz`, `:9400/api/v1/pool-status` lists the discovered hosts,
the Prometheus `pool-aggregator` target UP, Loki `{pool}` streams, the
**Yuruna Pool** Grafana dashboard across ≥2 hosts, and that
killing the collector leaves runners testing.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.26

Back to [Yuruna](../README.md)
