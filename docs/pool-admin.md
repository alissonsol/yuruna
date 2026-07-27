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

- `-HostId` is the host's `runtime/host.uuid` (`42` + 30 hex). The pool dashboard's
  **Host ID** column renders it GUID-dashed for readability, and every pool-admin
  command accepts that form too, so a value copied off the panel works as pasted.
  Membership is the single source of truth and is idempotent — re-adding a host is
  a no-op.
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
- Full field reference: [`test/schemas/pool-test-sets.schema.yml`](../test/schemas/pool-test-sets.schema.yml).

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

## Purging a stale host

`Remove-HostFromPool` only drops a host from ONE pool's `members[]`. A host that
ran cycles also leaves a `hosts/info.<hostId>.yml` identity record plus replicated
cycle folders on the NAS, and — separately — keeps showing on the **Yuruna hosts**
dashboard, which is the pool-aggregator's own polled, in-memory view (each host
kept for the aggregator's host TTL after last contact — 24h by default, set with
`-host-ttl`), *not* the NAS records. To fully retire a
stale host — a disposable `example/nested.host` run, a decommissioned box, an id
that will never return — use:

```powershell
pwsh test/Remove-PoolHost.ps1 -HostId 42<...30 hex...>          # add -WhatIf to preview
```

It (1) reads `networkStorage.poolLocalPath` from `test.config.yml` and deletes
`<poolLocalPath>/hosts/info.<hostId>.yml` + `<poolLocalPath>/<hostId>/`; (2) strips
the id from EVERY pool's `members[]` (needs `pool.intentGitUrl`; without it the NAS
records are still removed and membership is skipped with a warning); and (3) asks
the aggregator to **forget** the host (`POST /api/v1/forget-host`) so it leaves the
dashboard NOW instead of after the host TTL. Step 3 is opt-in + best-effort: it
fires only when a `pool-auth-token` and a caching-proxy are configured (the same
CA-pinned bearer transport as pool push), and a missing token / unreachable
aggregator is a silent skip — the panel still self-clears on the TTL. A host that
is still live is re-discovered on the aggregator's next poll, so stop/drain it
before forgetting. It refuses this host's own uuid, or a record last seen < 24 h
ago, unless `-Force`. Run it on a host with the pool share mounted.

## Command summary

| Command | Does | Key parameters |
|---|---|---|
| `New-Pool.ps1` | create a pool | `-PoolId` (req), `-DisplayName`, `-DesiredState` |
| `Add-HostToPool.ps1` | add a host | `-PoolId` (req), `-HostId` (req) |
| `Remove-HostFromPool.ps1` | remove a host from ONE pool's members | `-PoolId` (req), `-HostId` (req) |
| `Remove-PoolHost.ps1` | **purge** a stale host: delete its NAS records + strip ALL memberships | `-HostId` (req), `-Force`, `-ConfigPath` |
| `Set-PoolTestSet.ps1` | assign a test-set | `-PoolId` (req), `-Name` (req), `-Order`, `-CycleStrategy` |
| `Set-PoolDesiredState.ps1` | run / pause / drain | `-PoolId` (req), `-State` (req) |
| `Get-PoolStatus.ps1` | read members + test-sets (intent) | `-PoolId` |
| `Test-PoolIntent.ps1` | validate every intent file | — |

All mutating commands support `-WhatIf` (preview) and `-Confirm`, validate against the
schemas **before** writing, and `git commit` + `push` for you. `-IntentGitUrl` defaults to
`pool.intentGitUrl` from `test.config.yml` when omitted. A failed push **fails the command**
(non-zero exit): a change committed locally but not pushed is not durable, and a later admin
command discards it — recover by re-running from a writable location (on the proxy: a `file://`
or local path to the bare repo), or delete the admin clone dir to discard the local change and
re-clone from the remote. Every command has full help: e.g. `Get-Help test/Set-PoolTestSet.ps1 -Full`.

## Pool control service

The Pool control service is the operator UI + API for the LAN pool intent. It
serves three pages and drives the pool-intent git store; runners only PULL that
store read-only. Every button routes through the same admin CLIs documented
above, so the UI and the command line cannot diverge.

### What it does

- **Assign** (`/`) &mdash; assign a test-set (a framework/project repo pair) to each
  pool; show members and the copy-config-from-a-peer command.
- **Pools** (`/pools`) &mdash; create a pool (mints its stable `poolGuid`, the
  dashboard "Pool ID"), set desiredState (run/paused/drain), add/remove hosts (a
  host belongs to at most one pool), delete an empty pool.
