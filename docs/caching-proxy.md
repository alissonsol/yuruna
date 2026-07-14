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

## Cache VM sizing

Every host's caching-proxy `New-VM.ps1` creates the cache VM with **12 GB
RAM, 4 vCPU** — matched explicitly across Hyper-V, macOS UTM, and Ubuntu
KVM so a cache rebuilt on any host has the same headroom.

This is a DEDICATED cache VM (one job: serve the squid object cache to
every guest), so the memory budget is sized around squid's `cache_mem 9 GB`
(= 75 % of VM RAM, per the `host/vmconfig/caching-proxy.base.user-data`
tuning). Empirically a 1 GB `cache_mem` on this VM put squid's RSS at
~2 GB during active cycles (sslcrtd children + connection buffers + in-RAM
hot objects = ~1 GB beyond `cache_mem`), so 9 GB `cache_mem` implies
~10 GB peak squid + ~1.5 GB for the rest of the stack (apache, grafana,
prometheus, loki, promtail, squid-exporter, caching-proxy-parser, systemd,
page cache). 12 GB leaves ~500 MB of OS headroom.

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

## External cache override

A client machine uses a remote cache by exporting one env var:

```
# Windows
$Env:YURUNA_CACHING_PROXY_IP = '10.0.0.5'
```

```
# macOS
export YURUNA_CACHING_PROXY_IP=10.0.0.5
```

When set, [Invoke-TestRunner.ps1](../test/Invoke-TestRunner.ps1) and
[Start-StatusService.ps1](../test/Start-StatusService.ps1) skip local discovery and
route everything through the remote IP. Guest `New-VM.ps1` inherits the
URL, fetches the CA from `http://<remote>/yuruna-squid-ca.crt`, and
configures apt with:

- `apt.proxy = http://<remote>:3128` (HTTP)
- `Acquire::https::Proxy "http://<remote>:3129";` (HTTPS body caching)

Un-set (or empty) to fall back to local discovery.

## Port-map dispatch by host topology

`Invoke-TestInnerRunner.ps1` picks one of three branches when wiring
clients up to the cache:

1. **External cache** (`$Env:YURUNA_CACHING_PROXY_IP` set). The remote
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

With no arguments and no env var, falls back to local discovery (same
path `Invoke-TestRunner.ps1` uses). Exit 1 on any required-port failure
— suitable for a `&&` chain.

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
environment. If the caller's shell exports any of those pointing at a
previous cycle's cache IP that no longer hosts squid (stale after a
host reboot, wrong LAN, or a cache VM that just got destroyed by
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
the remote-cache override) is still set in the next shell. Step 1's
`Remove-HostProxy` handles the persistent OS-level state (WinINet
registry, `/etc/environment`, `networksetup`); this in-process gap is
what `Remove-HostProxy` cannot reach. The behavior is uniform across
ubuntu.kvm / windows.hyper-v / macos.utm — all three run the same
.NET `HttpClient`.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.14

Back to [Yuruna](../README.md)
