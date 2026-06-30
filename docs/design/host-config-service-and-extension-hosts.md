# Host Config Service & Extension hosts — Design (GOAL 2 + GOAL 3)

> Status: **implemented.** In the tree: the per-host Config CA
> ([Test.HostConfigCA.psm1](../../test/modules/Test.HostConfigCA.psm1)), the mTLS
> Host Config Service ([Start-HostConfigService.ps1](../../test/Start-HostConfigService.ps1)
> / [Stop-HostConfigService.ps1](../../test/Stop-HostConfigService.ps1), launched
> from [Start-CachingProxy.ps1](../../test/Start-CachingProxy.ps1) Step 2.6), per-VM
> client-cert baking in all three caching-proxy `New-VM.ps1`, the guest
> fetch/remount timer in
> [caching-proxy.base.user-data](../../host/vmconfig/caching-proxy.base.user-data),
> the **registration-driven Extension hosts** panel (the stash-server host
> advertises `activeExtensions`; the aggregator emits the row from registration —
> **no ystash-nas mount, no Config Service dependency** for the dashboard, §5.1),
> and the **ypool-nas migration** (the cache VM fetches its ypool-nas credential
> over mTLS via `yuruna-config-fetch pool`; the plaintext pool password no longer
> ships in the seed). The Config Service now exists solely for **ypool-nas
> replication**. **Remaining follow-up (§7):** the stash-VM's own dynamic
> ystash-nas mount (the stash daemon VM still mounts with a baked credential).
> Companion work: the dashboard rename ("Yuruna Pool" → "Yuruna hosts",
> GOAL 1) is already landed in
> [grafana-pool-dashboard.json](../../test/extension/pool-aggregator/grafana-pool-dashboard.json)
> and the inline copy in
> [caching-proxy.base.user-data](../../host/vmconfig/caching-proxy.base.user-data).

## 1. Goals

1. **(GOAL 1 — done)** Rename the Grafana dashboard title to *Yuruna hosts*
   (title text only; `uid`/`tags` unchanged).
