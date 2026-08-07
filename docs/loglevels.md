# Log-level cascade

Every Yuruna entry point shares one resolved log level that gates which
PowerShell streams reach the terminal AND propagates to every child
pwsh / per-cycle inner runner / sequence engine through `$env:YURUNA_LOG_LEVEL`.

The canonical implementation lives in
[`test/modules/Test.LogLevel.psm1`](../test/modules/Test.LogLevel.psm1).
This module is the single source of truth for the rank table +
preference cascade, so it is not duplicated across the 60+ scripts and
runner files that depend on it.

## Levels

| Rank | Level         | Why a level exists |
|------|---------------|--------------------|
| 1    | `Error`       | Highest priority. Always visible. |
| 2    | `Warning`     | Operator-actionable problems that did NOT fail the cycle. |
| 3    | `Information` | Default. Step-level progress, banners, PASS/WARN/FAIL rows. |
| 4    | `Verbose`     | What each OCR engine reads on every `waitForText` poll — the operator-relevant signal when a step is hanging — plus child-process command lines. |
| 5    | `Debug`       | Wire-protocol traces (VNC bytes, scancode bursts). |

Each level shows itself **and every higher-priority level**. `-logLevel
Warning` shows Error + Warning; `-logLevel Verbose` shows everything
except Debug.

## Three-state resolution

1. **Command-line override** — `-logLevel Verbose` on
   `Invoke-TestRunner.ps1` / `Invoke-TestRunnerInnerLoop.ps1` /
   `Invoke-TestSequence.ps1` / `install/setup.ps1`.
2. **`logLevel:` in `test.config.yml`** — hot-reloadable; the inner
   runner re-resolves on every `Sync-RuntimeConfig`, so an operator can
   edit the YAML mid-cycle and the next step picks it up.
3. **Default `Information`** — invalid values fall back here with a
   one-line warning, so a YAML typo does not silently silence the
   transcript.

The default differs by entry point. The three-phase scripts
(`Set-Resource.ps1` / `Set-Component.ps1` / `Set-Workload.ps1`),
`Test-Configuration.ps1` and `Invoke-Clear.ps1` default to `Error` —
they run interactively, where anything above an error is noise.
Only the test runner (`Invoke-TestRunner.ps1`) and `install/setup.ps1`
default to `Information`: their transcripts are the record of a long
run nobody watched all of.

The cmdline override wins over a hot-reload: start a runner at
`Information` and a config edit to `Warning` will not promote it. Stop
the runner and restart without `-logLevel` to release the override.

## Propagation across pwsh boundaries

Child pwsh processes (the outer → inner spawn, sequence engine sub-
processes, `Invoke-TestSequence` standalone) inherit `$env:YURUNA_LOG_LEVEL`
but NOT PowerShell preference variables. The env var IS the propagation
channel. The cascade module exports `Use-LogLevelFromEnv`; every child
script that should honor the parent's level calls it at the top:

```
# Honor logLevel from Invoke-TestRunner.ps1 via $env:YURUNA_LOG_LEVEL. See docs/loglevels.md.
$_logLevelMod = Join-Path $PSScriptRoot '../../../test/modules/Test.LogLevel.psm1'
if (-not (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) -and (Test-Path $_logLevelMod)) {
    Import-Module $_logLevelMod -Global
}
if (Get-Command Use-LogLevelFromEnv -ErrorAction SilentlyContinue) { Use-LogLevelFromEnv }
```

This idiom keeps each
`host/<platform>/guest.<x>/{Get-Image,New-VM}.ps1` from carrying an
11-line copy-paste rank table.

**Load only when absent, never `-Force`.** Some of these scripts are
run IN-PROCESS by their caller (`Start-CachingProxyServiceVM.ps1`
calls `Get-Image.ps1` and `New-VM.ps1` with the call operator), and a
forced re-import there tears down and rebuilds the module instance the
caller is already using — taking whatever that instance keeps in module
scope with it, and narrating a dozen import lines into the transcript at
Verbose (`feedback_module_force_import_evicts_global`). The tradeoff is
that an edit to the module mid-session is not picked up, which is
acceptable for a leaf script that only reads the level. The two values
that must outlive such a re-import — the child transcript's path/owner
pid and the caller's captured `ProgressPreference` — are anchored in the
runspace `$global:` scope rather than in module scope for the same
reason.

### A setup run is the deepest chain of it

`install/setup.ps1` resolves the level, then starts a dozen repo scripts,
each in its own pwsh, and some of those start the per-guest builders:

```
setup.ps1 -logLevel Debug
  └─ test/Start-CachingProxyServiceVM.ps1        Use-LogLevelFromEnv
       └─ host/<platform>/guest.<x>/New-VM.ps1   Use-LogLevelFromEnv
```

Nothing is passed on the command line down that chain — the environment
variable is inherited at each hop, so every script that calls
`Use-LogLevelFromEnv` lands on the level the operator asked for. The one
hop it does NOT survive is the Windows elevated relaunch: `-Verb RunAs`
builds the process through the AppInfo service, which does not carry the
parent's environment, so `setup.ps1` passes the resolved level to its own
elevated copy as an argument. `Test.SetupLogLevel.Tests.ps1` guards both
halves.

A script started this way applies the level AFTER its own preference
assignments, and where it also assigns `$InformationPreference` at
script scope it re-reads that variable from the global the cascade
writes. A script-scoped assignment shadows the global for the rest of
the file, so without the re-read `-logLevel Error` would quiet every
child but not the lines of the script that set it.

## Why `$ErrorActionPreference` stays at `Continue`

`Set-LogLevelPreference` writes `$global:WarningPreference`,
`$global:InformationPreference`, `$global:VerbosePreference`,
`$global:DebugPreference`, and (at Verbose+) `$global:ProgressPreference`.
It deliberately does NOT touch `$ErrorActionPreference`. Errors must
stay visible at every level, and PowerShell's `-ErrorAction Stop`
semantics depend on the inherited default — silencing the preference
would suppress the throw-on-error contract that many `try/catch`
blocks rely on.

## Why `ProgressPreference` collapses at Verbose+

`Write-Progress` overwrites the bottom line of the terminal. At Verbose
or Debug the per-poll OCR text would scroll past and the progress bar
would replay each tick, making the transcript unreadable. The cascade
silences it past Information so `-logLevel Verbose` gives clean,
line-oriented output.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.07

Back to [Yuruna](../README.md)
