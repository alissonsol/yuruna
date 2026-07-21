# Caching proxy — test-harness operator reference

Wrappers around the Squid cache VM: exposing it to remote clients,
pointing a test host at a remote cache, preflighting before a run.
Cache-VM concepts (setup, config, HTTPS/SSL-bump, monitoring, credentials,
`YurunaCacheContent`) are in [Caching](caching.md).

## Why a separate cache VM

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

## Rebuild, adopt-if-healthy, and the bring-up lock

`Start-CachingProxy.ps1` **adopts a healthy proxy by default** instead of
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
concurrent `Start-CachingProxy` runs, or a bring-up racing the runner's
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

| Role | Typical hold | Timeout behaviour |
| --- | --- | --- |
| `rebuild` (`Start-CachingProxy`) | ~15 min | Bounded wait, long enough to absorb a runner's sub-second port-map hold; a live holder still there past the bound means fail-fast. |
| `portmap` (runner `Add-PortMap`) | ~1 s | Try-once (`TimeoutSeconds 0`). If a rebuild holds the lock, the runner skips this cycle's port-map — the rebuild owns the maps and the cache is down mid-rebuild anyway — and re-applies on the next cycle. |

The adopt-or-rebuild decision itself is a pure function over the proxy VM's
state plus a health probe, wrapped by a thin I/O layer that resolves
`Get-VMState` / `Read-CachingProxyState` / `Invoke-CachingProxyProbe` at call
time behind `Get-Command` guards, so the decision stays testable without a VM.

## Cache VM sizing

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

## Cache-VM password persistence

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

1. If the runtime state file has a password, `Set-Password 'yuruna'` from it.
2. `Get-Password 'yuruna'` returns either the rehydrated value or a fresh
   random one (first-ever install).
3. Write the value back to the runtime state file (idempotent on rebuild).

## Cache-VM NAS and config service

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
- **Pool push-ingest shared bearer** — the operator-supplied token gating
  the aggregator's `POST /ingest`, mirroring the ypool-nas loud-fail
  gate. It is read ONLY when the operator declared a vaultKey for
  `pool-auth-token` AND populated it (`Test-VaultEntry`); an empty
  vaultKey means push is DISABLED, and calling `Get-Password` then would
  auto-generate a per-host random token and break the shared-token
  model. Baked EMPTY when disabled/unset — the aggregator refuses
  `/ingest`.
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

## Severity policy