- **Test sets** (`/test-sets`) &mdash; CRUD the named-triple library
  (`test-sets.yml`). GH_TOKEN is **never** stored here &mdash; it stays host-local.

Assigning copies the chosen library triple into the pool's inline `testSet`; a
pooled runner then overrides its `repositories.frameworkUrl`/`projectUrl` with it
for the cycle and runs the assigned project's own `test.runner.yml`.

### Architecture

A small Go daemon (`test/extension/pool-control/server`, module `pool-control`) that:

- Serves the embedded static pages + a JSON API (`/api/state`, `/api/pool`,
  `/api/pool/testset`, `/api/testset`, ...). Strict page CSP; XSS-safe DOM.
- **Shells out to the PowerShell pool-admin CLIs** (`New-Pool.ps1`,
  `Set-PoolTestSet.ps1`, `Add-HostToPool.ps1`, `Remove-Pool.ps1`,
  `Set-PoolTestSetDefinition.ps1`, `Get-PoolIntent.ps1`) rather than reimplementing
  git + YAML + schema validation + commit/push in Go &mdash; one authoritative
  implementation. A failed push surfaces to the UI as an error (never a silent
  success).
- **Self-announces** to the pool aggregator (beacon, area `pool-control`) and, via
  the `runtime/pool-control.json` marker + `host.registration.json`, appears in the
  Extension hosts table (shown as "Pool control"). Either path alone paints the row.
- Persists an **audit log** (`audit.jsonl`) + **status.json** (last write,
  last-publish outcome, heartbeat, intent-readable, health) under
  `poolNetworkPath/pool-control/` (the pool NAS), surviving restarts. `/healthz`
  serves that status. A monitor loop probes the intent every `--monitor-interval`.

### Running it

**Default &mdash; on its own VM:**

```powershell
pwsh test/Start-PoolControlVM.ps1 [-VMName yuruna-pool-control]
# stop (and tear down the VM) with test/Stop-PoolControlVM.ps1
```

Like Start-CachingProxyVM / Start-StashVM, this brings the service up on a
dedicated VM. `host/vmconfig/pool-control.base.user-data` seeds an Ubuntu guest
that builds the daemon, installs pwsh + `powershell-yaml`, CIFS-mounts the pool NAS
for the state dir, and runs it under systemd (`guest/ubuntu.server.26/ubuntu.server.26.pool-control.sh`).
The per-hypervisor `guest.pool-control/New-VM.ps1` (mirroring the stash VM chain)
generates the seed with `/etc/yuruna/{pool.env,host.env,pool-nas.cifs.cred}` and a
distinct guest username. **No `go` toolchain is needed on the host** &mdash; the
daemon is built inside the guest. The Extension-hosts row then points at the VM
(beacon self-IP); deleting the VM clears it after the announce TTL.

After the VM boots, the launcher waits for the daemon to actually serve on `:80`
(up to 15 min; override with `YURUNA_POOL_CONTROL_READY_TIMEOUT=<seconds>`) before
reporting success &mdash; an IP alone is not "up", since the guest still has to
build the daemon. If `:80` never comes up, it pulls the in-guest build log,
`cloud-init status`, and the `pool-control.service` journal over the harness SSH
key and prints them, so a failed build shows you the reason instead of a dead URL.
(That log is root-only; the harness `yuruna` account has NOPASSWD `sudo`, so
`sudo tail /var/log/cloud-init-output.log` reads it &mdash; a plain `tail` returns
`Permission denied`.)

**Host-side (proof / fallback):**

```powershell
pwsh test/Start-PoolControlVM.ps1 -HostSideProof [-Port 8090] [-AggregatorUrl <url>]
# UI at http://<host>:8090/ ; stop with test/Stop-PoolControlVM.ps1
```

`-HostSideProof` builds + runs the daemon directly on this host instead of a VM.
Needs `go` + `pwsh` on PATH and the framework checkout (the CLIs live at
`<repo>/test/*.ps1`).

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

- [control-routes.md](control-routes.md) — what a host accepts from the dashboard's action
  buttons, and the one-time `pool-auth-token` setup that enables them from another machine.
- [pool-storage.md](pool-storage.md) — optional NAS replication of pool observability data
  (a separate, NAS-only feature).
- [test/extension/pool-aggregator/README.md](../test/extension/pool-aggregator/README.md) —
  the read-only pool dashboard + telemetry collector.
- [test-config.md](test-config.md) — the host-side `pool` config keys.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.26

Back to [Yuruna](../README.md)
