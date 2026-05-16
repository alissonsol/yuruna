# Yuruna Architecture

Cross-cutting concepts referenced by every README. Other docs link here
rather than repeat.

## Three capabilities

1. **Reproducible host/guest VM setups** — provision development
   workspaces as VMs on macOS UTM, Windows Hyper-V, or Ubuntu
   KVM/libvirt. See [Hosts](../host/README.md) and
   [Guests](../guest/README.md).
2. **Kubernetes deployment** — three-phase model targeting localhost,
   AWS, Azure, or GCP with the same project layout. See
   [Kubernetes Deployment](kubernetes.md).
3. **Test harness** — continuous VM creation + validation across hosts
   and guests, with status server, notifications, and extensible
   sequences. See [Test harness](../test/CODE.md).

## Three-phase deployment model

```text
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

```powershell
Set-Resource.ps1  <project> <cloud>
Set-Component.ps1 <project> <cloud>
Set-Workload.ps1  <project> <cloud>
Test-Runtime.ps1
```

`<cloud>` is `localhost`, `aws`, `azure`, or `gcp`. Cloud variants require
a one-time auth step (`az login`, `aws configure`, `gcloud auth …`) — see
[Yuruna Authentication](authenticate.md). Syntax reference:
[Yuruna Syntax](syntax.md).

## Project layout

```text
yuruna/
├── automation/         # Set-*, Test-*, yuruna-* PowerShell modules
├── global/resources/   # OpenTofu templates per cloud
├── project/            # Project under verification (cloned from test.config.yml's repositories.projectUrl each cycle)
│   ├── example/        # Reference project (website)
│   ├── template/       # Scaffold for a new project
│   └── test/           # Cycle-level test sequences (test.sequence.yml)
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

## License

Scripts and examples are provided "as is". See [MIT License](../LICENSE.md).

Back to [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
