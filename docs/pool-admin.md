<a id="4207d71a-0001"></a>

# Yuruna pool admin guide -- assign test sequences to a host pool

> **Who this is for.** A **pool administrator / operator** running several Yuruna test
> hosts who wants them to share work and report together. It is *not* a guide to writing
> test sequences or harness code, and assumes the test **sequences already exist** (the
> ones a single host runs from `test.runner.yml`); your job here is to point a set of
> hosts at the project that runs them.

<a id="4207d71a-0002"></a>

## What a pool is

A **pool** is a named group of test hosts that run the same assigned work and report
under one label (the `poolId`). You manage a pool by editing one small file
of **intent** -- `pools.yml` -- through a handful of admin commands. You never touch the
hosts directly: each runner **pulls** the intent every cycle and acts on it.

Intent has three parts:

- **members** -- which hosts belong to the pool (by their stable host id).
- **test-set** -- which framework/project repo pair the pool runs; the assigned
  project's own `test.runner.yml` is the work.
- **desiredState** -- whether the pool is running, paused, or draining.

```
  you --run--> admin CLI --writes--> pools.yml  (intent git repo on the caching-proxy-service)
                                          |
  every host --pulls read-only each cycle-+--> runs the assigned test-set, reports under <poolId>
```

The intent repo holds **only non-secret** files (`pools.yml`, the `test-sets.yml`
library, `guests.compatibility.yml`). No credential is ever routed through it.

<a id="4207d71a-0003"></a>

## Before you start

1. **The intent store exists.** The caching-proxy-service VM seeds a bare git repo at
   `/var/lib/yuruna/pool-intent.git` and serves it **read-only over HTTP** at
   `http://<proxy>/pool-intent.git`. Set up automatically when the caching-proxy-service is
   provisioned.
2. **Each host has opted in.** In each host's `test/test.config.yml`, set the `pool` block:
   ```yaml
   pool:
     enabled: true
     intentGitUrl: http://<proxy>/pool-intent.git   # the READ-ONLY HTTP url
     localClonePath: ''                              # optional; defaults under runtime/
   ```
   A host with `pool.enabled: false` (the default) runs standalone.
3. **You know each host's id.** Every host has a stable id in `runtime/host.uuid` -- a
   `42`-prefixed 32-hex string, also shown as `hostId` on the host's own status page and
   on the pool dashboard. Anywhere a FULL one is put in front of you it is spelled
   GUID-dashed (`42abcdef-0123-4567-89ab-cdef01234567`); the stores hold the bare hex.
4. **You can write the intent repo.** The HTTP URL above is read-only. The admin commands
   need a **writable** path/URL, so run them **on the caching-proxy-service** against the local repo
   (`/var/lib/yuruna/pool-intent.git`), or against any pre-authenticated writable remote.
   Pass it with `-IntentGitUrl <writable-url>`, or set `pool.intentGitUrl` to a writable
   value in the `test.config.yml` you run the admin CLI from (then you can omit the flag).

Run the commands below from the repo root.

<a id="4207d71a-0004"></a>

## Step 1 -- Create the pool

```powershell
pwsh test/pool/New-Pool.ps1 -PoolId lab -DisplayName 'Lab pool' -IntentGitUrl <writable-url>
```

- `-PoolId` is a short, lowercase, DNS-safe name (`a-z 0-9 -`). It becomes the **permanent
  label** for this pool's telemetry on the dashboard, so pick it deliberately -- renaming it
  later forks the history.
- The pool starts empty (`desiredState: run`, no members, no test-set).

<a id="4207d71a-0005"></a>

## Step 2 -- Add the hosts

Run once per host:

```powershell
pwsh test/pool/Add-HostToPool.ps1 -PoolId lab -HostId 42abcdef0123456789abcdef01234567 -IntentGitUrl <writable-url>
```

- `-HostId` is the host's `runtime/host.uuid` (`42` + 30 hex). The pool dashboard's
  **Host ID** column shows its first 8 characters and reveals the full id GUID-dashed
  from the cell's own menu; every pool-admin command accepts that form, so a value
  copied off the panel works as pasted, and each command echoes it back the same way.
  Membership is the single source of truth; re-adding a host is a no-op.
- To remove a host later, see **Step 6** below (drain it first if it is running).

<a id="4207d71a-0006"></a>

## Step 3 -- Define the test-set (a framework/project repo pair)

A **test-set** is `{name, frameworkUrl, projectUrl}`. Assigning one to a pool makes every member
override its own `repositories.frameworkUrl` / `repositories.projectUrl` with the
pair for the cycle and run the assigned project's own `test.runner.yml` plan.
`GH_TOKEN` is never stored in pool intent; it stays host-local.

Register the pair in the intent store's test-set library (`test-sets.yml`, the
store behind the pool-control service "Test sets" page):

