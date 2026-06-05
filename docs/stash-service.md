# Stash Service

The Yuruna Stash Service is a file-receiving service. Clients send
files to it using the standard `scp` client; the service stores those
files inside a Linux VM and indexes them for later retrieval through
an in-VM UI (planned, out of scope here).

Operationally, the Stash Service mirrors the existing
[caching proxy](caching-proxy.md): it lives in its own VM, is started
independently of other services, and provisions on top of an Ubuntu
Server image.

## Why a separate service VM

Test guests are stateless by design — every cycle recreates them
from the base image — so any diagnostic artifact a guest produces
(screenshots, system logs, memory dumps, crash captures) has to leave
the guest before the cycle teardown wipes the disk. The stash VM is
the persistent host-side store every guest can `scp` to. Running it
as its own VM (rather than as a host-side daemon) keeps two
properties: the stash does not compete for resources with the test
guests it serves, and a multi-cycle history survives even when the
test harness on the host is restarted or upgraded.

## Cross-host layout

| File / folder | Role |
|---|---|
| [`test/Start-StashService.ps1`](../test/Start-StashService.ps1) | Brings up the stash VM. Detects host type, dispatches to `host/<host>/guest.stash-service/New-VM.ps1`, and (UTM only) registers the bundle + starts via `utmctl`. |
| [`test/Stop-StashService.ps1`](../test/Stop-StashService.ps1) | Graceful stop of the stash VM. Does NOT delete the VM (no `Remove-StashService` cmdlet per [§2](#operational-model)). |
| `host/windows.hyper-v/guest.stash-service/` | Hyper-V per-host scripts: [Get-Image](../host/windows.hyper-v/guest.stash-service/Get-Image.ps1), [New-VM](../host/windows.hyper-v/guest.stash-service/New-VM.ps1), `vmconfig/{user-data,meta-data}`. |
| `host/ubuntu.kvm/guest.stash-service/` | KVM per-host scripts: [Get-Image](../host/ubuntu.kvm/guest.stash-service/Get-Image.ps1), [New-VM](../host/ubuntu.kvm/guest.stash-service/New-VM.ps1), `vmconfig/{user-data,meta-data}`. |
| `host/macos.utm/guest.stash-service/` | UTM per-host scripts: [Get-Image](../host/macos.utm/guest.stash-service/Get-Image.ps1), [New-VM](../host/macos.utm/guest.stash-service/New-VM.ps1), `config.plist.template`, `vmconfig/{user-data,meta-data}`. |
| [`test/extension/stash-service/`](../test/extension/stash-service/) | Pluggable extension area. Default provider exports `Get-StashServiceInfo`. Go daemon source lands under [`server/`](../test/extension/stash-service/server/) when it's written. |

## What v1 implements

Cloud-init brings the VM up to a state where `ssh yuruna@<vm-ip>` and
console login work — nothing more. Per the
[Q&A decision recorded during scoping](#scoping-decisions):
"cloud-init just brings up the VM. The execution of the
ubuntu.server.24.update.sh will come later via automation."

So v1 ships:

1. Three host-specific VM-creation pipelines (Get-Image + New-VM +
   minimal user-data) targeting Ubuntu 24.04 LTS (Noble).
2. Two host-side cmdlets: `Start-StashService`, `Stop-StashService`.
3. An extension scaffold with a placeholder `Get-StashServiceInfo`.
4. A reserved location for the Go daemon source at
   [`test/extension/stash-service/server/`](../test/extension/stash-service/server/).

## What v1 does NOT implement

Out of scope for v1, deferred to subsequent passes:

- The Go daemon itself (SCP wire-protocol handler, SQLite store).
- Cloud-init-driven daemon launch (systemd unit, supervisor).
- The in-VM UI for browsing received files.
- The `ubuntu.server.24.update.sh` execution (will be triggered by
  a later automation step, not by cloud-init runcmd).

## VM defaults

| Property | Value |
|---|---|
| Default `-VMName` | `yuruna-stash-service` |
| Base image | Ubuntu 24.04 LTS (Noble Numbat) cloud image |
| RAM | 8 GB |
| vCPU | `max(4, floor(hostCores / 2))` per [VM core-count policy](definition.md#defining-the-vm-core-count-policy) |
| Disk | 256 GB sparse |
| Network | LAN-routable bridge: Yuruna-External (Hyper-V), bridged `yuruna-external` (KVM), bridged QEMU (UTM) |
| Console user | `yuruna` (passwordless sudo; SSH key + vault password) |

## Operational model

Two host-side cmdlets only:

```
pwsh test/Start-StashService.ps1      # bring up the VM
pwsh test/Stop-StashService.ps1       # graceful stop (does NOT delete)
```

There is no `Get-StashServiceStatus`, `Restart-StashService`, or
`Remove-StashService`. Restart = `Stop-StashService` followed by
`Start-StashService` (the latter is idempotent and rebuilds the VM
from the base image).

Reachability: each host's New-VM places the stash VM on a
LAN-routable bridge, so peers reach `<vm-ip>:22` directly. No
host-side port forwarding is created or required.

## Scoping decisions

Recorded during initial implementation; the spec leaves these open.

| Decision | Choice |
|---|---|
| Go daemon source location | `test/extension/stash-service/server/` (extension area, not under `guest/` or per-host) |
| Default VM sizing | 8 GB RAM / 4 vCPU / 256 GB disk |
| Host-side port mapping | Direct LAN only (peers reach the VM's own IP) |
| Provisioning style | Cloud-init brings the VM up only; `ubuntu.server.24.update.sh` runs later via automation, NOT via cloud-init runcmd |

## Security posture

Intentionally open — any username, any password, any public key are
accepted by the custom SSH server (when implemented).
Designed to run on a trusted network alongside other Yuruna test infrastructure.
Network ACLs, rate limiting, file scanning are not in scope.

The console user (`yuruna`) on the VM itself is a normal Linux
account whose password lives in the authentication vault. The
custom stash daemon (not yet implemented) is a separate auth
surface that accepts any credentials.

Back to [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
