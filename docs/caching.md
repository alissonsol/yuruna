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
[`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh),
[`automation/Invoke-FetchAndExecute.ps1`](../automation/Invoke-FetchAndExecute.ps1),
and `wget`/`curl` calls in each `virtual/guest.*/` install script. The
fetch-and-execute wrappers also honor an explicit `EXEC_QUERY_PARAMS`
override (used verbatim, takes precedence).

The variable is read by whichever shell expands the URL — it is **not**
auto-pushed into guest VMs. Set it again inside the guest to cache-bust
guest install scripts.

---

## Squid cache VM

Optional local HTTP/HTTPS caching proxy packaged as a standalone VM.
Works identically on Windows Hyper-V and macOS UTM.

### What it does

Ubuntu Server VM (4 GB RAM, 4 vCPU, 144 GB disk — 128 GB for the squid
cache) on `:3128`, transparently caching every cacheable response (`.deb`
packages, ISO metadata, firmware blobs, anything fetched over plain
HTTP). First install populates; subsequent installs hit LAN speed.

### Why Squid replaced apt-cacher-ng

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
| **Hyper-V** | `Get-VM squid-cache` → IP via ARP on Default Switch (matched by MAC) or KVP, then TCP-probe `:3128`. |
| **UTM** | `utmctl status squid-cache` → if `started`, subnet-probe 192.168.64.2-30. Fallback subnet probe runs even without `utmctl`. |

### Severity policy

Silent fallback-to-CDN can't mask a 429:

- **No cache VM registered / not running** → **WARNING**, proceed against CDN.
- **Cache VM running but `:3128` unreachable** → **ERROR**, exit 1.

See [../test/CachingProxy.md](../test/CachingProxy.md) for the test-harness
operator reference.

## Cache configuration

Squid is tuned as a **replayable snapshot**: once an object lands, it
stays; the cache keeps serving when origin is unreachable. Fully
populated = guest installs with zero internet.

Config lives in
`virtual/host.{windows.hyper-v,macos.utm}/guest.squid-cache/vmconfig/user-data`
(identical settings in both).

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
hit → disk; cache miss → `504`. This enables the fully-disconnected
workflow and points clearly at the missing URL on a miss. The flip
happens **after** prewarm because empty cache + `offline_mode` = 504 on
every request.

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
Viewer. Pre-provisioned "Yuruna Caching Proxy" dashboard:

- Client HTTP(S) requests/sec — `rate(squid_client_http_requests_total[5m])`
- Client HTTP(S) hits/sec — `rate(squid_client_http_hits_total[5m])`
- Data served (kB/s) — Total:
  `rate(squid_client_http_kbytes_out_kbytes_total[5m])`,
  Cached: `rate(squid_client_http_hit_kbytes_out_bytes_total[5m])`.
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
`/var/log/squid/access.log` and ships every line to Loki on
`127.0.0.1:3100` with the single stream label `job=squid`. Retention
capped at 7d. Verify with
`curl -G 'http://127.0.0.1:3100/loki/api/v1/query_range' --data-urlencode 'query={job="squid"}' --data-urlencode 'limit=5'`.

**squid-exporter** — [boynux/squid-exporter](https://github.com/boynux/squid-exporter)
speaks squid's cache-manager protocol on `localhost:3128`. Built from
source during cloud-init (`go install`); `golang-go` is purged once
the static binary lands in `/usr/local/bin/squid-exporter`.

**cachemgr.cgi (fallback)** — `http://<vm-ip>/cgi-bin/cachemgr.cgi`,
Cache Host `localhost`, Port `3128`. Reports: `info`, `utilization`,
`storedir`, `mem`, `client_list`, `objects`. Restricted to RFC1918 at
Apache; squid's `manager` ACL allows only `localhost`.

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

Cloud-init creates a single `yuruna` debug user (replaces the cloud
image's default `ubuntu` — `users:` without a `- default` entry
suppresses ubuntu creation):

- **Password** — fresh 10-char alphanumeric per `New-VM.ps1`. Printed
  in the ready banner, saved to
  `<HyperVVHDPath>\squid-cache\squid-cache-password.txt` (Windows) or
  `~/virtual/squid-cache/squid-cache-password.txt` (UTM, chmod 600),
  baked into the seed via `chpasswd`. Expiry disabled. Regenerated on
  every rebuild (a static password let browser password managers
  auto-suggest it against cachemgr.cgi).
- **SSH key** — harness public key from `test/.ssh/yuruna_ed25519` via
  [Test.Ssh.psm1](../test/modules/Test.Ssh.psm1). `ssh yuruna@<ip>` is
  passwordless from the host.
- **Sudo** — passwordless (`NOPASSWD:ALL`). VM is on a private switch,
  RFC1918-only.

### Reaching the cache from outside the host (port 8022)

`Start-CachingProxy.ps1` adds an `8022 -> 22` host port forward
alongside the squid/Grafana ones:

```bash
ssh -p 8022 yuruna@<host-lan-ip>     # -> cache VM :22
```

Port 8022 (not 22) avoids colliding with the host's own sshd. Managed
the same way as :80 / :3000 — netsh portproxy + Yuruna firewall rule on
Windows, detached pwsh TcpListener on macOS — re-applied by every caller
of `Add-CachingProxyPortMap` (test runner, status server, repair script).

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
[`Start-CachingProxyForwarder.ps1`](../virtual/host.macos.utm/Start-CachingProxyForwarder.ps1)
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
[`virtual/host.windows.hyper-v/VM.common.psm1`](../virtual/host.windows.hyper-v/VM.common.psm1)
exposes `Get-OrCreateYurunaExternalSwitch`, which idempotently creates
`Yuruna-External` bound to the host's primary physical NIC (default
IPv4 route, `-AllowManagementOS:$true` so the host keeps its own
network);
[`guest.squid-cache/New-VM.ps1`](../virtual/host.windows.hyper-v/guest.squid-cache/New-VM.ps1)
calls it on every provision and falls back to `Default Switch` if no
LAN-routed NIC is available. The cache VM then gets a real LAN IP via
DHCP; remote clients hit `<cache-lan-ip>:3128` directly — squid sees
real client IPs at TCP level, no PROXY protocol needed.

