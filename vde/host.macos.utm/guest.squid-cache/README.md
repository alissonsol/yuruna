# Squid Cache VM (macOS UTM)

Optional local HTTP caching proxy for Ubuntu Desktop (and other) test-VM
installations.

## Why this matters more on macOS

All UTM VMs running in Apple Virtualization's Shared network mode NAT
out through the host's single public IP. When the test harness runs
cycles back-to-back, every install hits `security.ubuntu.com` from
that same IP and trips the CDN's per-source rate limit much faster
than on Hyper-V (where the host also NATs, but typically there's one
guest in flight). A local Squid intercepts those requests so the
first install populates the cache and every subsequent install pulls
`.deb` packages from LAN at disk speed.

This replaces the earlier apt-cacher-ng setup on the macOS side. See
the top-level Hyper-V [README](../../host.windows.hyper-v/guest.squid-cache/README.md)
for the full rationale; the pivot (Squid caches more URL shapes, and
tunnels HTTPS via CONNECT) is the same here.

## Setup

```bash
cd ~/git/yuruna/vde/host.macos.utm/guest.squid-cache
pwsh ./Get-Image.ps1
pwsh ./New-VM.ps1
```

`Get-Image.ps1` downloads the Ubuntu Server Noble cloud image
(arm64, qcow2), converts it to raw via `qemu-img convert`, and resizes
it to 144 GB for cache storage (128 GB squid cache + OS headroom).
The raw format is required by Apple
Virtualization.framework.

`New-VM.ps1` assembles a UTM bundle at
`~/Desktop/Yuruna.VDE/<hostname>.nosync/squid-cache.utm/` containing:

- `config.plist` (Apple Virtualization backend, 4 GB RAM / 4 vCPU)
- `Data/efi_vars.fd` (created via the Virtualization.framework Swift API)
- `Data/disk.img` (APFS-clone of the pre-built raw cloud image)
- `Data/seed.iso` (cloud-init metadata + user-data, produced via `hdiutil`)

Double-click the `.utm` file to register it with UTM, then start the
VM. Cloud-init installs squid, apache2, and squid-cgi on first boot
and **pre-warms** the cache by pulling `linux-firmware` (the main 429
offender) and the HWE kernel meta through the local proxy. Expect
5-15 minutes on first boot depending on upstream bandwidth.

Once running, find the VM's IP. `utmctl ip-address` does **not** work
for Apple Virtualization-backed VMs (UTM's CLI only supports it for
QEMU guests); use one of these instead:

```bash
# (a) simplest — open the UTM window for squid-cache and read the
#     "eth0: <ip>" line the Linux console prints at the login prompt.

# (b) Apple's shared-NAT DHCP leases file (usually user-readable):
awk -F'[ =]' '/name=squid-cache/{f=1} f && /ip_address/{print $NF; exit}' \
    /var/db/dhcpd_leases

# (c) port-scan the Shared-NAT subnet for a squid listener on :3128
#     — works regardless of what the VM called itself:
for i in $(seq 2 30); do
  nc -z -w 1 192.168.64.$i 3128 2>/dev/null && echo "squid at 192.168.64.$i"
done
```

## How guest VMs use it

At seed-ISO creation time, the Ubuntu Desktop
[`New-VM.ps1`](../guest.ubuntu.desktop/New-VM.ps1) checks for the cache
in this order:

1. `utmctl status squid-cache` — if the VM is registered with UTM
2. If status is `started`, subnet-probe 192.168.64.2-30 for a TCP
   listener on port 3128. (`utmctl ip-address` is NOT used — it
   returns "Operation not supported by the backend" on Apple
   Virtualization VMs; the subnet probe works regardless.)
3. If utmctl isn't installed (neither on PATH nor at
   `/Applications/UTM.app/Contents/MacOS/utmctl`), falls back to the
   same subnet probe for alternate setups

When the cache is reachable, `http://<ip>:3128` gets substituted into
the autoinstall `apt.proxy` field **and** into a persistent apt proxy
dropin inside the installed target. Subiquity's in-install apt calls,
cloud-init's first-boot `openssh-server` install, and every subsequent
`apt-get` in the guest all flow through the cache.

