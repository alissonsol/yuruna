# Forward resilience — scoping (#7)

**Forward resilience = proactive failure *avoidance*, the complement to the
mature reactive layer.** The harness already classifies, remediates, and
self-heals *after* a failure. #7 asks the prior question: can we keep a cycle
(or a step) from entering a known-bad state in the first place, so the
reactive machinery fires less often and a fragile run degrades instead of
burning a whole cycle into a timeout?

This is a **scoping** document: a grounded gap analysis and a tiered menu of
candidate mechanisms, so the scope of #7 can be chosen deliberately. It does
not commit to building any specific item until the scope is picked.

## 1. Where we stand

The **reactive** layer is comprehensive and not the gap:

- 15-class failure taxonomy with severity + inner-cause routing
  (`Test.FailureTaxonomy`, `Test.SequenceFailureState`).
- Remediation dispatcher with a handler per class
  (`Test.Remediation` — `retry_with_backoff`, `restart_from_snapshot`,
  `operator_intervention_required`, …).
- Two-tier watchdog (process `runner.heartbeat` + runspace
  `runner.stepHeartbeat`) with watchdog-kill synthesis.
- Capture-feed self-heal (frame-hash freeze detection +
  `Restart-VMConsole`, capped).
- A 60-min failure-pause loop with commit-polling break-outs.

The **proactive** layer covers the *critical path* but is thin on the largest
failure classes:

- Pre-cycle config gate (`test/Test-Config.ps1`): config/schema, host-type +
  feature state, connectivity probes, ASCII/no-BOM, vault cross-refs — and a
  **capacity check that only *warns*** (RAM ≥16 GiB, CPU ≥4 cores).
- Per-cycle hygiene (`Test.RunnerOuterLoop`): stale-state sweep, PID/heartbeat
  wipe, hot-reload of timeout + auto-remediation config.
- Guest-readiness gates (`Wait-SshReady`, `Wait-VMIp`, `Wait-ForText`).
- Caching-proxy availability probe; image-checksum verification; DPI warning.

### The gap, by failure class

| Failure class / mode | Today's posture |
|---|---|
| IP / DHCP-pool exhaustion | **Reacted-to only** — a no-IP guest burns the cycle into a KVP/IP timeout; capacity check warns on total RAM/CPU, never on IP/pool headroom |
| Transient proxy 5xx saturation | **Reacted-to only** — `network_timeout` → `retry_with_backoff` *into* the saturated proxy; no shed / fail-fast / fallback decision |
| Host disk exhaustion (VHDX growth, snapshot chains) | **Reacted-to only** — surfaces as `host_io_blocked` mid-step |
| Snapshot missing / corrupt | **Reacted-to only** — `snapshot_restore_failed` at restore time → operator |
| Credential / vault drift | **Reacted-to only** — `credential_expired` at the auth step → operator |
| OCR degradation (DPI / frozen feed) | **Partially prevented** — DPI warning + crop + frame-hash self-heal; foundational fragility remains |
| KVP IP lateness (External vSwitch) | **Mitigated** — ARP pre-probe, but cannot beat daemon startup lag |

**The single biggest gap: no admission control, circuit-breaking, or
backpressure.** The outer loop retries (bounded by the 60-min cap +
commit-poll escapes) but never *sheds* or *degrades* when the host, network,
or proxy is saturated.

## 1b. Empirical grounding (860-cycle corpus)

The a-priori ranking above was checked against the actual run history:
**860 per-cycle event streams, 2026-05-21 → 2026-06-08, single host
(ALIUS-ALIEN01).** The result re-ranks the menu sharply.

> **Counting trap:** the `failureClass` field rides on **`step_end`** events
> (45,377 of them — a step's *classification metadata*, what it *would* map to
> if it failed), not on failures. Naively tallying the field reports
> "credential_expired 12,514 / host_io_blocked 8,860" — pure noise. Genuine
> failures are the `step_failure` / `ssh_handshake_failed` / crash events.

**Actual failures: 53 events, ~1 failed cycle per ~16** (37 `step_failure`
across 30 cycles + 16 ssh-handshake). Real ranking:

