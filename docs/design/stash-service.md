# Yuruna Stash Service — Specification

## 1. Purpose and Overview

The Yuruna Stash Service is a file-receiving service. Clients send
files to it using the standard `scp` client; the service stores those
files on its own **isolated stash storage share** and indexes them for
later retrieval through a UI (planned, out of scope here).

Operationally, the Stash Service mirrors the existing
[caching proxy](../caching-proxy.md) (Squid cache) service: it lives in
its own VM, is started independently of other services, and is
provisioned on top of an Ubuntu Server image by the standard
update-setup script. Unlike the caching proxy — whose data is
rebuildable and host-local — the stash's received files are **durable**:
they live on a dedicated NAS share configured under
`networkStorage.stash*` (separate from the
[pool storage](../pool-storage.md) share), so they survive VM stop/start
and VM reimage.

## 2. Operational Model

The service exposes only two host-side cmdlets: `Start-StashServer` and
`Stop-StashServer`. There is no `Get-StashServerStatus`,
`Restart-StashServer`, or `Remove-StashServer`: `Stop-StashServer`
removes the VM and all of its on-disk files itself (§3.2), so the next
`Start-StashServer` builds from a clean slate with no leftover VM files.
Wholesale test-VM cleanup (e.g. `Remove-TestVMFiles`) still sweeps a
stash VM like any other, exactly as for the caching proxy.

The Stash Service **depends on its own stash storage being configured**
(`networkStorage.stashNetworkPath`, `stashNetworkUser`,
`stashLocalPath`, and a usable vault password stored for
`stashNetworkUser`), because its StashFolder lives on that dedicated
share (§6.1). This storage is **isolated from the pool share**: the
stash uses its own NAS share and its own NAS account, and does not reuse
the pool credential. If the stash storage is not configured,
`Start-StashServer` fails fast (§3.1) — there is no VM-local storage
fallback.

Search and inspection of received files is done via a UI that reads the
VM-local metadata index and resolves artifacts through the mounted
share. That UI is specified separately in
[stash-service-ui.md](stash-service-ui.md); the storage layout, the
VM-local index, and the on-share sidecar records (§8) are designed so it
can read them directly. The UI spec also notes a few amendments it folds
back into this document (an HTTP listener in the daemon, extra metadata
fields, and a UI-initiated delete path).

## 3. Host-side Components

Two PowerShell cmdlets run on the host and orchestrate the VM
lifecycle.

### 3.1 Start-StashServer

