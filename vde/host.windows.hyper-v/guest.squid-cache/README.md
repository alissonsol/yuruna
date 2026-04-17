# Squid Cache VM (Hyper-V)

Optional local HTTP caching proxy for Ubuntu Desktop (and other) test-VM
installations.

## What it does

Runs [Squid](https://www.squid-cache.org/) inside a lightweight Ubuntu
Server VM (2 GB RAM, 4 vCPU, 50 GB disk). The VM listens on port 3128
and transparently caches every cacheable HTTP response that flows
through it — `.deb` packages, ISO metadata files, firmware blobs, and
anything else the installer (or the workload running inside the guest)
fetches over plain HTTP. The first install populates the cache; every
subsequent install of the same package pulls from the local VM at disk
speed.

This replaces the previous apt-cacher-ng setup. Two reasons for the
pivot:

1. **Squid caches more.** apt-cacher-ng only recognizes apt-shaped URLs.
   Subiquity's kernel install step (`apt-get install linux-firmware`,
   etc.) happens before the late-command that wires the cache into the
   target system, so those downloads went direct and were the main
   source of intermittent `429 Too Many Requests` errors from
   `security.ubuntu.com`. A generic HTTP proxy caches those too.
2. **Squid tunnels HTTPS (CONNECT) by default.** apt-cacher-ng refuses
   CONNECT and broke `wget https://...` calls in late-commands. Squid
   passes them through (without caching the body — caching HTTPS
   requires SSL-bump with a generated CA trusted by each guest, tracked
   as a follow-up enhancement).

## Setup

Run once from an elevated PowerShell:

```powershell
cd $HOME\git\yuruna\vde\host.windows.hyper-v\guest.squid-cache
pwsh .\Get-Image.ps1
pwsh .\New-VM.ps1
```

`Get-Image.ps1` downloads the Ubuntu Server Noble cloud image (amd64),
converts it from qcow2 to VHDX via `qemu-img`, and resizes it to 50 GB
for cache storage.

`New-VM.ps1` creates a Hyper-V Gen 2 VM named `squid-cache` on the
Default Switch, attaches a cloud-init seed ISO that installs and
configures squid, starts the VM, and waits until port 3128 responds.
The script prints the proxy URL when ready.

**Pre-warm on first boot.** After squid starts, cloud-init points the
VM's own apt at `http://127.0.0.1:3128` and runs `apt-get install
--download-only --reinstall` for `linux-firmware`, the HWE kernel meta,
`intel-microcode`, `amd64-microcode`, and `firmware-sof-signed`. Those
.debs flow through squid on the way in and land in its cache. Without
this step the *first* guest install still races `security.ubuntu.com`'s
429 rate limiter for `linux-firmware` (~330 MB) — squid can't serve
what it hasn't seen yet. Pre-warm adds ~2-10 minutes to the one-time
`New-VM.ps1` run, depending on upstream bandwidth.

## How guest VMs use it

At seed-ISO creation time, the Ubuntu Desktop
[`New-VM.ps1`](../guest.ubuntu.desktop/New-VM.ps1) calls
`Get-VM squid-cache`, discovers the cache VM's IP via ARP (scoped to the
Default Switch interface, matched by MAC) or Hyper-V KVP, and TCP-probes
port 3128. When reachable, `http://<ip>:3128` gets substituted into the
autoinstall `apt.proxy` field **and** into a persistent apt proxy dropin
inside the installed target. Subiquity's own apt-get calls during
install, cloud-init's first-boot openssh-server install, and every
subsequent `apt-get` in the guest all flow through the cache.