```powershell
pwsh test/pool/Set-PoolTestSetDefinition.ps1 -Name smoke -FrameworkUrl <framework-url> -ProjectUrl <project-url> -IntentGitUrl <writable-url>
```

- The library keeps the UI and CLI views consistent; for CLI-only use it is
  optional -- Step 4's `Set-PoolTestSet.ps1` takes the URLs directly.
- Full field reference: [`test/schemas/pool-test-sets.schema.yml`](../test/schemas/pool-test-sets.schema.yml).

<a id="4207d71a-0007"></a>

## Step 4 -- Assign the test-set to the pool

```powershell
pwsh test/pool/Set-PoolTestSet.ps1 -PoolId lab -Name smoke -FrameworkUrl <framework-url> -ProjectUrl <project-url> -IntentGitUrl <writable-url>
```

- A pool holds **exactly one** `testSet`; assigning replaces the previous one (a
  legacy `testSets[]` array is dropped on write).
- The URLs are recorded inline in `pools.yml`, so the assignment is
  self-contained -- no file in the project repo is involved.
- Nothing probes the URLs at assignment time: a typo first surfaces when a
  member's next cycle tries to clone.

<a id="4207d71a-0008"></a>

## Step 5 -- Verify

```powershell
pwsh test/pool/Test-PoolIntent.ps1             # schema-validates pools.yml (+ guests.compatibility.yml); host-in-one-pool invariant
pwsh test/pool/Get-PoolStatus.ps1 -PoolId lab  # shows members, desiredState, and the assigned test-set
```

There is nothing to "deploy": each runner picks up the new intent at the start of its
**next cycle**, so no host restart is needed. Once a pooled host completes a cycle,
confirm it took effect on the **Yuruna hosts** Grafana dashboard (it groups every host under
your `poolId`), or directly: `curl -sk https://<proxy>:9400/api/v1/pool-status`.

<a id="4207d71a-0009"></a>

## Step 6 -- Operate the pool

```powershell
pwsh test/pool/Set-PoolDesiredState.ps1 -PoolId lab -State paused -IntentGitUrl <writable-url>   # run | paused | drain
pwsh test/pool/Remove-HostFromPool.ps1  -PoolId lab -HostId 42<...30 hex...> -IntentGitUrl <writable-url>
```

- **run** -- cycle normally.
- **paused** -- finish the in-flight cycle, then hold (re-checking every ~30 s) until you set
  it back to `run`.
- **drain** -- stop after the current cycle; the runner process exits. Re-add the host and
  restart its runner to rejoin.
- **Removing a running host:** set `drain` first, let it stop, then `Remove-HostFromPool`.

In-flight cycles always finish, so pause/drain never corrupt an accumulating run.

<a id="4207d71a-000a"></a>

## Purging a stale host

`Remove-HostFromPool` only drops a host from ONE pool's `members[]`. A host that
ran cycles also leaves a `hosts/info.<hostId>.yml` identity record plus replicated
cycle folders on the NAS, and -- separately -- keeps showing on the **Yuruna hosts**
dashboard, which is the pool-aggregator-service's own polled, in-memory view (each host
kept for the aggregator's host TTL after last contact -- 24h by default, set with
`-host-ttl`), *not* the NAS records. To fully retire a stale host -- a disposable
`example/nested.host` run, a decommissioned box, an id that will never return -- use:

```powershell
pwsh test/pool/Remove-PoolHost.ps1 -HostId 42<...30 hex...>          # add -WhatIf to preview
```

It (1) reads `networkStorage.poolStorageLocalPath` from `test.config.yml` and deletes
`<poolStorageLocalPath>/hosts/info.<hostId>.yml` + `<poolStorageLocalPath>/<hostId>/`; (2) strips
the id from EVERY pool's `members[]` (needs `pool.intentGitUrl`; without it the NAS
records are still removed and membership is skipped with a warning); and (3) asks
the aggregator to **forget** the host (`POST /api/v1/forget-host`) so it leaves the
dashboard NOW instead of after the host TTL. Step 3 is opt-in + best-effort: it
fires only when an internal authentication key and a caching-proxy-service are configured (the same
CA-pinned bearer transport as pool push), and a missing token / unreachable
aggregator is a silent skip -- the panel still self-clears on the TTL. A host that
is still live is re-discovered on the aggregator's next poll, so stop/drain it
before forgetting. It refuses this host's own uuid, or a record last seen < 24 h
ago, unless `-Force`. Run it on a host with the pool share mounted.

<a id="4207d71a-000b"></a>

## Command summary

Every command below lives in `test/pool/`.

