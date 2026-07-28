# Yuruna lab operator guide

Bring-up runbook for a Yuruna lab: several physically local machines
sharing one caching proxy, NAS-backed pool and stash storage, and a
pool-control service, grouped into pools and assigned test sets.

[Section A: Quickstart](#section-a-quickstart) is the complete command
sequence — shared services first, then machine by machine.
[Section B: Deep dive](#section-b-deep-dive) explains each step in
depth; every quickstart step links its deep-dive counterpart. The
guide ends with a worked
[two-pool split](#two-pools-running-two-different-test-sets) running a
different test set on each group of hosts.

Prerequisite: every lab machine has completed the
[operator guide](operator.md) through A.2 — OS baseline, preflight,
framework install, and the Yuruna test user (signed in as that user).
The shared services below are built once, on the most powerful
machine; every other machine only points at them.

---

## Section A: Quickstart

"Elevated" means an Administrator PowerShell on Windows, `sudo` on
macOS / Ubuntu. Run commands from the `yuruna` folder.

### A.1 Enable test automation (every machine)

Elevated, on each lab machine
([B.1](#b1-enable-test-automation-every-machine)):

```
pwsh test/Enable-TestAutomation.ps1
```

On Windows, sign out and back in if it reports display-scaling
changes.

### A.2 Create lab storage

Run where the storage lives — on a machine that mounts the NAS path,
or on the shared-services machine if there is no NAS
([B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas)):

```
pwsh test/New-Lab.ps1 -Name <lab-name> -Root <storage-root>
```

`<lab-name>` is lowercase (letters, digits, hyphens — the pool-id
charset); `<storage-root>` is e.g. `D:\work` on Windows or `/srv` on
Linux. Share the two folders it created — one dedicated account per
share, using the passwords `New-Lab` just generated into the lab
vault:

```powershell
# On the machine hosting the shares (elevated, Windows example)
New-LocalUser yuruna-pool  -Password (Read-Host -AsSecureString 'yuruna-pool password')
New-LocalUser yuruna-stash -Password (Read-Host -AsSecureString 'yuruna-stash password')
New-SmbShare -Name yuruna.pool  -Path D:\work\yuruna.pool  -FullAccess yuruna-pool
New-SmbShare -Name yuruna.stash -Path D:\work\yuruna.stash -FullAccess yuruna-stash
icacls D:\work\yuruna.pool  /grant 'yuruna-pool:(OI)(CI)M'
icacls D:\work\yuruna.stash /grant 'yuruna-stash:(OI)(CI)M'
```

Then, on each machine you configure by hand — the shared-services
machine now ([A.4](#a4-start-the-stash-service)–[A.5](#a5-start-the-pool-control-service)
require it) and the first cycle machine in
[A.6](#a6-bring-up-the-first-machine) — fill `networkStorage.*` in
`test/test.config.yml` and store both share passwords in the host
vault ([Setting the SMB passwords in the vault](test-config.md#setting-the-smb-passwords-in-the-vault)).
Machines enrolled in [A.7](#a7-enroll-each-additional-machine)
receive the config and credentials through the sync.

### A.3 Start the caching proxy (one per lab)

On the shared-services machine; elevated on Windows, `sudo -E` on
macOS ([B.3](#b3-start-the-caching-proxy--dashboards)):

```
pwsh test/Start-CachingProxyVM.ps1
```

Note the proxy VM's IP the script prints when it finishes — every
machine's `vmStart.cachingProxyIP`
([A.6](#a6-bring-up-the-first-machine)) points at it.

The Grafana "Yuruna hosts" dashboard's "Lab token" stat tile shows
the 6-character code later steps redeem to enroll hosts. It rotates
about once a minute — read the current value each time you run
`Set-LabToken.ps1` rather than writing it down.

### A.4 Start the stash service

Elevated on Windows; needs the A.2 configuration on this machine
([B.4](#b4-start-the-stash-service)):

```
pwsh test/Start-StashVM.ps1
```

### A.5 Start the pool control service

Elevated on Windows ([B.5](#b5-start-the-pool-control-service)):

```
pwsh test/Start-PoolControlVM.ps1
pwsh test/Set-LabToken.ps1 -LabToken <code>
```

`<code>` is the current "Lab token" tile value
([A.3](#a3-start-the-caching-proxy-one-per-lab)); `Set-LabToken.ps1`
enrolls this host in the lab.

### A.6 Bring up the first machine

On the machine that will run cycles first: edit
`test/test.config.yml` — at minimum `repositories.projectUrl` (and
`GH_TOKEN` if private) and `guestSequence`, plus the
`networkStorage.*` values and share passwords from
[A.2](#a2-create-lab-storage) and the `vmStart.cachingProxyIP` from
[A.3](#a3-start-the-caching-proxy-one-per-lab) — then enroll,
validate, and run ([B.6](#b6-configure-the-first-machine)):

```
pwsh test/Set-LabToken.ps1 -LabToken <code>
pwsh test/Test-Config.ps1
pwsh test/Test-Project.ps1
pwsh test/Invoke-TestRunner.ps1
```

Skip `Set-LabToken.ps1` if this is the shared-services machine —
[A.5](#a5-start-the-pool-control-service) already enrolled it. Fix
every `Test-Config` FAIL; debug `Test-Project` until green; then
leave the runner cycling — it serves the status dashboard at
`http://<host>:8080/`.

### A.7 Enroll each additional machine

On each remaining machine ([B.7](#b7-each-additional-machine)):

```
pwsh test/Set-LabToken.ps1 -LabToken <code>
pwsh test/Sync-HostConfiguration.ps1 -ReferenceHost <ip-or-name>
pwsh test/Test-Project.ps1
```

The sync copies the reference host's config converted for this host
and finishes by running `Test-Config.ps1`. Once `Test-Project` is
green, open the Pool control UI at `http://<pool-control-vm-ip>/`
(also linked as "Pool control" in the Grafana "Yuruna hosts"
dashboard's Extension hosts table), add the host to a pool, assign a
test set, then:

```
pwsh test/Invoke-TestRunner.ps1
```

---

## Section B: Deep dive

### B.1 Enable test automation (every machine)

```
pwsh test/Enable-TestAutomation.ps1
```

Run on each lab machine. Explicit opt-in that turns it into a test
host: display sleep, screen saver, screen lock, display scaling
(Windows), TCC grants (macOS). Elevated (Administrator / sudo);
idempotent; supports `-WhatIf`. On Windows, sign out and back in if it
reports display-scaling changes — OCR needs 100% scaling. Details are
owned by `host/<platform>/Enable-TestAutomation.ps1`.

### B.2 Lab storage: pool and stash shares (ideally on a NAS)

Durable network tiers ([pool-storage.md](pool-storage.md),
[stash-guide.md](stash-guide.md)) are backed by two SMB3 shares —
`yuruna.pool` and `yuruna.stash` — on a NAS if you have one, otherwise
on the machine hosting the shared services. `test/New-Lab.ps1` creates
the folders, the lab vault, and the seeded pool-intent repository in
one idempotent step, run where the storage lives; commands:
[A.2](#a2-create-lab-storage).

It generates one credential per share account into the lab vault —
plain YAML protected by filesystem permissions, so it stays **copyable
to the other lab machines** (DPAPI-bound files would not decrypt off
the machine that wrote them; see `test/schemas/lab.vault.schema.yml`).
Sharing the folders is left to the operator — one dedicated account per
share, as in the A.2 example. (NAS / Ubuntu / macOS: any Samba/SMB
server with the same two share names and accounts.) Then, on each
machine, fill `networkStorage.*` in `test.config.yml`, put the share
passwords in the vault, and set `pool.networkReplicate: true` on hosts
that should archive cycles to the NAS — see
[test-config.md](test-config.md).

### B.3 Start the caching proxy + dashboards

```
pwsh test/Start-CachingProxyVM.ps1
```

One proxy serves the whole lab. Builds the `yuruna-caching-proxy` VM
and exposes ports 80 (CA cert), 3128/3129 (Squid), 3000 (Grafana),
9302 (metrics). Elevated on Windows; macOS needs `sudo -E`. On every
lab machine, set `vmStart.cachingProxyIP` in `test.config.yml` to this
proxy's IP so cycles find it. The build mints and stores a random
`lab-auth-token` in this host's vault when none exists, so the proxy
never comes up with an empty token; once the dashboards are up, the
"Yuruna hosts" Grafana dashboard shows the current 6-character lab
connection token in its "Lab token" stat tile (rotating about once a
minute) — later steps redeem that code to enroll hosts. The cache VM survives framework
reinstalls. Details: [caching.md](caching.md#caching-proxy--test-harness-operator-reference), including
exposing the cache to remote clients and pointing a host at a remote
cache.

### B.4 Start the stash service

```
pwsh test/Start-StashVM.ps1
```

Brings up the `yuruna-stash-service` VM — the lab-wide drop box for
files and snippets (web UI + scp). Elevated on Windows. It mounts the
`yuruna.stash` share
from [B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas), so
set that up first. No login; trusted networks only. User guide:
[stash-guide.md](stash-guide.md).

### B.5 Start the pool control service

```
pwsh test/Start-PoolControlVM.ps1
```

Brings up the `yuruna-pool-control` VM — operator UI + API for LAN pool
intent: create pools, add hosts, assign test sets. Elevated on
Windows. Cloud-init builds the daemon inside the guest (no host `go`
toolchain needed) and persists its audit log + status under
`poolNetworkPath` — set up the shares
([B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas)) first.
The VM serves the UI on port 80 (`http://<pool-control-vm-ip>/`),
also linked as "Pool control" in the Grafana "Yuruna hosts"
dashboard's Extension hosts table.
Enroll this host with `test/Set-LabToken.ps1 -LabToken <code>` —
`<code>` is the current 6-character code on the dashboard's "Lab
token" tile ([B.3](#b3-start-the-caching-proxy--dashboards)); the
script fetches the shared `lab-auth-token` into the host vault.
Add `-HostSideProof` to build + run it directly on this host instead (UI
at `http://<host>:8090/`, needs `go` + `pwsh` on PATH). Details:
[the Pool control service section](pool-admin.md#pool-control-service) of
the pool admin guide.

Each service VM has its own administrator account and vault key — see
[VM administrator accounts](operator.md#vm-administrator-accounts).

### B.6 Configure the first machine

On the machine that will run cycles first (any of them):

1. **Enroll in the lab** — `pwsh test/Set-LabToken.ps1 -LabToken
   <code>` (current "Lab token" tile value); already done for the
   shared-services machine in
   [B.5](#b5-start-the-pool-control-service). Without the token the
   host still cycles standalone but never reports to the lab
   dashboards.
2. **Configure and validate** — edit `test/test.config.yml` and run
   `pwsh test/Test-Config.ps1`
   ([operator guide B.6](operator.md#b6-configure-and-validate));
   include the `networkStorage.*` values and share passwords from
   [B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas) and
   the `vmStart.cachingProxyIP` from
   [B.3](#b3-start-the-caching-proxy--dashboards).
3. **One local cycle** — `pwsh test/Test-Project.ps1` until green; one
   cycle with no loop around it is the cheapest place to debug.
4. **Continuous cycles** — `pwsh test/Invoke-TestRunner.ps1`; it
   auto-starts the status dashboard at `http://<host>:8080/`
   ([test-runner.md](test-runner.md)).

### B.7 Each additional machine

1. **OS baseline, preflight, install, test user** — operator guide
   through [A.2](operator.md#a2-create-the-test-user); reboot if the
   installer asks.
2. **Enable test automation** — `pwsh test/Enable-TestAutomation.ps1`
   ([B.1](#b1-enable-test-automation-every-machine)).
3. **Enroll in the lab, then sync configuration from an existing
   host:**

   ```
   pwsh test/Set-LabToken.ps1 -LabToken <code>
   pwsh test/Sync-HostConfiguration.ps1 -ReferenceHost <ip-or-name>
   ```

   `<code>` is the 6-character code on the dashboard's "Lab token"
   tile; `Set-LabToken.ps1` redeems it at the aggregator and stores
   the shared `lab-auth-token` in this host's vault. The sync then
   copies the reference host's `test.config.yml` converted for this
   host (share paths, mount points, host aliases — cross-host-type is
   the point), authenticating with this host's own stored token, and
   **finishes by running Test-Config.ps1** — so this step ends with a
   validated config. If the aggregator is unreachable, skip
   `Set-LabToken.ps1` and pass the raw token to
   `Sync-HostConfiguration.ps1` instead:
   `-SharedToken '<raw-token>' -PersistSharedToken` — the raw
   `lab-auth-token` is in the shared-services host's vault.
   No local caching proxy is needed: the synced
   `vmStart.cachingProxyIP` points at the shared one.
4. **(Recommended) one local cycle** — `pwsh test/Test-Project.ps1` to
   prove the host green standalone before the pool drives it.
5. **Join a pool and take assignments** — open the Pool control UI at
   `http://<pool-control-vm-ip>/` (linked as "Pool control" in the
   Grafana "Yuruna hosts" dashboard's Extension hosts table), add
   this host to a pool, and assign a test set. CLI equivalent:
   `test/Add-HostToPool.ps1` + `test/Set-PoolTestSet.ps1`
   ([pool-admin.md](pool-admin.md)). Then start
   `pwsh test/Invoke-TestRunner.ps1`.

---

## Two pools running two different test sets

A worked example of the common scale-out shape: one lab, two groups of
hosts, each group running a different body of tests. Names here are
placeholders — substitute your own.

Assume four hosts registered and green standalone (each has passed the
one-local-cycle check of [B.7](#b7-each-additional-machine)), the pool
NAS from [B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas),
and the pool-control VM from
[B.5](#b5-start-the-pool-control-service). `<intent-url>` below is the
writable pool-intent git URL; every command that mutates intent takes
it.

### 1. Define the two test-sets

A test-set is a named framework/project repo **pair**: a pooled
member overrides its own `repositories.frameworkUrl` /
`repositories.projectUrl` with it for the cycle and runs the assigned
project's own `test.runner.yml` plan. "Two different bodies of tests"
therefore means two project repos — two projects, or two branches or
forks of one. `GH_TOKEN` is never stored in pool intent; it stays
host-local.

Register both pairs in the intent store's test-set library (it backs
the Pool control "Test sets" page; `Set-PoolTestSet.ps1` in step 4
also accepts the URLs directly):

```powershell
pwsh test/Set-PoolTestSetDefinition.ps1 -Name testset1 -FrameworkUrl <framework-url> -ProjectUrl <project-a-url> -IntentGitUrl <intent-url>
pwsh test/Set-PoolTestSetDefinition.ps1 -Name testset2 -FrameworkUrl <framework-url> -ProjectUrl <project-b-url> -IntentGitUrl <intent-url>
```

### 2. Create both pools

```powershell
pwsh test/New-Pool.ps1 -PoolId poola -DisplayName 'Pool A' -IntentGitUrl <intent-url>
pwsh test/New-Pool.ps1 -PoolId poolb -DisplayName 'Pool B' -IntentGitUrl <intent-url>
```

`-PoolId` is permanent — `New-Pool.ps1` mints a stable `poolGuid` for
it (the dashboard's "Pool ID"), so renaming later means a new pool
and forks the telemetry history.

### 3. Split the hosts between them

A host belongs to **at most one pool**, which is what makes the split
meaningful. Each `-HostId` is that host's `runtime/host.uuid`:

```powershell
pwsh test/Add-HostToPool.ps1 -PoolId poola -HostId <host-1-uuid> -IntentGitUrl <intent-url>
pwsh test/Add-HostToPool.ps1 -PoolId poola -HostId <host-2-uuid> -IntentGitUrl <intent-url>
pwsh test/Add-HostToPool.ps1 -PoolId poolb -HostId <host-3-uuid> -IntentGitUrl <intent-url>
pwsh test/Add-HostToPool.ps1 -PoolId poolb -HostId <host-4-uuid> -IntentGitUrl <intent-url>
```

### 4. Assign one test-set to each pool

```powershell
pwsh test/Set-PoolTestSet.ps1 -PoolId poola -Name testset1 -FrameworkUrl <framework-url> -ProjectUrl <project-a-url> -IntentGitUrl <intent-url>
pwsh test/Set-PoolTestSet.ps1 -PoolId poolb -Name testset2 -FrameworkUrl <framework-url> -ProjectUrl <project-b-url> -IntentGitUrl <intent-url>
```

A pool holds exactly one `testSet`; assigning replaces the previous
one. Members do not split the work: from its next cycle, every poola
member clones `<project-a-url>` and runs that project's full
`test.runner.yml` plan, reporting under the pool.

### 5. Verify before the next cycle

```powershell
pwsh test/Test-PoolIntent.ps1 -IntentGitUrl <intent-url>          # schema-validates the intent files
pwsh test/Get-PoolStatus.ps1  -PoolId poola -IntentGitUrl <intent-url>
pwsh test/Get-PoolStatus.ps1  -PoolId poolb -IntentGitUrl <intent-url>
```

`Test-PoolIntent.ps1` validates `pools.yml` (and
`guests.compatibility.yml` when present) against the schemas and
enforces that a host belongs to at most one pool; `Get-PoolStatus.ps1`
shows members, `desiredState`, and the assigned test-set. Neither
probes the repo URLs — a typo there first surfaces when a member's
next cycle tries to clone. Nothing is deployed: each runner pulls
intent at cycle start, so the assignment takes effect on the next
cycle with no restart.

### 6. Operate the two pools independently

`desiredState` is per pool, so one can be paused while the other keeps
cycling:

```powershell
pwsh test/Set-PoolDesiredState.ps1 -PoolId poolb -State paused -IntentGitUrl <intent-url>
pwsh test/Set-PoolDesiredState.ps1 -PoolId poolb -State run    -IntentGitUrl <intent-url>
```

To move a host from Pool A to Pool B, drain it first, let its current
cycle finish, then remove and re-add:

```powershell
pwsh test/Set-PoolDesiredState.ps1  -PoolId poola -State drain  -IntentGitUrl <intent-url>
pwsh test/Remove-HostFromPool.ps1   -PoolId poola -HostId <host-2-uuid> -IntentGitUrl <intent-url>
pwsh test/Add-HostToPool.ps1        -PoolId poolb -HostId <host-2-uuid> -IntentGitUrl <intent-url>
pwsh test/Set-PoolDesiredState.ps1  -PoolId poola -State run    -IntentGitUrl <intent-url>
```

Draining stops the runner process on every Pool A member, so restart
`Invoke-TestRunner.ps1` on the hosts that stayed — and on the moved
host once it is in Pool B. Full command reference and limitations:
[pool-admin.md](pool-admin.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.28

Back to [Yuruna](../README.md)
