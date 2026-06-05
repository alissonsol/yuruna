# Remediation dispatcher

When a sequence step fails, the inner runner writes
`$YURUNA_LOG_DIR/last_failure.json` with a `failureClass` token drawn
from the enum in
[`Test.SequenceAction`](../test/modules/Test.SequenceAction.psm1). The
remediation dispatcher in
[`test/modules/Test.Remediation.psm1`](../test/modules/Test.Remediation.psm1)
maps that token to an actionable recommendation — the keystone of
autonomous self-heal.

Before this module nothing consumed the FailureClass enum. An
operator (or a future autonomous loop) had to grep the free-text
error message and guess what to do next. The dispatcher closes the
loop: read the failure record, route on `failureClass`, return what
the caller should do.

## Public surface

| Function | Signature | Used by |
|---|---|---|
| `Register-RecoveryHandler` | `-FailureClass -Handler` | External modules add or override a handler |
| `Register-BuiltinRecoveryHandler` | (no args) | Installs the default handler set at module load |
| `Get-RecoveryHandler` | `-FailureClass` | Dispatcher; introspection |
| `Get-RegisteredFailureClass` | (no args) | Capability matrix on startup; introspection |
| `Get-RecoveryRecommendationName` | (no args) | Canonical recommendation vocabulary (shared with each verb's SuggestedRecoveries) |
| `Invoke-Remediation` | `-FailureRecord [-LastFailurePath]` | Operator / autonomous loop; returns the recommendation hashtable |
| `Clear-RecoveryHandler` | (no args) | Tests only |

## Recommendation taxonomy

Each handler returns a hashtable whose `Recommendation` field MUST be
one of the canonical values below. A streaming consumer can pivot on
this small finite set instead of free-text matching:

| Recommendation | Meaning |
|---|---|
| `retry_immediately` | Transient; rerun the failing step now. |
| `retry_with_backoff` | Likely transient (network blip, rate limit); the caller picks the backoff. |
| `restart_from_snapshot` | Guest state went sideways; restore to the last good snapshot and replay from there. |
| `reconnect` | Transport-level (VNC dropped, SSH session died); rebuild the connection and continue. |
| `pause_and_inspect` | Repeating the step risks burning resources; surface and wait. |
| `operator_intervention_required` | The runner cannot self-recover (vault password wrong, image unsigned). |
| `escalate` | Reserved — a valid recommendation an external handler may return to flag a novel case for the framework to learn. No built-in handler emits it; the no-handler / handler-error fallback is `operator_intervention_required`. |

## Advisory by design

Handlers return **what the caller should do**, not what they
**did**. A future iteration can flip individual handlers to act
directly (call `Repair-VncConnection`, `Wait-SshReady`,
`Restore-VMDiskSnapshot` themselves) once the autonomous loop's blast
radius is bounded. Today the safer contract is: dispatcher tells you
the next step; caller decides.

## Registry shape

The registry uses the shared
[`New-YurunaRegistry`](../test/modules/Test.Registry.psm1)
primitive, so it appears in `Get-YurunaRegistryDirectory` alongside
`SequenceAction`, `HostIO`, `OcrProvider`,
[`CredentialProvider`](component-registry.md), and
[`HostCondition`](host-condition-registry.md) — autonomous tooling
enumerates every routing surface through one API.

## Event emission

Every dispatch emits a `remediation_recommended` NDJSON event
carrying `(failureClass, recommendation, severity, handledBy)` so a
streaming consumer follows what the dispatcher chose without having
to parse the recommendation object. Schema lives in
[`Test.EventSchema`](../test/modules/Test.EventSchema.psm1); the same
validator that gates the cycle event stream.

## Adding a new failure class

1. Add the new value to the `FailureClass` enum in
   [`Test.SequenceAction`](../test/modules/Test.SequenceAction.psm1).
2. Register a handler in
   [`Test.Remediation`](../test/modules/Test.Remediation.psm1)'s
   built-in block, or from an external module via
   `Register-RecoveryHandler`.
3. The handler is a `param([hashtable]$c)` scriptblock that reads
   `$c.Failure` (the parsed last_failure.json) and `$c.Context`
   (vmName, guestKey, hostType, stepNumber, actionVerb, severity,
   suggestedRecoveries), returning `@{ Recommendation = '<enum>';
   Rationale = '<short>' }` (optional `Actions`, `HandledBy`,
   `AutoApply`). Severity is attached by the dispatcher from the
   failure record, not by the handler.
4. The startup capability matrix picks up the registration
   automatically; the dispatcher cannot reach an unrouted class
   because the validator at module load throws if any enum value is
   missing a handler.

## Related

- [Test harness](test-harness.md) — overall architecture.
- [Watchdog and heartbeat protocol](watchdog.md) — the kill side of self-healing.
- [Runner state machine](runner-state.md) — explicit lifecycle that surfaces a fault transition.

Back to [Test harness](test-harness.md) · [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