- Creates a new VM from the configured Ubuntu Server image. Default
  image: `ubuntu.server.26` (Ubuntu 26.04 LTS, Resolute Raccoon —
  matching the caching proxy's LTS track). Configurable via cmdlet
  parameter.
- **Stash storage pre-flight.** Validates
  `networkStorage.stashNetworkPath`, `stashNetworkUser`,
  `stashLocalPath`, and a **stored** vault credential for
  `stashNetworkUser` (`Get-YurunaStashStorageConfig` plus a stored-
  credential check). Missing or unusable configuration ⇒ the cmdlet
  refuses to start and points the operator at the stash storage setup.
  No VM-local storage fallback.
- **Networking:** DHCP on a **LAN-routable (bridged)** interface,
  reusing the conventions already used by the caching proxy. A bridged
  interface is required so the VM can reach the NAS over SMB3 (same
  constraint as caching-proxy service replication — a NAT'd VM cannot
  reach the share).
- Bakes the stash storage `stashNetworkPath` + `stashNetworkUser`
  credential and the host's `hostId` into the VM's cloud-init seed (same
  mechanism as the caching-proxy ypool-nas service replication), and installs
  `cifs-utils`, so the VM can mount the stash share.
- After first boot, runs the existing `ubuntu.server.26.update.sh`
  setup script. The update-setup always clones the Yuruna repository
  into the VM (existing behavior), which provides the daemon source and
  the in-VM UI code.
- Mounts the share over cifs (`nofail`) and ensures the StashFolder
  subtree (§6.1) exists.

### 3.2 Stop-StashServer

- Gracefully stops the VM, then removes it and **all of its on-disk
  files** — the registry/domain entry, the copied disk image, the
  cloud-init seed, and (UTM) the `.utm` bundle — so the next
  `Start-StashServer` builds from a clean slate with no leftover VM
  files. The graceful stop runs first so the daemon's flush worker
  (§8.4) can push NAS-offline buffered uploads to the share before the
  disk is deleted.
- The durable stash data is untouched: received files, the per-artifact
  sidecar records (§8.5), and the persisted SSH host key (§4.4) live on
  the NAS stash share, not on the disposable VM disk.
- In-flight uploads are not drained: a hard stop is acceptable. Any
  partial files, `status = pending` records, and not-yet-flushed
  locally-buffered artifacts (§8.4) still on the VM-local disk are
  discarded with it — the same reimage caveat as §8.4. Committed
  (on-share) artifacts and their sidecars are durable.

## 4. VM-side Service

A long-running daemon inside the VM accepts SCP connections.

### 4.1 Implementation

Custom SSH server, implemented using Go's `crypto/ssh`. Not OpenSSH. The
server accepts files two ways, both routed into the same stash storage:

- **Legacy SCP sink-mode wire protocol** (`scp -t`) — the original
  protocol; required for the multi-file / recursive ZIP grouping (§5.3,
  §5.4) and for surfacing the upload ID to the client (§9).
- **SFTP subsystem** (write-only) — because modern OpenSSH `scp` (≥ 9.0)
  uses the SFTP protocol **by default** and does not fall back to the
  legacy protocol. Without this, a plain `scp` would require `-O`. The
  SFTP backend stores each uploaded file as its own record; it does not
  ZIP-group (§5.3/§5.4 are legacy-only) and cannot surface the ID to the
  client (§9). Downloads and directory listings are refused — the stash
  is a sink. Stat reports any path as a directory so `scp` appends the
  local filename (path stays metadata, §5.1).

### 4.2 Listening Port and Bind Interface

TCP port 22, bound to all interfaces (`0.0.0.0`). The default sshd
inside the VM must be disabled so the custom server can bind port 22.
Local TTY remains the only interactive access path to the VM; no GUI.

### 4.3 Authentication

Auth is a pass-through used only to capture the username as metadata; no
credentials are validated.

- The daemon accepts the SSH **"none"** method, so a standard `scp`/`sftp`
  client connects with **zero prompts** (no passphrase, no password) — the
  right experience for an automated, trusted-network sink. The username
  from the auth request is still captured and stored as metadata.
- **Password** is accepted as a fallback (any value) for a client that
  declines "none".
- **Public-key auth is deliberately NOT advertised.** Accepting any key
  would make clients offer their local keys and prompt for each key's
  passphrase before connecting — friction with no security value here.
- Any username is accepted and captured.

### 4.4 Host Key

A single SSH host key is generated on first run and persisted across
restarts. Stored under the StashFolder (§6.1) — i.e. **on the stash
share** — so it survives VM stop/start **and reimage** without clients
re-trusting the host. Because the StashFolder is namespaced per
`hostId` (§6.1), each host's stash carries its own persistent host key.

Storing the private host key on the share exposes it to anything
holding the storage-only `stashNetworkUser` credential; given the §11
trusted-network posture and the pass-through auth (§4.3), an
impersonator gains nothing a direct connection would not already grant,
so this is an accepted trade-off.

### 4.5 OS-level User

No Linux user is created for SCP purposes. The custom SSH server
accepts any client-supplied username as metadata; no dedicated OS user
is needed. The service runs as whatever user it is launched as, which
must have write access to the mounted StashFolder and to the VM-local
metadata + buffer directories (§6.1, §8.4).

### 4.6 Process Management and Logging

The daemon is launched and supervised by a **systemd unit** installed
during bring-up (`Restart=on-failure`). The unit must order `After=`
the cifs mount of the StashFolder so the daemon does not start before
the share is available. Operational logs are written to stderr,
captured by journald (`journalctl -u stash-server`).

### 4.7 Presence Beacon

The daemon **self-announces** to the pool-aggregator (`POST
<aggregator>/announce`) so the pool dashboard's **Extension hosts** row
exists **without depending on the owning host's status server**. The
registration path (`host.registration.json`, read by the aggregator
through that status server) goes silent whenever the status server is
down — the state a host reboot routinely leaves behind — while the
stash VM auto-restarts and keeps serving; the beacon is the service's
own liveness signal for exactly that gap.

Behavior:

- **hello** at daemon startup (retried on a short catch-up cadence
  until the aggregator first answers, covering whole-lab boot ordering);
- **re-announce** every `--presence-interval` (default **15 minutes**,
  `0` disables) so the aggregator's announce TTL never expires while
  the service lives;
- **goodbye** (`active: false`) at shutdown, best-effort, so a
  deliberately stopped service leaves the panel immediately instead of
  aging out.

The announce carries the **owning host's** `hostId` (`--host-id`, baked
from the stash storage seed at bring-up — the same identity the pool
table keys on) and the daemon's UI **port**; the aggregator derives the
service URL from the connection's **source address**, so the daemon
never needs to know its own IP and an announcer can only advertise
itself. The aggregator reaps an entry not refreshed within its
`-announce-ttl` (default 45 minutes — tolerant of two missed beacons).
Best-effort throughout: an unreachable aggregator never affects stash
operation.

