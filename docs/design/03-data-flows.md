# Data flows

> One sentence: the most frequent runtime data flows, one sequence diagram each.

See [Design overview](00-index.md) · [Yuruna Architecture](../architecture.md).

Derived from `automation/Set-{Resource,Component,Workload}.ps1`,
`test/modules/{Test.RunnerOuterLoop,Test.RunnerInnerLoop,Invoke-Sequence}.psm1`,
`test/modules/Test.Notify.psm1`, and `automation/fetch-and-execute.sh`.

## A. Three-phase deployment

```mermaid
sequenceDiagram
    actor Operator
    participant Engine as Set-* (automation)
    participant Tofu as OpenTofu
    participant Docker
    participant Registry
    participant Cluster as Helm / kubectl

    Operator->>Engine: Set-Resource [project] [cloud]
    Engine->>Tofu: init / plan / apply (resources.yml)
    Tofu-->>Engine: resources.output.yml (cluster, registry, IPs)
    Operator->>Engine: Set-Component [project] [cloud]
    Engine->>Docker: build + tag (components.yml)
    Docker->>Registry: push image
    Operator->>Engine: Set-Workload [project] [cloud]
    Engine->>Cluster: helm install / kubectl apply (workloads.yml)
    Cluster-->>Engine: release status
```

The operator runs the phases one by one; nothing chains them.
`resources.output.yml` is the hand-off: written by `Set-Resource` from
`tofu output -json`, layered into the environment by both later phases.
Each phase validates its YAML first (`Confirm-*List`), and `Set-Workload`
auto-runs `Test-Runtime.ps1` as pre-flight.

## B. Test cycle (one guest)

```mermaid
sequenceDiagram
    participant Outer as OuterLoop
    participant Inner as InnerRunner
    participant Host as Host contract
    participant Guest as Guest VM
    participant Status as Status server
    participant Notify

    Outer->>Outer: git pull, clear state, arm watchdog
    Outer->>Inner: spawn (guestSequence)
    loop per guest
        Inner->>Host: New-VM, Start-VM
        Host->>Guest: boot + cloud-init
        Inner->>Guest: Start-GuestOS (OCR/SSH sequence steps)
        Inner->>Guest: New-VM.Resource, Screenshots
        Inner->>Guest: Start-GuestWorkload (workload sequences)
        Guest-->>Inner: step pass/fail
        Inner->>Status: write current-action + cycle event
        Inner->>Host: Stop-VM, Remove-VM
    end
    Inner->>Notify: alert when failure gate reached
    Inner-->>Outer: exit code
    Note over Outer: exit 0 loops immediately, non-zero enters failure-pause
```

Step order per guest is the base plan in
`test/modules/Test.RunnerInnerLoop.psm1`: `New-VM` → `Start-VM` →
`Start-GuestOS` → `New-VM.Resource` → `Screenshots`
(`Invoke-ScreenshotTest`) → `Start-GuestWorkload` → teardown. The
notification gate (diagram D) lives in the inner runner.

## C. Guest repo / artifact fetch

```mermaid
sequenceDiagram
    participant Guest as fetch-and-execute.sh
    participant HostEnv as /etc/yuruna/host.env
    participant StatusSrv as Host status server
    participant Proxy as Caching proxy (squid)
    participant Upstream as GitHub / mirrors

    Guest->>HostEnv: read YURUNA_HOST_IP:PORT
    Guest->>StatusSrv: GET /livecheck
    alt host reachable
        Guest->>StatusSrv: GET /yuruna-repo/[path]
    else fallback
        Guest->>Upstream: GET raw.githubusercontent.com/...
    end
    Guest->>Proxy: apt/dnf, image pulls
    Proxy->>Upstream: miss → fetch + cache
    Upstream-->>Proxy: payload
    Proxy-->>Guest: cached payload
```

## D. Failure diagnostics & alert

```mermaid
sequenceDiagram
    participant Inner as InnerRunner
    participant Diag as Save-GuestDiagnostic
    participant Guest as Guest VM
    participant HostDiag as Get-SystemDiagnostic
    participant Status as Status server
    participant Notify

    Inner->>Diag: step failed
    Diag->>Guest: Wait-SshReady, collect logs/screenshot
    Diag-->>Status: failure_*.txt / .png
    Inner->>HostDiag: host.diagnostics.txt
    Inner->>Status: last_failure.json + cycle event
    Inner->>Notify: alert after failuresBeforeAlert
```

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.10
