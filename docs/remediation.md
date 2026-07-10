# Remediation dispatcher

When a sequence step fails, the inner runner writes
`$YURUNA_LOG_DIR/last_failure.json` with a `failureClass` token drawn
from the enum in
[`Test.SequenceAction`](../test/modules/Test.SequenceAction.psm1). The
remediation dispatcher in
[`test/modules/Test.Remediation.psm1`](../test/modules/Test.Remediation.psm1)
maps that token to an actionable recommendation — the keystone of
autonomous self-heal.

This module is what consumes the FailureClass enum. Without it, an
operator (or a future autonomous loop) would have to grep the free-text
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

## Inner-cause routing past `retry_exhausted`

An exhausted `retry` reports the outer class `retry_exhausted`, which
masks the deepest verb's actionable cause. The failure record preserves
that cause in `innerFailureClass`; when the outer class is
`retry_exhausted` and the inner class has its own registered handler, the
dispatcher routes on the **inner** class so the recommendation targets
the real failure rather than the generic retry wrapper. `severity` and
`suggestedRecoveries` follow the routed class; the outer class stays
visible as `RoutedFromFailureClass` on the result and `outerFailureClass`
on the `remediation_recommended` event. With no inner class (or no inner
handler) the dispatcher routes on the outer class unchanged.

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
   and `reproCommand` — each an empty string when absent, so a handler
   string-tests without a null guard), returning `@{ Recommendation =
   '<enum>'; Rationale = '<short>' }` (optional `Actions`, `HandledBy`,
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

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.10

Back to [Yuruna](../README.md)
