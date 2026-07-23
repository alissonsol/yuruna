# Deployment topology

> One sentence: how the parts run and talk over the network when fully
> deployed, grouped into seven network nodes.

See [Design overview](00-index.md) · [Yuruna Architecture](../architecture.md).

Derived from `test/Invoke-TestRunner.ps1`, the
`test/Start-{StatusService,CachingProxy,StashServer,HostConfigService}.ps1`
scripts, `host/vmconfig/caching-proxy.base.user-data`,
`test/extension/{pool-aggregator,stash-service}`, and
`test.config.yml.template` (`statusService`, `configService`,
`networkStorage`, `pool`). Mermaid has no deployment-diagram type, so each
network node is a `subgraph`.

```mermaid
flowchart TD
    subgraph operator[Operator Workstation]
        cli[CLI: Add-AutomationToPath<br/>Set-* / Test-Runtime]
    end
    subgraph runnerhost[Test-Runner / Hypervisor Host]
        runner[Invoke-TestRunner]
        statussrv[Status server :8080<br/>/yuruna-repo /livecheck /control]
        hostcfg[Host config service :8443<br/>mTLS NAS credentials]
        provider[Host provider<br/>Hyper-V / KVM / UTM]
    end
    subgraph infravm[Infrastructure VMs]
        squid[Caching proxy VM<br/>squid :3128 :3129, zot :5000<br/>Grafana :3000, parser :9302]
        stash[Stash service VM<br/>scp :22, UI :80]
    end
    subgraph guestvm[Guest VMs under test]
        guest[fetch-and-execute.sh<br/>workload scripts]
    end
    subgraph pooltier[Pool Tier]
        aggregator[pool-aggregator :9400<br/>+ Loki]
        nas[networkStorage NAS<br/>pool + stash shares]
    end
    subgraph cloud[Target Cloud and Cluster]
        k8s[Kubernetes cluster]
        registry[Container registry]
    end
    subgraph external[External Sources]
        github[GitHub repos]
        mirrors[apt / dnf mirrors, images]
    end

    cli -->|deploy| cloud
    runner -->|create VM| provider
    provider --> guestvm
    guest -->|/yuruna-repo| statussrv
    guest -->|apt, image pulls| squid
    squid -->|miss| mirrors
    guest -->|large artifacts| stash
    runner -->|git pull| github
    %% planned/optional: pool tier active only when pool.enabled / networkStorage set
    stash -.->|presence beacon| aggregator
    stash -.->|files| nas
    hostcfg -.->|NAS creds for pool hosts| nas
    runner -.->|cycle NDJSON /ingest| aggregator
    runner -.->|replicate| nas
    k8s -.- registry
```

The caching-proxy VM co-locates squid (HTTP proxy :3128, ssl-bump :3129,
CA cert served on :80), the zot OCI pull-through cache (:5000), Grafana
(:3000), and the Go access-log parser (:9302); :3128 is the only port the
runner hard-depends on. The stash VM's SSH sink is reached through an
8022→22 port remap when NAT'd, and its presence beacon announces the host
to the pool-aggregator. The host config service (`configService`, default
port 8443) hands NAS credentials to pool hosts over mTLS.

`%% planned` The **Pool Tier** is gated by `pool.enabled` (default `false`
in `test.config.yml`); `pool.networkReplicate` (default `false`) governs
the NAS `replicate` edge, and the `networkStorage` pool/stash paths are
empty by default. The dashed edges activate only when those tiers are
configured. A single machine commonly hosts both **Operator Workstation**
and **Test-Runner / Hypervisor Host**.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.22
