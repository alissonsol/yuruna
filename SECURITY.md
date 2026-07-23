# Yuruna Security Policy

Yuruna provisions VMs, deploys workloads to Kubernetes, and runs a
test harness across host/guest combinations. This policy covers how
to report vulnerabilities and the security expectations that come
with the project's [Yuruna License](LICENSE.md).

## Supported versions

Yuruna uses [Calendar Versioning](https://calver.org/) (`YYYY.MM.DD`,
see [Changelog](CHANGELOG.md)). Security fixes land on `main` and
are picked up by the next tagged release; older tags are not
patched. Run the latest release before reporting.

## Reporting a vulnerability

Please **do not** open a public GitHub issue for suspected
vulnerabilities. Use one of:

- **Preferred** — GitHub's [private vulnerability reporting](https://github.com/alissonsol/yuruna/security/advisories/new)
  on the `alissonsol/yuruna` repository.
- **Email** — [security@yuruna.dev](mailto:security@yuruna.dev),
  or [contrib@yuruna.dev](mailto:contrib@yuruna.dev) as fallback.

Include: affected files or scripts, host/guest platform
([macOS UTM](host/macos.utm/README.md),
[Windows Hyper-V](host/windows.hyper-v/README.md),
[Ubuntu KVM/libvirt](host/ubuntu.kvm/README.md)),
reproduction steps, and any logs from
`automation/Get-SystemDiagnostic.ps1` if relevant. Expect an initial
acknowledgement within a few working days.

## Scope

In scope:

- Scripts and modules under this repository.
- [Installer entry points](install/README.md) executed via `curl | bash`
  / `irm | iex` from `raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/`.
- Cloud-init `user-data` and "fetch-and-execute" patterns documented
  in [Yuruna Contributor Guidance](CONTRIBUTING.md) — these download from `main`
  at VM-creation time.
- Default configurations shipped with the
  [test harness](test/README.md) and
  [caching proxy](docs/caching.md).

Out of scope:

- Upstream components (Hyper-V, UTM, KVM/libvirt, Kubernetes,
  Docker, OpenTofu, container images, Linux/Windows guests).
  Report those to their respective projects.
- Findings that require local administrator/root on the host running
  Yuruna — Yuruna assumes the operator already has that privilege.
- Anything inside an example workload under `project/` (cloned from
  [yuruna-project](https://github.com/alissonsol/yuruna-project))
  beyond what is documented as supported.

## Operator responsibilities

Yuruna's design assumes the operator controls the host. Treat the
following as your responsibility, not the project's:

- **Credentials** — files matching `*.config.yml`,
  `transports.yml` (notification), and the per-cycle authentication
  vault under `test/status/extension/authentication/`
  hold secrets and are git-ignored. Never commit them.
- **Network exposure** — Kubernetes deployments, the status server,
  and the caching proxy bind to the host. Restrict ingress before
  running outside a trusted LAN.
- **Cloud cost and blast radius** — see the cost warning in
  [Yuruna ...](README.md) and [Yuruna Resources Clean Up](docs/cleanup.md).
- **Verifying fetched scripts** — installer one-liners and
  cloud-init pull from `main`. Pin to a commit SHA if you require
  reproducibility.

## Disclosure

Once a fix is merged and a release is tagged, the advisory is
published via GitHub Security Advisories. Reporters are credited
in [Contributors](CONTRIBUTING.md#contributors) on request.

## License reminder

Yuruna is provided "AS IS" under the [Yuruna License](LICENSE.md),
without warranty of any kind. This policy describes how the
maintainers handle reports; it does not extend the warranty or
liability terms of the license.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.22

Back to [Yuruna](README.md)
