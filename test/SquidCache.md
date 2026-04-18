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
2. **Squid tunnels HTTPS (CONNECT) by default.** apt-cacher-ng refuses
   CONNECT and broke `wget https://...` calls in late-commands. Squid
   passes them through (without caching the body — caching HTTPS
   requires SSL-bump, see [Future: HTTPS caching](#future-https-caching)).

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
| Squid           | 3128 | 0.0.0.0, RFC1918 ACL     | The proxy itself.                                                |

### Grafana (primary UI)

```
http://<squid-cache-vm-ip>:3000
```

Opens directly to anonymous Viewer — **no login step**. The
pre-provisioned "Squid Cache (yuruna)" dashboard includes:

- **Scrape targets up** — confirms Prometheus is reaching both itself
  and `squid-exporter`. If either shows 0, something in the stack is
  down.
- **Client HTTP requests/sec** — `rate(squid_client_http_requests_total[5m])`
- **Client HTTP hits/sec** — `rate(squid_client_http_hits_total[5m])`
- **Client HTTP kbytes_out/sec** — `rate(squid_client_http_kbytes_out_total[5m])`

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

## Future: HTTPS caching

The current config tunnels HTTPS via `CONNECT` without caching the
encrypted bodies. Caching HTTPS would require **SSL-bump**: squid
terminates TLS with a locally-generated CA, caches the plaintext, and
re-encrypts on the way out. That CA's certificate must be installed in
every guest's trust store — straightforward via cloud-init
`write_files` + `update-ca-certificates`. Not yet implemented.
