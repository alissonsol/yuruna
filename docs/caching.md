# Caching

Yuruna has two complementary caching layers:

1. **[`YurunaCacheContent`](#the-yurunacachecontent-cache-buster)** — an
   environment variable that controls cache-busting of the one-liner
   `irm` / `wget` / `curl` commands throughout the repo. Leave it unset
   to let proxies serve stored copies; set it to a unique datetime-like
   value to force a fresh fetch.
2. **[Squid cache VM](#squid-cache-vm)** — an optional lightweight VM
   that runs Squid as an HTTP/HTTPS caching proxy for the test VMs.
   First install populates the cache; every subsequent install pulls
   from LAN at disk speed.

The two layers are independent but compose cleanly: keeping
`YurunaCacheContent` unset is what lets the Squid VM serve cached copies
of the install scripts themselves.

## The `YurunaCacheContent` cache-buster

Every Yuruna one-liner builds its URL from an optional `?nocache=<value>`
suffix driven by the **`YurunaCacheContent`** environment variable. Unset
or empty → no suffix, fully cacheable URL, and an intermediate HTTP proxy
(like the Squid VM below) can serve stored copies instead of re-hitting
`raw.githubusercontent.com`.

To force a fresh fetch, set `YurunaCacheContent` to any unique string —
typically a datetime. Every subsequent one-liner in that shell (or on
that host, if persisted) carries the value and caches treat it as a new
resource.

Pick whichever scope matches how long you want the override to last:

```powershell
# Windows PowerShell — current session only:
$env:YurunaCacheContent = (Get-Date -Format yyyyMMddHHmmss)

# Windows — persist for the current user across new sessions (open a new shell after):
setx YurunaCacheContent (Get-Date -Format yyyyMMddHHmmss)

# Clear it again when you want caching back:
Remove-Item Env:YurunaCacheContent    # current session
setx YurunaCacheContent ""            # persisted value
```

```bash
# macOS / Linux — current session only:
export YurunaCacheContent="$(date +%Y%m%d%H%M%S)"

# Persist: add the export line to ~/.zshrc or ~/.bash_profile.

# Clear:
unset YurunaCacheContent
```

### Where the variable is read

- `irm "…<url>$nc" | iex` one-liners in the guest READMEs (PowerShell).
- [`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh) and
  [`automation/Invoke-FetchAndExecute.ps1`](../automation/Invoke-FetchAndExecute.ps1)
  — URL helpers used by the test harness and guest scripts.
- `wget` / `curl` calls inside each install script under
  [`vde/guest.amazon.linux/`](../vde/guest.amazon.linux/) and
  [`vde/guest.ubuntu.desktop/`](../vde/guest.ubuntu.desktop/).

The suffix expands to `?nocache=<value>` when set, empty otherwise. The
`automation/fetch-and-execute.*` wrappers also honor an explicit
`EXEC_QUERY_PARAMS` override that takes precedence and is used verbatim
— useful for pinning a specific query string rather than a cache-buster
timestamp.

### Propagating the variable into VMs

`YurunaCacheContent` is read by whichever shell (host PowerShell, guest
Bash, etc.) expands the URL. It is **not** automatically pushed into
guest VMs; set it again inside the guest if you want guest install
scripts to cache-bust when fetching from the host-side proxy.

---

## Squid cache VM

Optional local HTTP caching proxy for Ubuntu Desktop (and other) test-VM
installations, packaged as a standalone VM alongside the test harness.
Works identically on Windows Hyper-V and macOS UTM hosts.

### What it does

Runs [Squid](https://www.squid-cache.org/) inside a lightweight Ubuntu
Server VM (4 GB RAM, 4 vCPU, 144 GB disk — 128 GB for squid's on-disk
cache). The VM listens on port 3128 and transparently caches every
cacheable HTTP response — `.deb` packages, ISO metadata, firmware blobs,
anything the installer or guest workload fetches over plain HTTP. First
install populates the cache; subsequent installs pull from the local VM
at disk speed.

### Why it replaced apt-cacher-ng

1. **Squid caches more.** apt-cacher-ng only recognizes apt-shaped URLs.
   Subiquity's kernel install step (`apt-get install linux-firmware`,
   etc.) happens before the late-command wires the cache into the target
   system, so those downloads went direct and were the main source of
   intermittent `429 Too Many Requests` errors from
   `security.ubuntu.com`. A generic HTTP proxy caches those too.
2. **Squid tunnels HTTPS (CONNECT) by default** and — on Hyper-V — also
   **caches HTTPS** via a second SSL-bump listener on `:3129` (see
   [HTTPS caching](#https-caching)). apt-cacher-ng refused CONNECT and
   broke `wget https://...` in late-commands; Squid passes those through
   on `:3128` and, for clients that trust the local CA, transparently
   caches the bodies on `:3129`.

### Why the cache matters more on macOS

UTM VMs in Apple Virtualization's Shared network mode NAT out through
the host's single public IP. Back-to-back test cycles hit
`security.ubuntu.com` from the same IP and trip the CDN's per-source
rate limit much faster than on Hyper-V (typically one guest in flight).
A local Squid intercepts those requests so the first install populates
the cache and subsequent installs pull `.deb` packages from LAN.

## Setup

### Windows Hyper-V

Run once from an elevated PowerShell:

```powershell
cd $HOME\git\yuruna\vde\host.windows.hyper-v\guest.squid-cache
pwsh .\Get-Image.ps1
pwsh .\New-VM.ps1
```

- [Get-Image.ps1](../vde/host.windows.hyper-v/guest.squid-cache/Get-Image.ps1) —
  downloads the Ubuntu Server Noble cloud image (amd64), converts it
  from qcow2 to VHDX via `qemu-img`, and resizes it to 144 GB (128 GB
  squid cache + OS headroom).
- [New-VM.ps1](../vde/host.windows.hyper-v/guest.squid-cache/New-VM.ps1) —
  creates a Hyper-V Gen 2 VM named `squid-cache` on the Default Switch,
  attaches a cloud-init seed ISO that installs and configures squid,
  starts the VM, and waits until port 3128 responds. Prints the proxy
  URL when ready.

### macOS UTM

```bash
cd ~/git/yuruna/vde/host.macos.utm/guest.squid-cache
pwsh ./Get-Image.ps1
pwsh ./New-VM.ps1
```

- [Get-Image.ps1](../vde/host.macos.utm/guest.squid-cache/Get-Image.ps1) —
  downloads the Ubuntu Server Noble cloud image (arm64, qcow2),
  converts it to raw via `qemu-img convert`, and resizes to 144 GB. Raw
  format is required by Apple Virtualization.framework.
- [New-VM.ps1](../vde/host.macos.utm/guest.squid-cache/New-VM.ps1) —
  assembles a UTM bundle at
  `~/Desktop/Yuruna.VDE/<hostname>.nosync/squid-cache.utm/` containing
  `config.plist` (Apple Virtualization backend), `Data/efi_vars.fd`
  (Virtualization.framework Swift API), `Data/disk.img` (APFS-clone of
  the raw cloud image), and `Data/seed.iso` (cloud-init user-data via
  `hdiutil`). Double-click the `.utm` file to register it with UTM,
  then start the VM.

### Finding the cache VM's IP

| Host | Method |
|------|--------|
| **Hyper-V** | `Get-VM squid-cache \| Get-VMNetworkAdapter` on the host, or reuse the IP `New-VM.ps1` printed when the VM came up. |
| **UTM** | (a) open the UTM window and read the `eth0: <ip>` line at the console login prompt; (b) `awk -F'[ =]' '/name=squid-cache/{f=1} f && /ip_address/{print $NF; exit}' /var/db/dhcpd_leases`; (c) port-scan 192.168.64.2-30 for a :3128 listener. `utmctl ip-address` does **not** work for Apple Virtualization-backed VMs (UTM's CLI only supports it for QEMU guests). |

### Pre-warm on first boot

After squid starts, cloud-init points the VM's own apt at
`http://127.0.0.1:3128` and runs `apt-get install --download-only --reinstall`
for `linux-firmware`, the HWE kernel meta, and (amd64 only)
`intel-microcode`, `amd64-microcode`, `firmware-sof-signed`. Those .debs
flow through squid and land in its cache. Without this step the *first*
guest install still races `security.ubuntu.com`'s 429 rate limiter for
`linux-firmware` (~330 MB) — squid can't serve what it hasn't seen yet.

Expect **5-15 minutes** for first-boot prewarm (depends on upstream
bandwidth). Once prewarm finishes, cloud-init flips squid into
[offline_mode](#offline_mode).

## How guest VMs use it

At seed-ISO creation time, each guest's `New-VM.ps1` discovers the cache
and writes its URL into the autoinstall `apt.proxy` field **and** a
persistent apt proxy dropin inside the installed target. Subiquity's
in-install apt calls, cloud-init's first-boot `openssh-server` install,
and every subsequent `apt-get` flow through the cache.

### Discovery

| Host | Method |
|------|--------|
| **Hyper-V** | `Get-VM squid-cache` → IP via ARP on Default Switch (matched by MAC) or Hyper-V KVP, then TCP-probe :3128. |
| **UTM** | `utmctl status squid-cache` → if `started`, subnet-probe 192.168.64.2-30 for a :3128 listener. (`utmctl ip-address` returns "Operation not supported by the backend" on Apple Virtualization VMs; subnet probe works regardless.) Fallback subnet probe runs even when `utmctl` is missing. |

### Severity policy

Silent fallback-to-CDN can't mask a 429:

- **No cache VM registered / not running** → **WARNING**, install
  proceeds against Ubuntu's CDN.
- **Cache VM running but :3128 unreachable** → **ERROR**, `exit 1`. Fix
  it (cloud-init, squid, firewall) before retrying. Prevents the exact
  429 failures the cache was meant to prevent.

No changes to `test-config.json` or the test sequences are needed.

See [test/CachingProxy.md](../test/CachingProxy.md) for the test-harness
operator reference — how `Invoke-TestRunner.ps1`,
`Start-CachingProxy.ps1`, and `Test-CachingProxy.ps1` surface the cache
to remote clients, consume `YURUNA_CACHING_PROXY_IP`, and preflight a
candidate cache before a run.

## Cache configuration

Squid is tuned as a **replayable snapshot**: once an object lands it
stays, and the cache keeps serving even when origin is unreachable. Once
fully populated it supports guest installs with **zero internet access**.

The config lives in
[vde/host.windows.hyper-v/guest.squid-cache/vmconfig/user-data](../vde/host.windows.hyper-v/guest.squid-cache/vmconfig/user-data)
and
[vde/host.macos.utm/guest.squid-cache/vmconfig/user-data](../vde/host.macos.utm/guest.squid-cache/vmconfig/user-data)
— same squid settings in both.

### Never release unless needed

- `cache_swap_high 99` / `cache_swap_low 98` — eviction only starts
  above 99% full and stops at 98%. Default 90/95 would release objects
  with ~5 GB free space remaining.
- `cache_replacement_policy heap LFUDA` +
  `memory_replacement_policy heap GDSF` — when eviction runs, LFUDA /
  GDSF retain large, frequently-used blobs (linux-firmware, kernels)
  and drop rarely-touched small objects first. Expensive-to-refetch
  content survives.
- `quick_abort_min -1 KB` — if a client disconnects mid-download, squid
  finishes the fetch rather than discarding the partial object. The
  next client gets a cache hit.

### Serve stale, never serve failures

- `negative_ttl 0 seconds` — do not cache 4xx/5xx responses. A transient
  blip during one install must not turn into a poisoned 504 served
  forever for an object squid could otherwise fetch successfully.
- Aggressive `refresh_pattern` overrides for content-addressable files
  (`.deb .udeb .tar.xz .tar.gz .tar.bz2 .iso`):
  `override-expire override-lastmod ignore-reload ignore-no-store ignore-must-revalidate ignore-private`.
  These force squid to keep serving cached copies regardless of origin
  `Cache-Control` or client `no-cache` hints. Apt metadata (`InRelease`,
  `Packages`, `Release`, `Sources`) uses a shorter TTL so apt still
  sees fresh package lists during prewarm.

### offline_mode

After prewarm, cloud-init writes `/etc/squid/conf.d/yuruna-offline.conf`:

```
offline_mode on
```

and runs `squid -k reconfigure`. From that point on, **squid never
contacts origin**:

- Cache hit → served from disk.
- Cache miss → `504 Gateway Timeout`.

This is what makes the fully-disconnected workflow real: as long as
every URL is already cached, the guest can install with no internet on
the host. If something's missing (new package version, new repo entry)
you get a clean 504 pointing at the exact URL — no confusion about
whether it came from cache or origin.

`offline_mode` is flipped on **after** prewarm because an empty cache +
offline_mode returns 504 on the very first request, preventing prewarm
from populating anything.

### Refreshing the cache against origin

Two recipes:

**Temporary** — serve from origin for one burst, then go back offline:

```bash
ssh ubuntu@<squid-cache-ip>
sudo rm /etc/squid/conf.d/yuruna-offline.conf
sudo squid -k reconfigure
# ... do whatever apt-get update etc. you need ...
echo "offline_mode on" | sudo tee /etc/squid/conf.d/yuruna-offline.conf
sudo squid -k reconfigure
```

**Full rebuild** — wipe everything and re-prewarm from scratch:

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

The VM runs three monitoring services alongside squid itself:

| Service         | Port | Binding                  | Purpose                                                          |
|-----------------|------|--------------------------|------------------------------------------------------------------|
| Grafana OSS     | 3000 | 0.0.0.0                  | Primary dashboard UI; anonymous Viewer (no login).               |
| Prometheus      | 9090 | 127.0.0.1                | Metrics datastore; accessed via Grafana.                         |
| squid-exporter  | 9301 | 127.0.0.1                | Prometheus exporter; reads squid cachemgr over :3128.            |
| cachemgr.cgi    | 80   | 0.0.0.0, RFC1918 ACL     | Raw cachemgr UI; kept as a fallback.                             |
| CA cert         | 80   | 0.0.0.0                  | `/yuruna-squid-ca.crt` served by Apache.                         |
| Squid HTTP      | 3128 | 0.0.0.0, RFC1918 ACL     | Plain-HTTP proxy + HTTPS CONNECT tunnel (no caching of bodies).  |
| Squid HTTPS     | 3129 | 0.0.0.0, RFC1918 ACL     | SSL-bump listener — caches HTTPS bodies.                         |

### Grafana (primary UI)

```
http://<squid-cache-vm-ip>:3000
```

Opens directly to anonymous Viewer — **no login step**. The
pre-provisioned "Squid Cache (yuruna)" dashboard includes:

- **Client HTTP(S) requests/sec** — `rate(squid_client_http_requests_total[5m])`
- **Client HTTP(S) hits/sec** — `rate(squid_client_http_hits_total[5m])`

  There is no HTTPS-specific client counter — squid-exporter reads
  squid's own `client_http.*` counters which aggregate HTTP and HTTPS
  (via CONNECT and ssl-bump) into the same family — hence "HTTP(S)" in
  every panel title. A true protocol split would need a different
  exporter that parses `access.log`. Also: boynux/squid-exporter
  appends `_kbytes_total` — not `_total` — for kbyte counters, so the
  bytes panel below queries `squid_client_http_kbytes_out_kbytes_total`;
  the simpler-looking `_kbytes_out_total` does not exist and renders
  "No data".
- **Client HTTP(S) data served (kB/s): total vs cached** — full-width
  timeseries, two series on one axis:
  - `Total` — `rate(squid_client_http_kbytes_out_kbytes_total[5m])`
  - `Cached` — `rate(squid_client_http_hit_kbytes_out_bytes_total[5m])`

  The vertical gap between the lines is traffic that went through the
  host's outside pipe to origin. Squid's cachemgr exposes the hit bytes
  directly as `client_http.hit_kbytes_out` — no hit-ratio multiplication,
  no guessing.

  Watch the suffix: boynux/squid-exporter is inconsistent about unit
  labels. `client_http.kbytes_out` → `_kbytes_total` (Total query) but
  `client_http.hit_kbytes_out` → `_bytes_total` (Cached query), despite
  both values still being reported in kbytes by squid. Both series are
  on the same kB/s scale. Writing the Cached query as
  `..._hit_kbytes_out_kbytes_total` is the fast-path mistake — the
  series doesn't exist, only the Total line renders, Cached shows "No
  data." Verify the actual metric name with:
  `curl -s http://127.0.0.1:9301/metrics | grep hit_kbytes_out`.

To edit dashboards, log in with `admin` / `admin` (Grafana's default;
the install doesn't rotate it because the VM is reachable only on the
private Hyper-V/UTM switch). The datasource is provisioned with UID
`yuruna-prometheus` so custom dashboards can reference it without
knowing Grafana's auto-generated UID.

Grafana is the self-hosted OSS build, installed from
`apt.grafana.com stable main` — no account, no Grafana Cloud.

### Prometheus

Bound to loopback only — not reachable from the host. SSH into the VM
first:

```bash
ssh ubuntu@<squid-cache-vm-ip>
curl 'http://127.0.0.1:9090/api/v1/query?query=up'
```

Or use Grafana's **Explore** view (top-left menu → Explore) to run
ad-hoc PromQL without exposing Prometheus. The scrape config in
`/etc/prometheus/prometheus.yml` polls `localhost:9090` (self) and
`localhost:9301` (squid-exporter) every 15 s.

### squid-exporter

The [boynux/squid-exporter](https://github.com/boynux/squid-exporter)
binary runs as `squid-exporter.service` and speaks Squid's cache-manager
protocol to `localhost:3128`. Built from source during cloud-init via
`go install` (no stable apt package, no stable GitHub release-asset URL)
— that's why `golang-go` briefly appears in the package list; the
toolchain is purged at end of runcmd once the static binary lands in
`/usr/local/bin/squid-exporter`.

### cachemgr.cgi (fallback)

The original raw cachemgr UI is available as a debugging fallback when
Prometheus or Grafana are down:

```
http://<squid-cache-vm-ip>/cgi-bin/cachemgr.cgi
```

Leave **Cache Host** as `localhost` and **Cache Port** as `3128` on the
form. Useful reports:

- `info` — overall stats, uptime, total/client requests
- `utilization` — hit ratio broken down over 5/60 minutes
- `storedir` — disk-cache occupancy
- `mem` — memory-pool usage
- `client_list` — which guest IPs have proxied through
- `objects` — list cached URLs (big page on a busy cache)

Access is restricted to RFC1918 sources at the Apache layer, and
Squid's default ACL allows the `manager` scheme only from `localhost` —
only host and local-network callers reach this page.

### CLI

For quick checks from inside the VM:

```bash
ssh ubuntu@<squid-cache-vm-ip>
sudo squidclient mgr:info           # overall stats
sudo squidclient mgr:utilization    # hit ratios
sudo squidclient mgr:5min           # 5-minute rolling stats
sudo tail -f /var/log/squid/access.log   # per-request trace
```

The third-to-last field of `access.log` is `TCP_HIT`, `TCP_MISS`,
`TCP_OFFLINE_HIT`, etc. — a quick way to confirm the cache is serving.

### Purging a single cached entry

The `yuruna.conf` drop-in (written by cloud-init) enables the `PURGE`
method for RFC1918 sources via a method-scoped ACL. Invalidate one URL
without nuking the whole cache, using either `squidclient` (installed
by cloud-init) or plain `curl`:

```bash
# From inside the cache VM:
sudo squidclient -m PURGE http://<origin-host>:<port>/<path>

# From any RFC1918 workstation on the same LAN:
squid-cli purge http://<cache-vm-ip>:3128 http://<origin-host>:<port>/<path>
# or without squid-cli:
curl -x http://<cache-vm-ip>:3128 -X PURGE http://<origin-host>:<port>/<path>
```

A successful purge returns `HTTP/1.1 200 OK`. `404 Not Found` means the
object wasn't in the cache (safe no-op). For total cache wipes, stop
squid, `rm -rf /var/spool/squid/*`, and `squid -z` to re-initialize —
see the init steps in the squid-cache user-data.

## Access / credentials

Cloud-init configures the default `ubuntu` user with:

- **Password** — a fresh random 10-char alphanumeric string, generated
  by `New-VM.ps1` on every rebuild. It is:
  - printed in the script's output banner when the cache is ready,
  - saved to a local file:
    - **Hyper-V**: `<HyperVVHDPath>\squid-cache\squid-cache-password.txt`
      (typically `C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\squid-cache\squid-cache-password.txt`),
    - **UTM**: `~/virtual/squid-cache/squid-cache-password.txt`
      (chmod 600, owner-only),
  - baked into the seed.iso's `user-data` (`chpasswd` module).

  Password expiry is disabled, so repeated console or
  `ssh -o PreferredAuthentications=password` sessions keep working
  without an interactive reset. A new random password is generated on
  every `New-VM.ps1` run — the old one is overwritten. (Using the
  static string `password` for every rebuild caused browser password
  managers to cache and auto-suggest it against cachemgr.cgi, producing
  repeated popups.)

- **SSH key** — the yuruna test-harness public key (generated/cached at
  `test/.ssh/yuruna_ed25519` by
  [Test.Ssh.psm1](../test/modules/Test.Ssh.psm1)).
  `ssh ubuntu@<squid-cache-ip>` works passwordless from the host.

Both paths exist because this VM is most often debugged when it
*hasn't* finished cloud-init yet — SSH isn't up, only the console. The
password isn't a secret: the VM is reachable only on the private
Hyper-V Default Switch or UTM Shared NAT (not externally routable), and
squid itself restricts access to RFC1918 sources.

## Management

The cache VM is independent of the test harness. It is **not** created
or destroyed by [Invoke-TestRunner.ps1](../test/Invoke-TestRunner.ps1).

### Windows Hyper-V

- **Start**: `Start-VM squid-cache`
- **Stop**: `Stop-VM squid-cache`
- **Delete**: `Stop-VM squid-cache -Force; Remove-VM squid-cache -Force`,
  then delete the `squid-cache` folder under the Hyper-V VHDX path.
- **Auto-start on host boot**:
  `Set-VM squid-cache -AutomaticStartAction Start`

### macOS UTM

- **Start / Stop**: `utmctl start squid-cache` /
  `utmctl stop squid-cache`, or the UTM GUI.
- **Delete**: stop the VM, right-click → Delete in UTM, then
  `rm -rf ~/Desktop/Yuruna.VDE/<hostname>.nosync/squid-cache.utm`.

### Both hosts

- **Clear cache** (wipe all stored objects, keep the VM):
  ```bash
  ssh ubuntu@<squid-cache-ip>
  sudo systemctl stop squid
  sudo rm -rf /var/spool/squid/*
  sudo squid -z -N
  sudo systemctl start squid
  ```
- **Inspect hits/misses**: `sudo tail -f /var/log/squid/access.log`
  inside the VM, or use the Grafana dashboard.
- **Reload squid config** (after editing `/etc/squid/conf.d/*`):
  `sudo squid -k reconfigure`.

## HTTPS caching

Shipped on both Hyper-V and UTM.

The cache VM runs a second squid listener on `:3129` that performs
**SSL-bump** — squid terminates TLS with a locally-generated CA, caches
the plaintext bodies through the same `refresh_pattern` and
`offline_mode` pipeline as HTTP, and re-encrypts on the way out with a
per-SNI leaf cert it mints on the fly. Guests that trust the CA get
HTTPS apt traffic cached; everything else (including guests that don't
trust the CA) keeps using `:3128` with CONNECT tunneling and no caching
— nothing regresses.

### Key / cert material

Generated once by cloud-init on first boot (idempotent — a re-run does
**not** rotate the CA, which would orphan already-trusted guests):

| Path                                 | Contents                                                    |
|--------------------------------------|-------------------------------------------------------------|
| `/etc/squid/ssl_cert/ca.key`         | 2048-bit RSA private key, `proxy:proxy 600`. VM-local only. |
| `/etc/squid/ssl_cert/ca.pem`         | Self-signed CA cert (10 years). CN includes hostname + UTC timestamp. |
| `/var/lib/squid/ssl_db/`             | `security_file_certgen` DB of per-SNI leaf certs (4 MB). |
| `/var/www/html/yuruna-squid-ca.crt`  | Copy of the public cert, served by Apache.                  |

The public cert is published at
`http://<cache-vm-ip>/yuruna-squid-ca.crt` by the same Apache that
serves `cachemgr.cgi`. Only the public cert is exposed — `ca.key`
never leaves the cache VM.

### Guest trust flow

The two platforms use different delivery paths because Apple VZ's
shared-NAT blocks guest↔guest traffic — a UTM guest can't reach the
cache VM's IP directly. On macOS the host pre-fetches the CA and embeds
it in the autoinstall seed instead of having the guest fetch it
late-command-side.

**Hyper-V (in-install wget):** `vmconfig/user-data` for each guest runs
this inside `late-commands` when a proxy was injected by `New-VM.ps1`:

1. Derive the cache host from the proxy URL (strip `http://` and `:3128`).
2. `wget http://<cache>/yuruna-squid-ca.crt` into
   `/target/usr/local/share/ca-certificates/yuruna-squid-ca.crt`.
3. `curtin in-target -- update-ca-certificates` so the installed system
   trusts it.
4. Append `Acquire::https::Proxy "http://<cache>:3129";` to the
   existing `/target/etc/apt/apt.conf.d/99yuruna-apt-cache` dropin.

Best-effort — if CA fetch fails, the guest keeps the HTTP proxy and
lets HTTPS apt go direct. No install abort.

**UTM (host-side pre-fetch + base64 in seed):** `guest.ubuntu.*/New-VM.ps1`
runs on the host, reads `$HOME/virtual/squid-cache/cache-ip.txt`
(written by `Start-CachingProxy.ps1`) or
`$Env:YURUNA_CACHING_PROXY_IP` if set, fetches
`http://<ip>/yuruna-squid-ca.crt`, base64-encodes it, and splices it
into the autoinstall seed as `CA_CERT_BASE64_PLACEHOLDER`. The guest's
`late-commands` then:

1. `printf '%s' "<base64>" | base64 -d > /target/.../yuruna-squid-ca.crt`
2. `curtin in-target -- update-ca-certificates`
3. Append `Acquire::https::Proxy "http://192.168.64.1:3129";` — the
   VZ gateway, not the cache VM IP, because the host-side `:3129`
   forwarder (started by `Start-CachingProxy.ps1`) is the only path
   guests have to reach the ssl-bump listener.

Empty placeholder → no-op, HTTPS apt bypasses the cache. Same
degrade-gracefully semantics as Hyper-V.

### Where caching actually kicks in

- **Subiquity in-install HTTPS calls** (kernel, firmware) — still via
  `:3128` CONNECT, **not cached**. The CA isn't in the installer
  environment's trust store during subiquity's apt step; only the
  target chroot gets it.
- **Guest first-boot + all post-install apt** — HTTPS traffic routes
  through `:3129`, gets bumped, and lands in squid's on-disk cache
  alongside the HTTP content.
- **Non-apt HTTPS** (browsers, `curl`, snap, Go binaries) — untouched.
  The CA is in the system trust store, but nothing in the guest is
  configured to route non-apt traffic through squid.

### ssl_bump rules

Minimum viable recipe: `peek step1` → `bump all`. Squid reads the TLS
ClientHello for the SNI hostname, then intercepts. If a pin-checking
client (snap, Go HTTPS) ends up on the install path, add an
`acl nobump dstdomain ...` + `ssl_bump splice nobump` pair **above**
the bump-all line rather than disabling bumping wholesale — see the
`/etc/squid/conf.d/yuruna.conf` dropin.
