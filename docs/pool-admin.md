# Yuruna pool admin guide — assign test sequences to a host pool

> **Who this is for.** A **pool administrator / operator** running several Yuruna test
> hosts who wants them to share work and report together. It is *not* a guide to writing
> test sequences or harness code. It assumes the test **sequences already exist** (the ones
> a single host runs from `test.runner.yml`); your job here is to group some of them and
> point a set of hosts at them.

## What a pool is

A **pool** is a named group of test hosts that all run the same assigned work and report
their results under one label (the `poolId`). You manage a pool by editing one small file
of **intent** — `pools.yml` — through a handful of admin commands. You never touch the
hosts directly: each runner **pulls** the intent every cycle and acts on it.

Intent has three parts:

- **members** — which hosts belong to the pool (by their stable host id).
- **test-sets** — which groups of existing test sequences the pool runs.
- **desiredState** — whether the pool is running, paused, or draining.

```
  you ──run──▶ admin CLI ──writes──▶ pools.yml  (intent git repo on the caching-proxy)
                                          │
  every host ──pulls read-only each cycle─┘──▶ runs the assigned test-sets, reports under <poolId>
```

The intent repo holds **only non-secret** files (`pools.yml`, the test-set manifests,
`guests.compatibility.yml`). No credential is ever routed through it.

## Before you start

1. **The intent store exists.** The caching-proxy VM seeds a bare git repo at
   `/var/lib/yuruna/pool-intent.git` and serves it **read-only over HTTP** at
   `http://<proxy>/pool-intent.git`. This is set up automatically when the caching-proxy is
   provisioned — you don't create it.
2. **Each host has opted in.** In each host's `test/test.config.yml`, set the `pool` block:
   ```yaml
   pool:
     enabled: true
     intentGitUrl: http://<proxy>/pool-intent.git   # the READ-ONLY HTTP url
     localClonePath: ''                              # optional; defaults under runtime/
   ```
   A host with `pool.enabled: false` (the default) runs standalone, exactly as before.
3. **You know each host's id.** Every host has a stable id in `runtime/host.uuid` — a
   `42`-prefixed 32-hex string. It is also shown as `hostId` on the host's own status page
   and on the pool dashboard.
4. **You can write the intent repo.** The HTTP url above is read-only. The admin commands
   need a **writable** path/url, so run them **on the caching-proxy** against the local repo
   (`/var/lib/yuruna/pool-intent.git`), or against any pre-authenticated writable remote.
   Pass it with `-IntentGitUrl <writable-url>`, or set `pool.intentGitUrl` to a writable
   value in the `test.config.yml` you run the admin CLI from (then you can omit the flag).

Run the commands below from the repo root.

## Step 1 — Create the pool

```powershell
pwsh test/New-Pool.ps1 -PoolId lab -DisplayName 'Lab pool' -IntentGitUrl <writable-url>
```

- `-PoolId` is a short, lowercase, DNS-safe name (`a-z 0-9 -`). It becomes the **permanent
  label** for this pool's telemetry on the dashboard, so pick it deliberately — renaming it
  later forks the history.
- The pool starts empty (`desiredState: run`, no members, no test-sets).

## Step 2 — Add the hosts

Run once per host:

```powershell
pwsh test/Add-HostToPool.ps1 -PoolId lab -HostId 42abcdef0123456789abcdef01234567 -IntentGitUrl <writable-url>
```

- `-HostId` is the host's `runtime/host.uuid` (`42` + 30 hex). Membership is the single
  source of truth and is idempotent — re-adding a host is a no-op.
- To remove a host later, see **Step 6** below (drain it first if it is running).

## Step 3 — Group your test sequences into a test-set

A **test-set** is a named list of test **sequences you already run**, plus a few options.
Create `test-sets/<name>.yml` in your **project** repo (next to the sequences), e.g.
`test-sets/smoke.yml`:

```yaml
schemaVersion: 1
name: smoke
sequences:                      # the SAME sequence names your test.runner.yml already runs
  - amazon.linux.2023.install
  - ubuntu.server.24.install
perGuestOverrides:              # optional: per-guest tweaks just for this set
  guest.ubuntu.server.24:
    keystrokeMechanism: GUI     # GUI | SSH
    variables:
      username: yuser1
provisioning:
  betweenSets: none             # only 'none' is active today
```

- The **filename stem must equal `name`** (`smoke.yml` → `name: smoke`).
- `sequences[]` are **existing top-level sequence names** — the exact strings your
  `test.runner.yml` lists (no folder, no extension). You are not writing sequences here,
  only naming which ones this pool should run.
- Each host automatically runs only the guests it can (folder present + capability supported
  + hypervisor-compatible) and skips the rest, trusting another pool member to cover them —
  there is no central dispatcher.
- Full field reference: [`test/schemas/test-set.schema.yml`](../test/schemas/test-set.schema.yml).
  Working example: [`test/pool/examples/test-sets/smoke.yml`](../test/pool/examples/test-sets/smoke.yml).

## Step 4 — Assign the test-set to the pool

```powershell
pwsh test/Set-PoolTestSet.ps1 -PoolId lab -Name smoke -Order 0 -CycleStrategy all -IntentGitUrl <writable-url>
```

