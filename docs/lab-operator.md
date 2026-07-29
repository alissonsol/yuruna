# Yuruna lab operator guide

Bring-up runbook for a Yuruna lab: several physically local machines
sharing one caching-proxy service, NAS-backed pool and stash storage, and a
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
([B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas)).

**Storage on this machine (no NAS)** — elevated, one command does all
of it (folders, accounts, shares, mounts, config):

```
pwsh test/New-LocalLabStorage.ps1
```

It asks only where storage should live, suggesting `/srv/yuruna`
(Ubuntu), `/Users/Shared/yuruna` (macOS), or `<drive>\Shares\yuruna`
(Windows, first non-system drive). It calls `New-Lab` for you, so the
lab is created too. Skip to the last paragraph of this step afterwards
— it writes `networkStorage.*` and the vault entries on this machine
itself.

To add **another lab** to that machine later, `New-Lab` on its own is
enough — it finds the folders, the storage root, and the share
accounts already here and reuses them, so `-Root` is not needed and no
second set of passwords is minted:

```
pwsh test/New-Lab.ps1 -Name <lab-name>
```

**Storage on a NAS or a separate file server** — create the folders
and the lab vault here, then create the accounts and grant the share
permissions **on that device**, with its own administration tool:

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

### A.3 Start the caching-proxy service (one per lab)

