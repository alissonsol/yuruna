<a id="422226cb-0001"></a>

# Yuruna hosts dashboard -- what each panel means

> **Who this is for.** An operator reading the **Yuruna hosts** Grafana dashboard --
> the lab-wide summary served by the caching-proxy-service's Grafana and fed by the
> **pool-aggregator-service** collector on the same VM, which polls every host and
> publishes what it learns. The dashboard is viewable with no credential. Each panel's
> (i) tooltip gives the short reading and links here; this page carries the full story.

<a id="422226cb-0002"></a>

## Lab token

The lab connection token **and** the collector's health, in one tile.

**Blue -- a 6-character code.** The code a joining host redeems for the shared
internal authentication key:

```
pwsh test/lab/Set-LabToken.ps1 -LabToken CODE
```

It rotates every minute (aggregator `-lab-token-rotate`), and a displayed code stays
redeemable for about three minutes, so read it right before enrolling. The full
enrollment walk is in [control-routes](https://yuruna.link/42185271). The tile is
driven by `yuruna_pool_lab_token`; the code itself rides as the metric's `token` label.

**Red "Collector down".** The pool-aggregator-service -- the service on this proxy that
polls every host and feeds this whole dashboard -- has stopped reporting. No code can be
minted, and **every other panel here may be stale**. The tile links to
[collector-down](https://yuruna.link/collector-down), which is the fix. Detection is
`absent(yuruna_pool_collector_up)`: the collector exports that gauge as a constant 1, so
its disappearance from a scrape *is* the outage, and exactly one of the tile's two
queries ever returns a series.

**Gray "off".** The collector is up but the exchange is disabled: the aggregator holds
no internal authentication key, or rotation is off (`-lab-token-rotate 0`).

<a id="422226cb-0003"></a>

## Success%

The share of terminal cycles across the whole lab that finished "pass", within the
dashboard's selected time range (top-right picker).

It is computed as `100 * Pass / (Pass + Fail)` over the same Loki transition log the
*Pool hosts* table's Pass and Fail columns use. The tile is lab-wide; the table
omits hosts without a `baseUrl`, so summing its visible rows can give a lower count.
The numerator carries the per-host zero baseline, so
a pool where every cycle failed reads 0.00% rather than going blank.

With **no** terminal cycle in range the whole expression is empty and the tile shows
`n/a` -- deliberately not 100%, so an idle or freshly built pool cannot read as healthy.

Thresholds: red below 95%, amber below 100%, green at exactly 100%.

<a id="422226cb-0004"></a>

## Addresses in use

A **measured** count of the IPv4 addresses the lab is currently holding: the
caching-proxy-service's observed clients UNION every registered host's current
address, deduplicated so a host that also proxies is counted once. The host half
matters on its own -- a statically addressed host answers no DHCP and appears in no
lease table, yet still occupies an address in the subnet.

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

<a id="422226cb-0005"></a>

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
[control-routes](https://yuruna.link/42185271).

**One function can legitimately appear twice.** The table lists a row per host and
function, not per function, so two hosts each running a pool-control service produce two
Pool-control rows -- differing in Host ID, and in where the Extension link lands. That is
usually worth acting on rather than reading past: a machine converted into a pool worker
is meant to have retired its own service VMs
([lab-operator](https://yuruna.link/42383647)), and a second row for a service the lab
already provides is how a survivor announces itself.

Panel height tracks the extension-host count, maintained by
`yuruna-fit-pool-dashboard.timer` on the proxy -- the `gridPos.h` in the dashboard file
is only the pre-collector default.

<a id="422226cb-0006"></a>

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

**Commit** shows the first 8 characters of each reported Git commit, framework
first and project second, separated by a comma. Its links open the corresponding
commits in their repositories. A bracketed label after each hash describes how
the host verified that repository's selected revision:

| Label | `verification` in saved records | Meaning |
|---|---|---|
| `mirror.origin` | `mirror-confirmed` | The host accepted a signed mirror response confirming the selected commit against GitHub. Object fetches try the local mirror first and can fall back to the origin. |
| `remote.origin` | `origin-direct` | The host successfully checked the requested ref directly against GitHub, the upstream origin. This can be a normal fallback when the mirror is unavailable, unsupported, still populating, or not trusted by that host; origin-first mode can also produce it. |
| `mirror.stale` | `mirror-stale` | The mirror could not confirm its cached revision with GitHub, and the host's direct attempt also failed with a network error. The host accepted a signed cached revision within the configured age and rollback limits. Treat this as degraded connectivity; it does not confirm the latest upstream revision. |
| `mirror.fresh` | `mirror-fresh` | Legacy freshness terminology. Current hosts report `mirror.origin` for a revision confirmed through the mirror; this label is retained for records using the older wording. |
| `not.applicable` | `not-applicable` | Mirror verification does not apply: mirroring is disabled or the repository URL is outside the supported GitHub mirror scope. |

`remote.origin` describes **verification**, so it does not by itself mean an
update failed or the running checkout is stale. Git objects can still come from
the mirror when it holds the exact commit independently verified by the host.
The labels record the source selection reported with that commit, rather than a
continuous check of mirror health. A plain hash without a label means the host
did not report a recognized verification state; older hosts may do this.
The dotted names are display labels; saved records retain their protocol values
so older hosts and existing cycle history remain readable.

To learn why a particular host used the origin, open its status page through
**Control** and hover over the provenance label beside the commit. The tooltip
includes `source` (where the objects came from), `verification`, `fallbackReason`,
and `originCheckedAt` (the last upstream confirmation time). The same fields are
available in that host's `status.json`, under `gitCommits`. For example,
`mirror-unavailable` means the mirror endpoint could not be used, while
`mirror-untrusted` means the host has no enrolled verification key. See
[Git mirror outage behavior and diagnostics](caching.md#42f6b05f-005a).

**Control** is the host link *and* says up front whether following it will let you
drive the host:

| Cell | Meaning |
|---|---|
| **remote** (green) | the host holds the same internal authentication key the proxy mints proofs from, so its Pause/Continue buttons will work |
| **onsite** (gray) | the buttons will 403; the host holds no token and can only be driven from its own console |
| **onsite** (amber) | the buttons will 403 too, but the cause is a mismatched token or a clock skewed far enough to expire a fresh proof, rather than no token at all |
| **unknown** | the host has not answered `/control/control-status`, which an older framework build does not serve |

The link itself works in every state -- it opens the host's status page **read-only** --
and routes through the aggregator's `/go/host` redirect, which resolves the host's
**current** IP server-side and hands the browser the short-lived control token.
Enrolling a host, and what to do with a 403, are covered in
[control-routes](https://yuruna.link/42185271).

**Host ID** opens a menu whose first entry is that host's full id, GUID-formatted
(8-4-4-4-12), checkable against another screen and copyable into a pool-admin command,
which accepts that form as pasted ([pool-admin](https://yuruna.link/4207d71a)); the
entry names the host and navigates nowhere. Its second entry is the same host link, so
two cells per row carry the token -- but Control is still the cell that says up front
whether following it will drive the host.

**Last cycle** links to the cycle folder. Artifacts are served from the generating host
and are never copied into this dashboard; the one way they travel is an operator using
*Share cycle results* on the timeline below, which packs one cycle folder for that
operator to mail on.

**A host can occupy two rows for a few minutes, and both are current.** Everything the
table shows apart from Pass and Fail arrives as a Prometheus label on
`yuruna_pool_host_info`, and a series is identified by its labels -- so the moment a
host starts a cycle, changes status, or reports a new commit or version, that is a new
series rather than a new value on the old one. The replaced series keeps its last
sample and stays inside the staleness window an instant query reads, so for about five
minutes the host answers twice. The two rows share a Host ID and differ in Status, Last
cycle, Commit or Version, and the older one disappears on its own. It is worth knowing
because the reflex -- that a repeated Host ID means a host registered twice -- is wrong
here: the *Pool hosts* page the pool-control service serves is keyed by host id with
these values as fields, so it never doubles, and disagreeing with this table is not a
fault in either.

Panel height tracks the host count (`yuruna-fit-pool-dashboard.timer`) so the table
never scrolls -- the `gridPos.h` in the dashboard file is only the pre-collector
default.

<a id="422226cb-0007"></a>

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

The panel selects the hostname-free series (`hostname=""`). No series carries a
`hostname` label any more -- the aggregator stopped emitting one -- and the matcher is
kept because in PromQL an empty-string match also selects a series that has the label
absent, so it costs nothing and still excludes a hostname-bearing series should one
reappear.

Panel height tracks the host count (`yuruna-fit-pool-dashboard.timer`) so rows keep a
legible height instead of being squeezed -- the `gridPos.h` in the dashboard file is
only the pre-collector default.

On a rebuilt proxy, the stretch of each row before the collector first saw the host is
written by the history backfill ([History after a rebuild](#422226cb-000c)). A click on
a block weeks old still finds its cycle: the backfill keeps an index of every cycle
folder each host holds, rotated `history.<date>/` buckets included, and the click
resolves from it.

<a id="422226cb-0008"></a>

## The smaller tiles

These three keep their full story in the tooltip itself.

- **Hosts total** -- distinct pool hosts seen within the aggregator's host TTL (24h by
  default, `-host-ttl`), keyed on the stable hostId, reachable or not. Driven by
  `yuruna_pool_hosts_total`.
- **Failed cycles** -- cycles that finished "fail" lab-wide within the selected time
  range, counted from the Loki transition log (exact, and reaching back to Loki
  retention, unlike a Prometheus counter window). This can include hosts absent
  from the table because they have no `baseUrl`.
  Green when zero; red when any.
- **Total cycles** -- terminal cycles lab-wide within the selected range: the
  denominator behind Success%. Counted
  from the same Loki transition log as Failed cycles, with the same reach. A cycle
  still running has no terminal status yet and is not in scope. The dashboard is
  lab-wide -- its pool filter is a match-all -- while per-pool figures live on the
  pool-control board, which joins the same counts onto pools.yml members[].

<a id="422226cb-0009"></a>

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
  events, sorted so the dominant failure modes across the pool lead. Click a failure
  class to open its meaning and diagnostic guidance on yuruna.link.
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

<a id="422226cb-000d"></a>

## Drill-down: caching proxy

The collapsed row between the incidents drill-down and the host memory row. It exists
for one question: when a guest's step failure blames the caching proxy -- the registry
cache (zot) or the web cache (squid) on the proxy VM -- was the proxy down, or did that
one guest lose its path to the lab? From inside the guest the two are the same event, a
connection that never answers, and only the proxy's own account of that minute tells
them apart.

The four status tiles share the top row. The two per-client request panels sit below
them, followed by the step-failure log.

- **zot /v2/ liveness** -- whether the registry cache answers `GET /v2/`, the check
  every guest-side gate performs before a pull. Green `up`, red `DOWN`, `n/a` when the
  probe has not run. Driven by `yuruna_zot_v2_up`.
- **Guest pull path** -- the request a guest actually makes (a manifest GET through
  the cache's `ns=` path), judged by the deadline a real client applies. Green `ok`
  means a pull started now would succeed; red `FAILING` means a client would have
  abandoned it, whether the cache answered late or not at all. Driven by
  `yuruna_zot_guest_path_ok_under_client_patience`.
- **Manifest path** -- the canary manifest HEAD under the same deadline
  (`yuruna_zot_manifest_ok_under_client_patience`). Red beside a green liveness tile is
  the signature of a sync stall: `/v2/` answers in milliseconds while every pull times
  out, so guests report the proxy as unreachable although the endpoint is up. The
  latency history behind this tile is on the proxy VM's own
  [cache-health dashboard](https://yuruna.link/4227a895).
- **Docker Hub budget** -- pulls left in the current Docker Hub window for the proxy's
  egress address, shared by every guest behind it: green at 25 or more, amber from 10,
  red below. Exhaustion never reaches a guest as a clean 429; the guest sees a cache
  that stopped answering in time. `n/a` means the budget could not be read,
  deliberately not painted as zero -- the value is `yuruna_dockerhub_ratelimit_remaining`
  gated on `yuruna_dockerhub_ratelimit_probe_ok`.
- **zot requests per client, per minute** and **squid requests per client, per
  minute** -- the proxy's own account of who it was serving: zot's request log
  (`{job="zot"}`, one line per client address, the source port stripped so one guest is
  one line) and squid's access log (`{job="squid"}`, whose third field is the client).
  A guest fetches packages through squid and images through zot, so the two panels
  together say whether a guest reached the proxy VM at all. `127.0.0.1` in the zot
  panel is the proxy VM's own probe.
- **Step failures that name the caching proxy** -- the `step_failure` events whose
  reason or console tail mentions the caching proxy, over the selected time range.
  **Start here.** Each line carries the host, the cycle and the UTC time of the
  failure, and that minute is the one to read every other panel in the row at.

**How to read it.** Set the time range around the failing minute, then:

- **Liveness and pull path green, every other guest's line still present in the
  per-client panels, the failing guest's line absent or ended** -- that guest lost its
  path to the lab, not the proxy. The proxy never saw it leave, so nothing on the proxy
  VM will explain the failure; continue on the host that runs the guest, with the
  recipe in [pool-admin](https://yuruna.link/4207d71a).
- **Liveness green, pull path or manifest path red** -- the proxy is up but not
  serving pulls: a sync stall, or an exhausted pull budget. Every guest fails the same
  way at once, and the per-client panels keep showing their requests, because the
  attempts that time out are still logged. Continue on the cache-health dashboard.
- **Liveness red or `n/a`, every client line ended at the same time** -- the proxy
  itself, or the path to the proxy VM, is down, and every host that reaches the
  internet through it will report the same minute.

The four tiles are read on the proxy VM and say nothing about any particular guest;
the per-client panels are where one guest becomes visible. A guest present in the squid
panel but absent from the zot panel in the failing minute had a registry problem, not a
network one.

<a id="422226cb-000b"></a>

## Drill-down: host memory

The two tables in this collapsed row combine the collector's host inventory with
memory readings scraped directly from Windows, Ubuntu, and macOS hosts. Every
host in the inventory has a row, including hosts without a memory reading. Missing
readings show `n/a`.

- **Available memory per host** -- Windows available physical memory; Ubuntu's
  `MemAvailable`, including memory the kernel expects to reclaim; and a macOS
  estimate of free plus inactive pages from `vm_stat`. The macOS estimate uses
  the reported page size and is not a memory-pressure measurement or a guarantee
  that every inactive page can be reclaimed immediately.
- **Commit headroom per host** -- the commit limit minus committed bytes. On
  Windows this measures how much more memory the host can promise before an
  allocation is refused, and the limit moves while Windows resizes the paging
  file. Ubuntu reports `/proc/meminfo`'s `CommitLimit` minus `Committed_AS`;
  its allocation meaning depends on the kernel's overcommit policy and the
  difference can be negative. It is not the Windows allocation guarantee.
  macOS has no equivalent counter, so its commit readings remain `n/a`, even
  when **Exporter** is **Up**. The **Support** column shows **Unsupported** for
  macOS, **Supported** for Windows and Ubuntu, and **Unknown** for other or
  unreported platforms. Support comes from the host inventory, so a macOS host
  remains **Unsupported** when it is unreachable. A supported host with missing
  telemetry still shows `n/a` for its byte readings; support does not imply a
  healthy exporter.

**Host ID** shows the first 8 characters, just as in *Pool hosts*. Click it to see the
full GUID and open that host's status page. **Type** identifies the host platform.
**Minimum** is the lowest reading in the selected time window; **Latest** shows the
last reading in that window, with a sparkline of its history. These are recorded
readings, so a latest value can remain visible while the exporter is down.

**Exporter** describes the scrape at the end of the selected window:

- **Up** -- Prometheus successfully scraped the exporter. A missing memory value
  still means that the requested metric was not supplied.
- **Down** -- the exporter scrape failed. The host's status page can remain reachable
  while its exporter port is blocked or the metrics request times out.
- **Not scraped** -- there is no current scrape result. Only reachable Windows,
  Ubuntu, and macOS hosts are discovered as exporter targets; unsupported platforms
  and unreachable hosts have no target. Their inventory rows remain visible.

The collector discovers exporter addresses from the hosts it currently reaches;
Prometheus follows that list. Series use the stable `hostId`, including as their
scrape identity, so a DHCP address change keeps the same memory history. The tables
join that history to the inventory on `hostId` and exclude retired host IDs. An absent
reading stays unavailable rather than becoming a zero-byte reading.

Windows uses `windows_exporter` on port 9182 (or the configured host metrics port).
Ubuntu and macOS expose native `yuruna_host_memory_*` metrics at `/metrics` on
their existing status service, normally port 8080; no extra exporter package or
listener is needed. Discovery uses each confirmed status endpoint, including an
announced custom port. Failed native memory collection returns HTTP 503 so the
**Exporter** column reports **Down** instead of implying a successful reading.
The proxy's metric allowlist keeps both Windows and native Unix memory metrics.
Existing installations need the updated Unix status service, collector discovery,
Prometheus allowlist, and dashboard before Unix readings appear. Memory samples
begin when scraping starts; cycle-history backfill cannot recover earlier memory
readings.

Ubuntu hosts running public version `2026.10.18.2` do not yet expose the native
`/metrics` endpoint. Their platform is **Supported**, but a 404 from that listener
means the installed release lacks the endpoint. Those hosts need the next public
release containing native memory metrics; a proxy rebuild alone cannot add the
host endpoint. Keep their configured repository and branch when updating them.

Host Refresh preserves an already-running status listener. After the framework
update, a normal test cycle restarts it when the installed commit changes;
copied working-tree changes require an explicit status-service restart using the
host's existing configuration. Updating files alone does not activate `/metrics`.

<a id="422226cb-000c"></a>

## History after a rebuild

The collector records only what it watches happen, so a rebuilt caching-proxy-service
VM would open on an empty board while every host still keeps the cycles it ran. A
second job on the same VM, **pool-history-backfill**, reads those cycles back -- from
the pool share when it holds a committed copy, else from the host -- and writes them to
Loki and Prometheus exactly as the collector would have, for the last 90 days:

- every finished cycle's result: the Success%, Failed cycles and Total cycles tiles,
  the Pass and Fail columns of *Pool hosts*, and the status transitions log;
- the per-step events of the last 7 days, which is as long as Loki keeps events: the
  step-failure and event-stream panels;
- the per-host incidents the collector would have raised before it first saw the host;
- the *Cycle outcome over time* row, wherever its live series has no samples.

It backfills the hosts the collector reaches now, and a host that joins the pool later
on its next sweep. All times are UTC from end to end: hosts write them, the job keeps
them, and Loki and Prometheus store them. It never writes a cycle, an event or a
timeline sample the stores already hold, so it is safe to leave running and to restart.

The collector also carries each host's recent completed-cycle summaries in
`status.history` (normally the last 30 cycles). These can restore the timeline's
known start-to-finish intervals even when the host's log listing or event files
cannot be read, or the backfill has deferred requests to that host. This recovery
uses the summaries already held by the collector, preserves existing samples,
and leaves unknown intervals empty. It does not reconstruct detailed events or
the Loki cycle counts; those still require readable cycle files. A host with a
long gap can therefore regain recent timeline blocks before its full history.

What it cannot restore:

- a cycle no readable copy of survives -- it is tried three times and then left out;
- the host memory panels: those readings are taken live and never recorded on a host;
- why a host was idle: a backfilled row holds a cycle's result for at most 30 minutes
  after the cycle ended and is empty after that, where the live row would have shown
  paused, stopped or unreachable;
- pool-wide incidents, which correlate hosts the job reads one at a time, and an
  incident still open when the collector first saw the host.

**Pace.** The job runs at the lowest CPU and I/O priority, under a systemd CPU limit of a
tenth of the VM less a point (`CPUQuota`), and it spaces its requests: at most one every
2 seconds to any host's status service, 120 cycles a minute in all, and 1 MB/s of
writes to Loki. Each sweep writes at most 200 cycles per host, newest first: the
board refills backwards from the rebuild moment -- the cycles just before it land
first, then yesterday's, then the day before's, out to the horizon. While history is
left it sweeps every minute, then every 15.
It asks a host for its cycle listing once and then at most hourly, working in between
from the folders that listing found and from the pool share. A host's status service
answers one request at a time, so a listing that takes longer than 10 seconds keeps
that host's guests waiting: the job then sends the host nothing for a day, still restores
its cycles from the pool share and recent timeline intervals from the collector's
summaries, and says until when in its log. When the proxy can read the host's
archive directory directly, it requests `/log/?localOnly=true`: the host lists
local folders without enumerating the same NAS archive and checking every
completion sentinel. Ordinary `/log/` requests still include archived cycles.
Loki answers for a line stamped days in the past only once it has filed the line away,
about half an hour after the write, so a backfilled cycle reaches the Loki panels that
long after the job reports it written; the timeline row, read from Prometheus, shows it
at once.

**Watch it** with `journalctl -u pool-history-backfill -f` on the proxy: one line per
sweep counts the cycles, events, incidents and timeline samples written, the cycles
it could not read, and the hosts with history still to write.

**Start over** by removing its state while it is stopped:
`sudo systemctl stop pool-history-backfill`, then
`sudo rm -rf /var/lib/pool-history-backfill/hosts`, then
`sudo systemctl start pool-history-backfill`. Wait an hour after the job last wrote
anything first: the state is how it remembers what Loki has not filed away yet, and
without it a cycle written in that hour would be written twice.

<a id="422226cb-000a"></a>

## See also

- [control-routes](https://yuruna.link/42185271) -- who is allowed to drive a
  host from the dashboard's buttons, and the one-time enrollment that enables it.
- [collector-down](https://yuruna.link/collector-down) -- restoring the
  pool-aggregator-service collector this whole dashboard depends on.
- [cache-health dashboard](https://yuruna.link/4227a895) -- the proxy VM's own board:
  manifest latency, upstream reach and the pull budget, where the caching-proxy row
  sends you when the proxy itself is at fault.
- [pool-admin](https://yuruna.link/4207d71a) -- running a pool: membership,
  framework and project repositories, configured state.
- [lab-operator](https://yuruna.link/42383647) -- bringing a lab up.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.22

Back to [Yuruna](../README.md)
