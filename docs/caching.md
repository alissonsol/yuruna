# Caching

Two independent layers that compose: keeping `YurunaCacheContent` unset
lets the Squid VM serve cached copies of install scripts.

1. **[`YurunaCacheContent`](#the-yurunacachecontent-cache-buster)** —
   env var controlling cache-busting of `irm`/`wget`/`curl` one-liners.
2. **[Squid cache VM](#squid-cache-vm)** — optional VM that caches
   HTTP/HTTPS for test VMs. First install populates; subsequent installs
   pull from LAN.

## The `YurunaCacheContent` cache-buster

Every Yuruna one-liner appends `?nocache=<value>` when `YurunaCacheContent`
is set. Unset → cacheable URL (intermediate proxies can serve stored
copies). Set to any unique string (typically a datetime) → fresh fetch.

Exception: the bootstrap installers in
[install/README.md](../install/README.md) cache-bust unconditionally via
`?nocache=$(Get-Date -Format yyyyMMddHHmmss)` (PowerShell) or
`?nocache=$(date +%Y%m%d%H%M%S)` (bash). The bootstrap is a one-shot per
fresh host, and a stale cached installer is the worst kind of stale —
the operator can't tell and re-running from the README is the
documented recovery path. `YurunaCacheContent` is ignored there.

```
# Windows PowerShell — current session:
$env:YurunaCacheContent = (Get-Date -Format yyyyMMddHHmmss)
# Persist for the user (open a new shell):
setx YurunaCacheContent (Get-Date -Format yyyyMMddHHmmss)
# Clear:
Remove-Item Env:YurunaCacheContent        # current session
setx YurunaCacheContent ""                # persisted
```

```
# macOS / Linux — current session:
export YurunaCacheContent="$(date +%Y%m%d%H%M%S)"
# Persist: add the line to ~/.zshrc or ~/.bash_profile.
unset YurunaCacheContent                  # clear
```

Read by: guest README `irm … | iex` one-liners,
[`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh),
and `wget`/`curl` calls in each `guest/<name>/` install script.
`fetch-and-execute.sh` also honors an explicit `EXEC_QUERY_PARAMS`
override (used verbatim, takes precedence).

The variable is read by whichever shell expands the URL — it is **not**
auto-pushed into guest VMs. Set it again inside the guest to cache-bust
guest install scripts.

---

## Squid cache VM

Optional local HTTP/HTTPS caching proxy packaged as a standalone VM.
Works identically on Windows Hyper-V, macOS UTM, and Ubuntu KVM/libvirt.

### What it does

Ubuntu Server VM (12 GB RAM with 7 GB `cache_mem`, 4 vCPU, 512 GB disk
with a 384 GB `cache_dir`) on `:3128`, transparently caching every
cacheable response (`.deb` packages, ISO metadata, firmware blobs,
anything fetched over plain HTTP). First install populates; subsequent
installs hit LAN speed. This is a *dedicated* VM — the memory budget
is sized around squid's hot-object LRU plus the zot OCI registry
pull-through cache; the full breakdown is in
[Cache VM sizing](#cache-vm-sizing).

### Why Squid over apt-cacher-ng

- **Caches more.** apt-cacher-ng recognized only apt-shaped URLs, so
  subiquity's in-install `apt-get install linux-firmware` bypassed it
  and kept hitting `security.ubuntu.com`'s 429 rate limit.
- **Tunnels HTTPS by default** (`:3128` CONNECT) and **caches HTTPS**
  via an SSL-bump listener on `:3129` (see [HTTPS caching](#https-caching)).
  apt-cacher-ng refused CONNECT.

Rate-limiting bites macOS faster: Apple Virtualization's Shared NAT
egresses every UTM VM through the host's single public IP.

## Setup

### Windows Hyper-V

From an elevated PowerShell (one-time):

```
cd $HOME\git\yuruna\host\windows.hyper-v\guest.caching-proxy
pwsh .\Get-Image.ps1
pwsh .\New-VM.ps1
```

- [Get-Image.ps1](../host/windows.hyper-v/guest.caching-proxy/Get-Image.ps1)
  downloads Ubuntu Server Resolute (amd64), converts qcow2→VHDX via
  `qemu-img`, resizes to 512 GB.
- [New-VM.ps1](../host/windows.hyper-v/guest.caching-proxy/New-VM.ps1)
  creates Gen 2 VM `yuruna-caching-proxy` on the Yuruna-External vSwitch
  (falling back to the Default Switch when no LAN-routable NIC is
  available), attaches a cloud-init seed ISO that installs and configures
  squid, and waits until port 3128 responds. Prints the proxy URL on ready.

### macOS UTM

```
cd ~/git/yuruna/host/macos.utm/guest.caching-proxy
pwsh ./Get-Image.ps1
pwsh ./New-VM.ps1
```

- [Get-Image.ps1](../host/macos.utm/guest.caching-proxy/Get-Image.ps1)
  downloads arm64 qcow2, keeps it qcow2 (a raw disk trips the macOS
  F_PUNCHHOLE sparse-clone path), resizes to 512 GB.
- [New-VM.ps1](../host/macos.utm/guest.caching-proxy/New-VM.ps1)
  assembles `~/yuruna/guest.nosync/yuruna-caching-proxy.utm/`
  with `config.plist` (QEMU backend),
  `Data/disk.qcow2` (APFS-clone of the qcow2 image),
  `Data/seed.iso` (cloud-init via `hdiutil`). Double-click the `.utm` to
  register it with UTM, then start.

### Ubuntu KVM/libvirt

```
cd ~/git/yuruna/host/ubuntu.kvm/guest.caching-proxy
pwsh ./Get-Image.ps1
pwsh ./New-VM.ps1
```

- [Get-Image.ps1](../host/ubuntu.kvm/guest.caching-proxy/Get-Image.ps1)
  downloads the Ubuntu Server Resolute cloud image native to the host's
  architecture (amd64 or arm64), keeps qcow2 (libvirt-qemu boots it
  natively — no conversion), resizes to 512 GB sparse.
- [New-VM.ps1](../host/ubuntu.kvm/guest.caching-proxy/New-VM.ps1)
  copies the base image into `$HOME/yuruna/vms/yuruna-caching-proxy/`,
  generates a NoCloud seed ISO with `genisoimage`, then runs
  `virt-install --import` against either the bridged `yuruna-external`
  libvirt network (LAN-routable IP — preferred) or the NAT `default`
  network (host-only fallback). Waits for the VM to obtain an IP and
  for squid to listen on `:3128`. Prints the proxy URL on ready.

The bridged `yuruna-external` network is auto-provisioned by
`test/Start-CachingProxyVM.ps1` on first run; see
[Squid Cache ...](../host/ubuntu.kvm/guest.caching-proxy/README.md)
for manual bridge setup and rollback.

### Finding the cache VM's IP

| Host | Method |
|------|--------|
| **Hyper-V** | `Get-VM yuruna-caching-proxy \| Get-VMNetworkAdapter`, or reuse the IP `New-VM.ps1` printed. |
| **UTM** | (a) read `eth0: <ip>` at the console login; (b) `awk -F'[ =]' '/name=yuruna-caching-proxy/{f=1} f && /ip_address/{print $NF; exit}' /var/db/dhcpd_leases`; (c) port-scan 192.168.64.2-30 for `:3128`. `utmctl ip-address` does **not** work for Apple Virtualization-backed VMs. |
| **KVM/libvirt** | `virsh -c qemu:///system domifaddr --source agent yuruna-caching-proxy` (preferred, requires qemu-guest-agent which the cloud-init user-data installs); falls back to `--source lease` for the NAT `default` network and `--source arp` for bridged networks. `Get-VMIp` in `host/ubuntu.kvm/modules/Yuruna.Host.psm1` runs the same source-of-sources lookup with loopback/link-local filtering. |

### Pre-warm on first boot

After squid starts, cloud-init points the VM's own apt at
`http://127.0.0.1:3128` and runs `apt-get install --download-only --reinstall`
for `linux-firmware`, the HWE kernel meta, and (amd64 only)
`intel-microcode`, `amd64-microcode`, `firmware-sof-signed`. Without
this, the *first* guest install still races the 429 rate limiter for
`linux-firmware` (~330 MB).

Expect **5–15 min** for first-boot prewarm. Cloud-init then flips squid
into [offline_mode](#offline_mode).

## How guests use it

At seed-ISO creation time, each guest's `New-VM.ps1` discovers the cache
and writes its URL into autoinstall `apt.proxy` plus a persistent apt
proxy dropin inside the installed target. Subiquity, cloud-init's
first-boot `openssh-server` install, and every subsequent `apt-get` flow
through the cache.

### Discovery

| Host | Method |
|------|--------|
| **Hyper-V** | `Get-VM yuruna-caching-proxy` → IP via ARP on Default Switch (matched by MAC) or KVP, then TCP-probe `:3128`. |
| **UTM** | `utmctl status yuruna-caching-proxy` → if `started`, subnet-probe 192.168.64.2-30. Fallback subnet probe runs even without `utmctl`. |
| **KVM/libvirt** | `virsh domifaddr --source agent\|lease\|arp` cascade (see `Get-VMIp` in `host/ubuntu.kvm/modules/Yuruna.Host.psm1`), filtering loopback and link-local. The cache VM's IP is then persisted under `test/status/runtime/yuruna-caching-proxy.yml` for fast-path lookup on subsequent calls. |

### Severity policy

Silent fallback-to-CDN can't mask a 429:

- **No cache VM registered / not running** → **WARNING**, proceed against CDN.
- **Cache VM running but `:3128` unreachable** → **ERROR**, exit 1.

See the [test-harness operator reference](#caching-proxy--test-harness-operator-reference)
below for the wrappers that expose the cache and preflight it.

## Cache configuration

Squid is tuned as a **replayable snapshot**: once an object lands, it
stays; the cache keeps serving when origin is unreachable. Fully
populated = guest installs with zero internet.

Config lives in the shared
[`host/vmconfig/caching-proxy.base.user-data`](../host/vmconfig/caching-proxy.base.user-data)
plus the per-host `caching-proxy.{hyperv,kvm,utm}.overlay.yml` (the overlay
swaps only the arch-specific package list; New-VM merges them via
`New-CloudInitUserData`).

### Never release unless needed

- `cache_swap_high 99` / `cache_swap_low 98` — eviction only above 99%;
  stop at 98%. Default 90/95 would release ~5 GB early.
- `cache_replacement_policy heap LFUDA` +
  `memory_replacement_policy heap GDSF` — eviction retains large,
  frequently-used blobs (linux-firmware, kernels); drops rare small ones.
- `quick_abort_min -1 KB` — finish fetches even when the client
  disconnects, so the next client gets a cache hit.

### Serve stale, never serve failures

- `negative_ttl 0 seconds` — do not cache 4xx/5xx. A transient blip
  mustn't poison a 504 for an object squid could otherwise fetch.
- Aggressive `refresh_pattern` for content-addressable files
  (`.deb .udeb .tar.xz .tar.gz .tar.bz2 .iso`):
  `override-expire override-lastmod ignore-reload ignore-no-store
  ignore-private`. Apt metadata uses a shorter
  TTL so apt still sees fresh package lists.

### OpenTofu provider + binary caching

The squid drop-in pins year-long TTLs on four OpenTofu-adjacent
hostnames so a single warmup makes every subsequent `tofu init` and
every `tofu` binary install survive upstream blips:

| Host                         | What it serves                                              |
|------------------------------|-------------------------------------------------------------|
| `registry.opentofu.org`      | `/v1/providers/.../<ver>/download/...` JSON metadata        |
| `releases.opentofu.org`      | First-party (`hashicorp/*`) provider artifacts              |
| `packages.opentofu.org`      | Apt repo for the `tofu` binary (`/opentofu/tofu/any/...`)   |
| `get.opentofu.org`           | `opentofu.gpg` + `install-opentofu.sh`                      |

Every path served by those hostnames is content-addressed by version
(provider zips are immutable per release; `.deb` files include the
version in the URL), so a long-TTL `refresh_pattern` with
`override-expire override-lastmod ignore-reload ignore-no-store
ignore-private` is safe — there is no observable downside to caching
forever.

Apt repository indexes under `packages.opentofu.org/.../dists/` would
otherwise be frozen by the host-level pattern, but the
`/InRelease|/Release|/Release.gpg|/Packages*` short-TTL
`refresh_pattern` entries declared earlier in `yuruna.conf` match
first and keep apt metadata fresh. A second class of provider zips
lives on the GitHub release CDN (`github.com/.../releases/download/`
→ 302 → `objects.githubusercontent.com/...`); both endpoints get the
same year-long TTL via their own dedicated `refresh_pattern` entries.

Guests reach these endpoints through the SSL-bumped `:3129` listener
(see [HTTPS caching](#https-caching)): cloud-init exports
`https_proxy=http://<cache>:3129/` system-wide, so `curl`,
`apt-get update`, and `tofu init` all flow through squid and pick up
cached responses without the install scripts having to know about
the proxy.

Source: the `refresh_pattern` block in
[`host/vmconfig/caching-proxy.base.user-data`](../host/vmconfig/caching-proxy.base.user-data).

### offline_mode

After prewarm, cloud-init writes `/etc/squid/conf.d/yuruna-offline.conf`
(`offline_mode on`) and runs `squid -k reconfigure`. From then on: cache
hit → disk; cache miss → `504`. This enables the fully-disconnected
workflow and points clearly at the missing URL on a miss. The flip
happens **after** prewarm because empty cache + `offline_mode` = 504 on
every request.

### Refreshing the cache

Temporary — serve from origin for one burst, then offline again:

```
ssh caching-proxy-admin@<caching-proxy-ip>
sudo rm /etc/squid/conf.d/yuruna-offline.conf && sudo squid -k reconfigure
# ... apt-get update etc. ...
echo "offline_mode on" | sudo tee /etc/squid/conf.d/yuruna-offline.conf
sudo squid -k reconfigure
```

Full rebuild:

```
# Windows Hyper-V:
Stop-VM yuruna-caching-proxy -Force; Remove-VM yuruna-caching-proxy -Force
Remove-Item -Recurse "<HyperVVHDPath>\yuruna-caching-proxy"
pwsh .\New-VM.ps1
```

```
# macOS UTM:
utmctl stop yuruna-caching-proxy
rm -rf ~/yuruna/guest.nosync/yuruna-caching-proxy.utm
pwsh ./New-VM.ps1
```

## Workload registry pulls

### Workload registry pull-through

The example workload scripts start a local Docker registry by pulling
`registry:2` (Docker Hub canonical, i.e. `docker.io/library/registry:2`).
Dockerd's `registry-mirrors` in `/etc/docker/daemon.json` (set by
`guest/<GUEST>/<GUEST>.k8s.sh` at provision time) routes this through the
yuruna-caching-proxy's zot pull-through cache — zot serves the manifest
from cache with stale-on-error semantics, so upstream rate-limit blips
don't break the test. Pinning `public.ecr.aws/docker/library/registry:2`
to dodge Docker Hub's anonymous limit is unreliable — that mirror has
itself returned 400 across multiple test hosts simultaneously; the zot
pull-through is the durable fix.

Transient egress blips surface here as `network is unreachable`,
connection resets, or DNS hiccups while pulling `registry:2` — e.g. a
host-side DHCP re-lease that momentarily blackholes the guest's NAT
route, or TLS jitter to the cache. These are not rate limits and clear
within seconds, so the scripts retry with backoff (mirroring the
`docker build` retry) instead of aborting the whole run under
`set -euo pipefail`. Each attempt is also stall-bounded with
`timeout --foreground`, so a wedged pull surfaces as a retriable
failure instead of hanging the script.

### Workload registry local-first

`docker build` resolves every `FROM` tag inside a single invocation
(buildkit's `load metadata` step). When that resolution targets a
remote registry, a wedged endpoint hangs the build mid-command, where
no retry loop can reach it. The workload scripts therefore never build
against a remote registry:

1. Every base image the Dockerfile needs is looked up in the guest's
   local docker store first (matched by `repo:tag` under any registry
   prefix). Only when missing is it pulled into the store, trying
   `${CACHE_HOST}:5000/` (zot pull-through cache — LAN-fast, absorbs
   MCR TLS jitter) and then `mcr.microsoft.com/` — the survival path
   when the cache VM is absent, unreachable, or unable to serve the
   tag. Each candidate is gated by a cheap manifest GET
   (`curl --max-time 30`) first, so a wedged registry is skipped in
   seconds rather than consuming a pull window — and on zot that GET
   also triggers the onDemand sync ahead of the pull. The pull itself
   is stall-bounded (`timeout --foreground`, default 300 s,
   overridable via `YURUNA_PULL_STALL_TIMEOUT` for slow links) as a
   backstop against mid-stream wedges, and a candidate that stalls
   mid-pull is dropped for the remainder of the run — a mid-stream
   wedge is not a blip, so retrying it would burn another full bound
   with no better odds.
2. The images are tagged and pushed into the guest-local
   `localhost:5000` distribution registry — the same `registry:2`
   container the built app image is pushed to.
3. The build runs with `--build-arg REGISTRY=localhost:5000/`, so
   `FROM` metadata and base layers resolve over loopback only, with no
   network dependency.

The localhost `components.yml` `buildCommand` passes the same
`REGISTRY=<registryLocation>/` build-arg, and each component's
`seed-base-images.ps1` pre-processor re-seeds idempotently (a manifest
already served by the local registry is a no-op), so the
`Set-Component` rebuild is loopback-only in every flow — guest test
runs, book chapters, or a dev machine — not just when a workload
script seeded first. On a machine where the base images were never
pulled, that seed step is the single place that still touches a
registry over the network, with the same cache-first source order.
(The Dockerfiles' `RUN` package restores remain a separate, per-build
network dependency.)

## Monitoring

The VM runs these services alongside squid:

| Service         | Port | Binding                  | Purpose |
|-----------------|------|--------------------------|---------|
| Grafana OSS     | 3000 | 0.0.0.0                  | Primary dashboard UI; anonymous Viewer. |
| Prometheus      | 9090 | 127.0.0.1                | Metrics datastore. |
| Loki            | 3100 | 127.0.0.1                | Log datastore — backs the access-log panel. |
| Promtail        | 9080 | 127.0.0.1                | Tails `/var/log/squid/yuruna_access.log` into Loki. |
| squid-exporter  | 9301 | 127.0.0.1                | Reads squid cachemgr over `:3128`. |
| CA cert         | 80   | 0.0.0.0                  | `/yuruna-squid-ca.crt` via Apache. |
| Squid HTTP      | 3128 | 0.0.0.0, RFC1918         | Plain HTTP + HTTPS CONNECT. |
| Squid HTTPS     | 3129 | 0.0.0.0, RFC1918         | SSL-bump — caches HTTPS bodies. |

**Grafana (primary UI)** — `http://<caching-proxy-vm-ip>:3000`. Anonymous
Viewer. Pre-provisioned "Yuruna caching proxy" dashboard:

- Client HTTP(S) data served (kB/s): total vs cached — Total:
  `rate(squid_client_http_kbytes_out_kbytes_total[5m])`,
  Cached: `rate(squid_client_http_hit_kbytes_out_bytes_total[5m])`.
- Served / From cache (7 days, 24 hours) — four stat panels driven by
  `increase(squid_client_http_kbytes_out_kbytes_total[…]) * 1024` and
  `increase(squid_client_http_hit_kbytes_out_bytes_total[…]) * 1024`.
- Internet connectivity / Offline mode support — `squid_internet_reachable`
  and `squid_offline_mode_configured` from `squid-meta-exporter.sh`.
- Cached (Mem) / Cached (Disk) — current cached content ready to be served:
  `squid_info_Storage_Mem_size * 1024` (in-memory) and
  `squid_info_Storage_Swap_size * 1024` (on-disk).
- Recent 100 requests (client IP / status / size / method / URL / User-Agent) — Loki
  logs panel parses `/var/log/squid/yuruna_access.log` at query time.
  Size uses `%<st`; User-Agent from `%{User-Agent}>h`. The custom
  `logformat yuruna` writes to a *separate* file — the stock `access.log`
  keeps its default format for cachemgr.cgi / manual `tail -f`. Empty
  until Promtail ships its first line. Cardinality stays bounded: only
  `job=squid` is a stream label.

No HTTPS-specific client counter — squid's `client_http.*` counters
aggregate HTTP + HTTPS (CONNECT + ssl-bump), hence "HTTP(S)".
boynux/squid-exporter mixes unit suffixes: Total uses `_kbytes_total`,
Cached uses `_bytes_total` (both are kbytes). Verify with
`curl -s http://127.0.0.1:9301/metrics | grep hit_kbytes_out`.

Edit dashboards with `admin`/`admin` (unrotated; VM is on private
switch). Datasource UIDs: `yuruna-prometheus`, `yuruna-loki`. Grafana
is the OSS build from `apt.grafana.com stable main`.

**Prometheus** — loopback-only. SSH in then
`curl 'http://127.0.0.1:9090/api/v1/query?query=up'`, or use Grafana
Explore. Scrapes `:9090` and `:9301` every 15 s.

**Loki + Promtail** — loopback-only, same repo. Promtail tails
`/var/log/squid/yuruna_access.log` (squid's custom `logformat yuruna`
stream) and ships every line to Loki on
`127.0.0.1:3100` with the single stream label `job=squid`. Retention
capped at 7d. Verify with
`curl -G 'http://127.0.0.1:3100/loki/api/v1/query_range' --data-urlencode 'query={job="squid"}' --data-urlencode 'limit=5'`.

**squid-exporter** — [boynux/squid-exporter](https://github.com/boynux/squid-exporter)
speaks squid's cache-manager protocol on `localhost:3128`. Built from
source during cloud-init (`go install`); `golang-go` is purged once
the static binary lands in `/usr/local/bin/squid-exporter`.

### Loki + Promtail boot-order traps

`runcmd` brings Loki and Promtail up explicitly (not just relying on
the debs' enable-by-default postinst). Three traps to respect:

- **Restart after the `proxy` group exists.** The Promtail drop-in
  declares `SupplementaryGroups=proxy` so it can read
  `/var/log/squid/access.log` (which squid writes mode 0640
  `proxy:adm`). The `proxy` group lands with `squid-openssl`; if
  Promtail was started by deb-postinst before squid landed, it
  caches the old unit and logs `permission denied` on every poll
  forever. Solution: `daemon-reload` + explicit `restart` after
  packages settle.
- **Pre-create per-service state dirs.** Neither postinst reliably
  creates `/var/lib/promtail` (positions file) or `/var/lib/loki`
  (Loki's `path_prefix`). Loki crashes with
  `mkdir /var/lib/loki: permission denied` because `/var/lib` is
  `root:root` and the `loki` user can't create top-level entries.
  systemd retries 19× then gives up with "Start request repeated
  too quickly"; Promtail then silently retries `POST
  /loki/api/v1/push` forever and the Grafana panel stays empty.
  `runcmd` runs `install -d -o promtail` / `install -d -o loki`
  and `systemctl reset-failed` to clear the rate-limit.
- **Create the `zot` user BEFORE Promtail starts.** Promtail's
  drop-in lists `SupplementaryGroups=proxy zot`; on modern systemd a
  missing group either silently drops the entry (OCI "Recent 100"
  panel stays empty even once zot starts logging) or the unit fails
  to start (which also takes down the squid "Recent 100" panel
  because nothing tails `yuruna_access.log`). The zot binary
  install later in `runcmd` would create the user — but Promtail is
  already enabled by then. Idempotent
  `id zot >/dev/null 2>&1 || useradd ...` up front.

## Zot OCI registry

Squid catches digest-pinned blob / manifest URLs (immutable,
content-addressable) but **cannot** cache the tag-pointer freshness
check (`HEAD /v2/<image>/manifests/<tag>`) — that's a revalidation
against upstream by definition. AWS ECR Public's anonymous quota
and Docker Hub's anonymous-pull limits both bite on those HEADs.

`zot` is OCI-protocol-aware and serves the manifest cache with a
TTL + stale-on-error — the behavior that masks the
"`registry:2` returns 400 from `public.ecr.aws`" class of incident
that has taken out multiple test hosts simultaneously.

Guests reach `zot` at `http://<cache-vm>:5000` and configure
`dockerd` with `registry-mirrors` (set by
`guest/ubuntu.server.24/ubuntu.server.24.k8s.sh` at provision
time). Plain HTTP (no TLS) — intra-LAN, same trust boundary as the
SSL-bump CA the guests already trust. The `zot` binary is fetched
from GitHub releases by `runcmd`.

### mcr.microsoft.com appears twice

In the zot `registries[]` block, `mcr.microsoft.com` is declared
twice:

1. `onDemand: true` + `prefix: **` — catch-all for any future MCR
   image.
2. `pollInterval: 6h` + tagged content for `dotnet/sdk:10.0` and
   `dotnet/aspnet:10.0` — first on-demand sync of `dotnet/sdk:10.0`
   takes ~30 s end-to-end (skopeo walks the index, per-arch
   manifests, config blobs, disk commit) and trips the workload
   acquisition gate running `curl --max-time 30` right at the
   boundary. The scheduled pre-warm keeps the two manifests
   resident so the gate returns in 0 ms and the subsequent pull
   starts streaming immediately.

## macOS UTM platform notes

Apple Virtualization Framework (AVF) and UTM Shared NAT introduce
several traps that the cache-VM `user-data` accounts for. They only
fire on `host/macos.utm/`; the same image on Hyper-V or KVM doesn't
need any of this.

### Disable NIC TX offloads on AVF bridge

`/etc/systemd/network/10-yuruna-no-offload.link` switches off TSO,
GSO, GRO, and TX-checksum offload on every `virtio_net` interface.
Without it, the cache VM tops out at **~360 KB/s** (cwnd collapsed to
1–2 segments) instead of the line-rate **~941 Mbps** measured with
offloads off. iperf3 from a remote LAN host confirmed the ~120×
gain.

Mechanism: with offloads on, the guest defers segmentation and
checksumming to "the NIC", but AVF's bridge path forwards onto the
host's `en0` without performing those deferred ops — remote
receivers see invalid checksums / oversized segments, drop them,
and cubic collapses cwnd.

Two layers, both required:

- **systemd `.link` drop-in** (write-files) applies at udev rename
  time on every subsequent boot, **before** the NIC is brought up.
- **`ethtool -K enp0s1 tx off gso off tso off gro off`** (runcmd,
  first line) applies the change on **this** boot. cloud-init
  write-files runs after `enp0s1` is already up and DHCP'd, so
  udev has already processed the interface without the `.link` in
  place. Without the runcmd step, the very first apt fetches
  through the proxy crawl until reboot.

The Hyper-V build of the same `user-data` does **not** include
either step — the Hyper-V virtual NIC handles offloads correctly in
kernel.

### UTM Shared NAT topology

UTM's Shared mode hands out `192.168.64.0/24` with a gateway of
`192.168.64.1` (the host). Three consequences in the squid config:

- **RFC1918 ACL covers all three blocks** (`10/8`, `172.16/12`,
  `192.168/16`) so the same `yuruna.conf` is reusable across
  alternate network modes — only the `192.168/16` entry actually
  matches on UTM.
- **`macos-host` `/etc/hosts` alias.** `runcmd` discovers the
  gateway dynamically via `ip -4 route show default` and appends
  `<gw> macos-host` so squid access-log triage is readable without
  hardcoding a subnet that could change.
- **All UTM VMs egress through the host's single public IP.** That
  amplifies upstream rate-limiting (`security.ubuntu.com` 429s bite
  faster than on Hyper-V where every VM may NAT through its own
  source) — one of the reasons squid's broader caching matters most
  on this platform.

### Cache-VM disk sizing for the macOS install image

`maximum_object_size 65 GB` is sized so the cache covers **every**
install image yuruna currently provisions, including the macOS
install image (~18 GB) and headroom for a 64 GB worst case
(Xcode-bundled SDKs, full Windows Server install media, full-fat
dev VM templates). Squid's `maximum_object_size` is **inclusive** —
anything strictly larger is silently not cached, so the 1 GB
headroom on top of 64 GB matters. Raising the value does not
allocate disk on its own; it only changes the rejection threshold.

### CA cert published over Apache without ACL

The `runcmd` step
`install -m 0644 /etc/squid/ssl_cert/ca.pem /var/www/html/yuruna-squid-ca.crt`
publishes the SSL-bump CA at `http://<cache>/yuruna-squid-ca.crt`
intentionally **world-readable**. RFC1918 reachability is enforced
at the UTM Shared NAT network layer, not by Apache. Only the public
cert is copied; `ca.key` stays inside `/etc/squid/ssl_cert/` with
mode `600 proxy:proxy`.

**cachemgr (CLI only)** — the `squid-cgi` (`cachemgr.cgi`) web UI was
dropped in Ubuntu 26.04 / Squid 7, so cache-manager data is read with
`squidclient mgr:<page>` on the VM instead (`info`, `utilization`,
`storedir`, `mem`, `client_list`, `objects`). Squid's `manager` ACL
allows only `localhost`.

**CLI** inside the VM:

```
sudo squidclient mgr:info | mgr:utilization | mgr:5min
sudo tail -f /var/log/squid/access.log   # 3rd-to-last field: TCP_HIT/MISS/OFFLINE_HIT
```

### Purging a single cached entry

The `yuruna.conf` dropin enables the `PURGE` method for RFC1918:

```
# Inside the cache VM:
sudo squidclient -m PURGE http://<origin>:<port>/<path>

# From any RFC1918 workstation:
curl -x http://<cache-vm-ip>:3128 -X PURGE http://<origin>:<port>/<path>
```

`200` = purged; `404` = wasn't cached (safe no-op). For total wipes:
stop squid, `rm -rf /var/spool/squid/*`, `squid -z`.

## Access / credentials

Cloud-init creates a single `yuruna` debug user (replaces the cloud
image's default `ubuntu` — `users:` without a `- default` entry
suppresses ubuntu creation):

- **Password** — managed by the authentication extension
  (code at
  [`test/extension/authentication/`](../test/extension/authentication/);
  per-cycle vault.yml at
  `test/status/extension/authentication/vault.yml`). Cross-cycle
  persistence lives in `test/status/runtime/yuruna-caching-proxy.yml`
  (host-agnostic), kept aligned with the vault as described in
  [Cache-VM password persistence](#cache-vm-password-persistence).
  Printed in the ready banner; baked into the seed via
  `chpasswd`. Expiry disabled. The first-ever rebuild on a host
  generates a fresh 10-char alphanumeric password; subsequent rebuilds
  preserve it.
- **SSH key** — harness public key from `test/status/ssh/yuruna_ed25519` via
  [Test.Ssh.psm1](../test/modules/Test.Ssh.psm1). `ssh caching-proxy-admin@<ip>` is
  passwordless from the host.
- **Sudo** — passwordless (`NOPASSWD:ALL`). VM is on a private switch,
  RFC1918-only.

### Reaching the cache from outside the host (port 8022)

`Start-CachingProxyVM.ps1` adds an `8022 -> 22` host port forward
alongside the squid/Grafana ones:

```
ssh -p 8022 caching-proxy-admin@<host-lan-ip>     # -> cache VM :22
```

Port 8022 (not 22) avoids colliding with the host's own sshd. Managed
the same way as :80 / :3000 — netsh portproxy + Yuruna firewall rule on
Windows, detached pwsh TcpListener on macOS — re-applied by every caller
of `Add-PortMap` (test runner, status server, repair script).

### Real client IPs in the access log: PROXY protocol on :3128 / :3129

Plain TCP forwarding NATs the source IP — every connection through the
host shows the host's NAT-side IP (e.g. `172.24.208.1` on Hyper-V
Default Switch), obscuring which LAN client made each request.

Squid's `require-proxy-header` http_port option (Squid 6 / Noble
spelling; older docs say `accept-proxy-protocol`) parses a HAProxy PROXY
v1 line — `PROXY TCP4 <client_ip> <bind_ip> <client_port> <bind_port>\r\n`
prepended by the forwarder — and uses the supplied client IP for ACLs
and the access log.

Both platforms preserve source IP, but via different plumbing forced by
what each host's network stack allows.

##### macOS: pwsh forwarder + PROXY v1

Apple VZ shared-NAT isolates guest↔guest traffic on `192.168.64.0/24`,
so LAN clients can't reach the cache VM directly. The Mac host runs
[`Start-CachingProxyForwarder.ps1`](../host/macos.utm/Start-CachingProxyForwarder.ps1)
on `0.0.0.0:3128` / `:3129`, accepts each LAN client's TCP connection,
opens an upstream connection to the cache VM's `:3138` / `:3139` (Squid
binds with `require-proxy-header`), prepends the PROXY v1 line, and
bridges bytes. Squid logs the supplied client IP.

##### Windows: External vSwitch (bridged cache VM)

On Hyper-V the userspace pwsh forwarder is **silently dropped on
inbound LAN traffic**, even with port-scope and per-program Defender
Allow rules — confirmed by remote probing and re-probing from the cache
VM through the Default-Switch NAT. The filter sits below
`New-NetFirewallRule`'s reach (per-process Defender on Public profile,
EDR / corporate-policy overlays, or a Hyper-V WFP module — none reliably
overridable from PowerShell). Kernel-mode netsh portproxy bypasses the
filter (which is why 80/3000/8022 work), but netsh has no PROXY-protocol
mode and rewrites the source IP at the kernel NAT.

The fix is to **bypass the host's forwarder layer entirely**: bridge the
cache VM to LAN with a Hyper-V External vSwitch.
[`host/windows.hyper-v/modules/Yuruna.Host.psm1`](../host/windows.hyper-v/modules/Yuruna.Host.psm1)
exposes `Get-OrCreateYurunaExternalSwitch`, which idempotently creates
`Yuruna-External` bound to the host's primary physical NIC (default
IPv4 route, `-AllowManagementOS:$true` so the host keeps its own
network);
[`guest.caching-proxy/New-VM.ps1`](../host/windows.hyper-v/guest.caching-proxy/New-VM.ps1)
calls it on every provision and falls back to `Default Switch` if no
LAN-routed NIC is available. The cache VM then gets a real LAN IP via
DHCP; remote clients hit `<cache-lan-ip>:3128` directly — squid sees
real client IPs at TCP level, no PROXY protocol needed.

Constraints: a PCI-attached wired NIC works best. Two uplink classes
can't carry a bridged guest MAC — Wi-Fi APs typically refuse frames for
MACs they didn't authenticate, and USB Ethernet adapters lack the
promiscuous/MAC-spoofing support Hyper-V bridging needs — so on such an
uplink DHCP fails and the guest boots with eth0 DOWN; the helper
(`Test-WindowsUplinkNotBridgeable`) warns and diverts to the Default
Switch. The cache VM is on the LAN broadcast domain —
squid's RFC1918 ACL still gates proxy use, but anyone on the LAN can
TCP-connect. Removing the bridge requires explicit
`Remove-VMSwitch -Name 'Yuruna-External'` (no auto-clean — other VMs
may share the switch).

The wiring (per platform):

| Endpoint       | Host port | macOS VM | Windows VM | macOS forwarder  | Windows forwarder        | Notes                                                  |
|----------------|-----------|----------|------------|------------------|--------------------------|--------------------------------------------------------|
| Squid HTTP     | 3128      | 3138     | n/a        | pwsh + PROXY v1  | direct (External vSwitch) | macOS: `http_port 3138 require-proxy-header`           |
| Squid SSL-bump | 3129      | 3139     | n/a        | pwsh + PROXY v1  | direct (External vSwitch) | macOS: `http_port 3139 require-proxy-header ssl-bump`  |
| Apache CA cert | 80        | 80       | n/a        | pwsh (sudo bind) | direct (External vSwitch) | static file — source IP not relevant                   |
| Grafana        | 3000      | 3000     | n/a        | pwsh             | direct (External vSwitch) | dashboard UI                                           |
| SSH            | 8022      | 22       | n/a        | pwsh             | direct (External vSwitch) | sshd has its own client-IP logging                     |

`n/a` for Windows host port: no host-side listener on the
External-vSwitch path. Operators hit Grafana at
`http://<cache-lan-ip>:3000`, the cache at `<cache-lan-ip>:3128`, etc.
`New-VM.ps1` prints the LAN IP on success; `Test-CachingProxy` consumes
it via `$Env:YURUNA_CACHING_PROXY_IP`.

The cache VM keeps both squid listener pairs regardless of platform:
`http_port 3128`/`3129` (no PROXY) for direct LAN clients and bridged
guests, plus `http_port 3138`/`3139 require-proxy-header` for the macOS
PROXY-v1 path.

Local Default-Switch guests on Hyper-V reach the cache via host routing
through the External vSwitch, so they appear at squid as the host's LAN
IP. To get per-guest IP visibility, migrate them to the External
vSwitch.

`proxy_protocol_access` allows PROXY headers from RFC1918 + loopback
only. The macOS host forwarder is on a private network, but the
deny-by-default posture costs nothing.

##### Windows fallback: Default Switch + netsh portproxy

When `Get-OrCreateYurunaExternalSwitch` cannot bridge the uplink (no
LAN-routable NIC, a not-bridgeable uplink — Wi-Fi or a USB Ethernet
adapter — or switch creation skipped), the cache VM lands on the
built-in `Default Switch` and the test/
scripts re-enable netsh portproxy. LAN clients reach `<host-lan-ip>:3128`
and squid logs the host's vEthernet IP — the source-IP-loss gap kept as
a fallback, not a default. `Test-CacheVMOnExternalNetwork` (the
Yuruna.Host contract function, implemented in
[`host/windows.hyper-v/modules/Yuruna.Host.psm1`](../host/windows.hyper-v/modules/Yuruna.Host.psm1)
on top of `Test-CacheVmOnYurunaExternalSwitch` in
[`Yuruna.Host.psm1`](../host/windows.hyper-v/modules/Yuruna.Host.psm1)) is the
runtime detection switch.

##### Windows: App Execution Alias self-heal (latent)

`Add-PortMap` in
[`host/windows.hyper-v/modules/Yuruna.Host.psm1`](../host/windows.hyper-v/modules/Yuruna.Host.psm1)
carries a self-heal for one Windows path-resolution failure mode: after
the userspace forwarder spawns pwsh, it reads
`(Get-Process -Id <pid>).Path` and rewrites the per-program firewall
rule, in case `Get-Command pwsh` returned a Microsoft Store App
Execution Alias stub. Not exercised today (the External-vSwitch path
doesn't use the userspace forwarder on Windows) — kept ready.

Implementation:
* macOS — `-PrependProxyV1` on
  [`Start-CachingProxyForwarder.ps1`](../host/macos.utm/Start-CachingProxyForwarder.ps1),
  wired through `-ProxyProtocolPort` on `Add-PortMap` in
  [`host/macos.utm/modules/Yuruna.Host.psm1`](../host/macos.utm/modules/Yuruna.Host.psm1).
* Windows — `Get-OrCreateYurunaExternalSwitch` and
  `Test-CacheVmOnYurunaExternalSwitch` in
  [`Yuruna.Host.psm1`](../host/windows.hyper-v/modules/Yuruna.Host.psm1)
  (exposed cross-platform via the `New-ExternalNetwork` /
  `Test-CacheVMOnExternalNetwork` contract functions in
  [`Yuruna.Host.psm1`](../host/windows.hyper-v/modules/Yuruna.Host.psm1)),
  consumed by
  [`guest.caching-proxy/New-VM.ps1`](../host/windows.hyper-v/guest.caching-proxy/New-VM.ps1)
  and by the Windows branches of
  [`Start-CachingProxyVM.ps1`](../test/Start-CachingProxyVM.ps1),
  [`Invoke-TestRunner.ps1`](../test/Invoke-TestRunner.ps1), and
  [`Start-StatusService.ps1`](../test/Start-StatusService.ps1).

The console password isn't a secret: squid's `http_access` ACL restricts
proxy use to RFC1918. The VM is most often debugged before cloud-init
finishes (Apache, squid, Grafana, Prometheus all install over apt) —
console fallback via `vmconnect` is the normal path during that window.

## Management

The cache VM is independent of the test harness — **not** created or
destroyed by [Invoke-TestRunner.ps1](../test/Invoke-TestRunner.ps1).

### Windows Hyper-V

- Start/Stop: `Start-VM yuruna-caching-proxy` / `Stop-VM yuruna-caching-proxy`
- Delete: `Stop-VM -Force; Remove-VM -Force`, then delete
  `<HyperVVHDPath>\yuruna-caching-proxy`.
- Auto-start on host boot: `Set-VM yuruna-caching-proxy -AutomaticStartAction Start`

### macOS UTM

- Start/Stop: `utmctl start yuruna-caching-proxy` / `utmctl stop yuruna-caching-proxy`.
- Delete: stop, right-click → Delete in UTM, then
  `rm -rf ~/yuruna/guest.nosync/yuruna-caching-proxy.utm`.

### Both hosts

- Clear cache (wipe objects, keep VM):

```
ssh caching-proxy-admin@<cache-ip>
sudo systemctl stop squid && sudo rm -rf /var/spool/squid/* && sudo squid -z -N
sudo systemctl start squid
```

- Reload config: `sudo squid -k reconfigure` inside the VM.
- Watch hits/misses: `sudo tail -f /var/log/squid/access.log`.

## HTTPS caching

Shipped on Hyper-V, UTM, and Ubuntu KVM. A second squid listener on `:3129`
performs **SSL-bump** — terminates TLS with a locally-generated CA,
caches plaintext bodies through the same `refresh_pattern` and
`offline_mode` pipeline, and re-encrypts with a per-SNI leaf cert minted
on the fly. Guests that trust the CA get cached HTTPS apt traffic; the
rest stays on `:3128` with CONNECT tunneling (no caching).

### Key / cert material

Generated once by cloud-init on first boot (idempotent — re-runs do
**not** rotate the CA, which would orphan trusted guests):

| Path                                 | Contents |
|--------------------------------------|----------|
| `/etc/squid/ssl_cert/ca.key`         | 2048-bit RSA key, `proxy:proxy 600`. VM-local only. |
| `/etc/squid/ssl_cert/ca.pem`         | Self-signed CA (10 years). CN: hostname + UTC timestamp. |
| `/var/lib/squid/ssl_db/`             | `security_file_certgen` DB of per-SNI leaves. |
| `/var/www/html/yuruna-squid-ca.crt`  | Public cert, served by Apache. |

Public cert published at `http://<cache-vm-ip>/yuruna-squid-ca.crt`.
Only the public cert is exposed — `ca.key` never leaves the VM.

### Guest trust flow

Platforms differ because Apple VZ's shared-NAT blocks guest↔guest
traffic — a UTM guest can't reach the cache VM IP directly.

**Hyper-V (in-install wget):** when `New-VM.ps1` injected a proxy, the
`host/vmconfig/ubuntu.server.base.user-data` `late-commands`:

1. Derive cache host from proxy URL (strip `http://` and `:3128`).
2. `wget http://<cache>/yuruna-squid-ca.crt` into
   `/target/usr/local/share/ca-certificates/`.
3. `curtin in-target -- update-ca-certificates`.
4. Append `Acquire::https::Proxy "http://<cache>:3129";` to
   `/target/etc/apt/apt.conf.d/99yuruna-apt-cache`.

Best-effort: if CA fetch fails, the guest keeps HTTP proxy and lets
HTTPS apt go direct.

**UTM (host pre-fetch + base64 in seed):** `guest.ubuntu.*/New-VM.ps1`
reads the cache VM IP from `test/status/runtime/yuruna-caching-proxy.yml`
(written by `Start-CachingProxyVM.ps1` via `Test.CachingProxy.psm1`) or
`$Env:YURUNA_CACHING_PROXY_IP`, fetches the CA, base64-encodes it, and
splices into the seed as `CA_CERT_BASE64_PLACEHOLDER`. Guest
`late-commands`:

1. `printf '%s' "<base64>" | base64 -d > /target/.../yuruna-squid-ca.crt`
2. `curtin in-target -- update-ca-certificates`
3. `Acquire::https::Proxy "http://192.168.64.1:3129";` — the VZ gateway,
   not the cache IP, because the host-side `:3129` forwarder (from
   `Start-CachingProxyVM.ps1`) is the only path guests have.

Empty placeholder → HTTPS apt bypasses the cache.

### Where caching actually kicks in

- **Subiquity in-install HTTPS** (kernel, firmware) — `:3128` CONNECT,
  **not cached**. The CA isn't in subiquity's trust store; only the
  target chroot gets it.
- **Guest first-boot + post-install apt** — HTTPS routes through `:3129`,
  bumped, lands in cache alongside HTTP content.
- **Non-apt HTTPS** (browsers, curl, snap, Go) — untouched.

### ssl_bump rules

Minimum viable: `peek step1` → `bump all`. Squid reads the TLS
ClientHello for SNI, then intercepts. For pin-checking clients (snap,
Go HTTPS), add `acl nobump dstdomain ...` + `ssl_bump splice nobump`
**above** `bump all` rather than disabling bumping. See
`/etc/squid/conf.d/yuruna.conf`.

### Squid 6 parser traps

The yuruna squid drop-in encodes three FATAL-at-parse traps the Noble
package surfaces but the older docs do not:

- **`step1` ACL must be declared explicitly** — Squid does NOT
  auto-define `at_step` ACLs. Without `acl step1 at_step SslBump1`,
  `ssl_bump peek step1` FATALs with `"Bungled ... ssl_bump peek
  step1"` and squid never binds 3128/3129.
- **`dynamic_cert_mem_cache_size` is TOP-LEVEL in Squid 6** (not an
  `http_port` option). Inlining it on the `http_port` line FATALs
  with `"Bungled"`. The default 4 MB is fine; leave it unset.
- **PROXY-protocol option name changed** — Squid 6 spells it
  `require-proxy-header`; the old `accept-proxy-protocol` (Squid 4 /
  older docs) FATALs at parse with
  `"Unknown http_port option 'accept-proxy-protocol'"`. Same
  semantics — every connection on the port MUST start with a PROXY
  v1 (or v2) header. The `:3138` / `:3139` listeners (separate from
  `:3128` / `:3129`) exist precisely because `require-proxy-header`
  is mandatory: local NAT-shared guests that connect without one
  still need `:3128` / `:3129` open.

Always run `squid -k parse` before `squid -k reconfigure` to surface
these at deploy time rather than after a restart that fails to bind.

## Caching proxy — test-harness operator reference

Wrappers around the Squid cache VM: exposing it to remote clients,
pointing a test host at a remote cache, preflighting before a run.
Cache-VM concepts (setup, config, HTTPS/SSL-bump, monitoring,
credentials, `YurunaCacheContent`) are covered in the sections above.

### Why a separate cache VM

Back-to-back test cycles hammer Ubuntu CDN endpoints (the
`archive.ubuntu.com`, `security.ubuntu.com`, GitHub container
registries, k8s artifact mirrors) on every fresh-VM install. Without a
cache between the test guests and the CDN, a typical cycle hits 429
"Too Many Requests" responses within minutes and stretches each
install from ~2 min (warm cache) to ~30 min (live) or fails outright
when an upstream mirror rate-limits the test-lab egress IP. The
caching proxy VM lives on the same host network as the test guests
and serves the same bytes from disk on every cycle; only the cache VM
contacts the CDN, so the test guests stay network-isolated and the
upstream rate limit applies once per cache miss rather than once per
guest install.

### Rebuild, adopt-if-healthy, and the bring-up lock

`Start-CachingProxyVM.ps1` **adopts a healthy proxy by default** instead of
rebuilding it. On each run it probes the existing `yuruna-caching-proxy` VM
(running + squid `:3128` + ssl-bump `:3129` + a valid CA cert); if it is
healthy it skips the ~15-min destroy / image / New-VM / discovery and only
re-asserts the host-side services and port maps. Pass **`-ForceRebuild`** to
force a full destroy+rebuild — do this after a base-image or config change,
since adopt is health-only and does not re-check the image. A half-wedged proxy
(any probe failure) rebuilds automatically.

Bring-up is serialized by a drain-style **PID+StartTime lock**
(`caching-proxy.lock` plus a `.start` sidecar in the runtime dir) so the
destructive VM lifecycle and the host port-map writes cannot interleave — two
concurrent `Start-CachingProxyVM` runs, or a bring-up racing the runner's
per-cycle `Add-PortMap`.

Lock identity mirrors `runner.pid` (`Test.SingleInstance`): a holder counts as
alive only if its PID still exists **and** its recorded process `StartTime`
still matches, so a reused PID cannot impersonate a dead holder. A dead or
mismatched holder is STALE and is reclaimed on the next acquire. Because a
stale lock drains on acquire, a holder that crashes without releasing
self-heals — callers therefore release explicitly on the happy path and rely on
the drain for error exits, exactly the way a crashed runner leaves `runner.pid`
behind for the next run to reclaim.

Two hold profiles share the one lock, distinguished only by their timeout:

| Role | Typical hold | Timeout behavior |
| --- | --- | --- |
| `rebuild` (`Start-CachingProxyVM`) | ~15 min | Bounded wait, long enough to absorb a runner's sub-second port-map hold; a live holder still there past the bound means fail-fast. |
| `portmap` (runner `Add-PortMap`) | ~1 s | Try-once (`TimeoutSeconds 0`). If a rebuild holds the lock, the runner skips this cycle's port-map — the rebuild owns the maps and the cache is down mid-rebuild anyway — and re-applies on the next cycle. |

The adopt-or-rebuild decision itself is a pure function over the proxy VM's
state plus a health probe, wrapped by a thin I/O layer that resolves
`Get-VMState` / `Read-CachingProxyState` / `Invoke-CachingProxyProbe` at call
time behind `Get-Command` guards, so the decision stays testable without a VM.

#### yuruna-external bridge bring-up (KVM, Step 1.5)

libvirt's NAT `default` network keeps the cache VM host-only
(192.168.122/24 behind masquerade), so `Start-CachingProxyVM` promotes it
to the bridged `yuruna-external` network. `New-YurunaExternalNetwork` is
idempotent and self-healing: if the network exists it ensures started +
autostart, verifies the backing bridge still has its LAN uplink, and heals
or rebuilds the bridge if not (a brief flap, announced by Step 0's plan).
The step runs unattended (`-Confirm:$false`) because Step 0's
`Get-YurunaExternalNetworkPlan` already showed the operator the full
host-networking impact and rollback recipe.
`YURUNA_EXTERNAL_BRIDGE_SKIP=1` short-circuits it for the host-only path.

### Cache VM sizing

Every host's caching-proxy `New-VM.ps1` creates the cache VM with **12 GB
RAM, 4 vCPU** — matched explicitly across Hyper-V, macOS UTM, and Ubuntu
KVM so a cache rebuilt on any host has the same headroom.

This is a DEDICATED cache VM (squid and the zot OCI pull-through registry
are its only top-priority workloads), so the memory budget is sized around
those two directives rather than the other way around. Per the
`host/vmconfig/caching-proxy.base.user-data` tuning, squid's `cache_mem` is
**7 GB** (58 % of the VM's 12 GB), leaving 2 GB for zot — which handles the
Docker Hub manifest HEADs squid cannot. Empirically squid's RSS runs ~1 GB
above `cache_mem` (sslcrtd children + connection buffers + in-RAM hot
objects), so 7 GB implies ~8 GB squid RSS; zot peaks at ~500 MB during heavy
parallel pulls. That leaves ~2 GB for the rest of the stack (apache, grafana,
prometheus, loki, promtail, squid-exporter, caching-proxy-parser, kernel,
page cache).

4 vCPU stays — caching is I/O- and memory-bound, not CPU-bound; raising
the vCPU count without raising RAM wouldn't help. Swap is masked in
user-data, so an OOM event is unrecoverable; if you tune `cache_mem`
upward, raise the VM total proportionally.

### Cache-VM password persistence

The squid-cache VM's `yuruna` user password must survive cache-VM rebuilds
on any host. The vault (external-auth simulation) persists across cycles,
but the password also lives in `<track>/yuruna-caching-proxy.yml`
(host-agnostic, under the framework's status/runtime dir, managed by
`Test.CachingProxy` / `Read-`/`Save-CachingProxyState`). The runtime state
file is the source of truth: if it has a value, `Set-Password` rewrites the
vault entry from it before `Get-Password` reads it back. This keeps the
runtime state file and vault aligned even if they ever diverge (e.g. the
vault is rebuilt from scratch or the state file is restored from a backup),
and keeps the authentication extension generic — it never sees the runtime
state path; the host-specific `New-VM.ps1` bridges the two. The same track
file is shared by all hosts, so a cache VM rebuilt by any host hands the
same credentials to the harness.

Order of operations in every caching-proxy `New-VM.ps1`:

1. If the runtime state file has a password, `Set-Password 'caching-proxy-admin'` from it.
2. `Get-Password 'caching-proxy-admin'` returns either the rehydrated value or a fresh
   random one (first-ever install).
3. Write the value back to the runtime state file (idempotent on rebuild).

### Cache-VM NAS and config service

Every caching-proxy `New-VM.ps1` bakes the same three credential surfaces
into the seed, resolved on the host at VM-creation time:

- **networkStorage pool (ypool-nas) service replication** — the
  `networkUser` credential name, the share path (unix form), and this
  host's id, so the proxy can rsync its observability data to the NAS.
  `REPLICATE` stays `false` unless the networkStorage pool is configured
  AND `networkUser` has a vault password, so an empty credential is never
  baked. `networkUser` is the single NAS account used for every storage
  connection (host drain + guest mount alike). The NAS password itself is
  NOT baked — it is served at runtime by the Host Config Service
  (`/v1/nas/pool`) and written by `yuruna-config-fetch`, so a rotated NAS
  password reaches a running VM without a rebuild; the service's own
  vault gate returns 503 (no replication, self-healing) until the
  operator sets the password.
- **Pool push-ingest shared bearer** — the shared `lab-auth-token`
  gating the aggregator's `POST /ingest`, baked to
  `/etc/yuruna/lab-auth.token`. It is read from the vault's
  `lab-auth-token` entry (a legacy `pool-auth-token` entry is also
  accepted, so hosts holding one keep working); when the building host's
  vault has neither, `New-VM` mints and stores a random `lab-auth-token`
  first, so a proxy is never built with an empty token. An empty-token
  proxy (no control proofs minted, `/ingest` refused with 503, "Lab
  token" tile "off") remains diagnosable but is a failure state, not a
  normal early state.
- **Host Config Service mTLS materials** — a per-VM client leaf minted by
  THIS host's Config CA, baked with the CA cert + service port so the
  cache VM can fetch ystash-nas (and ypool-nas) credentials at boot AND
  hourly over mutual TLS. A rotated NAS password then reaches the running
  VM without a rebuild (the bake-once staleness fix). The client leaf
  chains to this host's CA, so the service serves ONLY this host's VMs.
  PEMs are baked base64 so they survive the cloud-init `write_files`
  block scalar (`encoding: b64`).

Values containing a single quote (share path / user) or a newline / quote
(token) are refused with a warning instead of baked — they would
unbalance the guest's single-quoted, sourced `/etc/yuruna/ypool-nas.env`
or corrupt the baked token file and the runner's bearer header.

### Serving remote clients

A fresh cache VM is only reachable from its own host (Hyper-V Default
Switch / UTM Shared NAT). To let a different LAN machine use it,
[Start-CachingProxyVM.ps1](../test/Start-CachingProxyVM.ps1) forwards the VM's
ports onto the host's interfaces: `:3128` (HTTP + HTTPS CONNECT), `:3129`
(ssl-bump), `:80` (Apache + CA cert), `:3000` (Grafana).

**Windows Hyper-V** (elevated PowerShell):

```
cd $HOME\git\yuruna\test
pwsh .\Start-CachingProxyVM.ps1
```

`Add-PortMap` issues `netsh interface portproxy add v4tov4`
per port and adds a matching `Yuruna-CachingProxy-Port-<N>` inbound
firewall rule. Without elevation the portproxy/firewall calls are
skipped with a warning and the cache stays reachable only from guests
on the Default Switch.

**macOS UTM** (sudo required to bind `:80`):

```
cd ~/git/yuruna/test
sudo -E pwsh ./Start-CachingProxyVM.ps1
```

`sudo -E` preserves `$HOME` so state files land in
`~/yuruna/image/caching-proxy/`, not `/var/root/...`. Without sudo the script
still runs — `:3128`, `:3129`, `:3000` forwarders launch unprivileged,
but `:80` is skipped with a warning and the remote CA-cert download is
unavailable.

Remote clients point at `http://<host-lan-ip>:3128` (apt) or
`http://<host-lan-ip>/yuruna-squid-ca.crt` (CA).

**Squid ACL** accepts only RFC1918 sources (`10/8`, `172.16/12`,
`192.168/16`). Public-IP clients stay denied even if firewall + portproxy
let the packets through. Not an open internet proxy.

### Pinning the cache VM's IP (stable MAC + DHCP reservation)

Every `Start-CachingProxyVM.ps1` run rebuilds the VM with a fresh random
MAC, so the DHCP server leases a new IP each time and consumers must
re-discover it. There is no reliable way to *request* a specific IP
from DHCP across the three hypervisors (on the preferred bridged
networks the DHCP server is the LAN router, which no host API can
program), so the supported path keeps DHCP as the source of truth and
pins the *MAC* instead:

```
pwsh ./Start-CachingProxyVM.ps1 -MacAddress 02:11:22:33:44:55
```

`-MacAddress` (accepted as `AA:BB:CC:DD:EE:FF`, `AA-BB-CC-DD-EE-FF`, or
bare `AABBCCDDEEFF`; also on each platform's
`guest.caching-proxy/New-VM.ps1` directly) gives the VM's NIC the same
MAC on every rebuild: Hyper-V `Set-VMNetworkAdapter -StaticMacAddress`,
virt-install `--network ...,mac=`, and the UTM bundle's `config.plist`.
Create a one-time DHCP reservation for that MAC on the LAN router (or
in libvirt's `default`-network dnsmasq / macOS `bootpd` on the NAT
fallback paths) and the cache IP becomes known and stable — a natural
fit for `vmStart.cachingProxyIP` (below).

Rules of thumb:

- Use a **locally-administered unicast** address: first octet `02`,
  `06`, `0A`, or `0E`. Multicast and all-zero MACs are rejected at
  validation; a globally-unique OUI draws a warning (it can collide
  with real hardware).
- Pick a **distinct MAC per host** — two hosts on one LAN each running
  a cache VM must not share one.
- Some Wi-Fi access points drop locally-administered MACs, the same
  limitation that already applies to bridged cache networking on Wi-Fi.

### External cache override

A client machine names a remote cache through two sources, resolved at
cycle start by `Resolve-CachingProxyEndpoint` (Test.CachingProxy) —
shared by `Invoke-TestInnerRunner.ps1` and
[Test-Sequence.ps1](../test/Test-Sequence.ps1);
[Invoke-TestRunner.ps1](../test/Invoke-TestRunner.ps1) and
[Test-Project.ps1](../test/Test-Project.ps1) both funnel into the
former. In priority order:

1. `vmStart.cachingProxyIP` in `test/test.config.yml` — persistent key,
   editable on the status page (which also probe-validates it at save
   time). Probed first; wins when its squid HTTP port `:3128` answers.
2. `$Env:YURUNA_CACHING_PROXY_IP` — session-scope env var, probed only
   when the config key is empty or its probe fails:

```
# Windows
$Env:YURUNA_CACHING_PROXY_IP = '10.0.0.5'
```

```
# macOS
export YURUNA_CACHING_PROXY_IP=10.0.0.5
```

The winner (from either source) is published into
`$Env:YURUNA_CACHING_PROXY_IP` for the rest of the cycle, so
[Start-StatusService.ps1](../test/Start-StatusService.ps1) and every
downstream consumer route through the remote IP. Guest `New-VM.ps1`
inherits the URL, fetches the CA from
`http://<remote>/yuruna-squid-ca.crt`, and configures apt with:

- `apt.proxy = http://<remote>:3128` (HTTP)
- `Acquire::https::Proxy "http://<remote>:3129";` (HTTPS body caching)

When both sources are empty — or both fail their `:3128` probes (the
env var is then cleared) — local discovery runs unchanged: a host
running its own cache VM falls back to it, and a host with none
proceeds without a caching proxy.

### Port-map dispatch by host topology

`Invoke-TestInnerRunner.ps1` picks one of three branches when wiring
clients up to the cache:

1. **External cache** (an external cache resolved from
   `vmStart.cachingProxyIP` or `$Env:YURUNA_CACHING_PROXY_IP`; the
   winner is published into the env var at cycle start). The remote
   serves all four ports. Install VMs default to `Yuruna-External` and
   sit on the LAN, so they reach the remote IP directly via outbound
   NAT — no host-side forwarder needed. Any leftover portproxy from a
   prior local-cache cycle is torn down so the old VM IP cannot answer
   stale proxy requests. The dashboard URL points at the remote IP.

2. **Local cache on `Yuruna-External` vSwitch** (fast path). When the
   cache VM is bridged to LAN, install VMs (which also prefer
   `Yuruna-External`) sit on the same segment and reach squid at its
   DHCP-assigned LAN IP. squid sees real client IPs at TCP level — no
   forwarder, no PROXY-protocol header, no portproxy. Any leftover
   `netsh portproxy` from a prior Default-Switch cycle is removed so
   it cannot silently NAT-rewrite a parallel path. The dashboard URL
   points at the cache VM's LAN IP (not the host IP — the host is no
   longer the proxy entry point).

3. **Local cache on Hyper-V Default Switch** (fallback). squid lives
   on the same NAT as the install VMs but does not accept LAN clients
   directly, so the runner forwards host:port → cache:port. Default
   Switch's NAT does **not** route to LAN destinations without
   `IPEnableRouter=1` (which the runner does not toggle), which is
   why both the install scripts and the cache prefer
   `Yuruna-External` and only fall back here when External cannot be
   created (no LAN, or a not-bridgeable uplink — Wi-Fi or a USB Ethernet
   adapter).

Per-port platform divergence in branch 3:

| Concern | Windows | macOS |
|---------|---------|-------|
| Port-map atomicity | `netsh portproxy` clears all ports at once (`Clear-AllCachingProxyPortMapping`), so every port the host should expose must appear in every caller's list. | Per-port pidfile; callers manage subsets independently. |
| Port 80 (Apache + CA cert) | Included in the runner's list. | **Excluded** — `:80` (<1024) needs root, and `Start-CachingProxyVM.ps1` is the only caller that pre-caches sudo. |
| HTTP / HTTPS forwarder shape | `host:HTTP → VM:HTTP` / `host:HTTPS → VM:HTTPS` via plain `netsh portproxy`. | `host:HTTP → VM:3138` / `host:HTTPS → VM:3139` via userspace pwsh forwarder + PROXY v1 header — squid logs real client IPs. |

`Yuruna.Host`'s `Test-CacheVMOnExternalNetwork` is the discriminator:
on Windows it checks for any External-type vSwitch; on macOS it
always returns `$true` (VMnet shared). So branches 2 and 3 are
Windows-only in practice — macOS always takes branch 2.

The "detected" word printed at startup is an ANSI OSC 8 hyperlink to
the Grafana dashboard so modern terminals (Windows Terminal, VS Code)
can ctrl-click into the caching-proxy view. Terminals without OSC 8
drop the escapes silently.

### Validating before a run

[Test-CachingProxy.ps1](../test/Test-CachingProxy.ps1) probes every port the
runner relies on and reports PASS/FAIL/WARN — runnable from any machine,
even without Hyper-V / UTM installed:

```
$Env:YURUNA_CACHING_PROXY_IP = '10.0.0.5'
pwsh test/Test-CachingProxy.ps1
# === Summary: 5 PASS, 0 WARN, 0 FAIL ===

pwsh test/Test-CachingProxy.ps1 -CacheIp 10.0.0.5   # ad-hoc, no env var
```

With no `-CacheIp`, the script resolves the cache in the **same order
the runner does at cycle start**, through the same
`Resolve-CachingProxyEndpoint` resolver: `vmStart.cachingProxyIP`
(test.config.yml) probed first, then `$Env:YURUNA_CACHING_PROXY_IP`,
then local discovery — so the IP it smoke-tests is the IP
`Invoke-TestRunner.ps1` will actually pick. A configured source with no
reachable HTTP proxy port is reported (WARN) and the script falls back
to local discovery, exactly as the runner would; unlike the runner, the
script never publishes the winner into `$Env:YURUNA_CACHING_PROXY_IP`
(read-only probe). `-CacheIp` bypasses the resolution to probe an
arbitrary IP. Exit 1 on any required-port failure — suitable for a
`&&` chain.

### Promoting to the host system proxy

`Test-CachingProxy.ps1 -SetHostProxy` repoints WinINet (Windows) or
networksetup (macOS) at the cache so every host-side
`Invoke-WebRequest` / `curl` / `git` flows through it. The previous
proxy state is snapshotted to `~/.yuruna/host-proxy.backup.json` and
restored by `Stop-CachingProxyVM.ps1`.

Yuruna also writes a "managed" marker (HKCU registry value on
Windows, `~/.yuruna/host-proxy.managed` on macOS) so a re-promotion
across a missing backup file recognizes the existing state as
Yuruna's own and snapshots it as clean — without the marker, a lost
backup turned every subsequent `Stop-CachingProxyVM` +
`Test-CachingProxy.ps1 -SetHostProxy` cycle into a self-loop because
the contaminated snapshot kept getting restored. `Start-CachingProxyVM.ps1`
also clears any leftover Yuruna proxy state at startup, so a fresh
provision never inherits a stale `ProxyServer` from a prior cycle.

### In-process proxy env var hygiene at provision time

`Start-CachingProxyVM.ps1`'s whole job is to *bring up* the cache, so
every network call it makes (Get-Image's `Invoke-WebRequest`,
`Save-CachedHttpUri`'s no-cache fall-through, `virt-install` fetching
osinfo, `qemu-img`/`genisoimage` reaching the public internet) must
go DIRECTLY to the public Internet. .NET's `HttpClient` honors
`HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` from the process
environment. If the caller's shell exports any of those pointing at
a cache IP that no longer hosts squid (stale after a
host reboot, wrong LAN, or a cache VM destroyed by
`Stop-CachingProxyVM.ps1`), every download fails with "Network is
unreachable" — well before the cache we're about to build exists.
`YURUNA_CACHING_PROXY_IP` belongs in the same bucket: downstream
discovery (`Invoke-TestRunner.ps1`'s remote-cache branch,
`Test-CachingProxy.ps1`) translates it into a proxy URL.

The script therefore drops `HTTP_PROXY`, `http_proxy`, `HTTPS_PROXY`,
`https_proxy`, `NO_PROXY`, `no_proxy`, `ALL_PROXY`, `all_proxy`, and
`YURUNA_CACHING_PROXY_IP` from THIS process and its children. The
user's shell is untouched — anything they exported for OTHER scripts
(later runs of `Invoke-TestRunner.ps1`, `Test-CachingProxy.ps1` with
the remote-cache env fallback) is still set in the next shell. Step 1's
`Remove-HostProxy` handles the persistent OS-level state (WinINet
registry, `/etc/environment`, `networksetup`); this in-process gap is
what `Remove-HostProxy` cannot reach. The behavior is uniform across
ubuntu.kvm / windows.hyper-v / macos.utm — all three run the same
.NET `HttpClient`.

### Migrating to a replacement cache VM

How to replace the Squid cache VM (host retirement, resize, newer base
image) without ever serving clients from a cold cache.
[Move-CachingProxy.ps1](../test/Move-CachingProxy.ps1) builds a
temporary parent-child Squid hierarchy — the NEW cache fetches its
misses from the OLD cache's warm store at LAN speed — and later tears
it down and retires the old VM. Cache-VM concepts are covered in
the sections above. Short link:
<https://yuruna.link/caching-proxy-migration>.

#### Why migrate warm

A cold cache re-fights the battle the cache VM exists to win: every
fresh-VM install hammers the Ubuntu CDN and container registries until
429 rate limits stretch a ~2 min warm install to ~30 min or fail it
outright (see [why a separate cache VM](#why-a-separate-cache-vm)).
Warming the new cache from the old one keeps every hot object served
from disk on the LAN, and only true misses go to the origin — once,
from one VM.

#### How it works

```
[ client ] --> [ NEW cache (miss) ] --tls :3130--> [ OLD cache (hit or origin) ]
```

`-Start` writes one drop-in file on each VM —
`/etc/squid/conf.d/yuruna-migration.conf` — and reloads squid.
`squid.conf` and the stock `yuruna.conf` are never modified, so ending
the migration is exactly "delete the drop-in, reconfigure".

On the **old** cache (the parent):

- `acl yuruna_migration_child src <new-ip>` + `http_access allow` —
  explicit admission for the child (belt-and-suspenders: the stock
  yuruna ACL already admits RFC1918 sources).
- `https_port 3130 tls-cert=... tls-key=...` — a TLS proxy port that
  reuses the ssl-bump CA pair as its server certificate.

On the **new** cache (the child):

- `cache_peer <old> parent 3130 0 no-query default tls
  tls-flags=DONT_VERIFY_PEER,DONT_VERIFY_DOMAIN` — the old cache
  becomes the default parent. The link is TLS because squid refuses to
  relay ssl-bumped `https://` requests over a plaintext peer link;
  over TLS, both the ssl-bumped HTTPS objects **and** the plain-HTTP
  objects warm from the old cache. Verification is off because the old
  cache presents its self-minted squid CA as the server certificate —
  a lab-internal, migration-lifetime link between two VMs the operator
  controls.
- `prefer_direct off` + `nonhierarchical_direct off` — send misses
  (including requests squid would classify as non-hierarchical)
  through the parent instead of going direct.

If the old cache has no ssl-bump CA pair, or `:3130` fails to come up,
the script falls back automatically to a plain `:3128` parent and says
so — plain-HTTP objects still warm from the old cache; ssl-bumped
HTTPS objects re-fetch direct.

`-End` deletes the drop-in on the new cache (it keeps everything it
cached and goes direct from then on), deletes the drop-in on the old
cache, and runs `systemctl disable --now squid` there so the old VM is
inert and ready to power off — even across an accidental reboot.

Every configuration write on either VM is validated with
`squid -k parse` **before** `squid -k reconfigure` (a FATAL config
error fed to a reconfigure can kill the running squid); a failed parse
restores the exact prior state of both VMs.

#### Prerequisites

- Control machine: PowerShell 7 and OpenSSH client 8.4+ (any machine;
  no hypervisor access needed). The script is standalone — no harness
  modules required.
- Both cache VMs reachable over SSH with password login (`yuruna`
  user by default) and sudo rights.
- VM-to-VM reachability: the new cache must reach the old cache's
  `:3128`/`:3130` **directly**. Both VMs should sit on bridged/LAN
  networks (`Yuruna-External` / `yuruna-external`); a cache behind
  host NAT (Hyper-V Default Switch, libvirt default network) is
  invisible to the other VM even when its host forwards `:3128`.
- squid active on both VMs (the script verifies this and stops if not).

#### Starting the copy cycle

```
pwsh test/Move-CachingProxy.ps1 -Start -OldAddress 192.168.68.13 -NewAddress 192.168.68.60
```

Prompts (masked) for both passwords; `-OldUser`/`-NewUser` default to
`yuruna`, and `-OldPassword`/`-NewPassword` exist for scripted use.
The script then:

1. Opens SSH sessions to both VMs and probes sudo (NOPASSWD or
   password-on-stdin — never on a command line).
2. Verifies both look like yuruna cache VMs (squid installed and
   active, `conf.d` present) and that the new VM reaches the old VM's
   `:3128` directly.
3. Checks `:3130` is free on the old cache, writes the parent drop-in,
   parse-gates it, reconfigures, and waits for `:3130` to listen
   (falling back to plain `:3128` peering if it does not).
4. Writes the child drop-in on the new cache, parse-gates it, and
   reconfigures. Any failure here rolls **both** VMs back to the state
   they were found in.
5. Verifies end to end (warn-only): an HTTP fetch through the new
   cache's `:3128`, an ssl-bump HTTPS fetch through `:3129`, and a
   check that the old cache's `access.log` shows the child.

It ends by printing the guidance to **go to the clients and switch
them to the new cache VM**:

- Harness machines: set `vmStart.cachingProxyIP: <new>` in
  `test/test.config.yml` (or the status page's Edit config). That key
  is probed **first** at cycle start, and while the warm-up hierarchy
  runs the old cache still answers — so a stale old IP persisted there
  keeps winning no matter what the env var says. Only machines whose
  config key is empty can switch via the fallback env var instead:
  `$Env:YURUNA_CACHING_PROXY_IP = '<new>'` (Windows) /
  `export YURUNA_CACHING_PROXY_IP=<new>` (macOS/Linux) — see
  [External cache override](#external-cache-override).
- Hand-wired clients (DNS, DHCP options, WPAD, apt proxy files):
  repoint `<old>:3128 → <new>:3128` and `<old>:3129 → <new>:3129`.
- Validate from any client: `pwsh test/Test-CachingProxy.ps1 -CacheIp <new>`.

Re-running `-Start` is safe: it rewrites the same drop-ins.

#### While the hierarchy runs

As clients use the new cache, its misses fill from the old cache and
the old cache's request rate decays naturally — typically a few days
for the hot set. Watch the drain:

```
ssh caching-proxy-admin@<old>
sudo tail -f /var/log/squid/access.log
```

Both VMs also expose their Grafana dashboards on `:3000`.

#### Ending the copy cycle

When old-cache traffic is negligible:

```
pwsh test/Move-CachingProxy.ps1 -End -OldAddress 192.168.68.13 -NewAddress 192.168.68.60
```

The script then:

1. Detaches the new cache first (removes the drop-in, parse-gates,
   reconfigures, confirms `:3128` still serves) — once the child
   forgets the parent, nothing depends on the old cache.
2. Removes the old cache's drop-in and runs
   `systemctl disable --now squid` there. An unreachable old VM is a
   warning, not a failure — it usually means the VM is already off.
3. Prints the guidance to **go to the old VM's host and deactivate
   it** (default VM name `yuruna-caching-proxy`):
   - Power off: `Stop-VM` (Hyper-V) / `virsh shutdown` (KVM) /
     `utmctl stop` (UTM).
   - Tear down host-side plumbing that pointed at it (port forwards,
     host-proxy promotion): `pwsh test/Stop-CachingProxyVM.ps1` on that
     host.
   - Keep the powered-off VM for a grace period; rollback is booting
     it and `sudo systemctl enable --now squid`. Delete the VM and its
     disk once the new cache has proven itself.

Re-running `-End` is safe: already-done parts are skipped with a note.

#### Resilience model

- **Parse-gate + rollback.** Every write is `squid -k parse`-validated
  before `squid -k reconfigure`; on failure both VMs are restored to
  their captured prior state and the original error surfaces.
- **TLS fallback.** No CA pair on the old cache, or `:3130` never
  listens → automatic downgrade to plain `:3128` peering with a
  warning describing the reduced coverage.
- **Bounded SSH.** Every remote command runs under a hard wall-clock
  cap and connection retries, so a half-dead session cannot hang the
  run; host keys are not pinned because cache VMs are recreated on
  recycled DHCP addresses (the same policy as the harness's SSH
  driver).
- **Idempotent phases.** Both `-Start` and `-End` can be re-run after
  any interruption.
- **Credential hygiene.** Passwords travel via a per-run `SSH_ASKPASS`
  helper (temp directory ACLed to the current user, deleted on exit)
  and via sudo's stdin — never on a command line, never in output.

#### Troubleshooting

| Symptom | Likely cause / action |
|---------|----------------------|
| `SSH authentication failed` | Wrong password, or password auth disabled on the VM. |
| `cannot reach <old>:3128 directly` | One of the VMs is behind host NAT. Put both caches on the bridged network, or accept a cold start. |
| `:3130 did not come up ... falling back` | The old squid cannot open a TLS port (missing certs / build). HTTP objects still warm; HTTPS re-fetches direct. |
| End-to-end probe returned `000` (warn) | No internet egress from the lab, or squid unhealthy — check `sudo systemctl status squid` and the VM's Grafana. |
| `-End`: parse fails after drop-in removal | The new cache's config is broken independently of the migration; the drop-in is put back and nothing is reconfigured. Fix the config, re-run. |
| Old VM unreachable during `-End` (warn) | Usually already powered off. If not intended, re-run `-End` when it is reachable. |

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.28

Back to [Yuruna](../README.md)
