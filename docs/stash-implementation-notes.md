<a id="429e934f-0001"></a>

# Stash implementation notes

These notes describe the constraints the stash service daemon
(`test/extension/stash-service/server/`) is built around. The Go sources keep
short comments and point here for the longer explanation. The operator view of
the service -- how to use it, its limits and its pages -- is the
[stash guide](stash-guide.md).

<a id="429e934f-0002"></a>

## One daemon, one pipeline

Applies to: `main.go`, `internal/httpsrv/httpsrv.go`, `internal/sshsrv/ingest.go`,
`internal/config/config.go`

One Go process serves both ways in: the SSH sink on port 22 (SCP and SFTP) and
the HTTP UI and API on port 80. They share one ID allocator, one storage
pipeline and one VM-local index, so a stash created in the browser is
indistinguishable from one sent with `scp`: same naming, same record, same
sidecar, same buffering when the share is offline. The only difference a record
carries is its `source` (`scp` or `ui`).

<a id="429e934f-0003"></a>

## Listener and authentication

Applies to: `internal/sshsrv/sshsrv.go`, `main.go`

The sink listens on TCP 22 on all interfaces; the VM's own sshd is disabled so
the daemon can bind it, and the VM's local console stays the only interactive
path (the daemon refuses shell and exec requests). Authentication is a
pass-through that captures the username as metadata and validates nothing: the
SSH "none" method is accepted so `scp` and `sftp` connect with no prompt, a
password is accepted with any value for a client that declines "none", and
public-key authentication is not advertised, because accepting any key would
make clients prompt for each local key's passphrase for no security gain.

<a id="429e934f-0004"></a>

## Trust posture

Applies to: `internal/scp/scp.go`, `internal/sshsrv/sshsrv.go`

The service runs on the lab LAN, which is the trust boundary: the sink takes
files from anyone who can reach it, and reads stay open. What the code still
guards against is damage within that posture -- a client path never becomes a
server path, a body or a control line is bounded, untrusted bytes never execute
in a browser, and the destructive verb (delete) needs the lab gate. The SMB
credential baked into the VM is scoped to the stash share only.

<a id="429e934f-0005"></a>

## Host key

Applies to: `internal/sshsrv/sshsrv.go`

The SSH host key is generated once and stored under the StashFolder on the
share (`hostkey/`), so it survives a VM restart and a reimage without clients
re-trusting the host, and each `hostId` has its own. A present share key wins
and must be a readable, valid regular file (or a link to one); an unreadable,
corrupt, dangling or non-regular share key stops startup rather than being
replaced, and creating a key never overwrites a competing publisher's. When the
share-key path is absent, startup may use an existing VM-local key under
`buffer/hostkey/` or create one there if the share cannot take it; a local key
is promoted only to an absent share key. When permission or I/O errors leave the
share key's state unknown, startup proceeds only with an already provisioned
valid local key and writes neither path. The key on the share is readable by
anything holding the stash share credential; under the pass-through
authentication an impersonator gains nothing a direct connection does not.

<a id="429e934f-0006"></a>

## Presence beacon

Applies to: `main.go`, `internal/config/config.go`, `internal/httpsrv/httpsrv.go`

The daemon announces itself to the pool aggregator (`POST /announce`), so the
pool dashboard's Extension hosts row does not depend on the owning host's status
service, which is down exactly when a host reboot leaves the stash VM serving on
its own. It sends a hello at startup (retried on a short cadence until the
aggregator first answers), re-announces every `--presence-interval` (default two
minutes, `0` disables), and says goodbye at shutdown. The announce carries the
owning host's `hostId` (`--host-id`) and the UI port; the aggregator takes the
address from the connection, so the daemon never needs its own IP and can only
advertise itself, and the aggregator confirms the address (`/healthz`) before
publishing it. The same `--aggregator-url` resolves a `hostId` to that host's
stash UI (see *Host attribution and links*). All of it is best effort: an
unreachable aggregator never affects stash operation.

<a id="429e934f-0007"></a>

## Upload protocols

Applies to: `internal/scp/scp.go`, `internal/sshsrv/sftp.go`, `internal/sshsrv/sshsrv.go`