## 5. SCP Protocol Behavior

The service accepts files from clients invoking the standard syntax:

```
scp <file> <username>@<host>:<path>
```

### 5.1 Path Handling

The client-supplied path is **not** used as a filesystem location on
the server. The path is captured verbatim as "path metadata" and
persisted with the file record.

### 5.2 Single-file Upload

One file in → one stored artifact, one generated ID, one metadata
record.

### 5.3 Multi-file Upload

Example: `scp a.txt b.txt user@host:/path`

All files in the invocation are placed into a single temporary folder
on the server and then archived into one ZIP. The ZIP is the stored
artifact. One ID, one metadata record per invocation. **Legacy protocol
only:** over SFTP (§4.1) each file is a separate record — the SFTP
protocol uploads files independently, with no invocation boundary to
group on.

### 5.4 Recursive Upload

Example: `scp -r dir/ user@host:/path`

Supported. The transferred directory tree is archived into a single
ZIP. The ZIP is the stored artifact. One ID, one metadata record per
invocation. **Legacy protocol only**, as in §5.3: over SFTP each file in
the tree becomes its own record.

### 5.5 Filename and Size Edge Cases

- **Empty filename:** ignored (no file stored, no metadata record).
- **Zero-byte file:** saved as a zero-byte file. The filename itself
  may be the meaningful payload, so the record is still created.
- **Per-file size limit:** 100 MB, defined as a constant in code. Files
  exceeding the limit are truncated at 100 MB. Metadata flags the
  truncation with `status = truncated`.

### 5.6 Concurrency

Multiple simultaneous SCP sessions are supported. A mutex protects ID
generation to ensure per-day uniqueness under concurrent allocation
within the daemon. Metadata writes rely on SQLite's transactional model
and do not require an additional application-level lock. File writes use
unique paths (the per-day-unique ID).

Because the StashFolder is namespaced per `hostId` (§6.1), **each stash
daemon owns a distinct path** on the share. The in-process mutex is
therefore sufficient even with multiple stash VMs in the pool: IDs need
only be unique **per day, per hostId**, and no cross-process
coordination is required.

## 6. Storage Layout

### 6.1 StashFolder

Received files and the persisted host key live under a **StashFolder**
that is a subfolder of the dedicated stash share, namespaced by
`hostId`:

```
<networkStorage.stashNetworkPath>/<hostId>/     # e.g. //server.local/work/yuruna.stash/42ab…/
```

mounted on the VM at `<networkStorage.stashLocalPath>/<hostId>/` (e.g.
`/mnt/stash/42ab…/`). The `hostId` (`runtime/host.uuid`) is baked
into the cloud-init seed by `Start-StashServer`. The StashFolder path is
configurable; the above is the default.

The **metadata index** does **not** live on the share — SQLite's file
locking is unreliable over SMB/CIFS — but on the VM's local disk (§8).
Durable, reimage-surviving metadata is provided by per-artifact sidecar
records on the share (§8.5).

### 6.2 Directory Structure

