# Yuruna caching-proxy dashboard -- what each panel means

> **Who this is for.** An operator reading the **Yuruna caching-proxy service** Grafana
> dashboard on the caching-proxy VM. It watches the web path -- the squid cache every
> guest routes HTTP(S) through: how much traffic is served, how much of it came from
> cache, and whether the VM can still reach the internet at all. Each panel's (i)
> tooltip gives the short reading and links here.

## Client HTTP(S) data served (kB/s): total vs cached

Throughput delivered to clients over a 5-minute window: "Total" (yellow) is every
response, "Cached" (green) is the subset answered from cache. The gap between the two
is the upstream bandwidth the lab still needs.

## Recent 100 requests

The last 100 client requests pulled from `/var/log/squid/yuruna_access.log` via Loki.
Columns: client IP, status code, response bytes, HTTP method, URL, and User-Agent. This
is the per-request forensic view behind the throughput panel above.

## Served / From cache (24 hours and 7 days)

Four tiles, one mechanism. "Served" is the total bytes squid delivered to clients over
the window, from cache or fetched from origin on a miss -- driven by
`squid_client_http_kbytes_out_kbytes_total` from squid-exporter. "From cache" is the
subset answered by cache hits, memory (`TCP_MEM_HIT`) and disk (`TCP_HIT`) -- driven by
`squid_client_http_hit_kbytes_out_bytes_total`. Comparing the pair over a window gives
the byte hit ratio the lab is actually getting.

## Internet connectivity

Whether the cache VM can reach the upstream internet. Green "On" when an HTTPS GET of
`https://www.google.com/generate_204` succeeds within 5s, deliberately with no proxy in
the path; red "Off" when it does not -- misses cannot be fetched, and what keeps being
served depends on offline mode below. "Unknown" means the probe has not reported at
all: the metric (`squid_internet_reachable` from `squid-meta-exporter.sh`) is absent,
which points at the exporter rather than at the network. The tile renders these words,
never a raw 1/0 -- the metric carries the number underneath.

## Offline mode support

Whether squid will keep serving cache hits when upstream fails. Green "On" when the
runtime config has `offline_mode on`, meaning cache hits are served unconditionally
when upstream answers 5xx; red "Off" otherwise. "Unknown" means the live query did not
answer. Queried live from `/squid-internal-mgr/config`, so it reflects what the daemon
is actually applying rather than what a config file says.

## Cached (Mem) / Cached (Disk)

Currently cached content ready to be served, in memory and on disk. Driven by
`squid_info_Storage_Mem_size` and `squid_info_Storage_Swap_size` (KB) from
squid-exporter, converted to bytes for display.

## See also

- [cache-health-dashboard](https://yuruna.link/cache-health-dashboard) -- the registry
  path: the zot pull-through dashboard on the same VM.
- [hosts-dashboard](https://yuruna.link/hosts-dashboard) -- the pool-wide Yuruna hosts
  dashboard.
- [caching](https://yuruna.link/caching) -- the two composable caching layers and the
  operator reference for the cache VM.
- [squid](https://yuruna.link/squid) -- Squid's own documentation.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.20

Back to [Yuruna](../README.md)
