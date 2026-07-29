# pool-aggregator-service

The read-only multi-host **pool view** for the Yuruna test harness — the
MVP of the pool harness (see [docs/opportunities.md](../../../docs/opportunities.md)).

## What it does

A small stdlib-only Go daemon that runs on the **caching-proxy-service machine** (the
pool services host). It needs **no host list** — it auto-discovers pool members.
Every `-interval` (default 30s) it:

1. **Discovers candidate IPs from the squid access log**
   (`/var/log/squid/yuruna_access.log`) — every host that pulls
   packages/images through the proxy appears there. Reads only the recent tail
   (last ~35 min, just over a 30-min DHCP lease), plus the last-known IP of each
   host already in the view (so an idle host stays live).
2. **Probes** each candidate IP's status service (`http://<ip>:8080/runtime/status.json`)
   and keeps the ones that answer with a `hostId`. Non-runners (guests, other
   clients) don't serve it and are dropped.
3. **Identifies on the stable `hostId`** (the persistent `runtime/host.uuid`), not the
   IP. This makes the pool **DHCP-resilient**: a host that changes IP reappears
   at the new IP and resolves to the **same** `hostId` (one member, not two); a
   host that cycles through many IPs over short leases collapses to one `hostId`;
   and there is **no DNS dependency** — everything keys off log IPs + `hostId`.
4. On a **cycle-status transition**, pushes one line to **Loki**
   (`/loki/api/v1/push` on `127.0.0.1:3100`) with labels `{pool,hostId,cycleStartUtc,src=cycle}`
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
   cycleStartUtc, cycleFolderUrl, derived status —
   keyed on `hostId`, **no** hostname; `version` is the host's framework
   `VERSION`, fetched per poll from `<baseUrl>/yuruna-repo/VERSION`; `commit` is
   the current cycle's short SHAs (framework, project) from `status.json`'s
   `gitCommits`, with `commitUrl`/`projectCommitUrl` the per-repo
   `…/commit/<sha>` deep-links the table's Commit column resolves; `control` is
   the remote-control verdict of point 5c),
   `yuruna_pool_host_status` (numeric 0–5:
   unreachable/running/pass/fail/idle/paused), and `yuruna_pool_host_last_seen_seconds`.
   Served at `/metrics`. The whole pool telemetry is **hostname-free** (see below).