```
On the share (durable):
<stashNetworkPath>/<hostId>/
├── hostkey/                                # persisted SSH host key(s)
└── files/
    └── yyyy/
        └── mm/
            └── dd/
                ├── a1b2.pdf                # single file with extension
                ├── a1b2.yuruna.meta.json   # sidecar record for a1b2 (§8.5)
                ├── c3d4                     # single file with no extension
                ├── c3d4.yuruna.meta.json
                ├── e5f6.yuruna.archive.zip  # multi-file or recursive upload
                └── e5f6.yuruna.meta.json

VM-local (ephemeral):
/var/lib/stash-server/
├── metadata/stash.sqlite                   # query index (§8)
└── buffer/                                 # NAS-offline staging (§8.4)
```

The `yyyy/mm/dd` folder is created on the first upload for that date.
Date is in UTC.

### 6.3 Stored Artifact Naming

The on-disk filename is `<id>` optionally followed by an extension
derived from the original filename, per the rules below.

**Single-file uploads.** The extension is derived from the original
filename and appended to the ID (e.g. `a1b2.pdf`, `a1b2.tar.gz`). This
makes preview tools work naturally on the stored files.

Extension extraction rules, applied in order:

1. **No dot** in the filename (e.g. `Makefile`, `LICENSE`): no
   extension. Store as `<id>`.
2. **Filename starts with a dot** (e.g. `.bashrc`, `.gitignore`,
   `.config.json`): treated as a dotfile with no extension, regardless
   of any internal dots. Store as `<id>`. The leading-dot rule wins
   over the multi-dot rule below.
3. **Filename contains one or more dots and does not start with one:**
   the extension is everything from the first dot onward (e.g.
   `report.final.v2.pdf` → `.final.v2.pdf`; `archive.tar.gz` →
   `.tar.gz`). This preserves compound extensions.
4. **Length cap:** the extension is capped at 32 characters total,
   including the leading dot. Anything beyond the cap is discarded.
5. **Charset sanitization:** only characters in `[A-Za-z0-9._-]` are
   kept. When the extension contains any character outside that set,
   **the entire extension is discarded and the file is stored as
   `<id>` only** (RESOLVED — see §13).
6. **Case normalization:** after sanitization, the extension is
   lowercased before being written to disk (e.g. `report.PDF` → stored
   as `<id>.pdf`).

The `originalFilename` metadata field always records the filename as
sent by the client, with original case and characters preserved.

**Multi-file and recursive uploads.** The archive's on-disk filename is
`<id>.yuruna.archive.zip`. This extension is fixed and not derived from
any client-supplied name.

## 7. ID Generation

- **ID format:** exactly **4 characters**, lowercase letters and
  digits, alphabet `[a-z0-9]` (RESOLVED — always 4). The per-day space
  is 36⁴ ≈ 1.68 million IDs.
- **Uniqueness scope:** per day, per `hostId`, i.e. unique within one
  `yyyy/mm/dd` folder under one host's StashFolder. IDs may repeat
  across dates and across hosts.
- **Collision handling:** regenerate and retry until a unique ID is
  found within that day's folder.
- **Timing:** the ID is generated before the file is received, so it can
  be written into the metadata record up front and returned to the
  client at the start of the transfer.

## 8. Metadata

Metadata is stored in a SQLite database on the VM's **local** disk
(default `/var/lib/stash-server/metadata/stash.sqlite`) — not on the
share, because SQLite locking is unreliable over SMB/CIFS. The local
DB is the fast query index; durable metadata is the on-share sidecar
records (§8.5), from which the local index can be rebuilt after a
reimage.

### 8.1 Record Fields

Each upload produces one metadata record:

| Field | Description |
|---|---|
| `id` | Generated 4-character ID |
| `storedPath` | Absolute path to the stored artifact, including the extension when present. Points to the share location once committed (e.g. `…/<hostId>/files/yyyy/mm/dd/a1b2.pdf`), or to the VM-local buffer while `locallyBuffered` is true (§8.4) |
| `originalFilename` | Filename as sent by the client, original case and characters preserved. Multi-file uploads: a synthesized name (e.g. the temp folder name). Recursive uploads: the root directory name |
| `isArchive` | Boolean — true when the artifact is a ZIP (multi-file or recursive upload) |
| `username` | Username supplied by the client |
| `pathMetadata` | The destination path the client put after the `:` in the SCP command |
| `clientAddress` | Source IP of the SCP connection |
| `createdAt` | Datetime (UTC) the record was first created (before transfer began) |
| `receivedAt` | Datetime (UTC) the upload completed (null while pending) |
| `status` | One of `pending`, `complete`, `partial`, `truncated` |
| `sizeBytes` | Final size of the stored artifact in bytes |
| `locallyBuffered` | Boolean — true while the artifact is on the VM-local buffer awaiting flush to the share (§8.4) |

