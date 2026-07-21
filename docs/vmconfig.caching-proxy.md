# Caching-proxy cloud-init reference

This file collects the rationale behind every non-trivial cloud-init stanza in
[`host/vmconfig/caching-proxy.base.user-data`](../host/vmconfig/caching-proxy.base.user-data) --
the seed that builds the Yuruna **caching-proxy** VM (squid SSL-bump cache +
zot OCI pull-through registry + the Prometheus / Grafana / Loki observability
stack + the pool-aggregator collector). The user-data file stays lean: each
topic collapses to a single line of the form:

```
# --- REGION: https://yuruna.link/vmconfig/caching-proxy#<topic-slug>
```

The fragment resolves to a `### <topic name>` heading in this file (standard
GitHub Markdown slug: lowercase the heading, drop punctuation, spaces become
hyphens).

This is the cache-VM companion to the guest-side
[vmconfig topic reference](vmconfig.md). The cache is covered from three angles
across sibling docs:

- [vmconfig.md](vmconfig.md) -- shared guest user-data rationale; the cache
  appears there only as a *client* concern (apt proxy block, CA trust, proxy
  egress enforcement).
- [caching-proxy.md](caching-proxy.md) -- the operator / wiring reference
  (serving remote clients, port-map dispatch, host-proxy promotion). That doc
  is about *using* the cache; this one is about how the cache VM is *built*.
- [caching.md](caching.md) -- squid SSL-bump, refresh_pattern and
  YurunaCacheContent concepts referenced from the embedded squid.conf.

Comments that live *inside* the deployed artifacts (the squid.conf directives,
the embedded Python rewriter, the runcmd shell scripts, the systemd units) stay
with their file -- they ship to the guest and are read in place when debugging
the running VM. This document covers the cloud-init-level structural rationale.

Sections are ordered to match the top-to-bottom flow of the user-data
(cloud-config keys, then `write_files`, then `runcmd`), so the file and this
doc can be read side by side.

---

## Topics

### Squid-cache hostname vs template name

```
hostname: yuruna-caching-proxy
```

OS-side hostname is kept in lock-step with the hypervisor's VM / libvirt
domain name (`yuruna-caching-proxy`). Renaming happens HERE only -- the
source-tree directory `guest.caching-proxy/` and the image filename keep the
`caching-proxy` token because they identify the guest type /
template, not the running VM. This split prevents a rename cascade across the
repo every time the runtime VM gets renamed.

### Users replace cloud image default with yuruna

Replace the Ubuntu cloud image's default `ubuntu` user with `yuruna`. Listing a `users:` block WITHOUT `- default` suppresses ubuntu creation entirely -- only the listed users land in /etc/passwd. yuruna gets:
- Passwordless sudo (this VM is a debug box on a private network).
- The yuruna harness SSH key for passwordless `ssh yuruna@<cache-ip>`.
- lock_passwd: false so chpasswd below can set a known random password for console fallback (the host VM console) when cloud-init hasn't finished and SSH isn't up yet.

### Grafana apt repo inline GPG key

Grafana OSS repo: inline ASCII-armored key (keyserver.ubuntu.com access is intermittently unreliable; inline key avoids cascade failures during package-update). Rotate by refetching from https://apt.grafana.com/gpg.key when Grafana publishes a new key (verify fingerprint B53A E77B ADB6 30A6 8304 6005 963F A277 1045 8545).

### Package squid-openssl not squid

squid-openssl: OpenSSL-linked build. Ubuntu's default `squid` package is built WITHOUT --with-openssl (Debian packaging split over OpenSSL vs GPL licensing), so its http_port parser rejects `ssl-bump`, `tls-cert=`, etc. with a "Bungled" FATAL at config-load and squid.service never binds a socket. squid-openssl ships the same /usr/sbin/squid and squid.service unit, and Conflicts: squid.

### squidclient and apache2

squidclient (/usr/bin/squidclient) ships in squid-common (already pulled in by squid-openssl); no separate package needed. PURGE example: curl -x http://<cache>:3128 -X PURGE http://<origin>:<port>/<path>

### Monitoring stack packages