5b. **Discovers extension hosts (registration-driven).** Each poll it reads every
   pool host's `host.registration.json` (already fetched for poolId/gating) and, for
   each `area` in that record's **`activeExtensions`** — the runtime list of
   extension services the host is ACTIVELY running (e.g. `stash-service` when it
   hosts a stash-service VM; the host writes it via `Start-StashServiceVM` →
   `runtime/stash-service.json` → `Write-HostRegistrationRecord`, which also refreshes
   it on bring-up so the host appears WITHOUT waiting for a test cycle) — exposes
   `yuruna_pool_host_extension{hostId,area,baseUrl,target}` (+`_last_seen_seconds`).
   This keys on the SAME `hostId` namespace as the pool table, so a host that both runs
   cycles and hosts a stash service shows one Host ID in both. It needs **no ystash-nas
   mount and no config service** on the aggregator's host — a host self-reports the
   service it runs and the aggregator already polls its registration. Drives the
   dashboard's **Extension hosts** table (`stash-service` → "Stash service"). `target`
   (the service UI the host advertised in the registration record's
   **`extensionTargets`**, e.g. the stash-service VM's base URL it resolved via `Get-VMIp`)
   rides as a label so the table deep-links the Extension cell
   **directly** — the SAME hidden-URL-column
   pattern the Pool hosts table uses for `baseUrl` (a Grafana table column carries no
   field labels, so a `${__field.labels.hostId}` redirect would resolve empty).
   `baseUrl` (the host's status page, empty when the pool does not know the host)
   rides too, but the Host ID cell is **not** linked: an extension host that runs no
   cycles has no status page, so `/go/host` would answer *host not known to the
   pool* — open such a host from the **Pool hosts** table instead. The
   `extensionTargets` map is also exposed in `/api/v1/pool-status` for the stash UI's
   `hostId → stashBaseUrl` lookup, and `/go/stash` resolves it for IP-free consumers.
5c. **Accepts extension self-announces (`POST /announce`).** The registration path
   above goes silent whenever the owning host's status service is down — routinely,
   after a host reboot — while the service VM auto-restarts and keeps serving. So the
   service announces ITSELF: the stash service POSTs `{hostId, area, targetPort}` at
   startup, every beacon period (default 15 min), and `active:false` at shutdown. The advertised URL is derived from the announce's SOURCE
   address (an announcer can only advertise itself — the same trust squid-log
   discovery extends to any LAN client), the row's `baseUrl` fills from the host view
   when the host is known, and a registration row for the same `(hostId, area)` wins.
   Entries reap after `-announce-ttl` (default 45m, two missed beacons) or on a
   goodbye; every accepted announce is pushed to Loki (`{pool,hostId,src=announce}`)
   so a collector restart restores live rows instantly instead of waiting a period.
   Announce-fed targets also back `/go/stash` and pool-status `stashBaseUrl` when the
   registration has nothing. Open-by-design write route (no bearer): telemetry-only,
   tightly validated, bounded, self-identity-bound; `-announce-ttl 0` disables it.
5d. **Answers "where is area X served?" (`GET /api/v1/extension-hosts`).** The
   registration + announce records above are also the pool's answer to a host that
   NEEDS a service it does not run. Such a host cannot find the stash service (or
   pool-control service) on its own: the service lives on another host, often another
   subnet, at an address DHCP is free to change, and nothing in the consuming
   host's config knows where it is — so the alternative is a hard-coded literal
   that is correct only until the service moves, and then a cycle spends its whole
   timeout budget on a machine that no longer exists. Since the aggregator runs
   inside the caching-proxy-service VM, knowing the **proxy** address — which every host
   already needs, to reach the cache at all — becomes enough to locate everything
   else the pool offers. Conversely a host with no caching-proxy service has no aggregator
   to ask, and no pool: there is nothing to look up, and the lookup says so.

   `?area=<slug>` returns one area (`404` when the pool knows no live host for it,
   so a caller can tell "not there" from "here it is"); no query returns every
   area. Each entry carries `host` (the bare address callers compose probes and
   scp targets from), `target` (the advertised base URL), `hostId`, `source`
   (`registration` | `announce`) and `lastSeenUnixMs`. Registration wins over an
   announce — the owning host re-resolves that target live each cycle, so it tracks
   a DHCP change sooner than the next beacon — then freshest, then lowest hostId,
   so the answer is deterministic and a consumer that re-asks is not walked between
   equally valid hosts. A TTL-expired announce is skipped at read time rather than
   trusted until the next poll reaps it. Read-only and unauthenticated, the same
   posture as `/api/v1/pool-status`: it discloses service coordinates to a caller
   already on the LAN those services listen on, and every consumer proves the
   address independently (the stash pre-flight demands `/healthz`) before using it.
   Host-side reader: `Get-PoolExtensionHost -Area stash-service` in
   [`default.psm1`](default.psm1) — the pool half on its own. Client code calls
   the framework entry point instead,
   `Get-ExtensionHostAddress -HostType stash-service`
   ([`Test.Extension.psm1`](../../modules/Test.Extension.psm1)), which returns
   this answer in a list alongside the addresses the host can see without a pool.
   See [Extensions API — finding a service this host does not
   run](../../../docs/extensions-api.md#finding-a-service-this-host-does-not-run).
5e. **Reports which hosts it can actually drive.** Each poll it also reads every
   reachable host's `GET /control/control-status` (open, read-only) and classifies
   the answer into `yuruna_pool_host_info`'s **`control`** label — the dashboard's
   **Control** column, which is also the host link. `ready` ("remote") means the
   host holds the SAME `lab-auth-token` this proxy mints proofs from, so its
   control buttons will work; `none`/`mismatch`/`skew` ("onsite") mean they will
   403 because the host holds no token, holds a different one (enrolled against a
   proxy since rebuilt), or has a clock skewed far enough to expire a fresh proof;
   `unknown` means the host never answered — a framework build older than that
   route does not serve it, and guessing "onsite" there would read as a false
   negative on every host during a rollout. The comparison is on a non-secret
   **tag** (`HMAC-SHA256(token,"yuruna-control|tag|v1")`) that names the token
   without disclosing it, compared **inside this process**: only the state name is
   ever exported, because `/metrics` is unauthenticated. A host that answers
   replaces its verdict (including the 404 of an older build, so a stale `ready`
   cannot persist); a host that does not answer keeps the last one, since the row
   already reports it unreachable. See
   [control-routes.md](../../../docs/control-routes.md#get-controlcontrol-status).
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
   (`{pool,hostId,src=incident}`, with `failCount` / `peakFails` / `durationSeconds`).
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
   `durationSeconds`); restored from the incident feed on restart like per-host.
9. **Serves the lab connection token exchange.** Every `-lab-token-rotate`
   (default 60s) it mints a 6-character **lab connection token** (lowercase
   a-z0-9) and exposes it as `yuruna_pool_lab_token{pool,token}` — an info
   gauge carrying the current code — which drives the dashboard's **Lab token**
   stat tile. A host redeems the displayed code at `POST /api/v1/lab-token`
   (via `test/Set-LabToken.ps1`) and receives the shared **lab-auth-token**,
   the bearer that gates `/ingest` and the other token-gated pool routes; a
   displayed code stays redeemable for about three rotations, so the tile never
   shows a code that is already dead. The reply is **sealed under the redeemed
   code** (AES-256-GCM, PBKDF2-HMAC-SHA256 key over code + fresh salt): that is
   what authenticates this aggregator to a host that cannot verify its TLS leaf
   — the leaf is signed by the proxy's own CA, which an enrolling host has no
   reason to trust yet — and it keeps the shared token off the wire in the clear
   on a proxy running plain HTTP. The exchange is per-address throttled (IPv6
   grouped by /64) and every attempt is audited (aggregator log + Loki, label
   `src="lab-token"`; the code itself is never logged) and counted in
   `yuruna_pool_lab_token_exchanges_total{pool,outcome}`. `-lab-token-rotate 0`
   disables the tile and the exchange; the tile shows `off` when the aggregator
   holds no token.

The pool view is rendered by **Grafana** (`grafana-pool-dashboard.json`, uid
`yuruna-pool`) over Prometheus + Loki: a five-tile summary row (**Hosts
reachable** · **Hosts total** · **Failing now** · **Failed cycles** ·
**Collector**), a **Lab token** stat beside the **Extension hosts** table
(the 6-char lab connection token — point 9), a **per-host table** (control ·
type · framework version · last cycle · status · last seen · pass/fail, with
deep-links to each host's own status page and cycle folder), a **host × time state-timeline**, and a collapsed **drill-down**
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
- `pool-aggregator-service.service` — systemd unit (`User=proxy`, hardened,
  `ReadOnlyPaths=/var/log/squid` to read the access log; `:9400`; `ExecStart`
  carries `-auth-token-file /etc/yuruna/lab-auth.token -host-ttl 24h
  -lab-token-rotate 60s`).
- `pool-aggregator-service.config.yml` / `pool-aggregator-service.contract.yml` — the Yuruna
  extension area scaffolding (mirrors `caching-proxy-parser-service`).
- `default.psm1` — `Get-PoolAggregatorServiceManifest` (metadata; nothing runs on the
  harness host).
- `grafana-pool-dashboard.json` — the `yuruna-pool` dashboard. **Canonical,
  lintable copy.** It is NOT fetched at boot; an identical copy ships inline via
  `write_files` in `host/vmconfig/caching-proxy-service.base.user-data` so the dashboard
  deploys even when the collector build fails or its source has not yet reached
  public `yuruna`. Edit this file, then sync the inline copy (keep the two in
  step). The timeline's "open cycle results" and "open host status page" data
  links, and the Pool hosts table's **Control** cell, all target
  `${aggregator}`, a hidden constant variable holding this
  proxy's `/go/` base — routing every host click through `/go/host` is what
  hands the browser the short-lived control token the host's Pause/Continue
  buttons require. **No Host ID cell is a link, in any table.** In Pool hosts
  that is so exactly one cell per row grants control and it is the one that says
  whether control is on offer (point 5e); in **Extension hosts** it is because a
  host may run an extension service without running cycles, and then it has no
  status page for `/go/host` to resolve at all. Both copies carry the literal `AGGREGATOR_BASE_PLACEHOLDER`,
  which cloud-init substitutes at boot with `http://<proxy-ip>:9400` — always
  plain http: the `/go/*` hop only redirects the browser to plain-http host
  status pages, so an https link would put a proxy-CA interstitial in front of
  every host click while protecting nothing the next hop does not already carry
  in clear. The aggregator answers both protocols on `:9400` (TLS stays for the
  token-bearing clients: the ingest forwarder, `Set-LabToken.ps1`, the
  Prometheus scrape).

  The `gridPos.h` of the three **per-host** panels (host × time timeline, Pool
  hosts, Extension hosts) is only a pre-collector default. Grafana has no
  "fit to content" panel height, so on the proxy VM
  `yuruna-fit-pool-dashboard.py` (cloud-init `write_files` +
  `yuruna-fit-pool-dashboard.timer`, every 5min) recomputes those heights from
  the live host count and rewrites the provisioned copy in place, so a table
  sized for today's pool neither scrolls when a host joins nor shows dead
  whitespace when one leaves. The script also keeps the **Lab token** stat
  (id `18`, beside the 20-unit-wide Extension hosts table) in step with that
  table's row and height. Changing the panel **ids** (`7`, `6`, `17`, `18`) or
  adding a fourth per-host panel means updating that script.

## Flags

`-squid-log` (default `/var/log/squid/yuruna_access.log`) · `-status-port`
(default `8080`) · `-loki` · `-pool` (default `default`) · `-interval`
(default `30s`) · `-listen` (default `:9400`) · `-rehydrate-window` (default
`168h`; `0` disables — see above) · `-incident-fails` (default `3`) ·
`-incident-window` (default `2h`) · `-cross-host-fails` (default `3`) ·
`-cross-host-window` (default `15m`) · `-host-ttl` (default `24h`) · `-announce-ttl` (default `45m`; `0`
disables `POST /announce`) · `-auth-token-file` (file holding the shared
lab-auth-token that bearer-gates `/ingest` + `/api/v1/forget-host`; the unit
points it at `/etc/yuruna/lab-auth.token`) · `-lab-token-rotate` (default
`60s`; `0` disables the Lab token tile and the `/api/v1/lab-token` exchange).

## Endpoints (`:9400`)

HTTPS when the proxy-CA TLS leaf (`/etc/squid/ssl_cert/pool-aggregator-service.crt`) is present
(it is minted in cloud-init, so a rebuilt proxy serves `:9400` over TLS); plain HTTP when
the leaf is absent.

| Path | Method | Auth | Purpose |
|---|---|---|---|
| `/healthz` | GET | none | `ok` liveness |
| `/metrics` | GET | none | Prometheus text (`yuruna_pool_*`) — scraped by the local Prometheus |
| `/api/v1/pool-status` | GET | none | JSON snapshot of every discovered host's last poll |
| `/api/v1/extension-hosts[?area=<slug>]` | GET | none | where the pool currently sees each extension area served. With `?area=` one entry (`area`, `host`, `target`, `hostId`, `source`, `lastSeenUnixMs`) and **404** when no live host serves it; without it every area at once. Registration beats announce, then freshest, then lowest hostId; a TTL-expired announce is skipped at read time. The lookup a host uses to find the stash / pool-control service knowing only the caching-proxy-service address |
| `/go/cycle?host=<hostId>&t=<epochMs>` | GET | none | dashboard timeline click → 302 to that host's cycle-results folder. Resolves the host's **current** IP from the live view (so the link survives a host IP change) and the cycle covering `t` (current cycle in-memory, else the host's `/log/` listing, else the Loki transition feed); degrades to the host's status root when the folder can't be resolved |
| `/go/host?host=<hostId>` | GET | none | dashboard timeline click → 302 to that host's status-page **root**. Same `host` uuid → **current** IP resolution as `/go/cycle` (survives a host IP change), but always lands on the status page rather than a cycle folder — the IP-free state-timeline rows can't carry the IP, so the link resolves it here |
| `/go/stash?host=<hostId>&area=<area>` | GET | none | 302 to that host's extension-service UI (default `area=stash-service`, the stash-service VM), resolved from the URL the host **advertised** in `extensionTargets` (refreshed each cycle / on `Start-StashServiceVM` via `Get-VMIp`). For IP-free, hostId-only consumers — the dashboard table itself links directly via the `target` label. Unknown host/target → 404 |
| `/api/v1/lab-token` | POST | none (per-IP throttled) | lab-token exchange: body `{"labToken":"<6 chars>"}` → `200 {"ok":true,"v":1,"salt":…,"nonce":…,"ciphertext":…,"tag":…}` — redeems the dashboard's **Lab token** code for the shared lab-auth-token, sealed under that code so only the redeemer can open it (called by `test/Set-LabToken.ps1`). `400` malformed, `403` unknown/expired code, `429` per-IP throttle, `503` disabled (`-lab-token-rotate 0`). Every attempt audited (aggregator log + Loki, `src="lab-token"`) |
| `/ingest` | POST | Bearer | runner-side push of NDJSON events (supplements pull); the bearer is the shared lab-auth-token (`-auth-token-file`). `503` when the proxy holds no token — a failure state, since the proxy build mints one |
| `/api/v1/forget-host?hostId=<42-hex>` | POST | Bearer | operator eviction: drop one hostId from the in-memory view NOW (all per-host maps → gone from the next `/metrics` scrape) instead of waiting out the configured host TTL (`-host-ttl`). Same token as `/ingest`; 503 when no token, 400 on a malformed id. JSON `{forgotten, hostId, wasPresent}`. A still-reachable host is re-discovered on the next poll — stop/drain it first. Called by `test/Remove-PoolHost.ps1` |
| `/announce` | POST | none (self-identity-bound) | extension-presence beacon (stash service et al., point 5c): the advertised URL derives from / must match the sender's address, so an announcer can only advertise itself; telemetry-only, bounded, disabled (503) when `-announce-ttl` is `0` |

## Deploy + verify

Built + installed on the caching-proxy-service VM's first boot by that VM's cloud-init
(`host/vmconfig/caching-proxy-service.base.user-data`). The build fetches the source
from the **LOCAL host working tree** served by the deploying host's status
server (`http://<host>:<port>/yuruna-repo/test/extension/pool-aggregator-service/`) —
the same base-URL resolution as `automation/fetch-and-execute.sh`: read
`/etc/yuruna/host.env` (host IP+port baked into the seed by `New-VM.ps1`), probe
`/livecheck`, else fall back to github raw. It then `go build`s, installs the
binary + unit, and `systemctl enable --now`s. Failure is soft.

Because it reads the host's **live working tree**, **no github mirror is
required** — the host serves whatever is checked out at request time, so a
rebuild always gets the latest local source. `Start-CachingProxyServiceVM.ps1` starts the
status service before creating the VM. If the server is unreachable (or
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
systemctl status pool-aggregator-service
curl -sk https://localhost:9400/healthz            # -> ok
curl -sk https://localhost:9400/api/v1/pool-status | jq   # discovered hosts (after some proxy traffic)
curl -sk https://localhost:9400/api/v1/extension-hosts | jq              # every area the pool can locate
curl -sk 'https://localhost:9400/api/v1/extension-hosts?area=stash-service' | jq   # one area; 404 when nobody serves it
curl -sk https://localhost:9400/metrics            # -> yuruna_pool_* lines
# Prometheus target pool-aggregator-service UP; Loki has {pool,hostId,cycleStartUtc} streams;
# Grafana 'Yuruna hosts' dashboard renders the 24h cross-host view.
```

## MVP limits

- **Initial** discovery is **proxy-traffic-driven**: a host first appears only
  once it (or its guests) has pulled through the proxy. A host that has never
  routed through the proxy won't be discovered (registration-driven
  discovery is planned). Once discovered, though, a host is remembered — re-probed at its
  last-known IP while idle (`hostTtl`) and re-seeded from Loki's presence beacon
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
- Assumes each host's status service is on `:8080` (`-status-port`); a host on a
  remapped port isn't probed correctly until the registration record carries the
  real port (planned).
- TLS on `:9400` (proxy-CA leaf) + a bearer-gated `POST /ingest` push
  route that SUPPLEMENTS pull (closing the trailing-event gap; Loki dedups the overlap).
  The bearer is the shared `lab-auth-token`, minted and stored in the building
  host's vault at proxy build when none exists — so push is enabled once the
  proxy is built and hosts enroll (`test/Set-LabToken.ps1` redeems the
  dashboard's Lab token code). `/metrics`, `/healthz`, `/api/v1/pool-status`
  stay open + unauthenticated for the
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

Last review: 2026.07.27