| Command | Does | Key parameters |
|---|---|---|
| `New-Pool.ps1` | create a pool | `-PoolId` (req), `-DisplayName`, `-DesiredState` |
| `Add-HostToPool.ps1` | add a host | `-PoolId` (req), `-HostId` (req) |
| `Remove-HostFromPool.ps1` | remove a host from ONE pool's members | `-PoolId` (req), `-HostId` (req) |
| `Remove-PoolHost.ps1` | **purge** a stale host: delete its NAS records + strip ALL memberships | `-HostId` (req), `-Force`, `-ConfigPath` |
| `Set-PoolTestSet.ps1` | assign the pool's one test-set (replaces) | `-PoolId` (req), `-Name` (req), `-FrameworkUrl` (req), `-ProjectUrl` (req) |
| `Set-PoolTestSetDefinition.ps1` | upsert/delete a library test-set | `-Name` (req), `-FrameworkUrl`, `-ProjectUrl`, `-Delete` |
| `Set-PoolDesiredState.ps1` | run / pause / drain | `-PoolId` (req), `-State` (req) |
| `Get-PoolStatus.ps1` | read members + the assigned test-set (intent) | `-PoolId` |
| `Get-PoolIntent.ps1` | dump the whole intent store as JSON (what the dashboard reads) | -- |
| `Test-PoolIntent.ps1` | validate the intent files | -- |
| `Convert-ToPoolWorker.ps1` | turn a standalone machine into a worker of an existing lab | `-ReferenceHost` (req), `-InternalAuthKey`, `-KeepCachingProxy` |

All mutating commands support `-WhatIf` (preview) and `-Confirm`, validate against the
schemas **before** writing, and `git commit` + `push` for you. `-IntentGitUrl` defaults to
`pool.intentGitUrl` from `test.config.yml` when omitted. A failed push **fails the command**
(non-zero exit): a change committed locally but not pushed is not durable, and a later admin
command discards it -- recover by re-running from a writable location (on the proxy: a `file://`
or local path to the bare repo), or delete the admin clone dir to discard the local change and
re-clone from the remote. Every command has full help: e.g. `Get-Help test/pool/Set-PoolTestSet.ps1 -Full`.

<a id="4207d71a-000c"></a>

## Pool-control service

The Pool-control service is the operator UI + API for the LAN pool intent. It
drives the pool-intent git store; runners only
PULL that store read-only. Every button routes through the admin CLIs above,
so the UI and the command line cannot diverge.

<a id="4207d71a-000d"></a>

### What it does

- **Assign** (`/assign`) &mdash; assign a test-set to each pool; show members
  and the copy-config-from-a-peer command.
- **Pools** (`/pools`) &mdash; create a pool (mints its stable `poolGuid`, the
  dashboard "Pool ID"), drive every member's **Pool Status** (below), add/remove
  hosts (a host belongs to at most one pool), delete an empty pool.