### 8.2 Atomicity and Write Order

1. Generate the ID with per-day uniqueness retry.
2. Create the metadata record with `status = pending`, populating
   everything known up front (`id`, `username`, `pathMetadata`,
   `originalFilename`, `clientAddress`, `createdAt`, intended
   `storedPath`).
3. Stream the file to disk:
   - **Share writable:** stream into a share staging dir, then finalize
     into `…/files/yyyy/mm/dd/<id>[.ext]`.
   - **Share not writable:** stream into the VM-local buffer
     (§8.4); set `locallyBuffered = true` and `storedPath` to the local
     path.
4. On successful completion: update the record to `status = complete`,
   or `status = truncated` if the 100 MB cap was hit; set `receivedAt`
   and `sizeBytes`; write the sidecar (§8.5) next to the committed
   artifact (skipped while `locallyBuffered`, written at flush time).
5. On failure mid-transfer: the partial file is kept on disk; the
   record is updated to `status = partial` with whatever `sizeBytes`
   was received.

### 8.3 Search Requirements

The store must support efficient lookup by:

- `id` (exact)
- `username` (exact and substring)
- `createdAt` / `receivedAt` (range)
- `originalFilename` (substring)
- `pathMetadata` (substring)

The future UI is the primary consumer of these queries.

### 8.4 Local Buffering and Flush (NAS-offline resilience)

When the share is unreachable or unmounted, uploads are not rejected:
the daemon streams the artifact to a VM-local buffer
(default `/var/lib/stash-server/buffer/`, mirroring the
`files/yyyy/mm/dd/` layout) and marks the record `locallyBuffered =
true`.

A **flush worker** runs periodically and on mount-return. For each
locally-buffered artifact it:

1. Copies the artifact into the share staging dir and fsyncs it.
2. Atomically renames it into `…/files/yyyy/mm/dd/<id>[.ext]`.
3. Writes the sidecar record (§8.5).
4. Updates `storedPath` to the share path and clears `locallyBuffered`.
5. Deletes the VM-local copy.

The flush is idempotent: an artifact already present on the share (same
`id`/day) is treated as committed and the local copy is cleaned up.

**Buffer ceiling.** The buffer has a capacity constant (default 5 GB).
Once exceeded, further uploads are rejected (§9 still returns the ID and
the daemon logs the rejection) rather than filling the VM disk.

**Reimage caveat.** The buffer and the VM-local index are on ephemeral
disk. A VM reimage — or a `Stop-StashServer`, which deletes the VM disk
(§3.2) — during a NAS outage loses any not-yet-flushed artifacts and
their records. Committed (on-share) artifacts and their sidecars are
unaffected.

### 8.5 On-share Sidecar Records (durable metadata)

Each committed artifact gets a sidecar JSON file written next to it on
the share, named `<id>.yuruna.meta.json`. It carries the full §8.1
field set. The sidecar is written **last** — after the artifact is
finalized on the share — so its presence marks a fully committed upload
(the same "sentinel written last" pattern poolStorage uses with
`.yuruna-complete`).

Sidecars make the rich metadata durable without placing a mutable
SQLite DB on SMB. After a VM reimage, the daemon rebuilds the VM-local
index by scanning the sidecars under `files/`. The sidecar file name
shares the artifact's `<id>` prefix, so it reserves the same ID in the
on-disk allocator scan (§7) and is never itself treated as an artifact.

## 9. Returning the ID to the Client

Under the **legacy** SCP protocol the generated ID is written to the SSH
connection's stderr channel during the exchange. Standard `scp` clients
render stderr to the user's terminal, so the ID becomes visible to the
operator.

Format (single line, stable marker prefix):

```
YURUNA-STASH-ID: <id>
```

**SFTP limitation:** the SFTP protocol has no channel to surface this
line to the `scp`/`sftp` client, so over SFTP (§4.1) the ID is logged
server-side and recorded in metadata, not echoed to the client. An
operator who needs the ID at upload time can use `scp -O` (legacy).

