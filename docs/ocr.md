<a id="42607283-0001"></a>

# OCR providers

Yuruna polls the guest framebuffer for text to drive `waitForText`,
`waitForTextWithNudge`, `waitForAndEnter`, `passwdPrompt`, and `tapOn`. The matching engine is
pluggable: three built-in providers ship today, each with a per-platform
availability check and a private invocation backend.

Provider registry lives in
[`test/modules/Test.OcrEngine.psm1`](../test/modules/Test.OcrEngine.psm1).

<a id="42607283-0002"></a>

## Built-in providers

| Provider       | Platform        | Backend |
|----------------|-----------------|---------|
| `tesseract`    | any             | Local `tesseract` binary; cross-platform fallback. |
| `winrt`        | Windows 10+     | `Windows.Media.Ocr` via a persistent `powershell.exe` (5.1) worker. |
| `macos-vision` | macOS 10.15+    | Apple Vision via `swift script.swift`, with a `swiftc -O` pre-compile cache. |

<a id="42607283-0003"></a>

## Per-platform default ordering

`Get-EnabledOcrProvider` returns the first provider that matches, in
this order, when `$env:YURUNA_OCR_ENGINES` is unset:

- **macOS UTM**: `macos-vision, tesseract`
- **Windows Hyper-V**: `winrt, tesseract`
- **Ubuntu KVM**: `tesseract`

Why ordering matters: the default combine mode is `Or` (see
`Get-OcrCombineMode` in
[`Test.OcrMatch.psm1`](../test/modules/Test.OcrMatch.psm1)), which
short-circuits on the first engine that finds the search pattern. The
first engine listed is therefore the primary; later engines are
fallbacks invoked only when the primary's text did not match.

<a id="42607283-0004"></a>

## Operator overrides

| Variable                  | Effect |
|---------------------------|--------|
| `YURUNA_OCR_ENGINES`      | Comma-separated provider list. Reorders or restricts the active set. Example: `tesseract,winrt`. |
| `YURUNA_OCR_COMBINE`      | `Or` (default -- first match wins) or `And` (every enabled provider must match). |
| `YURUNA_OCR_WORKER`       | `0` disables the persistent WinRT worker and reverts to one-shot `powershell.exe` spawns per OCR call (slower; debug only). |

<a id="42607283-0005"></a>

## Why a persistent WinRT worker

`powershell.exe` cold-starts at 150-300 ms per spawn, so a cycle with
~1000 OCR polls would burn 3-5 minutes on process-start overhead
alone. The persistent worker keeps one `powershell.exe` alive for the
inner-runner lifetime and feeds image paths over stdin -- per-call
latency drops to ~5-15 ms (a ~10-30x speedup). A worker failure falls
back to the one-shot path for that single call, so a broken worker can
never harden into a permanent OCR outage.

**Wire protocol** (line-oriented, UTF-8):

| Direction | Line | Meaning |
|-----------|------|---------|
| parent -> worker | `<imagePath>\n` | One request per OCR call |
| worker -> parent | `__YURUNA_READY__\n` | Printed once after init |
| worker -> parent | `<ocrLine>\n` | Zero or more per request |
| worker -> parent | `__YURUNA_EOR_OK__\n` | Success terminator |
| worker -> parent | `__YURUNA_EOR_ERR__ <msg>\n` | Failure terminator |

**Lifecycle.** Lazy spawn on first call. Any I/O failure or unexpected
EOF tears down the worker and re-throws; `Invoke-WinRtOcr` catches and
falls back to the one-shot path for that call (the next call
respawns). The module's `OnRemove` handler closes stdin and waits up
to 2 s before `Kill()` so a re-import doesn't leak the worker.

