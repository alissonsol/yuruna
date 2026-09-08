<a id="4227a895-0001"></a>

# Yuruna caching-proxy VM dashboards -- what each panel means

> **Who this is for.** An operator reading either Grafana dashboard on the
> caching-proxy VM: **Yuruna cache health (registry path)** (the zot
> pull-through registry) or **Yuruna caching-proxy service** (the Squid web
> path every guest routes HTTP(S) through). Each panel's (i) tooltip gives
> the short reading and links here.

Jump to: [Cache health dashboard (registry path)](#cache-health-dashboard-registry-path) |
[Caching-proxy dashboard (web path)](#caching-proxy-dashboard-web-path)

<a id="4227a895-0002"></a>

## Cache health dashboard (registry path)

This dashboard watches the zot pull-through registry: whether a manifest
answers fast enough for a real client, whether the upstream pull budget is
the reason it does not, and whether the VM itself is the bottleneck.

<a id="4227a895-0003"></a>

### Manifest latency (canary)

Time for a HEAD of the canary tag through this cache, which re-runs the on-demand
upstream sync. Amber starts at 5s; red starts at 30s because dockerd abandons a pull
whose response headers have not arrived by roughly then -- a cache can sit green on
every liveness check and still be past this line.

<a id="4227a895-0004"></a>

### Manifest path fast enough for a real pull?

Whether the canary beside this one answered inside the response-header deadline a
client applies -- `yuruna_zot_manifest_client_patience_seconds`, 30s for dockerd. Green
"pull-viable" when it did; red "PULLS FAILING" when it did not. zot sends no headers
until its on-demand sync resolves, so a manifest that eventually returns 200 at 55s is
one every pull against it abandons. The latency stat measures the stall; this says
whether what it measured is survivable.

<a id="4227a895-0005"></a>

### Upstream pull budget left

Anonymous pulls remaining in the current window for this egress IP, shared by every
guest in the lab. Green at 25 or more remaining, amber from 10 up, red below 10.
Exhausting it does not reach a guest as a clean 429 -- the pull-through retries
upstream first, and the guest only sees a cache that stopped answering in time.

The panel is gated on the probe gauge: the exporter reports an unread budget as zero,
so an ungated panel would paint an auth or egress failure in the same red as a genuine
exhaustion. "No data" here therefore means the budget was not read -- deliberately not
drawn as zero.

<a id="4227a895-0006"></a>

### zot /v2/ liveness

The check every client-side gate performs today. Green "up" when the endpoint answers;
red "DOWN" otherwise. Kept beside the canary on purpose: it answers in milliseconds
throughout a manifest stall, so agreement between the two is the point -- "up" here
with a red canary beside it is the fault signature.

<a id="4227a895-0007"></a>

### Manifest path latency: canary vs what clients actually got

The canary (one probe every 10 minutes) against the quantiles of every HEAD zot served.
The quantiles come from zot's own histogram, so they include the guests' pulls; when
they climb together the cache is the cause, when only the guests' climb the load is.

<a id="4227a895-0008"></a>

### Upstream registries: round trip from this VM

Unauthenticated `GET /v2/` per configured sync upstream, which spends no pull budget.
This is the leg zot depends on: flat here while the canary above climbs means the stall
is inside the cache, not on the way out of it.

<a id="4227a895-0009"></a>

### Upstream pull budget over time

Budget remaining across the window. A sawtooth that reaches zero names rate limiting as
the trigger for a cluster of slow-manifest failures. The remaining series is gated on
the probe gauge so a window the exporter could not read breaks the line instead of
drawing a floor at zero, which would read as the exhaustion this panel exists to spot.

<a id="4227a895-000a"></a>

### Cache VM: CPU busy %

Host-level load for the VM every service here runs on -- the discriminator between a
starved box and a service blocked on something remote.

<a id="4227a895-000b"></a>

### Cache VM: memory available / cache disk free

Memory headroom and free space under the squid `cache_dir` and `/var/lib/zot`. Swap is
masked on this VM, so memory exhaustion presents as the OOM killer rather than as
slowdown.

<a id="4227a895-000c"></a>

### Registry requests slower than 10s

zot's own request log filtered to slow answers. These return 200 -- they are not errors
anywhere else in the stack, which is why a slow cache reads as a healthy one until this
panel is consulted.

<a id="4227a895-000d"></a>

### Sync / upstream lines (no HTTP request attached)

zot lines that belong to the sync extension rather than to a client request -- the
upstream retry and failure record behind a slow manifest. Empty is the normal state;
entries here explain the latency the panels above only measure.

<a id="4227a895-000e"></a>

## Caching-proxy dashboard (web path)

This dashboard watches the web path -- the Squid cache every guest routes HTTP(S)
through: how much traffic is served, how much of it came from cache, and whether the
VM can still reach the internet at all.

<a id="4227a895-000f"></a>

### Client HTTP(S) data served (kB/s): total vs cached

Throughput delivered to clients over a 5-minute window: "Total" (yellow) is every
response, "Cached" (green) is the subset answered from cache. The gap between the two
is the upstream bandwidth the lab still needs.

<a id="4227a895-0010"></a>

### Recent 100 requests

The last 100 client requests pulled from `/var/log/squid/yuruna_access.log` via Loki.
Columns: client IP, status code, response bytes, HTTP method, URL, and User-Agent. This
is the per-request forensic view behind the throughput panel above.

<a id="4227a895-0011"></a>

### Served / From cache (24 hours and 7 days)

Four tiles, one mechanism. "Served" is the total bytes Squid delivered to clients over
the window, from cache or fetched from origin on a miss -- driven by
`squid_client_http_kbytes_out_kbytes_total` from squid-exporter. "From cache" is the
subset answered by cache hits, memory (`TCP_MEM_HIT`) and disk (`TCP_HIT`) -- driven by
`squid_client_http_hit_kbytes_out_bytes_total`. Comparing the pair over a window gives
the byte hit ratio the lab is actually getting.

<a id="4227a895-0012"></a>

### Internet connectivity

Whether the cache VM can reach the upstream internet. Green "On" when an HTTPS GET of
`https://www.google.com/generate_204` succeeds within 5s, deliberately with no proxy in
the path; red "Off" when it does not -- misses cannot be fetched, and what keeps being
served depends on offline mode below. "Unknown" means the probe has not reported at
all: the metric (`squid_internet_reachable` from `squid-meta-exporter.sh`) is absent,
which points at the exporter rather than at the network. The tile renders these words,
never a raw 1/0 -- the metric carries the number underneath.

<a id="4227a895-0013"></a>

### Offline mode support

Whether Squid will keep serving cache hits when upstream fails. Green "On" when the
runtime config has `offline_mode on`, meaning cache hits are served unconditionally
when upstream answers 5xx; red "Off" otherwise. "Unknown" means the live query did not
answer. Queried live from `/squid-internal-mgr/config`, so it reflects what the daemon
is actually applying rather than what a config file says.

<a id="4227a895-0014"></a>

### Cached (Mem) / Cached (Disk)

Currently cached content ready to be served, in memory and on disk. Driven by
`squid_info_Storage_Mem_size` and `squid_info_Storage_Swap_size` (KB) from
squid-exporter, converted to bytes for display.

<a id="4227a895-0015"></a>

## See also

- [hosts-dashboard](https://yuruna.link/hosts-dashboard) -- the pool-wide Yuruna hosts
  dashboard.
- [caching](https://yuruna.link/caching) -- the two composable caching layers and the
  operator reference for the cache VM.
- [squid](https://yuruna.link/squid) -- Squid's own documentation.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.08

Back to [Yuruna](../README.md)
