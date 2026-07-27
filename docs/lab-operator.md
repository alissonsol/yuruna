# Yuruna lab operator guide

Bring-up runbook for a Yuruna lab: several physically local machines
sharing one caching proxy, NAS-backed pool and stash storage, and a
pool-control service, grouped into pools and assigned test sets. It
ends with a worked [two-pool split](#two-pools-running-two-different-test-sets)
running a different test set on each group.

Prerequisite: every lab machine has completed steps 1–4 of the
[operator guide](operator.md) — OS baseline, preflight, framework
install, and the Yuruna test user. The shared services below are built
once, on the most powerful machine; every other machine only points at
them.

---

## 1. Enable test automation (every machine)

```
pwsh test/Enable-TestAutomation.ps1
```

Run on each lab machine. Explicit opt-in that turns it into a test
host: display sleep, screen saver, screen lock, display scaling
(Windows), TCC grants (macOS). Elevated (Administrator / sudo);
idempotent; supports `-WhatIf`. On Windows, sign out and back in if it
reports display-scaling changes — OCR needs 100% scaling. Details are
owned by `host/<platform>/Enable-TestAutomation.ps1`.

## 2. Lab storage: pool and stash shares (ideally on a NAS)

Durable network tiers ([pool-storage.md](pool-storage.md),
[stash-guide.md](stash-guide.md)) are backed by two SMB3 shares —
`yuruna.pool` and `yuruna.stash` — on a NAS if you have one, otherwise
on the machine hosting the shared services. Create the folders, the
lab vault, and the seeded pool-intent repository in one idempotent
step, run where the storage lives (for a NAS, run it on a machine that
mounts the NAS path):

```
pwsh test/New-Lab.ps1 -Name <lab-name> -Root <storage-root>
```

It generates one credential per share account into the lab vault —
plain YAML protected by filesystem permissions, so it stays **copyable
to the other lab machines** (DPAPI-bound files would not decrypt off
the machine that wrote them; see `test/schemas/lab.vault.schema.yml`).
Sharing the folders is left to the operator — one dedicated account per
share:

```powershell
# On the machine hosting the shares (elevated, Windows example)
New-LocalUser yuruna-pool  -Password (Read-Host -AsSecureString 'yuruna-pool password')
New-LocalUser yuruna-stash -Password (Read-Host -AsSecureString 'yuruna-stash password')
New-SmbShare -Name yuruna.pool  -Path D:\work\yuruna.pool  -FullAccess yuruna-pool
New-SmbShare -Name yuruna.stash -Path D:\work\yuruna.stash -FullAccess yuruna-stash
icacls D:\work\yuruna.pool  /grant 'yuruna-pool:(OI)(CI)M'
icacls D:\work\yuruna.stash /grant 'yuruna-stash:(OI)(CI)M'
```

(NAS / Ubuntu / macOS: any Samba/SMB server with the same two share
names and accounts.) Then, on each machine, fill `networkStorage.*` in
`test.config.yml`, put the share passwords in the vault, and set
`pool.networkReplicate: true` on hosts that should archive cycles to
the NAS — see [test-config.md](test-config.md).

## 3. Start the caching proxy + dashboards

```
pwsh test/Start-CachingProxyVM.ps1
```

One proxy serves the whole lab. Builds the `yuruna-caching-proxy` VM
and exposes ports 80 (CA cert), 3128/3129 (Squid), 3000 (Grafana),
9302 (metrics). Elevated on Windows; macOS needs `sudo -E`. On every
lab machine, set `vmStart.cachingProxyIP` in `test.config.yml` to this
proxy's IP so cycles find it. The cache VM survives framework
reinstalls. Details: [caching.md](caching.md#caching-proxy--test-harness-operator-reference), including
exposing the cache to remote clients and pointing a host at a remote
cache.

## 4. Start the stash service

```
pwsh test/Start-StashVM.ps1
```

Brings up the `yuruna-stash-service` VM — the lab-wide drop box for
files and snippets (web UI + scp). It mounts the `yuruna.stash` share
from step 2, so set that up first. No login; trusted networks only.
User guide: [stash-guide.md](stash-guide.md).

## 5. Start the pool control service

```
pwsh test/Start-PoolControlVM.ps1
```

Brings up the `yuruna-pool-control` VM — operator UI + API for LAN pool
intent: create pools, add hosts, assign test sets. Cloud-init builds the
daemon inside the guest (no host `go` toolchain needed) and persists its
audit log + status under `poolNetworkPath` — set up the shares (step 2)
first. Set the shared pool auth token with `test/Set-PoolAuthToken.ps1`.
Add `-HostSideProof` to build + run it directly on this host instead (UI
at `http://<host>:8090/`, needs `go` + `pwsh` on PATH). Details:
[the Pool control service section](pool-admin.md#pool-control-service) of
the pool admin guide.

Each service VM has its own administrator account and vault key — see
[VM administrator accounts](operator.md#vm-administrator-accounts).

## 6. Configure the first machine

On the machine that will run cycles first (any of them):

1. **Configure and validate** — edit `test/test.config.yml` and run
   `pwsh test/Test-Config.ps1`
   ([operator.md step 6](operator.md#6-configure-and-validate));
   include the `networkStorage.*` and `vmStart.cachingProxyIP` values
   from steps 2–3.
2. **One local cycle** — `pwsh test/Test-Project.ps1` until green; one
   cycle with no loop around it is the cheapest place to debug.
3. **Continuous cycles** — `pwsh test/Invoke-TestRunner.ps1`; it
   auto-starts the status dashboard at `http://<host>:8080/`
   ([test-runner.md](test-runner.md)).

## 7. Each additional machine

1. **OS baseline, preflight, install, test user** — operator-guide
   steps 1–4; reboot if the installer asks.
2. **Enable test automation** — `pwsh test/Enable-TestAutomation.ps1`
   (step 1 above).
3. **Sync configuration from an existing host:**

   ```
   pwsh test/Sync-HostConfiguration.ps1 -ReferenceHost <ip-or-name> [-SharedToken <token> -PersistSharedToken]
   ```

   Copies the reference host's `test.config.yml` converted for this
   host (share paths, mount points, host aliases — cross-host-type is
   the point), can install the pool auth token, and **finishes by
   running Test-Config.ps1** — so this step ends with a validated
   config. No local caching proxy is needed: the synced
   `vmStart.cachingProxyIP` points at the shared one.
4. **(Recommended) one local cycle** — `pwsh test/Test-Project.ps1` to
   prove the host green standalone before the pool drives it.
5. **Join a pool and take assignments** — open the Pool control UI
   (linked from the status dashboard as "Pool control", or
   `http://<pool-host>:8090/`), add this host to a pool, and assign a
   test set. CLI equivalent: `test/Add-HostToPool.ps1` +
   `test/Set-PoolTestSet.ps1` ([pool-admin.md](pool-admin.md)). Then
   start `pwsh test/Invoke-TestRunner.ps1`.

---

## Two pools running two different test sets

A worked example of the common scale-out shape: one lab, two groups of
hosts, each group running a different body of tests. Names here are
placeholders — substitute your own.

Assume four hosts registered and green standalone (each has completed
step 4 of "Each additional machine"), the pool NAS from step 2, and the
pool-control VM from step 5. `<intent-url>` below is the writable
pool-intent git URL; every command that mutates intent takes it.

### 1. Author the two test-sets in the project repo

A test-set names sequences the project already runs; it does not define
them. Two files under `test-sets/` in the **project** repo:

```yaml
# test-sets/testset1.yml
schemaVersion: 1
name: testset1
sequences:
  - start.guest.ubuntu.server.26
  - start.guest.amazon.linux.2023
```

```yaml
# test-sets/testset2.yml
schemaVersion: 1
name: testset2
sequences:
  - start.guest.windows.11
  - workload.guest.ubuntu.server.26
```

The filename stem must equal `name`, and each entry must be a top-level
sequence name the project's `test.runner.yml` already lists (no folder,
no extension) — the names above are the framework's own. Commit and push
both files: runners read them from the project repo, not from the intent
store.

### 2. Create both pools

```powershell
pwsh test/New-Pool.ps1 -PoolId poola -DisplayName 'Pool A' -IntentGitUrl <intent-url>
pwsh test/New-Pool.ps1 -PoolId poolb -DisplayName 'Pool B' -IntentGitUrl <intent-url>
```

`-PoolId` is permanent — it labels this pool's telemetry on the Grafana
"Yuruna hosts" dashboard forever, so renaming later forks the history.

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
pwsh test/Set-PoolTestSet.ps1 -PoolId poola -Name testset1 -Order 0 -CycleStrategy all -IntentGitUrl <intent-url>
pwsh test/Set-PoolTestSet.ps1 -PoolId poolb -Name testset2 -Order 0 -CycleStrategy all -IntentGitUrl <intent-url>
```

Within a pool, every member runs the sequences it *can* — folder
present, capability supported, hypervisor compatible — and skips the
rest, trusting a peer to cover them. There is no central dispatcher, so
a pool whose members cannot collectively cover a test-set silently
leaves those sequences unrun; `Get-PoolStatus.ps1` is where you notice.

### 5. Verify before the next cycle

```powershell
pwsh test/Test-PoolIntent.ps1                 # validates pools.yml and every test-sets/*.yml
pwsh test/Get-PoolStatus.ps1 -PoolId poola
pwsh test/Get-PoolStatus.ps1 -PoolId poolb
```

`Set-PoolTestSet.ps1` records a *reference* and does not check that the
manifest exists — `Test-PoolIntent.ps1` is what catches a misspelled
name. Nothing is deployed: each runner pulls intent at cycle start, so
the assignment takes effect on the next cycle with no restart.

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
`Invoke-TestRunner.ps1` on the hosts that stayed. Full command reference
and limitations: [pool-admin.md](pool-admin.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.26

Back to [Yuruna](../README.md)
