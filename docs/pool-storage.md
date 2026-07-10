# poolStorage (ypool-nas) — NAS-backed durable replication

Hosts in the Yuruna pool are **reimageable at any time**, exactly like the guests
they test. So host-local storage is treated as fast, local, and **ephemeral**, and
the durable tier is an **optional** Network-Attached Storage share — the *yuruna
pool storage path* (**ypool-nas**). When enabled, each host replicates its finished
test-cycle output to the share over **SMB3** (the one network-file protocol uniform
across Windows, macOS, and Linux). Nothing host-local is load-bearing: wipe a host
and its archived cycles still live on the NAS.

This document is the **architecture + operations** reference. For the
`test.config.yml` parameter reference (and how to set the SMB password in the
vault) see [test-config.md](test-config.md).

## The model

- **Local stays local.** The runner writes cycle folders to `test/status/log/`
  exactly as before. poolStorage never changes the live data path or its
  performance.
- **Stash storage is isolated.** The stash service has its own separate tier
  under `networkStorage.stash*` (its own NAS share + account); it no longer
  shares the pool's share or credential. This page covers only the **pool**
  side (`networkStorage.pool*` + `networkReplicate`); for the stash storage
  reference see [test-config.md](test-config.md) and the stash guide.
- **The NAS is a cold archive.** Replication is a one-way **copy** of immutable,
  finished cycle folders — not a live data directory on the share. There is no
  live reader of the share (the pool dashboard reads each host's own HTTP status
  server, not the NAS), so the share is a durable backup an operator or a future
  tool can browse, not a hot path.
- **Per-host namespacing.** Each host writes under `<poolLocalPath>/<hostId>/…`, keyed
  on the stable opaque `hostId` (`runtime/host.uuid`), so many hosts share one
  share without collision.
- **Opt-in + off by default.** `networkReplicate: false` (the default), or any of the
  paths left empty, is a complete no-op: no mount, no copy, no background work.

## How replication works — the PoolStorageReplicator

At the end of every cycle the outer runner loop
([Test.RunnerOuterLoop.psm1](../test/modules/Test.RunnerOuterLoop.psm1)) fires
[Invoke-PoolStorageDrain.ps1](../test/modules/Invoke-PoolStorageDrain.ps1) as a
**detached** child process and immediately continues. The drain is the
replicator; the orchestration lives in `Invoke-PoolStorageDrain`
([Test.PoolStorage.psm1](../test/modules/Test.PoolStorage.psm1)).

**Asynchronous — never delays the loop.** The drain runs in its own process
(Windows `Start-Process` with an empty stdin sink + hidden window; macOS/Linux
`nohup` in its own process group), so however long a copy takes — or however dead
the NAS is — the cycle loop is never blocked. The outer loop fires it and waits
for nothing.

**Fail-fast.** Before mounting, the drain probes `<server>:445` (a bounded TCP
connect, ~5 s). An unreachable NAS is detected in seconds, recorded in the local
ledger (`lastConnectOk=false`, `lastError`), and the drain exits — the backlog is
left for next time.

**Backlog-draining.** Each run copies **every** cycle not yet recorded as
replicated, **oldest first**, scanning both the top-level log directory and the
rotated `history.YYYY-MM-DD/` buckets. It is capped at **100 cycles per run**
(`-MaxPerRun`) so a first-time catch-up of a large history can't run for hours;
the next run continues where it left off. Steady state (one new cycle per drain)
never approaches the cap. A big initial catch-up can be hurried with a one-off
`Invoke-PoolStorageDrain … -MaxPerRun 500`.

**Atomic — a cycle is copied, or it is not.** Each cycle is copied into
`<poolLocalPath>/<hostId>/<cycle>/`, then a tiny `.yuruna-complete` **sentinel** file
is written **last**, and only then is the cycle recorded in the ledger. A copy
interrupted partway leaves no sentinel and no ledger entry, so the next run
deletes the incomplete folder and recopies it. A partial replica is therefore
never trusted.