Severity policy (so silent fallback-to-CDN can't mask a 429):
- **No cache VM registered / not started** → WARNING, install proceeds
  against Ubuntu's CDN
- **Cache VM started but port 3128 unreachable** → ERROR, `exit 1`
  (the operator must fix it — check cloud-init, squid, firewall —
  before retrying the guest install)

No changes to `test-config.json` or the test sequences are needed.

## Monitoring — cachemgr.cgi

The VM bundles **Apache + squid-cgi** so Squid's built-in cache
manager is reachable from a browser on the host:

```
http://<squid-cache-vm-ip>/cgi-bin/cachemgr.cgi
```

Find the IP using one of the methods in the Setup section above
(`utmctl ip-address` doesn't work for Apple Virtualization VMs —
check the UTM window, `/var/db/dhcpd_leases`, or subnet-probe :3128).
The first page is
a form — leave **Cache Host** as `localhost` and **Cache Port** as
`3128`. Useful reports:

- **info** — overall stats, uptime, total/client requests
- **utilization** — hit ratio broken down over 5/60 minutes
- **storedir** — disk-cache occupancy (near the 40 GB cap?)
- **mem** — memory-pool usage
- **client_list** — which guest IPs have proxied through
- **objects** — list cached URLs (big page on a busy cache)

Access is restricted to RFC1918 sources at the Apache layer, and
Squid's own default ACL allows the `manager` scheme only from
`localhost`. So only the Mac host and guests on the same UTM Shared
network can reach the page.

For CLI access from inside the VM, `sudo squidclient mgr:info` (or
`mgr:5min`, `mgr:utilization`) returns the same data without the web UI.

## Access / credentials

Cloud-init configures the default `ubuntu` user with:

- **Password**: a fresh random 10-char alphanumeric string, generated by
  `New-VM.ps1` on every rebuild. The password is
  - printed in the script's output banner when the VM bundle is ready,
  - saved to `~/virtual/squid-cache/squid-cache-password.txt`
    (chmod 600, owner-only),
  - baked into the seed.iso's `user-data` (`chpasswd` module).

  Password expiry is disabled, so repeated UTM-window or
  `ssh -o PreferredAuthentications=password` sessions keep working
  without an interactive reset. A new random password is generated on
  every `New-VM.ps1` run — the old one is overwritten.

  (Before: we used the static string `password` for every rebuild, which
  caused browser password managers to cache and auto-suggest it against
  cachemgr.cgi and produce repeated popups. Random per-rebuild prevents
  that.)
- **SSH key**: the yuruna test-harness public key (generated/cached at
  `test/.ssh/yuruna_ed25519` by [Test.Ssh.psm1](../../../test/modules/Test.Ssh.psm1)).
  `ssh ubuntu@<ip>` works passwordless from the Mac host. (Find
  `<ip>` using the recipes in the Setup section — `utmctl ip-address`
  doesn't work for Apple Virtualization VMs.)

Both paths exist because this VM is most often debugged when it *hasn't*
finished cloud-init yet — SSH isn't up at that point, only the UTM
window. Treating the password as a secret is inappropriate: this VM is
reachable only on UTM's Shared NAT (not externally routable), and squid
itself restricts access to RFC1918 sources.

## Management

The cache VM is independent of the test harness. It is not created
or destroyed by `Invoke-TestRunner.ps1`.

- **Start/Stop**: `utmctl start squid-cache` / `utmctl stop squid-cache`
  or use the UTM GUI.
- **Delete**: stop the VM, right-click → Delete in UTM, then
  `rm -rf ~/Desktop/Yuruna.VDE/<hostname>.nosync/squid-cache.utm`.
- **Clear cache**: SSH into the VM and run
  `sudo systemctl stop squid && sudo rm -rf /var/spool/squid/* && sudo squid -z -N && sudo systemctl start squid`
- **Inspect hits/misses**: `sudo tail -f /var/log/squid/access.log`
  inside the VM, or use cachemgr.cgi for aggregate views.

## Future: HTTPS caching

The current config tunnels HTTPS via `CONNECT` without caching the
encrypted bodies. SSL-bump would require a generated CA installed in
every guest's trust store — not yet implemented.

Back to [[macOS UTM Host Setup](../README.md)]
