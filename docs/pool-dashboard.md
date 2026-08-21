# Yuruna hosts dashboard -- what each panel means

> **Who this is for.** An operator reading the **Yuruna hosts** Grafana dashboard --
> the lab-wide summary served by the caching-proxy service's Grafana and fed by the
> **pool-aggregator-service** collector on the same VM, which polls every host and
> publishes what it learns. The dashboard is viewable with no credential. Each panel's
> (i) tooltip gives the short reading and links here; this page carries the full story.

## Lab token

The lab connection token **and** the collector's health, in one tile.

**Blue -- a 6-character code.** The code a joining host redeems for the shared
`lab-auth-token`:

```
pwsh test/lab/Set-LabToken.ps1 -LabToken CODE
```

It rotates every minute (aggregator `-lab-token-rotate`), and a displayed code stays
redeemable for about three minutes, so read it right before enrolling. The full
enrollment walk is in [control-routes](https://yuruna.link/control-routes). The tile is
driven by `yuruna_pool_lab_token`; the code itself rides as the metric's `token` label.

**Red "Collector down".** The pool-aggregator-service -- the service on this proxy that
polls every host and feeds this whole dashboard -- has stopped reporting. No code can be
minted, and **every other panel here may be stale**. The tile links to
[collector-down](https://yuruna.link/collector-down), which is the fix. Detection is
`absent(yuruna_pool_collector_up)`: the collector exports that gauge as a constant 1, so
its disappearance from a scrape *is* the outage, and exactly one of the tile's two
queries ever returns a series.

**Grey "off".** The collector is up but the exchange is disabled: the aggregator holds
no `lab-auth-token`, or rotation is off (`-lab-token-rotate 0`).

## Success%

The share of terminal cycles across the whole lab that finished "pass", within the
dashboard's selected time range (top-right picker).

It is computed as `100 * Pass / (Pass + Fail)` over the same Loki transition log the
*Pool hosts* table's Pass and Fail columns are counted from, so this tile and those
columns can never disagree. The numerator carries the table's per-host zero baseline, so
a pool where every cycle failed reads 0.00% rather than going blank.

With **no** terminal cycle in range the whole expression is empty and the tile shows
`n/a` -- deliberately not 100%, so an idle or freshly built pool cannot read as healthy.

Thresholds: red below 95%, amber below 100%, green at exactly 100%.

## Addresses in use

A **measured** count of the IPv4 addresses the lab is currently holding: the caching
proxy's observed clients UNION every registered host's current address, deduplicated so
a host that also proxies is counted once. The host half matters on its own -- a
statically addressed host answers no DHCP and appears in no lease table, yet still
occupies an address in the subnet.

The tile deliberately makes **no claim about the DHCP pool**. Judging the pool needs two
numbers that live on the DHCP server and are not visible from the lab: the scope size
and the free-lease count. Read those on the server before concluding anything about
exhaustion -- a high count here is normal for a large lab and says nothing by itself.

It is a **floor, not a ceiling**: anything that neither reaches the internet through the
proxy nor registers as a host is invisible to both sources.

Metrics: `yuruna_pool_lab_addresses_in_use` drives the tile, with
`yuruna_pool_lab_addresses_in_use_hosts` carrying the host-record half (that half
survives the proxy being down). The companion gauge
`yuruna_pool_lab_distinct_addresses_complete` is 0 when the proxy-log scan was
truncated, which lowers the floor further.

**No thresholds are set, and the tile paints no color -- both deliberate**: any
threshold here would have to assume a lease period and a scope size, and assuming them
is what turns a measurement back into an estimate.

## Extension hosts

Hosts running an **extension function** (currently the Stash, Pool-control, and
Download-agent services), learned from each host's registration record
(`activeExtensions`). No ystash-nas mount or config service is consulted: a host
self-reports the service it runs, and the aggregator already polls its registration.
The table is driven by `yuruna_pool_host_extension`.

It shares the opaque **Host ID** namespace with the *Pool hosts* table, so a host that
both runs cycles and hosts a stash service shows the same Host ID in both. The column
shows the first 8 characters -- what tells a dozen near-identical 42-prefixed ids apart
at a glance. Clicking the cell opens a menu whose **first entry is that host's full id,
GUID-formatted (8-4-4-4-12)**, checkable by eye and copyable into a command; it names
the host and navigates nowhere. The menu's other entry is the same extension link the
Extension column carries.

There is no status-page link here, because `/go/host` cannot serve this table: a host
can run an extension service without running cycles, and such a host has no status page
for that redirect to resolve -- it would answer "host not known to the pool". Open a
host from the *Pool hosts* table instead: its rows are exactly the hosts that have a
status page, and that link carries the short-lived control token.

**Extension** names the function (e.g. Stash service) and links to that service's UI via
the aggregator's `/go/stash` redirect, which resolves the host-advertised address
server-side and hands the browser the same short-lived control token the *Pool hosts*
link carries. A service UI opened from here therefore arrives with its actions already
unlocked, and only falls back to its ordinary Lab token prompt when the proxy mints no
token at all. The proof mechanics -- fragment delivery, minting, verification -- are in
[control-routes](https://yuruna.link/control-routes).

Panel height tracks the extension-host count, maintained by
`yuruna-fit-pool-dashboard.timer` on the proxy -- the `gridPos.h` in the dashboard file
is only the pre-collector default.

## Pool hosts

One row per discovered host, identified by its opaque **Host ID** -- the stable per-host
UUID, shown as its first 8 characters. No hostname is disclosed, so this summary stays
safe to expose unauthenticated.

**Status** folds in reachability, whether anything is still driving the host, and its
pause state -- the same ladder the host's own status banner shows:

- **runner stopped** -- the host answers but its test runner is verifiably gone, so the
  cycle result below it is a record of what ran, not of what is running. It outranks
  every other reading for exactly that reason.
- **paused** -- a host that has actually stopped.
- **pausing (after cycle)** / **pausing (after step)** -- a host an operator has armed
  to stop but that is still executing, reported as such rather than as a plain
  "running" that would hide the pending stop.

**Pass / Fail** count terminal cycles within the dashboard's selected time range
(top-right): Last 3h shows only cycles finished in the last 3h. They are counted from
the Loki transition log -- exact, and reaching back to Loki retention -- with a per-host
zero baseline so they always show, 0 included.

**Control** is the host link *and* says up front whether following it will let you
drive the host:

| Cell | Meaning |
|---|---|
| **remote** (green) | the host holds the same `lab-auth-token` the proxy mints proofs from, so its Pause/Continue buttons will work |
| **onsite** (grey) | the buttons will 403; the host holds no token and can only be driven from its own console |
| **onsite** (amber) | the buttons will 403 too, but the cause is a mismatched token or a clock skewed far enough to expire a fresh proof, rather than no token at all |
| **unknown** | the host has not answered `/control/control-status`, which an older framework build does not serve |

The link itself works in every state -- it opens the host's status page **read-only** --
and routes through the aggregator's `/go/host` redirect, which resolves the host's
**current** IP server-side and hands the browser the short-lived control token.
Enrolling a host, and what to do with a 403, are covered in
[control-routes](https://yuruna.link/control-routes).

**Host ID** opens a menu whose first entry is that host's full id, GUID-formatted
(8-4-4-4-12), checkable against another screen and copyable into a pool-admin command,
which accepts that form as pasted ([pool-admin](https://yuruna.link/pool-admin)); the
entry names the host and navigates nowhere. Its second entry is the same host link, so
two cells per row carry the token -- but Control is still the cell that says up front
whether following it will drive the host.

**Last cycle** links to the cycle folder. Artifacts are served from the generating host
and are never copied into this dashboard; the one way they travel is an operator using
*Share cycle results* on the timeline below, which packs one cycle folder for that
operator to mail on.

Panel height tracks the host count (`yuruna-fit-pool-dashboard.timer`) so the table
never scrolls -- the `gridPos.h` in the dashboard file is only the pre-collector
default.

## Cycle outcome over time (host x UTC time)

Each row is a host, labeled with the first 8 characters of its Host ID; color is the
cycle status the pool-aggregator-service observed at that time. Times are UTC, the
dashboard's timezone, so a block lines up with the UTC log times in the drill-down
below.

Click a block for a menu. Its first entry is that host's full id, GUID-formatted
(8-4-4-4-12), checkable by eye and copyable into a command -- it names the host and
navigates nowhere. The rest are the row's actions:

- **Open cycle results** -- the link resolves the host's **current** IP server-side (it
  survives a host IP change) and the cycle covering that time. Cycle results that a
  host has archived to the pool share are served from the share by the collector, so
  these links keep resolving after a host has moved its logs off local disk -- or has
  been switched off entirely.
- **Share cycle results** -- resolves the same cycle and lands on the host's own share
  page, which packs the whole results folder into one archive named
  `SHORTID.UTCSTART.tar.gz` and hands it to your mail client. The archive is built on
  the host and is not uploaded anywhere by that page.

The panel selects the hostname-free series (`hostname=""`) so a host shows **one** row:
a legacy hostname-bearing series, retained until it ages out, would otherwise add a
duplicate row for the same Host ID.

Panel height tracks the host count (`yuruna-fit-pool-dashboard.timer`) so rows keep a
legible height instead of being squeezed -- the `gridPos.h` in the dashboard file is
only the pre-collector default.

## The smaller tiles

These three keep their full story in the tooltip itself.

- **Hosts total** -- distinct pool hosts seen within the aggregator's host TTL (24h by
  default, `-host-ttl`), keyed on the stable hostId, reachable or not. Driven by
  `yuruna_pool_hosts_total`.
- **Failed cycles** -- cycles that finished "fail" lab-wide within the selected time
  range: the sum of the table's Fail column, counted from the Loki transition log
  (exact, and reaching back to Loki retention, unlike a Prometheus counter window).
  Green when zero; red when any.
- **Total cycles** -- terminal cycles lab-wide within the selected range: the sum of
  the table's Pass and Fail columns, i.e. the denominator behind Success%. Counted
  from the same Loki transition log as Failed cycles, with the same reach. A cycle
  still running has no terminal status yet and is not in scope. The dashboard is
  lab-wide -- its pool filter is a match-all -- while per-pool figures live on the
  pool-control board, which joins the same counts onto pools.yml members[].

## Drill-down: incidents & cycle events

The collapsed row under the timeline. Its panels share the dashboard time range:

- **Incidents (open / resolved)** -- the incident lifecycle: a host opens an incident
  at N or more failed cycles within a trailing window (default 3 in 2h) and resolves
  once the window clears. Each line carries `incidentId`, host, `failCount` and, on
  resolve, `peakFails` and `durationSeconds`, plus the incident's failure class on the
  object itself: per-host `dominantClass` and `classHistogram`, and the pinned class on
  pool-wide incidents -- a cross-host incident requires the same class. From the
  aggregator's incident correlation (`src=incident` in Loki).
- **Failures by class & severity** -- the failure-class histogram of `step_failure`
  events, sorted so the dominant failure modes across the pool lead.
- **Recent step failures** -- the failing step's action, number, class, severity and
  reason per host/cycle, with deep-links into that host's full cycle artifacts.
- **Cycle event stream** -- every per-cycle NDJSON event tailed from each host; filter
  with the Grafana log search.
- **Cycle status transitions** -- one line each time a host's cycle changes state,
  from the status.json poll: the cycle-level audit trail behind the table and
  timeline above.
- **Incidents by failure class** -- the incidents themselves grouped by dominant
  class, distinct from the step_failure histogram above, which counts events whether
  or not they formed an incident.

## See also

- [control-routes](https://yuruna.link/control-routes) -- who is allowed to drive a
  host from the dashboard's buttons, and the one-time enrollment that enables it.
- [collector-down](https://yuruna.link/collector-down) -- restoring the
  pool-aggregator-service collector this whole dashboard depends on.
- [pool-admin](https://yuruna.link/pool-admin) -- running a pool: membership,
  test-sets, desired state.
- [lab-operator](https://yuruna.link/lab-operator) -- bringing a lab up.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.21

Back to [Yuruna](../README.md)