| Rank | Class | n | Read |
|---|---|---|---|
| 1 | `pattern_matched_failure` | 23 | Harness **correctly** catching a guest/script failure (incl. the `NONZERO SCRIPT EXIT:` gate). Not a harness-resilience gap — a guest panic can't be "prevented" — *except* the OCR command-echo false-match sub-case (`feedback_ocr_failure_pattern_command_echo_false_match`) |
| 2 | `network_timeout` (= ssh_handshake_failed) | 16 | **SSH readiness gate** timing out — the one genuinely addressable recurring class |
| 3 | `ocr_timeout` | 4 | Capture/OCR fragility |
| 3 | `unknown` | 4 | Unclassified |
| 5 | `engine_crash` | 3 | Harness self-crash |
| 6 | `retry_exhausted` | 2 | |
| 7 | `credential_expired` | 1 | |
| — | DHCP/IP-pool, proxy-5xx, disk `host_io_blocked`, `snapshot_restore_failed` | **0** | Zero actual failures |

Plus **interruptions**: 9 abort-recovery markers (all `recoverySignal=marker_file`)
+ 1 leftover `.incomplete` + the 3 engine crashes — caught reactively by the
boot-recovery sweep.

**Two structural caveats that reshape the recommendation:**

1. **Single-host corpus.** Multi-host failure modes (IP-pool exhaustion,
   cross-host capacity, proxy saturation under fan-out) are *structurally
   absent* — the premise of F1/F2/F4 is the planned multi-host **pool
   harness** (`project_pool_test_harness`), **not today's topology**. Their
   empirical current-pain is ~0.
2. **Auto-remediation is dormant.** `remediation_recommended` = **0** across
   860 cycles (`autoRemediationEnabled` defaults off). The mature reactive
   dispatcher is *built but not engaged*; the real reactive mechanism in use is
   the 60-min pause + commit-poll + manual operator fix.

**Net:** my a-priori Tier 1 (F1 IP-gate, F2 proxy-breaker) and F4/F5/F9
address **near-zero current failures**. The actual recurring pain is **OCR /
capture reliability and SSH readiness** — F6, F8, and a new SSH item (F10).

## 2. The unifying idea

A small **pre-flight decision layer** that runs before a cycle (and before a
risky step) and answers **go / degrade / shed / pause** from current host +
dependency health. Three primitives, each attaching to hooks that already
exist:

1. **Admission control** — don't *start* work the host can't finish
   (IP headroom, free RAM vs per-VM reservation, free disk).
2. **Circuit breakers** — stop hammering a saturated dependency; fail-fast or
   fall back instead of retrying into it.
3. **Graceful degradation** — when the primary mechanism is unreliable, switch
   to a *declared* alternative and **log the degradation** (so a degraded pass
   is visible, not silent).

## 3. Candidate menu

Effort: **S** ≈ hours · **M** ≈ a day · **L** ≈ multi-day.
Each candidate names the failure class it pre-empts and the existing hook it
attaches to (so none of this is greenfield).

### Tier 1 — highest leverage, bounded effort (recommended scope)

- **F1 · IP / capacity admission gate** — *prevents IP/DHCP-pool exhaustion +
  RAM oversubscription.* Before `New-VM`/`Start-VM` (infra stage in
  `Test.RunnerInnerRunner`), check IP-pool / lease headroom and free RAM
  against the per-VM reservation; if short, **pause-and-retry** (reuse the
  existing failure-pause loop) instead of spawning a guest that will never get
  an address. Promotes the `Test-Config` capacity *warning* into an
  enforceable per-cycle gate. **Effort M · Value High.**
- **F2 · Caching-proxy circuit breaker** — *prevents transient-5xx retry
  storms.* Track squid 5xx rate at the `Test-CachingProxyAvailable` /
  `Invoke-WithYurunaRetry` boundary; when the breaker trips, **fail-fast to
  the existing direct-internet fallback** (or pause) rather than retrying into
  a saturated proxy and exhausting the backoff budget. **Effort M · Value
  High.**
