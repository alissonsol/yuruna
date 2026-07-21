# pool-aggregator

The read-only multi-host **pool view** for the Yuruna test harness — the
MVP of the pool harness (see [docs/opportunities.md](../../../docs/opportunities.md)).

## What it does

A small stdlib-only Go daemon that runs on the **caching-proxy machine** (the
pool services host). It needs **no host list** — it auto-discovers pool members.
Every `-interval` (default 30s) it:

1. **Discovers candidate IPs from the squid access log**
   (`/var/log/squid/yuruna_access.log`) — every host that pulls
   packages/images through the proxy appears there. Reads only the recent tail
   (last ~35 min, just over a 30-min DHCP lease), plus the last-known IP of each
   host already in the view (so an idle host stays live).
2. **Probes** each candidate IP's status server (`http://<ip>:8080/runtime/status.json`)
   and keeps the ones that answer with a `hostId`. Non-runners (guests, other
   clients) don't serve it and are dropped.
3. **Identifies on the stable `hostId`** (the persistent `runtime/host.uuid`), not the
   IP. This makes the pool **DHCP-resilient**: a host that changes IP reappears
   at the new IP and resolves to the **same** `hostId` (one member, not two); a
   host that cycles through many IPs over short leases collapses to one `hostId`;
   and there is **no DNS dependency** — everything keys off log IPs + `hostId`.
4. On a **cycle-status transition**, pushes one line to **Loki**
   (`/loki/api/v1/push` on `127.0.0.1:3100`) with labels `{pool,hostId,cycleId,src=cycle}`
   and the proxy-side **ingest clock** as the timestamp (defends against host
   clock skew); the line carries the host's current `baseUrl` for drill-down.
4b. **Tails per-step events:** for each reachable host it fetches the
   current cycle's NDJSON event log
   (`<baseUrl>/<cycleFolderUrl>cycle.events.ndjson`) and ships new lines to Loki
   under `{pool,hostId,src=event}` — `cycle_start`/`step_end`/`step_failure`/typed
   sub-events, so the dashboard can answer *which step failed*, not just which
   host. A per-host byte cursor forwards only new lines (resets per cycle); each
   entry uses the **event's own timestamp**, so a restart that re-ships the
   in-flight cycle is idempotent (Loki drops exact duplicates).
