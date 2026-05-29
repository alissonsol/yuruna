# Yuruna Roadmap

**Yuruna asserts resources are configured to verify components against anticipated workloads.**

Status legend: ✓ done · 🚧 in progress · ⏸ paused / deferred ·
no marker = planned. Dates are last-status-change-on. The
[opportunities](opportunities.md) page tracks finer-grained
infrastructure and audit items in parallel.

## Horizon: 1-2 months (target 2026-07)

- Mobile example
- Chatbot example
- Yuruna stash: service to receive SCP files

## Horizon: 2-3 months (target 2026-08)

- Model training example
- Yuruna Hub
- Drift detection

## Horizon: 3+ months (target 2026-09+)

- Cloud support
- Yuruna AI assistant
- Guide (Book)

## Recently completed (audit-cycle outcomes, 2026-05)

✓ Critical / High / Medium audit batch — all 35 items resolved or
  verified as false positives. See [opportunities.md](opportunities.md)
  for the closed-issues breakdown.

✓ Autonomous-remediation infrastructure — failure-class dispatcher
  (R-4), NDJSON schema validator (R-7), cycle correlation IDs (R-8),
  runner state machine (R-11). Together they convert the existing
  telemetry surface into something a remediation loop can act on.

✓ State-recovery finish line — Write-YurunaStateFile primitive
  (R-1), boot-time recovery sweep (R-5). Every state class either
  has an atomic write helper or a startup detection + archive
  path.

✓ Snapshot manifest sidecars (R-6), image-integrity gateway (R-9,
  6/9 candidate Get-Image scripts wired), log rotation primitive
  (R-10).

🚧 Sequence verb-handler split (H-10) — `Invoke-Sequence.psm1`
  is ~2,461 lines after the M-3 key-code extraction. Final split
  of the inline `retry` / `recoverFromSnapshot` handlers stays
  deferred pending the comment-to-markdown migration that will
  reduce the file's explanatory-comment footprint substantially.

Back to [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