- **F3 · Graceful-degradation contract** — *makes degraded passes first-class.*
  A tiny shared helper that records a `degradation` event (dependency, primary,
  fallback-taken, reason) so today's ad-hoc fallbacks (proxy→direct, etc.)
  become a uniform, observable pattern instead of silent log lines. The
  substrate F2/F8 plug into. **Effort S · Value Med.**

### Tier 2 — solid, medium effort

- **F4 · Disk-headroom gate** — *prevents `host_io_blocked` from a full disk.*
  Before VM-create / `saveDiskSnapshot`, check free disk vs projected growth
  (image size + snapshot-chain delta); pause if short. **Effort S–M · Value
  Med-High.**
- **F5 · Snapshot integrity pre-check** — *moves `snapshot_restore_failed`
  earlier.* Verify a snapshot exists and is consistent at *save* time and at
  *pre-cycle* time, not first at restore. Extends the existing
  `Test-VMDiskSnapshot` probe. **Effort M · Value Med.**
- **F6 · Degradation-trend early action** — *acts before the hard OCR
  failure.* The frame-repair / no-text-poll counters already exist in
  `Wait-ForText`; when they trend up, **restart the console / widen the step
  timeout proactively** rather than waiting for the freeze threshold. **Effort
  M · Value Med.**
- **F10 · SSH-readiness hardening** — *targets the empirical #2 class
  (`ssh_handshake_failed` → `network_timeout`, 16 occurrences).* `Wait-SshReady`
  already gates on a real handshake; harden it against the half-up-sshd /
  mid-reboot races (`feedback_save_diag_post_reboot`,
  `feedback_get_guestaddress_no_polling`): longer/adaptive handshake budget,
  KVP-poll wrap, and a single re-key/reconnect before declaring failure.
  **Effort S–M · Value High (data-backed).**

### Tier 3 — larger or lower-immediacy

- **F7 · Predictive per-step timeout & pre-restore** — read recent
  `last_failure.json` history; for steps with recent transient failures,
  pre-emptively widen the timeout or pre-restore a known-good snapshot. **Effort
  M–L · Value Med.**
- **F8 · OCR → SSH-marker fallback for readiness gates** — where a step's
  readiness can be proven over SSH, prefer an SSH-side marker when the capture
  feed is unreliable, reducing dependence on the most fragile subsystem.
  **Effort M–L · Value Med-High.**
- **F9 · Vault / credential drift pre-check** — *read-only* verify that the
  credential a guest is provisioned with matches what the sequence will
  authenticate with, before the auth step. **Security-posture caution:**
  read-only verification only — **no** changes to password alphabets, lengths,
  hashing, or vault layout (see `feedback_no_unauthorized_security_changes`).
  **Effort M · Value Med.**

## 4. Recommendation (data-driven, supersedes the a-priori tiers)

The 860-cycle history splits the menu by **horizon**. The fork is the operator's
to pick: does #7 buy down *today's* failures or build *tomorrow's* topology?

### Horizon A — current single-host reliability *(what actually fails)*

Targets the real top classes (SSH readiness 16, OCR/capture 4 + the
pattern-match false-match sub-case). Highest current-pain leverage:

- **F10 · SSH-readiness hardening** — the empirical #2 class; small, data-backed.
- **F8 · OCR → SSH-marker fallback** — cuts dependence on the most fragile
  subsystem and neutralizes the OCR command-echo false-match.
