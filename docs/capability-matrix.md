# Capability matrix and cycle-plan gate

At every cycle start the inner runner publishes a single banner naming
what the harness can actually do on the current host — which OCR
engines are available, which host I/O actions are wired, which
extensions are active in each area. The same matrix is cross-referenced
against the per-cycle sequence plan: cycles that reference an
unimplemented host I/O action fail before any VM is touched, with a
message naming the missing backend instead of failing late inside a
step with "Unknown host: …".

Implementation:
[`test/modules/Test.Capability.psm1`](../test/modules/Test.Capability.psm1).
Surfaces three underlying registries:
[OCR providers](ocr.md),
[host I/O providers](host-io.md), and
[extension areas](extensions-api.md).

## The banner

```
─────────────────────────────────────────────────────────
Yuruna capability matrix (host.windows.hyper-v)
─────────────────────────────────────────────────────────
  Host I/O:   Send-Click, Send-Key, Send-Text
  OCR:        winrt, tesseract
  Extensions:
    authentication         default
    caching-proxy-parser   default
    notification           default
─────────────────────────────────────────────────────────
```

Printed once per cycle, right after `Resolve-CyclePlan` succeeds. Lands
in the per-cycle HTML log via the Information stream, so post-mortem
readers see what was actually wired at cycle start without re-running.

## The cycle-plan gate

After printing the banner the inner calls
`Test-CyclePlanCapabilityFromPlan`, which:

1. Walks every sequence in the cycle plan (including nested `retry`
   blocks) and collects the set of action verbs used.
2. For each verb, looks up its requirements via
   [`Test.SequenceAction\Get-SequenceActionRequirementMap`](../test/modules/Test.SequenceAction.psm1) —
   each verb declares which host I/O actions it needs and whether OCR
   is required.
3. Cross-references the requirements against the live
   `Test.HostIO`/`Test.OcrEngine` matrices.

When a required host I/O action is missing the cycle aborts with:

```
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  CAPABILITY GATE FAILED -- cycle aborted on 'host.ubuntu.kvm'.
  Sequences reference host I/O actions this host has no backend for:
    - Send-Click
  Wire a backend via Register-HostIOProvider in Invoke-Sequence.psm1,
  or drop the requiring action from the cycle's sequence YAMLs.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
```

A required OCR engine but no enabled+available provider produces the
parallel:

```
  Sequences require OCR but no OCR provider is enabled+available.
  Install tesseract or wire a per-host provider via Register-OcrProvider.
```

The cycle does NOT spin up a VM after a capability-gate failure;
`$GuestList` is emptied so the per-guest loop runs zero iterations,
and the cycle finalizes naturally with `$OverallPassed=false`. This
bumps `ConsecutiveFailures` and fires notifications on the same
threshold as any other failure.

## Unknown verbs are warnings, not failures

When a sequence references a verb not registered in
`Test.SequenceAction`, the gate emits a `Write-Warning` listing the
unknown verbs but does NOT abort the cycle. The engine's own action
switch in
[`Invoke-Sequence.psm1`](../test/modules/Invoke-Sequence.psm1) will
throw at runtime; the warning surfaces the typo / new-verb-in-progress
before the slow path.

## What's in the requirements table

Today (see the `Register-SequenceAction` block at the bottom of
[`Invoke-Sequence.psm1`](../test/modules/Invoke-Sequence.psm1)):

| Verb                     | HostIO required           | OCR required |
|--------------------------|---------------------------|--------------|
| `pressKey`               | `Send-Key`                | no           |
| `inputText`              | `Send-Text`               | no           |
| `inputTextAndEnter`      | `Send-Text`, `Send-Key`   | no           |
| `tapOn`                  | `Send-Click`              | yes          |
| `waitForText`            | _(none)_                  | yes          |
| `waitForAndEnter`        | `Send-Text`, `Send-Key`   | yes          |
| `passwdPrompt`           | `Send-Text`, `Send-Key`   | yes          |
| `fetchAndExecute`        | `Send-Text`, `Send-Key`   | yes          |
| `sshExec` / `sshFetchAndExecute` / `sshWaitReady` | _(none)_ | no |
| `saveDiskSnapshot` / `loadDiskSnapshot` / `saveSystemDiagnostic` / `takeScreenshot` / `break` / `callExtension` / `retry` / `waitForSeconds` | _(none)_ | no |

Adding a new verb means one `Register-SequenceAction` call that
declares its capabilities — the gate automatically picks up the new
verb on the next cycle.

## Guest coverage caveats

The harness assumes every guest can run on every host. One Apple-
licensing exception breaks that assumption: **macOS 26** can only be
virtualized on a macOS host. `host/windows.hyper-v/guest.macos.26/`
and `host/ubuntu.kvm/guest.macos.26/` do not exist by design;
`host/macos.utm/guest.macos.26/` is the only path. Cycle plans that
target `guest.macos.26` on a non-macOS host fail at planner time
(the guest folder is not discoverable on the host), not deep inside
a step.

## Calling the matrix outside a cycle

The matrix is queryable programmatically:

```
Import-Module test/modules/Test.Capability.psm1 -Global -Force
Import-Module test/modules/Invoke-Sequence.psm1 -Global -Force   # populates the registries

$matrix = Get-HostCapabilityMatrix -HostType 'host.windows.hyper-v'
$matrix.hostIO        # @('Send-Key','Send-Text','Send-Click')
$matrix.ocr           # @('winrt','tesseract')
$matrix.extensions    # ordered dict: area -> [active...]
```

Used by future health-checks, CI smoke tests, and the upcoming
`/control/capability` endpoint on the status server.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.12

Back to [Yuruna](../README.md)
