# Caching proxy — test-harness operator reference

Operator-facing reference for the test-harness scripts that front the
Squid cache VM: exposing it to remote clients, pointing a test host at
a remote cache, and preflighting the whole setup before a full run.

For the conceptual background — what the cache VM does, how it's set
up, cache configuration, HTTPS/SSL-bump, monitoring, access credentials,
and the `YurunaCacheContent` URL cache-buster — see the canonical
**[docs/caching.md](../docs/caching.md)**. This file assumes you have
already created the cache VM as described there.

## Severity policy

Silent fallback-to-CDN can't mask a 429:

- **No cache VM registered / not running** → **WARNING**, install proceeds
  against Ubuntu's CDN.
- **Cache VM running but :3128 unreachable** → **ERROR**, `exit 1`. The
  operator must fix it (check cloud-init, squid, firewall) before
  retrying. This prevents the exact 429 failures the cache was meant to
  prevent.

No changes to `test-config.json` or the test sequences are needed.

## Serving remote clients

A fresh cache VM is only reachable from its own host (Hyper-V Default
Switch / UTM Shared NAT). To let a **different machine** on the LAN use
the same cache — developer laptop, second test host, etc. —
[Start-CachingProxy.ps1](Start-CachingProxy.ps1) forwards the VM's ports
onto the host's interfaces. Every port the harness or an operator may
touch is exposed: :3128 (HTTP proxy + HTTPS CONNECT), :3129 (ssl-bump),
:80 (Apache + `/yuruna-squid-ca.crt`), :3000 (Grafana).

### Windows Hyper-V

Re-run `Start-CachingProxy.ps1` from an **elevated** PowerShell:

```powershell
cd $HOME\git\yuruna\test
pwsh .\Start-CachingProxy.ps1
```

The script calls `Add-CachingProxyPortMap` which issues `netsh interface
portproxy add v4tov4 ...` for each port and adds a matching
`Yuruna-CachingProxy-Port-<N>` inbound firewall rule. Without elevation
the portproxy and firewall calls are skipped with a warning and the
cache stays reachable only from guests on the Default Switch.

Remote clients then point at the host's LAN IP — for example,
`http://<host-lan-ip>:3128` for apt, or
`http://<host-lan-ip>/yuruna-squid-ca.crt` to download the CA.

### macOS UTM

Re-run with `sudo` so the :80 forwarder can bind the privileged port:

```bash
cd ~/git/yuruna/test
sudo -E pwsh ./Start-CachingProxy.ps1
```

`sudo -E` preserves `$HOME` so the forwarder's state files land in the
user's `~/virtual/squid-cache/`, not `/var/root/virtual/...`. Without
sudo the script still runs; :3128, :3129, :3000 forwarders launch
unprivileged, but :80 is skipped with a warning:

> `Add-CachingProxyPortMap: port 80 is privileged on macOS; skipping.
> Re-run under sudo to expose it to remote clients.`

HTTP caching and HTTPS body caching via :3129 still work for the local
host's guests. Only the remote CA-cert download at
`http://<mac-ip>/yuruna-squid-ca.crt` is unavailable in that mode.

### Squid ACL

Squid itself accepts only RFC1918 source IPs (`10/8`, `172.16/12`,
`192.168/16`) per the ACL in each `guest.squid-cache/vmconfig/user-data`.
LAN clients are covered; a client on a routable public IP would still
be denied even if firewall + portproxy let the packets through. The
cache is not an open internet proxy and is not meant to be.

## External cache override

A client machine can **use** a remote cache (instead of hosting one) by
setting a single environment variable before running the harness:

```powershell
# Windows
$Env:YURUNA_CACHING_PROXY_IP = '10.0.0.5'   # IP of the remote caching proxy host
```

```bash
# macOS
export YURUNA_CACHING_PROXY_IP=10.0.0.5
```

When this variable is set, [Invoke-TestRunner.ps1](Invoke-TestRunner.ps1)
and [Start-StatusServer.ps1](Start-StatusServer.ps1) skip local
cache-VM discovery and route everything through the remote IP. The
guest `New-VM.ps1` scripts (both desktop and server) inherit the URL,
fetch the CA from `http://<remote>/yuruna-squid-ca.crt`, and configure
apt with:

- `apt.proxy = http://<remote>:3128` (HTTP)
- `Acquire::https::Proxy "http://<remote>:3129";` (HTTPS body caching)

The remote host is assumed to run the same caching proxy image described
in [docs/caching.md](../docs/caching.md). No guest, runner, or
status-server config changes are needed beyond the env var. Un-set the
variable (or set it to an empty string) to fall back to local discovery.

## Validating before a run

[Test-CachingProxy.ps1](Test-CachingProxy.ps1) probes every port the runner
relies on and reports PASS/FAIL/WARN per check — runnable from any
machine, even without Hyper-V / UTM installed. Use it to confirm a
candidate remote cache is healthy **before** starting a full test cycle:

```powershell
$Env:YURUNA_CACHING_PROXY_IP = '10.0.0.5'
pwsh test/Test-CachingProxy.ps1
# === Summary: 5 PASS, 0 WARN, 0 FAIL ===
```

Or probe an ad-hoc IP without exporting the variable:

```powershell
pwsh test/Test-CachingProxy.ps1 -CacheIp 10.0.0.5
```

With no arguments and no env var, the script falls back to local
discovery (same path `Invoke-TestRunner.ps1` uses) and probes whatever
`Start-CachingProxy.ps1` brought up. Exit code is `1` when any required
port fails — suitable for a preflight `&&` chain.
