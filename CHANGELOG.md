# Changelog

Yuruna uses [Calendar Versioning](https://calver.org/): `YYYY.MM.DD`.
Tags are cut from the `main` branch; entries below summarize each
tagged release.

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