Preflight severity — WARNING when no cache VM is registered/running,
ERROR when one is running but `:3128` is unreachable — is documented once
in [Caching → Severity policy](caching.md#severity-policy). No changes to
`test.config.yml` or sequences are needed.

## Serving remote clients

A fresh cache VM is only reachable from its own host (Hyper-V Default
Switch / UTM Shared NAT). To let a different LAN machine use it,
[Start-CachingProxy.ps1](../test/Start-CachingProxy.ps1) forwards the VM's
ports onto the host's interfaces: `:3128` (HTTP + HTTPS CONNECT), `:3129`
(ssl-bump), `:80` (Apache + CA cert), `:3000` (Grafana).

**Windows Hyper-V** (elevated PowerShell):

```
cd $HOME\git\yuruna\test
pwsh .\Start-CachingProxy.ps1
```

`Add-PortMap` issues `netsh interface portproxy add v4tov4`
per port and adds a matching `Yuruna-CachingProxy-Port-<N>` inbound
firewall rule. Without elevation the portproxy/firewall calls are
skipped with a warning and the cache stays reachable only from guests
on the Default Switch.

**macOS UTM** (sudo required to bind `:80`):

```
cd ~/git/yuruna/test
sudo -E pwsh ./Start-CachingProxy.ps1
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

## Pinning the cache VM's IP (stable MAC + DHCP reservation)

Every `Start-CachingProxy.ps1` run rebuilds the VM with a fresh random
MAC, so the DHCP server leases a new IP each time and consumers must
re-discover it. There is no reliable way to *request* a specific IP
from DHCP across the three hypervisors (on the preferred bridged
networks the DHCP server is the LAN router, which no host API can
program), so the supported path keeps DHCP as the source of truth and
pins the *MAC* instead:

```
pwsh ./Start-CachingProxy.ps1 -MacAddress 02:11:22:33:44:55
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

## External cache override

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

## Port-map dispatch by host topology

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
   created (no LAN, Wi-Fi-only).

Per-port platform divergence in branch 3:

| Concern | Windows | macOS |
|---------|---------|-------|
| Port-map atomicity | `netsh portproxy` clears all ports at once (`Clear-AllCachingProxyPortMapping`), so every port the host should expose must appear in every caller's list. | Per-port pidfile; callers manage subsets independently. |
| Port 80 (Apache + CA cert) | Included in the runner's list. | **Excluded** — `:80` (<1024) needs root, and `Start-CachingProxy.ps1` is the only caller that pre-caches sudo. |
| HTTP / HTTPS forwarder shape | `host:HTTP → VM:HTTP` / `host:HTTPS → VM:HTTPS` via plain `netsh portproxy`. | `host:HTTP → VM:3138` / `host:HTTPS → VM:3139` via userspace pwsh forwarder + PROXY v1 header — squid logs real client IPs. |

`Yuruna.Host`'s `Test-CacheVMOnExternalNetwork` is the discriminator:
on Windows it checks for any External-type vSwitch; on macOS it
always returns `$true` (VMnet shared). So branches 2 and 3 are
Windows-only in practice — macOS always takes branch 2.

The "detected" word printed at startup is an ANSI OSC 8 hyperlink to
the Grafana dashboard so modern terminals (Windows Terminal, VS Code)
can ctrl-click into the caching-proxy view. Terminals without OSC 8
drop the escapes silently.

## Validating before a run

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

## Promoting to the host system proxy

`Test-CachingProxy.ps1 -SetHostProxy` repoints WinINet (Windows) or
networksetup (macOS) at the cache so every host-side
`Invoke-WebRequest` / `curl` / `git` flows through it. The previous
proxy state is snapshotted to `~/.yuruna/host-proxy.backup.json` and
restored by `Stop-CachingProxy.ps1`.

Yuruna also writes a "managed" marker (HKCU registry value on
Windows, `~/.yuruna/host-proxy.managed` on macOS) so a re-promotion
across a missing backup file recognizes the existing state as
Yuruna's own and snapshots it as clean — without the marker, a lost
backup turned every subsequent `Stop-CachingProxy` +
`Test-CachingProxy.ps1 -SetHostProxy` cycle into a self-loop because
the contaminated snapshot kept getting restored. `Start-CachingProxy.ps1`
also clears any leftover Yuruna proxy state at startup, so a fresh
provision never inherits a stale `ProxyServer` from a prior cycle.

## In-process proxy env var hygiene at provision time

`Start-CachingProxy.ps1`'s whole job is to *bring up* the cache, so
every network call it makes (Get-Image's `Invoke-WebRequest`,
`Save-CachedHttpUri`'s no-cache fall-through, `virt-install` fetching
osinfo, `qemu-img`/`genisoimage` reaching the public internet) must
go DIRECTLY to the public Internet. .NET's `HttpClient` honors
`HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` from the process
environment. If the caller's shell exports any of those pointing at
a cache IP that no longer hosts squid (stale after a
host reboot, wrong LAN, or a cache VM destroyed by
`Stop-CachingProxy.ps1`), every download fails with "Network is
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

## Migrating to a replacement cache VM

How to replace the Squid cache VM (host retirement, resize, newer base
image) without ever serving clients from a cold cache.
[Move-CachingProxy.ps1](../test/Move-CachingProxy.ps1) builds a
temporary parent-child Squid hierarchy — the NEW cache fetches its
misses from the OLD cache's warm store at LAN speed — and later tears
it down and retires the old VM. Cache-VM concepts are in
[Caching](caching.md). Short link:
<https://yuruna.link/caching-proxy-migration>.

### Why migrate warm

A cold cache re-fights the battle the cache VM exists to win: every
fresh-VM install hammers the Ubuntu CDN and container registries until
429 rate limits stretch a ~2 min warm install to ~30 min or fail it
outright (see [why a separate cache VM](#why-a-separate-cache-vm)).
Warming the new cache from the old one keeps every hot object served
from disk on the LAN, and only true misses go to the origin — once,
from one VM.

### How it works

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

### Prerequisites

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

### Starting the copy cycle

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

### While the hierarchy runs

As clients use the new cache, its misses fill from the old cache and
the old cache's request rate decays naturally — typically a few days
for the hot set. Watch the drain:

```
ssh yuruna@<old>
sudo tail -f /var/log/squid/access.log
```

Both VMs also expose their Grafana dashboards on `:3000`.

### Ending the copy cycle

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
     host-proxy promotion): `pwsh test/Stop-CachingProxy.ps1` on that
     host.
   - Keep the powered-off VM for a grace period; rollback is booting
     it and `sudo systemctl enable --now squid`. Delete the VM and its
     disk once the new cache has proven itself.

Re-running `-End` is safe: already-done parts are skipped with a note.

### Resilience model

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

### Troubleshooting

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

Last review: 2026.07.21

Back to [Yuruna](../README.md)
