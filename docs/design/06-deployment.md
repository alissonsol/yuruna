# Deployment topology

> One sentence: how the parts run and talk over the network when fully
> deployed, grouped into seven network nodes.

See [Design overview](00-index.md) · [Yuruna Architecture](../architecture.md).

Derived from `test/Invoke-TestRunner.ps1`, the status/caching/stash start
scripts under `test/`, `automation/fetch-and-execute.sh`, the pool tier
(`test/pool/`, `test/extension/pool-aggregator`), and `test.config.yml`
(`statusService`, `networkStorage`, `pool`). Mermaid has no deployment-diagram
type, so each network node is a `subgraph`.

```mermaid
flowchart TD
    subgraph operator[Operator Workstation]
        cli[CLI: Add-AutomationToPath<br/>Set-* / Test-Runtime]
    end
    subgraph runnerhost[Test-Runner / Hypervisor Host]
        runner[Invoke-TestRunner]
        statussrv[Status server :8080<br/>/yuruna-repo /livecheck]
        provider[Host provider<br/>Hyper-V / KVM / UTM]
    end
    subgraph infravm[Infrastructure VMs]
        squid[Caching proxy<br/>squid :3128]
        stash[Stash service]
    end
    subgraph guestvm[Guest VMs under test]
        guest[fetch-and-execute.sh<br/>workload scripts]
    end
    subgraph pooltier[Pool Tier]
        aggregator[pool-aggregator + Grafana]
        nas[networkStorage pool NAS<br/>SMB share]
    end
    subgraph cloud[Target Cloud and Cluster]
        k8s[Kubernetes cluster]
        registry[Container registry]
    end
    subgraph external[External Sources]
        github[GitHub repos]
        mirrors[apt / dnf mirrors]
    end

    cli -->|deploy| cloud
    runner -->|create VM| provider
    provider --> guestvm
    guest -->|/yuruna-repo| statussrv
    guest -->|apt/dnf, images| squid
    squid -->|miss| mirrors
    guest -->|large artifacts| stash
    runner -->|git pull| github
    %% planned: pool tier — active only when pool.enabled / pool.networkReplicate
    runner -.->|replicate| nas
    runner -.->|push status| aggregator
    k8s -.- registry
```

`%% planned` The **Pool Tier** is gated by `pool.enabled` (default `false` in
`test.config.yml`); `pool.networkReplicate` (default `false`) governs the NAS
`replicate` edge but only takes effect once the pool is enabled. The dashed
edges to the pool tier and to the target cluster activate only when those tiers
are configured. A single machine commonly hosts both **Operator Workstation**
and **Test-Runner / Hypervisor Host**.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.03
