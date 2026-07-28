# Extensions API

The harness defers five classes of swappable behavior to **extension
areas** under [`test/extension/`](../test/extension/) — authentication,
notification transports, caching-proxy log parsing, host-side
artifact stashing, and multi-host pool aggregation. An area is a
directory with one or more `.psm1` files plus a small YAML config
naming the active set.

Loader: [`test/modules/Test.Extension.psm1`](../test/modules/Test.Extension.psm1).

## Areas today

| Area                   | Active default | What it controls |
|------------------------|----------------|------------------|
| `authentication`       | `default`      | `${ext:authentication.GetPassword(<user>)}` / `NewRandomPassword()` / `SetPassword()` — vault read/write for sequences. The `default` extension stores per-cycle ephemeral test-VM passwords in plaintext YAML **by design**; see [Authentication — Test-harness vault threat model](authentication.md#test-harness-vault--threat-model) for the trust boundary. Wire a different extension (DPAPI / keyring / external secret manager) before driving any production system from a sequence. |
| `notification`         | `default`      | `Send-Notification -EventCode -EventMessage`; iterates configured transports (Resend, SMTP, etc.). |
| `caching-proxy-parser` | `default`      | Maps a Squid access-log line to a structured record for the test/perf log. Ships a Go sidecar (`main.go` + `caching-proxy-parser.service`) for inside-the-VM parsing; the PowerShell `default.psm1` is the host-side wrapper. |
| `stash-service`        | `default`      | Receives `scp`/`sftp`-uploaded artifacts (diagnostic bundles, screenshots) into a stash-storage-backed stash. Ships a Go daemon under [`server/`](../test/extension/stash-service/server/) (legacy SCP **and** SFTP, files on the ystash-nas share + VM-local SQLite index/sidecars) brought up by `Start-StashVM` + cloud-init, plus the PowerShell wrapper `default.psm1`. |
| `pool-aggregator`      | `default`      | Read-only multi-host **pool view** (`Get-PoolAggregatorManifest`) plus the pool half of the service lookup below (`Get-PoolExtensionHost`). Ships a stdlib-only Go daemon that runs on the caching-proxy machine (pool services host): it auto-discovers pool members from the squid access log, probes each one's status server, identifies on the stable `hostId`, and pushes cycle-status transitions to Loki. See [`pool-aggregator/README.md`](../test/extension/pool-aggregator/README.md). |

## Filesystem layout

```
test/extension/
├── authentication/
│   ├── authentication.config.yml       # active: ['default']
│   ├── authentication.contract.yml     # methods + parameter shape this area exports
│   ├── users.yml.template              # vault seed: harness copies on first cycle
│   └── default.psm1                    # exports Get-Password / Set-Password / Initialize-VaultConnection
├── notification/
│   ├── notification.config.yml         # active: ['default']
│   ├── notification.contract.yml       # methods this area exports
│   ├── transports.yml.template         # transport-credentials seed (e.g. Resend API key)
│   └── default.psm1                    # exports Send-Notification
├── caching-proxy-parser/
│   ├── caching-proxy-parser.config.yml # active: ['default']
│   ├── caching-proxy-parser.contract.yml
│   ├── caching-proxy-parser.service    # systemd unit for the in-VM Go sidecar
│   ├── go.mod, main.go                 # Go sidecar source (built into the proxy VM)
│   ├── README.md
│   └── default.psm1                    # host-side wrapper
├── stash-service/
│   ├── stash-service.config.yml        # active: ['default']
│   ├── server/                         # Go daemon (main.go + internal/{...})
│   └── default.psm1                    # host-side wrapper
└── pool-aggregator/
    ├── pool-aggregator.config.yml      # active: ['default']
    ├── pool-aggregator.contract.yml    # requiredFunction: Get-PoolAggregatorManifest
    ├── pool-aggregator.service         # systemd unit for the proxy-host Go daemon
    ├── go.mod, main.go, main_test.go   # stdlib-only Go daemon source
    ├── grafana-pool-dashboard.json     # companion Grafana dashboard
    ├── README.md
    └── default.psm1                    # host-side wrapper
```

The `<area>.contract.yml` files declare the methods + parameter shape
each area's PowerShell module must export. `Resolve-ExtensionMethod`
does not enforce them today (the contract is implicit in the callers);
they exist as the durable source-of-truth for the JSON Schema
follow-on noted in [Adding a new area](#adding-a-new-area).

Per-area state (vault file, transport credentials) lives under
[`test/status/extension/<area>/`](../test/status/) — git-ignored, never
shipped.

## The loader API

```
Resolve-ExtensionAreaDir   -Area
Read-ExtensionConfig       -Area
Get-ActiveExtensionName    -Area   # ALWAYS wrap in @(...) — single-entry config unrolls to scalar
Import-Extension           -Area [-RequireSingle]
Resolve-ExtensionMethod    -Area -ExtensionName -Method
Get-ExtensionHostAddress   -HostType [-VMName] [-AggregatorBaseUrl] [-TimeoutSeconds]
```

`Resolve-ExtensionMethod` is what makes the `${ext:area.Method(...)}`
substitution in sequence YAML work — it maps the CamelCase method name
to the exported `Verb-Noun` form (e.g. `GetPassword` → `Get-Password`)
and looks up the loaded module by **absolute path**, not module name.
Two areas can ship a `default.psm1`; the path-based lookup means each
area's exports are unambiguous.

## Finding a service this host does not run

Some areas are *services on the network* rather than code loaded into the
cycle — the stash service, pool control. A host that needs one usually does
not run it: the service lives on another host, often another subnet, at an
address DHCP is free to change. Nothing in this host's config knows where
it is, so the alternative is a hard-coded literal that is correct only
until the service moves — and then a cycle spends its whole timeout budget
on a machine that no longer exists.

`Get-ExtensionHostAddress` is the one call client code makes instead:

```powershell
Import-Module test/modules/Test.Extension.psm1 -Force -DisableNameChecking
# @() because a single address unrolls to a scalar, and an empty result to
# nothing at all — the same rule as Get-ActiveExtensionName.
$addresses = @(Get-ExtensionHostAddress -HostType 'stash-service')
foreach ($address in $addresses) {
    if (Test-StashHost -Address $address) { $stash = $address; break }
}
```

`-HostType` is the **extension area slug** naming the kind of service
(`stash-service`, `pool-control`) — unrelated to the hypervisor host type
`Get-HostType` returns (`host.windows.hyper-v`).

The answer is a **list, nearest first**, and may be empty:

| Order | Source | Answers for |
|---|---|---|
| 1 | `$env:YURUNA_EXTENSION_HOST_<AREA>` — area upper-cased, non-alphanumerics → `_` (e.g. `YURUNA_EXTENSION_HOST_STASH_SERVICE`) | an operator who states an address; it is meant, so nothing discovered outranks it |
| 2 | Host contract `Get-VMIp` on `yuruna-<area>` (override with `-VMName`, `''` skips it) | a service VM running on **this** host, at its current address across rebuilds |
| 3 | The pool — the aggregator's [`/api/v1/extension-hosts`](../test/extension/pool-aggregator/README.md#endpoints-9400), read through `Get-PoolExtensionHost` | a service running on **another** host, from its own registration/announce record |

Since the aggregator lives in the caching-proxy VM, knowing the proxy
address — which every host needs anyway, to reach the cache at all — is
enough to locate every other service the pool offers. A host with no
caching proxy has no aggregator to ask and no pool: that source simply
contributes nothing.

A list rather than one answer, because only the caller can say which
address is usable: it holds the probe (the stash pre-flight demands
`/healthz`), it may prefer a particular subnet, and it usually has a
site-specific last resort of its own to append. **Every entry is a hint,
never a promise** — prove one before committing a cycle to it. The lookup
is unauthenticated and does not verify the aggregator's TLS leaf (minted by
the proxy's own CA, which a harness host has no trust-store entry for); the
payload is LAN service coordinates, not a secret, and a wrong answer fails
closed at the caller's probe.

It never throws. Each source is independent — a pool that does not answer,
a host contract without `Get-VMIp`, an area nobody serves — and any of them
coming up empty just shortens the list. Addresses carrying whitespace or a
quote are dropped: they end up composed into URLs, `scp` targets and
single-quoted guest env lines, where such a value corrupts the command
rather than failing it.

The stash extension's `Resolve-Host` (what
`${ext:stash-service.ResolveHost(<vm>)}` expands to) consults it last,
after the local VM and the address the cycle's pre-flight already verified.

## Why `@(Get-ActiveExtensionName)` wrap

PowerShell's pipeline unrolls a single-element array to a scalar. A
config with one `active:` entry returns the string `'default'`; indexing
`$names[0]` returns the character `'d'`, not the name. Always:

```
$names = @(Get-ActiveExtensionName -Area 'authentication')
$extName = $names[0]
```

## Why `Import-Extension` matches by absolute path

When two areas ship a `default.psm1`, both modules register under the
same PowerShell module name `'default'`. `Get-Module -Name default`
returns whichever was imported last, so `Get-Command -Module default
Get-Password` resolves to whichever module loaded most recently — not
the one for the area the caller intended. `Resolve-ExtensionMethod`
matches modules by absolute `.psm1` path instead, so the intended
exports are always found.

## Adding a new extension to an existing area

1. Create `<extname>.psm1` in `test/extension/<area>/`.
2. Add `<extname>` to the `active:` list in `<area>.config.yml`.
3. The loader imports it on the next cycle; sequence YAML references
   to `${ext:<area>.Method(...)}` route to the new module if it
   exports `Method`.

For `notification`, multiple active extensions iterate in declaration
order — every transport sees every event. For `authentication`, the
loader expects **exactly one** active extension and throws on
ambiguity (`-RequireSingle`).

## Adding a new area

1. Create `test/extension/<newarea>/` with a `default.psm1` and a
   `<newarea>.config.yml`.
2. Add the area to the
   [capability matrix](capability-matrix.md) by simply existing —
   `Get-CapabilityExtensionArea` discovers areas by directory, not
   by a hardcoded list.
3. Document the contract the area's `.psm1` files must export. Today
   each area has its own implicit contract enforced by the calling
   code; a future improvement is to publish JSON schemas alongside
   the configs (the
   [`test/schemas/`](../test/schemas/) folder already hosts
   `extension-config.schema.yml` for the common envelope).

## POST /announce (pool-aggregator)

`handleAnnounce` in `test/extension/pool-aggregator/main.go` is the
extension-presence write surface: a service VM (e.g. the stash server's
beacon) POSTs `{hostId, area, targetPort, active}` on boot, every beacon
period, and with `active=false` at shutdown, so the dashboard's Extension
hosts row survives the owning host's status server being down (the state
a host reboot routinely leaves behind). The route is deliberately open
(no bearer, unlike `/ingest`) because requiring the shared
lab-auth-token would kill the beacon exactly where it is needed.
Containment instead:

