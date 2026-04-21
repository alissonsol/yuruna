# Yuruna Architecture

Cross-cutting concepts referenced by every README in this repo. Individual
docs may link here rather than repeat the material.

## Three capabilities

1. **Virtual Development Environment (VDE)** — reproducible workspaces built
   as VMs on macOS UTM or Windows Hyper-V. See [virtual/CODE.md](virtual/CODE.md).
2. **Kubernetes deployment** — a three-phase model that targets localhost,
   AWS, Azure, or GCP with the same project layout. See
   [docs/kubernetes.md](docs/kubernetes.md).
3. **Test harness** — continuous VDE creation + validation across hosts and
   guests, with status server, notifications, and extensible sequences. See
   [test/CODE.md](test/CODE.md).

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

Run any of these from the `examples/` or `projects/` folder (after
`./Add-AutomationToPath.ps1`):

```powershell
Set-Resource.ps1  <project> <cloud>
Set-Component.ps1 <project> <cloud>
Set-Workload.ps1  <project> <cloud>
Test-Runtime.ps1
```

`<cloud>` is `localhost`, `aws`, `azure`, or `gcp`. Cloud variants require
a one-time auth step (`az login`, `aws configure`, `gcloud auth …`) — see
[docs/authenticate.md](docs/authenticate.md). Syntax reference:
[docs/syntax.md](docs/syntax.md).

## Project layout

```text
yuruna/
├── automation/         # Set-*, Test-*, yuruna-* PowerShell modules
├── global/resources/   # OpenTofu templates per cloud
├── examples/           # Reference projects (website)
├── projects/           # Your projects (template/ as scaffold)
├── docs/               # User-facing documentation
├── virtual/            # VDE host/guest scripts and docs
└── test/               # Continuous test harness
```

## Reusable conventions

### `YurunaCacheContent` cache-buster

One-liners (`irm …$nc | iex`, `fetch-and-execute.sh`) read the
`YurunaCacheContent` env var. Unset → cacheable URL. Set to a unique
string (typically a datetime) → fresh fetch. Full setup, persistence
(`setx`, shell profiles), and the companion Squid VM are in
[docs/caching.md](docs/caching.md).

### Cost warning

Cloud resources incur charges. Always [clean up](docs/cleanup.md) what
you stop using.

### Windows line endings

Before cloning on Windows:
`git config --global core.autocrlf input`

### License

Scripts and examples are provided "as is". See [LICENSE.md](LICENSE.md).

---

Copyright (c) 2019-2026 by Alisson Sol et al.