- **Hosts** (`/hosts`) &mdash; every host the aggregator knows *and* every host
  the network scan found, not just pool members, so a host that was never
  auto-enrolled &mdash; or never registered at all &mdash; is visible along with
  the reason. Columns: **Host ID** (links to that host's status page),
  **Hostname**, **Type** (the host type without its `host.` prefix, e.g.
  `ubuntu.kvm`), **Memory**, **Cores**, **Total Storage** and **Free Storage**
  (each host's own report of its hardware, read from its status service),
  **Control** (the wire value: `ready` / `none` / `mismatch` /
  `skew`), **Framework** and **Project** (below), and the
  **Pool** picker, which *moves* the host.
  Storage is what the machine keeps: each space pool counts once &mdash; the
  volumes of one APFS container are a single 2 TB pool, not five &mdash; and
  attached storage (a USB or Thunderbolt drive, a card, a mounted image, a
  network share) is left out, since it cannot be planned against and a share
  would otherwise be counted once per host that mounts it.
  **Hostname** is the one column withheld from an uncredentialed read &mdash;
  the pool's own view of a host is deliberately hostname-free and this page
  renders unattended too, so the name arrives only once the browser is
  unlocked (below). **Show hostnames** prompts for the Lab token; arriving from
  the dashboard link unlocks the page on its own.
- **Scan** (`/scan`) &mdash; sweep a network for Yuruna hosts and add the ones
  that answer to the monitored list, pool member or not (below).
- **Test sets** (`/test-sets`) &mdash; CRUD the named-triple library
  (`test-sets.yml`). GH_TOKEN is **never** stored here.

Assign, Hosts, Pools and Test sets sort on any column header &mdash; clicking the
sorted one reverses it, and the columns that hold a control sort on the value
that control shows now (**Assign test set** on the set the pool holds, **Members**
on how many there are). The order survives the page's own minute-by-minute
re-read, so a table left sorted stays that way. Each of those tables opens with a
counter column that numbers the rows *as shown*: it reads 1&hellip;n down the page
whatever the sort, which is how many pools, hosts or test-sets there are.

Assigning copies the chosen library triple into the pool's inline `testSet`;
members then behave exactly as on the CLI path in Steps 3-4 above.

<a id="4207d71a-000e"></a>

### Framework and Project -- which repositories is each host on?

The two repository columns on `/hosts` are each host's own account of what it
runs on: the **framework** checkout its status service runs from, and the
**project** clone beside it. Each cell names the repository -- the last segment
of that clone's `remote.origin.url`, so `https://github.com/alius-git/amisad.dev`
reads `amisad.dev` -- which makes the table a lab-wide inventory: one glance says
which machines are on `yuruna` and which on a fork of it, and which project each
is testing.

Each cell also **links** to that repository, so a name that is not the one you
expected is one click from the repository itself rather than a url to retype.
The link is the host's own `remote.origin.url`, wherever it points: an ssh
remote (`git@github.com:owner/repo.git`) opens as its `https://` equivalent, and
a host running from a **local copy** links to that path as a `file:` url -- most
browsers will not follow one from a served page, but it still names the location
and copies. A credential written into a remote is stripped at the host, before
the url is served. A cell whose host reported no url at all stays plain text.

| Value | What it means | What to do |
| --- | --- | --- |
| a repository name | the clone this host holds, named by its own `remote.origin.url`, and linked to it | nothing |
| **`No access`** | the host was configured with a repository it cannot read -- a credential without access, or a url that did not answer. It links to the url that failed | grant that host's `GH_TOKEN` access to the repo, or fix the url in its `test.config.yml` |
| `--` | the host has no such clone *and* none configured (the in-tree project layout), or it has not answered yet | nothing |

The clone answers before the network does: it is what the machine actually
tracks -- which is not always the configured url, since a pool assignment
overrides that for a cycle -- and it costs no round trip. Only a host with no
readable clone probes the url it was configured with, which is what separates
"cannot read it" from "has not cloned it yet"; that probe runs *after* the
answer is sent, so it can never make a host's other columns time out with it,
and such a host reads `--` for one refresh before its answer arrives. Like the
hardware columns, these are read on page load and on **Refresh**, not on the
footer countdown.

<a id="4207d71a-000f"></a>

### Project access -- can each host read what its pool assigned?

A pool can hand a host a `projectUrl` that host's git credential cannot read:
the assignment is made centrally, the credential is host-local, and `GH_TOKEN`
deliberately never travels in pool intent. So each host also runs a
`git ls-remote` against a **pool-assigned** url at the top of a cycle *before*
the clone -- the problem is named at the host that has it, rather than surfacing
minutes later as a generic bootstrap error. Only a pool-assigned url is probed
this way; a host's own `projectUrl` is already preflighted by the clone, and
probing it twice would cost every unpooled host a round trip for nothing.

That answer rides in the host's registration record, and it is a different
question from the columns above -- *what the pool told this host to read*, not
*what the host holds*. It surfaces as the board's pool-level attention flag,
and as a tooltip on the host's **Project** cell.

| Value | What it means | What to do |
| --- | --- | --- |
| `ok` | the probe read the assigned project | nothing |
| `denied` | this host's git credential cannot read the assigned project -- a private repo, or a token without access to it | grant that host's `GH_TOKEN` access to the repo, **or** reassign the pool to a project every member can read |
| `unreachable` | the repo did not answer -- network or DNS, not permission | nothing; it is transient, and the cycle's clone retries through the normal backoff |
| absent | no probe ran: the host is in no pool, its pool assigned no test-set, the host did not answer, or the aggregator is unavailable | nothing |

`denied` **fails that host's cycle**, and the host does *not* fall back to its
own project: a green cycle running something the pool never assigned would
misreport the pool's coverage. It is classed `project_access_denied`, which
routes to operator intervention instead of consuming auto-remediation attempts
on a problem no retry can fix -- so every member of a pool with a bad assignment
goes red until someone acts, which is the intended loudness. The board names the
same hosts as a pool-level attention flag, which is advisory and changes no
state.

One timing caveat: a host publishes `host.registration.json` before the pool's
repositories override it, so this answer describes the *previous* cycle's view.
Immediately after an assignment, expect one cycle in which it has not caught up
yet.

<a id="4207d71a-0010"></a>

### Pool Status — pausing and continuing every member at once

The **Pool Status** column on `/pools` is the Pause/Continue buttons of every
member's own status page, driven from one place. It offers exactly what a single
host offers:

| Choice | What each member does |
| --- | --- |
| **Continue** | carry on with whatever it was doing (both pause switches cleared) |
| **Pause after cycle** | finish the cycle in flight, then hold |
| **Pause after step** | finish the step in flight, then hold |

A host has two independent pause switches, and choosing one of the three here
leaves **at most one** of them armed on every member &mdash; so the column always
names something a host is really doing. The cell shows what the members report
right now: one of the three when they all agree, **Mixed** when they differ or a
member did not answer (the disagreeing hosts are then listed under the
selector), `--` when none answered. Hosts stay individually controllable from
their own status pages; this changes them all and then reads them back.

This is **not** the pool's `desiredState` (`run`/`paused`/`drain`): that one
is durable intent in git, reconciled at a cycle
boundary, and `drain` ends the runner process. Pool Status acts on the live
pause switches instead &mdash; what "hold the lab now, then let it carry on"
means mid-cycle. `desiredState` has no page of its own; write it with
`Set-PoolDesiredState.ps1` (table above).

Driving another host's control routes needs a **control proof** (see
[control-routes.md](control-routes.md)), which the service obtains one of two
ways, in order:

1. the internal authentication key from `--auth-token-file`
   (default `/etc/yuruna/internal-auth.key`), if present &mdash; no round trip; or
2. the pool aggregator's `/go/host` redirect, the identical proof a browser
   receives from a dashboard host link.

Nothing bakes that token file into a service VM, so path 2 is what normally
carries this. When neither is available the change is refused **once**, naming
the file, rather than collecting one `403` per host.

Members are driven individually and reported individually: `2 applied, 1 failed
-- 42ab12cd (the host holds no lab token ...)`. A host that was never enrolled, is
powered off, or holds a different Lab token fails on its own without costing the
others their change. Every fan-out is written to the audit log with how much of
it landed.

<a id="4207d71a-0011"></a>

### Architecture

A small Go daemon (`test/extension/pool-control-service/server`, module `pool-control-service`) that:

- Serves the embedded static pages + a JSON API. Strict page CSP; XSS-safe DOM.
  The full surface, split by the gate each route sits behind:

  | Auth | Routes |
  |---|---|
  | open (GET) | `/healthz`, `/api/hostinfo`, `/api/session`, `/api/board`, `/api/hosts`, `/api/hosts/facts`, `/api/state`, `/api/scan`, `/api/diagnostics`, `/api/pool/host-control` |
  | open (POST) | `/api/login`, `/api/unlock-proof` -- the two ways INTO the gate |
  | lab-token | `/api/pool` (POST, DELETE), `/api/pool/desired-state`, `/api/pool/host`  (POST, DELETE), `/api/pool/move-host`, `/api/pool/testset`, `/api/pool/host-control`, `/api/scan`, `/api/scan/forget`, `/api/testset` (POST, DELETE) |

  Reads are open on the trusted LAN so a wall display needs no credential;
  everything that rewrites pool configuration goes through `gate.Require`.
- **Reads the aggregator's `GET /api/v1/pool-stats`** for the numbers on the
  board's cards: per-**host** terminal-cycle counts over a preset window.
  Per-host rather than per-pool because that route returns only what Loki can
  answer, and pool membership lives in the intent store the aggregator has never
  read -- its sole notion of a pool is the `poolId` a host self-advertises. The
  control service owns the join, because it already reads `members[]`. That
  split is what lets the board render a card for a pool whose hosts are all
  silent (`0` reporting) instead of that pool vanishing because no Loki stream
  happened to mention it. Read-only and open, like `pool-status`.
- **Shells out to the PowerShell pool-admin CLIs** in `test/pool/` (`New-Pool.ps1`,
  `Set-PoolTestSet.ps1`, `Add-HostToPool.ps1`, `Remove-Pool.ps1`,
  `Set-PoolTestSetDefinition.ps1`, `Get-PoolIntent.ps1`) rather than reimplementing
  git + YAML + schema validation + commit/push in Go &mdash; one authoritative
  implementation. A failed push surfaces to the UI as an error.
- **Drives the members' own control routes** for Pool Status
  (`/api/pool/host-control`): the one thing here that acts on other machines
  rather than on the intent store. Membership comes from intent and addresses
  from the aggregator, because the aggregator's notion of a pool is a label a
  host self-advertises &mdash; it cannot say who belongs.
- **Self-announces** to the pool-aggregator service (beacon, area `pool-control-service`) and, via
  the `runtime/pool-control-service.json` marker + `host.registration.json`, appears in the
  Extension hosts table (shown as "Pool-control service"). Either path alone paints the row.
- Persists an **audit log** (`audit.jsonl`) + **status.json** (last write,
  last-publish outcome, heartbeat, intent-readable, health) under
  `poolStorageNetworkPath/pool-control-service/` (the pool NAS), surviving restarts. `/healthz`
  serves that status. A monitor loop probes the intent every `--monitor-interval`.

<a id="4207d71a-0012"></a>

### Unlocking the actions

Everything this service changes **is** pool configuration &mdash; which pools
exist, which hosts belong to them, which test-set each one runs &mdash; so every
mutating route takes the write gate that
[docs/extensions-api.md](extensions-api.md#the-lab-token-rule) applies to every
extension service:

- **From a browser**, the first change you attempt prompts for the rotating
  6-character **Lab token** the Yuruna hosts dashboard shows on its own tile.
  Entering it exchanges the code for a session cookie (7 days, HttpOnly,
  SameSite=Lax so the dashboard deep-link keeps it) and re-sends the change you
  were making. There is nothing to set up: the daemon already knows the
  aggregator, and the aggregator owns the codes.
- **From automation**, send the internal authentication key as
  `Authorization: Bearer ...`. The daemon reads it from `--auth-token-file`
  (default `/etc/yuruna/internal-auth.key`, absent by default). Nothing bakes that
  file into the VM seed, so the bearer is opt-in: drop the token there yourself
  on a service VM that automation drives.

**Reads are open**, matching the aggregator's own `pool-status` and every other
extension service: the board renders on a wall display with no credential, and
nothing it shows is a secret the LAN cannot already read from the pool.

An aggregator that is down means the board cannot be unlocked &mdash; a
deliberate fail-closed, reported as `503` with reason `lab-token-unavailable`
rather than as a wrong code, so an operator does not retype a correct one until
they give up.

<a id="4207d71a-0013"></a>

### Running it

**Default &mdash; on its own VM:**

```powershell
pwsh test/service/Start-PoolControlServiceVM.ps1 [-VMName yuruna-pool-control-service]
# stop (and tear down the VM) with test/service/Stop-PoolControlServiceVM.ps1
```

Like Start-CachingProxyServiceVM / Start-StashServiceVM, this brings the service up on a
dedicated VM. `host/vmconfig/pool-control-service.base.user-data` seeds an Ubuntu guest
that builds the daemon, installs pwsh + `powershell-yaml`, CIFS-mounts the pool NAS
for the state dir, and runs it under systemd (`guest/ubuntu.server.26/ubuntu.server.26.pool-control-service.sh`).
The per-hypervisor `guest.pool-control-service/New-VM.ps1` (mirroring the stash-service VM chain)
generates the seed with `/etc/yuruna/{pool.env,host.env,pool-nas.cifs.cred}` and a
distinct guest username. **No `go` toolchain is needed on the host.** The
Extension-hosts row then points at the VM (beacon self-IP); deleting the VM
clears it after the announce TTL.

After the VM boots, the launcher waits for the daemon to serve on `:80`
(up to 15 min; override with `YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS=<seconds>`) before
reporting success &mdash; an IP alone is not "up": the guest still has to build
the daemon. If `:80` never comes up, it pulls the in-guest build log,
`cloud-init status`, and the `pool-control-service.service` journal over the harness SSH
key and prints them, so a failed build shows you the reason instead of a dead URL.
(That log is root-only; the harness `yuruna` account has NOPASSWD `sudo`, so
`sudo tail /var/log/cloud-init-output.log` reads it &mdash; a plain `tail` returns
`Permission denied`.)

**Host-side (proof / fallback):**

```powershell
pwsh test/service/Start-PoolControlServiceVM.ps1 -HostSideProof [-Port 8090] [-AggregatorUrl <url>]
# UI at http://<host>:8090/ ; stop with test/service/Stop-PoolControlServiceVM.ps1
```

`-HostSideProof` builds + runs the daemon directly on this host instead of a VM.
Needs `go` + `pwsh` on PATH and the framework checkout (the CLIs live at
`<repo>/test/*.ps1`).

<a id="4207d71a-0014"></a>

### Auto-enrollment

A host that has enrolled its Lab token, and is in **no pool at all**, can join a
pool without you adding it. It **ships off**: the sweep runs only when an
`autoEnrollment` block in the intent store's `pools.yml` names a target pool
*and* the daemon runs with `--auto-enroll` (`--auto-enroll-interval`, default 60s,
sets the cadence).

Once on, each tick does exactly this and no more:

- **Candidates are hosts whose `control` field is `ready` on the wire.**
  "Remote" and "onsite" are Grafana *display* mappings of that same field and
  appear nowhere in the API &mdash; a predicate written against those words
  matches zero hosts forever, and looks exactly like "nothing needed enrolling".
- **Only hosts in zero pools are added.** That preserves "a host belongs to at
  most one pool" by construction, and means the sweep can never move a host you
  placed deliberately.
- **`autoEnrollment.excluded[]` is honored**, so a host you removed from the
  target pool is never re-added &mdash; otherwise you and a 60-second timer would
  fight forever.
- **Nothing to do means nothing happens**: no commit, no push, no audit row.
- **Every tick logs the candidate count**, so "never enrolls anyone" reads
  differently from "nothing to enroll".

Failure is **bounded, not atomic**. Each host is its own CLI run, commit and
push, so a failure partway through leaves the earlier hosts enrolled. Enrollment
is idempotent and resumable, so the next tick finishes the job.

<a id="4207d71a-0015"></a>

### Network scan -- finding hosts nobody registered

A host reaches the pool's pages by registering with the aggregator. A machine
that is running a Yuruna status service but has never enrolled is therefore
invisible to every pool UI, even while it sits on the same subnet answering
probes. The **Scan** page asks the network instead.

**What it does.** Every address in the network you give it is asked for
`/livecheck` on the host status-service port (8080 by default,
`--scan-port`). An address counts as a Yuruna host only when that answer
*identifies itself* as `yuruna-status-service` &mdash; a 200 from some other web
server on the same port is not enough. Each host that answers is then asked for
its own registration record, which is where its host id, hostname and type come
from; a host that will not name itself is still recorded, by address.

**What it does not do.** Nothing on the scanned hosts changes, and pool intent
is never written: a discovered host is **monitored, not enrolled**. It appears
on the Hosts page marked `discovered`, in no pool, with its **Control** column
blank &mdash; that is the pool's reading of a *member*. Its hardware and
repository columns still fill in: those are the host's own answer about itself,
asked for at the address the sweep reached it at.
Its **address** is the link to its status page, and its host id is plain text:
a pool host's id links through the aggregator's `/go/host`, which resolves what
that host registered, and a discovered host registered nothing &mdash; so the
address, where the scan just got an answer, is the one way in that works.
Putting it in a pool stays your decision, made with that row's Pool picker.
(A host that never reported an id cannot be put in a pool at all, because
membership is recorded against the id; its picker says so.)

**The range, in CIDR notation.** An address and a prefix length:
`192.168.7.0/24` is the 254 machines whose first three numbers are `192.168.7`.
A larger prefix length covers fewer addresses (`/32` is one machine); a smaller
one covers more. Typing an address inside the network is fine &mdash;
`192.168.7.34/24` means the same subnet. The field says how many addresses your
entry covers before you press Scan, and refuses anything over **4096 addresses**
(narrower than `/20`): a mistyped `/8` is one keystroke from `/24` and would put
sixteen million connection attempts onto the lab network.

**The sweep.** The same scan runs on its own every **15 minutes**
(`--scan-interval`, `0` turns the timer off and leaves the page's button as the
only way to scan). With no `--scan-cidr` it sweeps the `/24` around the
service's own address, re-derived each time so a service that changed subnet
sweeps the one it is on now. A sweep that lands while you are running a scan is
skipped rather than queued.

**What the page shows.** The addresses being probed as they go by, how far the
run has got, and then only the hosts it **added** &mdash; a Yuruna host that was
already monitored is counted, not listed again. Below that is everything
discovery has ever found, with first- and last-seen times and a **Forget**
button for a machine that has been retired. Starting a scan and forgetting a
host both need the Lab token; reading the page does not.

The list is this service's own, kept beside the audit log under `--state-dir`
(`discovered-hosts.json`), so it survives an aggregator outage &mdash; which is
the case it exists for. With no state dir it lives in memory and is rebuilt by
the next sweep.

<a id="4207d71a-0016"></a>

## Download-agent service

The Download-agent service is the pool's shared guest-image downloader. It keeps
a **Download pool** on the pool NAS (`<pool root>/images/...`), re-verifies each
image against its origin on a schedule, and serves the artifacts to hosts over
HTTP -- so a lab pulls an ISO or cloud image from the internet once instead of
once per host. It needs pool storage configured -- without a share the service
is skipped.

<a id="4207d71a-0017"></a>

### What it does

- **Holds the pool.** One entry per `(hostType, imageKey, arch, variant)`, stored
  under generation names (upstream filename + the artifact's SHA-256 prefix) with
  a small `current.<arch>.<variant>.json` pointer that is written last, so a
  refresh never renames over a file a host is streaming. The current generation
  plus one previous is retained.
- **Keeps it fresh.** A background scanner walks the pool every
  `downloadAgentService.scanIntervalSeconds` and acts on anything expiring within
  `prefetchLeadSeconds` of its `freshnessSeconds` budget. Freshness probes go
  **direct** to the origin, never through the Squid cache -- a proxied HEAD would
  return frozen prewarm-era headers and certify staleness as freshness. Byte
  downloads do use the cache, falling back to direct on any proxy failure. When a
  refresh fails, the previous verified artifact stays servable.
- **Seeds itself.** With `autoSeed` on (the default) it reads the pool
  aggregator's host roster, derives the host types actually present, and
  pre-downloads the stable families for them. Hosts the aggregator has no status
  for are covered on demand instead.
- **Announces itself.** A beacon to the pool-aggregator service plus the
  `runtime/download-agent-service.json` marker put it in the dashboard's
  Extension hosts table as "Download-agent service", deep-linking to its UI.

<a id="4207d71a-0018"></a>

### The UI and its three actions

The daemon serves a single-page UI at `http://<agent-vm-ip>/` -- the agent
header (version, pool availability, lease state, scanner cadence, last seed
outcome), one row per image with its state badge, current filename, size on disk,
`lastVerifiedAt` and time-to-expiry, checksum verdict, source URL, and live
progress for in-flight downloads, plus a totals row answering "what is eating the
share". Reads are open on the LAN. Three per-row actions are gated:

- **Force refresh** -- re-verify against the origin now; download only if it
  changed. Also usable on an absent row to trigger a first download.
- **Delete** -- cancel any in-flight download, remove the pointer first, then
  every generation and sidecar. The next host request or seed pass re-downloads
  from the origin; this is the "force a new download" path. Hosts' local copies
  are untouched.
- **Prune previous** -- drop only the previous generation to reclaim space; the
  current one stays servable.

Each action is appended to `<pool root>/download-agent-service/audit.jsonl`. The
same three exist as API routes for automation, which also accept the shared
internal authentication key as a bearer.

<a id="4207d71a-0019"></a>

### Unlocking the actions

**Usually there is nothing to unlock.** Open a service UI from the *Yuruna
hosts* dashboard's *Extension hosts* table and it arrives already unlocked: that
link goes through the aggregator's `/go/stash` redirect, which hands the page a
short-lived control proof in the URL fragment (never sent to a server, never in
an access log), and the page exchanges it for a session on arrival. The prompt
below is what you see when there is no proof to spend -- the page was opened by
typing its address, or bookmarked, or the proof expired while the tab sat open.

The board's **Unlock actions** prompt takes the rotating 6-character **Lab
token** the Yuruna hosts dashboard already displays on its own tile -- the same
code `test/lab/Set-LabToken.ps1` redeems to enroll a host. Read it off the tile,
type it in, and that browser stays unlocked for a week. Nothing is provisioned
or stored on the agent VM.

The daemon does not judge the code itself: it forwards it to the aggregator's
`POST /api/v1/lab-token` exchange, which owns the rotation. So an aggregator
that is down means the board cannot be unlocked -- a deliberate fail-closed,
answered as `503 lab-token-unavailable` rather than as "wrong code". Automation
is unaffected; the same routes take `Authorization: Bearer <internal-auth-key>`.

The code is public on the LAN by construction (the aggregator publishes it on
its open `/metrics`). It stops a stray click on Delete; it is not a secret, and
it is worth having because it expires on its own.

With neither an aggregator to ask nor an internal authentication key configured the mutating
routes answer `503` -- never an ungated write.

<a id="4207d71a-001a"></a>

### Running it

```powershell
pwsh test/service/Start-DownloadAgentServiceVM.ps1 [-VMName yuruna-download-agent-service]
# stop (and tear down the VM) with test/service/Stop-DownloadAgentServiceVM.ps1
```

Like the pool-control service, the daemon is built **inside** the guest (no host
`go` toolchain) from `host/vmconfig/download-agent-service.base.user-data` +
`guest/ubuntu.server.26/ubuntu.server.26.download-agent-service.sh`, which
CIFS-mounts the pool share at `/mnt/yuruna-pool`. The launcher waits for the
daemon to serve on `:80` (up to 15 min; override with
`YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS=<seconds>`) and pulls the
in-guest build log and journal when it does not. `install/setup.ps1` runs the
stop/start pair for you in both modes whenever storage is configured, and never
fails setup on it. Config keys:
[test-config.md](test-config.md#downloadagentservice--the-pool-wide-image-downloader).

<a id="4207d71a-001b"></a>

## Design choices

- **One test-set per pool** -- split hosts into two pools to run two bodies of
  tests side by side.
- **Assignment is not probed** -- `Set-PoolTestSet` records the repo URLs without
  cloning them, and `Test-PoolIntent.ps1` checks shape, not reachability.
- **Members do not split the work** -- every member runs the assigned project's
  full `test.runner.yml` plan; there is no per-guest scheduling across members.

<a id="4207d71a-001c"></a>

## Advanced: two more optional `pools.yml` blocks

These have no dedicated command yet -- author them directly in `pools.yml` (validate with
`Test-PoolIntent.ps1`); see [`test/schemas/pools.schema.yml`](../test/schemas/pools.schema.yml):

- **`config.testCycle`** -- override test-cycle knobs for the whole pool (e.g.
  `stepTimeoutSeconds`, `autoRemediation.enabled`); pool value wins over each host's config.
- **`gating`** -- pool health-alert thresholds (the healthy-member quorum + how long before a
  pool is flagged "degraded"). Advisory: it drives alerting + the dashboard, never gating a
  cycle. Delivery is configured separately on the alert host (see the notifier docs).

<a id="4207d71a-001d"></a>

## Default-off + safety

The pool layer is entirely opt-in: a host with no `pool` block, or a pool with no
members or no assigned test-set, runs its local `test.runner.yml` exactly as a
standalone host. An unreachable intent store falls back to the last good copy,
then to standalone -- a pool never stops a host from testing.

<a id="4207d71a-001e"></a>

## See also

- [control-routes.md](control-routes.md) -- what a host accepts from the dashboard's action
  buttons, and the one-time internal authentication key setup that enables them from another machine.
- [pool-storage.md](pool-storage.md) -- optional NAS replication of pool observability data
  (a separate, NAS-only feature).
- [test/extension/pool-aggregator-service/README.md](../test/extension/pool-aggregator-service/README.md) --
  the read-only pool dashboard + telemetry collector.
- [test-config.md](test-config.md) -- the host-side `pool` config keys.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.12

Back to [Yuruna](../README.md)