5. Bumps **Prometheus** counters (`yuruna_pool_cycles_{pass,fail}_total` by
   `hostId`) once per terminal cycle, and on every scrape exposes per-host
   series that drive the dashboard table/timeline: `yuruna_pool_host_info`
   (labels: hostType, version, commit, commitUrl, projectCommitUrl, baseUrl,
   cycleId, cycleFolderUrl, derived status —
   keyed on `hostId`, **no** hostname; `version` is the host's framework
   `VERSION`, fetched per poll from `<baseUrl>/yuruna-repo/VERSION`; `commit` is
   the current cycle's short SHAs (framework, project) from `status.json`'s
   `gitCommits`, with `commitUrl`/`projectCommitUrl` the per-repo
   `…/commit/<sha>` deep-links the table's Commit column resolves),
   `yuruna_pool_host_status` (numeric 0–5:
   unreachable/running/pass/fail/idle/paused), and `yuruna_pool_host_last_seen_seconds`.
   Served at `/metrics`. The whole pool telemetry is **hostname-free** (see below).
5b. **Discovers extension hosts (registration-driven).** Each poll it reads every
   pool host's `host.registration.json` (already fetched for poolId/gating) and, for
   each `area` in that record's **`activeExtensions`** — the runtime list of
   extension services the host is ACTIVELY running (e.g. `stash-service` when it
   hosts a stash-server VM; the host writes it via `Start-StashServer` →
   `runtime/stash-server.json` → `Write-HostRegistrationRecord`, which also refreshes
   it on bring-up so the host appears WITHOUT waiting for a test cycle) — exposes
   `yuruna_pool_host_extension{hostId,area,baseUrl,target}` (+`_last_seen_seconds`).
   This keys on the SAME `hostId` namespace as the pool table, so a host that both runs
   cycles and hosts a stash server shows one Host ID in both. It needs **no ystash-nas
   mount and no Config Service** on the aggregator's host — a host self-reports the
   service it runs and the aggregator already polls its registration. Drives the
   dashboard's **Extension hosts** table (`stash-service` → "Stash service"). `baseUrl`
   (the host's status page) and `target` (the service UI the host advertised in the
   registration record's **`extensionTargets`**, e.g. the stash VM's base URL it
   resolved via `Get-VMIp`) ride as labels so the table deep-links each cell
   **directly** — Host ID → `baseUrl`, Extension → `target` — the SAME hidden-URL-column
   pattern the Pool hosts table uses for `baseUrl` (a Grafana table column carries no
   field labels, so a `${__field.labels.hostId}` redirect would resolve empty). The
   `extensionTargets` map is also exposed in `/api/v1/pool-status` for the stash UI's
   `hostId → stashBaseUrl` lookup, and `/go/stash` resolves it for IP-free consumers.
5c. **Accepts extension self-announces (`POST /announce`).** The registration path
   above goes silent whenever the owning host's status server is down — routinely,
   after a host reboot — while the service VM auto-restarts and keeps serving. So the
   service announces ITSELF: the stash server POSTs `{hostId, area, targetPort}` at
   startup, every beacon period (default 15 min), and `active:false` at shutdown
   (stash-service.md §4.7). The advertised URL is derived from the announce's SOURCE
   address (an announcer can only advertise itself — the same trust squid-log
   discovery extends to any LAN client), the row's `baseUrl` fills from the host view
   when the host is known, and a registration row for the same `(hostId, area)` wins.
   Entries reap after `-announce-ttl` (default 45m, two missed beacons) or on a
   goodbye; every accepted announce is pushed to Loki (`{pool,hostId,src=announce}`)
   so a collector restart restores live rows instantly instead of waiting a period.
   Announce-fed targets also back `/go/stash` and pool-status `stashBaseUrl` when the
   registration has nothing. Open-by-design write route (no bearer): telemetry-only,
   tightly validated, bounded, self-identity-bound; `-announce-ttl 0` disables it.
6. **Survives its own restart:** on startup it rehydrates the cycle counters (and
   the seen/counted dedup state) from Loki — the durable transition record —
   over the trailing `-rehydrate-window`. The counter resumes at its prior value
   rather than resetting to zero, so from Prometheus's view there is no reset:
   both the table's raw Pass/Fail and the 24h `increase()` tile stay correct
   across a collector restart, with no dashboard change. Best-effort: if Loki is
   unreachable the collector starts empty and rebuilds as cycles complete.
   It also **re-seeds its (volatile) host view** from Loki — each host's last-known
   IP, taken from the cycle-transition feed and from an on-discovery **presence**
   beacon (`{pool,hostId,src=presence}`, pushed whenever a host is first discovered
   or changes IP) — so a host discovered before the restart is re-probed on the
   first poll instead of vanishing. This closes the discovery-liveness gap for a
   host that is up + reachable but pulling nothing through the proxy right now (a
   paused runner, or a **stash-only** host that runs no cycles and so emits no
   transition line): without it, such a host drops off the Extension-hosts panel
   until it next routes through the proxy.
7. **Correlates incidents.** A host that fails `-incident-fails` cycles within
   `-incident-window` (default 3 in 2h) opens an **incident** — a fail-burst, not
   a one-off fail. Exposed as `yuruna_pool_incidents_active` /
   `yuruna_pool_host_incident` / `yuruna_pool_host_recent_fail_count` (Prometheus)
   and pushed to Loki as `incident_open` / `incident_resolved` lifecycle lines
   (`{pool,hostId,src=incident}`, with `failCount` / `peakFails` / `durationSec`).
   Hysteresis (open at ≥N, resolve at 0) keeps a still-failing host in one
   incident. On restart the fail window rehydrates from the cycle feed, and any
   **open** incident is restored from the `src=incident` feed with its
   **original** `incidentId` + `startedAt` — so the eventual `incident_resolved`
   still pairs with its `incident_open` and reports the true duration (no
   duplicate announce, no dangling open).
8. **Correlates cross-host (pool-wide) incidents.** When `-cross-host-fails`
   distinct hosts each fail within `-cross-host-window` (default 3 hosts in 15m)
   it opens a **pool-wide** incident — a systemic signal (shared cause: proxy,
   network, a bad commit) rather than one flaky host. Exposed as
   `yuruna_pool_wide_incident` / `yuruna_pool_wide_incident_hosts` (Prometheus)
   and `pool_incident_open` / `pool_incident_resolved` lines
   (`{pool,src=incident,scope=pool}`, with `affectedHosts` / `peakHosts` /
   `durationSec`); restored from the incident feed on restart like per-host.

The pool view is rendered by **Grafana** (`grafana-pool-dashboard.json`, uid
`yuruna-pool`) over Prometheus + Loki: summary tiles (incl. **Hosts in
incident** and **Pool-wide incident**), a **per-host table** (type · framework
version · last cycle · status · last seen · pass/fail, with deep-links to each
host's own status page and cycle folder), a **host × time state-timeline**, and a collapsed **drill-down**
row (incidents · **failures by class & severity** · recent step failures · full
cycle event stream · status transitions) over Loki. **Every** panel identifies
each host by its opaque **Host ID** (the stable `hostId`, shown GUID-formatted)
and its `hostType`, **not** its hostname — the entire pool view (table, timeline,
and the drill-down incident/event/transition panels) is hostname-free, so it
stays safe to expose unauthenticated; the hostname stays on each host's own
(to-be-authenticated) status page. Deep-links point at each host's **own status
server** — artifacts never leave the generating host.

**Read-only by design:** killing this daemon leaves every runner testing
unaffected (graceful degradation).

## Files

- `main.go` — the collector. Stdlib only (a static binary, no Go toolchain at
  runtime), cross-platform (no host-specific syscalls; builds + vets on the
  Windows harness toolchain identically to the Linux target).
- `go.mod` — module + Go version. Zero external dependencies.
- `pool-aggregator.service` — systemd unit (`User=proxy`, hardened,
  `ReadOnlyPaths=/var/log/squid` to read the access log; `:9400`).
- `pool-aggregator.config.yml` / `pool-aggregator.contract.yml` — the Yuruna
  extension area scaffolding (mirrors `caching-proxy-parser`).
- `default.psm1` — `Get-PoolAggregatorManifest` (metadata; nothing runs on the
  harness host).
- `grafana-pool-dashboard.json` — the `yuruna-pool` dashboard. **Canonical,
  lintable copy.** It is NOT fetched at boot; an identical copy ships inline via
  `write_files` in `host/vmconfig/caching-proxy.base.user-data` so the dashboard
  deploys even when the collector build fails or its source has not yet reached
  public `yuruna`. Edit this file, then sync the inline copy (keep the two in
  step). The timeline's "open cycle results" and "open host status page" data links
  target `${aggregator}`, a hidden constant variable holding this proxy's `/go/` base;
  both copies carry the literal `AGGREGATOR_BASE_PLACEHOLDER`, which cloud-init
  substitutes at boot with `http(s)://<proxy-ip>:9400` (scheme follows the
  aggregator's TLS leaf).

  The `gridPos.h` of the three **per-host** panels (host × time timeline, Pool
  hosts, Extension hosts) is only a pre-collector default. Grafana has no
  "fit to content" panel height, so on the proxy VM
  `yuruna-fit-pool-dashboard.py` (cloud-init `write_files` +
  `yuruna-fit-pool-dashboard.timer`, every 5min) recomputes those heights from
  the live host count and rewrites the provisioned copy in place, so a table
  sized for today's pool neither scrolls when a host joins nor shows dead
  whitespace when one leaves. Changing the panel **ids** (`7`, `6`, `17`) or
  adding a fourth per-host panel means updating that script.

## Flags

`-squid-log` (default `/var/log/squid/yuruna_access.log`) · `-status-port`
(default `8080`) · `-loki` · `-pool` (default `default`) · `-interval`
(default `30s`) · `-listen` (default `:9400`) · `-rehydrate-window` (default
`168h`; `0` disables — see above) · `-incident-fails` (default `3`) ·
`-incident-window` (default `2h`) · `-cross-host-fails` (default `3`) ·
`-cross-host-window` (default `15m`) · `-announce-ttl` (default `45m`; `0`
disables `POST /announce`).

## Endpoints (`:9400`)

HTTPS when the proxy-CA TLS leaf (`/etc/squid/ssl_cert/pool-aggregator.crt`) is present
(it is minted in cloud-init, so a rebuilt proxy serves `:9400` over TLS); plain HTTP when
the leaf is absent.

| Path | Method | Auth | Purpose |
|---|---|---|---|
| `/healthz` | GET | none | `ok` liveness |
| `/metrics` | GET | none | Prometheus text (`yuruna_pool_*`) — scraped by the local Prometheus |
| `/api/v1/pool-status` | GET | none | JSON snapshot of every discovered host's last poll |
| `/go/cycle?host=<hostId>&t=<epochMs>` | GET | none | dashboard timeline click → 302 to that host's cycle-results folder. Resolves the host's **current** IP from the live view (so the link survives a host IP change) and the cycle covering `t` (current cycle in-memory, else the host's `/log/` listing, else the Loki transition feed); degrades to the host's status root when the folder can't be resolved |
| `/go/host?host=<hostId>` | GET | none | dashboard timeline click → 302 to that host's status-page **root**. Same `host` uuid → **current** IP resolution as `/go/cycle` (survives a host IP change), but always lands on the status page rather than a cycle folder — the IP-free state-timeline rows can't carry the IP, so the link resolves it here |
| `/go/stash?host=<hostId>&area=<area>` | GET | none | 302 to that host's extension-service UI (default `area=stash-service`, the stash VM), resolved from the URL the host **advertised** in `extensionTargets` (refreshed each cycle / on `Start-StashServer` via `Get-VMIp`). For IP-free, hostId-only consumers — the dashboard table itself links directly via the `target` label. Unknown host/target → 404 |
| `/ingest` | POST | Bearer | runner-side push of NDJSON events (supplements pull); disabled (503) until a shared bearer token is configured |
| `/announce` | POST | none (self-identity-bound) | extension-presence beacon (stash server et al., point 5c): the advertised URL derives from / must match the sender's address, so an announcer can only advertise itself; telemetry-only, bounded, disabled (503) when `-announce-ttl` is `0` |

## Deploy + verify

Built + installed on the caching-proxy VM's first boot by that VM's cloud-init
(`host/vmconfig/caching-proxy.base.user-data`). The build fetches the source
from the **LOCAL host working tree** served by the deploying host's status
server (`http://<host>:<port>/yuruna-repo/test/extension/pool-aggregator/`) —
the same base-URL resolution as `automation/fetch-and-execute.sh`: read
`/etc/yuruna/host.env` (host IP+port baked into the seed by `New-VM.ps1`), probe
`/livecheck`, else fall back to github raw. It then `go build`s, installs the
binary + unit, and `systemctl enable --now`s. Failure is soft.

Because it reads the host's **live working tree**, **no github mirror is
required** — the host serves whatever is checked out at request time, so a
rebuild always gets the latest local source. `Start-CachingProxy.ps1` starts the
status server before creating the VM. If the server is unreachable (or
`statusService` is disabled in `test.config.yml`), the build falls back to github
raw — where the private collector source may be absent, so the collector is
skipped (logged loudly in `/var/log/cloud-init-output.log`).

The **dashboard does not share this dependency** — it deploys inline via
`write_files` regardless of the build, so the *Yuruna hosts* dashboard is present
from first boot (showing "No data" until the collector comes up).

After install (no config needed — discovery is automatic). `:9400` is HTTPS once the
TLS leaf is minted (the default on a rebuilt proxy), so use `https` + `-k` (the leaf is
signed by the pool CA, published at `http://<proxy>/yuruna-pool-ca.crt` for pinning):

```
systemctl status pool-aggregator
curl -sk https://localhost:9400/healthz            # -> ok
curl -sk https://localhost:9400/api/v1/pool-status | jq   # discovered hosts (after some proxy traffic)
curl -sk https://localhost:9400/metrics            # -> yuruna_pool_* lines
# Prometheus target pool-aggregator UP; Loki has {pool,hostId,cycleId} streams;
# Grafana 'Yuruna hosts' dashboard renders the 24h cross-host view.
```

## MVP limits

- **Initial** discovery is **proxy-traffic-driven**: a host first appears only
  once it (or its guests) has pulled through the proxy. A host that has never
  routed through the proxy won't be discovered (registration-driven
  discovery is planned). Once discovered, though, a host is remembered — re-probed at its
  last-known IP while idle (`hostTTL`) and re-seeded from Loki's presence beacon
  across a collector restart — so an idle / stash-only host stays on the dashboard
  without fresh proxy traffic. The **Extension hosts** row additionally has a
  discovery-independent path: the service VM's own `/announce` beacon (point 5c)
  keeps that row (and `/go/stash`) alive even when the owning host is neither
  probeable nor generating proxy traffic.
- Per-step NDJSON events are tailed into Loki for the
  step-failure / event-stream drill-down, surfaced as Loki logs panels.
- Incident correlation covers **per-host** (N-failures-in-M-minutes) and
  **cross-host / pool-wide** (K hosts failing within a short window). The
  failure-class + severity breakdown is a dashboard panel over the Loki
  `step_failure` events (not yet attached to the incident *object* itself). A
  collector restart re-derives fail windows + restores open incidents (per-host
  and pool-wide) from Loki's retained feeds; fails older than that retention
  aren't reconstructed. Cross-host correlation is temporal only (K hosts in a
  window) -- it does not yet require the SAME failure class across hosts.
- Only the **current** cycle's events are tailed, so a cycle that completes and
  rolls to a new folder between 30s polls can drop its trailing events. A failed
  cycle lingers in the runner's failure-pause, so its `step_failure` is reliably
  captured; a fast passing rollover may lose the final `step_end` lines (the
  cycle's pass/fail outcome is still captured via the status.json transition).
- Assumes each host's status server is on `:8080` (`-status-port`); a host on a
  remapped port isn't probed correctly until the registration record carries the
  real port (planned).
- TLS on `:9400` (proxy-CA leaf) + a bearer-gated `POST /ingest` push
  route that SUPPLEMENTS pull (closing the trailing-event gap; Loki dedups the overlap).
  Push is default-off (disabled until a shared `pool-auth-token` is configured);
  `/metrics`, `/healthz`, `/api/v1/pool-status` stay open + unauthenticated for the
  hostname-free dashboard + the local Prometheus scrape. Still trusted-LAN posture
  (the runner's `/metrics` read uses encryption-without-pinning; the token-bearing push
  pins the pool CA).
- **Service-data durability:** the collector itself is stateless — it rehydrates
  counters + open incidents from Loki on restart (point 6) — and the underlying
  Loki / Prometheus / Grafana stores on the proxy are now archived to the NAS by
  networkStorage.pool* **service replication** (an hourly guest-side `ypool-nas-replicate.timer`),
  so a reimaged proxy can be restored. Squid + zot caches are excluded. See
  [docs/pool-storage.md](../../../docs/pool-storage.md) (Service replication +
  restore procedure).
- The pool telemetry is **hostname-free**, so the unauthenticated dashboard never
  renders a host's hostname: hosts are identified by `hostId` everywhere. The
  `hostname` label is dropped from every metric; the transition (`src=cycle`) and
  incident (`src=incident`) Loki lines carry no hostname (cross-host incidents
  report affected hosts by `hostId`); and each forwarded NDJSON event
  (`src=event`) is run through `redactEventLine`, which strips the `hostname` field
  and the hostname-bearing `cycleFolder`. The metric/JSON struct field carrying
  the hostname is `json:"-"` (never parsed or serialized), so the unauthenticated
  `/api/v1/pool-status` snapshot is hostname-free too. The host's own (separately
  authenticated) status page keeps the full detail. **One residual:**
  `cycleFolderUrl`, whose host-side folder name embeds the hostname, is still
  present in the table's Last-cycle deep-link URL and in the `/api/v1/pool-status`
  JSON snapshot — never as rendered dashboard text. Eliminating it needs a
  host-side cycle-folder rename (or dropping the per-cycle deep-link), out of the
  collector's control.
- The table is mixed-datasource: `host_info` + last-seen (Prometheus, deep-link
  URLs as hidden columns) joined by `hostId` via `merge` + `organize` with the
  Pass/Fail counts, which come from **Loki** `count_over_time(...[$__range])` over
  the transition log — exact, range-scoped, and reaching back to Loki retention
  (a Prometheus counter window can't, and `metric - offset` collapses to 0 once
  the range exceeds Prometheus's scrape history). A per-host `... or (count(all
  terminal cycles) * 0)` zero-baseline keeps the columns present (showing 0) when
  a range has no fails. The "Failed cycles" tile is the same Loki count summed.
  The state-timeline keys on `host_status` (Prometheus). Verify rendering on a
  live Grafana when iterating the JSON.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.21
