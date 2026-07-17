# Yuruna Architecture

Cross-cutting concepts referenced by every README. Other docs link here
rather than repeat.

## Three capabilities

1. **Reproducible host/guest VM setups** — provision development
   workspaces as VMs on macOS UTM, Windows Hyper-V, or Ubuntu
   KVM/libvirt. See [Hosts](../host/README.md) and
   [Guests](../guest/README.md).
2. **Kubernetes deployment** — three-phase model targeting localhost,
   AWS, or Azure with the same project layout (GCP is planned, not yet
   available). See
   [Kubernetes Deployment](kubernetes.md).
3. **Test harness** — continuous VM creation + validation across hosts
   and guests, with status server, notifications, and extensible
   sequences. See [Test harness](test-harness.md).

## Three-phase deployment model

```
┌───────────┐    ┌────────────┐    ┌───────────┐
│ Resources │ => │ Components │ => │ Workloads │
│(OpenTofu) │    │  (Docker)  │    │  (Helm)   │
└───────────┘    └────────────┘    └───────────┘
```

Each phase reads its YAML from `config/<cloud>/` and passes outputs to the
next:

| Phase | File | Purpose |
|-------|------|---------|
| Resources  | `resources.yml`  | Provision clusters, registries, IPs |
| Components | `components.yml` | Build and push Docker images |
| Workloads  | `workloads.yml`  | Deploy Helm charts |

## CLI entry points

Run any of these from a project folder under `project/` (after
`./Add-AutomationToPath.ps1`):

```
Set-Resource.ps1  <project> <cloud>
Set-Component.ps1 <project> <cloud>
Set-Workload.ps1  <project> <cloud>
Test-Runtime.ps1
```

`<cloud>` is `localhost`, `aws`, or `azure` (`gcp` is planned, not yet
available). Cloud variants require
a one-time auth step (`az login`, `aws configure`, `gcloud auth …`) — see
[Yuruna Authentication](authentication.md). Syntax reference:
[Yuruna Syntax](syntax.md).

## Project layout

```
yuruna/
├── automation/         # Set-*, Test-*, Invoke-*, Get-* scripts and Yuruna.*.psm1 modules
├── global/resources/   # OpenTofu templates per cloud
├── install/            # Per-host installer entry points (curl|bash, irm|iex)
├── project/            # Project under verification (cloned from test.config.yml's repositories.projectUrl each cycle)
├── docs/               # User-facing documentation
├── host/               # Per-hypervisor VM provisioning (macos.utm, windows.hyper-v, ubuntu.kvm)
├── guest/              # Workload scripts run inside a running guest
└── test/               # Continuous test harness
```

## Reusable conventions

### `YurunaCacheContent` cache-buster

One-liners (`irm …$nc | iex`, `fetch-and-execute.sh`) read
`YurunaCacheContent`. Unset → cacheable URL. Set to a unique string
(typically a datetime) → fresh fetch. Full setup, persistence (`setx`,
shell profiles), and the companion Squid VM:
[Caching](caching.md).

### Cost warning

Cloud resources incur charges. Always [cleanup](cleanup.md) what
you stop using.

### Windows line endings

Before cloning on Windows:
`git config --global core.autocrlf input`

### Per-phase `*.stderr.log` catalog

Each automation phase writes a full stdout+stderr capture of its tool
calls into `.yuruna/<env>/...` with a `=== <cmd> (exit=N) ===` header,
plus a `*.rc` sidecar holding the LAST observed exit code:

| File | Producer | Captures |
|------|----------|----------|
| `tofu.stderr.log`    | Yuruna.Resource.psm1 (`Set-Resource`)           | `tofu init / plan / apply` |
| `helm.stderr.log`    | Yuruna.Workload.psm1                            | Chart install + ad-hoc `helm:` deployments |
| `kubectl.stderr.log` | Yuruna.Workload.psm1                            | `kubectl:` deployments |
| `shell.stderr.log`   | Yuruna.Workload.psm1                            | `shell:` deployments |
| `docker.stderr.log`  | Yuruna.Component.psm1                           | Build / tag / push pipeline |

`Get-SystemDiagnostic.ps1` cross-checks `*.rc` against in-cluster
state to flag a silent success-without-effect (e.g. `helm.rc=0` but
no helm releases). The scan uses `-Force` so recursion descends into
the dot-prefixed `.yuruna/` working folders; without `-Force`,
helm/kubectl stderr files are hidden on Linux and a real failure
shows as "no `*.stderr.log` — no phase has produced output" even when
a 60-char-truncated excerpt of the error sits in the earlier "Errors,
failures and warnings" section.

## License

Scripts and examples are provided "as is". See [Yuruna License](../LICENSE.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.17

Back to [Yuruna](../README.md)
