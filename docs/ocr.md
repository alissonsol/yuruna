# OCR providers

Yuruna polls the guest framebuffer for text to drive `waitForText`,
`waitForAndEnter`, `passwdPrompt`, and `tapOn`. The matching engine is
pluggable: three built-in providers ship today, each with a per-platform
availability check and a private invocation backend.

Provider registry lives in
[`test/modules/Test.OcrEngine.psm1`](../test/modules/Test.OcrEngine.psm1).

## Built-in providers

| Provider       | Platform        | Backend |
|----------------|-----------------|---------|
| `tesseract`    | any             | Local `tesseract` binary; cross-platform fallback. |
| `winrt`        | Windows 10+     | `Windows.Media.Ocr` via a persistent `powershell.exe` (5.1) worker. |
| `macos-vision` | macOS 10.15+    | Apple Vision via `swift script.swift`, with a `swiftc -O` pre-compile cache. |

## Per-platform default ordering

`Get-EnabledOcrProvider` returns the first provider that matches, in
this order, when `$env:YURUNA_OCR_ENGINES` is unset:

- **macOS UTM**: `macos-vision, tesseract`
- **Windows Hyper-V**: `winrt, tesseract`
- **Ubuntu KVM**: `tesseract`

Why ordering matters: the default combine mode is `Or` (see
`Get-OcrCombineMode` in
[`Invoke-Sequence.psm1`](../test/modules/Invoke-Sequence.psm1)), which
short-circuits on the first engine that finds the search pattern. So
the first engine listed is the primary; later engines are fallbacks
invoked only when the primary's text did not match.

## Operator overrides

| Variable                  | Effect |
|---------------------------|--------|
| `YURUNA_OCR_ENGINES`      | Comma-separated provider list. Reorders or restricts the active set. Example: `tesseract,winrt`. |
| `YURUNA_OCR_COMBINE`      | `Or` (default — first match wins) or `And` (every enabled provider must match). |
| `YURUNA_OCR_WORKER`       | `0` disables the persistent WinRT worker and reverts to one-shot `powershell.exe` spawns per OCR call (slower; debug only). |

## Why a persistent WinRT worker

`powershell.exe` cold-starts at 150-300 ms per spawn. A cycle with
~1000 OCR polls would burn 3-5 minutes per cycle on process-start
overhead alone. The persistent worker keeps one `powershell.exe`
alive for the inner-runner lifetime and feeds image paths over stdin —
the per-call latency drops to ~5-15 ms (a ~10-30× speedup). A worker failure
falls back to the one-shot path for that single call, so a broken
worker can never harden into a permanent OCR outage.

**Wire protocol** (line-oriented, UTF-8):

| Direction | Line | Meaning |
|-----------|------|---------|
| parent → worker | `<imagePath>\n` | One request per OCR call |
| worker → parent | `__YURUNA_READY__\n` | Printed once after init |
| worker → parent | `<ocrLine>\n` | Zero or more per request |
| worker → parent | `__YURUNA_EOR_OK__\n` | Success terminator |
| worker → parent | `__YURUNA_EOR_ERR__ <msg>\n` | Failure terminator |

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
remains in place; the job is the safety net for everything that
bypasses it. Job binding is best-effort: if `AssignProcessToJobObject`
fails the spawned worker is killed and the call falls back to the
one-shot path, so a degraded environment never leaks an orphaned
worker.

## Why the Vision Swift script is so opinionated

Two non-obvious transforms protect every macOS UTM screenshot before
`VNRecognizeTextRequest` sees it:

1. **Densest-text-row crop.** UTM/screencapture writes 2898×1698 PNGs
   where the actual login text fills only the top ~150 rows. Vision's
   detector returns 0 observations on images where content fills <10%
   of the vertical extent. The script counts lit pixels per row, skips
   an all-white toolbar bar, and crops to the densest cluster.

2. **PNG round-trip to strip DisplayP3 + 144 DPI.** Vision's text
   detector silently returns 0 observations on wide-gamut, 144 DPI
   PNGs that it reads cleanly when re-encoded as sRGB / 72 DPI.
   `CGImageDestination/PNG` strips both tags. Required after the
   AVF/screencapture switch.

`usesLanguageCorrection = false` is also load-bearing: console text
(hostnames with dashes, cloud-init timestamps, `ttyl` vs `tty1`) is
not natural language, and language correction was actively rewriting
valid OCR into nonsense.

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
3. The capability matrix at startup will list it under `OCR:` when the
   `IsAvailable` check passes. See
   [Capability matrix](capability-matrix.md).

The capability gate fails the cycle when a sequence references an
OCR-requiring action (`waitForText`, `passwdPrompt`, ...) and no
provider's `IsAvailable` returns `$true`.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.14

Back to [Yuruna](../README.md)
