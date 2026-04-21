# Caching proxy — test-harness operator reference

Wrappers around the Squid cache VM: exposing it to remote clients,
pointing a test host at a remote cache, preflighting before a run.
Cache-VM concepts (setup, config, HTTPS/SSL-bump, monitoring, credentials,
`YurunaCacheContent`) are in [../docs/caching.md](../docs/caching.md).

## Severity policy

Silent fallback-to-CDN can't mask a 429:

- **No cache VM registered / not running** → **WARNING**, proceed to CDN.
- **Cache VM running but `:3128` unreachable** → **ERROR**, exit 1.

No changes to `test-config.json` or sequences are needed.

## Serving remote clients

A fresh cache VM is only reachable from its own host (Hyper-V Default
Switch / UTM Shared NAT). To let a different LAN machine use it,
[Start-CachingProxy.ps1](Start-CachingProxy.ps1) forwards the VM's
ports onto the host's interfaces: `:3128` (HTTP + HTTPS CONNECT), `:3129`
(ssl-bump), `:80` (Apache + CA cert), `:3000` (Grafana).

**Windows Hyper-V** (elevated PowerShell):

```powershell
cd $HOME\git\yuruna\test
pwsh .\Start-CachingProxy.ps1
```

`Add-CachingProxyPortMap` issues `netsh interface portproxy add v4tov4`
per port and adds a matching `Yuruna-CachingProxy-Port-<N>` inbound
firewall rule. Without elevation the portproxy/firewall calls are
skipped with a warning and the cache stays reachable only from guests
on the Default Switch.

**macOS UTM** (sudo required to bind `:80`):

```bash
cd ~/git/yuruna/test
sudo -E pwsh ./Start-CachingProxy.ps1
```

`sudo -E` preserves `$HOME` so state files land in
`~/virtual/squid-cache/`, not `/var/root/...`. Without sudo the script
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

```powershell
# Windows
$Env:YURUNA_CACHING_PROXY_IP = '10.0.0.5'
```

```bash
# macOS
export YURUNA_CACHING_PROXY_IP=10.0.0.5
```

When set, [Invoke-TestRunner.ps1](Invoke-TestRunner.ps1) and
[Start-StatusServer.ps1](Start-StatusServer.ps1) skip local discovery and
route everything through the remote IP. Guest `New-VM.ps1` inherits the
URL, fetches the CA from `http://<remote>/yuruna-squid-ca.crt`, and
configures apt with:

- `apt.proxy = http://<remote>:3128` (HTTP)
- `Acquire::https::Proxy "http://<remote>:3129";` (HTTPS body caching)

Un-set (or empty) to fall back to local discovery.

## Validating before a run

[Test-CachingProxy.ps1](Test-CachingProxy.ps1) probes every port the
runner relies on and reports PASS/FAIL/WARN — runnable from any machine,
even without Hyper-V / UTM installed:

```powershell
$Env:YURUNA_CACHING_PROXY_IP = '10.0.0.5'
pwsh test/Test-CachingProxy.ps1
# === Summary: 5 PASS, 0 WARN, 0 FAIL ===

pwsh test/Test-CachingProxy.ps1 -CacheIp 10.0.0.5   # ad-hoc, no env var
```

With no arguments and no env var, falls back to local discovery (same
path `Invoke-TestRunner.ps1` uses). Exit 1 on any required-port failure
— suitable for a `&&` chain.