**Ctrl+C / abrupt-exit safety.** On spawn, the worker is bound to a
Win32 Job Object created with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` and
owned by the parent pwsh process. Console Ctrl+C, watchdog kill, or
any other path that terminates the parent (orderly exit, crash,
`TerminateProcess`) closes the only handle to that job, and the OS
kills the worker as a side effect. The graceful `OnRemove` path
remains; the job is the safety net for everything that bypasses it.
Job binding is best-effort: if `AssignProcessToJobObject`
fails the spawned worker is killed and the call falls back to the
one-shot path, so a degraded environment never leaks an orphaned
worker.

<a id="42607283-0006"></a>

## Why the Vision Swift script is so opinionated

Two non-obvious transforms protect every macOS UTM screenshot before
`VNRecognizeTextRequest` sees it:

1. **Densest-text-row crop.** UTM/screencapture writes 2898x1698 PNGs
   where the login text fills only the top ~150 rows. Vision's
   detector returns 0 observations on images where content fills <10%
   of the vertical extent. The script counts lit pixels per row, skips
   an all-white toolbar bar, and crops to the densest cluster.

2. **PNG round-trip to strip DisplayP3 + 144 DPI.** Vision's text
   detector silently returns 0 observations on wide-gamut, 144 DPI
   PNGs that it reads cleanly when re-encoded as sRGB / 72 DPI.
   `CGImageDestination/PNG` strips both tags. Required for
   AVF/screencapture output.

`usesLanguageCorrection = false` is also load-bearing: console text
(hostnames with dashes, cloud-init timestamps, `ttyl` vs `tty1`) is
not natural language, and language correction rewrites valid OCR into
nonsense.

<a id="42607283-0007"></a>

## Why Tesseract runs at --psm 6

`--psm 6` (single uniform block of text) is the only page-segmentation
mode that reads a terminal screenshot end-to-end. Terminal captures ARE
uniform blocks -- monospace, equal-size lines, top-aligned -- and PSM 6
walks the whole image as one block, so a sparse top-of-image text region
with empty space below still gets read in full.

Every neighboring mode drops text the harness depends on:

- **`--psm 4`** (single column of variable sizes): on screens with two
  visually-distinct content regions -- e.g. a tiny login prompt at the
  top plus a cloud-init dump rendered as a virtual second column at the
  bottom on retried boots -- PSM 4 picks ONE region as "the column" and
  silently drops the text in the other. The visible symptom is a
  `<hostname> login:` line missing from the OCR output even though the
  screenshot shows it.
- **`--psm 3`** (fully automatic, Tesseract's default): does its own
  multi-column detection and re-orders/merges adjacent UI regions, with
  the same `login:` drop-out as PSM 4.
- **`--psm 11`** (sparse text): fragments every word onto its own output
  line, which breaks the `Wait-ForText -ContainsString` substring match
  the test harness relies on.

<a id="42607283-0008"></a>

## Adding a new provider

1. Implement `Invoke-<Whatever>Ocr -ImagePath <path>` in a module or
   inline.
2. Register at the bottom of
   [`Test.OcrEngine.psm1`](../test/modules/Test.OcrEngine.psm1):

   ```powershell
   Register-OcrProvider -Name 'whatever' `
       -Invoke      { param([string]$ImagePath) Invoke-WhateverOcr -ImagePath $ImagePath } `
       -IsAvailable { [bool](Get-Command whatever -ErrorAction SilentlyContinue) }
   ```
3. The startup capability matrix lists it under `OCR:` when the
   `IsAvailable` check passes. See
   [Capability matrix](test-harness.md#capability-matrix-and-cycle-plan-gate).

The capability gate fails the cycle when a sequence references an
OCR-requiring action (`waitForText`, `passwdPrompt`, ...) and no
provider's `IsAvailable` returns `$true`.

<a id="42607283-0009"></a>

## Detecting a corrupted console echo

The last-resort diagnostics path types a command at a console and reads back
what OCR saw echoed, to judge whether the terminal is actually receiving
keystrokes or a stuck key is mangling them. `Test-ConsoleEchoIntact`
(`test/modules/Test.Diagnostic.psm1`) makes that judgment as a pure
function -- given only the text that was typed and the text OCR read off the
screen, with no screenshot, engine or host contact -- which is what makes its
failure signature testable against captured samples with no VM in the loop.

**The hard constraint is that OCR of a console is very noisy.** A correctly
typed line came back from a real, healthy capture as
`HFhttp:/7192.168.64.1:8080:F=...` -- `H=` read as `HF`, `//` as `/7`, `;` as
`:`, `curl` as `cur`, `2>&1` as `2>81` -- and cut off two-thirds through
because the rest had scrolled or fallen outside the recognized region. Any
check resembling equality, or any check demanding the whole command be
visible, rejects every healthy capture and makes this last-resort rung
strictly worse than no check at all.

So the test does not ask "does the screen match the command" but "does the
screen contain a long stretch the command cannot explain":

1. Both strings are normalized through `Get-OCRNormalized`, which folds known
   OCR confusion groups (`o`/`O`/`0`/`@`, `l`/`I`/`1`/`i`, `S`/`5`/`s`,
   `:`/`;`/`.`, ...) and drops characters OCR routinely invents or loses.
2. The command's distinct `GramSize`-character windows form the set of
   everything the screen is allowed to show.
3. Walking the OCR text, each position is *explained* if its window is in
   that set. The corruption signal is the longest run of consecutive
   *unexplained* positions that follows the command's own echo -- a run is
   counted only once at least `AnchorMinRun` explained positions have
   appeared in a row, marking where the command genuinely landed on screen.
   That anchor is what separates corruption from ordinary scrollback: text
   printed *before* the command (a login banner, a boot log, earlier output)
   is unexplained and unbounded but never preceded by the command's dense
   echo, so it goes uncounted. A stuck key, by contrast, appends or inserts
   its garbage at or after the command it corrupted, producing one
   continuous counted run hundreds of characters long -- isolated OCR noise
   can only ever invalidate `GramSize` consecutive windows, so it cannot
   accumulate into a false positive.
4. Independently, the fraction of the command's windows that appear anywhere
   in the OCR text is the truncation signal.

**Deliberately not used: `Test-OCRMatch`.** It answers "is this prompt on
screen" by splitting its pattern on whitespace and punctuation and requiring
only that each fragment appear somewhere -- measured against a fully
corrupted frame it still returns true for the pattern `rm -f y.ps1 y.txt`, so
a predicate built on it would never fire.

**Also deliberately not used: the longest run of one repeated character.** It
reads as the obvious test for a stuck key and does not work: on real frames
the longest same-character run was 24 on a corrupted capture against 25 on a
healthy one, no discrimination at all, because thousands of stuck glyphs do
not survive OCR as a clean run -- Tesseract renders them as scattered
fragments like "PUPPY PY BBY PPP YB BP..." across dozens of lines. Those
fragments are still unexplainable by the command, which is why the
run-of-unexplained-positions test above catches them anyway.

**`unknown` is a first-class verdict and always means "proceed."** It is
returned when the OCR text is too short to judge, or when the normalizer
itself is unavailable. A caller must press Enter on `unknown`: this is the
last-resort diagnostics path, and refusing to submit a line that simply could
not be read would lose the capture outright.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.18

Back to [Yuruna](../README.md)