Two protocols land in the same storage. The legacy SCP sink protocol (`scp -t`)
is the one that groups a multi-file or recursive upload into one ZIP and writes
the upload ID to the client (see *Upload IDs*). SFTP is served because OpenSSH
`scp` 9.0 and later uses it by default with no fallback; it is write-only
(downloads are refused and a listing is always empty, since the stash is a sink), it stores each
file as its own record because SFTP has no invocation boundary to group on, and
it cannot show the ID to the client. In both, the client-supplied path is never
a server location: it is recorded verbatim as `pathMetadata`, and SFTP reports
every path as a directory so `scp` appends the local file name.

<a id="429e934f-0008"></a>

## Filename and size edge cases

Applies to: `internal/scp/scp.go`, `internal/sshsrv/sftp.go`, `internal/sshsrv/sshsrv.go`,
`internal/sshsrv/ingest.go`, `internal/meta/meta.go`

An empty file name stores nothing and keeps no record (the pending row written
up front is removed). A zero-byte file is stored, because its name may be the
payload. A file is capped at 100 MiB: bytes past the cap are dropped and the
record's status is `truncated`. The cap is the same for every way in.

<a id="429e934f-0009"></a>

## Upload IDs

Applies to: `internal/id/id.go`, `internal/sshsrv/sshsrv.go`, `internal/sshsrv/sftp.go`,
`main.go`, `internal/config/config.go`

An ID is four characters of `[a-z0-9]`, unique per UTC day per `hostId` -- one
`yyyy/mm/dd` folder under one host's StashFolder -- and may repeat across days
and hosts. It is drawn before any byte arrives, so the pending record can carry
it and the legacy protocol can return it at the start of the transfer, on the
SSH stderr channel as the line `YURUNA-STASH-ID: <id>`. A collision is redrawn.
One in-process mutex makes allocation safe under concurrent sessions, and needs
no cross-process coordination because each daemon owns its own `hostId` folder.
The allocator also treats an ID claimed by a not-yet-flushed buffered artifact as
taken, so a flush can never collide with a newer upload of the same day.

<a id="429e934f-000a"></a>

## Storage layout

Applies to: `internal/store/store.go`, `internal/config/config.go`, `main.go`

The durable data lives under the StashFolder, a `hostId`-named subfolder of the
dedicated stash share: `hostkey/` and `files/yyyy/mm/dd/` (UTC dates, created on
the first upload of a day), each artifact next to its sidecar. The metadata index
and the offline buffer are VM-local (`/var/lib/stash-service/metadata/` and
`/var/lib/stash-service/buffer/`): SQLite's locking is unreliable over SMB, so
the index never lives on the share, and the sidecars are what makes metadata
survive a reimage. The buffer mirrors the share's `files/` layout, so a flush is
a copy to the same relative path.

<a id="429e934f-000b"></a>

## Stored artifact names

Applies to: `internal/store/store.go`, `internal/config/config.go`, `internal/sshsrv/ingest.go`

A single file is stored as `<id>` plus an extension derived from its original
name, so preview tools work on the stored files. The rules, in order: no dot
means no extension; a name starting with a dot is a dotfile with no extension,
whatever dots follow; otherwise the extension is everything from the first dot
(compound extensions such as `.tar.gz` survive); it is capped at 32 characters
including the dot; any character outside `[A-Za-z0-9._-]` discards the whole
extension (the simplest safe choice); and it is lowercased. The record keeps the
original name as sent. A multi-file or recursive upload is stored as
`<id>.yuruna.archive.zip`, an extension never derived from client input.

<a id="429e934f-000c"></a>

## Metadata index

Applies to: `internal/meta/meta.go`, `internal/config/config.go`, `main.go`

One row per upload in the VM-local SQLite index: `id`, `storedPath`,
`originalFilename`, `isArchive`, `username`, `pathMetadata`, `clientAddress`,
`createdAt`, `receivedAt`, `status` (`pending`, `complete`, `partial` or
`truncated`), `sizeBytes`, `locallyBuffered`, and the type fields of *Content
type detection*. The index supports lookups by exact `id`, by `username` (exact
and substring), by date range, and by substring of `originalFilename` and
`pathMetadata`. It is a fast query index, not the durable record: on a fresh VM
with an empty index the daemon rebuilds it from the sidecars on the share.

<a id="429e934f-000d"></a>

## Write order

Applies to: `internal/meta/meta.go`, `internal/sshsrv/sshsrv.go`, `internal/sshsrv/sftp.go`,
`internal/scp/scp.go`, `internal/sshsrv/ingest.go`