## 10. Configuration

**Configurable** (defaults shown):

| Setting | Default | Where |
|---|---|---|
| VM base image | `ubuntu.server.26` | Host-side cmdlet parameter |
| StashFolder path | `<stashNetworkPath>/<hostId>` (mounted at `<stashLocalPath>/<hostId>`) | VM-side service config |
| VM-local metadata path | `/var/lib/stash-server/metadata/` | VM-side service config |
| VM-local buffer path | `/var/lib/stash-server/buffer/` | VM-side service config |
| Presence re-announce period (§4.7) | `15m` (`0` disables) | `--presence-interval` (`STASH_PRESENCE_INTERVAL` at bring-up) |
| Presence identity (§4.7) | owning host's `hostId` from the stash storage seed | `--host-id` (baked at bring-up) |
| Aggregator base URL (§4.7, UI §3.4) | baked from the host's caching-proxy state | `--aggregator-url` (`STASH_AGGREGATOR_URL` overrides) |
| Delete-authorized host IP (UI §8.4) | baked from the seed's `YURUNA_HOST_IP` | `--host-ip` (`STASH_HOST_IP` overrides) |

**Dependency:** `networkStorage.stashNetworkPath` + `stashNetworkUser`
+ `stashLocalPath` (+ a stored vault password for `stashNetworkUser`)
must be set (§2, §3.1).

**Constants in code** (not configurable for now):

| Setting | Value |
|---|---|
| Listening port | 22 |
| Bind interface | 0.0.0.0 |
| Per-file size limit | 100 MB |
| ID alphabet | `[a-z0-9]` |
| ID length | 4 |
| Extension length cap (incl. leading dot) | 32 characters |
| Extension allowed charset | `[A-Za-z0-9._-]` |
| Archive extension (multi/recursive) | `.yuruna.archive.zip` |
| Sidecar extension | `.yuruna.meta.json` |
| Local buffer ceiling | 5 GB |
| Date timezone | UTC |
| Stderr ID format | `YURUNA-STASH-ID: <id>` |

## 11. Security Posture

This service is intentionally open: it accepts connections with no
credentials at all (SSH "none"), or any password (§4.3); no credentials
are validated. It is designed to run on a trusted network alongside
other Yuruna test infrastructure. Network ACLs, rate limiting, file
scanning, and similar hardening are not in scope for this version.

The `stashNetworkUser` SMB credential is baked into the VM's cloud-init
seed (the same accepted trade-off as the caching-proxy ypool-nas seed): scope
`stashNetworkUser` **storage-only** on the NAS — write access to
`stashNetworkPath` and nothing else — so a compromised stash VM leaks
only stash-share access (no host login, no other service, and no pool-
share access since the stash uses its own isolated account). The SSH
host private key resides on the share (§4.4). This service introduces no
change to the password alphabet, length, or storage.

## 12. Out of Scope (this version)

- Backup or restore beyond the durability the NAS share and sidecar
  records (§8.5) already provide.
- Authentication and authorization beyond protocol-level pass-through.
- File retention, aging, or cleanup policies. Orphaned data is manual
  housekeeping (as with poolStorage orphan host roots).
- Logging beyond stderr captured by journald.
- `Get-StashServerStatus`, `Restart-StashServer`, `Remove-StashServer`
  cmdlets.
- The UI for browsing and searching received files — specified in
  [stash-service-ui.md](stash-service-ui.md). (That spec amends a few
  items here: see §13 of the UI spec.)
- Cross-day and cross-host ID uniqueness.

## 13. Design Decisions

Key design decisions:

- **Disallowed characters in an extension (§6.3, rule 5):** discard the
  entire extension and store as `<id>` only (the simplest, safest
  option).
- **ID length (§7, §10):** always 4 characters over `[a-z0-9]`.
- **StashFolder location (§6.1):** a `hostId`-namespaced subfolder of
  the dedicated stash network share (`networkStorage.stashNetworkPath`),
  isolated from the pool share.
- **Metadata store (§8):** VM-local SQLite index, durable on-share
  sidecar records.
- **No stash storage configured (§3.1):** fail fast.
- **Share unreachable mid-receive (§8.4):** buffer locally, flush on
  return.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.22

Back to [Yuruna](../../README.md)