- `-Name` is the test-set's name (its manifest filename stem). This records a **reference**
  in `pools.yml`; it does **not** verify that `test-sets/smoke.yml` exists — Step 5 catches a typo.
- `-Order` (default 0) sets the order when a pool has several test-sets (lowest runs first).
- `-CycleStrategy` is `all` today (every member runs the set's runnable guests). `round-robin`
  and `single` are accepted but currently behave like `all` — see [Limitations](#current-limitations).
- Assign more than one test-set by running this again with another `-Name`/`-Order`.

## Step 5 — Verify

```powershell
pwsh test/Test-PoolIntent.ps1             # validates pools.yml + every test-sets/*.yml; flags a test-set name with no manifest
pwsh test/Get-PoolStatus.ps1 -PoolId lab  # shows members, desiredState, and the assigned test-sets (what you authored)
```

There is nothing to "deploy": each runner picks up the new intent on its **next cycle** (it
pulls at cycle start), so no host restart is needed. Once a pooled host completes a cycle,
confirm it took effect on the **Yuruna hosts** Grafana dashboard (it groups every host under
your `poolId`), or directly: `curl -sk https://<proxy>:9400/api/v1/pool-status`.

## Step 6 — Operate the pool

```powershell
pwsh test/Set-PoolDesiredState.ps1 -PoolId lab -State paused -IntentGitUrl <writable-url>   # run | paused | drain
pwsh test/Remove-HostFromPool.ps1  -PoolId lab -HostId 42<...30 hex...> -IntentGitUrl <writable-url>
```

- **run** — cycle normally.
- **paused** — finish the in-flight cycle, then hold (re-checking every ~30 s) until you set
  it back to `run`.
- **drain** — stop after the current cycle; the runner process exits. Re-add the host and
  restart its runner to rejoin.
- **Removing a running host:** set `drain` first, let it stop, then `Remove-HostFromPool`.

In-flight cycles always finish, so pause/drain never corrupt an accumulating run.

## Command summary

| Command | Does | Key parameters |
|---|---|---|
| `New-Pool.ps1` | create a pool | `-PoolId` (req), `-DisplayName`, `-DesiredState` |
| `Add-HostToPool.ps1` | add a host | `-PoolId` (req), `-HostId` (req) |
| `Remove-HostFromPool.ps1` | remove a host | `-PoolId` (req), `-HostId` (req) |
| `Set-PoolTestSet.ps1` | assign a test-set | `-PoolId` (req), `-Name` (req), `-Order`, `-CycleStrategy` |
| `Set-PoolDesiredState.ps1` | run / pause / drain | `-PoolId` (req), `-State` (req) |
| `Get-PoolStatus.ps1` | read members + test-sets (intent) | `-PoolId` |
| `Test-PoolIntent.ps1` | validate every intent file | — |

All mutating commands support `-WhatIf` (preview) and `-Confirm`, validate against the
schemas **before** writing, and `git commit` + `push` for you. `-IntentGitUrl` defaults to
`pool.intentGitUrl` from `test.config.yml` when omitted. A failed push is reported as a
*warning* (the change is committed locally) — re-run once the remote is reachable. Every
command has full help: e.g. `Get-Help test/Set-PoolTestSet.ps1 -Full`.

## Current limitations

- **`cycleStrategy`** — only `all` is active. `round-robin` and `single` are accepted and
  validated but currently run as `all` (with a warning).
- **`provisioning.betweenSets`** — only `none` is active. `snapshot-revert` and `reprovision`
  run as `none` (with a warning).
- **Assignment is by name** — `Set-PoolTestSet` records the name without checking the manifest
  exists, so always run `Test-PoolIntent.ps1` after editing intent.
- **Two repos.** The test-set *manifests* (`test-sets/*.yml`) live in your **project** repo
  next to the sequences; the *assignment* (the `testSets[]` reference) lives in the **intent**
  repo on the proxy. Keep both in step.

## Advanced: two more optional `pools.yml` blocks

These have no dedicated command yet — author them directly in `pools.yml` (validate with
`Test-PoolIntent.ps1`); see [`test/schemas/pools.schema.yml`](../test/schemas/pools.schema.yml):

- **`config.testCycle`** — override test-cycle knobs for the whole pool (e.g.
  `stepTimeoutMinutes`, `autoRemediationEnabled`); pool value wins over each host's config.
- **`gating`** — pool health-alert thresholds (the healthy-member quorum + how long before a
  pool is flagged "degraded"). Advisory: it drives alerting + the dashboard, never gating a
  cycle. Delivery is configured separately on the alert host (see the notifier docs).

## Default-off + safety

The pool layer is entirely opt-in: a host with no `pool` block, a pool with no members or no
test-sets, or a host that can run none of a set's guests, runs its local `test.runner.yml`
exactly as a standalone host. An unreachable intent store falls back to the last good copy,
then to standalone — a pool never stops a host from testing.

## See also

- [pool-storage.md](pool-storage.md) — optional NAS replication of pool observability data
  (a separate, NAS-only feature).
- [test/extension/pool-aggregator/README.md](../test/extension/pool-aggregator/README.md) —
  the read-only pool dashboard + telemetry collector.
- [test-config.md](test-config.md) — the host-side `pool` config keys.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.10

Back to [Yuruna](../README.md)
