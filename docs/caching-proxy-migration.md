# Caching-proxy migration — warm hand-off between cache VMs

How to replace the Squid cache VM (host retirement, resize, newer base
image) without ever serving clients from a cold cache.
[Move-CachingProxy.ps1](../test/Move-CachingProxy.ps1) builds a
temporary parent-child Squid hierarchy — the NEW cache fetches its
misses from the OLD cache's warm store at LAN speed — and later tears
it down and retires the old VM. Cache-VM concepts are in
[Caching](caching.md); the operational wrappers are in
[Caching proxy](caching-proxy.md).

## Why migrate warm

A cold cache re-fights the battle the cache VM exists to win: every
fresh-VM install hammers the Ubuntu CDN and container registries until
429 rate limits stretch a ~2 min warm install to ~30 min or fail it
outright (see [Caching proxy — why a separate cache VM](caching-proxy.md#why-a-separate-cache-vm)).
Warming the new cache from the old one keeps every hot object served
from disk on the LAN, and only true misses go to the origin — once,
from one VM.

## How it works

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

## Prerequisites

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

## Starting the copy cycle

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
  [External cache override](caching-proxy.md#external-cache-override).
- Hand-wired clients (DNS, DHCP options, WPAD, apt proxy files):
  repoint `<old>:3128 → <new>:3128` and `<old>:3129 → <new>:3129`.
- Validate from any client: `pwsh test/Test-CachingProxy.ps1 -CacheIp <new>`.

Re-running `-Start` is safe: it rewrites the same drop-ins.

## While the hierarchy runs

As clients use the new cache, its misses fill from the old cache and
the old cache's request rate decays naturally — typically a few days
for the hot set. Watch the drain:

```
ssh yuruna@<old>
sudo tail -f /var/log/squid/access.log
```

Both VMs also expose their Grafana dashboards on `:3000`.

## Ending the copy cycle

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

## Resilience model

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

## Troubleshooting

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

Last review: 2026.07.15

Back to [Yuruna](../README.md)