The cycle's identity is its **stable base name** — a folder moves through
`<base>.incomplete` → `<base>` → `<base>.aborted.<UTC>` over its lifecycle
(in-progress → clean close → boot-recovered crash), and the ledger/destination
key on the suffix-stripped identity
([Get-CycleFolderIdentity](../test/modules/Test.Log.psm1)) so a crashed cycle is
replicated **once**, not again under each renamed form.

**Single-instance.** The drain takes a lock file
(`runtime/poolstorage.drain.lock`) via an atomic create-if-not-exists, recording
its PID **and** process StartTime. A second drain fired while one is still
draining a backlog bails instantly; a stale lock from a crashed drain is
reclaimed — and because the check matches both PID and StartTime, OS PID reuse
after a crash cannot make a stale lock masquerade as a running drain (which would
otherwise silently stall replication forever). Same hardening as the runner's
`runner.pid` + `runner.start`.

**Loud-fail vault pre-check.** Before mounting, the drain confirms a real SMB
credential exists for `poolNetworkUser`. If the user has an empty `vaultKey` **and**
no stored vault entry, mounting would make `Get-Password` auto-generate a random
password the NAS will reject — so instead the drain **warns and bails** (no mount,
no junk vault entry). The check is read-only
([Test-VaultEntry](../test/extension/authentication/default.psm1) — it never
writes the vault or auto-generates). The fix is the recommended vault setup in
[test-config.md](test-config.md#setting-the-smb-passwords-in-the-vault):
map a non-empty `vaultKey` and `Set-Password` it.

## On-share layout

```
<poolLocalPath>/
  hosts/
    info.<hostId>.yml                       # host registry (uuid + fingerprint)
  <hostId>/
    000123.2026-06-10.14-22-08.<hostId>/   # one finished cycle's folder
      …cycle artifacts…
      .yuruna-complete                      # sentinel: copy committed
    000124.2026-06-10.14-39-51.<hostId>/
      …
```

Each drain also refreshes `hosts/info.<hostId>.yml` with this host's uuid + a
hardware fingerprint, so a reimaged box can **reclaim** its prior `hostId` instead
of re-keying — see [Host identity & reimage reclaim](#host-identity--reimage-reclaim).
A host that declines the reclaim (or whose hardware no longer matches) re-keys with
a new `runtime/host.uuid`, so its later cycles land under a new `<hostId>/` root and
old archives are never overwritten. Orphaned roots from retired hosts accrete on the
share over time; pruning them is a manual housekeeping task (no automatic cleanup).

## The local ledger

`runtime/poolstorage.state.json` is the **source of truth** for what has been
replicated (the share is never consulted to decide). Written atomically
(temp + rename). Shape:

```json
{
  "replicated": { "000123.2026-06-10.14-22-08.<hostId>": "2026-06-10T14:40:11Z" },
  "lastAttemptUtc": "2026-06-10T14:40:09Z",
  "lastConnectOk": true,
  "lastError": "",
  "pendingCount": 0,
  "lastCopied": 1
}
```

Entries whose cycle folder no longer exists locally (rotated fully away) are
pruned so the ledger stays bounded. The ledger lives on the host's **ephemeral**
disk: a reimaged host loses it and re-drains its (small, post-rotation) local
backlog — wasted work, never lost or duplicated data, since copies are idempotent
onto immutable folders.

## Host identity & reimage reclaim

A host's pool identity is `runtime/host.uuid` (a `42`-prefixed 32-hex id). It
lives on the **ephemeral** disk, so a reimage would normally mint a fresh uuid
and fork the host's pool history. To avoid that:

- **Registry.** After every successful drain the host writes
  `hosts/info.<hostId>.yml` to the share, carrying its `hostUuid`, `hostname`,
  `hostType`/`platform`, and a hardware **fingerprint** (SMBIOS product UUID,
  baseboard serial, MAC addresses, CPU model/count, RAM size). Best-effort —
  never blocks the drain.
- **Reclaim.** `Enable-TestAutomation` (all three host platforms) ends with an
  interactive **"Configure poolStorage now?"** prompt. On a host with **no local
  uuid**, it mounts the share, fingerprints the hardware, scans `hosts/` and
  **scores** each record against this hardware. A confident single match is
  offered for reclaim (**operator confirms — never silent**); the chosen uuid is
  written to `runtime/host.uuid` so the next cycle adopts it. Ambiguous or
  multiple strong matches are listed and default to a new uuid. Decline the prompt
  and a **new uuid is minted** (with a warning that reconnecting the history later
  is harder).
- **Why the fingerprint is captured at enable time.** The strong, near-unique keys
  (`/sys/class/dmi/id/product_uuid`, `board_serial`) are **root-only on Linux**,
  which the unprivileged per-cycle drain cannot read. `Enable-TestAutomation` has
  sudo primed, so it captures the full fingerprint once and caches it to
  `runtime/host.hwid.json`; the drain publishes from that cache. A host that never
  ran the enable step still publishes a degraded (non-privileged) fingerprint —
  weaker, but MAC + CPU + RAM still corroborate.
- **Match weighting.** SMBIOS UUID and baseboard serial are strong (near-unique);
  a MAC overlap is medium (NICs can be swapped/cloned); CPU/RAM/platform only
  corroborate. Firmware placeholders (`Default string`, all-zero UUIDs, etc.) are
  treated as absent so two unrelated boards never match on junk. A strong key
  alone clears the suggest threshold; corroboration alone needs several agreeing
  weak fields. The operator-confirm step is the backstop against a wrong reclaim
  (e.g. cloned VM SMBIOS).
- **Non-interactive runs** (CI, an installer that redirects stdin) **skip** the
  prompt with a warning; re-run `Enable-TestAutomation` in a terminal to configure
  poolStorage and reclaim. The prompt is also skipped under `-WhatIf`.

## Per-OS mount + the Linux sudo precondition

The mount is idempotent (a correctly-mounted share is a no-op) and every native
mount/copy subprocess is wall-clock-bounded + killed on timeout, so a wedged NAS
can never hang the drain.

| OS | Mount | Credential handling |
|---|---|---|
| **Windows** | `New-SmbMapping` (in-process, `-Persistent`) | Password passed in-process; never on a command line. |
| **Linux** | `sudo -n mount -t cifs` | A `0600` credentials file written **before** the secret, deleted after the mount; password never on `ps`. |
| **macOS** | `mount_smbfs -N` | Credentials are URL-encoded into the mount URL (so `@ # % & + =` in a password don't corrupt it). The password is briefly on the `mount_smbfs` argv (visible to `ps`); keychain integration is a future hardening. |

**Linux precondition — passwordless sudo for the mount.** `sudo -n` never prompts;
without a `NOPASSWD` rule it fails fast (recorded in `lastError`, loop unaffected)
and the share is never archived. Grant the test account passwordless `mount` and
`umount` (e.g. a `/etc/sudoers.d/` drop-in) on Linux pool hosts that use
poolStorage. When `localPath` sits under a **root-owned** parent such as `/mnt`,
also grant `mkdir`: the mount point is created unprivileged when its parent is
user-writable, but a root-owned parent forces a `sudo -n mkdir -p` fallback
(`mount` does not create its own target, so a missing mount point otherwise fails
the mount). Example drop-in (adjust binary paths to your distro):

```
test ALL=(root) NOPASSWD: /usr/bin/mkdir, /usr/bin/mount, /usr/bin/umount
```

## What is — and isn't — replicated

- **Replicated:** each host's finished **cycle output** (logs, screenshots, NDJSON
  events, diagnostics) — the per-cycle folders.
- **Not replicated:** the **squid cache** (`/var/spool/squid`). It is fully
  rebuildable from upstream and is handled by squid's own pooling; copying it would
  be churn with no durability value.
- **Service data (caching-proxy):** the proxy's **Loki, Prometheus, and Grafana**
  data — archived to ypool-nas by the guest itself (see *Service replication* below).
  The **stash** service is deferred (no data dir yet). Zot's OCI cache and squid's
  cache are excluded (rebuildable).

## Service replication (caching-proxy)

Beyond the host-side cycle replication above, the caching-proxy VM archives its own
**observability data** to the same share so a reimaged proxy can be restored. It is
**guest-side**: the proxy's cloud-init seed carries the config + a credential, mounts
the share over cifs, and an hourly `ypool-nas-replicate.timer` rsyncs the data dirs to
`<poolNetworkPath>/<hostId>/services/caching-proxy/<svc>/`.

- **Replicated:** `loki` + `prometheus` via `rsync -a` (crash-consistent, additive);
  `grafana` via `sqlite3 .backup` of the live `grafana.db` (a plain rsync of an open
  WAL sqlite can restore corrupt) plus an rsync of the rest. **Excluded:** squid +
  zot (caches), promtail (tail cursor).
- **Account (`networkStorage.poolNetworkUser`).** The proxy mounts with the **single**
  `poolNetworkUser` — the same account the host uses for cycle replication. There is no
  separate guest credential. **Operator prerequisite:** scope `poolNetworkUser`
  **storage-only** on the NAS — write access to `poolNetworkPath` and nothing else — and
  `Set-Password` its vault entry. **The password is NOT baked into the seed:** the proxy
  fetches it at boot and hourly from the **Host Config Service** over mutual TLS
  (`yuruna-config-fetch pool` → `GET /v1/nas/pool`), writing `/etc/yuruna/ypool-nas.cifs.cred`
  (0600) and remounting on change — so **rotating the vault password reaches the running
  proxy without a rebuild** (the host serves the current value live via `Get-Password`).
  Because the account is storage-only, a leaked credential is confined to the pool share
  (no host login, no other service). Empty `poolNetworkUser` ⇒ service replication stays off.
- **Enablement** is baked at VM-create time: the seed gets `YPOOL_NAS_REPLICATE=true`
  whenever poolStorage is **configured** (`poolNetworkPath` + `poolNetworkUser` set) — the
  password no longer needs to exist at bake time. Until the vault entry is set, the Config
  Service answers `503` for `/v1/nas/pool`, the credential file stays empty, the mount
  fails (`nofail`), and replication no-ops — self-healing on the next hourly run once you
  `Set-Password`. Activating the dynamic fetch requires a baked **client certificate**
  (minted by the host Config CA at VM-create); without it the proxy can't fetch and the
  share stays unmounted.
- **Reachability:** the proxy must be on a **LAN-routable (bridged)** network to reach
  the NAS; on a NAT proxy (Default Switch / UTM Shared / Hyper-V-on-Wi-Fi) the mount
  fails (nofail) and replication silently no-ops — visible at the breadcrumb below.
- **Visibility:** the proxy publishes `http://<proxy>/ypool-nas-status`
  (`last_attempt=… mounted=0|1 rc_loki=… rc_prometheus=… rc_grafana=…`) and logs to
  `journalctl -u ypool-nas-replicate`.

### Restoring the caching-proxy after a reimage (manual)
Replication is one-way; restore is a documented manual step. On the fresh proxy, with
the share mounted at `/mnt/ypool-nas`:
```sh
systemctl stop loki prometheus grafana-server
for s in loki prometheus grafana; do
  rsync -a "/mnt/ypool-nas/<hostId>/services/caching-proxy/$s/" "/var/lib/$s/"
done
chown -R loki:loki /var/lib/loki; chown -R prometheus:prometheus /var/lib/prometheus; chown -R grafana:grafana /var/lib/grafana
systemctl start loki prometheus grafana-server
```
(Grafana also self-rebuilds its datasources + dashboards from the seed's provisioning,
so a restore mainly recovers retained metrics/logs + any runtime dashboard edits.)

## Syncing a new host's config from a reference host

`host/<type>/Sync-HostConfiguration.ps1 -ReferenceHost <name-or-ip>` copies a
working pool host's `test.config.yml` onto this host — reference host of ANY
host type — so a new or reimaged host doesn't have to be configured by hand.
The heavy lifting lives in `test/modules/Test.HostConfigSync.psm1`; the three
per-host-type scripts are thin shells (run the one matching this host's OS;
the Windows variant needs an elevated session for the hosts-file write).

What it does, in order:

1. **Copy + convert.** Fetches the reference config over its status server
   (`GET /control/test-config`, JSON) and converts the host-type-specific
   values: share paths get the local slash style (`\\server\share` vs
   `//server/share`), and an EMPTY local mount path gets the local
   convention — `y:`/`z:` (Windows), `/mnt/<server>` (Ubuntu),
   `~/Shares/<server>` (macOS). An already-populated local mount path is
   kept (it reflects a working mount). The local `secrets` node survives;
   the reference's is never adopted. Non-portable reference values
   (`file://` projectUrl, absolute `pool.localClonePath`) are kept local
   with a warning. The write is atomic and the previous file lands in
   `test.config.yml.backup`.
2. **Hosts-file alias.** A networkStorage server name (e.g. `ypool-nas`)
   that does not resolve locally is looked up on the reference host
   (`GET /control/host-aliases` — the reference's own resolution of the
   names its config uses) and written via `automation/Set-HostAlias.ps1`
   (sudo on Linux/macOS). Prompt as fallback when the reference can't
   supply it.
3. **Vault credential.** A networkStorage user with no local vault entry is
   fetched from the reference's `GET /control/vault-credential`. That route
   is gated by the operator-set shared `pool-auth-token` (the same one that
   gates the aggregator's push ingest, and 503 until it is configured):
   the request proves token knowledge via an HMAC (the token never crosses
   the wire) and the response password is AES-GCM encrypted with a key
   derived from the token, so nothing crosses the plain-HTTP LAN in
   cleartext. Prompt as fallback; the value is stored with `Set-Password`.
4. **Validate.** Runs `pwsh test/Test-Config.ps1` (skippable with
   `-SkipValidation`) so a wrong password / share typo / missing sudo rule
   surfaces immediately — the same gate described below.

`-NonInteractive` never prompts (skips with warnings instead);
`-WhatIf` previews. A repeat run with nothing to change writes nothing.

## Operating & troubleshooting

`pwsh test/Test-Config.ps1` is the pre-flight check — it validates the
networkStorage pool block (all three pool paths set, a usable vault credential so
the mount won't auto-generate a junk password, and SMB `:445` reachability) before
a cycle runs. When the credential is configured **and** the server is reachable, it
goes one step further and **actively mounts `poolLocalPath` and creates the per-host
folder `<poolLocalPath>/<hostId>`** — the same write the replicator does — so a wrong
SMB password, a share-name typo, a missing Linux passwordless-sudo rule, or a
read-only share is caught here instead of failing silently in the detached drain.
With `networkReplicate: true` a failure of this active step is a **FAIL that stops the
cycle** (the gate refuses to start until it is fixed, or you bypass it with
`-NoConfigGate`); with `networkReplicate: false` it is advisory only. A merely-offline
NAS (no answer on `:445`) stays a WARN — the loop retries it each cycle, so it
never blocks a healthy run.

This is the same gate `Invoke-TestRunner`, `Test-Sequence`, and `Test-Project`
all run at startup, so all three refuse to begin when `networkReplicate` is on and the
share is not actually writable.

Everything the drain writes lives under the runtime directory:

| File | Purpose |
|---|---|
| `runtime/poolstorage.state.json` | the ledger (replicated set + last-run status) |
| `runtime/poolstorage.drain.out` / `.err` | the last drain's console output (Windows writes both; macOS/Linux writes only `.err`, stdout is discarded) |
| `runtime/poolstorage.drain.lock` | single-instance lock (`{pid,startUtc}`); absent between runs |

A drain's summary line reads e.g. `connectOk=True copied=20 pending=1097 error=''`.

**Run a drain by hand** (without waiting for a cycle), from a runner-active shell
where `$env:YURUNA_*` are set:

```powershell
pwsh -NoProfile -File ./test/modules/Invoke-PoolStorageDrain.ps1 -HostId '<hostId>'
```

or call the function directly after importing the module set
(`Test.PoolStorage`, `Test.StateFile`, `Test.Config`, and the authentication
extension):

```powershell
Import-Module ./test/modules/Test.PoolStorage.psm1 -Force
Invoke-PoolStorageDrain -HostId '<hostId>' -LogDir $env:YURUNA_LOG_DIR -RuntimeDir $env:YURUNA_RUNTIME_DIR -MaxPerRun 500
```

Common findings:

- **`connectOk=False, error='server unreachable…'`** — the TCP-445 probe failed:
  NAS off, wrong `poolNetworkPath`, or a firewall. The loop is unaffected; the backlog
  resumes when the NAS returns.
- **`error='vault credential not configured'`** — the loud-fail pre-check: set the
  `poolNetworkUser` password per [test-config.md](test-config.md#setting-the-smb-passwords-in-the-vault).
- **`error='mount failed'` on Linux** — usually missing passwordless sudo for
  `mount` (see the precondition above).
- **The cycle won't start, gate FAILs on `poolLocalPath / per-host folder
  pre-flight FAILED`** — `networkReplicate: true` and the active pre-flight could not
  mount the share or could not create `<poolLocalPath>/<hostId>` on it. The FAIL line
  names the stage: a *mount* failure points at the password / share name / Linux
  sudo; a *folder* failure points at a read-only share or missing write
  permission for `poolNetworkUser` under `poolLocalPath`. Fix the share, or set
  `networkReplicate: false` (downgrades it to advisory), or bypass once with
  `-NoConfigGate` for an unrelated in-progress edit.
- **The whole config won't load** — a Windows drive-letter `poolLocalPath` must be
  **quoted** in YAML (`poolLocalPath: 'w:'`, not `w:`); unquoted it breaks the entire
  `test.config.yml` parse. See the YAML-quoting note in [test-config.md](test-config.md).

## Security notes

The SMB password lives only in the per-host, git-ignored vault
(`test/status/extension/authentication/vault.yml`), never in `test.config.yml`. It
is passed in-process (Windows) or through a transient `0600` credentials file
(Linux); on macOS it is briefly on the `mount_smbfs` argv (the one residual
exposure, documented above). The replicator changes no security posture — the
vault pre-check is purely read-only and the password alphabet/length/storage are
untouched.

---

## Pool harness — membership, intent, and test-set execution

The **pool control plane** — creating pools, adding hosts, assigning already-developed
test sequences, and operating the fleet — is documented for operators in
**[pool-admin.md](pool-admin.md)**, a step-by-step guide. Read that to *use* pools; this
page covers only the NAS replication of pool observability data described above.

In brief: the operator authors slow-changing **intent** (pool membership +
`desiredState` + assigned test-sets) into a small **git repo on the caching-proxy**
(`/var/lib/yuruna/pool-intent.git`, served read-only over HTTP). Each runner pulls it at
cycle start, finds its pool by locating its `hostId` in `members[]`, and — when the pool
has assigned test-sets — drives the cycle from them instead of its local
`test.runner.yml` (decentralized: each host runs only the guests it can, skipping the
rest, trusting another member to cover them). Everything is best-effort and default-off:
an unreachable store, an unpooled host, or a pool with no test-sets all fall back to
single-host behavior. The intent repo holds only **non-secret** files; no credential is
ever routed through it.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.10

Back to [Yuruna](../README.md)
