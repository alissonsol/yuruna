# Extensions API

The harness defers seven classes of swappable behavior to **extension
areas** under [`test/extension/`](../test/extension/) — authentication,
notification transports, caching-proxy-service log parsing, host-side
artifact stashing, multi-host pool aggregation, pool configuration, and
pool-wide guest-image downloading. An area is a directory with one or more
`.psm1` files plus a YAML config naming the active set.

Loader: [`test/modules/Test.Extension.psm1`](../test/modules/Test.Extension.psm1).

Some areas are **services on the network** rather than code loaded into a
cycle. They share one interface, described
[below](#the-extension-interface): one manifest declaring what the service is,
one Go SDK for talking to the pool and gating writes, and one host-side module
for the runtime marker. A new extension service implements that interface and
is discovered by existing; it adds no case to any list in the framework.

## Areas today

| Area                   | Active default | What it controls |
|------------------------|----------------|------------------|
| `authentication`       | `default`      | `${ext:authentication.GetPassword(<user>)}` / `NewRandomPassword()` / `SetPassword()` — vault read/write for sequences. The `default` extension stores per-cycle ephemeral test-VM passwords in plaintext YAML **by design**; see [Authentication — Test-harness vault threat model](authentication.md#test-harness-vault--threat-model) for the trust boundary. Wire a different extension (DPAPI / keyring / external secret manager) before driving any production system from a sequence. |
| `notification`         | `default`      | `Send-Notification -EventCode -EventMessage`; iterates configured transports (Resend, SMTP, etc.). |
| `caching-proxy-parser-service` | `default`      | Maps a Squid access-log line to a structured record for the test/perf log. Ships a Go sidecar (`main.go` + `caching-proxy-parser-service.service`) for inside-the-VM parsing; the PowerShell `default.psm1` is the host-side wrapper. |
| `stash-service`        | `default`      | Receives `scp`/`sftp`-uploaded artifacts (diagnostic bundles, screenshots) into a stash-storage-backed stash. Ships a Go daemon under [`server/`](../test/extension/stash-service/server/) (legacy SCP **and** SFTP, files on the ystash-nas share + VM-local SQLite index/sidecars) brought up by `Start-StashServiceVM` + cloud-init, plus the PowerShell wrapper `default.psm1`. |
| `pool-aggregator-service`      | `default`      | Read-only multi-host **pool view** (`Get-PoolAggregatorServiceManifest`) plus the pool half of the service lookup below (`Get-PoolExtensionHost`). Ships a stdlib-only Go daemon that runs on the caching-proxy-service machine (pool services host): it auto-discovers pool members from the squid access log, probes each one's status service, identifies on the stable `hostId`, and pushes cycle-status transitions to Loki. See [`pool-aggregator-service/README.md`](../test/extension/pool-aggregator-service/README.md). |
| `pool-control-service` | `default`      | The operator board for **pool configuration**: which pools exist, which hosts belong to them, which test set each one runs. Ships a stdlib-only Go daemon on its own `yuruna-pool-control-service` VM that drives the pool-intent git store by shelling out to the pool-admin CLIs, with a web UI whose mutating actions unlock with the dashboard's rotating Lab token. The PowerShell `default.psm1` is the host-side pair — `Get-PoolControlServiceInfo` (status stub) and `Test-PoolControlServiceHost` (the `/healthz` pre-flight). See [pool-admin.md](pool-admin.md#pool-control-service). |
| `download-agent-service`       | `default`      | Pool-wide **guest-image downloader**: a stdlib-only Go daemon on its own `yuruna-download-agent-service` VM that keeps a Download pool on the pool share fresh and serves the artifacts to hosts over HTTP, with a web UI whose mutating actions unlock with the dashboard's rotating Lab token. The PowerShell `default.psm1` is the host-side pair — `Get-DownloadAgentServiceInfo` (status stub) and `Test-DownloadAgentServiceHost` (the `/healthz` reachability pre-flight). See [download-agent.md](download-agent.md). |

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
├── caching-proxy-parser-service/
│   ├── caching-proxy-parser-service.config.yml # active: ['default']
│   ├── caching-proxy-parser-service.contract.yml
│   ├── caching-proxy-parser-service.service    # systemd unit for the in-VM Go sidecar
│   ├── go.mod, main.go                 # Go sidecar source (built into the proxy VM)
│   ├── README.md
│   └── default.psm1                    # host-side wrapper
├── stash-service/
│   ├── stash-service.config.yml        # active: ['default']
│   ├── server/                         # Go daemon (main.go + internal/{...})
│   └── default.psm1                    # host-side wrapper
├── pool-aggregator-service/
│   ├── pool-aggregator-service.config.yml      # active: ['default']
│   ├── pool-aggregator-service.contract.yml    # requiredFunction: Get-PoolAggregatorServiceManifest
│   ├── pool-aggregator-service.service         # systemd unit for the proxy-host Go daemon
│   ├── go.mod, main.go, main_test.go   # stdlib-only Go daemon source
│   ├── grafana-pool-dashboard.json     # companion Grafana dashboard
│   ├── README.md
│   └── default.psm1                    # host-side wrapper
├── pool-control-service/
│   ├── pool-control-service.config.yml         # active: ['default'] + the service manifest
│   ├── pool-control-service.contract.yml
│   ├── server/                         # Go daemon (main.go + internal/{...}, incl. intent)
│   └── default.psm1                    # host-side status stub + /healthz pre-flight
├── download-agent-service/
│   ├── download-agent-service.config.yml       # active: ['default'] + the service manifest
│   ├── download-agent-service.contract.yml     # requiredFunction: Get-DownloadAgentServiceInfo
│   ├── server/                         # Go daemon (main.go + internal/{...}, incl. imagestore)
│   └── default.psm1                    # host-side status stub + /healthz pre-flight
└── extension-sdk/                      # the shared Go SDK, mirrored into each server/
    ├── go.mod, README.md
    ├── beacon/                         # POST /announce presence
    ├── pool/                           # the pool-aggregator read client
    └── labgate/                        # the lab-token write gate
```

Each `server/` additionally holds `internal/yex/` — the generated,
byte-identical copy of `extension-sdk/`, written by
[`tools/Sync-ExtensionSdk.ps1`](../tools/Sync-ExtensionSdk.ps1), never by hand.

The `<area>.contract.yml` files declare the methods + parameter shape
each area's PowerShell module must export. `Resolve-ExtensionMethod`
does not enforce them (the contract is implicit in the callers);
they are the durable source of truth for the JSON Schema
follow-on noted in [Adding a new area](#adding-a-new-area).

A service area additionally carries a `service:` block in its
`<area>.config.yml` — the manifest described
[below](#1-the-manifest--what-the-area-declares) — and, when it ships a Go
daemon, a `server/` directory holding that daemon plus the generated SDK
mirror at `server/internal/yex/`.

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

`Resolve-ExtensionMethod` powers the `${ext:area.Method(...)}`
substitution in sequence YAML: it maps the CamelCase method name
to the exported `Verb-Noun` form (e.g. `GetPassword` → `Get-Password`)
and looks up the loaded module by **absolute path**, not module name.
Two areas can ship a `default.psm1`; the path-based lookup keeps each
area's exports unambiguous.

## The extension interface

Four service extensions exist, and each new one used to mean copying the same
five things: a presence beacon, an aggregator read client, a write gate, a
runtime marker, and an entry in three hardcoded lists inside the framework. Each
copy drifted from the others, which is how one service ended up with a weaker
retry, another with a `clientIP` that mangles IPv6, and the one service that
rewrites pool configuration with no credential at all.

The interface is three layers, each with one source of truth.

### 1. The manifest — what the area declares

A service area's `<area>.config.yml` carries a `service:` block, validated by
[`test/schemas/extension-config.schema.yml`](../test/schemas/extension-config.schema.yml):

```yaml
active:
  - default
service:
  displayName: Stash service          # the label the Extension hosts column shows
  vmName: yuruna-stash-service        # the VM this host creates; absent = hosted elsewhere
  healthPort: 80                      # the port a CONSUMER connects to
  healthPath: /healthz
  startScript: Start-StashServiceVM.ps1
  stopScript: Stop-StashServiceVM.ps1
  markerBaseUrlKey: stashBaseUrl      # this area's own marker key, kept for older readers
  beaconInterval: 15m
  writeGate: none                     # or lab-token -- see the rule below
```

That one block feeds the service-VM roster the reboot sweep and the cleanup
guard read ([`Test.ServiceVm.psm1`](../test/modules/Test.ServiceVm.psm1)), the
runtime marker's shape, and the write-gate posture. An area **without** the
block is code the cycle loads (`authentication`, `notification`) or a sidecar
inside another VM — not something the pool can locate or restart, so returning
nothing for those is the answer, not a failure.

It is read by
[`Test.ExtensionService.psm1`](../test/modules/Test.ExtensionService.psm1),
**by lines and never through a YAML parser**. Not because a parser would be
wrong, but because it is not always loaded: the roster is imported on its own by
the reboot sweep and by cleanup paths, and a reader that answers only when a
parser happens to be present would empty the roster — so a rebooted host never
restarts its service VMs, and a prefix-matching cleanup can no longer prove it
will skip them. The schema constrains the block to a flat mapping of scalars, so
`key: value` at two spaces of indent is the whole grammar the reader handles.

### 2. The Go SDK — talking to the pool, and gating writes

[`test/extension/extension-sdk/`](../test/extension/extension-sdk/) is its own
Go module with three self-contained packages:

| Package | What a service gets |
|---|---|
| `beacon` | `POST /announce` presence: hello at boot (retried on a doubling catch-up cadence), re-announce every interval, `active:false` goodbye. |
| `pool` | The read client for the **information provider**: `Status`, `ExtensionHost(s)`, `ExtensionTarget`, `Healthz`, and `Get`/`GetURL` for untyped routes. |
| `labgate` | The write gate: `Require`, `RequireBearer`, `HandleLogin`, `Session`. |

Three decisions live in `pool` so they cannot vary per consumer: the trusted-LAN
TLS posture (the aggregator's leaf is signed by the pool CA, which no guest
trusts, so these reads encrypt without pinning); `SanitizeBaseURL` on **every**
URL-valued field of a response, because these reads do not verify who answered
and a UI renders what it gets as a link; and an https→http fallback on a
*transport* failure only, since an aggregator with no leaf answers `:9400` in
the clear while a protocol answer is authoritative.

Each service carries the byte-identical copy at `<area>/server/internal/yex/`
because each daemon is its own module, built **inside its own VM** from a copy
of `<area>/server/` alone — a module outside that directory is not there when
the compiler looks for it. Committing the mirror also keeps every service
independently buildable and testable from a plain checkout. The mirrors are
generated by [`tools/Sync-ExtensionSdk.ps1`](../tools/Sync-ExtensionSdk.ps1),
never edited; the extension-service suite fails if one drifts.
See [the SDK README](../test/extension/extension-sdk/README.md).

### 3. The host-side module — the runtime marker

[`Test.ExtensionService.psm1`](../test/modules/Test.ExtensionService.psm1) owns
`runtime/<area>.json`, the host's claim that it runs a service:

```
Get-ExtensionServiceManifest / -ManifestAll [-WithVMOnly]
Get-ExtensionServiceVmRoster
Write-ExtensionServiceMarker  -Area -Active -VMName -HostType -BaseUrl [-Extra]
Read-/Remove-ExtensionServiceMarker  -Area
Get-ExtensionServiceMarkerBaseUrl    -Marker -Area
Get-ActiveExtensionService           # -> activeExtensions + extensionTargets
```

`-Active` is the **readiness verdict**, not "the bring-up ran": the aggregator
paints the row and its deep-link from it, so publishing `$true` for a daemon
that never bound its port sends operators to a dead URL and hides the real
failure. The address is written under both the uniform `baseUrl` and the area's
own `markerBaseUrlKey`, because a consumer built before the uniform key reads
only the per-service one and a host can run a framework newer than the
aggregator it reports to.

[`Write-HostRegistrationRecord`](../test/modules/Test.Capability.psm1) turns
`Get-ActiveExtensionService` into the record's `activeExtensions` /
`extensionTargets` — no hardcoded block per service, so a new extension reaches
the pool without an edit to the registration writer.

### The Lab Token rule

**Any route that changes host or pool configuration requires the lab token** —
the shared `lab-auth-token` as a bearer, or a session unlocked with the rotating
6-character Lab token the *Yuruna hosts* dashboard displays. Not a
service-local secret: one more shared string to distribute and rotate buys
nothing a rotating pool-wide code does not already give, and it would be the
only credential in the lab no other service understands.

`labgate` is that rule in code, and each area's `writeGate:` declares it, so
"which services gate their writes" is answerable without reading four route
tables.

- **`lab-token`** — `pool-control-service` (pools, membership, test-set
  assignment), `download-agent-service` (delete a generation, force a
  re-download), `pool-aggregator-service` (`/ingest`, `/api/v1/forget-host`).
- **`none`** — `stash-service`. Its one destructive verb, `DELETE`, is
  restricted to the VM itself and the deploying host, which is a *narrower* rule
  than the lab token; and a stash holds artifacts, not configuration.

Three properties come with the gate:

- **Reads stay open.** Catalogs, boards, artifacts and status are readable on the
  trusted LAN, matching `pool-status`. Gating them would make a credential a
  prerequisite for a host doing its job, and for a wall display rendering a board.
- **Fail closed, and say which.** A validator that cannot be reached answers
  `503` with reason `lab-token-unavailable`, never `401` — an operator who
  cannot tell "wrong code" from "validator down" retypes a correct code until
  they give up. A service with neither credential configured answers `503`
  `auth-unconfigured` rather than running a write ungated.
- **Audited at the service.** Every unlock attempt is recorded with its source
  address. The aggregator's own audit cannot answer that question: from there,
  every operator in the lab is one source address.

`POST /announce` is the deliberate exception and stays open: requiring the
token would kill the beacon exactly where it is needed. It is contained instead
by self-identity binding, a health probe, bounded state, and being
telemetry-only ([below](#post-announce-pool-aggregator-service)).

### Building a new extension service

1. `test/extension/<area>/` with `<area>.config.yml` (`active:` + the `service:`
   block), `<area>.contract.yml`, and `default.psm1` exporting at least a status
   stub and a `Test-<Name>Host` `/healthz` pre-flight.
2. `server/` for the Go daemon. Import `beacon`, `pool` and `labgate` from
   `<module>/internal/yex/...`; put every configuration write behind
   `gate.Require`. Run `pwsh tools/Sync-ExtensionSdk.ps1` to place the mirror.
3. `test/Start-<Name>VM.ps1` / `Stop-<Name>VM.ps1` calling
   `Write-ExtensionServiceMarker` / `Remove-ExtensionServiceMarker` with the
   readiness verdict.
4. A guest bring-up script + `host/vmconfig/<area>.base.user-data` seeding
   `/etc/yuruna/pool.env` (`YURUNA_AGGREGATOR_URL`) and `/etc/yuruna/host.env`
   (`YURUNA_HOST_ID`), which is where the daemon's `--aggregator-url` and
   `--host-id` come from.
5. Add the `area` → `displayName` value-mapping to
   [`grafana-pool-dashboard.json`](../test/extension/pool-aggregator-service/grafana-pool-dashboard.json)
   and its inline copy, so the Extension hosts cell reads the label rather than
   the slug.

The roster, the capability matrix, the registration record, the pool lookup and
the reboot sweep pick it up with no further edits.

## Finding a service this host does not run

A host that needs a network service — the stash service, pool-control service,
download-agent service — usually does not run it: the service lives on another
host, often another subnet, at an address DHCP is free to change. Nothing in
this host's config knows where it is, so the alternative is a hard-coded literal
that is correct only until the service moves — and then a cycle spends its whole
timeout budget on a machine that no longer exists.

`Get-ExtensionHostAddress` is the one call client code makes instead:

```powershell
Import-Module test/modules/Test.Extension.psm1 -Force -DisableNameChecking
# @() because a single address unrolls to a scalar, and an empty result to
# nothing at all — the same rule as Get-ActiveExtensionName.
$addresses = @(Get-ExtensionHostAddress -HostType 'stash-service')
foreach ($address in $addresses) {
    if (Test-StashServiceHost -Address $address) { $stash = $address; break }
}
```

`-HostType` is the **extension area slug** naming the kind of service
(`stash-service`, `pool-control-service`, `download-agent-service`) — unrelated
to the hypervisor host type `Get-HostType` returns (`host.windows.hyper-v`).

The answer is a **list, nearest first**, and may be empty:

| Order | Source | Answers for |
|---|---|---|
| 1 | `$env:YURUNA_EXTENSION_HOST_<AREA>` — area upper-cased, non-alphanumerics → `_` (e.g. `YURUNA_EXTENSION_HOST_STASH_SERVICE`, `YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE`) | an operator who states an address; it is meant, so nothing discovered outranks it |
| 2 | Host contract `Get-VMIp` on `yuruna-<area>` (override with `-VMName`, `''` skips it) — `yuruna-stash-service`, `yuruna-pool-control-service`, `yuruna-download-agent-service` | a service VM running on **this** host, at its current address across rebuilds |
| 3 | The pool — the aggregator's [`/api/v1/extension-hosts`](../test/extension/pool-aggregator-service/README.md#endpoints-9400), read through `Get-PoolExtensionHost` | a service running on **another** host, from its own registration/announce record — and only at an address the aggregator has itself reached (see [below](#only-an-address-the-pool-has-reached-is-answered)) |

Since the aggregator lives in the caching-proxy-service VM, knowing the proxy
address — which every host needs anyway, to reach the cache at all — is
enough to locate every other service the pool offers. A host with no
caching-proxy service has no aggregator to ask and no pool: that source
contributes nothing.

A list rather than one answer, because only the caller can say which
address is usable: it holds the probe (the stash pre-flight demands
`/healthz`, and `Test-DownloadAgentServiceHost` gates every download-agent
candidate the same way), it may prefer a particular subnet, and it usually has a
site-specific last resort to append. **Every entry is a hint, never a
promise** — prove one before committing a cycle to it. The lookup
is unauthenticated and does not verify the aggregator's TLS leaf (minted by
the proxy's own CA, which a harness host has no trust-store entry for); the
payload is LAN service coordinates, not a secret, and a wrong answer fails
closed at the caller's probe.

It never throws. Each source is independent — a pool that does not answer,
a host contract without `Get-VMIp`, an area nobody serves — and any of them
coming up empty shortens the list. Addresses carrying whitespace or a
quote are dropped: they end up composed into URLs, `scp` targets and
single-quoted guest env lines, where such a value corrupts the command
rather than failing it.

The stash extension's `Resolve-Host` (what
`${ext:stash-service.ResolveHost(<vm>)}` expands to) consults it last,
after the local VM and the address the cycle's pre-flight already verified.

### Only an address the pool has reached is answered

Source 3 answers with an address **the aggregator has itself confirmed** at
`<target>/healthz`, and re-confirms every poll. The reason is the one class
of wrong answer a consumer cannot defend against: an address that is real
on the host that advertised it and unreachable everywhere else.

A host runs two kinds of guest network — the LAN it shares with every other
machine, and a hypervisor-private one only it can see (the macOS shared
vmnet, a Hyper-V Default Switch, libvirt's `virbr0`). Both look identical
from that host: an RFC 1918 address on a live interface, answering
`/healthz`. So a stash VM that came up on the private one is confirmed in
good faith and registered pool-wide; every OTHER host then resolves it and
spends its whole timeout budget on a machine it cannot route to — after
which the cycle stops, having built nothing.

Two checks close it, at the two places that can each see one half:

- the **owning host** refuses to advertise an address off its own
  pool-facing network (`Update-StashServiceMarkerAddress`, judged by
  `Get-Ipv4PoolSegmentVerdict`), so the address never enters
  `host.registration.json`. It only *refuses*, never insists: an
  undeterminable segment permits, and the service stays usable locally;
- the **aggregator** refuses any address it cannot reach itself, whichever
  source named it, and drops a confirmed one that stays silent for 5
  minutes. It sits where the consumers sit, so its probe is the only check
  that speaks for the pool rather than for one host.

`Test-Config.ps1`'s *Extension services (pool registry)* section reports
what the pool holds — including a registration it has refused, and one it
still advertises that this host cannot reach — so the whole class is
visible before a cycle starts rather than after one fails.

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
Get-Password` resolves to the most recently loaded module — not
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
3. Document the contract the area's `.psm1` files must export. Each
   area's contract is implicit, enforced by the calling code; a future
   improvement is to publish JSON schemas alongside
   the configs (the
   [`test/schemas/`](../test/schemas/) folder already hosts
   `extension-config.schema.yml` for the common envelope, which also
   validates the `service:` manifest).

For an area that is a **service on the network** rather than code the cycle
loads, follow [Building a new extension service](#building-a-new-extension-service)
instead: it adds the manifest, the SDK and the marker on top of these steps.

## POST /announce (pool-aggregator-service)

`handleAnnounce` in `test/extension/pool-aggregator-service/main.go` is the
extension-presence write surface: a service VM (e.g. the stash service's
beacon) POSTs `{hostId, area, targetPort, active}` on boot, every beacon
period, and with `active=false` at shutdown, so the dashboard's Extension
hosts row survives the owning host's status service being down (the state
a host reboot routinely leaves behind). The route is deliberately open
(no bearer, unlike `/ingest`) because requiring the shared
lab-auth-token would kill the beacon exactly where it is needed.
Containment instead:

1. **Self-identity binding** — the advertised service URL is derived from
   (or must match) the connection's source IP, so an announcer can only
   advertise itself, and must be an address the pool could route to at all
   (loopback, link-local, multicast and non-URL values are rejected `400`).
2. **Telemetry-only** — paints a dashboard row and redirect target; no
   control plane, host probing, or cycle accounting.
3. **Bounded** — tiny body cap, strict hostId/area charsets, at most
   `maxAnnounce` entries, TTL reap.
4. **Goodbyes only remove an entry the same source owns.**
5. **Confirmed before it is answered** — the handler probes a newly
   announced address at `/healthz` (see
   [above](#only-an-address-the-pool-has-reached-is-answered)), and the poll
   re-confirms it; an entry that stays unanswered for 5 minutes is removed
   as if it had said goodbye. An announce is a claim to be checked, not a
   fact to be republished.

**`2xx` means recorded, not merely received.** The entry itself lives in the
collector's memory; the Loki line the handler writes is the only copy that
survives a restart, and rehydrate restores the row afterwards. So when
that write does not land the handler answers `503` — the announce is kept and
serving, but the announcer is told to come back. A beacon retries only until its
*first* success and then sleeps a whole re-announce period, so a `2xx` for an
unrecorded announce would cost the pool an entire period of a healthy service
missing, in exchange for a retry worth seconds. Announcers
must therefore treat any non-`2xx` as "not done" and keep their catch-up
cadence, which is what the SDK `beacon` does. A pool configured with no Loki
keeps no announce history by choice and still answers `2xx`.

`-announce-ttl 0` disables the route.

`-host-ttl <duration>` (default `24h`) sets how long a host stays in the pool
view after its last contact; the reap drops the row on the next poll. Two values
follow it rather than being configured separately, so they cannot be ordered
wrongly:

- the **per-cycle dedup state** (which `hostId|cycleStartUtc` pairs have been counted)
  is kept one hour past the row, so a host that is reaped and then re-appears
  cannot re-count a terminal cycle it was already counted for;
- the Loki lookback resolving a departed host's address for dashboard deep links
  — including the `/go/host` redirect that mints a control proof — follows the
  TTL upward but never drops below 24h, so shortening the TTL cannot 404 a link
  the dashboard still displays. (`/go/cycle`'s own cycle-folder match keeps a
  separate fixed 6h window.)

This does **not** bound the cumulative `yuruna_pool_cycles_pass_total` /
`_fail_total` counters: those never time-expire, and survive until the
process restarts or `POST /api/v1/forget-host` clears that host. Shortening the
TTL also does not by itself evict a host that keeps being re-seeded from the
presence feed on restart — `Remove-PoolHost.ps1` / forget-host is the
deterministic path.

To change it, edit `pool-aggregator-service.service` and run
`systemctl daemon-reload && systemctl restart pool-aggregator-service` — no rebuild.
**`daemon-reload` is not optional:** a bare restart re-execs systemd's cached
unit and the old value stays in force. A drop-in works too, but the unit is
`Type=simple`, so the drop-in must reset `ExecStart` first (`ExecStart=` on its
own line, then the full replacement) or systemd refuses to load the service. A
non-positive value falls back to the 24h default. Older binaries do not carry
the flag — on an older proxy, check
`pool-aggregator-service -h | grep host-ttl` before adding it, or the service crash-loops
on `flag provided but not defined`.

## POST /api/v1/lab-token (pool-aggregator-service)

The enrollment exchange: a host redeems the 6-character lab connection
token shown on the dashboard's "Lab token" tile (body
`{"labToken":"<6 chars>"}`) and receives the shared lab-auth-token —
`200 {"ok":true,"v":1,"salt":…,"nonce":…,"ciphertext":…,"tag":…}`;
`400` malformed, `403` unknown/expired code, `429` per-IP throttle,
`503` disabled. The route is open — the caller is by definition a host
that does not yet hold the shared token — and contained by the
short-lived rotating code (`-lab-token-rotate`, default `60s`; a
displayed code stays redeemable for about three rotations), the
per-address throttle, and an audit of every attempt (aggregator log +
Loki, label `src="lab-token"`; the code is never logged).

The answer is **sealed under the redeemed code**: AES-256-GCM with a
PBKDF2-HMAC-SHA256 key over that code and a fresh salt (associated data
`yuruna-lab-token|v1`). That authenticates the aggregator to a
host that cannot verify its TLS leaf — the proxy's own CA signs it, and
an enrolling host has no reason to trust that CA yet — so nothing else
on the path can answer the exchange and plant a token the host would
then honor for control proofs. It also keeps the shared token off the
wire in the clear when the proxy runs plain HTTP (no TLS leaf).
`pwsh test/Set-LabToken.ps1 -LabToken <code>` is the client
(`Unprotect-LabTokenEnvelope` opens the envelope; a seal that does not
authenticate is refused, never stored); `-lab-token-rotate 0` disables
the exchange and the dashboard tile.
See [`pool-aggregator-service/README.md`](../test/extension/pool-aggregator-service/README.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.27

Back to [Yuruna](../README.md)
