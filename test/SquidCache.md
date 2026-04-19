# Squid Cache VM

Optional local HTTP caching proxy for Ubuntu Desktop (and other) test-VM
installations, packaged as a standalone VM that runs alongside the test
harness. This document is the canonical reference for the squid-cache VM
on both Windows Hyper-V and macOS UTM hosts.

## What it does

Runs [Squid](https://www.squid-cache.org/) inside a lightweight Ubuntu
Server VM (4 GB RAM, 4 vCPU, 144 GB disk — 128 GB of which is squid's
on-disk cache). The VM listens on port 3128 and transparently caches
every cacheable HTTP response that flows through it — `.deb` packages,
ISO metadata files, firmware blobs, and anything else the installer (or
the workload running inside the guest) fetches over plain HTTP. The
first install populates the cache; every subsequent install of the same
package pulls from the local VM at disk speed.

### Why it replaced apt-cacher-ng

1. **Squid caches more.** apt-cacher-ng only recognizes apt-shaped URLs.
   Subiquity's kernel install step (`apt-get install linux-firmware`,
   etc.) happens before the late-command that wires the cache into the
   target system, so those downloads went direct and were the main
   source of intermittent `429 Too Many Requests` errors from
   `security.ubuntu.com`. A generic HTTP proxy caches those too.