- **F6 · OCR degradation-trend early action** — pre-empt the OCR timeout.
- **F3 · degradation/observability contract** — cheap substrate; it also lets us
  *measure* real-vs-false `pattern_matched_failure` (the one corpus blind spot,
  since `last_failure.json` isn't archived per-cycle), confirming F8's payoff.

### Horizon B — pool-readiness *(ahead of the multi-host pool harness)*

- **F1 · IP/capacity admission gate**, **F2 · proxy circuit breaker**,
  **F4 · disk-headroom gate.** Real value, but their failure modes are
  *structurally absent* on one host — they pay off only once
  `project_pool_test_harness` lands. **Gate this horizon on that work**, not on
  current pain.

### Park (data does not justify now)

- **F9 · vault drift** (1 failure + security-posture caution),
  **F5 · snapshot pre-check** (0 actual), **F7 · predictive timeout** (needs a
  richer archived failure history first — i.e. archive `last_failure.json`
  per-cycle, a prerequisite worth doing regardless).

**My pick: Horizon A (F10 + F8 + F6 on the F3 substrate).** It attacks the
classes that actually fail, every item attaches to existing hooks
(`Wait-SshReady`, `Wait-ForText`), and all are statically testable — matching
the implement-then-runtime-validate workflow. Defer Horizon B to the pool
harness; park the rest.

> **One no-regrets prerequisite, independent of the horizon chosen:** archive
> `last_failure.json` into each cycle folder (today only the flattened
> `step_failure` event survives, so matched-pattern / label / OCR-tail detail is
> lost to history). It is the measurement substrate F3/F7 and any future tuning
> depend on, and it is cheap.

## 5. Non-goals

- **Not** rebuilding the reactive layer — it is mature; #7 is strictly the
  proactive complement.
- **No** detection-evasion or any security-posture change (F9 is read-only).
- **Not** per-cycle snapshot serving — that is a separate robustness item,
  deferred under #1 (the rename-race is already mitigated).

## 6. Implementation status (Horizon A)

- **F10 · SSH-readiness hardening — implemented, static-verified, pending live
  validation.** `Wait-SshReady` now tracks whether host-side discovery ever
  returned a real IP and, on failure, classifies the cause via the pure
  `Get-SshReadinessFailureCause` helper — separating the recoverable
  `ip_not_discovered` (KVP/DHCP/utmctl lateness) class from genuine
  `auth_denied` / `connection_refused` / `host_key_changed` / `probe_timeout` /
  `network_unreachable` faults. "Reached-sshd" evidence outranks the
  IP-discovery signal (a VM-name-resolvable host reaches sshd without a
  discovered IP). The `ssh_handshake_failed` event gains `cause` + `ipDiscovered`
  (schema is open — no validator change); the failure-path diagnostics now skip
  the irrelevant sshd/auth dumps when the IP was never discovered and point at
  the discovery fix instead. Covered by `test/modules/Test.Ssh.Tests.ps1`
  (9 cases, Pester 3.4 / 5+).
- **F3 · degradation/observability contract — implemented, static-verified,
  pending live validation.** `Send-YurunaDegradation` + the pure
  `New-YurunaDegradationRecord` builder (Test.Log.psm1) emit a `degradation`
  event onto `cycle.events.ndjson` when the harness falls back to a lesser
  mechanism and continues — making a degraded-but-passing cycle queryable
  instead of a silent fall-through, and giving F6/F8 a uniform substrate.
  Distinct from `*_failed`/`*_unavailable` (broke vs worked-around); best-effort
  (never fails a cycle); schema-valid against the open event schema. First call
  site wired: the otherwise-silent SSH→GUI keystroke fallback in
  `Invoke-Sequence`. Covered by `test/modules/Test.Log.Tests.ps1` (5 cases incl.
  a schema-validation assert); documented in `docs/failure-schema.md`.
- **F6 · OCR degradation-trend early action — implemented, static-verified,
  pending live validation.** `Wait-ForText`'s two reactive self-heals (no-text
  ring-repair, frozen-feed console-restart, each at a fixed threshold) are now
  trend-aware: once a console restart has fired the feed is known-flaky, so the
  next stall is caught at half the freeze window instead of re-waiting the full
  one; and each self-heal grants the deadline a **bounded grace** (pure
  `Get-OcrDegradationGrace`, capped at `min(timeout,120)s`) so a *recovering*
  feed isn't killed mid-recovery by the original deadline — the false
  `ocr_timeout`. A dead feed still times out (cap), and the timeout message
  stays honest about the grace granted. The first real consumer of F3: each
  proactive action emits a `degradation` event (`capture-feed` →
  `console-reconnect` / `vnc-handle-reset`), making the otherwise
  Verbose/Warning-only self-heals queryable. Covered by the new cases in
  `test/modules/Test.Invoke-Sequence.Tests.ps1` (7, Pester 3.4 / 5+).
- **F8 · OCR → SSH-marker fallback** — next (largest, last Horizon A unit).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.26

Back to [Yuruna](../README.md)
