# Yuruna cache health dashboard -- what each panel means

> **Who this is for.** An operator reading the **Yuruna cache health (registry path)**
> Grafana dashboard on the caching-proxy VM. It watches the zot pull-through registry:
> whether a manifest answers fast enough for a real client, whether the upstream pull
> budget is the reason it does not, and whether the VM itself is the bottleneck. Each
> panel's (i) tooltip gives the short reading and links here.

## Manifest latency (canary)

Time for a HEAD of the canary tag through this cache, which re-runs the on-demand
upstream sync. Amber starts at 5s; red starts at 30s because dockerd abandons a pull
whose response headers have not arrived by roughly then -- a cache can sit green on
every liveness check and still be past this line.

## Manifest path fast enough for a real pull?

Whether the canary beside this one answered inside the response-header deadline a
client applies -- `yuruna_zot_manifest_client_patience_seconds`, 30s for dockerd. Green
"pull-viable" when it did; red "PULLS FAILING" when it did not. zot sends no headers
until its on-demand sync resolves, so a manifest that eventually returns 200 at 55s is
one every pull against it abandons. The latency stat measures the stall; this says
whether what it measured is survivable.

## Upstream pull budget left

Anonymous pulls remaining in the current window for this egress IP, shared by every
guest in the lab. Green at 25 or more remaining, amber from 10 up, red below 10.
Exhausting it does not reach a guest as a clean 429 -- the pull-through retries
upstream first, and the guest only sees a cache that stopped answering in time.

The panel is gated on the probe gauge: the exporter reports an unread budget as zero,
so an ungated panel would paint an auth or egress failure in the same red as a genuine
exhaustion. "No data" here therefore means the budget was not read -- deliberately not
drawn as zero.

## zot /v2/ liveness

The check every client-side gate performs today. Green "up" when the endpoint answers;
red "DOWN" otherwise. Kept beside the canary on purpose: it answers in milliseconds
throughout a manifest stall, so agreement between the two is the point -- "up" here
with a red canary beside it is the fault signature.

## Manifest path latency: canary vs what clients actually got

The canary (one probe every 10 minutes) against the quantiles of every HEAD zot served.
The quantiles come from zot's own histogram, so they include the guests' pulls; when
they climb together the cache is the cause, when only the guests' climb the load is.

## Upstream registries: round trip from this VM

Unauthenticated `GET /v2/` per configured sync upstream, which spends no pull budget.
This is the leg zot depends on: flat here while the canary above climbs means the stall
is inside the cache, not on the way out of it.

## Upstream pull budget over time

Budget remaining across the window. A sawtooth that reaches zero names rate limiting as
the trigger for a cluster of slow-manifest failures. The remaining series is gated on
the probe gauge so a window the exporter could not read breaks the line instead of
drawing a floor at zero, which would read as the exhaustion this panel exists to spot.

## Cache VM: CPU busy %

Host-level load for the VM every service here runs on -- the discriminator between a
starved box and a service blocked on something remote.

## Cache VM: memory available / cache disk free

Memory headroom and free space under the squid `cache_dir` and `/var/lib/zot`. Swap is
masked on this VM, so memory exhaustion presents as the OOM killer rather than as
slowdown.

## Registry requests slower than 10s

zot's own request log filtered to slow answers. These return 200 -- they are not errors
anywhere else in the stack, which is why a slow cache reads as a healthy one until this
panel is consulted.

## Sync / upstream lines (no HTTP request attached)

zot lines that belong to the sync extension rather than to a client request -- the
upstream retry and failure record behind a slow manifest. Empty is the normal state;
entries here explain the latency the panels above only measure.

## See also

- [caching-proxy-dashboard](https://yuruna.link/caching-proxy-dashboard) -- the web
  path: the squid dashboard on the same VM.
- [hosts-dashboard](https://yuruna.link/hosts-dashboard) -- the pool-wide Yuruna hosts
  dashboard.
- [caching](https://yuruna.link/caching) -- the two composable caching layers and the
  operator reference for the cache VM.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.19

Back to [Yuruna](../README.md)