2. **Squid tunnels HTTPS (CONNECT) by default** and — on Hyper-V —
   also **caches HTTPS** via a second SSL-bump listener on `:3129` (see
   [HTTPS caching](#https-caching)). apt-cacher-ng refused CONNECT and
   broke `wget https://...` in late-commands; Squid passes those through
   unchanged on `:3128` and, for clients that trust the local CA,
   transparently caches the bodies on `:3129`.

### Why the cache matters more on macOS

All UTM VMs running in Apple Virtualization's Shared network mode NAT
out through the host's single public IP. When the test harness runs
cycles back-to-back, every install hits `security.ubuntu.com` from that
same IP and trips the CDN's per-source rate limit much faster than on
Hyper-V (where the host also NATs, but typically there's one guest in
flight). A local Squid intercepts those requests so the first install
populates the cache and every subsequent install pulls `.deb` packages
from LAN at disk speed.

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
flow through squid on the way in and land in its cache. Without this
step the *first* guest install still races `security.ubuntu.com`'s 429
rate limiter for `linux-firmware` (~330 MB) — squid can't serve what it
hasn't seen yet.

Expect **5-15 minutes** for first-boot prewarm (depends on upstream
bandwidth). Once prewarm finishes, cloud-init flips squid into
[offline_mode](#offline_mode).

## How guest VMs use it

At seed-ISO creation time, each guest's `New-VM.ps1` discovers the cache
and writes its URL into the autoinstall `apt.proxy` field **and** into a
persistent apt proxy dropin inside the installed target. Subiquity's
in-install apt calls, cloud-init's first-boot `openssh-server` install,
and every subsequent `apt-get` in the guest flow through the cache.

### Discovery

| Host | Method |
|------|--------|
| **Hyper-V** | `Get-VM squid-cache` → IP via ARP on Default Switch (matched by MAC) or Hyper-V KVP, then TCP-probe :3128. |
| **UTM** | `utmctl status squid-cache` → if `started`, subnet-probe 192.168.64.2-30 for a :3128 listener. (`utmctl ip-address` returns "Operation not supported by the backend" on Apple Virtualization VMs; subnet probe works regardless.) Fallback subnet probe runs even when `utmctl` is missing. |

### Severity policy

Silent fallback-to-CDN can't mask a 429:

- **No cache VM registered / not running** → **WARNING**, install proceeds
  against Ubuntu's CDN.
- **Cache VM running but :3128 unreachable** → **ERROR**, `exit 1`. The
  operator must fix it (check cloud-init, squid, firewall) before
  retrying. This prevents the exact 429 failures the cache was meant to
  prevent.

No changes to `test-config.json` or the test sequences are needed.

## Cache configuration

The squid config is tuned so the cache behaves as a **replayable
snapshot**: once an object lands it stays, and the cache keeps serving
even when origin is unreachable. Once fully populated, the cache
supports guest installs with **zero internet access**.

The config lives in
[vde/host.windows.hyper-v/guest.squid-cache/vmconfig/user-data](../vde/host.windows.hyper-v/guest.squid-cache/vmconfig/user-data)
and
[vde/host.macos.utm/guest.squid-cache/vmconfig/user-data](../vde/host.macos.utm/guest.squid-cache/vmconfig/user-data) —
both files carry the same squid settings.

### Never release unless needed

- `cache_swap_high 99` / `cache_swap_low 98` — eviction only starts when
  the disk is >99% full, stops once it's down to 98%. Default 90/95
  would release objects as soon as ~5 GB of free space remained.
- `cache_replacement_policy heap LFUDA` +
  `memory_replacement_policy heap GDSF` — when eviction does run, LFUDA
  / GDSF retain large, frequently-used blobs (linux-firmware, kernels)
  and drop rarely-touched small objects first. The expensive-to-refetch
  content survives.
- `quick_abort_min -1 KB` — if a client disconnects mid-download, squid
  finishes the fetch rather than discarding the partial object. The
  next client gets a cache hit.

### Serve stale, never serve failures

- `negative_ttl 0 seconds` — do not cache 4xx/5xx responses. A transient
  blip during one install must not turn into a poisoned 504 served
  forever for an object squid could otherwise fetch successfully next
  time.
- Aggressive `refresh_pattern` overrides for content-addressable files
  (`.deb .udeb .tar.xz .tar.gz .tar.bz2 .iso`):
  `override-expire override-lastmod ignore-reload ignore-no-store ignore-must-revalidate ignore-private`.
  These force squid to keep serving cached copies regardless of origin
  `Cache-Control` or client `no-cache` hints. Apt metadata
  (`InRelease`, `Packages`, `Release`, `Sources`) uses a shorter TTL so
  that during prewarm apt still sees fresh package lists.

### offline_mode

After the prewarm phase completes, cloud-init writes
`/etc/squid/conf.d/yuruna-offline.conf`:

```
offline_mode on
```

and runs `squid -k reconfigure`. From that point on, **squid never
contacts origin** for any object:

- Cache hit → served from disk.
- Cache miss → `504 Gateway Timeout`.

This is what makes the fully-disconnected workflow real: as long as
every URL a guest install requests is already in the cache, the guest
can install with no internet on the host. If something's missing (new
package version, new repository entry), you get a clean 504 pointing at
the exact URL — no confusion about whether it came from cache or origin.

`offline_mode` is flipped on **after** prewarm because an empty cache +
offline_mode returns 504 on the very first request, which would prevent
prewarm from populating anything.

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
| CA cert         | 80   | 0.0.0.0                  | `/yuruna-squid-ca.crt` served by Apache (Hyper-V only).          |
| Squid HTTP      | 3128 | 0.0.0.0, RFC1918 ACL     | Plain-HTTP proxy + HTTPS CONNECT tunnel (no caching of bodies).  |
| Squid HTTPS     | 3129 | 0.0.0.0, RFC1918 ACL     | SSL-bump listener — caches HTTPS bodies (Hyper-V only).          |

### Grafana (primary UI)

```
http://<squid-cache-vm-ip>:3000
```

Opens directly to anonymous Viewer — **no login step**. The
pre-provisioned "Squid Cache (yuruna)" dashboard includes:

- **Scrape targets up** — confirms Prometheus is reaching both itself
  and `squid-exporter`. If either shows 0, something in the stack is
  down.
- **Client HTTP(S) requests/sec** — `rate(squid_client_http_requests_total[5m])`
- **Client HTTP(S) hits/sec** — `rate(squid_client_http_hits_total[5m])`
- **Client HTTP(S) kbytes_out/sec** — `rate(squid_client_http_kbytes_out_kbytes_total[5m])`
  (boynux/squid-exporter appends `_kbytes_total` — not `_total` — for
  counters whose units are kbytes. Writing the panel query with the
  simpler-looking `_kbytes_out_total` is the fast-path mistake; the
  series simply doesn't exist and the panel renders "No data".)
- **Client HTTP(S) kbytes_in/sec** — `rate(squid_client_http_kbytes_in_kbytes_total[5m])`
  Symmetric ingress counterpart to kbytes_out. Note: there is no
  HTTPS-specific client counter — squid-exporter reads squid's own
  `client_http.*` counters, which aggregate HTTP and HTTPS (via CONNECT
  and ssl-bump) into the same family. Panel titles use "HTTP(S)" to
  reflect that the underlying counter covers both. A true protocol split
  would need a different exporter that parses `access.log` (e.g. a squid
  log exporter).
- **Client HTTP(S) data served (last 1h)** — stat panel,
  `increase(squid_client_http_kbytes_out_kbytes_total[1h])` with unit
  `kbytes` so Grafana auto-scales KB → MB → GB (1024-based, matching
  squid's internal accounting). Answers "how much did the proxy serve in
  the last hour" at a glance. `increase()` can under-read by roughly one
  scrape interval at the window edges — fine for an operator dashboard,
  not for billing.

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
binary runs as `squid-exporter.service` and speaks Squid's
cache-manager protocol to `localhost:3128`. It's built from source
during cloud-init via `go install` (no stable apt package, no stable
GitHub release-asset URL), which is why `golang-go` briefly appears in
the package list — the toolchain is purged at the end of runcmd once
the static binary is in `/usr/local/bin/squid-exporter`.

### cachemgr.cgi (fallback)

The original raw cachemgr UI is still available as a debugging fallback
when Prometheus or Grafana are down or being iterated on:

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
so only host and local-network callers reach this page.

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

## Access / credentials

Cloud-init configures the default `ubuntu` user with:

- **Password** — a fresh random 10-char alphanumeric string, generated
  by `New-VM.ps1` on every rebuild. The password is:
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
  [Test.Ssh.psm1](modules/Test.Ssh.psm1)).
  `ssh ubuntu@<squid-cache-ip>` works passwordless from the host.

Both paths exist because this VM is most often debugged when it
*hasn't* finished cloud-init yet — SSH isn't up at that point, only the
console. Treating the password as a secret is inappropriate: the VM is
reachable only on the private Hyper-V Default Switch or UTM Shared NAT
(not externally routable), and squid itself restricts access to RFC1918
sources.

## Management

The cache VM is independent of the test harness. It is **not** created
or destroyed by [Invoke-TestRunner.ps1](Invoke-TestRunner.ps1).

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

**Hyper-V: shipped. UTM: still a follow-up.**

On Hyper-V the cache VM runs a second squid listener on `:3129` that
performs **SSL-bump** — squid terminates TLS with a locally-generated
CA, caches the plaintext bodies through the same `refresh_pattern` and
`offline_mode` pipeline used for HTTP, and re-encrypts on the way out
with a per-SNI leaf cert it mints on the fly. Guests that trust the CA
get HTTPS apt traffic cached; everything else (including any guest that
doesn't trust the CA) keeps using `:3128` with CONNECT tunneling and no
caching, so nothing regresses.

### Key / cert material

Generated once by cloud-init on first boot of the squid-cache VM
(idempotent — a re-run does **not** rotate the CA, which would orphan
already-trusted guests):

| Path                                 | Contents                                                    |
|--------------------------------------|-------------------------------------------------------------|
| `/etc/squid/ssl_cert/ca.key`         | 2048-bit RSA private key, `proxy:proxy 600`. VM-local only. |
| `/etc/squid/ssl_cert/ca.pem`         | Self-signed CA cert (10 years). CN includes hostname + UTC timestamp. |
| `/var/lib/squid/ssl_db/`             | `security_file_certgen` DB of per-SNI leaf certs (4 MB). |
| `/var/www/html/yuruna-squid-ca.crt`  | Copy of the public cert, served by Apache.                  |

The public cert is published at
`http://<cache-vm-ip>/yuruna-squid-ca.crt` on the same Apache that
serves `cachemgr.cgi`. Only the public cert is exposed — `ca.key`
never leaves the cache VM.

### Guest trust flow

`vmconfig/user-data` for each Hyper-V guest (desktop and server) runs
this inside the `late-commands` block when a proxy was injected by
`New-VM.ps1`:

1. Derive the cache host from the proxy URL (strip `http://` and `:3128`).
2. `wget http://<cache>/yuruna-squid-ca.crt` into
   `/target/usr/local/share/ca-certificates/yuruna-squid-ca.crt`.
3. `curtin in-target -- update-ca-certificates` so the installed system
   trusts it.
4. Append `Acquire::https::Proxy "http://<cache>:3129";` to the
   existing `/target/etc/apt/apt.conf.d/99yuruna-apt-cache` dropin.

Every path is best-effort — if CA fetch fails (older cache build, Apache
down, etc.) the guest keeps the HTTP proxy, logs a `yuruna:` warning,
and lets HTTPS apt go direct. No install abort, no regression.

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

The minimum viable recipe: `peek step1` → `bump all`. Squid reads the
TLS ClientHello to learn the SNI hostname, then intercepts. If a
pin-checking client (snap, Go HTTPS) ends up on the install path, add
an `acl nobump dstdomain ...` + `ssl_bump splice nobump` pair **above**
the bump-all line rather than disabling bumping wholesale — see the
`/etc/squid/conf.d/yuruna.conf` dropin for where to edit.

### UTM: not implemented

The macOS/UTM `guest.squid-cache/vmconfig/user-data` does not yet carry
the SSL-bump block. Plain-HTTP caching and HTTPS CONNECT tunneling work
as before; HTTPS body caching is the next follow-up.
