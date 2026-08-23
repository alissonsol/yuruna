# Extensions API

The harness defers eight classes of swappable behavior to **extension
areas** under [`test/extension/`](../test/extension/) -- authentication,
notification transports, caching-proxy-service log parsing, caching-proxy
management, host-side artifact stashing, multi-host pool aggregation, pool
configuration, and pool-wide guest-image downloading. An area is a directory
with one or more `.psm1` files plus a YAML config naming the active set.

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
| `authentication`       | `default`      | `${ext:authentication.GetPassword(<user>)}` / `NewRandomPassword()` / `SetPassword()` -- vault read/write for sequences. The `default` extension stores per-cycle ephemeral test-VM passwords in plaintext YAML **by design**; see [Authentication -- Test-harness vault threat model](authentication.md#test-harness-vault--threat-model) for the trust boundary. Wire a different extension (DPAPI / keyring / external secret manager) before driving any production system from a sequence. |
| `notification`         | `default`      | `Send-Notification -EventCode -EventMessage`; iterates the subscriber list and delivers each one through its declared transport. The `default` extension implements exactly one, `email` via Resend; any other value in `transports.yml` warns `Unknown transport` and delivers nothing. Wire a new one by adding a branch here. |
| `caching-proxy-parser-service` | `default`      | Tails the Squid access log into a 100-entry in-memory ring and serves it on `:9302` as JSON (`/recent-requests`) plus a self-contained HTML page -- the source behind the Grafana dashboard's **Recent 100 requests** panel, replacing loki + promtail for it. Ships a stdlib-only Go daemon (`parse.go` + `main_linux.go` + `caching-proxy-parser-service.service`) built into the proxy VM; the PowerShell `default.psm1` is the host-side wrapper, exporting `Get-CachingProxyParserServiceManifest`. Nothing is persisted: the ring is the retention policy. |
| `caching-proxy-service` | `default`     | The **management plane** for the caching-proxy VM -- the area that made that VM self-describing instead of a hardcoded roster row. A stdlib+SDK Go daemon on `:9310` reports squid's runtime summary (via the manager API), the offline / no-upstream switch state, and zot's catalog, canary and prewarm records; it owns the two operator switches, which used to be SSH-only. Nothing that serves traffic moved: squid (`:3128`/`:3129`), zot (`:5000`), Grafana, Prometheus, Loki and the exporters are untouched. Runs either on the proxy VM (`--mode local`) or on another host that can reach those APIs (`--mode remote`, read-only -- see [below](#running-the-caching-proxy-service-from-another-host)). |
| `stash-service`        | `default`      | Receives `scp`/`sftp`-uploaded artifacts (diagnostic bundles, screenshots) into a stash-storage-backed stash. Ships a Go daemon under [`server/`](../test/extension/stash-service/server/) (legacy SCP **and** SFTP, files on the ystash-nas share + VM-local SQLite index/sidecars) brought up by `Start-StashServiceVM` + cloud-init, plus the PowerShell wrapper `default.psm1`. |
| `pool-aggregator-service`      | `default`      | Read-only multi-host **pool view** (`Get-PoolAggregatorServiceManifest`) plus the pool half of the service lookup below (`Get-PoolExtensionHost`). Ships a stdlib-only Go daemon that runs on the caching-proxy-service machine (pool services host): it auto-discovers pool members from the squid access log, probes each one's status service, identifies on the stable `hostId`, and pushes cycle-status transitions to Loki. See [`pool-aggregator-service/README.md`](../test/extension/pool-aggregator-service/README.md). |
| `pool-control-service` | `default`      | The operator board for **pool configuration**: which pools exist, which hosts belong to them, which test-set each one runs. Ships a stdlib-only Go daemon on its own `yuruna-pool-control-service` VM that drives the pool-intent git store by shelling out to the pool-admin CLIs, with a web UI whose mutating actions unlock with the dashboard's rotating Lab token. The PowerShell `default.psm1` is the host-side pair -- `Get-PoolControlServiceInfo` (status stub) and `Test-PoolControlServiceHost` (the `/healthz` preflight). See [pool-admin.md](pool-admin.md#pool-control-service). |
| `download-agent-service`       | `default`      | Pool-wide **guest-image downloader**: a stdlib-only Go daemon on its own `yuruna-download-agent-service` VM that keeps a Download pool on the pool share fresh and serves the artifacts to hosts over HTTP, with a web UI whose mutating actions unlock with the dashboard's rotating Lab token. The PowerShell `default.psm1` is the host-side pair -- `Get-DownloadAgentServiceInfo` (status stub) and `Test-DownloadAgentServiceHost` (the `/healthz` preflight). See [download-agent.md](download-agent.md). |

## Filesystem layout

```
test/extension/
+-- authentication/
|   +-- authentication.config.yml       # active: ['default']
|   +-- authentication.contract.yml     # methods + parameter shape this area exports
|   +-- users.yml.template              # vault seed: harness copies on first cycle
|   +-- default.psm1                    # 11 exports: the vault read/write pair, the credential
|                                       # resolvers, and the users.yml reader + its cache reset
+-- notification/
|   +-- notification.config.yml         # active: ['default']
|   +-- notification.contract.yml       # methods this area exports
|   +-- transports.yml.template         # transport-credentials seed (e.g. Resend API key)
|   +-- default.psm1                    # exports Send-Notification
+-- caching-proxy-parser-service/
|   +-- caching-proxy-parser-service.config.yml # active: ['default']
|   +-- caching-proxy-parser-service.contract.yml
|   +-- caching-proxy-parser-service.service    # systemd unit for the in-VM Go daemon
|   +-- go.mod                          # Go daemon source (built into the proxy VM)
|   +-- parse.go                        # regex, ring, counters, handlers -- no build tag
|   +-- main_linux.go                   # the tailer + main; needs syscall.Stat_t for logrotate
|   +-- main_other.go                   # non-Linux entry point, so the module still builds
|   +-- parse_test.go, main_linux_test.go
|   +-- README.md
|   +-- default.psm1                    # host-side wrapper
+-- caching-proxy-service/
|   +-- caching-proxy-service.config.yml        # active: ['default'] + the service manifest
|   +-- caching-proxy-service.contract.yml
|   +-- caching-proxy-service.service   # systemd unit for the in-VM Go daemon
|   +-- go.mod                          # flat module at the area root, like its two
|   |                                   # neighbors in the proxy VM -- that VM has no
|   |                                   # framework checkout, so cloud-init fetches the
|   |                                   # sources file by file and builds them in place
|   +-- main.go, squid.go, switches.go, registry.go
|   +-- main_test.go, squid_test.go
|   +-- default.psm1                    # host-side info stub + /healthz preflight
+-- stash-service/
|   +-- stash-service.config.yml        # active: ['default'] + the service manifest
|   +-- stash-service.contract.yml      # requiredFunction: the info stub, Resolve-Host,
|   |                                   # the /healthz preflight, the address publisher
|   +-- server/                         # Go daemon: main.go + internal/{...}, go.mod + go.sum
|   |                                   # (the one service module with third-party deps),
|   |                                   # and its own README.md
|   +-- default.psm1                    # host-side wrapper
+-- pool-aggregator-service/
|   +-- pool-aggregator-service.config.yml      # active: ['default'] + the service manifest
|   |                                   # (hostedIn, no vmName -- it runs in the proxy VM)
|   +-- pool-aggregator-service.contract.yml    # requiredFunction: Get-PoolAggregatorServiceManifest
|   +-- pool-aggregator-service.service         # systemd unit for the proxy-host Go daemon
|   +-- go.mod, main.go                 # stdlib-only Go daemon source, one file
|   +-- *_test.go                       # 17 test files beside it
|   +-- grafana-pool-dashboard.json     # companion Grafana dashboard
|   +-- README.md
|   +-- default.psm1                    # host-side wrapper
+-- pool-control-service/
|   +-- pool-control-service.config.yml         # active: ['default'] + the service manifest
|   +-- pool-control-service.contract.yml
|   +-- server/                         # Go daemon (main.go + internal/{...}, incl. intent)
|   +-- default.psm1                    # host-side status stub + /healthz preflight
+-- download-agent-service/
|   +-- download-agent-service.config.yml       # active: ['default'] + the service manifest
|   +-- download-agent-service.contract.yml     # requiredFunction: Get-DownloadAgentServiceInfo
|   +-- server/                         # Go daemon (main.go + internal/{...}, incl. imagestore)
|   +-- default.psm1                    # host-side status stub + /healthz preflight
+-- extension-sdk/                      # the shared Go SDK, staged beside each server/
    +-- go.mod, README.md               # at build time -- never copied into one
    +-- beacon/                         # POST /announce presence
    +-- pool/                           # the pool-aggregator read client
    +-- labgate/                        # the lab-token write gate
```

No `server/` holds a copy of the SDK. Each one names it as a sibling module
(`replace ... => ../extension-sdk`), and the guest bring-up puts it there while
it builds. The extension-service suite fails if a service reintroduces a
mirror, drops the `replace`, or stops staging the module.

The `<area>.contract.yml` files declare the methods + parameter shape each
area's PowerShell module must export, and `Import-Extension` checks them at
load: a module missing a declared verb produces a warning naming the full
delta, chosen over a throw so one stale area cannot take an unrelated cycle
down. Because that leaves nothing failing,
[`Test.ExtensionArea.Tests.ps1`](../test/modules/Test.ExtensionArea.Tests.ps1)
runs every shipped area through the loader and treats the warning as the
failure. `Resolve-ExtensionMethod`, by contrast, enforces nothing -- it resolves
a name and throws only when neither form is exported.

A service area additionally carries a `service:` block in its
`<area>.config.yml` -- the manifest described
[below](#1-the-manifest--what-the-area-declares) -- and, when it ships a Go
daemon, a `server/` directory holding that daemon.

Per-area state (vault file, transport credentials) lives under
[`test/status/extension/<area>/`](../test/status/) -- git-ignored, never
shipped.

## The loader API

```
Resolve-ExtensionAreaDir        -Area
Read-ExtensionConfig            -Area
Get-ActiveExtensionName         -Area   # ALWAYS wrap in @(...) -- single-entry config unrolls to scalar
Get-ExtensionAreaName                   # every area on disk; directory + config.yml is the whole rule
Import-Extension                -Area [-RequireSingle]
Import-ConfiguredExtension              # all areas at once; per-area failure warns, never throws
Assert-ExtensionContractCoverage -Area -ExtensionName -ExportedFunction
Resolve-ExtensionMethod         -Area -ExtensionName -Method
Get-ExtensionHostAddress        -HostType [-VMName] [-AggregatorBaseUrl] [-TimeoutSeconds]
```

`Resolve-ExtensionMethod` powers the `${ext:area.Method(...)}`
substitution in sequence YAML: it maps the CamelCase method name
to the exported `Verb-Noun` form (e.g. `GetPassword` -> `Get-Password`)
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
  # hostedIn: caching-proxy-service   # instead of vmName, when the service runs
  #                                   # inside another area's VM -- what the
  #                                   # pool-aggregator manifest declares
  healthPort: 80                      # the port a CONSUMER connects to
  healthPath: /healthz
  startScript: Start-StashServiceVM.ps1   # a NAME; the harness resolves it under test/service/
  stopScript: Stop-StashServiceVM.ps1
  markerBaseUrlKey: stashBaseUrl      # this area's own marker key, kept for older readers
  beaconInterval: 2m                  # must stay under the aggregator's 5-minute health grace
  writeGate: none                     # or lab-token -- see the rule below
```

That one block feeds the service-VM roster the reboot sweep and the cleanup
guard read ([`Test.ServiceVm.psm1`](../test/modules/Test.ServiceVm.psm1)), the
runtime marker's shape, and the write-gate posture. An area **without** the
block is code the cycle loads (`authentication`, `notification`) -- not
something the pool can locate or restart, so returning nothing for those is the
answer, not a failure.

Running inside another area's VM is a different thing from having no manifest.
`pool-aggregator-service` lives in the caching-proxy VM and still declares a
full block: `hostedIn` instead of `vmName`, which is what keeps it out of the
service-VM roster while leaving it locatable, health-probed and gated like any
other service. `-WithVMOnly` is the switch that separates the two.

It is read by
[`Test.ExtensionService.psm1`](../test/modules/Test.ExtensionService.psm1),
**by lines and never through a YAML parser**. Not because a parser would be
wrong, but because it is not always loaded: the roster is imported on its own by
the reboot sweep and by cleanup paths, and a reader that answers only when a
parser happens to be present would empty the roster -- so a rebooted host never
restarts its service VMs, and a prefix-matching cleanup can no longer prove it
will skip them. The schema constrains the block to a flat mapping of scalars, so
`key: value` at two spaces of indent is the whole grammar the reader handles.

### 2. The Go SDK — talking to the pool, and gating writes

[`test/extension/extension-sdk/`](../test/extension/extension-sdk/) is its own
Go module with three self-contained packages:

| Package | What a service gets |
|---|---|
| `beacon` | `POST /announce` presence: hello at boot (retried on a doubling catch-up cadence), re-announce every interval, `active:false` goodbye. The aggregator it announces to is seeded once, at `New-VM` time -- see [When the caching proxy is rebuilt](#when-the-caching-proxy-is-rebuilt). |
| `pool` | The read client for the **information provider**: `Status`, `ExtensionHost(s)`, `ExtensionTarget`, `Healthz`, and `Get`/`GetURL` for untyped routes. |
| `labgate` | The write gate: `Require`, `RequireBearer`, `HandleLogin`, `Session`. |

Three decisions live in `pool` so they cannot vary per consumer: the trusted-LAN
TLS posture (the aggregator's leaf is signed by the pool CA, which no guest
trusts, so these reads encrypt without pinning); `SanitizeBaseURL` on **every**
URL-valued field of a response, because these reads do not verify who answered
and a UI renders what it gets as a link; and an https->http fallback on a
*transport* failure only, since an aggregator with no leaf answers `:9400` in
the clear while a protocol answer is authoritative.

Each daemon is its own module, built **inside its own VM** from a copy of
`<area>/server/` alone -- a module outside that directory is not there when the
compiler looks for it. So the bring-up copies `extension-sdk/` in beside
`server/` and each `go.mod` resolves it as a sibling
(`replace yuruna.com/test/extension/extension-sdk => ../extension-sdk`). One
module, shared; no service holds a copy. In the enlistment the SDK sits one
directory further out than that, which is why `tools/Invoke-GoTest.ps1` builds
each service in a throwaway copy of the guest's layout instead of where the
module lives. See [the SDK README](../test/extension/extension-sdk/README.md).

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

**Active and the address are separate verdicts.** The daemon answering *inside*
the guest is the service being up; this host being able to open a socket to it
is a separate, local convenience. So the marker goes active for both, but the
address is published only when this host confirmed it end-to-end: advertising
one that leads through a forwarder which accepts and then cannot connect hangs
every peer that follows it for a full timeout. Presence with no address is a
state the pool handles -- the daemon's own announce carries the address, and the
aggregator confirms it by probing
([below](#only-an-address-the-pool-has-reached-is-answered)).

**"Still building" is deliberately not part of the marker.** A guest that is
still compiling its daemon is not serving yet, so the marker must not claim it
is. The bring-up still exits *successfully*: the VM was created and started,
which is what that step is for, and the daemon finishes and announces itself
without further help. Failing there would report a broken service over one that
is merely unfinished.

[`Write-HostRegistrationRecord`](../test/modules/Test.Capability.psm1) turns
`Get-ActiveExtensionService` into the record's `activeExtensions` /
`extensionTargets` -- no hardcoded block per service, so a new extension reaches
the pool without an edit to the registration writer.

### The Lab token rule

**Any route that changes host or pool configuration requires one of two credentials** --
the internal authentication key as a bearer, or a session unlocked with the rotating
6-character Lab token the *Yuruna hosts* dashboard displays. Not a
service-local secret: one more shared string to distribute and rotate buys
nothing a rotating pool-wide code does not already give, and it would be the
only credential in the lab no other service understands.

A session can also be unlocked by a **control proof** rather than the code. An
operator who opens a service UI from the dashboard's *Extension hosts* table
arrives holding one: the aggregator's `/go/stash` redirect mints it and leaves it
in the URL fragment, and the page spends it on `POST /api/unlock-proof`. That
saves going back to the dashboard to copy a code off a tile to act on a
page it just sent you to. The proof is the weakest of the three
credentials by design -- minted for one visit, valid for minutes, and redeemable
for nothing but a session on the service it was carried to, whereas the
6-character code can be exchanged for the internal authentication key itself.

A service VM is not normally given the internal authentication key (nothing bakes that file
into its seed), so it usually cannot check an arriving proof itself. It asks
`POST /api/v1/control-proof` on the aggregator, which is the same division of
labor the 6-character code already follows: validation stays with the daemon
that owns the secret. A service that *does* hold the token verifies locally and
makes no round trip.

`labgate` is that rule in code, and each area's `writeGate:` declares it, so
"which services gate their writes" is answerable without reading four route
tables.

- **`lab-token`** -- `pool-control-service` (pools, membership, test-set
  assignment), `download-agent-service` (delete a generation, force a
  re-download), `pool-aggregator-service` (`/ingest`, `/api/v1/forget-host`),
  `stash-service` (`DELETE` a stash, singly or a page-worth at once).
- **`none`** -- nothing at present.

`stash-service` is the one whose *reads* are the point: browsing and dropping a
file in stay open, because a guest pushing a diagnostic over `scp` must not need
a credential. Only `DELETE` is gated, and it is gated pool-wide rather than
per-host -- the stash share is mounted with write access to every host's folder,
so one unlocked UI can reclaim disk anywhere, including on a host that is
switched off.

Three properties come with the gate:

- **Reads stay open.** Catalogs, boards, artifacts and status are readable on the
  trusted LAN, matching `pool-status`. Gating them would make a credential a
  prerequisite for a host doing its job, and for a wall display rendering a board.
- **Fail closed, and say which.** A validator that cannot be reached answers
  `503` with reason `lab-token-unavailable`, never `401` -- an operator who
  cannot tell "wrong code" from "validator down" retypes a correct code until
  they give up. A service with neither credential configured answers `503`
  `auth-unconfigured` rather than running a write ungated.
- **Audited at the service.** Every unlock attempt is recorded with its source
  address. The aggregator's own audit cannot answer that question: from there,
  every operator in the lab is one source address.

`POST /announce` is the deliberate exception and stays open, contained
by self-identity binding, a health probe, bounded state, and being
telemetry-only ([below](#post-announce-pool-aggregator-service)).

### Building a new extension service

1. `test/extension/<area>/` with `<area>.config.yml` (`active:` + the `service:`
   block), `<area>.contract.yml`, and `default.psm1` exporting at least a status
   stub and a `Test-<Name>Host` `/healthz` preflight.
2. `server/` for the Go daemon. Import `beacon`, `pool` and `labgate` from
   `yuruna.com/test/extension/extension-sdk/...`; put every configuration write
   behind `gate.Require`. The SDK is staged beside `server/` at bring-up and
   resolved with
   `replace yuruna.com/test/extension/extension-sdk => ../extension-sdk`.
3. `test/Start-<Name>VM.ps1` / `Stop-<Name>VM.ps1` calling
   `Write-ExtensionServiceMarker` / `Remove-ExtensionServiceMarker` with the
   readiness verdict.
4. A guest bring-up script + `host/vmconfig/<area>.base.user-data` seeding
   `/etc/yuruna/pool.env` (`YURUNA_AGGREGATOR_URL`) and `/etc/yuruna/host.env`
   (`YURUNA_HOST_ID`), which is where the daemon's `--aggregator-url` and
   `--host-id` come from.
5. Add the `area` -> `displayName` value-mapping to
   [`grafana-pool-dashboard.json`](../test/extension/pool-aggregator-service/grafana-pool-dashboard.json)
   and its inline copy, so the Extension hosts cell reads the label rather than
   the slug.

The roster, the capability matrix, the registration record, the pool lookup and
the reboot sweep pick it up with no further edits.

### Service scripts run at `$ErrorActionPreference` Continue

Every service bring-up and teardown script leaves `$ErrorActionPreference` at
its inherited `Continue`, and must keep it there. A script-scoped `Stop` is not
scoped to the script: an advanced function invoked from it runs under the same
preference, so every helper the script calls has its NON-terminating errors
promoted to terminating ones.

Several steps are built on exactly that tolerance -- the storage preflight warns
and proceeds when the share does not answer, and the post-boot publish steps are
reported-never-fatal. Under `Stop` each of those designed outcomes ends the
bring-up instead, and its reason is left on a console that is gone by the time
anyone reads the run log.

Where a condition really must stop the script, it says so itself with an
explicit `Write-Error` followed by `exit`, the way the preflight hard gates do.
That keeps every stopping decision at the point that makes it, instead of
spreading it across every helper the script happens to call.

### A service that never served fails loudly

A bring-up that ends with no daemon serving exits non-zero. Warning-plus-zero is
not an option: the caller records the script's exit code as the step's outcome,
so a zero puts `<service>: PASS` in a run summary for a VM whose daemon does not
exist.

**An IP is not readiness.** `New-VM` confirms the VM has an address, but the
daemon still has to build INSIDE the guest -- apt, the Go toolchain, the build
itself, a CIFS mount, then a systemd start -- which takes several minutes on
first boot. Probe `:80` until it actually serves before declaring success.

**Gather the evidence before exiting.** A failing bring-up is the only moment
the guest is still up and answerable, so the in-guest build log, cloud-init
status and the service journal are pulled over the harness SSH key before the
script exits, and the operator sees why without SSHing in blind.
`/var/log/cloud-init-output.log` is root-only -- a plain `tail` as the service
account returns `Permission denied` -- which is why the seed gives the
`<service>-admin` account NOPASSWD sudo and the capture reads the log through
`sudo`. Pin that account with `-User`: it is the only login the VM has, and
`Get-GuestSshUser` would otherwise return a per-cycle cascade override that an
earlier run in the same shell session left registered for the guest key.

**Say what actually happened, not what the budget allowed.** Very different
failures reach this line -- an address that never answered; that address plus a
second one the last-resort lookup found, which was also silent; only the
last-resort address; or no address at all -- and quoting the nominal timeout for
the last of those describes a wait that never occurred, sending the reader to
look for a long in-guest build behind a failure that took seconds. Name every
address this host dialed, because the reader's next move is to check the guest's
own address against them, and one left out of the line is one they cannot rule
out.

## Bring-up knobs

Two sets, on opposite sides of the boundary.

**In the guest**, each bring-up script reads its own `<SERVICE>_*` variables
from the environment cloud-init runs it in, and every one has a working default
-- an unset variable is the normal case, not a missing setting. What they
configure ends up in the daemon's systemd unit, so a value only takes effect on
the bring-up that bakes it.

| Service | Variables |
|---|---|
| `stash-service` | `STASH_HTTP_ADDR` (`0.0.0.0:80`; set it EMPTY to disable the UI -- the script uses `-` rather than `:-` so an empty value survives), `STASH_AGGREGATOR_URL` (overrides the seeded `pool.env` value), `STASH_PRESENCE_INTERVAL`, `STASH_POOL_WINDOW_DAYS` (`30`), `STASH_BUILD_TAGS` (empty; `-tags magika` opts the image into the ONNX detection backend, which also needs the runtime and model assets vendored) |
| `download-agent-service` | `DOWNLOAD_AGENT_HTTP_ADDR` (`0.0.0.0:80`), `DOWNLOAD_AGENT_PRESENCE_INTERVAL`, `DOWNLOAD_AGENT_AUTH_TOKEN_FILE` (`/etc/yuruna/internal-auth.key`; an absent file disables the bearer path rather than opening it) |
| `pool-control-service` | `POOL_CONTROL_HTTP_ADDR` (`0.0.0.0:80`), `POOL_CONTROL_PRESENCE_INTERVAL`, `POOL_CONTROL_AUTH_TOKEN_FILE`, `POOL_CONTROL_SCAN_CIDR` (empty = derive the /24 around the daemon's own address), `POOL_CONTROL_SCAN_PORT` (`8080`), `POOL_CONTROL_SCAN_INTERVAL` (`15m`; empty disables the sweep, and is spelled `0` to the daemon because an empty duration is a flag parse error -- an operator's off switch must not become a service that will not start) |

`<SERVICE>_PRESENCE_INTERVAL` is the beacon cadence and defaults to `2m` in all
three. It must stay under the aggregator's five-minute health grace; see
[the manifest](#1-the-manifest--what-the-area-declares).

**On the host**, each `Start-<Service>VM.ps1` waits for the daemon to answer
`:80`, and the wait is overridable because first boot builds the daemon inside
the guest:

- `YURUNA_STASH_SERVICE_READY_TIMEOUT_SECONDS`
- `YURUNA_POOL_CONTROL_SERVICE_READY_TIMEOUT_SECONDS`
- `YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS`

All three default to **2700** seconds and take a positive integer; anything
else is ignored with a verbose note rather than failing the bring-up. The value
is a floor, not a ceiling: the wait extends itself beyond it -- to at most twice
the value -- for as long as the guest ITSELF answers over SSH that cloud-init is
still running, so a slow host is not failed for a build that was progressing.
The usual reason to set one is the opposite case: a short value for a quick
re-check against a VM already up.

## Running the caching-proxy service from another host

The `caching-proxy-service` daemon is the one extension service written to run
somewhere other than the VM it describes. Everything it reads is an API or a
file on a share -- never a local socket, never a systemd call -- so the same
binary answers from the proxy VM or from a machine that can reach it.

**The data plane never moves.** Squid (`:3128`, `:3129`), zot (`:5000`),
Grafana, Prometheus, Loki and the exporters stay on the caching-proxy VM in
either mode. What relocates is the management plane: reading state and flipping
switches. Moving it buys isolation -- a management plane that survives the box
it reports on -- and costs a network hop per read.

| | `--mode local` (default) | `--mode remote` |
|---|---|---|
| squid summary | manager pages over loopback | manager pages over the LAN, which needs the ACL below |
| switch state | the `conf.d` drop-ins themselves | inferred from squid's running config, and says so |
| switch changes | writes the drop-in, `squid -k reconfigure` | **501 `caching-proxy-remote-readonly`** |
| zot catalog | zot's API over loopback | zot's API over the LAN |
| canary verdict | `/zot-meta` over loopback | `/zot-meta` over the LAN |
| prewarm record | `/var/lib/yuruna` on the box | absent unless the share is mounted |

Remote mode is **read-only, and refuses rather than pretends**. Stock squid has
no remote reconfigure: a change made off the box could be written but never
loaded, so both switch routes answer `501` with reason
`caching-proxy-remote-readonly` and name the mode that refused. That is a
statement about squid, not about permissions -- which is why it is `501` and
not `403`, and why an on-box agent is what would lift it.

**The manager ACL is the one prerequisite, and it is not a drop-in.** Stock
`squid.conf` runs `http_access deny manager` well before it includes
`conf.d/*.conf`, and `http_access` is first-match-wins -- so an allow rule added
in a drop-in is dead code. Opening the manager interface to a remote reader
means editing `squid.conf` itself, above that deny, and pairing it with a
`cachemgr_passwd`. Nothing in the shipped seed does this: local mode does not
need it (loopback is already allowed by the stock `allow localhost manager`),
and opening squid's manager interface to the LAN is a posture change no VM
should get for a mode it is not running.

## MCP endpoints

Every Go daemon serves the Model Context Protocol at `POST /mcp` on the port it
already listens on, and the core framework serves it on stdio. The rule the
whole surface is built on is that **MCP adds a protocol, never a second
truth**: a tool wraps a route or a script that already exists, and inherits the
gate that route already declares.

That is enforced structurally rather than by discipline. These daemons build
their read payloads inside the handler, so a hand-written tool would mean the
same shape maintained twice; instead `mcp.FromRoute` INVOKES the route handler
in-process and returns what it wrote. One body, produced once, by one function
-- a tool cannot answer differently from the route it wraps, and the per-daemon
suites assert the two match.

| Service | Endpoint | Tools |
|---|---|---|
| `pool-aggregator-service` | `POST :9400/mcp` | `pool_status`, `pool_extension_hosts`, `pool_stats` |
| `caching-proxy-service` | `POST :9310/mcp` | `caching_proxy_status`, `caching_proxy_switches`, `caching_proxy_hostinfo`, and the gated `caching_proxy_set_offline` / `caching_proxy_set_no_upstream` |
| `stash-service` | `POST :80/mcp` | `stash_list`, `stash_hostinfo`, `stash_session` |
| `pool-control-service` | `POST :80/mcp` | `pool_control_board`, `pool_control_hosts`, `pool_control_host_facts`, `pool_control_state`, `pool_control_diagnostics`, `pool_control_hostinfo` |
| `download-agent-service` | `POST :80/mcp` | `download_agent_status`, `download_agent_images`, `download_agent_diagnostics`, `download_agent_hostinfo` |
| core framework | `test/service/Start-McpServer.ps1` (stdio) | the ten `automation/` entry points |

`caching-proxy-parser-service` is deliberately absent: it has no auth story at
all, so there is no gate for a mutating tool to inherit and nothing to make
read-only tools a considered decision rather than a default.

### What a tool may do, and who decides

The annotation on each tool is the same claim its route makes:

- **Read-only tools skip the gate** and carry exactly the exposure of the GET
  route they wrap -- open on the trusted LAN, matching `pool-status`. Gating
  them would make a credential a prerequisite for reading a board.
- **Mutating tools pass the daemon's own labgate**, through the identical
  three-way answer its HTTP routes give: `503` with reason `auth-unconfigured`
  when the service has no way in configured at all, `401`-equivalent when the
  gate exists and the caller has not passed it, and through otherwise.
- **A domain refusal keeps its own token.** A caching-proxy daemon in remote
  mode refuses `caching_proxy_set_offline` with
  `caching-proxy-remote-readonly`, the same string its `501` body carries, so an
  operator who knows one knows the other.

Only four daemons mount a mutating tool at all, and three of them mount none.
That is a decision per service rather than an oversight: the aggregator's
mutations are a telemetry firehose and a route that deletes evidence an
operator may be mid-way through reading; pool-control's each commit and push
the pool intent store; stash's `DELETE` reaches every host's stash on the shared
mount, not just its own; and the download agent's `ensure` route is
**deliberately ungated** on the HTTP side, so a tool for it could not both
mirror its route's gate and honor the rule that a mutating tool takes the lab
token. Reconciling that contradiction comes before it gets a tool.

### Why stdio for the core, and only stdio

The core framework's entry points are scripts an operator runs on their own
machine, so its server runs foreground on stdin/stdout with no listener, no
token and no gate. The transport IS the trust model: a process reading one
operator's stdin was started by that operator and can do exactly what they can
already do by typing the same command. A credential there would protect nothing
and imply a boundary that does not exist.

That server also reads each entry point the way that entry point actually
answers, because they are not uniform: `Test-Runtime` has no exit statement and
reports its verdict as the last pipeline object; `Get-SystemDiagnostic` always
exits 0, so a zero means the report was produced and never that the host is
well; `Check-DependencyVersion` emits JSON natively and is passed through; and
`Set-HostAlias` writes no transcript, so a thrown error is its only failure
signal. Reading any of those by exit code alone reports the wrong thing.

### Connecting a client

```json
{
  "mcpServers": {
    "yuruna-core": {
      "command": "pwsh",
      "args": ["-NoProfile", "-File", "test/service/Start-McpServer.ps1"]
    },
    "yuruna-pool": { "url": "http://<proxy>:9400/mcp" },
    "yuruna-cache": { "url": "http://<proxy>:9310/mcp" }
  }
}
```

A JSON-RPC error is still HTTP `200`: the RPC layer answered, and a non-200
would say the transport failed, which is a different fact and sends a reader
looking in the wrong place. Notifications get `202` and no body.

## Which framework snapshot a service VM is built from

The extension service daemons are Go binaries whose version is stamped at
COMPILE time, read from the `VERSION` file of whatever enlistment the guest
fetched. Nothing re-reads it afterwards: the guest builds once, and the number
it prints on its UI, in `/api/hostinfo` and in every diagnostics payload is
frozen there for the life of the VM.

The stamping is a linker flag, not a file the daemon opens. Each guest
bring-up reads the enlistment's `VERSION`, keeps the first line with whitespace
stripped (a trailing newline or a CRLF would otherwise become part of the
version string), falls back to `dev` when the file is missing or empty, and
compiles with:

```
go build -ldflags "-X main.version=$VERSION_STR" -o <daemon> .
```

Every daemon therefore declares a package-level `var version` that the linker
overwrites. Lose the flag and the build still succeeds -- the variable keeps
its zero value, the UI footer renders `dev` or nothing at all, and
`Assert-ServiceVmFrameworkSource` can no longer tell which enlistment the VM
came from. That is why each daemon's suite asserts the `version` field of
`/api/hostinfo` rather than only its shape.

That makes the fetch the whole story. The cloud-init seed pulls this host's
enlistment from the host status service (`/yuruna-archive.tar.gz`, with the
coordinates sed-read out of `/etc/yuruna/host.env`, never sourced) and falls
back to cloning the public GitHub mirror when the host does not answer, so a
bring-up still works off-LAN. The two sources are NOT equivalent: the host
serves the enlistment the operator is working in, while the mirror is a
published snapshot that lags it by however long since the last release push.
Whichever wins is compiled into the daemon minutes later, so a silent fall back
to the mirror deploys older code that then reports itself as current forever.

The status service therefore has to be up BEFORE `New-VM` bakes and boots the
guest, not after -- a server started later is one the guest never saw. The
bring-up keeps the `{ShouldStart; Port}` record that decision produced rather
than discarding it, because the framework-source gate later has to probe the
port this decision resolved; re-deriving it would be a second reading of the
same config, free to disagree with the reading that actually started the server.

Two checks bracket the build, and only one of them is evidence:

- **Before the build**, `Assert-GuestFrameworkSource` refuses a bring-up whose
  guest could not possibly reach this host's enlistment. It is a cheap early
  stop that saves the long in-guest build, nothing more. It cannot prove which
  address the seed will end up baking, because that is resolved per host type
  inside `New-VM.ps1`.
- **After the daemon serves**, `Assert-ServiceVmFrameworkSource` reads what the
  guest ACTUALLY did (`/etc/yuruna/framework-source`, written by the seed and
  left world-readable so the unprivileged service account can read it) against
  what the daemon actually reports (`/api/hostinfo`). That one is authoritative,
  and it is the check that fails a bring-up.

The split is the point: the preflight is a prediction and the post-boot check
is an observation, so only the second may be trusted to say a deployed service
runs current code. The preflight can pass and the guest still fall back -- the
host address is baked at seed time and the guest reaches for it minutes into
first boot, so a host that renumbered in between sends the fetch to the mirror
with everything on this side looking correct.

A mismatch fails the bring-up but does NOT retract the runtime marker. A stale
build is still a running service, and withdrawing the row would replace an
accurate advertisement with a false one; what is wrong is the bring-up's claim
to have deployed this enlistment, so that is what fails. `-AllowMirrorSource` is
the deliberate escape for an off-LAN bring-up: it downgrades both checks to a
warning, and the service then runs published code on purpose.

## Finding a service this host does not run

A host that needs a network service -- the stash service, pool-control service,
download-agent service -- usually does not run it: the service lives on another
host, often another subnet, at an address DHCP is free to change. Nothing in
this host's config knows where it is, so the alternative is a hard-coded literal
that is correct only until the service moves -- and then a cycle spends its whole
timeout budget on a machine that no longer exists.

`Get-ExtensionHostAddress` is the one call client code makes instead:

```powershell
Import-Module test/modules/Test.Extension.psm1 -Force -DisableNameChecking
# @() because a single address unrolls to a scalar, and an empty result to
# nothing at all -- the same rule as Get-ActiveExtensionName.
$addresses = @(Get-ExtensionHostAddress -HostType 'stash-service')
foreach ($address in $addresses) {
    if (Test-StashServiceHost -Address $address) { $stash = $address; break }
}
```

`-HostType` is the **extension area slug** naming the kind of service
(`stash-service`, `pool-control-service`, `download-agent-service`) -- unrelated
to the hypervisor host type `Get-HostType` returns (`host.windows.hyper-v`).

The answer is a **list, nearest first**, and may be empty:

| Order | Source | Answers for |
|---|---|---|
| 1 | `$env:YURUNA_EXTENSION_HOST_<AREA>` -- area upper-cased, non-alphanumerics -> `_` (e.g. `YURUNA_EXTENSION_HOST_STASH_SERVICE`, `YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE`) | an operator who states an address; it is meant, so nothing discovered outranks it |
| 2 | Host contract `Get-VMIp` on `yuruna-<area>` (override with `-VMName`, `''` skips it) -- `yuruna-stash-service`, `yuruna-pool-control-service`, `yuruna-download-agent-service` | a service VM running on **this** host, at its current address across rebuilds |
| 3 | The pool -- the aggregator's [`/api/v1/extension-hosts`](../test/extension/pool-aggregator-service/README.md#endpoints-9400), read through `Get-PoolExtensionHost` | a service running on **another** host, from its own registration/announce record -- and only at an address the aggregator has itself reached (see [below](#only-an-address-the-pool-has-reached-is-answered)) |

Since the aggregator lives in the caching-proxy-service VM, knowing the proxy
address -- which every host needs anyway, to reach the cache at all -- is
enough to locate every other service the pool offers. A host with no
caching-proxy service has no aggregator to ask and no pool: that source
contributes nothing.

A list rather than one answer, because only the caller can say which
address is usable: it holds the probe (the stash preflight demands
`/healthz`, and `Test-DownloadAgentServiceHost` gates every download-agent
candidate the same way), it may prefer a particular subnet, and it usually has a
site-specific last resort to append. **Every entry is a hint, never a
promise** -- prove one before committing a cycle to it. The lookup
is unauthenticated and does not verify the aggregator's TLS leaf (minted by
the proxy's own CA, which a harness host has no trust-store entry for); the
payload is LAN service coordinates, not a secret, and a wrong answer fails
closed at the caller's probe.

It never throws. Each source is independent -- a pool that does not answer,
a host contract without `Get-VMIp`, an area nobody serves -- and any of them
coming up empty shortens the list. Addresses carrying whitespace or a
quote are dropped: they end up composed into URLs, `scp` targets and
single-quoted guest env lines, where such a value corrupts the command
rather than failing it.

The stash extension's `Resolve-Host` (what
`${ext:stash-service.ResolveHost(<vm>)}` expands to) consults it last,
after the local VM and the address the cycle's preflight already verified.

#### Asking the pool directly, and why an empty answer is not one answer

Source 3 is the pool-aggregator area's own module, and a caller that wants only
that source can use it directly:

```powershell
$address = Get-PoolExtensionHostFrom -BaseUrl $aggregatorUrl -Area 'stash-service'
if (-not $address) {
    $why = Get-PoolExtensionHostLastOutcome
    # $why.Outcome: 'no-host' | 'http-error' | 'transport-error' | 'no-aggregator' | 'ok' | 'none'
}
```

`Get-PoolExtensionHostFrom` returns a bare string so it can never throw into a
cycle, which means every failure looks identical at the call site. Two of them
are not remotely the same thing: **`no-host`** is a settled answer -- the pool
says nobody serves this area -- while **`transport-error`** is a statement about
the asker's own link, and usually cures itself. A caller that stops a cycle on
the empty string reports the first when it saw the second, and sends an operator
looking for a service that was running the whole time.

`Get-PoolExtensionHostLastOutcome` is where the reason is kept: a hashtable of
`Outcome`, `Detail` and `Uri`. It is **session-scoped and overwritten by every
lookup**, so read it immediately after the call it belongs to. A transport
failure also warns rather than logging verbosely, because it is the shape that
stops cycles.

### Only an address the pool has reached is answered

Source 3 answers with an address **the aggregator has itself confirmed** at
`<target>/healthz`, and re-confirms every poll. The reason is the one class
of wrong answer a consumer cannot defend against: an address that is real
on the host that advertised it and unreachable everywhere else.

A host runs two kinds of guest network -- the LAN it shares with every other
machine, and a hypervisor-private one only it can see (the macOS shared
vmnet, a Hyper-V Default Switch, libvirt's `virbr0`). Both look identical
from that host: an RFC 1918 address on a live interface, answering
`/healthz`. So a stash VM that came up on the private one is confirmed in
good faith and registered pool-wide; every OTHER host then resolves it and
spends its whole timeout budget on a machine it cannot route to -- after
which the cycle stops, having built nothing.

Two checks close it, at the two places that can each see one half:

- the **owning host** refuses to advertise an address off its own
  pool-facing network (`Update-StashServiceMarkerAddress`, judged by
  `Get-Ipv4PoolSegmentVerdict`), so the address never enters
  `host.registration.json`. It only *refuses*, never insists: an
  undeterminable segment permits, and the service stays usable locally;
- the **aggregator** refuses any address it cannot reach itself, whichever
  source named it, and stops answering with a confirmed one that stays
  silent for 5 minutes. It sits where the consumers sit, so its probe is the
  only check that speaks for the pool rather than for one host.

A refused address is **suppressed, not forgotten**: the entry stays, naming
the address it refused and why, until the announce TTL or a goodbye removes
it. The usual cause of an address going silent is a service that renumbered,
and it re-announces from the new address within a beacon period -- which is
why `beaconInterval` must stay under those 5 minutes. Slower, and the pool
holds neither address for the difference: an area that resolves to nothing,
while the service is up and reachable the whole time. Keeping the entry also
keeps the failure legible, as `yuruna_pool_extension_unreachable` and a
`suppressed` entry in `/api/v1/extension-hosts`'s `services` -- "advertised
at X, which does not answer" rather than a silent absence.

`Test-Config.ps1`'s *Extension services (pool registry)* section reports
what the pool holds -- including a registration it has refused, and one it
still advertises that this host cannot reach -- so the whole class is
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
Get-Password` can resolve to the wrong area's module.
`Resolve-ExtensionMethod` matches modules by absolute `.psm1` path
instead, so the intended exports are always found.

## Adding a new extension to an existing area

1. Create `<extname>.psm1` in `test/extension/<area>/`.
2. Add `<extname>` to the `active:` list in `<area>.config.yml`.
3. The loader imports it on the next cycle; sequence YAML references
   to `${ext:<area>.Method(...)}` route to the new module if it
   exports `Method`.

For `notification`, multiple active extensions iterate in declaration
order -- every transport sees every event. For `authentication`, the
loader expects **exactly one** active extension and throws on
ambiguity (`-RequireSingle`).

## Adding a new area

1. Create `test/extension/<newarea>/` with a `default.psm1` and a
   `<newarea>.config.yml`.
2. Add the area to the
   [capability matrix](test-harness.md#capability-matrix-and-cycle-plan-gate) by existing --
   `Get-CapabilityExtensionArea` discovers areas by directory, not
   by a hardcoded list.
3. Document the contract the area's `.psm1` files must export. A future
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
internal authentication key would kill the beacon exactly where it is needed.
Containment instead:

1. **Self-identity binding** -- the advertised service URL is derived from
   (or must match) the connection's source IP, so an announcer can only
   advertise itself, and must be an address the pool could route to at all
   (loopback, link-local, multicast and non-URL values are rejected `400`).
2. **Telemetry-only** -- paints a dashboard row and redirect target; no
   control plane, host probing, or cycle accounting.
3. **Bounded** -- tiny body cap, strict hostId/area charsets, at most
   `maxAnnounce` entries, TTL reap.
4. **Goodbyes only remove an entry the same source owns.**
5. **Confirmed before it is answered** -- the handler probes a newly
   announced address at `/healthz` (see
   [above](#only-an-address-the-pool-has-reached-is-answered)), and the poll
   re-confirms it; an entry that stays unanswered for 5 minutes is removed
   as if it had said goodbye. An announce is a claim to be checked, not a
   fact to be republished.

**`2xx` means recorded, not merely received.** The entry itself lives in the
collector's memory; the Loki line the handler writes is the only copy that
survives a restart, and rehydrate restores the row afterwards. So when
that write does not land the handler answers `503` -- the announce is kept and
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
  -- including the `/go/host` redirect that mints a control proof -- follows the
  TTL upward but never drops below 24h, so shortening the TTL cannot 404 a link
  the dashboard still displays. (`/go/cycle` and `/go/cycle-share` share one
  resolver, and its cycle-folder match keeps a separate fixed 6h window.)

This does **not** bound the cumulative `yuruna_pool_cycles_pass_total` /
`_fail_total` counters: those never time-expire, and survive until the
process restarts or `POST /api/v1/forget-host` clears that host. Shortening the
TTL also does not by itself evict a host that keeps being re-seeded from the
presence feed on restart -- `Remove-PoolHost.ps1` / forget-host is the
deterministic path.

To change it, edit `pool-aggregator-service.service` and run
`systemctl daemon-reload && systemctl restart pool-aggregator-service` -- no rebuild.
**`daemon-reload` is not optional:** a bare restart re-execs systemd's cached
unit and the old value stays in force. A drop-in works too, but the unit is
`Type=simple`, so the drop-in must reset `ExecStart` first (`ExecStart=` on its
own line, then the full replacement) or systemd refuses to load the service. A
non-positive value falls back to the 24h default. Older binaries do not carry
the flag -- on an older proxy, check
`pool-aggregator-service -h | grep host-ttl` before adding it, or the service crash-loops
on `flag provided but not defined`.

### When the caching proxy is rebuilt

The beacon's aggregator URL is baked into the guest seed at `New-VM` time
(`Get-PoolAggregatorServiceSeedUrl` -> `YURUNA_AGGREGATOR_URL` in
`/etc/yuruna/pool.env` -> `--aggregator-url`) and is never re-resolved in-guest.
So whether an extension host re-registers itself turns on the rebuilt proxy's
address, not on the rebuild:

- **Same address** -- yes, unprompted, within one beacon period (2 min). The
  handler accepts an announce from a `hostId` the pool has never seen and
  confirms the target itself, so the row needs no prior discovery. The
  *registration*-sourced row takes longer: a rebuilt proxy starts with an empty
  squid log and an empty Loki, so the owning host is re-discovered only once it
  next pulls through the proxy.
- **New address** -- no. Every rebuild draws a fresh MAC and therefore a new DHCP
  lease, and the beacon keeps posting to the address that is gone. Either pin the
  proxy's MAC to a DHCP reservation
  ([caching.md](caching.md#pinning-the-cache-vms-ip-stable-mac--dhcp-reservation))
  so the rebuild keeps its address, or re-run the service's
  `Start-*ServiceVM.ps1`, which rebuilds the VM through `New-VM.ps1` and re-bakes
  the current one.

Hosts themselves need neither: host-side consumers re-resolve the proxy on every
run. Enrollment is separate -- a rebuilt proxy mints a new internal authentication key, so
each host stays *onsite* until `Set-LabToken.ps1` re-enrolls it
([control-routes.md](control-routes.md#enabling-remote-control-on-a-host)).

## POST /api/v1/host-announce (pool-aggregator-service)

The host-level counterpart to `/announce`: a **host** POSTs
`{"hostId":"<42-hex>","statusPort":<port>}` when its address changes, when its
status service starts, and on a periodic beacon.

It exists because squid-log discovery is pull-only, and so lags exactly when it
matters. A host enters the log only when it or its guests pull through the
proxy, so between cycles the view ages out and the address it still holds is the
one the host has just left -- and a guest resolving through that view gets an
answer that is confidently wrong. This route moves a host's address inside the
host view that `pool-status`, the `/go/*` redirects and the guest resolver all
read. `/announce`, by contrast, is area-scoped *extension* presence.

Containment mirrors `/announce`, with one gate deliberately stronger:

1. **Self-identity bound.** The address is taken from the connection, never the
   body, so an announcer can only advertise itself.
2. **Confirmed, not believed -- on identity.** `/announce` probes `/healthz`;
   this one fetches the announced address's own `/runtime/status.json` and
   requires the `hostId` THERE to equal the claimed one. The claim being made is
   an identity, so identity is what gets checked: a machine that cannot serve
   that host's `status.json` cannot rename itself into that host's place.
3. **Bounded.** Same body cap and hostId charset as `/announce`.
4. **No bearer**, for the same reason `/announce` has none -- requiring the
   internal authentication key would kill the beacon in exactly the labs that need it. The
   route relocates an existing identity and confers no control-plane capability.

`400` covers a malformed body, a bad hostId or `statusPort`, an address the pool
could not route to, an address that did not serve `status.json`, and an address
that served a *different* hostId. `503` when `-announce-ttl` is `0`. As with
`/announce`, a 2xx means **recorded**, not merely received.

## POST /api/v1/lab-token (pool-aggregator-service)

The enrollment exchange: a host redeems the 6-character lab connection
token shown on the dashboard's "Lab token" tile (body
`{"labToken":"<6 chars>"}`) and receives the internal authentication key --
`200 {"ok":true,"v":1,"salt":...,"nonce":...,"ciphertext":...,"tag":...}`;
`400` malformed, `403` unknown/expired code, `429` per-IP throttle,
`503` disabled. The route is open -- the caller is by definition a host
that does not yet hold that key -- and contained by the
short-lived rotating code (`-lab-token-rotate`, default `60s`; a
displayed code stays redeemable for about three rotations), the
per-address throttle, and an audit of every attempt (aggregator log +
Loki, label `src="lab-token"`; the code is never logged).

The answer is **sealed under the redeemed code**: AES-256-GCM with a
PBKDF2-HMAC-SHA256 key over that code and a fresh salt (associated data
`yuruna-lab-token|v1`). That authenticates the aggregator to a
host that cannot verify its TLS leaf -- the proxy's own CA signs it, and
an enrolling host has no reason to trust that CA yet -- so nothing else
on the path can answer the exchange and plant a token the host would
then honor for control proofs. It also keeps the key off the
wire in the clear when the proxy runs plain HTTP (no TLS leaf).
`pwsh test/lab/Set-LabToken.ps1 -LabToken <code>` is the client
(`Unprotect-LabTokenEnvelope` opens the envelope; a seal that does not
authenticate is refused, never stored); `-lab-token-rotate 0` disables
the exchange and the dashboard tile.
See [`pool-aggregator-service/README.md`](../test/extension/pool-aggregator-service/README.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.27

Back to [Yuruna](../README.md)
