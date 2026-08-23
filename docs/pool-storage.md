# poolStorage (ypool-nas) — NAS-backed durable replication

Hosts in the Yuruna pool are **reimageable at any time**, exactly like the guests
they test. So host-local storage is treated as fast and **ephemeral**, and
the durable tier is an **optional** Network-Attached Storage share -- the *yuruna
pool storage path* (**ypool-nas**). When configured, each host archives its finished
test-cycle output to the share over **SMB3** (the one network-file protocol uniform
across Windows, macOS, and Linux). Nothing host-local is load-bearing: wipe a host
and its archived cycles still live on the NAS.

Archiving has two **modes**, selected by `networkStorage.moveLogsToPoolStorage`:
**copy** (the default -- the local folder is kept) and **move** (the local folder is
deleted once the copy is verified, so the share holds the only copy). Everything
below describes copy mode unless it says otherwise; [Move mode](#move-mode-the-share-holds-the-only-copy)
covers what changes.

This document is the **architecture + operations** reference. For
`test.config.yml` parameters (and how to set the SMB password in the
vault) see [test-config.md](test-config.md).

**No NAS?** `pwsh test/lab/New-LocalLabStorage.ps1` turns the machine you are
standing at into its own pool and stash storage server -- folders, storage
accounts, shares, vault entries, mounts, and config, in one idempotent command on
Windows, macOS, or Ubuntu. The shares are local but are consumed **as if they
were remote** (a loopback host alias per tier, mounted over SMB by the same
`Connect-YurunaPoolStorage` used below), so everything on this page applies
unchanged and moving to real hardware later only changes what the alias
resolves to. Later labs on that machine need only
`pwsh test/lab/New-Lab.ps1 -Name <lab-name>`, which reuses the storage root and the
share credentials already there instead of minting a second, conflicting set.
It is for **local** storage only: a NAS owns its own accounts and permissions,
which have to be created on the device itself. See
[operator.md](operator.md#b7-local-shares-for-pool-and-stash-storage).

## The model

- **Local stays local while a cycle runs.** The runner writes cycle folders to
  `test/status/log/` unchanged. poolStorage never changes the live data path or its
  performance; in move mode a finished folder is removed only after its copy is
  verified on the share.
- **Stash storage is isolated.** The stash service has its own tier under
  `networkStorage.stash*` -- its own NAS share and account, not the pool's share
  or credential. This page covers only the **pool**
  side (`networkStorage.pool*`); for the stash storage
  reference see [test-config.md](test-config.md) and the stash guide.
- **Replication is a cold archive.** It is a one-way **copy** of
  immutable, finished cycle folders -- not a live data directory -- and the pool
  dashboard reads each host's own HTTP status service, not the NAS. So the
  replicated `<hostId>/` roots stay a durable, browsable backup, not a hot
  path. **The share as a whole is not cold**, though: the
  pool services keep their own live subtrees beside the archive -- the
  pool-control service its audit log and status, and the download-agent service
  the guest-image **Download pool** it continuously writes, re-verifies and
  serves to hosts over HTTP (see [On-share layout](#on-share-layout)). Sizing and
  retention are therefore a live concern, not just an archival one.
- **Per-host namespacing.** Each host writes under
  `<poolStorageLocalPath>/hosts/<hostId>/...`, keyed on the stable opaque `hostId`
  (`runtime/host.uuid`), so many hosts use one share without collision.
- **The three paths are the opt-in.** Any of `poolStorageNetworkPath`,
  `poolStorageNetworkUser`, `poolStorageLocalPath` left empty is a complete no-op:
  no mount, no copy, no background work. Populating all three turns archiving on;
  `moveLogsToPoolStorage` then selects copy vs move.

## How replication works — the PoolStorageReplicator

At the end of every cycle the outer runner loop
([Test.RunnerOuterLoop.psm1](../test/modules/Test.RunnerOuterLoop.psm1)) fires
[Invoke-PoolStorageDrain.ps1](../test/modules/Invoke-PoolStorageDrain.ps1) as a
**detached** child process and immediately continues. The drain is the
replicator; the orchestration lives in `Invoke-PoolStorageDrain`
([Test.PoolStorage.psm1](../test/modules/Test.PoolStorage.psm1)).

**Asynchronous -- never delays the loop.** The drain runs in its own process
(Windows `Start-Process` with an empty stdin sink + hidden window; macOS/Linux
`nohup` in its own process group), so however long a copy takes -- or however dead
the NAS is -- the cycle loop is never blocked.

**Fail-fast.** Before mounting, the drain probes `<server>:445` (a bounded TCP
connect, ~5 s). An unreachable NAS is detected in seconds, recorded in the local
ledger (`lastConnectOk=false`, `lastError`), and the drain exits -- the backlog is
left for next time.

**Backlog-draining.** Each run copies **every** cycle not yet recorded as
replicated, **oldest first**, scanning both the top-level log directory and the
rotated `history.YYYY-MM-DD/` buckets. It is capped at **100 cycles per run**
(`-MaxPerRun`) so a first-time catch-up of a large history can't run for hours;
the next run continues where it left off. Steady state (one new cycle per drain)
never approaches the cap. A big initial catch-up can be hurried with a one-off
`Invoke-PoolStorageDrain ... -MaxPerRun 500`.

**Atomic -- a cycle is copied, or it is not.** Each cycle is copied into
`<poolStorageLocalPath>/hosts/<hostId>/test-cycles/<cycle>/`, then a tiny
`.yuruna-complete` **sentinel** file
is written **last**, and only then is the cycle recorded in the ledger. A copy
interrupted partway leaves no sentinel and no ledger entry, so the next run
deletes the incomplete folder and recopies it.

The cycle's identity is its **stable base name** -- a folder moves through
`<base>.incomplete` -> `<base>` -> `<base>.aborted.<UTC>` over its lifecycle
(in-progress -> clean close -> boot-recovered crash), and the ledger/destination
key on the suffix-stripped identity
([Get-CycleFolderIdentity](../test/modules/Test.Log.psm1)) so a crashed cycle is
replicated **once**, not again under each renamed form.

**Single-instance.** The drain takes a lock file
(`runtime/poolstorage.drain.lock`) via an atomic create-if-not-exists, recording
its PID **and** process StartTime. A second drain fired while one is still
draining a backlog bails instantly; a stale lock from a crashed drain is
reclaimed -- and because the check matches both PID and StartTime, OS PID reuse
after a crash cannot make a stale lock masquerade as a running drain (which would
otherwise silently stall replication forever). Same hardening as the runner's
`runner.pid` + `runner.start`.

**Loud-fail vault pre-check.** Before mounting, the drain confirms a real SMB
credential exists for `poolStorageNetworkUser`. If the user has an empty `vaultKey` **and**
no stored vault entry, mounting would make `Get-Password` auto-generate a random
password the NAS will reject -- so the drain **warns and bails** (no mount,
no junk vault entry). The check is read-only
([Test-VaultEntry](../test/extension/authentication/default.psm1) -- it never
writes the vault or auto-generates). The fix is the recommended vault setup in
[test-config.md](test-config.md#setting-the-smb-passwords-in-the-vault):
map a non-empty `vaultKey` and `Set-Password` it.

## On-share layout

```
<poolStorageLocalPath>/
  hosts/
    info.<hostId>.yml                       # host registry (uuid + fingerprint)
    <hostId>/
      test-cycles/
        000123.2026-06-10.14-22-08.<hostId>/   # one finished cycle's folder
          ...cycle artifacts...
          .yuruna-complete                     # sentinel: copy verified + committed
        000124.2026-06-10.14-39-51.<hostId>/
          ...
      services/                             # this host's service data (proxy)
        caching-proxy-service/{loki,prometheus,grafana}/
  images/                                   # the Download pool (download-agent service)
    .agent-lease.json                       # single-writer lease {hostId, vmName, renewedAtUtc}
    <hostType>/<imageKey>/                  # ubuntu.kvm/guest.ubuntu.server.26/, ...
      current.<arch>.<variant>.json         # servable pointer -- written LAST
      <upstreamFilename>.<sha256[:12]>            # generation artifact
      <upstreamFilename>.<sha256[:12]>.meta.json  # its metadata sidecar
      .staging/                             # agent-private temp area (PID-suffixed)
      manual/<arch>.<variant>/              # drop a hand-downloaded artifact here
  download-agent-service/
    audit.jsonl                             # one line per UI/API mutation
    status.json                             # last-write / heartbeat snapshot
```

`images/` and `download-agent-service/` belong to the **download-agent service**
VM, which CIFS-mounts this same share at `/mnt/yuruna-pool`. Artifacts are
stored under generation names (the upstream filename plus the first 12 hex chars
of its SHA-256) so a refresh writes a new file rather than renaming over one a
host may be streaming; the tiny `current.<arch>.<variant>.json` pointer is
written last and is the only thing whose replacement changes what is served. The
current generation plus one previous is retained per
`(hostType, imageKey, arch, variant)`. The state directory sits *beside*
`images/` rather than inside it so the images tree stays artifacts-only, and pool
walkers skip dot-prefixed entries (`.agent-lease.json`, `.staging/`). The
`manual/` folders are the one place on this share meant to be written by hand:
an artifact the agent cannot fetch itself (Windows 11, when Microsoft refuses
the resolve) is copied in there and adopted into the pool on the next scan --
see [download-agent.md](download-agent.md#when-the-resolver-is-refused-the-drop-folder).
Sizing:
these are full guest ISOs and cloud images, so budget for the families the lab's
host types use -- the UI's totals row reports the current draw. See
[pool-admin.md](pool-admin.md#download-agent-service).

Each run also refreshes `hosts/info.<hostId>.yml` with this host's uuid + a
hardware fingerprint, so a reimaged box can **reclaim** its prior `hostId` instead
of re-keying -- see [Host identity & reimage reclaim](#host-identity--reimage-reclaim).
A host that declines the reclaim (or whose hardware no longer matches) re-keys with
a new `runtime/host.uuid`, so its later cycles land under a new `<hostId>/` root and
old archives are never overwritten. Orphaned roots from retired hosts accrete on the
share; pruning them is a manual housekeeping task.

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
  "lastCopied": 1,

  "recentArchivedBytes": [1043216384, 998244352],
  "movedRecent": [ { "cycle": "000123....", "utc": "...", "bytes": 1043216384 } ],
  "lastMove": { "utc": "...", "moved": 1, "deleted": 1, "spaceShort": false,
                "freeBytes": 91234567890, "requiredBytes": 3293216384 }
}
```

`recentArchivedBytes` is a rolling sample of the last few archived cycle sizes,
recorded in **both** modes so a host switched to move mode already has a real
projection to size its space check against. `movedRecent` and `lastMove` are
diagnostics for move mode.

Entries whose cycle folder no longer exists locally (rotated fully away) are
pruned so the ledger stays bounded. The ledger lives on the host's **ephemeral**
disk: a reimaged host loses it and re-drains its (small, post-rotation) local
backlog -- wasted work, never lost or duplicated data, since copies are idempotent
onto immutable folders.

In move mode the pruning empties the `replicated` map almost as fast as it fills,
because every archived cycle's local folder is deleted. That is safe rather than
alarming: the pending set is *local folders minus the ledger*, so a folder that is
gone locally can never re-enter it. The durable record of what was archived is the
share itself -- each committed folder carries a `.yuruna-complete` sentinel.

## Move mode: the share holds the only copy

With `networkStorage.moveLogsToPoolStorage: true`, each finished cycle is copied,
**verified**, and then deleted locally. Three things change.

**It runs synchronously.** Copy mode fires a detached child and the loop moves on;
move mode cannot, because whether the copy succeeded is part of the cycle's verdict.
The phase is wall-clock bounded (30 minutes overall, 10 minutes per copy) and a slow
NAS produces a warning, not a failure -- a slow share is not a full one.

**The commit order is load-bearing.** Verify -> sentinel -> ledger -> delete. Every
interruption in that sequence is recovered on the next run:

| Killed | Recovery |
|---|---|
| before the sentinel | the destination is sentinel-less, so it is nobody's archive: the next run deletes and recopies it |
| after the sentinel, before the ledger | the cycle is still pending, and the run **adopts** the finished archive rather than re-copying -- re-verifying would compare a possibly half-deleted local source against a complete copy, fail, and delete a perfectly good archive |
| during the delete | the cycle is no longer pending, so a **delete-sweep** at the start of each run finishes it |

**Verification is shape, not content.** Recursive file count and total bytes, source
against destination, before the sentinel is written. Hashing multi-gigabyte folders
across SMB every cycle costs far more than it buys, and rsync/robocopy already verify
each file's own transfer; what this catches is the truncated or partial tree a
connection that dropped mid-copy leaves behind, which a per-file check cannot see
because the missing files were never attempted.

What is never moved: the **live cycle** and any folder whose on-disk leaf still ends
in `.incomplete`. Rotated `history.YYYY-MM-DD/` buckets **are** archived, flattened
into `test-cycles/` -- on-share leaves are always the bare cycle identity, with
`.incomplete` / `.aborted.<UTC>` suffixes stripped.

### Free space, and what a full share does

A share with no room is the one archiving failure that **fails the cycle**, because
in move mode a cycle whose results cannot be archived has lost them. Two checks, one
shared rule -- `free >= ceil(size x 1.10) + 2 GiB reserve`:

- **Before each cycle**, projected from the largest of the last five archived cycles
  (1 GiB floor when there is no sample). Short => the cycle **does not start**: the
  runner records `pool_storage_full` and takes its normal failure pause, which ends
  on a config edit, a new framework/project commit, the dashboard's Start cycle, or
  the one-hour cap -- then re-checks. A cycle that would run for 45 minutes only to
  fail at the end is not worth running.
- **Before each copy**, against the folder's measured size. Short => nothing is copied
  and nothing is deleted; the cycle is marked failed.

The 2 GiB reserve protects the share's **other** tenants -- the guest-image download
pool, the proxy's observability archive, `pool-intent.git` -- from being squeezed to
zero by archiving. Thresholds are code constants in `Test.PoolStorage.psm1`, next to
the wall-clock caps.

A share whose free space cannot be measured never fails anything: the copy proceeds
and fails loudly on its own if the share really is full.

**Nothing prunes the share.** Running out of room is an expected, recoverable state
whose remedy is a human deleting old archives -- which is exactly what the failure
message says. `test/pool/Remove-PoolHost.ps1` removes a retired host's whole archive
root (and its pre-unification one, if any).

## Reading archived results after the local copy is gone

Every link in the product still names the local URL (`log/<cycle>/...`), recorded in
`status.json` history rows written while the folder was local. Rather than rewriting
those after the fact, two read paths resolve them against the share:

- **The host's own status service** re-roots a `log/...` request at
  `<poolStorageLocalPath>/hosts/<hostId>/test-cycles/` when the local file is gone,
  mapping the URL onto the flat share layout (a leading `history.<date>/` segment is
  dropped and lifecycle suffixes are stripped). The same containment and deny-list
  checks apply to the share root as to the local one, and only this host's own
  `hostId` is ever used. The `/cycle/<n>` short link and the `.zip` share page use
  the same fallback, so **Share cycle results** keeps working. The `/log/` index
  merges archived cycle names in, so the directory does not look empty.
- **The pool-aggregator-service** serves the share directly at
  `/archive/<hostId>/test-cycles/<cycle>/...` on `:9400`, from the mount the proxy
  already has (`-pool-archive-root`). `/go/cycle` -- the dashboard's *Open cycle
  results* link -- redirects there whenever the cycle is committed on the share, which
  keeps the link working even when the host is switched off or reimaged. Only
  sentinel-complete folders resolve, so a click can never land inside a copy that is
  still running. A `yuruna_pool_archive_available` gauge reports 0 when the proxy's
  NAS mount is away.

Neither path changes any recorded URL, so `Test.Status.psm1`, `Test.Log.psm1` and the
dashboard JS are untouched.

## Host identity & reimage reclaim

A host's pool identity is `runtime/host.uuid` (a `42`-prefixed 32-hex id). It
lives on the **ephemeral** disk, so a reimage would normally mint a fresh uuid
and fork the host's pool history. To avoid that:

- **Registry.** After every successful drain the host writes
  `hosts/info.<hostId>.yml` to the share, carrying its `hostUuid`, `hostname`,
  `hostType`/`platform`, and a hardware **fingerprint** (SMBIOS product UUID,
  baseboard serial, MAC addresses, CPU model/count, RAM size). Best-effort --
  never blocks the drain.
- **Reclaim.** `Enable-TestAutomation` (all three host platforms) ends with an
  interactive **"Configure poolStorage now?"** prompt. On a host with **no local
  uuid**, it mounts the share, fingerprints the hardware, scans `hosts/` and
  **scores** each record against this hardware. A confident single match is
  offered for reclaim (**operator confirms -- never silent**); the chosen uuid is
  written to `runtime/host.uuid` so the next cycle adopts it. Ambiguous or
  multiple strong matches are listed and default to a new uuid. Decline the prompt
  and a **new uuid is minted** (with a warning that reconnecting the history later
  is harder).
- **Why the fingerprint is captured at enable time.** The strong, near-unique keys
  (`/sys/class/dmi/id/product_uuid`, `board_serial`) are **root-only on Linux**,
  which the unprivileged per-cycle drain cannot read. `Enable-TestAutomation` has
  sudo primed, so it captures the full fingerprint once and caches it to
  `runtime/host.hwid.json`; the drain publishes from that cache. A host that never
  ran the enable step still publishes a degraded (non-privileged) fingerprint --
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

**Linux precondition -- passwordless sudo for the mount.** `sudo -n` never prompts;
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

**`Sync-HostConfiguration` installs this for you.** The unattended runner cannot
self-elevate, but the config sync is an interactive operator session, so it
offers to install the drop-in once -- resolving the account and the real
`mkdir`/`mount`/`umount` paths, writing the rule via `sudo tee` (one password
prompt), and validating it with `visudo -cf` (removing it again if it does not
validate). It is idempotent (a no-op when passwordless sudo is already in effect,
detected via `sudo -n -l`), Linux-only (macOS mounts via `mount_smbfs -N` and
Windows via SMB mappings need no sudo), and skipped under `-NonInteractive` (which
falls back to printing the drop-in to install by hand). The same step is available
directly as `Set-PoolStorageSudoers`.

### Guest-side pool NAS CIFS mount options

The table above is the host side. The service guests -- the download-agent and
pool-control VMs -- mount the same share themselves, at `/mnt/yuruna-pool`, and
persist it through `/etc/fstab` so it survives a reboot and so systemd exposes a
`.mount` unit the daemon can order `After=`. The option string is short and every
part of it is load-bearing:

```
credentials=/etc/yuruna/pool-nas.cifs.cred,vers=3.0,uid=<svc>,gid=<svc>,file_mode=0666,dir_mode=0777,noperm,nofail,_netdev[,ip=<addr>]
```

**The modes are a mapping, not a permission choice.** CIFS has no per-file POSIX
ownership to expose: the whole mount is presented as belonging to one `uid`/`gid`,
and `file_mode`/`dir_mode` are the permission bits every object on it appears to
carry. The server then maps that mount mode onto the ACL of objects the guest
CREATES -- so a tight `dir_mode` does not harden anything, it locks each new folder
to its single creator, and the hosts that have to read the pool back (guest images,
the audit log, archived cycles) lose access to everything the VM wrote. The open
`0777`/`0666` pair is chosen to MATCH the parent share; the share's own ACL is where
access is actually decided. `noperm` tells the client to stop second-guessing with a
local permission check the server will re-evaluate anyway.

**`ip=` covers name resolution the guest does not have.** The share is configured as
a UNC path, and its server component is frequently a bare NetBIOS name or a
host-side alias that only the host's resolver knows. A guest on a hypervisor-private
network cannot resolve either, and the mount fails at name lookup before any
credential is tried. `ip=` hands cifs the address directly and leaves the UNC name
intact for the SMB session. The value is baked by `Get-YurunaPoolSeedValue`, which
never emits an address a guest cannot dial, so it is safe to pass unconditionally
whenever it is present.

**Only the LOCAL fallback directory is ever `chown`ed.** After creating the state
dir, the installers check `mountpoint -q` and run `chown` only when the path is NOT
on the share. On a mounted share the `uid`/`gid` options have already placed
ownership, so the `chown` would buy nothing -- and worse, on a mode-mapped mount it
can push an owner-only ACL back onto the server and lock the hosts out of the very
pool the guest is maintaining. When the mount is absent the daemon degrades to a
local directory that really is POSIX-owned, and there the `chown` is what lets the
unprivileged service user write.

`iocharset=utf8` is deliberately absent: `nls_utf8` is not built into the minimal
cloud kernel and requesting it fails the mount with `error(79)`. Every name in the
pool is ASCII. `nofail` and `_netdev` keep a NAS outage from wedging boot -- the
daemons are written to start without the share and report it as unavailable rather
than refusing to run.

## What is — and isn't — replicated

- **Replicated:** each host's finished **cycle output** (logs, screenshots, NDJSON
  events, diagnostics) -- the per-cycle folders.
- **Not replicated:** the **squid cache** (`/var/spool/squid`). It is fully
  rebuildable from upstream and is handled by squid itself; copying it would
  be churn with no durability value.
- **Service data (caching-proxy-service):** the proxy's **Loki, Prometheus, and Grafana**
  data -- archived to ypool-nas by the guest itself (see *Service replication* below).
  The **stash** service is deferred (no data dir yet); Zot's OCI cache is excluded
  too (rebuildable).

## Service replication (caching-proxy-service)

Beyond the host-side cycle replication above, the caching-proxy-service VM archives its own
**observability data** to the same share so a reimaged proxy can be restored. It is
**guest-side**: the proxy's cloud-init seed carries the config + a credential,
CIFS-mounts the share, and an hourly `ypool-nas-replicate.timer` rsyncs the data dirs to
`<poolStorageNetworkPath>/hosts/<hostId>/services/caching-proxy-service/<svc>/`.

- **Replicated:** `loki` + `prometheus` via `rsync -a` (crash-consistent, additive);
  `grafana` via `sqlite3 .backup` of the live `grafana.db` (a plain rsync of an open
  WAL sqlite can restore corrupt) plus an rsync of the rest. **Excluded:** squid +
  zot (caches), promtail (tail cursor).
- **Account (`networkStorage.poolStorageNetworkUser`).** The proxy mounts with the **single**
  `poolStorageNetworkUser` -- the same account the host uses for cycle replication, with no
  separate guest credential. **Operator prerequisite:** scope `poolStorageNetworkUser`
  **storage-only** on the NAS -- write access to `poolStorageNetworkPath` and nothing else -- and
  `Set-Password` its vault entry. **The password is NOT baked into the seed:** the proxy
  fetches it at boot and hourly from the **config service** over mutual TLS
  (`yuruna-config-fetch pool` -> `GET /v1/nas/pool`), writing `/etc/yuruna/ypool-nas.cifs.cred`
  (0600) and remounting on change -- so **rotating the vault password reaches the running
  proxy without a rebuild** (the host serves the current value live via `Get-Password`).
  Because the account is storage-only, a leaked credential is confined to the pool share
  (no host login, no other service). Empty `poolStorageNetworkUser` => service replication stays off.
- **Enablement** is baked at VM-create time: the seed gets `YPOOL_NAS_REPLICATE=true`
  whenever poolStorage is **configured** (the three `poolStorage*` paths set) -- the
  password need not exist at bake time. Until the vault entry is set, the config
  service answers `503` for `/v1/nas/pool`, the credential file stays empty, the mount
  fails (`nofail`), and replication no-ops -- self-healing on the next hourly run once you
  `Set-Password`. Activating the dynamic fetch requires a baked **client certificate**
  (minted by the host Config CA at VM-create); without it the proxy can't fetch and the
  share stays unmounted.
- **Reachability:** the proxy must be on a **LAN-routable (bridged)** network to reach
  the NAS; on a NAT proxy (Default Switch / UTM Shared / Hyper-V-on-Wi-Fi) the mount
  fails (nofail) and replication silently no-ops -- visible at the breadcrumb below.
- **Visibility:** the proxy publishes `http://<proxy>/ypool-nas-status`
  (`last_attempt=... mounted=0|1 rc_loki=... rc_prometheus=... rc_grafana=...`) and logs to
  `journalctl -u ypool-nas-replicate`.

### Restoring the caching-proxy-service after a reimage (manual)
Replication is one-way; restore is a documented manual step. On the fresh proxy, with
the share mounted at `/mnt/ypool-nas`:
```sh
systemctl stop loki prometheus grafana-server
for s in loki prometheus grafana; do
  rsync -a "/mnt/ypool-nas/hosts/<hostId>/services/caching-proxy-service/$s/" "/var/lib/$s/"
done
chown -R loki:loki /var/lib/loki; chown -R prometheus:prometheus /var/lib/prometheus; chown -R grafana:grafana /var/lib/grafana
systemctl start loki prometheus grafana-server
```
(Grafana also self-rebuilds its datasources + dashboards from the seed's provisioning,
so a restore mainly recovers retained metrics/logs + any runtime dashboard edits.)

A proxy that has not been rebuilt since the per-host roots were unified is still
writing to the pre-unification `/mnt/ypool-nas/<hostId>/services/...` path. Restore
from whichever of the two roots actually holds data; the proxy moves to the
`hosts/` root on its next rebuild.

## Syncing a new host's config from a reference host

### A reference host on older key names

The sync rewrites retired key spellings onto their current paths before it reads
anything, so a reference host that has not been reconciled still hands over its
configuration. This matters most for `networkStorage`: the converter reads a
missing `poolStorageNetworkPath` as *"the reference has no pool storage"* and
**clears the tier**, which also removes the user names, which leaves the
credential sync with nothing to fetch. A reference one rename behind would
therefore erase the section it was asked for, reporting only that the tier was
being cleared.

The renames it handles are in `Get-RetiredConfigKeyMap`
(`test/modules/Test.ConfigNaming.psm1`) -- including the six
`networkStorage.pool*`/`stash*` -> `*Storage*` moves and unit changes such as
`testCycle.stepTimeoutMinutes` -> `stepTimeoutSeconds` (x60).

The translation is **per sync**. The reference keeps serving old names to
everything else, so the sync warns and points at the permanent fix -- run
`pwsh tools/Update-TestConfigNaming.ps1` then `pwsh test/Test-Config.ps1` on the
reference host.

### The copy itself

`host/<type>/Sync-HostConfiguration.ps1 -ReferenceHost <name-or-ip>` copies a
working pool host's `test.config.yml` onto this host -- reference host of ANY
host type -- so a new or reimaged host doesn't have to be configured by hand.
The heavy lifting lives in `test/modules/Test.ConfigServiceSync.psm1`; the three
per-host-type scripts are thin shells (run the one matching this host's OS;
the Windows variant needs an elevated session for the hosts-file write).

**Opting out of pool membership (`-NoPool`).** A disposable or self-verification
host -- e.g. the `example/nested.host` nested-host cycle -- that only needs the
reference host's *cache* but must NOT join the pool can pass `-NoPool`: the sync
drops the `pool` + `networkStorage` nodes, so the host never mounts the NAS,
replicates cycles, or writes a `hosts/info.<hostId>.yml` record. Without it an
ephemeral host (a fresh `hostId` every rebuild) leaves a new dead entry in the
pool set on each run. `vmStart.cachingProxyIp` + `repositories.*` still come
across, so cache reuse is unaffected.

What it does, in order:

1. **Copy + convert.** Fetches the reference config over its status service
   (`GET /control/test-config`, JSON) and converts the host-type-specific
   values: share paths get the local slash style (`\\server\share` vs
   `//server/share`), and an EMPTY local mount path gets the local
   convention -- `y:`/`z:` (Windows), `/mnt/<server>` (Ubuntu),
   `~/Shares/<server>` (macOS). An already-populated local mount path is
   kept (it reflects a working mount). The local `secrets` node survives;
   the reference's is never adopted. Non-portable reference values
   (`file://` projectUrl, absolute `pool.localClonePath`) are kept local
   with a warning. The write is atomic and the previous file lands in
   `test.config.yml.backup`.
2. **Hosts-file alias.** Each networkStorage server name (e.g. `ypool-nas`)
   is reconciled against the reference host's own resolution of it
   (`GET /control/host-aliases`) -- the reference is the source of truth, so
   its address is adopted whenever it disagrees with what this host resolves
   the name to, not only when the name fails to resolve here. That makes a
   re-run repair a **stale** alias (a NAS that moved address) instead of
   leaving the old entry in place because it still "resolves". Written via
   `automation/Set-HostAlias.ps1` (sudo on Linux/macOS); nothing is written
   when the two already agree. If the reference can't supply an address, a
   working local mapping is kept and only a genuinely-unresolved name
   prompts. A failed alias fetch is reported with the server's reason (e.g.
   the 500 a status service that started without its modules returns -- restart
   it on the reference) rather than silently dropping to a prompt.
3. **Vault credential.** Each networkStorage user's credential is reconciled
   against the reference's `GET /control/vault-credential`. That route is
   gated by the internal authentication key (the same one that
   gates the aggregator's push ingest, and 503 until it is configured):
   the request proves token knowledge via an HMAC (the token never crosses
   the wire) and the response password is AES-GCM encrypted with a key
   derived from the token, so nothing crosses the plain-HTTP LAN in
   cleartext. Because that gate is mandatory, **credentials sync only once an
   internal authentication key is provisioned on BOTH hosts** -- the reference (so it
   will serve) and this host (so it can unlock). Before prompting, the sync
   probes the reference: one with no token of its own says so in one
   actionable line (naming
   `Set-LabToken.ps1`) instead of asking for a token and then a
   password it could never have used. With the token in place a re-run
   **refreshes a rotated password** -- the fetched value is compared to the
   stored one and rewritten only when they differ. A user that already has a
   local entry and no key available is kept as-is (pass `-InternalAuthKey`, or
   store an `internal-auth-key`, to have re-runs check it against the
   reference). Values are stored with `Set-Password`; an operator prompt is
   the last resort, only for a missing entry the reference cannot serve.
4. **Mount prerequisite (Linux).** Offers to install the passwordless-sudo
   drop-in the poolStorage mount needs, so validation's mount succeeds instead
   of warning while the runner buffers locally. See the Linux precondition
   above; no-op on macOS/Windows and when already configured.
5. **Validate.** Runs `pwsh test/Test-Config.ps1` (skippable with
   `-SkipValidation`) so a wrong password / share typo / missing sudo rule
   surfaces immediately -- the same gate described below. Its framework/project
   freshness and `projectUrl` reachability checks authenticate to github.com
   with `GH_TOKEN` when set (plain `git` does not read `GH_TOKEN` on its own),
   so a private remote neither fails the check nor blocks on a credential
   prompt.

`-NonInteractive` never prompts (skips with warnings instead);
`-WhatIf` previews. A repeat run with nothing to change writes nothing; re-run
it to pull updated values (a moved NAS, a rotated password) from the reference
host.

## Operating & troubleshooting

`pwsh test/Test-Config.ps1` is the preflight check -- it validates the
networkStorage pool block (all three pool paths set, a usable vault credential so
the mount won't auto-generate a junk password, and SMB `:445` reachability) before
a cycle runs. When the credential is configured **and** the server is reachable, it
**actively mounts `poolStorageLocalPath` and creates the per-host
folder `<poolStorageLocalPath>/hosts/<hostId>`** -- the same write the replicator does -- so a wrong
SMB password, a share-name typo, a missing Linux passwordless-sudo rule, or a
read-only share is caught here instead of failing silently in the detached drain.
With `moveLogsToPoolStorage: true` a failure of this active step is a **FAIL that stops the
cycle** (the gate refuses to start until it is fixed, or you bypass it with
`-NoConfigGate`) -- the local copy is about to be deleted, so archiving has to work.
In copy mode it is advisory only, since the local folder survives regardless. A merely-offline
NAS (no answer on `:445`) stays a WARN -- the loop retries it each cycle, so it
never blocks a healthy run.

`Start-TestRunner`, `Debug-TestSequence`, and `Invoke-TestProject` all run this
same gate at startup, so all three refuse to begin when `moveLogsToPoolStorage` is on
and the share is not writable. The one-shot entry points never archive on their own:
a finished folder from `Debug-TestSequence` / `Invoke-TestProject` waits for the
next runner-driven cycle.

Everything the drain writes lives under the runtime directory:

| File | Purpose |
|---|---|
| `runtime/poolstorage.state.json` | the ledger (archived set + last-run status + the move diagnostics) |
| `runtime/poolstorage.drain.out` / `.err` | **copy mode only** -- the last detached drain's console output (Windows writes both; macOS/Linux writes only `.err`, stdout is discarded). A move-mode host never spawns that child, so these files freeze at the moment it switched; its per-cycle summary goes to the runner console and `runtime/outer.log` instead |
| `runtime/poolstorage.drain.lock` | single-instance lock (`{pid,startTicks}`); absent between runs. Taken by the archiver itself, so it covers the detached drain and the synchronous mover alike |
| `runtime/poolstorage.space-fail.notified` | latch so a share that stays full alerts once per streak rather than once per hour; cleared by the next run that finds room |

A drain's summary line reads e.g. `connectOk=True copied=20 pending=1097 error=''`.

**Run a drain by hand** (without waiting for a cycle), from a runner-active shell
where `$env:YURUNA_*` are set:

```powershell
pwsh -NoProfile -File ./test/modules/Invoke-PoolStorageDrain.ps1 -HostId '<hostId>'
```

The script resolves the mode from config, so a hand-run on a move-mode host moves
(and deletes) exactly as the runner would. It takes the same single-instance lock,
so it is safe to run while the runner is going -- one of the two simply waits for the
next cycle.

or call the function directly after importing the module set
(`Test.PoolStorage`, `Test.StateFile`, `Test.Config`, and the authentication
extension):

```powershell
Import-Module ./test/modules/Test.PoolStorage.psm1 -Force
Invoke-PoolStorageDrain -HostId '<hostId>' -LogDir $env:YURUNA_LOG_DIR -RuntimeDir $env:YURUNA_RUNTIME_DIR -MaxPerRun 500
```

Common findings:

- **`connectOk=False, error='server unreachable...'`** -- the TCP-445 probe failed:
  NAS off, wrong `poolStorageNetworkPath`, or a firewall. The loop is unaffected; the backlog
  resumes when the NAS returns.
- **`error='vault credential not configured'`** -- the loud-fail pre-check: set the
  `poolStorageNetworkUser` password per [test-config.md](test-config.md#setting-the-smb-passwords-in-the-vault).
- **`error='mount failed'` on Linux** -- usually missing passwordless sudo for
  `mount` (see the precondition above).
- **Linux: a message blames the `networkUser` password, but the password is
  correct** -- read the mount's own line first. If it ends in a sudo refusal
  (`sudo: a password is required` on the C sudo, `sudo: interactive
  authentication is required` on sudo-rs, which is Ubuntu's default sudo from
  25.10 on), then `mount` never ran, the NAS was never contacted, and the
  credential cannot be the cause: fix the drop-in, not the password. Confirm in
  one command -- `sudo -n -l /usr/bin/mount` exits 0 when the `NOPASSWD` rule is
  in effect. Check it *while the failure is happening*: sudo-rs writes **no**
  log entry for a refused `sudo -n`, so nothing on the host records the moment
  afterwards. If the rule answers but the mount was still refused, look for
  another `/etc/sudoers.d` file sorting **after** the poolStorage drop-in -- the
  last matching rule wins, so a later one re-requiring a password overrides it.
- **The cycle won't start, gate FAILs on `poolStorageLocalPath / per-host folder
  pre-flight FAILED`** -- `moveLogsToPoolStorage: true` and the active preflight could not
  mount the share or could not create `<poolStorageLocalPath>/hosts/<hostId>` on it. The FAIL line
  names the stage: a *mount* failure points at the password / share name / Linux
  sudo; a *folder* failure points at a read-only share or missing write
  permission for `poolStorageNetworkUser` under `poolStorageLocalPath`. Fix the share, or set
  `moveLogsToPoolStorage: false` (downgrades it to advisory), or bypass once with
  `-NoConfigGate` for an unrelated in-progress edit.
- **`spaceShort=True`, or the cycle fails with `pool_storage_full`** -- the share is
  out of room (see [Free space](#free-space-and-what-a-full-share-does)). Nothing was
  archived and nothing was deleted, so no results were lost. Delete old cycle
  archives under `<poolStorageLocalPath>/hosts/*/test-cycles/`, or retire dead hosts
  with `test/pool/Remove-PoolHost.ps1`; the runner re-checks before each cycle and
  resumes on its own. Check what else is on the volume first -- the guest-image pool
  under `images/` is usually the largest tenant.
- **A dashboard cycle link 404s on a move-mode host** -- the host's own status service
  serves archived cycles from its mount, and the aggregator serves them from the
  proxy's. If both are away the results are reachable only from the NAS directly.
  `yuruna_pool_archive_available 0` on the proxy's `/metrics` means its mount is the
  one that is gone; `mountpoint -q /mnt/ypool-nas` on the proxy confirms it.
- **Local disk keeps growing on a move-mode host** -- archiving is not reaching the
  share at all. Move mode never deletes a folder it did not verify, so a NAS that is
  unreachable, unmountable or credential-broken leaves everything local by design.
  The health warning at each cycle end names the cause; rotation still caps the
  directory, so this is bounded, not unbounded.
- **`another poolStorage run holds the lock`** -- a previous run is still working
  through a backlog (a first archiving pass after a long outage can take a while).
  This cycle's results stay local and the next run picks them up. Nothing is lost.
- **The whole config won't load** -- a Windows drive-letter `poolStorageLocalPath` must be
  **quoted** in YAML (`poolStorageLocalPath: 'w:'`, not `w:`); unquoted it breaks the entire
  `test.config.yml` parse. See the YAML-quoting note in [test-config.md](test-config.md).
- **macOS: the mount is refused however correct the password is** -- macOS keeps a
  separate credential per authentication authority and `smbd` accepts only the
  SMB-NT one, which `sysadminctl` never creates. Every other check passes on such
  an account, including `dscl . -authonly`, which is why the credential looks
  fine. Enable the hash type and re-set the password (only passwords set
  *after* the change get an SMB-NT hash, so both commands are required):
  `sudo pwpolicy -u yuruna-pool -sethashtypes SMB-NT on` then
  `sudo sysadminctl -resetPasswordFor yuruna-pool -newPassword '<lab-vault password>'`.
  `New-LocalLabStorage.ps1` does this itself and proves it with an `smbutil`
  probe; the manual fix is for accounts it did not create.
- **In a guest: `cifs_mount failed w/return code = -111`** -- not a credential
  problem. `-111` is a refused TCP connection, so the guest *did* get an address
  and dialed it: classically the share's server name resolving to something
  host-local (`127.0.0.1` from a local-lab hosts alias), which inside a VM is the
  guest's own loopback. A rejected credential is `mount error(13)` instead, and an
  unresolvable name fails in `mount.cifs` before the kernel is involved. Check
  from inside the guest with `getent hosts <server>` and `grep cifs /etc/fstab` --
  the `ip=` option should name an address the guest can route to. The host-side
  preflight passes in this case, because on the host the alias is correct.

## Security notes

The SMB password lives only in the per-host, git-ignored vault
(`test/status/extension/authentication/vault.yml`), never in `test.config.yml`. It
is passed in-process (Windows) or through a transient `0600` credentials file
(Linux); on macOS it is briefly on the `mount_smbfs` argv (the one residual
exposure, documented above). The vault pre-check is purely read-only: the
replicator neither writes the vault nor alters the password alphabet, length,
or storage.

---

## Pool harness — membership, intent, and test-set execution

The **pool-control service plane** -- creating pools, adding hosts, assigning already-developed
test sequences, and operating the fleet -- is documented step by step in
**[pool-admin.md](pool-admin.md)**; read that to *use* pools. This
page covers only the NAS replication of pool observability data described above.

In brief: the operator authors slow-changing **intent** (pool membership +
`desiredState` + assigned test-sets) into a small **git repo on the caching-proxy-service**
(`/var/lib/yuruna/pool-intent.git`, served read-only over HTTP). Each runner pulls it at
cycle start, finds its pool by locating its `hostId` in `members[]`, and -- when the pool
has assigned test-sets -- drives the cycle from them instead of its local
`test.runner.yml` (decentralized: each host runs only the guests it can, skipping the
rest, trusting another member to cover them). Everything is best-effort and default-off:
an unreachable store, an unpooled host, or a pool with no test-sets all fall back to
single-host behavior. The intent repo holds only **non-secret** files; no credential is
ever routed through it.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.23

Back to [Yuruna](../README.md)