1. **Self-identity binding** — the advertised service URL is derived from
   (or must match) the connection's source IP, so an announcer can only
   advertise itself.
2. **Telemetry-only** — paints a dashboard row and redirect target; no
   control plane, host probing, or cycle accounting.
3. **Bounded** — tiny body cap, strict hostId/area charsets, at most
   `maxAnnounce` entries, TTL reap.
4. **Goodbyes only remove an entry the same source owns.**

`-announce-ttl 0` disables the route.

`-host-ttl <duration>` (default `24h`) sets how long a host stays in the pool
view after its last contact; the reap drops the row on the next poll. Two values
follow it rather than being configured separately, so they cannot be ordered
wrongly:

- the **per-cycle dedup state** (which `hostId|cycleId` pairs have been counted)
  is kept one hour past the row, so a host that is reaped and then re-appears
  cannot re-count a terminal cycle it was already counted for;
- the Loki lookback resolving a departed host's address for dashboard deep links
  — including the `/go/host` redirect that mints a control proof — follows the
  TTL upward but never drops below 24h, so shortening the TTL cannot 404 a link
  the dashboard still displays. (`/go/cycle`'s own cycle-folder match keeps a
  separate fixed 6h window.)

This does **not** bound the cumulative `yuruna_pool_cycles_pass_total` /
`_fail_total` counters: those are not time-expired at all, and survive until the
process restarts or `POST /api/v1/forget-host` clears that host. Shortening the
TTL also does not by itself evict a host that keeps being re-seeded from the
presence feed on restart — `Remove-PoolHost.ps1` / forget-host is the
deterministic path.

