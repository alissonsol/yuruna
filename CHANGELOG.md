# Changelog

Yuruna uses [Calendar Versioning](https://calver.org/): `YYYY.MM.DD`.
Tags are cut from the `main` branch; entries below summarize each
tagged release.

## 2026.05.15

First publicly tracked release. Highlights since the project's
internal history:

- **Three host platforms** with parity (macOS UTM, Windows Hyper-V,
  Ubuntu KVM/libvirt). Single-line installers per host under
  [install/](install/).
- **Three guest OS templates** (Amazon Linux, Ubuntu Server,
  Windows 11) plus a `macos.26` Apple-Silicon guest on UTM.
- **Test harness** with GUI (VNC/Hyper-V keystroke) and SSH cycles,
  per-cycle authentication vault under
  [test/extension/authentication/](test/extension/authentication/),
  Resend-based notifications under
  [test/extension/notification/](test/extension/notification/), and
  status server.
- **Caching proxy VM** for fast image/package re-runs; see
  [docs/caching.md](docs/caching.md) and
  [test/extension/caching-proxy-parser/](test/extension/caching-proxy-parser/).
- **Cross-host diagnostics** via
  [`automation/Get-SystemDiagnostic.ps1`](automation/Get-SystemDiagnostic.ps1)
  and end-of-cycle save-diagnostic.
- **Documentation pass**: terminology in
  [docs/definition.md](docs/definition.md), incident rationale in
  [docs/memory.md](docs/memory.md), VM config gotchas in
  [host/vmconfig.md](host/vmconfig.md), and short-link redirector
  at [yuruna.link](https://yuruna.link).

Back to [Yuruna](README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