2. **(GOAL 2)** Add an **Extension hosts** table to the dashboard, ABOVE the
   existing **Pool hosts** table, with columns **Host ID** and **Extension**
   (the host's function, e.g. *Stash service*). Source the list of stash
   servers by having the aggregator VM scan **ystash-nas**.
3. **(GOAL 3)** Let the host **serve NAS connection info + credentials to only
   the VMs running under that same host**, resolved **at request time** so a
   rotated password reaches running VMs without a rebuild. First consumer:
   ystash-nas (needed by GOAL 2's crawl). Then migrate ypool-nas off the
   bake-once path.

## 2. Decisions taken (operator-confirmed)

| Axis | Decision |
|---|---|
| GOAL 3 access control | **mTLS** — guest presents a client cert; host validates it |
| GOAL 3 transport | **TLS** on the serving endpoint (not cleartext HTTP) |
| GOAL 2 discovery | **Registration-driven** — the stash host advertises `activeExtensions`; the aggregator emits the panel from registration (no ystash-nas mount). Supersedes the earlier "aggregator scans ystash-nas" decision (§5.1). |
| CA topology | **Dedicated per-host Config CA** (isolated from the in-VM aggregator pool CA) |
| Crypto profile | **EC P-256**, SHA-256; CA validity 10 y, leaf validity 2 y; Config port **8443** |
| Poll cadence | **Hourly** (aligned with `ypool-nas-replicate.timer`) |
| ypool-nas scope | **ystash-nas first; migrate ypool-nas as a follow-up** |
| Sequencing | Rename landed; this document is the 2+3 design — all sign-offs resolved (§8) |

These two GOAL-3 answers combine into a single mechanism: **mutual TLS**. The
serving endpoint gains a TLS server leaf (transport), and it *requires* a client
certificate (access control). One CA underpins both.

## 3. Why a new host-side service rather than the existing status server

The credentials live in the **host vault**
([test/status/extension/authentication/vault.yml](../../test/status/extension/authentication/vault.yml)),
resolvable only by host-side PowerShell via `Get-Password`
([Test.Extension / authentication default.psm1](../../test/extension/authentication/default.psm1)).
So the serving process must run **on the host**, in PowerShell.

The existing host status server
([test/Start-StatusService.ps1](../../test/Start-StatusService.ps1)) is a
`System.Net.HttpListener` bound to `http://*:<port>`, deliberately
**unauthenticated** (serves the dashboard, `/yuruna-repo/`, runtime files) with a
deny-list that already **blocks** the plaintext-cred files. We do **not** relax
that deny-list. Two further reasons not to extend it:

- **`HttpListener` HTTPS is not portable.** `HttpListener` is not a self-contained
  server: on Windows it is a thin wrapper over the **http.sys** kernel driver, so
  TLS is terminated in http.sys and the server cert is bound to the *port*
  out-of-band via `netsh http add sslcert` (you never pass a cert in code; the
  binding must be re-done on rotation). On **Linux/macOS** (KVM/UTM hosts) there
  is no http.sys — `HttpListener` is a fully *managed* reimplementation that has
  **no API to supply a server certificate**, so an `https://` prefix does not
  negotiate TLS, and client-cert retrieval (`GetClientCertificate`) is likewise
  unsupported. An mTLS endpoint on `HttpListener` is therefore a Windows-only
  construct, and a Yuruna host can be any of the three platforms. Note this is
  specific to `HttpListener`: .NET TLS *is* portable via **`SslStream`** (which is
  what Kestrel uses under the hood) — we use that primitive directly (§4), passing
  the cert in code with `clientCertificateRequired: true`, identically on all
  three host OSes, with rotation as a pure file operation.
- **Surface separation.** Keep the open, unauthenticated status server open; put
  secrets behind a separate, mutually-authenticated channel.

**Therefore:** a new dedicated host-side service — the **Host Config Service** —
implemented with `TcpListener` + `SslStream` (fully cross-platform in .NET;
supports `clientCertificateRequired` + a server-side validation callback). It
speaks just enough HTTP/1.1 over the TLS stream to answer one JSON `GET`.

## 4. GOAL 3 — Host Config Service

### 4.1 Trust model: a per-host Config CA = cryptographic proof-of-residency

A **per-host Config CA** is minted once on the host and persisted in the host
runtime tree (gitignored, alongside the vault and `runtime/host.uuid`), e.g.
`test/status/runtime/host-config-ca/`. From it the host derives:

- a **server leaf** for the Host Config Service (presented on the TLS handshake);
- a **per-VM client leaf + key**, issued at VM-create time and baked into that
  VM's cloud-init seed.

Because **only VMs this host created carry a client cert signed by this host's
CA**, mTLS scopes access to *exactly the VMs running under that host* — the cert
is the residency proof, and it survives DHCP IP changes (no IP ACLs). This is the
literal realization of "serve only to the VMs running under that same host".

> **Relationship to the existing pool CA — decided.** Today the aggregator mints
> its own CA + `:9400` leaf inside the caching-proxy VM
> ([pool-aggregator README](../../test/extension/pool-aggregator/README.md),
> `yuruna-pool-ca.crt`). v1 uses a **dedicated, purpose-scoped per-host Config CA**
> kept **separate** from that in-VM aggregator CA (lowest risk; no change to how
> the aggregator obtains its `:9400` leaf). Converging the two onto a single
> host-rooted root is explicitly deferred as possible future work, not part of
> this change.

### 4.2 Endpoint contract

`GET https://<host>:<configPort>/v1/nas/<name>`  where `<name>` ∈ {`stash`, `pool`}

- **mTLS required.** Handshake fails closed if the client presents no cert or a
  cert not chaining to this host's Config CA.
- Host resolves **at request time**:
  - connection info from `test.config.yml` `networkStorage.*`
    ([test.config.yml.template](../../test/test.config.yml.template)),
  - password **live** via `Get-Password -Username <networkUser>` (vault).
- Response JSON (no-store):
  ```json
  { "name":"stash", "networkPath":"//nas/ystash", "username":"...",
    "password":"...", "localPath":"/mnt/ystash-nas", "version":"<sha256-of-fields>" }
  ```
  `version` lets the guest detect a change (rotation) cheaply.
- Mirrors the existing host-side runtime resolution that
  [Invoke-PoolStorageDrain](../../test/modules/Invoke-PoolStorageDrain.ps1) and
  [Test.PoolStorage.psm1](../../test/modules/Test.PoolStorage.psm1) already do —
  this brings the **guest** path to parity with the host path (which already
  picks up rotations).

### 4.3 Guest side: fetch at boot + on a timer, remount on change

A small systemd unit + timer in the guest (new bits in
[caching-proxy.base.user-data](../../host/vmconfig/caching-proxy.base.user-data)
and [stash-service.base.user-data](../../host/vmconfig/stash-service.base.user-data)):

1. On boot and every interval (**hourly**, confirmed; aligned with the existing
   `ypool-nas-replicate.timer`), `curl --cert/--key/--cacert` the Config Service.
2. If `version` changed, rewrite the `0600 root:root` cred file
   (`/etc/yuruna/ystash-nas.cifs.cred`, later `/etc/yuruna/ypool-nas.cifs.cred`)
   and **remount** the share.
3. Best-effort: a host/Config-Service outage leaves the last-known cred file in
   place (no worse than today).

The host coordinates (`/etc/yuruna/host.env`, written at VM-create time) already
give the guest the host IP/port; the Config Service port is added there too.

### 4.4 Rotation flow (the problem this fixes)

Today: `New-VM.ps1` bakes `YPOOL_NAS_PASSWORD_PLACEHOLDER` once
([New-VM.ps1:285-289](../../host/windows.hyper-v/guest.caching-proxy/New-VM.ps1#L285-L289))
→ a later vault rotation never reaches the running VM → replication breaks.

After: rotate the vault password (`Set-Password`). On the guest's next poll the
Config Service returns the new password (resolved live), the guest rewrites the
cred file and remounts. **No rebuild, no manual SSH.**

### 4.5 Crypto parameters — confirmed

Operator-approved (these are security posture; sign-off recorded here):

| Parameter | Value |
|---|---|
| CA + leaf key | **EC P-256** |
| Signature | **SHA-256** |
| CA validity | **10 y** (host-persisted) |
| Leaf validity | **2 y** (server + per-VM client; re-issued on VM rebuild anyway) |
| EKU | server leaf = serverAuth; client leaf = clientAuth |
| Config port | **TCP 8443** (distinct from status `:8080`) |

The NAS password keeps its **existing vault storage and alphabet** — unchanged.
The only new secret material is the cert/key pair (a coordinate, not a NAS
secret), baked like the SSH key already is.

### 4.6 Threat model summary

- **Who can read creds:** only a process holding a client key signed by this
  host's Config CA → only this host's VMs. Cleartext-on-wire eliminated (TLS).
- **Blast radius of a leaked per-VM key:** that one VM could fetch the NAS creds
  it would mount anyway; it cannot impersonate another VM (per-VM certs) and the
  creds are storage-scoped on the NAS.
- **Status server unchanged:** still open + deny-listed; secrets never traverse it.

### 4.7 Lifecycle & reliability (caching-proxy companion, not runner-coupled)

The Config Service is a **companion of the caching proxy**: its only job is to
serve NAS creds to the caching-proxy / stash VMs a host created, so its lifecycle
belongs to the **caching-proxy bring-up on that host** —
`Start-CachingProxy.ps1` Step 2.6 calls `Start-YurunaConfigServiceIfEnabled`
([Test.Prelude.psm1](../../test/modules/Test.Prelude.psm1)). It is deliberately
**NOT** wired into the test runner. The status server is genuinely dual-owned
(every test-runner host needs it *and* the cache bring-up serves the repo through
it); the Config Service is not — coupling it to the runner would (a) start it on
plain test-runner hosts that never host a caching proxy (needless CA + `:8443`),
and (b) fail to start it on a dedicated caching-proxy/services host that doesn't
run the runner — the actual failure mode observed in the field.

The launcher is **idempotent + skip-if-healthy**: a no-op when a live instance is
already accepting on the port (so re-running `Start-CachingProxy` doesn't churn
it), `-Restart` forces a relaunch (new code), and it writes a
`config-server.health` breadcrumb so a down service is visible rather than silent.

**Durability across host reboot (the open item).** Because ownership is the
caching-proxy bring-up (a script, not an OS service), the Config Service does not
survive a host reboot on its own. The correct fix is a **boot-persistent
supervisor on the caching-proxy host** (Windows Scheduled Task at startup / Linux
systemd / macOS launchd), registered by `Start-CachingProxy`, mirroring however
the host already auto-starts the caching proxy VM + the runner at boot — **runner-
independent**. Until that lands, re-running `Start-CachingProxy.ps1` after a reboot
re-establishes it (Step 2.6 is idempotent). **Guest side:** the fetch runs at boot
(`OnBootSec=30s`) + hourly with a short **retry burst** (the host service may not
be up when the VM boots), publishes a `/var/www/html/config-fetch-<name>-status`
breadcrumb, and distinguishes "host unreachable (stale baked IP)" from "Config
Service down" for diagnosis.

## 5. GOAL 2 — Extension hosts panel + discovery

### 5.1 Discovery: registration-driven (no ystash-nas mount)

> **Superseded design note.** An earlier revision had the aggregator *mount and
> scan ystash-nas* for per-`hostId` folders. That made the dashboard listing
> depend on the aggregator's host running a Config Service and holding ystash-nas
> creds — a fragile cross-host dependency that broke whenever the aggregator ran on
> a different host than the stash server (the common pool topology). It is replaced
> by the registration-driven path below; the aggregator no longer mounts ystash-nas.

- The host that runs a stash-server VM **advertises it**: `Start-StashServer.ps1`
  writes `runtime/stash-server.json`; `Write-HostRegistrationRecord`
  ([Test.Capability.psm1](../../test/modules/Test.Capability.psm1)) folds that into
  `host.registration.json` as **`activeExtensions: ["stash-service"]`** (the
  RUNTIME list of services the host is actively running — distinct from
  `capabilities.extensions`, which is what every host *could* run).
  `Stop-StashServer.ps1` removes the marker, so the host drops from the panel.
- The **aggregator already polls every pool host's** `host.registration.json` (for
  poolId/gating); it now also reads `activeExtensions` and emits one
  `yuruna_pool_host_extension{hostId, area}` per active area. **No mount, no Config
  Service, no NAS creds** on the aggregator's host — a host self-reports the
  service it runs.
- **Key namespace note:** the advertised hostId is the host's `runtime/host.uuid`
  — the **same `hostId`** the pool view uses (and the same one ystash-nas folders
  are named by). So a host that both runs cycles and hosts a stash server appears
  under one Host ID in both panels.

### 5.2 New telemetry

The aggregator emits a new low-cardinality series:

```
yuruna_pool_host_extension{pool, hostId, area="stash-service"}  1
yuruna_pool_host_extension_last_seen_seconds{pool, hostId, area}  <epoch>
```

`area` is the stable identifier; the friendly function label ("Stash service") is
applied in the **dashboard** via Grafana value-mappings (`stash-service` →
`Stash service`), keeping function naming in the lintable dashboard JSON. The
series is general, so future extension hosts (other `area`s, discovered by other
means) slot in without a schema change.

### 5.3 Dashboard panel

- New **full-width table** (`w=24, x=0`) titled **Extension hosts**, inserted
  **above Pool hosts** (panel id 6, currently `y=13`): new table at `y=13`,
  shift Pool hosts to `y=22+` and the collapsed drill-down row (`y=23`) + its
  nested children down by the inserted height. Stat row (`y=0`) and timeline
  (`y=4`) stay put.
- **Host ID** column mirrors Pool hosts verbatim: GUID regex
  `^(.{8})(.{4})(.{4})(.{4})(.{12})$` → `$1-$2-$3-$4-$5`, `custom.width 330`,
  right-align, and the `${__data.fields.baseUrl}` deep-link when the host is also
  a pool member (else plain text).
- **Extension** column = mapped function name from `area`.
- Applied **canonical-file-first**
  ([grafana-pool-dashboard.json](../../test/extension/pool-aggregator/grafana-pool-dashboard.json)),
  then mirrored **byte-identically** into the inline copy in
  [caching-proxy.base.user-data](../../host/vmconfig/caching-proxy.base.user-data)
  (except the `AGGREGATOR_BASE_PLACEHOLDER` sed substitution), per the documented
  two-copy sync rule.

## 6. Implementation surface (file-by-file)

**GOAL 3 — Host Config Service**
- `test/Start-HostConfigService.ps1` *(new)* — `TcpListener`+`SslStream` mTLS
  server; resolves `networkStorage.*` + `Get-Password` per request.
- `test/modules/Test.HostConfigCA.psm1` *(new)* — mint/persist the per-host
  Config CA; issue server leaf + per-VM client leaf.
- `host/*/guest.caching-proxy/New-VM.ps1` ×3 and the stash-service New-VM path —
  issue a per-VM client cert, bake cert/key + Config CA + port into the seed
  (next to `host.env`). Start the Config Service before VM create (like
  `Start-CachingProxy.ps1` starts the status server).
- `host/vmconfig/caching-proxy.base.user-data`,
  `host/vmconfig/stash-service.base.user-data` — write the baked cert/key/CA;
  add the fetch+remount timer; replace the baked-once NAS cred with a
  Config-Service fetch.

**GOAL 2 — Extension hosts (registration-driven, §5.1)**
- `test/modules/Test.Capability.psm1` — `Write-HostRegistrationRecord` emits
  `activeExtensions` from the `runtime/stash-server.json` marker.
- `test/Start-StashServer.ps1` / `Stop-StashServer.ps1` — write / remove the marker.
- `test/extension/pool-aggregator/main.go` — parse `activeExtensions` from each
  host's registration and emit `yuruna_pool_host_extension*` from it (no mount, no
  scan, no `-stash-root`).
- `grafana-pool-dashboard.json` + inline copy — the Extension hosts table.

## 7. Rollout, compatibility, testing

- **Backward compatible / soft-fail:** if the Config Service is unreachable or
  no client cert is baked (old VM), the guest keeps its last cred file — today's
  behavior. The dashboard panel shows "No data" until the aggregator scan runs,
  exactly like the rest of the dashboard on first boot.
- **Sequencing:** (1) Config CA + service for ypool-nas; (2) Extension hosts via
  registration (host advertises `activeExtensions`; aggregator emits the panel) —
  no ystash-nas mount; (3) migrate ypool-nas replication off bake-once to the
  Config Service.
- **Tests:** mTLS accept/reject (valid cert, no cert, foreign-CA cert);
  request-time rotation (rotate vault → guest remounts); hostId-folder scan unit
  test (reuse `looksLikeHostID` fixtures); dashboard JSON ↔ inline byte-sync
  check; PSScriptAnalyzer clean on all new `.ps1`/`.psm1`.

## 8. Resolved decisions

All sign-offs are settled (operator-confirmed):

1. **CA topology (§4.1):** **dedicated per-host Config CA**, kept separate from the
   in-VM aggregator pool CA. Convergence deferred.
2. **Crypto parameters (§4.5):** **EC P-256 / SHA-256**, CA 10 y, leaf 2 y, Config
   port **8443**.
3. **Poll interval (§4.3):** **hourly**, aligned with `ypool-nas-replicate.timer`.
4. **ypool-nas migration scope:** **ystash-nas first** — and ypool-nas is now also
   migrated: `yuruna-config-fetch pool` owns the read-write `/mnt/ypool-nas` mount +
   credential (fetched over mTLS, refreshed on rotation), `ypool-nas-replicate.sh`
   only rsyncs into it, and the pool password is no longer baked. The stash-daemon
   VM's own ystash-nas mount remains on a baked credential (separate follow-up).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.27

Back to [Yuruna](../../README.md)
