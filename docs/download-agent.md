# Yuruna download-agent service -- one download for the whole lab

> **Who this is for.** An operator running Yuruna test hosts against a shared
> pool NAS who is tired of every host pulling the same multi-gigabyte ISO from
> the internet. It is not a guide to writing test sequences. It assumes the
> **pool storage tier is already configured** (`networkStorage.pool*` in
> `test/test.config.yml`); without a share there is nowhere for the image pool to
> live and the service is skipped.

## What it is

The **download-agent service** is an extension service VM
(`yuruna-download-agent-service`) that owns a **Download pool** on the pool
share. It resolves each guest image the way the host scripts do, downloads it
once, verifies the publisher checksum, stores it under a content-addressed
generation name, and serves the bytes over HTTP with `Range` support. A
background scanner re-checks each image against its origin on a schedule so the
pool never drifts silently out of date, and an embedded web UI shows what the
pool holds and what it costs in disk, and can force a refresh, a delete, or a
prune.

Three properties shape everything else:

- **Degrade, never fail.** The agent is an optimization. A host that cannot
  reach it, an agent whose pool share is unmounted, an origin that is down: each
  falls back to the behavior of a lab with no agent. Nothing about the agent can
  fail a test cycle.
- **Reads are open, writes are gated.** The UI, the catalog, the metadata, the
  bytes, and `/healthz` answer any client on the trusted LAN. Refresh, delete,
  and prune require the dashboard's rotating Lab token or the lab-auth token.
- **The pool is the durable part.** The VM is disposable -- stopping the service
  destroys it, and starting it rebuilds from the base image. Everything
  downloaded lives on the pool share and is adopted again by the rebuilt agent.

