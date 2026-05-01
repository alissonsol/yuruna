# Caching

Yuruna has two complementary caching layers. They are independent but
compose: keeping `YurunaCacheContent` unset is what lets the Squid VM
serve cached copies of the install scripts themselves.

1. **[`YurunaCacheContent`](#the-yurunacachecontent-cache-buster)** —
   env var controlling cache-busting of `irm` / `wget` / `curl`
   one-liners throughout the repo.
2. **[Squid cache VM](#squid-cache-vm)** — optional lightweight VM that
   caches HTTP/HTTPS for test VMs. First install populates; subsequent
   installs pull from LAN at disk speed.

## The `YurunaCacheContent` cache-buster

Every Yuruna one-liner appends `?nocache=<value>` when `YurunaCacheContent`
is set. Unset → cacheable URL, intermediate proxies can serve stored
copies. Set to any unique string (typically a datetime) → fresh fetch.

```powershell
# Windows PowerShell — current session:
$env:YurunaCacheContent = (Get-Date -Format yyyyMMddHHmmss)
# Persist for the user (open a new shell):
setx YurunaCacheContent (Get-Date -Format yyyyMMddHHmmss)
# Clear:
Remove-Item Env:YurunaCacheContent        # current session
setx YurunaCacheContent ""                # persisted
```

```bash
# macOS / Linux — current session:
export YurunaCacheContent="$(date +%Y%m%d%H%M%S)"
# Persist: add the line to ~/.zshrc or ~/.bash_profile.
unset YurunaCacheContent                  # clear
```

Read by: guest README `irm … | iex` one-liners,
[`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh)
and [`automation/Invoke-FetchAndExecute.ps1`](../automation/Invoke-FetchAndExecute.ps1),
and `wget`/`curl` calls in each `virtual/guest.*/` install script. The
fetch-and-execute wrappers also honor an explicit `EXEC_QUERY_PARAMS`
override (used verbatim, takes precedence).

`YurunaCacheContent` is read by whichever shell expands the URL — it is
**not** auto-pushed into guest VMs. Set it again inside the guest if you
want guest install scripts to cache-bust.

---

## Squid cache VM

Optional local HTTP/HTTPS caching proxy packaged as a standalone VM
alongside the test harness. Works identically on Windows Hyper-V and
macOS UTM.

### What it does

Ubuntu Server VM (4 GB RAM, 4 vCPU, 144 GB disk — 128 GB for the squid
cache) listening on `:3128`, transparently caching every cacheable
response — `.deb` packages, ISO metadata, firmware blobs, anything fetched
over plain HTTP. First install populates; subsequent installs hit LAN
speed.

### Why Squid replaced apt-cacher-ng

- **Caches more.** apt-cacher-ng only recognized apt-shaped URLs, so
  subiquity's in-install `apt-get install linux-firmware` bypassed it and
  kept hitting `security.ubuntu.com`'s 429 rate limit. Squid caches
  those too.
- **Tunnels HTTPS by default** (`:3128` CONNECT) and — on Hyper-V —
  **caches HTTPS** via a second SSL-bump listener on `:3129` (see
  [HTTPS caching](#https-caching)). apt-cacher-ng refused CONNECT.

Rate-limiting bites macOS faster because Apple Virtualization's Shared
NAT egresses every UTM VM through the host's single public IP.

## Setup

### Windows Hyper-V

From an elevated PowerShell (one-time):

```powershell
cd $HOME\git\yuruna\virtual\host.windows.hyper-v\guest.squid-cache
pwsh .\Get-Image.ps1
pwsh .\New-VM.ps1
```

- [Get-Image.ps1](../virtual/host.windows.hyper-v/guest.squid-cache/Get-Image.ps1)
  downloads Ubuntu Server Noble (amd64), converts qcow2→VHDX via
  `qemu-img`, resizes to 144 GB.
- [New-VM.ps1](../virtual/host.windows.hyper-v/guest.squid-cache/New-VM.ps1)
  creates Gen 2 VM `squid-cache` on the Default Switch, attaches a
  cloud-init seed ISO that installs and configures squid, and waits until
  port 3128 responds. Prints the proxy URL on ready.

### macOS UTM

```bash
cd ~/git/yuruna/virtual/host.macos.utm/guest.squid-cache
pwsh ./Get-Image.ps1
pwsh ./New-VM.ps1
```

- [Get-Image.ps1](../virtual/host.macos.utm/guest.squid-cache/Get-Image.ps1)
  downloads arm64 qcow2, converts to raw (required by Apple
  Virtualization), resizes to 144 GB.
- [New-VM.ps1](../virtual/host.macos.utm/guest.squid-cache/New-VM.ps1)
  assembles `~/Desktop/Yuruna.VDE/<hostname>.nosync/squid-cache.utm/`
  with `config.plist` (Apple Virtualization backend),
  `Data/efi_vars.fd`, `Data/disk.img` (APFS-clone of the raw image),
  `Data/seed.iso` (cloud-init via `hdiutil`). Double-click the `.utm` to
  register it with UTM, then start.

### Finding the cache VM's IP

| Host | Method |
|------|--------|
| **Hyper-V** | `Get-VM squid-cache \| Get-VMNetworkAdapter`, or reuse the IP `New-VM.ps1` printed. |
| **UTM** | (a) read `eth0: <ip>` at the console login; (b) `awk -F'[ =]' '/name=squid-cache/{f=1} f && /ip_address/{print $NF; exit}' /var/db/dhcpd_leases`; (c) port-scan 192.168.64.2-30 for `:3128`. `utmctl ip-address` does **not** work for Apple Virtualization-backed VMs. |

### Pre-warm on first boot

After squid starts, cloud-init points the VM's own apt at
`http://127.0.0.1:3128` and runs `apt-get install --download-only --reinstall`
for `linux-firmware`, the HWE kernel meta, and (amd64 only)
`intel-microcode`, `amd64-microcode`, `firmware-sof-signed`. Without this
the *first* guest install still races the 429 rate limiter for
`linux-firmware` (~330 MB).

Expect **5–15 minutes** for first-boot prewarm. Cloud-init then flips
squid into [offline_mode](#offline_mode).

## How guests use it

At seed-ISO creation time, each guest's `New-VM.ps1` discovers the cache
and writes its URL into autoinstall `apt.proxy` and a persistent apt
proxy dropin inside the installed target. Subiquity, cloud-init's
first-boot `openssh-server` install, and every subsequent `apt-get` flow
through the cache.

### Discovery

| Host | Method |
|------|--------|
| **Hyper-V** | `Get-VM squid-cache` → IP via ARP on Default Switch (matched by MAC) or KVP, then TCP-probe `:3128`. |
| **UTM** | `utmctl status squid-cache` → if `started`, subnet-probe 192.168.64.2-30. Fallback subnet probe runs even without `utmctl`. |

### Severity policy

Silent fallback-to-CDN can't mask a 429:

- **No cache VM registered / not running** → **WARNING**, proceed against CDN.
- **Cache VM running but `:3128` unreachable** → **ERROR**, exit 1.

See [../test/CachingProxy.md](../test/CachingProxy.md) for the test-harness
operator reference.

## Cache configuration

Squid is tuned as a **replayable snapshot**: once an object lands it
stays; the cache keeps serving when origin is unreachable. Fully
populated = guest installs with zero internet.

Config lives in
`virtual/host.{windows.hyper-v,macos.utm}/guest.squid-cache/vmconfig/user-data`
(same settings in both).

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
  ignore-must-revalidate ignore-private`. Apt metadata uses a shorter
  TTL so apt still sees fresh package lists.

### offline_mode

After prewarm, cloud-init writes `/etc/squid/conf.d/yuruna-offline.conf`
(`offline_mode on`) and runs `squid -k reconfigure`. From then on: cache
hit → disk; cache miss → `504`. This is what enables the
fully-disconnected workflow and, on a miss, points clearly at the missing
URL. `offline_mode` is flipped **after** prewarm because an empty cache +
`offline_mode` = 504 on every request.

### Refreshing the cache

Temporary — serve from origin for one burst, then offline again:

```bash
ssh yuruna@<squid-cache-ip>
sudo rm /etc/squid/conf.d/yuruna-offline.conf && sudo squid -k reconfigure
# ... apt-get update etc. ...
echo "offline_mode on" | sudo tee /etc/squid/conf.d/yuruna-offline.conf
sudo squid -k reconfigure
```

Full rebuild:

```powershell
# Windows Hyper-V:
Stop-VM squid-cache -Force; Remove-VM squid-cache -Force
Remove-Item -Recurse "<HyperVVHDPath>\squid-cache"
pwsh .\New-VM.ps1
```

```bash
# macOS UTM:
utmctl stop squid-cache
rm -rf ~/Desktop/Yuruna.VDE/<hostname>.nosync/squid-cache.utm
pwsh ./New-VM.ps1
```

## Monitoring

The VM runs these services alongside squid:

| Service         | Port | Binding                  | Purpose |
|-----------------|------|--------------------------|---------|
| Grafana OSS     | 3000 | 0.0.0.0                  | Primary dashboard UI; anonymous Viewer. |
| Prometheus      | 9090 | 127.0.0.1                | Metrics datastore. |
| Loki            | 3100 | 127.0.0.1                | Log datastore — backs the access-log panel. |
| Promtail        | 9080 | 127.0.0.1                | Tails `/var/log/squid/access.log` into Loki. |
| squid-exporter  | 9301 | 127.0.0.1                | Reads squid cachemgr over `:3128`. |
| cachemgr.cgi    | 80   | 0.0.0.0, RFC1918         | Raw cachemgr UI fallback. |
| CA cert         | 80   | 0.0.0.0                  | `/yuruna-squid-ca.crt` via Apache. |
| Squid HTTP      | 3128 | 0.0.0.0, RFC1918         | Plain HTTP + HTTPS CONNECT. |
| Squid HTTPS     | 3129 | 0.0.0.0, RFC1918         | SSL-bump — caches HTTPS bodies. |

**Grafana (primary UI)** — `http://<squid-cache-vm-ip>:3000`. Anonymous
Viewer (no login). Pre-provisioned "Squid Cache (yuruna)" dashboard:

- Client HTTP(S) requests/sec — `rate(squid_client_http_requests_total[5m])`
- Client HTTP(S) hits/sec — `rate(squid_client_http_hits_total[5m])`
- Data served (kB/s) — `Total`:
  `rate(squid_client_http_kbytes_out_kbytes_total[5m])`,
  `Cached`: `rate(squid_client_http_hit_kbytes_out_bytes_total[5m])`.
- Last 100 requests (client IP / status / URL) — Loki logs panel,
  parses `/var/log/squid/access.log` at query time with
  `{job="squid"} | regexp ... | line_format ...`. Empty until Promtail
  has shipped at least one line; takes a few seconds after first guest
  fetch. Cardinality stays bounded because client IP and URL are kept
  out of Loki labels — only `job=squid` is a stream.

No HTTPS-specific client counter — squid's `client_http.*` counters
aggregate HTTP + HTTPS (CONNECT + ssl-bump), hence "HTTP(S)".
boynux/squid-exporter is inconsistent about unit suffixes: Total uses
`_kbytes_total`, Cached uses `_bytes_total` (despite both being kbytes).
Verify with
`curl -s http://127.0.0.1:9301/metrics | grep hit_kbytes_out` — writing
Cached as `..._hit_kbytes_out_kbytes_total` is the fast-path mistake;
that series doesn't exist.

Edit dashboards with `admin`/`admin` (default; unrotated because the VM
is on the private switch). Datasource UIDs: `yuruna-prometheus`,
`yuruna-loki`. Grafana is the self-hosted OSS build from
`apt.grafana.com stable main`.

**Prometheus** is loopback-only. SSH in then
`curl 'http://127.0.0.1:9090/api/v1/query?query=up'`, or use Grafana's
Explore view. Scrape config polls `:9090` and `:9301` every 15 s.

**Loki + Promtail** — also loopback-only, same `apt.grafana.com` repo.
Promtail tails `/var/log/squid/access.log` and ships every line to Loki
on `127.0.0.1:3100`; the only stream label is `job=squid` (client IP
and URL are kept out of labels to avoid cardinality blow-up). Retention
capped at 7d via Loki's compactor. Verify ingestion with
`curl -G 'http://127.0.0.1:3100/loki/api/v1/query_range' --data-urlencode 'query={job="squid"}' --data-urlencode 'limit=5'`
or use Grafana Explore against the Loki datasource.

**squid-exporter** — [boynux/squid-exporter](https://github.com/boynux/squid-exporter)
service, speaks squid's cache-manager protocol on `localhost:3128`.
Built from source during cloud-init (`go install`); `golang-go`
briefly appears in the package list, then is purged once the static
binary lands in `/usr/local/bin/squid-exporter`.

**cachemgr.cgi (fallback)** — `http://<vm-ip>/cgi-bin/cachemgr.cgi`,
Cache Host `localhost`, Cache Port `3128`. Reports: `info`,
`utilization`, `storedir`, `mem`, `client_list`, `objects`. Restricted
to RFC1918 at Apache; squid's `manager` ACL allows only `localhost`.

**CLI** inside the VM:

```bash
sudo squidclient mgr:info | mgr:utilization | mgr:5min
sudo tail -f /var/log/squid/access.log   # 3rd-to-last field: TCP_HIT/MISS/OFFLINE_HIT
```

### Purging a single cached entry

The `yuruna.conf` dropin enables the `PURGE` method for RFC1918:

```bash
# Inside the cache VM:
sudo squidclient -m PURGE http://<origin>:<port>/<path>

# From any RFC1918 workstation:
curl -x http://<cache-vm-ip>:3128 -X PURGE http://<origin>:<port>/<path>
```

`200` = purged; `404` = wasn't cached (safe no-op). For total wipes:
stop squid, `rm -rf /var/spool/squid/*`, `squid -z`.

## Access / credentials

Cloud-init creates a single `yuruna` debug user (replacing the Ubuntu
cloud image's default `ubuntu` user — `users:` in user-data with no
`- default` entry suppresses ubuntu creation entirely). It has:

- **Password** — fresh random 10-char alphanumeric per `New-VM.ps1` run.
  Printed in the ready banner, saved to
  `<HyperVVHDPath>\squid-cache\squid-cache-password.txt` (Windows) or
  `~/virtual/squid-cache/squid-cache-password.txt` (UTM, chmod 600), and
  baked into the seed via `chpasswd`. Expiry disabled. Regenerated on
  every rebuild (a static `password` caused browser password managers to
  auto-suggest it against cachemgr.cgi).
- **SSH key** — the harness public key from
  `test/.ssh/yuruna_ed25519` via
  [Test.Ssh.psm1](../test/modules/Test.Ssh.psm1). `ssh
  yuruna@<squid-cache-ip>` is passwordless from the host.
- **Sudo** — passwordless (`NOPASSWD:ALL`). Same trust model as the
  password: this VM is on a private switch, RFC1918-only.

### Reaching the cache from outside the host (port 8022)

`Start-CachingProxy.ps1` adds an `8022 -> 22` host port forward
alongside the squid/Grafana ones, so a remote operator can SSH to the
cache from any LAN client:

```bash
ssh -p 8022 yuruna@<host-lan-ip>     # -> cache VM :22
```

Port 8022 (not 22) on the host avoids colliding with the host's own
sshd. The forward is managed the same way as :3128 / :3000 — netsh
portproxy + Yuruna firewall rule on Windows, detached pwsh
TcpListener on macOS — and re-applied by every caller of
`Add-CachingProxyPortMap` (test runner, status server, repair script).

Both paths exist because the VM is most often debugged before cloud-init
finishes. The password is not a secret: the VM is reachable only on the
private Hyper-V Default Switch / UTM Shared NAT, and squid restricts to
RFC1918.

## Management

The cache VM is independent of the test harness — **not** created or
destroyed by [Invoke-TestRunner.ps1](../test/Invoke-TestRunner.ps1).

### Windows Hyper-V

- Start/Stop: `Start-VM squid-cache` / `Stop-VM squid-cache`
- Delete: `Stop-VM -Force; Remove-VM -Force`, then delete
  `<HyperVVHDPath>\squid-cache`.
- Auto-start on host boot: `Set-VM squid-cache -AutomaticStartAction Start`

### macOS UTM

- Start/Stop: `utmctl start squid-cache` / `utmctl stop squid-cache`.
- Delete: stop, right-click → Delete in UTM, then
  `rm -rf ~/Desktop/Yuruna.VDE/<hostname>.nosync/squid-cache.utm`.

### Both hosts

- Clear cache (wipe objects, keep VM):

```bash
ssh yuruna@<squid-cache-ip>
sudo systemctl stop squid && sudo rm -rf /var/spool/squid/* && sudo squid -z -N
sudo systemctl start squid
```

- Reload config: `sudo squid -k reconfigure` inside the VM.
- Watch hits/misses: `sudo tail -f /var/log/squid/access.log`.

## HTTPS caching

Shipped on both Hyper-V and UTM. A second squid listener on `:3129`
performs **SSL-bump** — terminates TLS with a locally-generated CA,
caches plaintext bodies through the same `refresh_pattern` and
`offline_mode` pipeline, and re-encrypts with a per-SNI leaf cert minted
on the fly. Guests that trust the CA get cached HTTPS apt traffic;
everything else keeps using `:3128` with CONNECT tunneling (no caching).

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

**Hyper-V (in-install wget):** `vmconfig/user-data` runs inside
`late-commands` when `New-VM.ps1` injected a proxy:

1. Derive cache host from proxy URL (strip `http://` and `:3128`).
2. `wget http://<cache>/yuruna-squid-ca.crt` into
   `/target/usr/local/share/ca-certificates/`.
3. `curtin in-target -- update-ca-certificates`.
4. Append `Acquire::https::Proxy "http://<cache>:3129";` to the existing
   `/target/etc/apt/apt.conf.d/99yuruna-apt-cache`.

Best-effort: if CA fetch fails, the guest keeps HTTP proxy and lets
HTTPS apt go direct — no install abort.

**UTM (host pre-fetch + base64 in seed):** `guest.ubuntu.*/New-VM.ps1`
reads `$HOME/virtual/squid-cache/cache-ip.txt` (written by
`Start-CachingProxy.ps1`) or `$Env:YURUNA_CACHING_PROXY_IP`, fetches
the CA, base64-encodes it, and splices into the seed as
`CA_CERT_BASE64_PLACEHOLDER`. Guest `late-commands`:

1. `printf '%s' "<base64>" | base64 -d > /target/.../yuruna-squid-ca.crt`
2. `curtin in-target -- update-ca-certificates`
3. `Acquire::https::Proxy "http://192.168.64.1:3129";` — the VZ gateway,
   not the cache IP, because the host-side `:3129` forwarder
   (from `Start-CachingProxy.ps1`) is the only path guests have.

Empty placeholder → no-op, HTTPS apt bypasses the cache.

### Where caching actually kicks in

- **Subiquity in-install HTTPS** (kernel, firmware) — still `:3128`
  CONNECT, **not cached**. The CA isn't in subiquity's trust store yet;
  only the target chroot gets it.
- **Guest first-boot + post-install apt** — HTTPS routes through `:3129`,
  bumped, lands in cache alongside HTTP content.
- **Non-apt HTTPS** (browsers, curl, snap, Go) — untouched; nothing else
  is configured to route through squid.

### ssl_bump rules

Minimum viable: `peek step1` → `bump all`. Squid reads the TLS
ClientHello for SNI, then intercepts. If a pin-checking client (snap, Go
HTTPS) hits the install path, add `acl nobump dstdomain ...` +
`ssl_bump splice nobump` **above** `bump all` rather than disabling
bumping. See `/etc/squid/conf.d/yuruna.conf`.
