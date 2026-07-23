# Yuruna Contributor Opportunities

Prioritized work the project would welcome help on, ranked by **return on
investment** (value delivered vs. effort to build). New contributors: pick
a level that matches the time you have, and read
[Contributing](../CONTRIBUTING.md) for the workflow. Architecture context
is in [Yuruna Architecture](architecture.md).

This page consolidates the former `opportunities-hostpool.md`,
`opportunities-installer.md`, and `opportunities-resilience.md` design
records and the former `roadmap.md` horizon view; their load-bearing
detail is folded into the items below, and the large workstreams they
tracked are now mostly shipped (see
[Recently shipped](#recently-shipped)).

Status: 🚧 in progress · ⏸ deferred / parked · no marker = open.
Priorities are re-ranked against an 860-cycle single-host corpus
(2026-05-21 → 06-08): 53 real failures, dominated by SSH readiness (16)
and OCR/capture (4+); several a-priori "big" items (IP-pool exhaustion,
proxy 5xx, disk) show **zero** occurrences on one host and only become
real under multi-host fan-out — which is why they sit in Low ROI.

## Roadmap

**Yuruna asserts resources are configured to verify components against
anticipated workloads.** The horizons below are coarse product
milestones (dates are targets); the ROI-ranked sections that follow
track the finer-grained infrastructure and reliability work in
parallel.

### Horizon: 1-2 months (target 2026-07)

- Mobile example
- Chatbot example
- Yuruna stash: service to receive SCP files

### Horizon: 2-3 months (target 2026-08)

- Model training example
- Yuruna Hub
- Drift detection

### Horizon: 3+ months (target 2026-09+)

- Cloud support
- Yuruna AI assistant
- Guide (Book)

## High ROI

Highest value for the least effort — mostly things already built that need
validation, or small changes against real recurring pain.

- **Live-validate the pool MVP end-to-end.** 🚧 The read-only pool view
  (pull-collector, Grafana dashboard, Loki/Prometheus wiring) is built and
  static-verified but has never run against live hosts. Bring up the host
  status server, boot the caching-proxy VM, run a cycle or two so hosts
  pull through the squid proxy, then confirm `:9400/healthz`, that
  `/api/v1/pool-status` lists discovered hosts, the Prometheus target is
  UP, Loki streams flow, the dashboard renders across ≥2 hosts, and killing
  the collector leaves every runner still testing. This is the only part of
  the pool MVP not statically checkable, and it validates the
  `(hostId, runId, cycleId)` join keys on real data.
- **Archive `last_failure.json` per-cycle.** Copy it into each cycle folder
  so matched-pattern / label / OCR-tail detail survives history. Today only
  the flattened `step_failure` event persists, which is the one corpus
  blind spot (it prevents measuring real-vs-false `pattern_matched_failure`)
  and is the prerequisite for predictive tuning. Cheap, no-regrets.
- **SSH connectivity across hosts.** Wire uniform host-to-host SSH so
  cross-host operations work; foundational for the multi-host pool harness.
- **Windows startup + minimal-workload test sequence.** Give Windows guests
  the same end-to-end startup-plus-workload exercise other platforms have,
  closing a test-matrix coverage gap.
- **Validate config for duplicate resource / context names.** Detect
  repeated resource names and duplicate context names at preflight, before
  they cause ambiguous or overwriting behavior mid-cycle. Fits the existing
  config-validation gate; low effort.
- **Fix the wrong time zone in Ubuntu guests.** Set the correct time zone
  during provisioning so timestamps and time-sensitive logic are accurate.
- **Document starting a new project from the template.** Lowers the
  onboarding barrier; low effort.
- **Fix `tofu apply` `/bin/sh` failure on Windows.** The EKS apply path
  works on macOS but fails on Windows because of a `/bin/sh` invocation in
  the `terraform-aws-eks` module's `local-exec`
  ([issue #757](https://github.com/terraform-aws-modules/terraform-aws-eks/issues/757)).
  Make it work under Windows shells so AWS clusters can be provisioned from
  Windows hosts.
- **Finish the Windows-installer single-materialization.** 🚧 Built (IRM to
  a GUID-named BOM-less temp file, every child relaunched via `-File`,
  eliminating the multi-fetch), statically verified. Remaining: a real
  `irm | iex` run on a fresh PS5.1 host before relying on it. Closes the
  supply-chain window where the elevated child re-fetched a moving `main`.
- **Enforce the ASCII/no-BOM gate at release time.** 🚧 The check exists
  and runs per-cycle and in a per-clone pre-commit hook; the remaining work
  is invoking it as a hard precondition in the release script (the
  authoritative backstop). A UTF-8 BOM on `windows.hyper-v.ps1` makes PS5.1
  `irm | iex` die at line 1 — denial-of-bootstrap on every fresh host.

## Medium ROI

Solid value, moderate effort — the bulk of the everyday backlog.

**Harness reliability**
- **Reduce framework incidents to ≤1 per rolling 24 h.** Umbrella
  reliability bar for unattended cycles; fed by the resilience and pool
  work rather than a single fix.
- **OCR → SSH-marker fallback for readiness gates.** Where a step's
  readiness can be proven over SSH, prefer an SSH-side marker over the
  fragile capture/OCR feed; also neutralizes the OCR command-echo
  false-match. Highest-leverage open item against real recurring pain
  (OCR/capture), but large — the next Horizon-A unit.
- **Loop / repeat-count sequence construct.** Add `loop: _number(001-003)`
  so repeated near-identical steps are expressed once instead of
  copy-pasted; the "single PowerShell script for a repeated block" doc note
  is the interim workaround.
- **Validate the session before cloud-based scripts execute.** Check the
  session/credentials context up front so failures surface early instead of
  mid-run against the wrong or unauthenticated environment.

**Pool harness**
- **Persistent volume for pool telemetry.** Retention tiering is done, but
  `/var/lib/{loki,prometheus}` sit on the caching-proxy VM root, so a
  rebuild wipes all pool history — move it onto a persistent volume.
- **Wire the parsed-but-stubbed cycle strategies and provisioning modes.**
  Only `cycleStrategy: all` + `provisioning.betweenSets: none` are
  runtime-active; `round-robin`/`single` and snapshot-revert/reprovision
  are parsed and validated but silently execute as all/none.
- **Enrich incident objects.** Attach the failure-class histogram to the
  incident object itself, and require the *same* failure class across hosts
  before declaring a cross-host incident (currently any cross-host failures
  in the window group together). Detection scaffolding and taxonomy already
  exist.
- **Solve SSH-key distribution to pool nodes.** Provisioning pool members
  needs key distribution. **Constraint:** any route must replicate the
  `/yuruna-repo` secret deny-list (vault.yml, transports.yml, ssh keys,
  password files, caching-proxy config, `.git`, test.config.yml)
  byte-for-byte — one missed pattern leaks secrets pool-wide; do not change
  security posture without explicit authorization.

**Cloud providers**
- **AWS: retrieve created registry credentials during `import-clusters`**
  so imported clusters can authenticate to their registry.
- **AWS: resolve cluster public-IP addressing** (incl.
  `public_subnet_map_public_ip_on_launch`) so nodes get the intended public
  addressing.
- **GCP: fix `min_master_version` and remove the v1.19+ ingress hack** —
  same root cause; cluster creation with v1.19+ failed, forcing an
  ingress workaround.
- **GCP: fix the IP load balancer** so services get a working external IP.
- **Finish and publish the AWS and GCP resource templates**, and expand the
  template library more broadly.
- **Azure: general improvements** (currently unscoped).

**Other**
- **Reword the in-guest download line to a transparency message.** Replace
  the pre-download echo in `fetch-and-execute.sh` with one human-readable
  line so anyone watching the console/OCR log sees remote code is about to
  run. Disclosure only — guest-side integrity gating is deliberately
  declined (disposable VM, same trust domain). Avoid the literal tokens
  "fetch"/"execute" so the OCR failure-matcher doesn't false-trip.
- **Skip a `tofu` variable when it isn't required**, to drop spurious apply
  warnings that obscure real issues.
- **Destroy `tofu` `local-exec` resources on `tofu destroy`** — they
  currently leak because destroy doesn't track them.
- **Decide whether to copy all code during component setup**
  (`Yuruna.Component.psm1`) — affects setup cost and component isolation.
- **Document the Hyper-V Amazon Linux nested-virtualization setup**
  (`host/windows.hyper-v/guest.amazon.linux.2023/read.more.md`).

## Low ROI

Low current value, very high effort, or deliberately deferred. Worth doing
only when the enabling condition arrives.

- **Horizon B resilience gates — IP/capacity admission, caching-proxy
  circuit breaker, disk-headroom.** ⏸ Each hooks into fields the host
  registration and pool planner already reserve, so they are data-population
  exercises, not re-architecture. Deferred because the failure classes they
  address (DHCP/IP exhaustion, proxy 5xx, full disk) show **zero**
  occurrences on a single host — they only become real under multi-host
  fan-out. Gate on the pool harness.
- **Quorum-gated failure-pause break (consensus control).** ⏸ Making a
  pool's advisory `degraded` flag actually pause/break a host's
  failure-pause loop needs cross-host consensus, which the atomic
  single-instance runner model deliberately avoids. Hardest item in the
  design; tackle only with a clear consensus design.
- **Write-side control beyond polled intent.** ⏸ The git intent store,
  pull-sync shim, and admin CLI already give decentralized `desiredState`
  control. Keep any expansion intent-based (pull) — a central
  command-dispatch master would add a single point of failure and fight the
  autonomous pull model.
- **Snapshot integrity pre-check.** ⏸ Verify a snapshot exists and is
  consistent at save/pre-cycle time, not first at restore. Parked: zero
  `snapshot_restore_failed` events in the corpus.
- **Predictive per-step timeout & pre-restore.** ⏸ Read recent
  `last_failure.json` history to pre-widen timeouts or pre-restore for
  flaky steps. Parked — depends on the per-cycle failure archive above.
- **Vault / credential drift pre-check.** ⏸ Verify the provisioned
  credential matches what the sequence will authenticate with, before the
  auth step. **Constraint:** read-only verification only — no changes to
  password alphabets, lengths, hashing, or vault layout, and no
  detection evasion. Parked (1 corpus occurrence).
- **Fully close the Windows installer `%TEMP%` TOCTOU.** ⏸ GUID-random
  naming + delete defeats predictable-path hijack but not a same-user race
  between write and open. A full fix (ACL'd per-user dir the child
  re-validates, or passing bytes via handle/stdin) abandons the
  `-File`/`$PSCommandPath` model and is UAC-fragile for a threat that
  already requires same-user code execution — kept as *mitigated*.
- **Serve immutable per-cycle repo snapshots.** ⏸ Would eliminate the
  working-tree-rename race at its source, but conflicts with the
  interceptor workflow that serves the live working tree so local changes
  are testable without pushing. The race is already handled by the capture
  self-heal; revisit only if that trade-off changes.
- **Integrate a mobile testing framework** (e.g. Maestro) to drive mobile
  app flows.
- **Build a VS Code extension** to start projects and run commands from the
  editor.
- **Generate a topology graph from the YAML config** (e.g. Python
  graphviz) for an at-a-glance view of project structure.

## Recently shipped

Large workstreams completed since these opportunities were first scoped —
kept here for context (details in the linked docs / code):

- **Autonomous-remediation infrastructure** — failure-class dispatcher,
  NDJSON schema validator, cycle correlation IDs, and the runner state
  machine; together they convert the existing telemetry surface into
  something a remediation loop can act on.
- **State-recovery primitives** — the atomic `Write-YurunaStateFile`
  helper and the boot-time recovery sweep, so every state class either
  has an atomic write helper or a startup detection + archive path.
  Snapshot manifest sidecars and the log-rotation primitive shipped
  alongside.
- **Verb-handler registry migration** — all 21 sequence verbs moved from
  the inline switch in `Invoke-Sequence.psm1` to the
  `Test.SequenceAction` / `Test.SequenceHandler` registry;
  `Invoke-Sequence` is now purely the executor.
- **Cross-driver host-driver shared helpers** — platform-independent
  download/VM/guest-IP/proxy-probe logic factored into `host/modules/`,
  injecting the one varying platform detail per call. (Backend VM/proxy
  paths stay per-platform by design; the KVM IPv6-bracketing proxy probe is
  intentionally not folded in.)
- **Multi-host pool harness, Phases 0–6** — DHCP-resilient `hostId` +
  capability record; the self-discovering stdlib-Go pull-collector and
  Grafana pool dashboard; per-step NDJSON tail + incident correlation; v1
  pool/test-set schemas, git intent store, pull-sync shim, and admin CLI
  ([pool-admin.md](pool-admin.md)); test-set execution with per-guest
  overrides; advisory pool gating, alerting, and first-engage remediation;
  push telemetry with TLS/bearer auth. All additive — a no-pool host is
  byte-identical to single-host.
- **Installer & in-guest script integrity** — signed `install.sha256`
  (RSA-4096 detached signature + bundled key); opt-in git-tag pinning;
  pinned apt-key fingerprints + PowerShell tarball checksum in the Ubuntu
  installer; hard-fail image/ISO checksums with GPG-authenticated Ubuntu
  hashes and a commit-pinned `Fido.ps1`; pinned Homebrew and libosinfo
  fetches; the ASCII/no-BOM pre-commit hook. (Standing rule: re-verify every
  fingerprint/hash/commit-SHA against live upstream at implementation time.)
- **Resilience Horizon A** — the graceful-degradation / observability
  contract (`Send-YurunaDegradation`, [failure-schema.md](failure-schema.md));
  OCR degradation-trend early action in `Wait-ForText`; and SSH-readiness
  hardening (`Wait-SshReady` failure-cause classification) — the last
  addresses the empirical #1 recurring failure class.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.22

Back to [Yuruna](../README.md)