Every host-side `Get-Image.ps1` asks the agent before it contacts a publisher —
the Ubuntu Server ISOs, the shared extension cloud image, Amazon Linux 2023,
virtio-win, and (best effort) the Windows 11 media. What each script does with
the answer is in
[guest-image-setup.md](guest-image-setup.md#agent-first-image-downloads): a host
holding the current artifact stops immediately, a host that needs bytes takes
them from the LAN, and anything else falls back to the publisher path with the
same output and exit codes as a lab that runs no agent.

## Activating it

The agent activates the same way in **Standalone** and **Lab** mode: whenever
pool storage is configured, `install/setup.ps1` runs the stop/start pair for it.
The step is non-critical -- a failed agent build never fails setup, because
everything degrades to the no-agent path.

To bring it up or rebuild it by hand:

```powershell
pwsh test/Start-DownloadAgentServiceVM.ps1 [-VMName yuruna-download-agent-service]
pwsh test/Stop-DownloadAgentServiceVM.ps1   # tears the VM down; the pool is untouched
```

`Start-DownloadAgentServiceVM.ps1`, in order:

1. **Gates on the pool credential.** A NAS user with no *stored* password is a
   hard stop before anything is built: a mapped-but-unstored vault key would
   make the guest seed bake an auto-generated value the NAS rejects
   (`cifs mount error(13)`), and the VM would come up serving an empty pool. A
   credential that is stored but does not authenticate is a warning only -- the
   daemon runs fine against an offline share, reporting `poolAvailable:false`.
2. **Starts the host status service first.** The guest fetches the framework
   archive from `http://<host>:<port>/yuruna-archive.tar.gz` minutes into its
   first boot. A status service started *after* the build is one the guest never
   saw.
3. **Delegates to `host/<platform>/guest.download-agent-service/New-VM.ps1`**,
   which builds the seed and the VM. The Go daemon is compiled **inside** the
   guest -- no host `go` toolchain is needed.
4. **Waits for `:80` to actually serve**, up to 15 minutes. An IP is not "up":
   the guest still has to install the toolchain, build the daemon, and mount the
   share. Override the budget with
   `YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS=<seconds>` -- useful for
   a quick re-check of a VM that is already running.
5. **Publishes the marker with the readiness verdict**, then refreshes the host
   registration so the dashboard picks it up within one aggregator poll.

On Windows the script needs an elevated session (Hyper-V VM creation), and says
so before it changes anything rather than half-way through.

If `:80` never comes up, the script SSHes into the guest with the harness key and
prints `cloud-init status`, the unit's journal, the listener table, the pool
mount state, and the tail of `/var/log/cloud-init-output.log` -- so a failed build
shows the reason instead of a dead URL.

## The Download pool

Everything lives under the pool share:

```
<pool root>/
  images/
    .agent-lease.json                      single-writer lease
    <hostType>/<imageKey>/
      current.<arch>.<variant>.json        pointer -- written LAST
      <upstreamFilename>.<sha256[:12]>            generation artifact
      <upstreamFilename>.<sha256[:12]>.meta.json  its sidecar
      <older generation> + sidecar                one previous, retained
      .staging/                            agent-private, swept on every scan
  download-agent-service/
    audit.jsonl                            one line per unlock and mutation
    status.json                            last snapshot
```

- `<hostType>` is `windows.hyper-v`, `ubuntu.kvm`, or `macos.utm`.
- `<imageKey>` is the guest folder name (`guest.ubuntu.server.24`,
  `guest.ubuntu.server.26`, `guest.amazon.linux.2023`, `guest.windows.11`),
  except the extension service guests, which share one pooled artifact under
  `ubuntu.extension.26`, and auxiliary artifacts, which get a key of their own
  (`virtio-win`).
- The full identity of one entry is `(hostType, imageKey, arch, variant)`, with
  `arch` in `amd64|arm64` and `variant` in `stable|daily`. `variant` names the
  *requested preference*, so two preferences that resolve to the same artifact
  keep separate pointers.

**Why generation names instead of plain upstream filenames.** Several families
publish a fixed filename whose content changes (the cloud image, daily ISOs).
With plain names, promoting a new download would rename over the previous
generation -- destroying retention -- and over a file the daemon may be
streaming to a host, which SMB does not do atomically. With
generations, a refresh writes into `.staging/`, verifies, renames into place,
writes the sidecar, and only then replaces the tiny pointer file. A reader
already streaming keeps its handle on the old generation. Content addressing
also gives free dedup: a re-download whose hash matches an existing generation
just re-stamps freshness and rewrites the pointer.

**Retention** is the pointer's generation plus one previous, per identity.

**The lease.** Nothing stops two machines sharing one NAS from each running an
agent, so the agents keep a lease at `images/.agent-lease.json`,
renewed every scan and considered expired after three scan intervals. An agent
that finds a live lease held by someone else enters **read-only mode**: it still
serves committed generations and answers metadata, but defers downloads to the
holder and reports `leaseHolder` in its status. Correctness never depends on the
lease -- generation-addressed storage makes concurrent writers safe on its own;
the lease only makes duplicate work rare.

## Freshness and the scanner

An image is **fresh** for `freshnessSeconds` after its `lastVerifiedAt`, which is
stamped whenever a direct origin probe matches the stored metadata (filename,
URL, `Content-Length`, `Last-Modified` -- the same four fields the host-side
skip-guard compares). Every `scanIntervalSeconds` the agent walks the pool and
acts on anything whose freshness expires within `prefetchLeadSeconds`:

- **Probe matches** -> `lastVerifiedAt` is bumped. No bytes move. This is the
  common case, and nearly free.
- **Probe differs** (new point release, changed length) -> a single-flight
  download runs, the checksum is verified, a new generation is written, and the
  pointer flips. If it fails, the **previous verified artifact stays servable**
  and the next scan retries.
- **Origin unreachable** -> nothing is stamped. The pool serves stale rather than
  certifying staleness as freshness.

Two caching-proxy rules are load-bearing and easy to get backwards:

| Traffic | Path | Why |
|---|---|---|
| Byte downloads | squid first (`:3128` / ssl-bump `:3129`), direct on any proxy failure including the offline-mode `504` | The bytes are exactly what a cache is for |
| Freshness probes and resolver fetches | **always direct** | The proxy pins `.iso`/`.zip` with `override-expire override-lastmod` and runs `offline_mode` after prewarm. A proxied `HEAD` returns frozen prewarm-era headers as a success, which would certify staleness as freshness forever |

**Seeding.** Content enters the pool three ways. With `autoSeed` on (the
default), each scan reads the pool aggregator's host roster, derives the host
types present, infers arch from host type, and pre-downloads the stable families
for them, at most two seed downloads at a time so seeding never starves an
interactive request. Beyond that, a host's first request creates an entry on
demand, and the UI's Force refresh creates one manually. Hosts the aggregator has
no status for, and arm64 KVM hosts (the roster carries no arch field), are
covered on demand -- never an error. `guest.windows.11` and `virtio-win` are
never seeded: a best-effort family should not spend seed bandwidth, and
virtio-win is wanted only by hosts that build a Windows guest.

## Windows 11: a best-effort family, and what it is worth

Microsoft publishes no fetchable URL for the Windows 11 media. The page mints a
short-lived signed one per visit, which is why every `guest.windows.11`
`Get-Image.ps1` either drives **Fido** (a PowerShell script that asks for that
URL the way the page does) or, on KVM, gives up and prints manual instructions.

The agent does the same centrally: its VM installs PowerShell and vendors Fido --
the same tagged release, verified against the same SHA-256, that the host scripts
pin -- and the daemon runs it to mint a URL and download once for the lab.

**Be clear-eyed about this one.** Best effort means exactly that:

- **Fido under PowerShell on Linux is unproven.** It is a Windows-oriented
  script; nothing guarantees the request flow it drives keeps working there, or
  survives a Microsoft page change.
- **The minted URL is short-lived**, so the daemon has to download immediately
  on resolve; there is no stored URL to re-check later. Freshness for this one
  family therefore compares filename and size only, never the URL -- every
  resolve produces a different one.
- **PowerShell and Fido are both best-effort installs.** Either can be missing
  after a build. The cloud-init log says which state the VM is in --
  look for the `Windows 11 family ENABLED` or `Windows 11 family UNAVAILABLE`
  line in `/var/log/cloud-init-output.log`.

When any of that fails, the agent reports the family **absent** and the hosts
silently do what they always do: Hyper-V and UTM run Fido themselves, KVM asks
for a manual download. Nothing regresses, and nothing warns -- an agent that does
not hold Windows media is an ordinary state, not a fault.

**The gain, when it works, is real but uneven.** On Hyper-V and UTM it saves a
repeated multi-gigabyte pull. On **KVM it is a new capability**: that script has
never had an automated path -- it exits non-zero with instructions until an
operator drops an ISO in place -- so a pool holding the media turns a manual step
into an unattended one.

**virtio-win is not best effort.** The KVM Windows guest also needs Fedora's
signed driver ISO: a plain pinned URL the agent resolves like any other family,
seeded on demand and served from the pool like the Ubuntu images.

**These are build-time additions to the agent VM.** An agent VM built before
them has no PowerShell and no Fido; rebuild it (`Stop-` then
`Start-DownloadAgentServiceVM.ps1`, which is what a setup re-run does anyway) to
pick them up.

## The web UI

The daemon serves a single-page UI at `/`, reachable from the Extension hosts
table's deep-link or directly at the base URL the marker publishes. Reads are
open on the LAN; the page polls the same `GET /api/v1/images` that automation
uses, so the UI has no private endpoints.

### What you can see

**Agent header** -- daemon version; pool availability; lease state (holder, or
read-only when another agent holds it); scanner cadence with last and next scan
time; auto-seed status and the last seed outcome.

**One row per `(hostType, imageKey, arch, variant)`:**

| Field | What it tells you |
|---|---|
| State badge | `fresh`, `stale`, `downloading`, `failed`, `absent` |
| Upstream filename | The current generation's real name, as published |
| Size on disk | Current plus previous generation -- what this row costs |
| `lastVerifiedAt` + time to expiry | When the origin last confirmed these bytes, and when the scanner will look again |
| `checksumVerdict` | `verified` (publisher checksum matched), `unpublished` (family publishes none), `none` |
| `sourceUrl` / `downloadedAt` | Provenance: exactly where these bytes came from and when |
| Progress | `bytesDone`/`bytesTotal` while a download is in flight |
| Last error | On a `failed` row, the string the attempt died with |

**Totals row** -- pool bytes used, with per-hostType subtotals: the answer to
"what is eating the share".

### Sorting the table

Every column header except Actions is a button: click to sort by that column,
click again to reverse. The arrow says which column is active and which way it
runs. The choice is remembered in the browser and survives a reload.

Two columns deliberately do not sort alphabetically, because their text is not
the question:

- **State** sorts by severity -- `failed`, `downloading`, `absent`, `stale`,
  `fresh`. An operator sorting by state wants the row that needs them at the
  top, and alphabetically that row would be buried between `absent` and
  `fresh`.
- **Size** sorts by bytes. As text, "9 GiB" orders ahead of "12 GiB", which
  puts the wrong row at the top of the question the column exists to answer.

`Last verified` sorts by timestamp, with never-verified rows gathered at the
oldest end. Rows that tie on the sorted column fall back to their identity, so
the order does not shuffle under the cursor while the page polls.

### The three actions, and when to use each

All three are per-row and gated (an unlocked session or a bearer). Each appends
`{atUtc, action, hostType, imageKey, arch, variant, outcome}` to
`<pool root>/download-agent-service/audit.jsonl` and is also available as an API
route for automation. Unlock attempts land in the same file as `unlock` lines
(outcome `ok`, `refused`, `throttled`, or `unavailable`, with the caller's
address), so the trail shows who opened the board as well as what they changed.

| Action | What it does | Reach for it when |
|---|---|---|
| **Force refresh** | Re-verifies against the origin **now**. Downloads only if something changed -- an unchanged origin just re-stamps freshness in seconds. On an `absent` row it triggers the first download. | A point release just shipped and you do not want to wait for the scan window; or you want to populate an entry the seed pass does not cover (a daily variant, an arch nothing reported). This is the cheap, safe, everyday button. |
| **Delete** | Cancels any in-flight download for the key, clears its staging, removes the pointer **first**, then every generation and sidecar. The row shows `deleting` until complete. | You suspect the stored bytes are wrong, or you need the space back now. The next host request or seed pass re-downloads from the origin -- so this is also the **"force a genuinely new download"** path, stronger than Force refresh, which will not re-fetch bytes the origin calls unchanged. Hosts' local copies are untouched, and an unchanged origin yields the same SHA-256, so their fingerprints match again after the re-download with nothing re-transferred. |
| **Prune previous** | Deletes only the previous generation. The current one stays servable throughout. | The share is filling up and you have accepted the current generation. Retention drops to one for that row until the next refresh creates a new previous. |

`POST /api/v1/refresh` re-verifies the whole pool in one call. That one is
**bearer-only** (the lab-auth token): an automation route, not a button.

## Unlocking the actions

**Usually there is nothing to unlock.** Open the Download pool from the *Yuruna
hosts* dashboard — the *Extension hosts* table, `Download-agent service` — and it
arrives already unlocked. That link goes through the aggregator's `/go/stash`
redirect, which hands the page a short-lived control proof in the URL fragment
(never sent to a server, never in an access log); the page exchanges it for a
session on arrival. Going back to the dashboard to copy a code off a tile, in
order to act on a page the dashboard just sent you to, is a step worth not
having.

The prompt below is what you see when there is no proof to spend: the page was
opened by typing its address, or bookmarked, or the proof expired while the tab
sat open.

The board's **Unlock actions** prompt takes the same 6-character **Lab token**
the Yuruna hosts dashboard shows on its own tile. Read the code off the tile,
type it into the board, and that browser holds an unlocked session for a week.
There is nothing to provision, nothing to look up in a vault, and nothing to
remember between rebuilds.

**The code rotates about once a minute.** The dashboard's tile trails a rotation
by up to about three quarters of a minute (a Prometheus scrape plus a panel
refresh), so the aggregator accepts the current code *and* its two predecessors.
A code you have just read stays redeemable for at least one full rotation; one
that leaked out of the lab stops working on its own within roughly three.

**The daemon does not validate the code itself.** It forwards what you typed to
the aggregator's `POST /api/v1/lab-token` exchange, which owns the codes and
their rotation, and believes only a definite answer. Two consequences:

- An **unreachable or unconfigured aggregator means the board cannot be
  unlocked** -- the answer is `503 {"reason":"lab-token-unavailable"}`, which is
  deliberately a different answer from "wrong code". The gate fails closed; it
  never lets the click through. Automation is unaffected:
  `Authorization: Bearer <lab-auth-token>` still works, and is the way to drive
  the agent when the aggregator is down.
- With **neither** an aggregator to ask nor a token configured, the mutating
  routes answer `503 {"ok":false,"reason":"auth-unconfigured"}` -- never an
  ungated write.

A rejected code answers `401`, and eight rejections from one address inside ten
minutes answer `429` without troubling the aggregator -- so a typo loop cannot
burn through the lab's shared attempt budget. Every attempt, accepted or not, is
recorded in the audit log.

**The code is public on the LAN by design.** The aggregator publishes it on its
open `/metrics` and paints it on a dashboard tile, so anyone who can reach the
dashboard can read it. That is the point: the gate stops a stray click on a
Delete button, it is not a secret. Its value is the rotation -- unlike a stored
passcode, a code that walks out of the lab expires by itself.

## Discovery, ports, and the Extension hosts row

The daemon listens on `0.0.0.0:80` in the guest, plain HTTP on the trusted LAN,
the same posture as the stash and pool-control services.

The host advertises the agent two independent ways, and either alone paints the
dashboard row:

- **The marker.** `runtime/download-agent-service.json` --
  `{active, vmName, hostType, startedAtUtc, downloadAgentServiceBaseUrl}` --
  written by the start script and folded into `host.registration.json`, which the
  aggregator already polls. `active` carries the **readiness verdict**, not "the
  script ran": a bring-up that never saw `:80` publishes `active:false` rather
  than deep-linking operators to a dead UI.
- **The beacon.** The daemon posts to the aggregator's `/announce` at boot, every
  15 minutes, and once more as a goodbye on shutdown.

### UTM Shared NAT and port 8082

vmnet cannot bridge a Wi-Fi uplink, so on a Wi-Fi Mac the VM is built on UTM
Shared NAT, where its address is inside a segment no peer can route to. The start
script therefore forwards **host `:8082` to guest `:80`** and writes the marker's
`downloadAgentServiceBaseUrl` as `http://<mac-lan-ip>:8082/`. On a bridged host
the marker carries the VM's own address and no forward is needed.

The port is fixed, not picked at run time: `:80` is the caching proxy's CA-cert
endpoint, `:2222` is the stash service, and `:8081` is the pool-control service.
Asking for a port already forwarded would attach to that forwarder and publish
the wrong service at the advertised URL.

The beacon cannot cover this case -- the aggregator derives the announcing
address from the request's source IP, which NAT rewrites to the Mac's address
*without* the port that reaches the guest. That is why the published endpoint
comes from the marker. A Shared-NAT Mac is a **reduced-value placement**: prefer
a bridged host for the agent.

### Pinning an endpoint by hand

`YURUNA_EXTENSION_HOST_DOWNLOAD_AGENT_SERVICE=<address>` pins the endpoint for a
host, ahead of any discovery -- the escape hatch for a lab whose agent lives
somewhere discovery cannot see.

## Configuration

Five keys under `downloadAgentService` in `test/test.config.yml`; the reference
table is in
[test-config.md](test-config.md#downloadagentservice--the-pool-wide-image-downloader).

```yaml
downloadAgentService:
  autoSeed: true              # pre-download stable families for reported host types
  enabled: true               # declared master switch
  freshnessSeconds: 86400     # 24 h
  prefetchLeadSeconds: 7200   # act 2 h before expiry
  scanIntervalSeconds: 900    # walk the pool every 15 min
```

The live values are read at **VM-create time** and baked onto the daemon's flag
line in the guest seed, so a change takes effect on the next stop/start of the
agent VM, not on the next cycle. The same defaults are compiled into the daemon,
so a bare daemon and one with no config block behave identically.

Joining lab hosts need **no** new config key -- discovery rides the aggregator,
with the environment pin above as the manual override.

## The agent's vault user

The agent VM's login is `download-agent-service-admin`, declared in
`test/extension/authentication/users.yml.template`. Bootstrap copies that
template only when the runtime `users.yml` is absent, so an
**already-bootstrapped host running strict mode** would otherwise fail
`Test-Config`'s user scan the first time it sees the smoke sequence. The
authentication area merges template-declared service-VM entries into an existing
runtime `users.yml`, so there is no manual migration step, and strict mode ships
default-off, so only opt-in hosts are affected.

The merge is additive only. A host carried over from an older build keeps a
`download-agent-service-passcode` entry in its runtime `users.yml`, and possibly
a value under that key in `vault.yml`, that nothing reads. Neither grants access
to anything -- no daemon compares against them and no seed carries them -- so
leaving them costs nothing. Delete both by hand if you would rather the vault
held only live credentials.

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| Start script times out waiting on `:80` | First boot is still installing the toolchain and building the daemon | Re-run to re-check, or raise `YURUNA_DOWNLOAD_AGENT_SERVICE_READY_TIMEOUT_SECONDS`. The printed `cloud-init status` says whether it is still running |
| Start script prints a `go build` or `apt` error | Package or source problem in the guest | The log tail names the line; fix and rebuild with Stop then Start |
| Daemon serves, UI says `poolAvailable:false` | The pool share did not mount in the guest | Check the NAS credential (`Set-Password` the `poolStorageNetworkUser`) and that the share is reachable, then rebuild. The daemon deliberately keeps serving; every `ensure` answers `pool-unavailable` and hosts fall back |
| "the daemon IS serving in-guest but this host cannot connect" | The address is not reachable from here | A stale DHCP lease (compare the guest console's own `eth0` line), a guest firewall dropping `:80`, or a bridged-mode address being probed on a Shared-NAT host. Waiting cannot help -- the daemon is already up |
| No Extension hosts row | The host status service is not serving `host.registration.json`, or the marker says `active:false` | Run `test/Start-StatusService.ps1`; check `runtime/download-agent-service.json`. The beacon alone still paints a row, minus the status baseUrl link |
| Row appears but the deep-link is dead from other machines | Shared-NAT Mac whose `:8082` forward did not install | Re-run the start script once the VM has an address; prefer a bridged host for the agent |
| Unlock says `503 lab-token-unavailable` | The daemon could not reach the aggregator to check the code, so it refused rather than guessing | Check the caching-proxy VM and the aggregator (`journalctl -u pool-aggregator-service`). Until it answers, drive the agent with the `Authorization: Bearer <lab-auth-token>` API routes |
| Unlock refuses a code you just read | The code rotated more than about three minutes ago, or the tile is stale | Re-read the tile and retry. If the tile itself reads "collector down", fix the aggregator first |
| UI actions return `503 auth-unconfigured` | The VM was built with no aggregator URL and no lab-auth token, so neither gate exists | Set a lab token with `test/Set-LabToken.ps1`, then rebuild the agent VM so the seed carries the aggregator URL |
| UI actions return "read-only" / show a `leaseHolder` | Another agent on the same NAS holds the lease | Expected. Use that agent's UI, or stop it -- the lease expires after three scan intervals |
| An entry is stale and refuses to refresh | The origin is unreachable directly | The pool keeps serving the previous verified generation. Nothing to do but restore origin reachability; the next scan retries |
| `guest.windows.11` never appears in the pool, or stays `absent` after a Force refresh | Best-effort family: no PowerShell, no Fido, or Fido could not mint a URL under Linux pwsh | Grep `/var/log/cloud-init-output.log` in the agent VM for `Windows 11 family` -- the line names the state. A VM built before this family existed simply needs a Stop/Start rebuild. Hosts are unaffected either way: Hyper-V and UTM run Fido themselves, KVM stays manual |
| Pool is eating the share | Retention is current + previous per identity | Prune previous on the fat rows, or Delete entries for host types this lab no longer runs |

The manual smoke test for the daemon build itself is
`test/sequences/workload.guest.ubuntu.server.26.download-agent-service.yml`. It
is standalone and deliberately **not** wired into any automated test-set: run it
by hand to verify the daemon compiles and starts on a vanilla guest.

## See also

- [pool-admin.md](pool-admin.md#download-agent-service) -- the service in the
  context of the rest of the pool tooling.
- [pool-storage.md](pool-storage.md) -- the pool share itself: paths,
  credentials, and the on-share layout.
- [caching.md](caching.md) -- the squid caching proxy the agent's byte downloads
  ride through, and its offline-mode behavior.
- [network.md](network.md) -- the Shared-NAT host-port allocation table.
- [test-config.md](test-config.md#downloadagentservice--the-pool-wide-image-downloader) --
  the config-key reference.
- [guest-image-setup.md](guest-image-setup.md) -- how hosts obtain guest images.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.06

Back to [Yuruna](../README.md)