To change it, edit `pool-aggregator.service` and run
`systemctl daemon-reload && systemctl restart pool-aggregator` — no rebuild.
**`daemon-reload` is not optional:** a bare restart re-execs systemd's cached
unit and the old value stays in force. A drop-in works too, but the unit is
`Type=simple`, so the drop-in must reset `ExecStart` first (`ExecStart=` on its
own line, then the full replacement) or systemd refuses to load the service. A
non-positive value falls back to the 24h default. The flag exists only in
binaries built from the commit that added it — on an older proxy, check
`pool-aggregator -h | grep host-ttl` before adding it, or the service crash-loops
on `flag provided but not defined`.

## POST /api/v1/lab-token (pool-aggregator)

The enrollment exchange: a host redeems the 6-character lab connection
token shown on the dashboard's "Lab token" tile (body
`{"labToken":"<6 chars>"}`) and receives the shared lab-auth-token —
`200 {"ok":true,"v":1,"salt":…,"nonce":…,"ciphertext":…,"tag":…}`;
`400` malformed, `403` unknown/expired code, `429` per-IP throttle,
`503` disabled. The route is open — the caller is by definition a host
that does not yet hold the shared token — and contained instead by the
short-lived rotating code (`-lab-token-rotate`, default `60s`; a
displayed code stays redeemable for about three rotations), the
per-address throttle, and an audit of every attempt (aggregator log +
Loki, label `src="lab-token"`; the code itself is never logged).

The answer is **sealed under the redeemed code**: AES-256-GCM with a
PBKDF2-HMAC-SHA256 key over that code and a fresh salt (associated data
`yuruna-lab-token|v1`). This is what authenticates the aggregator to a
host that cannot verify its TLS leaf — the proxy's own CA signs it, and
an enrolling host has no reason to trust that CA yet — so nothing else
on the path can answer the exchange and plant a token the host would
then honor for control proofs. It also keeps the shared token off the
wire in the clear when the proxy runs plain HTTP (no TLS leaf).
`pwsh test/Set-LabToken.ps1 -LabToken <code>` is the client
(`Unprotect-LabTokenEnvelope` opens the envelope; a seal that does not
authenticate is refused, never stored); `-lab-token-rotate 0` disables
the exchange and the dashboard tile.
See [`pool-aggregator/README.md`](../test/extension/pool-aggregator/README.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.27

Back to [Yuruna](../README.md)
