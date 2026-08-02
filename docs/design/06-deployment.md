# Deployment topology

> One sentence: how the parts run and talk over the network when fully
> deployed, grouped into seven network nodes.

See [Design overview](00-index.md) · [Yuruna Architecture](../architecture.md).

Derived from `test/Invoke-TestRunner.ps1`, the
`test/Start-{StatusService,ConfigService}.ps1` and
`test/Start-{CachingProxyServiceVM,StashServiceVM,PoolControlServiceVM}.ps1` scripts,
`host/vmconfig/{caching-proxy-service,stash-service,pool-control-service}.base.user-data`,
`test/extension/{pool-aggregator-service,pool-control-service,stash-service}`,
`test/modules/{Test.PoolSync,Test.PoolStorage,Test.VMUtility}.psm1`, and
`test/test.config.yml.template`. Mermaid has no deployment-diagram type, so
each network node is a `subgraph`.

```mermaid
flowchart TD
    subgraph operator[Operator Workstation]
        cli[CLI: Add-AutomationToPath<br/>Set-* / pool + lab admin]
    end
    subgraph runnerhost[Test-Runner / Hypervisor Host]
        runner[Invoke-TestRunner]
        statussrv[Status service :8080<br/>/yuruna-repo /livecheck /control]
        hostcfg[Host config service :8443<br/>mTLS NAS credentials]
        provider[Host provider<br/>Hyper-V / KVM / UTM]
    end
    subgraph infravm[Infrastructure VMs]
        squid[Caching-proxy service VM<br/>squid :3128 :3129, zot :5000<br/>Apache :80, Grafana :3000<br/>parser :9302, aggregator :9400]
        stash[Stash service VM<br/>sshd :22, UI :80]
    end
    subgraph guestvm[Guest VMs under test]
        guest[fetch-and-execute.sh<br/>workload scripts]
    end
    subgraph pooltier[Pool Tier]
        poolctl[Pool-control service VM<br/>UI + API :80]
        nas[networkStorage NAS<br/>pool + stash + pool-intent.git]
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
    guest -->|/livecheck /yuruna-repo| statussrv
    guest -->|apt, image pulls| squid
    squid -->|miss| mirrors
    squid -->|/yuruna-repo build source| statussrv
    runner -->|git pull| github
    %% planned/optional: each dashed edge has its own config gate - see prose
    squid -.->|mTLS /v1/nas/pool :8443| hostcfg
    squid -.->|CIFS| nas
    squid -.->|probe /runtime/status.json :8080| statussrv
    runner -.->|clone pool-intent.git :80| squid
    runner -.->|cycle NDJSON /ingest :9400| squid
    runner -.->|replicate| nas
    guest -.->|large artifacts scp :22| stash
    stash -.->|files| nas
    stash -.->|presence beacon| squid
    poolctl -.->|intent + state CIFS| nas
    poolctl -.->|presence beacon| squid
    cli -.->|operator UI :80| poolctl
    cli -.->|admin CLIs write intent| nas
    k8s -.- registry
```

**The caching-proxy-service VM is the busiest box.** It co-locates squid (HTTP proxy
:3128, ssl-bump :3129, plus PROXY-protocol variants :3138/:3139 that macOS
maps host→VM), the zot OCI pull-through cache (:5000), Apache (:80), Grafana
(:3000), the Go access-log parser (:9302), the **pool-aggregator-service** (:9400) and
a loopback-only Loki (127.0.0.1:3100, reachable only through Grafana). Only
:3128 is a hard runner dependency. Apache :80 serves the CA certificates,
`/squid-meta`, `/ypool-nas-status`, and the read-only `/pool-intent.git`
alias.

**Two edges run opposite to the obvious direction.** The cache VM is the
*client* of the config service: its cloud-init curls
`https://<san>:8443/v1/nas/pool` with `--cacert/--cert/--key` and writes the
CIFS credential at runtime, so a rotated NAS password propagates without a
rebuild. `Start-CachingProxyServiceVM.ps1` refuses to build the VM when
`configService` is enabled but not accepting on :8443. The stash and
pool-control-service VMs do **not** use this path — their CIFS credentials are baked
into their cloud-init seeds, and `/v1/nas/stash` is served but never called.
Likewise, the pool-aggregator-service's primary data path is a **pull**: it harvests
IPs from the squid access log and probes each one's status service on :8080 for
`/runtime/status.json`, then fetches `host.registration.json`,
`cycle.events.ndjson` and `/yuruna-repo/VERSION`. The `/ingest` push is a
supplement.

**The pool-intent store lives on the NAS**, not on the pool-control-service VM:
`pool-intent.git` sits under the pool share, the cache VM's Apache serves it
read-only over :80, and each runner clones from there every cycle.
The pool-control service writes to the same bytes through its own CIFS mount. The
operator's admin CLIs also write the intent directly — the pool-control-service daemon
shelling out to those same CLIs server-side is an internal detail, not an
operator-to-daemon call.

**All three infra VMs bootstrap from the deploying host's status service**:
each seed reads `/etc/yuruna/host.env` and probes `/livecheck` first. They
differ in what they pull — the cache VM fetches per-file Go source from
`/yuruna-repo`, while the stash and pool-control-service VMs pull the whole framework
as `/yuruna-archive.tar.gz`. That is why the launchers must start the status
server before creating the VM. Only one edge is drawn to keep the diagram
readable.

**Ports and remaps.** The 8022→22 remap belongs to the **caching-proxy-service** VM
(its SSH jump-host access); the stash-service VM's SSH sink is reached directly on
port 22, with the guest disabling the OS sshd to free it. On Windows the cache
VM is exposed through kernel `netsh interface portproxy` plus firewall rules
with no host process; on macOS `host/macos.utm/Start-CachingProxyServiceForwarder.ps1`
is a real long-lived host process, and it prepends a HAProxy PROXY v1 header
(host :3128/:3129 → VM :3138/:3139, the `require-proxy-header` listeners) so
squid still logs the real client IP rather than the host's NAT-side one.

The client-IP limitation belongs to the **Linux KVM NAT fallback**: there
`systemd-socket-proxyd` re-originates every connection from the host, so squid
records one client IP for the whole LAN, the pool-aggregator-service discovers no
hosts, and the pool dashboard shows "No data". Caching still works on that
path; the multi-host pool view needs the cache VM **bridged**, which is why
the UTM and Hyper-V dashboards populate.
`Start-PoolControlServiceVM.ps1 -HostSideProof` adds a third listener on the runner
host (:8090, deliberately clear of :8080) and needs a local `go` toolchain.

`%% planned` **Each dashed edge has its own gate — there is no single pool
switch.** `pool.enabled` (default `false`) gates only the pool-intent pull.
The `/ingest` push is gated on a stored `lab-auth-token` plus a reachable
proxy; the NAS `replicate` edge on `pool.networkReplicate` (default `false`);
the stash tier on the three `networkStorage.stash*` keys (empty by default).
Neither `Start-PoolControlServiceVM.ps1` nor `Start-CachingProxyServiceVM.ps1` consults
`pool.enabled` at all — the VMs are brought up by their own launchers
regardless. A single machine commonly hosts both **Operator Workstation** and
**Test-Runner / Hypervisor Host**.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.02
