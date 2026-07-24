# Yuruna operator guide

Bring-up runbook for a Yuruna test lab: one first machine to a passing
test cycle, the three scale-up service VMs (caching proxy, stash
service, pool control), each additional machine, and finally a worked
[two-pool split](#two-pools-running-two-different-test-sets) running a
different test set on each. Every step names the script it runs and
links the reference doc that owns the details.

The order is deliberate: each step validates the one before it, cheap
checks run before expensive ones (config validation before the
caching-proxy VM build), and network storage is deferred to the
scale-up section because nothing in the first-cycle path reads it
([pool storage is opt-in, off by default](pool-storage.md)).

---

## First machine

### 1. Operating-system baseline (assumed)

A freshly installed Windows 11 Pro/Enterprise/Education (or Windows
Server), macOS 26+, or Ubuntu 26+ host. Tested baseline: 32 GB RAM,
512 GB free disk, 16+ physical cores ([requirements.md](requirements.md)).

### 2. Preflight dependencies

Before running the installer, confirm:

- **License / activation** — Windows must be activated and a
  Hyper-V-capable edition (Pro or above; Home has no Hyper-V).
- **OS updates applied** — pending updates can force a reboot mid-install.
- **Virtualization enabled in firmware** — Intel VT-x / AMD-V
  (Ubuntu: `grep -E 'vmx|svm' /proc/cpuinfo` must match).
- **Network access to github.com** — the installer clones the framework.

The installer re-checks the hardware baselines and prompts before
proceeding on an under-spec'd host.

### 3. Install the framework

Run the remote one-liner for the host OS (from
[install/README.md](../install/README.md), also linked at
<https://yuruna.link/install>):

Windows (PowerShell, self-elevates):

```
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1?nocache=$(Get-Date -Format yyyyMMddHHmmss)" | iex
```

macOS (Terminal):

```
/bin/bash -c "$(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos.utm.sh?nocache=$(date +%Y%m%d%H%M%S)")"
```

Ubuntu (Terminal):

```
bash <(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh?nocache=$(date +%Y%m%d%H%M%S)")
```

Alternatively `git clone` the repo and run the matching
`install/<host>.{ps1,sh}` yourself; for a signature-checked install or
to pin a release (disable auto-update), see
[install/README.md](../install/README.md). The clone lands in
`~/git/yuruna` (`%USERPROFILE%\git\yuruna` on Windows). **Reboot if the
installer says RESTART REQUIRED** (first-time Hyper-V enablement).

### 4. Enable test automation

```
pwsh test/Enable-TestAutomation.ps1
```

Explicit opt-in that turns this machine into a test host: display
sleep, screen saver, screen lock, display scaling (Windows), TCC
grants (macOS). Elevated (Administrator / sudo); idempotent; supports
`-WhatIf`. On Windows, sign out and back in if it reports display-scaling
changes — OCR needs 100% scaling. Details are owned by
`host/<platform>/Enable-TestAutomation.ps1`.

### 5. Configure and validate

Edit `test/test.config.yml` (created from
`test/test.config.yml.template`; parameter reference:
[test-config.md](test-config.md)). Minimum for a first run:
`repositories.projectUrl` (and `GH_TOKEN` if private), `guestSequence`.
Then validate:

```
pwsh test/Test-Config.ps1
```

Checks the config and the `test/extension/*` configs, probes GitHub and
Resend reachability, and fires a smoke-test notification (`-SkipSend`
to validate only). Fix every FAIL before moving on — this takes seconds
and the next step takes many minutes.

### 6. Start the caching proxy + dashboards

```
pwsh test/Start-CachingProxyVM.ps1
```

Builds the `yuruna-caching-proxy` VM and exposes ports 80 (CA cert),
3128/3129 (Squid), 3000 (Grafana), 9302 (metrics). Elevated on Windows;
macOS needs `sudo -E`. Set `vmStart.cachingProxyIP` in
`test.config.yml` to the proxy's IP so cycles find it. The cache VM
survives framework reinstalls. Details: [caching-proxy.md](caching-proxy.md).

### 7. Run one test cycle

```
pwsh test/Test-Project.ps1
```

One-shot cycle: wipes `project/`, re-clones `repositories.projectUrl`,
runs a single cycle exactly as the runner would, and exits. Debug here
until green — one cycle with no loop around it is the cheapest place.

### 8. Run continuous cycles

```
pwsh test/Invoke-TestRunner.ps1
```

The resilient outer loop: pulls the framework, runs a cycle in a fresh
inner process, repeats; on failure it pauses until new commits land or
a timeout passes ([test-runner.md](test-runner.md)). It auto-starts the
status dashboard at `http://<host>:8080/` — no separate
`Start-StatusService.ps1` step needed.

---

## Scale-up services (optional; recommended on the most powerful machine)

### 9. SMB shares for pool + stash storage

Durable network tiers ([pool-storage.md](pool-storage.md),
[stash-guide.md](stash-guide.md)) are backed by two SMB3 shares — on
this machine, or any NAS. One dedicated account per share:

```powershell
# On the machine hosting the shares (elevated, Windows example)
New-LocalUser yuruna-pool  -Password (Read-Host -AsSecureString 'yuruna-pool password')
New-LocalUser yuruna-stash -Password (Read-Host -AsSecureString 'yuruna-stash password')
New-Item -ItemType Directory -Force D:\work\yuruna.pool, D:\work\yuruna.stash
New-SmbShare -Name yuruna.pool  -Path D:\work\yuruna.pool  -FullAccess yuruna-pool
New-SmbShare -Name yuruna.stash -Path D:\work\yuruna.stash -FullAccess yuruna-stash
icacls D:\work\yuruna.pool  /grant 'yuruna-pool:(OI)(CI)M'
icacls D:\work\yuruna.stash /grant 'yuruna-stash:(OI)(CI)M'
```

(Ubuntu/macOS: any Samba/SMB server with the same two share names and
accounts.) Then fill `networkStorage.*` in `test.config.yml`, put the
share passwords in the vault, and set `pool.networkReplicate: true` on
hosts that should archive cycles to the NAS — see
[test-config.md](test-config.md).

### 10. Stash service

```
pwsh test/Start-StashVM.ps1
```

Brings up the `yuruna-stash-service` VM — the shared drop box for files
and snippets (web UI + scp). No login; trusted networks only. User
guide: [stash-guide.md](stash-guide.md).

### 11. Pool control

```
pwsh test/Start-PoolControlVM.ps1
```

Brings up the `yuruna-pool-control` VM — operator UI + API for LAN pool
intent: create pools, add hosts, assign test sets. Cloud-init builds the
daemon inside the guest (no host `go` toolchain needed) and persists its
audit log + status under `poolNetworkPath` — set up the shares (step 9)
first. Set the shared pool auth token with `test/Set-PoolAuthToken.ps1`.
Add `-HostSideProof` to build + run it directly on this host instead (UI
at `http://<host>:8090/`, needs `go` + `pwsh` on PATH). Details:
[pool-control.md](pool-control.md).

### VM administrator accounts

Each service VM is seeded with its own administrator, and each password
lives under its own vault key:

| VM | Administrator |
| -- | ------------- |
| `yuruna-caching-proxy` | `caching-proxy-admin` |
| `yuruna-pool-control` | `pool-control-admin` |
| `yuruna-stash-service` | `stash-admin` |

One account for all three would mean one vault entry: building any VM
would overwrite the password the other two were provisioned with, and
their console logins would stop working with no visible cause.

A VM whose seed named a different administrator keeps that account and
that vault entry until it is rebuilt — the names above apply from the
next build of each VM. `Move-CachingProxy.ps1` talks to two cache VMs at
once, so pass `-OldUser` when the source VM's account differs from the
`caching-proxy-admin` default. Remove a superseded vault entry only after
every VM provisioned with it has been rebuilt.

`users.yml.template` declares all three. An existing
`status/extension/authentication/users.yml` is not re-bootstrapped from
the template (that happens only when the file is absent), so hosts running
`strict: true` need the three entries added by hand — see
[test-config.md](test-config.md).

---

## Each additional machine

1. **OS baseline + preflight** — same as first-machine steps 1–2.
2. **Install the framework** — same one-liner (step 3); reboot if asked.
3. **Enable test automation** — `pwsh test/Enable-TestAutomation.ps1`
   (step 4).
4. **Sync configuration from an existing host:**

   ```
   pwsh test/Sync-HostConfiguration.ps1 -ReferenceHost <ip-or-name> [-SharedToken <token> -PersistSharedToken]
   ```

   Copies the reference host's `test.config.yml` converted for this
   host (share paths, mount points, host aliases — cross-host-type is
   the point), can install the pool auth token, and **finishes by
   running Test-Config.ps1** — so this step ends with a validated
   config. No local caching proxy is needed: the synced
   `vmStart.cachingProxyIP` points at the shared one.
5. **(Recommended) one local cycle** — `pwsh test/Test-Project.ps1` to
   prove the host green standalone before the pool drives it.
6. **Join a pool and take assignments** — open the Pool control UI
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
step 5 of "Each additional machine"), the pool NAS from step 9, and the
Pool control VM from step 11. `<intent-url>` below is the writable
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

Last review: 2026.07.24

Back to [Yuruna](../README.md)