On the shared-services machine; elevated on Windows, `sudo -E` on
macOS ([B.3](#b3-start-the-caching-proxy-service--dashboards)):

```
pwsh test/Start-CachingProxyServiceVM.ps1
```

Note the proxy VM's IP the script prints when it finishes — every
machine's `vmStart.cachingProxyIp`
([A.6](#a6-bring-up-the-first-machine)) points at it.

The Grafana "Yuruna hosts" dashboard's "Lab token" stat tile shows
the 6-character code later steps redeem to enroll hosts. It rotates
about once a minute — read the current value each time you run
`Set-LabToken.ps1` rather than writing it down.

### A.4 Start the stash service

Elevated on Windows; needs the A.2 configuration on this machine
([B.4](#b4-start-the-stash-service)):

```
pwsh test/Start-StashServiceVM.ps1
```

### A.5 Start the pool control service

Elevated on Windows ([B.5](#b5-start-the-pool-control-service)):

```
pwsh test/Start-PoolControlServiceVM.ps1
pwsh test/Set-LabToken.ps1 -LabToken <code>
```

`<code>` is the current "Lab token" tile value
([A.3](#a3-start-the-caching-proxy-service-one-per-lab)); `Set-LabToken.ps1`
enrolls this host in the lab.

### A.6 Bring up the first machine

On the machine that will run cycles first: edit
`test/test.config.yml` — at minimum `repositories.projectUrl` (and
`GH_TOKEN` if private) and `guestSequence`, plus the
`networkStorage.*` values and share passwords from
[A.2](#a2-create-lab-storage) and the `vmStart.cachingProxyIp` from
[A.3](#a3-start-the-caching-proxy-service-one-per-lab) — then enroll,
validate, and run ([B.6](#b6-configure-the-first-machine)):

```
pwsh test/Set-LabToken.ps1 -LabToken <code>
pwsh test/Test-Config.ps1
pwsh test/Invoke-TestProject.ps1
pwsh test/Invoke-TestRunner.ps1
```

Skip `Set-LabToken.ps1` if this is the shared-services machine —
[A.5](#a5-start-the-pool-control-service) already enrolled it. Fix
every `Test-Config` FAIL; debug `Invoke-TestProject` until green; then
leave the runner cycling — it serves the status dashboard at
`http://<host>:8080/`.

### A.7 Enroll each additional machine

On each remaining machine ([B.7](#b7-each-additional-machine)):

```
pwsh test/Set-LabToken.ps1 -LabToken <code>
pwsh test/Sync-HostConfiguration.ps1 -ReferenceHost <ip-or-name>
pwsh test/Invoke-TestProject.ps1
```

The sync copies the reference host's config converted for this host
and finishes by running `Test-Config.ps1`. Once `Invoke-TestProject` is
green, open the pool-control service UI at `http://<pool-control-service-vm-ip>/`
(also linked as "Pool-control service" in the Grafana "Yuruna hosts"
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

**When the storage lives on the machine you are standing at,
`test/New-LocalLabStorage.ps1` does the whole step instead.** It calls
`New-Lab` for the folders, the lab vault, and the intent repository,
then does what `New-Lab` deliberately leaves alone: creates one local
storage account per tier (not an administrator, no interactive shell,
and on Ubuntu no OS password at all), stands up the SMB server
(starting it on Windows, enabling File Sharing on macOS, installing
Samba + cifs-utils on Ubuntu), publishes one share per tier scoped to
its own account, stores both passwords under a mapped `vaultKey`,
mounts the shares, and writes the six `networkStorage.*` keys. It is
idempotent, supports `-WhatIf`, and adds `-EnableReplication` for
`pool.networkReplicate`.

The shares are local but are consumed **as if they were remote**: each
tier gets a hosts-file alias (`ypool-nas`, `ystash-nas`) pointing at
the loopback address, and the mount goes over SMB through that name,
using the same code path the unattended cycle uses. So a one-machine
lab exercises the same replication and gating code as a lab with a
NAS, and moving to real hardware later is a change of what the alias
resolves to and nothing else. On Windows it also registers the two
names as NTLM loopback exemptions (`BackConnectionHostNames`) and sets
`EnableLinkedConnections`, without which the machine refuses its own
SMB connection and the mapped drives are invisible outside the
elevated session; both apply at the next restart or sign-in.

**Adding more labs to that machine** takes only `New-Lab` — the
storage step is not repeated. The share accounts are machine-wide (one
`yuruna-pool` OS account serves every lab whose storage lives here), so
`New-Lab` reuses what is already present: `-Root` may be omitted (the
root is read back from a lab already on this machine), and a credential
already in the host vault is reused rather than regenerated. Minting a
second password would leave the new lab vault disagreeing with the OS
account, the SMB server, and every other machine in the lab, and each
mount driven from it would fail against a share that never had that
password. `New-Lab` reports which credentials it reused; the lookup is
read-only and `-Force` still reuses rather than rotates. See
[operator.md](operator.md#b7-local-shares-for-pool-and-stash-storage).

**It is for local storage only.** A NAS or a separate file server owns
its own accounts and its own access control, and nothing on this
machine can create them — do that on the device, then point
`networkStorage.*` at it as above. The script says so and asks for
confirmation before it changes anything.

### B.3 Start the caching-proxy service + dashboards

```
pwsh test/Start-CachingProxyServiceVM.ps1
```

One proxy serves the whole lab. Builds the `yuruna-caching-proxy-service` VM
and exposes ports 80 (CA cert), 3128/3129 (Squid), 3000 (Grafana),
9302 (metrics). Elevated on Windows; macOS needs `sudo -E`. On every
lab machine, set `vmStart.cachingProxyIp` in `test.config.yml` to this
proxy's IP so cycles find it. The build mints and stores a random
`lab-auth-token` in this host's vault when none exists, so the proxy
never comes up with an empty token; once the dashboards are up, the
"Yuruna hosts" Grafana dashboard shows the current 6-character lab
connection token in its "Lab token" stat tile (rotating about once a
minute) — later steps redeem that code to enroll hosts. The cache VM survives framework
reinstalls. Details: [caching.md](caching.md#caching-proxy-service--test-harness-operator-reference), including
exposing the cache to remote clients and pointing a host at a remote
cache.

### B.4 Start the stash service

```
pwsh test/Start-StashServiceVM.ps1
```

Brings up the `yuruna-stash-service` VM — the lab-wide drop box for
files and snippets (web UI + scp). Elevated on Windows. It mounts the
`yuruna.stash` share
from [B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas), so
set that up first. No login; trusted networks only. User guide:
[stash-guide.md](stash-guide.md).

### B.5 Start the pool control service

```
pwsh test/Start-PoolControlServiceVM.ps1
```

Brings up the `yuruna-pool-control-service` VM — operator UI + API for LAN pool
intent: create pools, add hosts, assign test sets. Elevated on
Windows. Cloud-init builds the daemon inside the guest (no host `go`
toolchain needed) and persists its audit log + status under
`poolStorageNetworkPath` — set up the shares
([B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas)) first.
The VM serves the UI on port 80 (`http://<pool-control-service-vm-ip>/`),
also linked as "Pool-control service" in the Grafana "Yuruna hosts"
dashboard's Extension hosts table.
Enroll this host with `test/Set-LabToken.ps1 -LabToken <code>` —
`<code>` is the current 6-character code on the dashboard's "Lab
token" tile ([B.3](#b3-start-the-caching-proxy-service--dashboards)); the
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
   the `vmStart.cachingProxyIp` from
   [B.3](#b3-start-the-caching-proxy-service--dashboards).
3. **One local cycle** — `pwsh test/Invoke-TestProject.ps1` until green; one
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
   No local caching-proxy service is needed: the synced
   `vmStart.cachingProxyIp` points at the shared one.

   Before overwriting anything, the sync compares the fetched config
   against **this** host's `test.config.yml.template` and stops to ask if
   the reference host is behind it — listing the retired key names it
   still uses, the current keys it lacks (which would land here silently
   defaulted), and the keys it carries that the schema has dropped. The
   fix is at the source: run `pwsh tools/Update-TestConfigNaming.ps1` and
   `pwsh test/Test-Config.ps1` on the reference host, then sync again.
   `-AllowStaleReference` accepts the drift and proceeds; under
   `-NonInteractive` a stale reference fails the run unless that switch
   is passed, so an unattended sync cannot quietly propagate a
   half-migrated config across the lab.
4. **(Recommended) one local cycle** — `pwsh test/Invoke-TestProject.ps1` to
   prove the host green standalone before the pool drives it.
5. **Join a pool and take assignments** — open the pool-control service UI at
   `http://<pool-control-service-vm-ip>/` (linked as "Pool-control service" in the
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
and the pool-control-service VM from
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
the pool-control service "Test sets" page; `Set-PoolTestSet.ps1` in step 4
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

Last review: 2026.07.29

Back to [Yuruna](../README.md)