Every upload follows one order: draw the ID; write the record as `pending` with
everything known up front; stream the bytes into a staging folder on the share
when it is writable, or into the VM-local buffer otherwise; on success, finalize
the artifact, mark the record `complete` or `truncated` with its size and
receive time, and write the sidecar last. A transfer that fails midway keeps the
bytes received and marks the record `partial`.

<a id="429e934f-000e"></a>

## Local buffering and flush

Applies to: `internal/sshsrv/flush.go`, `internal/sshsrv/sshsrv.go`, `internal/store/store.go`,
`internal/meta/meta.go`, `internal/id/id.go`, `internal/httpsrv/poolindex.go`, `main.go`,
`internal/config/config.go`

The share being offline does not reject uploads. Once startup has a host key,
an upload while the share is not a live writable network mount streams into the
VM-local buffer and its record is marked `locallyBuffered`. A flush worker,
periodic and woken when the mount returns, moves each buffered artifact in
arrival order: copy into the share's staging folder and sync, rename into
`files/yyyy/mm/dd/`, write the sidecar, point the record at the share, delete
the local copy. It is idempotent: an artifact already on the share counts as
committed. The buffer stops taking uploads at 5 GiB rather than fill the VM
disk. A reimage during an outage loses what was not flushed; committed artifacts
are unaffected. The rest of the daemon degrades the same way: a pool scan that
cannot read the share shows no remote stashes rather than failing.

<a id="429e934f-000f"></a>

## Sidecar records

Applies to: `internal/meta/meta.go`, `internal/sshsrv/sshsrv.go`, `internal/config/config.go`,
`main.go`

Each committed artifact has `<id>.yuruna.meta.json` beside it on the share,
carrying the whole record. It is written last and atomically, so its presence
marks a fully committed upload, and a failure to write it is retried, because it
is the record a reimage rebuilds from. A sidecar shares the artifact's ID
prefix, so it reserves that ID in the allocator's scan and is never taken for an
artifact. Other hosts read the pool from these sidecars.

<a id="429e934f-0010"></a>

## Configuration and constants

Applies to: `internal/config/config.go`

Configurable: the sink address (`0.0.0.0:22`; `--listen-addr` is a dev-only
override), the StashFolder, the metadata and buffer directories, the UI
address (`:80`), the pool window and rescan interval, the list page size, the
aggregator URL, the presence identity and interval. Constants in code: the
100 MiB file cap, the ID alphabet and length, the
32-character extension cap and its character set, the archive and sidecar
extensions, the 5 GiB buffer ceiling, UTC dates, the `YURUNA-STASH-ID:` line,
the 500-row list cap and the 1 MiB inline text preview. Constants are frozen
here so a change is one edit.

<a id="429e934f-0011"></a>

## Pages and API

Applies to: `internal/httpsrv/handlers.go`, `internal/httpsrv/httpsrv.go`

The pages are plain HTML, CSS and JavaScript embedded in the binary (vendored
from the shared look of the status pages, never fetched from a host at run
time) over a JSON API under `/api/`. Every API answer is `no-store`, and an
error is `{"ok":false,"code":...,"error":...}` with the code stable and the text
display-only.

<a id="429e934f-0012"></a>

## Pool-wide view

Applies to: `internal/httpsrv/poolindex.go`, `internal/httpsrv/httpsrv.go`

The list and search span the whole pool. This host's rows come from its own
index, which includes in-flight and buffered stashes that have no sidecar yet;
other hosts' rows come from their sidecars on the share. The merge key is
`(hostId, yyyy, mm, dd, id)`. Scanning every sidecar per request is too slow and
holding all of history grows without bound, so the pool index keeps a bounded
window in memory (default 30 days), refreshed by a periodic rescan (default 60
seconds) and by `POST /api/refresh`, and updated directly by this daemon's own
writes. A query reaching before the window scans the relevant day folders for
that request only; a permalink reads its one artifact and sidecar. The pool
index is a cache: a removed sidecar drops out on the next rescan.

<a id="429e934f-0013"></a>

## Host attribution and links

Applies to: `internal/httpsrv/httpsrv.go`