Constraints: a wired NIC works best; Wi-Fi APs typically refuse frames
for MACs they didn't authenticate, so DHCP may fail on a Wi-Fi-only
host (the helper warns). The cache VM is on the LAN broadcast domain —
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

When `Get-OrCreateYurunaExternalSwitch` cannot create the External
switch (no LAN-routable NIC, Wi-Fi-only host, switch creation skipped),
the cache VM lands on the built-in `Default Switch` and the test/
scripts re-enable netsh portproxy. LAN clients reach `<host-lan-ip>:3128`
and squid logs the host's vEthernet IP — the source-IP-loss gap kept as
a fallback, not a default. `Test-CacheVmOnYurunaExternalSwitch` in
[`VM.common.psm1`](../virtual/host.windows.hyper-v/VM.common.psm1) is
the runtime detection switch.

##### Windows: App Execution Alias self-heal (latent)

[`Test.PortMap.psm1`](../test/modules/Test.PortMap.psm1) carries a
self-heal for one Windows path-resolution failure mode: after
`Start-WindowsCachingProxyForwarder` spawns pwsh, it reads
`(Get-Process -Id <pid>).Path` and rewrites the per-program firewall
rule, in case `Get-Command pwsh` returned a Microsoft Store App
Execution Alias stub. Not exercised today (the External-vSwitch path
doesn't use the userspace forwarder on Windows) — kept ready.

Implementation:
* macOS — `-PrependProxyV1` on
  [`Start-CachingProxyForwarder.ps1`](../virtual/host.macos.utm/Start-CachingProxyForwarder.ps1),
  wired through `-ProxyProtocolPort` on `Add-CachingProxyPortMap` in
  [`Test.PortMap.psm1`](../test/modules/Test.PortMap.psm1).
* Windows — `Get-OrCreateYurunaExternalSwitch` and
  `Test-CacheVmOnYurunaExternalSwitch` in
  [`VM.common.psm1`](../virtual/host.windows.hyper-v/VM.common.psm1),
  consumed by
  [`guest.squid-cache/New-VM.ps1`](../virtual/host.windows.hyper-v/guest.squid-cache/New-VM.ps1)
  and by the Windows branches of
  [`Start-CachingProxy.ps1`](../test/Start-CachingProxy.ps1),
  [`Invoke-TestRunner.ps1`](../test/Invoke-TestRunner.ps1), and
  [`Start-StatusServer.ps1`](../test/Start-StatusServer.ps1).

The console password isn't a secret: squid's `http_access` ACL restricts
proxy use to RFC1918. The VM is most often debugged before cloud-init
finishes (Apache, squid, Grafana, Prometheus all install over apt) —
console fallback via `vmconnect` is the normal path during that window.

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

**Hyper-V (in-install wget):** when `New-VM.ps1` injected a proxy,
`vmconfig/user-data` `late-commands`:

1. Derive cache host from proxy URL (strip `http://` and `:3128`).
2. `wget http://<cache>/yuruna-squid-ca.crt` into
   `/target/usr/local/share/ca-certificates/`.
3. `curtin in-target -- update-ca-certificates`.
4. Append `Acquire::https::Proxy "http://<cache>:3129";` to
   `/target/etc/apt/apt.conf.d/99yuruna-apt-cache`.

Best-effort: if CA fetch fails, the guest keeps HTTP proxy and lets
HTTPS apt go direct.

**UTM (host pre-fetch + base64 in seed):** `guest.ubuntu.*/New-VM.ps1`
reads `$HOME/virtual/squid-cache/cache-ip.txt` (written by
`Start-CachingProxy.ps1`) or `$Env:YURUNA_CACHING_PROXY_IP`, fetches
the CA, base64-encodes it, and splices into the seed as
`CA_CERT_BASE64_PLACEHOLDER`. Guest `late-commands`:

1. `printf '%s' "<base64>" | base64 -d > /target/.../yuruna-squid-ca.crt`
2. `curtin in-target -- update-ca-certificates`
3. `Acquire::https::Proxy "http://192.168.64.1:3129";` — the VZ gateway,
   not the cache IP, because the host-side `:3129` forwarder (from
   `Start-CachingProxy.ps1`) is the only path guests have.

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
