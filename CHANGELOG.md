# Changelog

Yuruna uses [Calendar Versioning](https://calver.org/): `YYYY.MM.DD`.
Tags are cut from the `main` branch; entries below summarize each
tagged release.

## 2026.05.29

- **Reliability and resilience review.** Review of error handling,
  standardization of the extensibility, host contract, and test
  modules for host conditions. Split several large monolithic
  modules into more focused modules to ease maintenance. Adds the
  runner state machine ([test/modules/Test.RunnerState.psm1](test/modules/Test.RunnerState.psm1)),
  snapshot manifest sidecars
  ([test/modules/Test.SnapshotManifest.psm1](test/modules/Test.SnapshotManifest.psm1))
  and the remediation dispatcher
  ([test/modules/Test.Remediation.psm1](test/modules/Test.Remediation.psm1)).
- **Stash service.** New `stash-service` extension area for receiving
  SCP'd guest artifacts (diagnostic bundles, screenshots) into a
  host-side stash. PowerShell wrapper at
  [test/extension/stash-service/](test/extension/stash-service/);
  Go daemon under
  [test/extension/stash-service/server/](test/extension/stash-service/server/).
  Driven by [test/Start-StashService.ps1](test/Start-StashService.ps1) /
  [test/Stop-StashService.ps1](test/Stop-StashService.ps1).
- **OCR engine probes.** New
  [test/Test-WinRtOcr.ps1](test/Test-WinRtOcr.ps1) and
  [test/Test-TesseractOcr.ps1](test/Test-TesseractOcr.ps1) smoke-test
  the two registered OCR engines independently of a full cycle.
- **Bootstrap ASCII gate.** New
  [test/Test-AsciiNoBom.ps1](test/Test-AsciiNoBom.ps1) verifies that
  [install/windows.hyper-v.ps1](install/windows.hyper-v.ps1) stays
  pure ASCII with no BOM (a BOM there breaks PS 5.1 `irm | iex` at
  the `param()` line).
- **Concurrent-write safety for `status.json`.** The runner and the
  status-server process both flush `status.json`; a shared fixed
  `"$file.tmp"` temp name let one process's atomic rename clobber the
  other's half-written temp. Every atomic writer (the canonical
  `Write-YurunaStateFile`, `Write-StatusJson`, and the status server's
  inline writers) now uses a per-writer `PID+GUID` temp name, so the
  temp-write + rename stays collision-free across processes.
- **Atomic `last_failure.json`.** Both the normal and crash failure
  paths now write `last_failure.json` through `Write-YurunaStateFile`
  instead of a raw `Set-Content`, closing the window where a remediator
  or the status UI could read a truncated record.
- **Jittered backoff between `retry` attempts.** The `retry` verb
  re-ran inner steps with no delay, exhausting all attempts in
  milliseconds and giving transient faults no time to clear. It now
  waits `Get-PollDelay` (jittered, exponentially capped) between
  attempts and refreshes the step heartbeat across the wait so the
  watchdog stays aligned.

## 2026.05.22

- **Username cascade + corporate identity mapping.** New
  `test/status/extension/authentication/users.yml` (bootstrapped from a
  committed template) maps logical sequence-level usernames onto
  corporate identities (AD / Entra / ...) plus the vault keys that
  hold their passwords.
- **`test/status/` reorganization (breaking layout change).** All
  harness runtime state now lives under one tree with at most two
  subfolder levels before data.
- **License**: [LICENSE.md](LICENSE.md) is now titled "Yuruna License"
  (based on the MIT License) and adds a plain-language "No Warranty /
  'As Is'" restatement plus an explicit "Administrator Risk Warning"
  section covering scripts that require elevated/root privileges.

## 2026.05.15

First publicly tracked release. Highlights since the project's
internal history:

- **Three host platforms** with parity (macOS UTM, Windows Hyper-V,
  Ubuntu KVM/libvirt). Single-line installers per host under
  [install/](install/).
- **Three guest OS templates** (Amazon Linux 2023, Ubuntu Server 24.04,
  Windows 11) plus a `macos.26` Apple-Silicon guest on UTM.
- **Test harness** with GUI (VNC/Hyper-V keystroke) and SSH cycles,
  per-cycle authentication vault (code in
  [test/extension/authentication/](test/extension/authentication/);
  runtime vault.yml at `test/status/extension/authentication/vault.yml`,
  created on first use), Resend-based notifications (code in
  [test/extension/notification/](test/extension/notification/);
  runtime transports.yml at
  `test/status/extension/notification/transports.yml`, created on
  first use), and status server.
- **Caching proxy VM** for fast image/package re-runs; see
  [Caching](docs/caching.md) and
  [test/extension/caching-proxy-parser/](test/extension/caching-proxy-parser/).
- **Cross-host diagnostics** via
  [`automation/Get-SystemDiagnostic.ps1`](automation/Get-SystemDiagnostic.ps1)
  and end-of-cycle save-diagnostic.
- **Documentation pass**: terminology in
  [Yuruna definitions](docs/definition.md), incident rationale in
  [Yuruna memory](docs/memory.md), VM config gotchas in
  [vmconfig topic reference](docs/vmconfig.md), and short-link redirector
  at [yuruna.link](https://yuruna.link).

Back to [Yuruna](README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