Every row names its host by the GUID-formatted `hostId` and host type, never a
host name, matching the pool dashboard's host-name-free posture; the local host
is marked. To link a remote stash to the UI of the host that owns it, the daemon
asks the pool aggregator for that host's advertised stash URL rather than store
addresses in metadata, where they would go stale. The lookup is best effort:
with no aggregator, or one that does not know the host, the row shows the
`hostId` alone.

<a id="429e934f-0014"></a>

## Listing and permalinks

Applies to: `internal/httpsrv/handlers.go`, `internal/httpsrv/poolindex.go`

The home page lists the pool newest first (`createdAt` descending), 50 rows a
page, at most 500 per answer. IDs are unique only per day per host, so a
permalink carries both: `/s/<hostId>/<yyyy>/<mm>/<dd>/<id>`. For the local host
`/s/<yyyy>/<mm>/<dd>/<id>` is a short alias, and a bare `/<id>` redirects to the
canonical form (local index first, then the newest pool match in the window).

<a id="429e934f-0015"></a>

## Stashes created in the browser

Applies to: `internal/sshsrv/ingest.go`

The create page takes pasted text or files, through the same pipeline as SCP.
Pasted text is stored as UTF-8; a title with a usable extension drives the naming
rules, and an untitled paste is recorded as `paste-<id>.txt`. One file is one
artifact; several are grouped into one archive, as the legacy multi-file upload
is. The record's `username` is the author field or `web`, `pathMetadata` is
empty, `clientAddress` is the browser's address and `source` is `ui`. On success
the page shows the new ID and permalink, the browser's counterpart of the
`YURUNA-STASH-ID:` line.

<a id="429e934f-0016"></a>

## Content type detection

Applies to: `internal/detect/detect.go`, `internal/detect/detect_magika.go`,
`internal/httpsrv/handlers.go`, `internal/sshsrv/sshsrv.go`, `internal/meta/meta.go`

The type is detected on the daemon from the artifact's leading bytes -- with
magika where the build includes it -- once, at upload or flush, and stored in the
record and the sidecar: `mimeType`, `contentClass` (`text`, `image`, `pdf`,
`audio`, `video`, `archive`, `other`), `isText`, and magika's `typeLabel` and
`typeScore`. The bytes decide, never the origin or the extension, so SCP and
browser stashes classify alike and the browser downloads no model. A service
archive is `archive` without detection; a failed or low-confidence detection is
`other`, download-only. A record that predates these fields is classified on
first view: for this host's own stash the result is written back to its record
and sidecar, while another host's stash is only computed for display, because a
host writes only its own metadata.

<a id="429e934f-0017"></a>

## Serving stash bytes

Applies to: `internal/httpsrv/handlers.go`, `internal/detect/detect.go`,
`internal/detect/detect_magika.go`

Stash bytes are served only by the raw and download routes, never interpolated
into a page. The inline content type comes from the stored type, not the URL:
an image, PDF, audio or video stash keeps its stored MIME type only when that
type maps back to the same class (a peer-written sidecar could claim
`{class:image, mime:text/html}`) and is served as `application/octet-stream`
otherwise; text, archive and other stashes are served as
`text/plain; charset=utf-8`. With `X-Content-Type-Options: nosniff` and a
restrictive Content-Security-Policy, an HTML or SVG stash can never run in the
operator's browser, even when opened directly; such types are download-only.
The pages build their DOM from data, never from stash content as markup.

<a id="429e934f-0018"></a>

## Deleting stashes

Applies to: `internal/httpsrv/handlers.go`, `internal/httpsrv/delete.go`, `internal/sshsrv/ingest.go`

Delete is the one destructive verb, and it is behind the lab gate: an unlocked
session, opened with the dashboard's lab code or with the proof the dashboard's
link carries, both checked by the pool aggregator (the daemon holds no
credential of its own). A stash this host received is removed through
its own index -- artifact (on the share or still in the buffer), sidecar and
row -- serialized against the flush worker so a record never moves under the
delete. A stash another host received is removed directly on the share, sidecar
first so a failure between the two unlinks leaves an invisible file rather than
a listed stash with no bytes; the owner's index drops its row on its own next
reconcile, and this daemon evicts it from its pool cache at once. A bulk delete
(`POST /api/stashes/delete`, up to one page of 500) answers one verdict per
stash, so one refusal cannot hide the rest. Delete does not reserve the ID,
which may recur on a later day.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Back to [Yuruna](../README.md)
