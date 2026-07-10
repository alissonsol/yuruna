# Log-level cascade

Every Yuruna entry point shares one resolved log level that gates which
PowerShell streams reach the terminal AND propagates to every child
pwsh / per-cycle inner runner / sequence engine through `$env:YURUNA_LOG_LEVEL`.

The canonical implementation lives in
[`test/modules/Test.LogLevel.psm1`](../test/modules/Test.LogLevel.psm1).
This module is the single source of truth for the rank table +
preference cascade, so it is not duplicated across the 28+ scripts and
four runner files that depend on it.

## Levels

| Rank | Level         | Why a level exists |
|------|---------------|--------------------|
| 1    | `Error`       | Highest priority. Always visible. |
| 2    | `Warning`     | Operator-actionable problems that did NOT fail the cycle. |
| 3    | `Information` | Default. Step-level progress, banners, PASS/WARN/FAIL rows. |
| 4    | `Verbose`     | Per-poll OCR text, child-process command lines. |
| 5    | `Debug`       | Wire-protocol traces (VNC bytes, scancode bursts). |

Each level shows itself **and every higher-priority level**. `-logLevel
Warning` shows Error + Warning; `-logLevel Verbose` shows everything
except Debug.

## Three-state resolution

1. **Command-line override** — `-logLevel Verbose` on
   `Invoke-TestRunner.ps1` / `Invoke-TestInnerRunner.ps1` /
   `Test-Sequence.ps1`.
2. **`logLevel:` in `test.config.yml`** — hot-reloadable; the inner
   runner re-resolves on every `Sync-RuntimeConfig`, so an operator can
   edit the YAML mid-cycle and the next step picks up the new value.
3. **Default `Information`** — invalid values fall back here with a
   one-line warning, so a YAML typo does not silently silence the
   transcript.

The cmdline override wins over a hot-reload — once you start a runner
at `Information`, a config edit to `Warning` will not promote it. Stop
the runner and restart without `-logLevel` to release the override.

## Propagation across pwsh boundaries

Child pwsh processes (the outer → inner spawn, sequence engine sub-
processes, `Test-Sequence` standalone) inherit `$env:YURUNA_LOG_LEVEL`
but NOT PowerShell preference variables. The env var IS the propagation
channel. The cascade module exports `Use-LogLevelFromEnv` — every child
script that should honor the parent's level calls it at the top:

```
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (Test-Path $_logLevelMod) { Import-Module $_logLevelMod -Global -Force; Use-LogLevelFromEnv }
```

This three-line idiom keeps each
`host/<platform>/guest.<x>/{Get-Image,New-VM}.ps1` from carrying an
11-line copy-paste rank table.

## Why `$ErrorActionPreference` stays at `Continue`

`Set-LogLevelPreference` writes `$global:WarningPreference`,
`$global:InformationPreference`, `$global:VerbosePreference`,
`$global:DebugPreference`, and (at Verbose+) `$global:ProgressPreference`.
It deliberately does NOT touch `$ErrorActionPreference`. Errors must
stay visible at every level; and PowerShell's `-ErrorAction Stop`
semantics depend on the inherited default — silencing the preference
would suppress the throw-on-error contract that many `try/catch`
blocks rely on.

## Why `ProgressPreference` collapses at Verbose+

`Write-Progress` overwrites the bottom line of the terminal. At Verbose
or Debug the per-poll OCR text would scroll past and the progress bar
would replay each tick, making the transcript unreadable. The cascade
silences it past Information so operators running with `-logLevel
Verbose` see clean, line-oriented output.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.10

Back to [Yuruna](../README.md)