Monitoring stack: Prometheus scrapes squid-exporter (localhost:9301); Grafana on :3000 (anonymous Viewer). squid-exporter has no apt package and no stable GitHub release-asset URL, so golang-go is pulled in just long enough to `go install` it; both build tools are purged at the end of runcmd (~400 MB reclaimed). The compiled binary stays.

loki + promtail back the "Recent 100 requests" Grafana panel -- Prometheus only stores aggregates, so per-request client IP / target URL are not available there. Promtail tails /var/log/squid/yuruna_access.log (squid's custom `logformat yuruna` stream) and ships to Loki on localhost:3100. Both come from apt.grafana.com (same repo as grafana) -- no extra source needed.

### Package acl for promtail log read

acl: needed by the post-zot setfacl step that grants promtail read access on /var/log/zot/zot.log (zot writes mode 0600, so group-read alone isn't enough -- promtail can't tail it without an ACL).

### Network debugging tool packages

Network debugging tools for interactive triage via console/SSH. The server cloud image ships `ip` but not `ifconfig` or `ping`; cheap to install, big quality-of-life win.

### Package openssl for CA generation

openssl for the CA-generation step in runcmd. The cloud image ships libssl but not the /usr/bin/openssl CLI, so `req -x509` would fail with "command not found" and leave squid's http_port 3129 unable to load tls-cert/tls-key. Kept top-level (not apt-get in runcmd) so failure surfaces in the package-install phase, not halfway through cache setup.

### Package unattended-upgrades

unattended-upgrades: applies security + LTS-point patches daily via the stock apt-daily.timer + apt-daily-upgrade.timer units that the package's postinst enables. Combined with the 20auto-upgrades drop-in below it gives the long-lived cache VM a self-maintained patch cadence so it doesn't accumulate CVEs between cache rebuilds. A first-boot `apt-get -y upgrade` at the end of runcmd applies the backlog that exists between the cloud image's build date and now.

### Packages cifs-utils and sqlite3 for NAS replication

cifs-utils + sqlite3 back the optional networkStorage pool (ypool-nas) service replication: the ypool-nas-replicate.timer mounts the NAS share over SMB3 (cifs) and uses sqlite3's online .backup to copy Grafana's live grafana.db consistently. Both are tiny Ubuntu-main packages with no kernel-version dependency, so they stay top-level (failure surfaces in the package phase, not mid-runcmd); the timer is only enabled when the seed was built with replication configured.

### Apt retries on transient errors

Retry apt fetches on transient network errors. Cloud-init's default is one-shot; a single timeout or TCP reset against archive.ubuntu.com fails the whole package install and leaves the VM without squid -- the exact "Exit code: 100 / Stdout: -" failure seen against `apt-get install apache2 squid`. Retries=5 covers transient hiccups; does NOT paper over 4xx (429/404) -- apt treats those as fatal and they need operator attention via /var/log/cloud-init-output.log.

### Unattended-upgrades schedule

unattended-upgrades enable flags. Both timers (apt-daily.timer + apt-daily-upgrade.timer) ship with the apt package and are enabled by default -- this dropin is what turns the upgrade phase on. Update-Package-Lists = run `apt-get update` daily; Unattended-Upgrade = run the upgrade phase daily. Auto-clean keeps /var/cache/apt from growing without bound between cycles. The default /etc/apt/apt.conf.d/50unattended-upgrades scopes upgrades to the security pocket only -- leave that conservative; widening to all pockets risks pulling in a kernel that needs a reboot we can't schedule on a long-lived cache box.

### Pool intent store over read-only HTTP

Pool intent store: serve the bare git repo READ-ONLY over the LAN via apache's static (dumb-HTTP) git protocol. Pooled hosts clone/pull http://<proxy>/pool-intent.git to learn pool membership + desiredState. The repo holds only NON-SECRET intent (pools.yml / test-sets / guests.compatibility); writes go through the admin CLI on the proxy (a local/file:// path), never this HTTP route. RFC1918 only, mirroring the cachemgr access policy.

### Squid drop-in config approach

Drop-in overrides on top of Ubuntu's stock /etc/squid/squid.conf. conf.d files include after the main config so same-named directives here win. Keeping this a drop-in (not a full replacement) means future squid package upgrades still get their default refresh_pattern and ACL baseline -- we only override what's specific to yuruna.

### Snapshot cache tuning

The `/etc/squid/conf.d/yuruna.conf` drop-in tunes squid as a **replayable
snapshot** rather than a churn-optimized web cache:

1. objects stay until the disk is nearly full (no proactive release),
2. the cache keeps serving when origin is unreachable or sends
   cache-hostile headers,
3. with `offline_mode` (flipped by runcmd after prewarm), a full cache
   supports guest installs with zero internet.

**Replacement policies.** `cache_replacement_policy heap LFUDA` keeps
frequently-used large objects (linux-firmware, kernels) over many small
ones; `memory_replacement_policy heap GDSF` does the same in-memory. When
eviction fires, rarely-touched small objects drop first -- the big,
expensive-to-refetch blobs survive, which is what offline replay needs.
The ordering constraint is load-bearing (and stays inline beside the
directive): `cache_replacement_policy` MUST appear before `cache_dir` --
squid binds the policy at `cache_dir` parse time, so a later override has
no effect.

**cache_mem budget math.** `cache_mem 7 GB` is 58 % of the VM's 12 GB,
keeping 2 GB free for the zot OCI registry pull-through cache (which
handles the Docker Hub manifest HEADs squid cannot -- see the zot topics
below). This is a DEDICATED cache VM (squid + zot are the only
top-priority workloads), so the memory budget is sized around these two
directives rather than the other way around. Empirically squid's RSS runs
~1 GB above `cache_mem` (sslcrtd children + connection buffers + in-RAM
hot objects), so 7 GB `cache_mem` implies ~8 GB squid RSS; zot peaks at
~500 MB during heavy parallel pulls; that leaves ~2 GB for apache /
grafana / prometheus / loki / promtail / squid-exporter /
caching-proxy-parser / kernel / page cache. Swap is masked, so tune VM
RAM + `cache_mem` + zot together -- 58 % on a smaller VM would OOM
mid-cycle with no swap fallback. The VM-side numbers (12 GB / 4 vCPU on
every host) are in
[caching-proxy.md -> Cache VM sizing](caching-proxy.md#cache-vm-sizing).

**Disk cache sizing.** `cache_dir ufs /var/spool/squid 393216 16 256`:
384 GB of the 512 GB VM disk for squid (393216 MB in squid's three-int
size/L1-dirs/L2-dirs format), leaving ~128 GB for OS, logs, and
headroom. `ufs` is fine for a single-host dev cache; switch to
`aufs`/`diskd` only if squid blocks on disk I/O under concurrent
installs.

**Object-size ceiling.** `maximum_object_size 65 GB` covers every
install image yuruna currently provisions, including the macOS install
image (~18 GB) and headroom for a 64 GB worst case (Xcode-bundled SDKs,
full Windows Server install media, full-fat dev VM templates). Squid's
threshold is INCLUSIVE -- anything strictly larger is silently NOT
cached -- so the 1 GB headroom on top of 64 GB matters. Raising the
ceiling doesn't allocate disk on its own; it only changes the rejection
threshold.

**Objects until near-full.** `cache_swap_high 99` / `cache_swap_low 98`:
never release unless forced -- evict only when the disk is more than 99 %
full, stopping at 98 %. The squid defaults (90/95) would start evicting
with ~5 GB still free, which is wrong for a sticky snapshot cache.

**offline_mode replay.** `offline_mode on` serves cached objects without
ever revalidating them with origin. Aggressive on purpose -- this VM
exists to keep test cycles running when upstream registries (Docker Hub,
registry.k8s.io, registry.opentofu.org, public.ecr.aws, etc.) have
intermittent 5xx / rate-limit incidents. With `offline_mode` off (the
squid default), the catch-all `refresh_pattern .` still revalidates every
hit, so a single upstream 5xx tears down the cycle even when squid has
everything else cached. With `offline_mode` on, cache MISSes still fall
through to upstream (otherwise the VM could never warm up); only HITs are
served unconditionally. See also "Flip squid into offline mode" below for
the post-prewarm runcmd flip.

**Container-registry digest caching (OCI + Docker v2).** Diagnostics
against active cycles showed identical digest-pinned blob/manifest URLs
being re-fetched multiple times per cycle (per
`awk '$4 ~ /MISS/' /var/log/squid/yuruna_access.log`):
`/v2/.../manifests/sha256:<hex>` and `/v2/.../blobs/sha256:<hex>` are
immutable by definition, yet registries return
`Cache-Control: must-revalidate` (or `private`) on them, so the stock
catch-all `refresh_pattern .` revalidates on every request. The override
targets digest-pinned URLs only (the `sha256:` segment); those cache for
the full year like apt `.deb` files. Tag-based manifest URLs
(`/manifests/<tag>` with no `sha256:`) stay revalidated -- tags ARE
mutable, e.g. `:latest`, `:2`, `:v0.28.4`. They get only a short
freshness window (`5 50% 60`) so concurrent guests in the same cycle hit
cache while a tag move within a few minutes is still picked up --
`collapsed_forwarding` already pools the parallel fetches; the window
just stretches past `must-revalidate`. The digest pattern matches the URL
PATH, so it works for any registry host: registry.k8s.io, ghcr.io,
registry-1.docker.io, public.ecr.aws, us-east4-docker.pkg.dev, and the
CDNs they 307-redirect to (cloudfront, S3, R2 cloudflarestorage) -- those
all carry the `sha256:` segment in the redirected path.

### Prometheus loopback only

Prometheus: loopback-only so its open UI isn't LAN-exposed; Grafana on :3000 is the entry point.

### Loki tiered retention

Loki: loopback-only (same 0.0.0.0 default as Prometheus). Tiered retention: 30d for transitions (src=cycle) + incidents (src=incident) -- the dashboard's count_over_time Pass/Fail + incident history span a month -- and 7d for per-step events (src=event), the recent-focused drill-down (caps disk). Pre-written here because cloud-init's --force-confold preserves it through package upgrades.

### Promtail timestamp only labels

Promtail: only timestamp in labels (client IP/URL in labels = stream explosion); positions.yaml on disk so reboots don't re-tail; /var/lib/promtail created in runcmd because the deb postinst doesn't always create it.

### Promtail supplementary groups drop-in

Promtail drop-in: SupplementaryGroups grants read on the upstream access logs:
- proxy:  /var/log/squid/yuruna_access.log (proxy:proxy 640)
- zot:    /var/log/zot/zot.log             (zot:zot     640)
Can't use Group= -- the promtail postinst falls back to `nogroup` (no `promtail` group created), so referencing it would fail.

### Squid metadata exporter

tiny script that reads the on-disk squid.conf and reports `squid_offline_mode_configured` (1 if `offline_mode on` is set) + `squid_listening` (1 if squid is bound to :3128). Output is a Prom-format file under /var/www/html, served by apache, scraped by Prometheus (job: squid_meta). Two reasons NOT to fold this into squid-exporter:
- squid-exporter taps squid's cachemgr counters; offline_mode is a config directive, not a counter. squid-exporter would need a fork to surface it.
- When squid is DOWN, squid-exporter's metrics stop publishing and Grafana shows "No data" -- exactly when the operator needs to know whether offline_mode was supposed to be on. This exporter reads the file directly, so the signal survives a crashed squid.

### Squid exporter unit

squid-exporter unit: binary go-installed in runcmd, loopback-only (Prometheus scrapes it).

### Grafana anonymous Viewer

Grafana: anonymous Viewer (no login/sign-up); admin/admin still editable. GF_* env vars applied via systemd drop-in.

### Grafana datasources pinned UIDs

Grafana datasources: UIDs pinned for stable cross-reference in the provisioned dashboard.

### Grafana dashboard rewriter

Rewriter for community Grafana dashboards downloaded from grafana.com. Upstream dashboards use a $DS_PROMETHEUS templating placeholder whose embedded default points at the original author's datasource (e.g. "VictoriaMetrics Bagno") -- without rewrite the dashboard loads but every panel renders "No data" until someone clicks through the picker. This script strips the picker and pins every panel's datasource to yuruna-prometheus, plus assigns a stable uid so re-runs are idempotent. Generic across any prometheus-only dashboard; today the only caller is the Zot dashboard install below.

### Grafana dashboard provider

watches /var/lib/grafana/dashboards for JSON; syncs post-boot edits.

### Yuruna host coordinates for source fetch

Yuruna host (status server) coordinates. Baked into the seed by the platform New-VM.ps1 (Get-GuestReachableHostIp + statusService.port). The runcmd build block below sources this to fetch the collector + parser source from the LOCAL host working tree (http://IP:PORT/yuruna-repo/) -- the host repo is the source of truth, so a rebuild never waits on the private->public github mirror. Same resolution as fetch-and-execute.sh. Empty IP/PORT (coordinates unavailable, e.g. status service disabled) make the build fall back to github.

### Yuruna hosts dashboard inlined

Yuruna hosts dashboard. INLINED (like squid.json) so it deploys from the local user-data -- independent of the pool-aggregator binary build AND of any GitHub fetch/mirror -- and therefore shows from first boot ("No data" until the collector is up). Keep in sync with the lintable canonical copy at test/extension/pool-aggregator/grafana-pool-dashboard.json.

### Yuruna hosts dashboard panel autofit

Panel heights are fixed in dashboard JSON; a fixed height per row doesn't scale across pool sizes. The autofit script recomputes heights based on host count. `yuruna-fit-pool-dashboard.py` reads the host count the collector is reporting (Prometheus + Loki on loopback), recomputes each panel's height from the dashboard grid geometry (a panel of `h` units is `38h - 8` px tall, less the chrome, the table header row, and -- on the timeline -- the x-axis and legend), re-stacks the panels below it, and rewrites `/var/lib/grafana/dashboards/pool.json` atomically. Heights round UP: a panel a few px too tall shows blank space, one a few px too short shows a scrollbar, and only the scrollbar is a defect. The `gridPos.h` values inlined above are only the pre-collector default. A collector that is down reports no hosts, which is indistinguishable from an empty pool, so a zero count leaves the file untouched rather than collapsing every panel to its header. Row counts track the dashboard's DEFAULT 24h window; a wider range picked in the time picker can still surface an older host and scroll.

### Squid dashboard inlined

Minimal squid dashboard: panels show "No data" gracefully if metric names drift between exporter releases.

### zot systemd unit

Systemd unit -- runs zot as an unprivileged service user with ProtectSystem=strict + ReadWritePaths confining writes to /var/lib/zot (blob store) and /var/log/zot. There is no apt package for zot on Resolute, so the binary install + manual systemd unit is the simplest path. The binary lands at /usr/local/bin/zot via runcmd.

### NetworkStorage pool replication config

networkStorage pool (ypool-nas) service replication: config + SMB credential + the timer-driven rsync of observability data to the NAS. All values are baked by New-VM.ps1 from the host's networkStorage pool config + vault (empty / REPLICATE=false when off).

### NAS cifs credentials

cifs credentials (0600 root). The networkUser account -- the single NAS account, ACL-scoped storage-only by the operator (write access to the share, nothing else).

### Pool auth token

the shared bearer that gates the aggregator's POST /ingest push surface. Baked by New-VM from the operator-set vault entry (pool.auth.token), or EMPTY when unconfigured -> the aggregator disables /ingest (never an unauthenticated write route). The aggregator trims surrounding whitespace. Mode 0640 root:proxy so the proxy-run aggregator can read it but it is not world-readable.

### Stop squid before CA bootstrap

Stop the squid apt's postinst started: it's FATAL (yuruna.conf references ca.pem before we generate it) or on partial/default config. Don't run `squid -z` here -- it also parses yuruna.conf and FATALs on the missing cert (was tried; left only a scary log FATAL).

### SSL-bump CA bootstrap

both steps idempotent so re-runs don't rotate the CA (rotating would orphan guests that already trusted it). Private key stays proxy:proxy 700; public cert served by Apache. CN includes timestamp to distinguish deliberate rebuilds.

### Pool aggregator TLS leaf

pool-aggregator TLS leaf: mint a server cert for the aggregator's :9400 surface (metrics + ingest), signed by the squid CA above (reused -- no new CA), so the LAN hop is encrypted + authenticated. Idempotent (no rotate). SAN carries the proxy's LAN IP (runners connect by IP) + 127.0.0.1 (loopback Prometheus). Key stays proxy:proxy 600 (the aggregator runs as proxy). Best-effort: a mint failure leaves no leaf and the aggregator falls back to plain HTTP.

### Resolve pool dashboard aggregator URL

Resolve the Yuruna hosts dashboard's aggregator base URL. The timeline's "open cycle results" data link points at this proxy's /go/cycle redirect, which resolves each host's CURRENT IP server-side (so the link survives a host IP change). The proxy's own LAN IP is only known at boot (DHCP), so substitute it here; scheme follows the aggregator's TLS leaf (https when minted, else http). Idempotent: a re-run finds no placeholder. The dashboard provider re-syncs the edited file, so this may land before or after grafana-server starts.

### Squid ssl_db initialization

security_file_certgen's `-c` is create-new and errors if the DB already exists, so the existence check guards re-runs. DB holds leaf certs minted per SNI hostname -- 4 MB is generous (each entry ~1 KB).

The `install -d` for /var/lib/squid is NOT redundant: on Ubuntu the squid-openssl postinst doesn't guarantee this directory, and security_file_certgen's Create() makes only the leaf `ssl_db/` dir, not the parent. Without `install -d` the helper FATALs with "Cannot create /var/lib/squid/ssl_db", sslcrtd children crash-loop on every spawn, squid bails with "The sslcrtd_program helpers are crashing too rapidly, need help!" and squid-parent blocks restart for 3600s. Running as `proxy` avoids a follow-up chown and confirms write access.

### Publish squid CA cert

Publish the CA public cert at http://<cache>/yuruna-squid-ca.crt so guests can fetch and trust it during install. Only the public cert is copied -- ca.key stays in /etc/squid/ssl_cert/. Mode 644 is intentional: RFC1918 reachability is enforced at the network layer (the host switch/bridge/NAT), so trust distribution works without an extra cachemgr-style `Require ip` dropin.

### Publish pool CA cert

Publish the SAME CA under a pool-specific name so a runner can pin the pool-aggregator's TLS leaf (it is signed by this CA) without coupling to the squid CA filename. Public cert only; the key never leaves /etc/squid/ssl_cert.

### Pre-warm the cache

security.ubuntu.com rate-limits linux-firmware (~330 MB) hard enough that every cold guest install 429s on it. Pre-fetching via the local proxy means squid has it before any guest asks, so the first-ever install serves from cache. Pull the HWE meta too so kernel, modules-extra, headers, and microcode .debs land alongside.

Wait up to 60s for squid's listener. apt's postinst usually has it up, but start can be slow on first boot.

### Route VM apt through local squid

Only NOW route this VM's own apt through local squid -- squid is confirmed listening, so the self-proxy loop is safe. Writing this dropin during write_files (before `packages:` runs) deadlocks apt: it tries to fetch squid itself through 127.0.0.1:3128 (not listening yet) and the install bombs with Exit 100.

### Prewarm download loop

Each call: --reinstall --download-only first (forces re-fetch of already-installed packages like linux-firmware); fall back to plain download-only for not-yet-installed packages (linux-generic-hwe-24.04 and friends). `|| true` on the fallback so one miss doesn't abort the loop.

### Reclaim apt cache after prewarm

Squid now has the large .debs cached under /var/spool/squid. Clear /var/cache/apt (squid's store is separate) to reclaim ~1 GB.

### Remove prewarm apt proxy dropin

Remove the apt proxy dropin so future apt inside this VM doesn't loop through its own squid. Guests still reach squid at 3128 over network.

### Flip squid into offline mode

Flip squid into offline_mode now prewarm is done. With offline_mode on, squid serves cached objects without contacting origin -- hit returns stored content, miss returns 504. Enables the "fully disconnected if everything is cached" workflow: guests can apt-install against this proxy with no internet on the host.

Must be AFTER prewarm -- with offline_mode on, a cold-cache first request returns 504 and prewarm populates nothing. Dropped as a separate conf.d file so an operator can refresh against origin by removing the one file and running `squid -k reconfigure`.

### offline_mode echo YAML mapping trap

Single-quote the echo so YAML doesn't parse `cache:` as a mapping key. cloud-init's shellify() chokes on a dict in runcmd and aborts the ENTIRE runcmd phase -- which happened once, leaving a VM with Apache's default page, no cachemgr, no offline_mode, no monitoring even though write_files and packages ran.

### Build squid-exporter and caching-proxy-parser

Build and install squid-exporter + caching-proxy-parser. No apt package for either; `go install` (squid-exporter) and `go build` against fetched source (caching-proxy-parser) keep this cross-arch path working -- amd64 on Hyper-V/KVM, arm64 on UTM, no URL guessing. squid-exporter pinned to v1.13.0 for reproducibility. v1.13.0 is the cutoff: it dropped legacy `cache_mgr://` URI support and switched to Squid 7's `/squid-internal-mgr/` HTTP path. Ubuntu 26.04 (Resolute) ships Squid 7.x, which rejects the old URI; earlier pins (v1.10.5 and below) install fine, scrape clean (squid_up still publishes), but produce squid_up=0 and zero counter metrics because the request path to squid is unreachable -- every Grafana panel that queries `squid_client_http_*_total` ends up empty. See https://github.com/boynux/squid-exporter/releases/tag/v1.13.0 for the cache_mgr -> squid-internal-mgr swap. Both runs happen AFTER the prewarm proxy cleanup so the Go module fetch (HTTPS to proxy.golang.org + GitHub) doesn't traverse squid -- HTTP squid can't cache HTTPS without SSL-bump.

### Purge Go toolchain after builds

Reclaim ~400 MB: Go toolchain is only needed for the builds above; both squid-exporter and caching-proxy-parser are static binaries.

### Start the monitoring stack

daemon-reload picks up the squid-exporter unit + grafana-server drop-in written via write_files. Grafana is restarted (not just enabled) so the anonymous-Viewer env vars take effect even if the deb postinst already started it.

### Enable squid metadata exporter timer

Squid meta exporter: timer drives a oneshot that writes /var/www/html/squid-meta every 30s. Started AFTER apache2 (already active by the packages phase) so the first scrape doesn't 404.

### Prime squid metadata exporter once

Run the script once immediately so /var/www/html/squid-meta exists before Prometheus's first scrape -- avoids a 15-second "No data" window on the dashboard at boot.

### Enable caching-proxy-parser service

caching-proxy-parser fails closed (the binary may not be present if the build above failed); `|| true` keeps the rest of runcmd going so loki+promtail+grafana still come up.

### Enable pool-aggregator service

pool-aggregator: read-only pool view. Soft-fail like the parser -- the binary may be absent if the build above failed; prometheus already has the pool-aggregator scrape job (it just reads 'down' until the daemon is up).

### Pool intent store seeding

Yuruna pool intent store: a bare git repo pooled hosts clone + pull READ-ONLY over HTTP (the yuruna-pool-intent apache conf) to learn pool membership + desiredState. The admin CLI (run on the proxy) pushes intent here. Seeded with an empty, schema-valid pools.yml on 'main' so the first clone is non-empty + deterministic. The post-update hook keeps the dumb-HTTP info current on every push. Idempotent (re-run skips an existing repo) and soft-fail (each fallible step is `|| true`) so it can never abort the phase.

### Wait for grafana-server to bind

Wait for grafana-server to bind :3000 and dump journal if it doesn't. On a slow first boot, grafana can take ~15s to come up after `restart` returns. Without this check, a failed start only surfaces when an operator tries the dashboard and gets "connection refused" -- by which time cloud-init logs may be rotated. Mirrors the squid:3128 diagnostic net so both failure modes surface the same way in /var/log/cloud-init-output.log.

### Enable yuruna hosts dashboard panel autofit

Enable the timer that keeps the Yuruna hosts dashboard's per-host panels sized to the pool (see "Yuruna hosts dashboard panel autofit" above). It first fires 3min after boot -- by then the collector has polled the pool at least once -- and every 5min after, so a host that joins or leaves is reflected within one tick plus the dashboard provider's 30s reload. `--now` also runs it once here, which costs two loopback queries and, on a pool that has not registered yet, does nothing.

### Install community Zot dashboard

Install the community Zot dashboard (Grafana ID 20501) alongside the hand-crafted Yuruna caching proxy dashboard. The upstream JSON uses a $DS_PROMETHEUS templating placeholder whose embedded default points at the original author's datasource ("VictoriaMetrics Bagno"); the rewriter (write_files) strips the picker and pins every panel to yuruna-prometheus + a stable uid + a friendly title so re-runs are idempotent. The dashboard provisioner under /etc/grafana/provisioning/dashboards/yuruna.yaml picks the file up on its next 30s tick. `else` branch keeps cycling: a transient grafana.com outage degrades to "missing extra dashboard" rather than failing the whole runcmd phase.

### Enable NAS replication timer conditionally

networkStorage pool (ypool-nas) service replication: enable the timer only when the seed was built with replication configured (REPLICATE=true). Read it with an exact-line grep, NOT by sourcing -- sourcing a malformed value would abort the whole runcmd phase (a `.`-parse error fires before any `|| true`). Block scalar dodges the colon-space YAML trap; grep dodges the source-time abort.

### Verify promtail supplementary groups

Verify promtail picked up BOTH supplementary groups. The drop-in writes "SupplementaryGroups=proxy zot"; failing on either keeps the corresponding Recent-100 panel empty. The check must verify each group explicitly: grepping only for `proxy` lets a missing `zot` group slip past observability.

### First-boot security upgrade

unattended-upgrades + the daily apt timers will keep pulling fixes from here on; this run flushes the backlog that exists between the cloud image's build date and boot day. Routed through 127.0.0.1:3128 (squid is up by now and the prewarm-proxy dropin already enabled this VM's apt-via-self loop) so the upgrade hits cache for anything other guests have pulled before. `|| true` because we DO NOT want a transient archive.ubuntu.com hiccup to fail the whole cycle -- the daily apt-daily-upgrade.timer will retry within 24 h.

### Confirm apt daily timers armed

Confirm the timers that drive the 24-hour cadence are actually armed. If the apt package's postinst didn't enable them (rare on Ubuntu but has happened on minimised cloud images), surface a clear breadcrumb so an operator notices BEFORE CVEs pile up.

### zot install binary and activation

zot install (binary fetch + systemd activation) ZOT_VERSION is pinned for reproducibility. To bump: read https://github.com/project-zot/zot/releases, verify the asset names still match `zot-linux-{amd64,arm64}` (NOT `-minimal` -- the sync extension is required for on-demand pull-through caching), then change ZOT_VERSION here. The binary download goes DIRECT to GitHub (not through this VM's own squid -- chicken-and-egg) and is a one-shot per VM build, so the ~220 MB transfer doesn't recur.

### Ready banner YAML mapping trap

Single-quoted: the bare `: ` after "ready" makes YAML parse the scalar as a mapping; shellify() gets a dict instead of a string and aborts the ENTIRE runcmd phase (CA gen, ssl_db init, prewarm, squid-exporter, monitoring -- none run). Silent in systemctl output because write_files still ran; only `cloud-init status --long` surfaces the TypeError.

---

## Maintenance notes

- New topic: add a `### <topic name>` section here, then in the user-data emit a
  single `# --- REGION: https://yuruna.link/vmconfig/caching-proxy#<topic-slug>` at
  the matching indent. Pick heading text whose GitHub slug is readable -- avoid
  `:`, `(`, `)`, `/`, `=` and other punctuation the slugifier strips silently.
- Removed topic: drop the section here AND the one-line pointer in the
  user-data. `grep -rn "vmconfig/caching-proxy#<slug>" host/vmconfig/` finds it.
- Comments inside deployed artifacts (squid.conf, embedded scripts, systemd
  units) intentionally stay in the user-data; document subsystem-level rationale
  here and leave the line-level "why" beside the code it ships with.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.21

Back to [Yuruna](../README.md)