Severity policy (so silent fallback-to-CDN can't mask a 429):
- **No `squid-cache` VM / stopped** → WARNING, install proceeds against
  Ubuntu's CDN
- **Cache VM running but port 3128 unreachable** → ERROR, `exit 1`
  (the operator must fix it — check cloud-init, squid, firewall —
  before retrying the guest install)

No changes to `test-config.json` or the test sequences are needed.

## Monitoring — cachemgr.cgi

The VM bundles **Apache + squid-cgi** so Squid's built-in cache manager
is reachable from a browser:

```
http://<squid-cache-vm-ip>/cgi-bin/cachemgr.cgi
```

Find the IP with `Get-VM squid-cache | Get-VMNetworkAdapter` on the
Hyper-V host, or reuse the IP `New-VM.ps1` printed when the VM came up.

The first page is a form. Leave **Cache Host** as `localhost` and
**Cache Port** as `3128` — cachemgr.cgi connects to squid from inside
the VM, so that's where the manager listens. Submit to get the menu
of reports. The useful ones for this setup:

- **info** — overall stats, uptime, total/client requests
- **utilization** — hit ratio broken down over 5/60 minutes
- **storedir** — disk-cache occupancy (i.e. are we near the 40 GB cap)
- **mem** — memory-pool usage
- **client_list** — which guest IPs have been proxying through
- **objects** — list cached URLs (big page on a busy cache)

Access is restricted to RFC1918 sources at the Apache layer
([`yuruna-cachemgr.conf`](vmconfig/user-data)), and Squid's own default
ACL allows the `manager` scheme only from `localhost`. So the Hyper-V
host (and any guest on the same Default Switch) can reach the page; the
wider internet cannot, even if the VM were somehow exposed.

For CLI access from inside the VM, `sudo squidclient mgr:info` (or
`mgr:5min`, `mgr:utilization`, etc.) returns the same data without the
web UI.

## Access / credentials

Cloud-init configures the default `ubuntu` user with:

- **Password**: a fresh random 10-char alphanumeric string, generated by
  `New-VM.ps1` on every rebuild. The password is
  - printed in the script's output banner when the cache is ready,
  - saved to `<HyperVVHDPath>\squid-cache\squid-cache-password.txt`
    (typically `C:\ProgramData\Microsoft\Windows\Virtual Hard Disks\squid-cache\squid-cache-password.txt`),
  - baked into the seed.iso's `user-data` (`chpasswd` module).

  Password expiry is disabled, so repeated console or
  `ssh -o PreferredAuthentications=password` sessions keep working
  without an interactive reset. A new random password is generated on
  every `New-VM.ps1` run — the old one is overwritten.

  (Before: we used the static string `password` for every rebuild, which
  caused browser password managers to cache and auto-suggest it against
  cachemgr.cgi and produce repeated popups. Random per-rebuild prevents
  that.)
- **SSH key**: the yuruna test-harness public key (generated/cached at
  `test/.ssh/yuruna_ed25519` by [Test.Ssh.psm1](../../../test/modules/Test.Ssh.psm1)).
  `ssh ubuntu@<squid-cache-ip>` works passwordless from the host.

Both paths exist because this VM is most often debugged when it *hasn't*
finished cloud-init yet — SSH isn't up at that point, only the text
console. Treating the password as a secret is inappropriate: this VM is
reachable only on the Hyper-V Default Switch (NAT, not externally
routable), and squid itself restricts access to RFC1918 sources.

## Management

The cache VM is independent of the test harness. It is not created or
destroyed by `Invoke-TestRunner.ps1`.

- **Start**: `Start-VM squid-cache`
- **Stop**: `Stop-VM squid-cache`
- **Delete**: `Stop-VM squid-cache -Force; Remove-VM squid-cache -Force`
  then delete the `squid-cache` folder under the Hyper-V VHDX path.
- **Clear cache**: SSH into the VM and run
  `sudo systemctl stop squid && sudo rm -rf /var/spool/squid/* && sudo squid -z -N && sudo systemctl start squid`
- **Inspect hits/misses**: `sudo tail -f /var/log/squid/access.log`
  inside the VM. The third-to-last field is `TCP_HIT`, `TCP_MISS`, etc.,
  or use the cachemgr.cgi page above for aggregate views.

The VM survives host reboots if Hyper-V auto-start is configured
(`Set-VM squid-cache -AutomaticStartAction Start`).

## Future: HTTPS caching

The current config tunnels HTTPS via `CONNECT` without caching the
encrypted bodies. To cache HTTPS too (e.g. GitHub release tarballs,
Microsoft package feeds), squid supports SSL-bump: it terminates TLS
with a locally generated CA, caches the plaintext, and re-encrypts on
the way out. That CA's certificate must be installed in every guest's
trust store, which is straightforward via cloud-init write_files +
`update-ca-certificates`. Not yet implemented.

Back to [[Windows Hyper-V Host Setup](../README.md)]
