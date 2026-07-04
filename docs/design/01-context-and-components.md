# Level-1 components

> One sentence: the seven top-level building blocks of Yuruna and how they
> connect. Drill into any block in [02-component-breakdown.md](02-component-breakdown.md).

See [Design overview](00-index.md) · [Yuruna Architecture](../architecture.md).

Derived from the repository layout: `automation/`, `host/`, `guest/`,
`install/`, `test/`, `global/` (yuruna) and the `yuruna-project` data repo.
`tools/` (release-pin updater + git hooks) is folded into **Deploy Engine**.

```mermaid
flowchart TD
    installers[Installers<br/>install/]
    host-provisioning[Host Provisioning<br/>host/]
    guest-workloads[Guest Workloads<br/>guest/]
    test-harness[Test Harness<br/>test/]
    deploy-engine[Deploy Engine<br/>automation/]
    project-data[Project & Global Data<br/>yuruna-project, global/]
    external-services[External Services<br/>clouds, registries, GitHub, OCR]

    installers -->|bootstrap host| host-provisioning
    test-harness -->|drives cycles| host-provisioning
    host-provisioning -->|create VM, run| guest-workloads
    guest-workloads -->|fetch repo / artifacts| test-harness
    test-harness -->|invoke phases| deploy-engine
    deploy-engine -->|read YAML| project-data
    test-harness -->|read config| project-data
    deploy-engine -->|provision / push / deploy| external-services
    guest-workloads -->|apt/dnf, images| external-services
```

| Component | Root | Responsibility |
|---|---|---|
| Installers | `install/` | One-shot per-host bootstrap (`irm\|iex`, `curl\|bash`). |
| Host Provisioning | `host/` | Create/start/stop VMs on Hyper-V, KVM, UTM. |
| Guest Workloads | `guest/` | Scripts that run **inside** a booted guest. |
| Test Harness | `test/` | Continuous VM create + validate loop, status, pool. |
| Deploy Engine | `automation/` | Three-phase Resources→Components→Workloads + validation. |
| Project & Global Data | `yuruna-project/`, `global/` | Per-project YAML, charts, OpenTofu templates, vault. |
| External Services | — | Clouds, container registries, k8s, GitHub, OCR, mirrors. |

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.03
