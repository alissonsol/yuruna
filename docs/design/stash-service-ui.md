# Yuruna Stash Service — UI Specification

> Companion to [stash-service.md](stash-service.md). That document
> specifies the file-receiving daemon (SCP/SFTP sink, storage layout,
> metadata, ID generation). This document specifies the **browser UI**
> for creating, browsing, viewing, and deleting stashes. Section numbers
> prefixed `SS§` refer to the stash-service spec; bare `§` refers to this
> document.

## 1. Purpose and Overview

The Stash UI is a pastebin-style web front-end for the stash service. It
lets an operator:

- **Create** a stash by pasting text into a field or uploading a file
  (§5).
- **Retrieve** a stash by searching or browsing a list of recent
  stashes (§4).
- **View** a stash inline when its type is renderable, and **download**
  it always (§6, §7).
- **Delete** a stash (§8).

The defining invariant: **a stash is a stash regardless of origin.** A
stash created by pasting text into the UI and a stash created by `scp`
(SS§5) are the same kind of object — same ID format (SS§7), same storage
layout (SS§6), same metadata record (SS§8.1), same sidecar (SS§8.5). The
UI create path routes through the **same daemon storage pipeline** as the
SCP path; it is not a separate store.

The UI runs **inside the stash VM**, served by the stash daemon itself.
The Yuruna repository is already cloned into the VM during bring-up
(SS§3.1), which provides the UI assets alongside the daemon source.

## 2. Hosting and Process Model

### 2.1 Served by the daemon over HTTP

The UI is served by an **HTTP listener added to the existing Go stash
daemon** — the same process that hosts the SSH/SCP sink (SS§4.1). No
separate UI process or systemd unit is introduced; the daemon gains a
second listener. This keeps the create path in-process with the SCP
path, so both share one ID allocator (SS§5.6), one storage pipeline
(SS§8.2), and one local index.

- **Listening port:** TCP **80** by default, configurable. Distinct from
  the SSH sink on :22 (SS§4.2).
- **Bind interface:** `0.0.0.0` (all interfaces), matching the sink.
- **Process management:** part of the existing `stash-server` systemd
  unit (SS§4.6); the HTTP listener starts and stops with the daemon and
  is ordered `After=` the cifs mount, since reads resolve artifacts
  through the share.

### 2.2 Open access posture

Consistent with the trusted-network posture of SS§11, the UI is
**unauthenticated**: no login, no credentials. Anyone who can reach the
VM on the HTTP port can browse, create, and delete. This is the same
trade-off the SCP sink already accepts (SS§4.3 "none" auth). Network
ACLs, rate limiting, and hardening remain out of scope (SS§11), as does
CSRF protection — there is no authenticated session to forge.

The one defense that **is** in scope is output safety: untrusted stash
bytes are never executed in the operator's browser (§7.4).

### 2.3 Front-end stack

Vanilla HTML/CSS/JS served as static assets by the daemon, plus a JSON
REST API (§9). No SPA framework. The pages **reuse the status-pages
front-end baseline** for visual and behavioral consistency:

- Color tokens, dark-mode, and mobile rules from the shared
  `yuruna.common.css` conventions (see the *Status pages (UI)* section of
  [definition.md](../definition.md)).
- Helpers from `yuruna.common.js` where practical — notably
  `Yuruna.startVisibilityAwarePolling` for the auto-refreshing recent
  list (don't burn battery on a backgrounded tab).

Because the daemon lives in a different VM than the host status server
(which is a PowerShell `HttpListener`, [test/Start-StatusService.ps1](../../test/Start-StatusService.ps1)),
the assets are **copied/vendored** into the daemon's served tree, not
fetched live from the host. Treat `yuruna.common.{css,js}` as a shared
look-and-feel source, not a runtime dependency on the host.

## 3. Scope: Pool-wide Aggregation

The UI presents stashes **across the whole pool**, not just the local
host's. StashFolders are namespaced per `hostId` (SS§6.1), and each
daemon owns its own VM-local index (SS§8), so a pool-wide view requires
reading beyond the local index.

### 3.1 Two data sources, merged

1. **Local index (fast, authoritative for this host).** The daemon's
   own VM-local SQLite index (SS§8) covers stashes created on this host,
   including in-flight (`pending`/`partial`) and `locallyBuffered` ones
   that have no sidecar yet (SS§8.4).
2. **On-share sidecars (durable, cross-host).** Every committed artifact
   on the share carries a `<id>.yuruna.meta.json` sidecar (SS§8.5)
   holding the full SS§8.1 field set. Scanning `…/stash/*/files/**` across
   **all** `hostId` folders yields every committed stash in the pool.

The UI merges the two: the local host contributes from its live index
(so just-uploaded and not-yet-flushed stashes appear immediately);
**other** hosts contribute from their sidecars. The merge key is
`(hostId, yyyy, mm, dd, id)` — unique pool-wide (SS§7 guarantees
per-day-per-host uniqueness).

### 3.2 Pool index cache (bounded window + on-demand deep scan)

Scanning every sidecar across the share on every request is too slow,
and holding the **entire** pool history in memory grows unbounded as the
pool ages. The daemon therefore keeps a **bounded** in-memory pool
index plus an on-demand path for older data:

- **Recent window in memory.** The pool index holds sidecars from the
  last `poolIndexWindowDays` (default 30, §11), built by a startup scan
  of that window across all `hostId` folders and refreshed by a periodic
  rescan (default 60 s) plus explicit refresh (§9). The daemon's own
  writes update it directly. This drives the recent list (§4.1) and the
  common case of search.
- **On-demand deep scan.** A query whose date range (§4.2) reaches
  before the in-memory window triggers a bounded scan of the relevant
  `yyyy/mm/dd` folders on the share for that request only — older data
  stays reachable without being permanently resident. A direct permalink
  (§4.4) always resolves by reading the one artifact + sidecar, no scan.

The pool index is a cache, not a source of truth — the share sidecars
and each host's local index remain authoritative. A stale pool index
self-heals on the next rescan; a removed sidecar (e.g. a remote delete,
§8.3) drops out of the cache on rescan. This deliberately overlaps the
planned pool harness ([opportunities-hostpool.md](../opportunities-hostpool.md));
the host-resolution piece already reuses the pool-aggregator (§3.4), and
if a fuller pool index service later lands this scan can read against it.

### 3.3 Host attribution

Every list row and the detail view show which **host** a stash belongs
to. To stay consistent with the pool dashboard's deliberately
**hostname-free** posture (see [pool-aggregator](../../test/extension/pool-aggregator/README.md)),
the label is the **GUID-formatted `hostId`** plus the host's `hostType`
— never a hostname. Search can filter by host (§4.2). The local host is
visually distinguished (it owns the live, unflushed records). Turning a
`hostId` into a reachable link is §3.4.

### 3.4 Resolving a hostId to a reachable host (pool-aggregator)

A stash's `hostId` is the owning host's stable `runtime/host.uuid`
(SS§6.1) — an opaque UUID, not an address. The UI needs to turn it into
a reachable URL for one thing: the remote-host deep-link in §8.3. Rather
than store addresses in stash metadata (which would go stale and would
re-introduce host identity into the durable record), the UI **reuses the
existing pool-aggregator** that already maintains a live, DHCP-resilient
`hostId → current IP` mapping for the *Yuruna hosts* dashboard.

- The pool-aggregator runs on the caching-proxy
  ([pool-aggregator](../../test/extension/pool-aggregator/README.md)),
  serving a read-only, unauthenticated, hostname-free
  `GET /api/v1/pool-status` snapshot keyed by `hostId` (and already
  resolves a host's *current* IP internally for its `/go/cycle`
  redirect). The stash UI queries it to resolve the owning host.
- **What the link must point at.** The aggregator today resolves a
  `hostId` to that host's **status server** (`:8080`). The stash
  remote-delete link instead needs that host's **stash-VM UI**. The
  small addition (folded back as an amendment, §13): the host advertises
  its stash-VM base URL (the host created the stash VM and knows its
  guest address) via its status server, so the aggregator carries it in
  the per-host record and the stash UI reads `hostId → stashBaseUrl`
  from the same `/api/v1/pool-status` call. The aggregator stays the
  single resolver; the stash service adds no address store of its own.
- **Best-effort, not a hard dependency.** The aggregator URL is
  configuration (§11). If it is unset, unreachable, or has not yet
  discovered the owning host (its discovery is proxy-traffic-driven), the
  UI degrades to showing the plain `hostId` label (§3.3) with **no**
  link — the operator finds the host themselves. This keeps the only
  hard dependency the same as the daemon's (its isolated stash storage,
  `networkStorage.stash*`, SS§2).
- Calls use the aggregator's TLS posture (HTTPS on `:9400` with the
  pool-CA leaf when present; pin via the published pool CA).

## 4. Browsing and Retrieval

### 4.1 Recent stashes list (home page)

The landing page is a reverse-chronological list of recent stashes
across the pool (§3), pastebin-style. Each row shows:

| Column | Source |
|---|---|
| Type icon | `contentClass` (§6) — text / image / pdf / audio / video / archive / other |
| ID | `id` (SS§8.1) |
| Name | `originalFilename` (SS§8.1) |
| Host | `hostId` + `hostType`, hostname-free (§3.3); links via §3.4 |
| User | `username` |
| Size | `sizeBytes`, human-readable |
| Created | `createdAt` (UTC; rendered in viewer locale with a UTC tooltip) |
| Status | `pending` / `complete` / `partial` / `truncated` badge |

- **Click** a row → the stash detail view (§6) at its permalink (§4.4).
- **Default page size** 50, with pagination or infinite scroll. The
  server caps a single response (§9) so a huge pool cannot return
  unbounded JSON.
- **Live refresh** via visibility-aware polling (§2.3): new stashes
  appear without a manual reload, and the poll freezes on a backgrounded
  tab.
- `pending` / `partial` rows are listed but show a "still receiving / no
  preview" state in detail (§6.4). `locallyBuffered` rows are listed
  from the local host only (no sidecar yet).

### 4.2 Search and filter

Search maps directly onto the lookups the store already supports
(SS§8.3), plus type and host facets:

- `id` — exact.
- `username` — exact and substring.
- `originalFilename` — substring.
- `pathMetadata` — substring (the SCP destination path, SS§5.1).
- `createdAt` / `receivedAt` — date range (UTC).
- `contentClass` / `mimeType` — facet (text, image, pdf, audio, video,
  archive, other).
- `hostId` — facet (this host / any specific host / all).
- `status` — facet.

Queries run against the merged pool view (§3). Substring search on
remote-host stashes is served from the cached sidecar fields (§3.2); a
query whose date range predates the in-memory window triggers the
on-demand deep scan (§3.2) for that request.

### 4.3 Archive contents (read-only listing)

For an archive artifact (`<id>.yuruna.archive.zip`, from a multi-file or
recursive upload — SS§5.3/§5.4, or a UI multi-file upload §5.2), the
detail view lists the ZIP entries (name, size) read from the central
directory. Individual entries are **not** separately downloadable in
this version; the download button fetches the whole archive (§7.5).

### 4.4 Permalinks / URL scheme

IDs are unique only per-day-per-host (SS§7), so a permalink must carry
host and date:

```
/s/<hostId>/<yyyy>/<mm>/<dd>/<id>
```

For the local host a short alias `/s/<yyyy>/<mm>/<dd>/<id>` resolves to
the same stash. The permalink is shown on the detail view for copy/share
(it only works inside the trusted network, like the rest of the
service).

**Short URL.** Because a stash server's whole point is a memorable link,
a bare ID resolves too: `/<id>` (and the explicit `/v/<id>` alias)
302-redirect to the canonical `/s/...` above. Resolution is local-index
first (authoritative, unique by ID), then the newest in-window pool match;
an unknown or non-ID path 404s, and the literal routes (`/new`, `/healthz`,
`/assets/`, `/s/`, root) take precedence over the `/{id}` catch-all. The
detail view shows the short link for a locally-owned stash.

## 5. Creating a Stash

The create page offers two inputs that both flow through the **same
daemon storage pipeline** as SCP (SS§8.2), so the result is
indistinguishable from an SCP-created stash.

### 5.1 Paste text

A large textarea (the primary, pastebin-style input) plus optional
fields:

- **Title / filename** (optional). If given and it contains a usable
  extension, the SS§6.3 extension-derivation rules apply to the stored
  artifact. If omitted, the artifact is named `<id>` and
  `originalFilename` defaults to `paste-<id>.txt`.
- The pasted text is encoded **UTF-8** and stored as the artifact bytes.

### 5.2 Upload file(s)

A file picker / drag-and-drop accepting one or more files:

- **Single file** → one artifact, mirroring SS§5.2. Extension derived
  per SS§6.3.
- **Multiple files** → archived into one `<id>.yuruna.archive.zip`,
  mirroring the legacy multi-file grouping (SS§5.3). One ID, one record.
- The **100 MB per-file size limit** (SS§5.5) applies identically;
  oversize content is truncated and the record flagged
  `status = truncated`.

### 5.3 Record fields for UI-created stashes

The create handler populates the same SS§8.1 record, with UI-appropriate
defaults:

| Field | UI value |
|---|---|
| `username` | Operator-supplied "author" field if present, else `web` |
| `pathMetadata` | Empty (there is no SCP destination path) |
| `clientAddress` | Source IP of the browser request |
| `originalFilename` | Title/filename field, or `paste-<id>.txt` for untitled paste |
| `source` | `ui` (new field, §10) — distinguishes from `scp` |
| `isArchive`, `sizeBytes`, `status`, timestamps | Same semantics as SS§8.1/§8.2 |

UI-created stashes are written to the **local host's** StashFolder (the
daemon serving the page owns that host's storage), get a sidecar
(SS§8.5), and are buffered locally then flushed if the share is offline
(SS§8.4) — identical to the SCP path.

### 5.4 Post-create

On success the UI redirects to the new stash's detail view (§6) and
surfaces its ID and permalink, the UI analogue of the
`YURUNA-STASH-ID:` line SCP clients see (SS§9).

## 6. Viewing a Stash

The detail view renders the artifact according to its detected type
(§6.1) and always offers a download (§7.5).

### 6.1 File-type detection (server-side, magika)

Type detection runs **on the daemon, at upload time** (and at flush for
buffered artifacts, SS§8.4; and during index rebuild-from-sidecars after
a reimage when only a sidecar exists, SS§8.5). The result is stored in
metadata and the
sidecar (§10), so:

- detection runs **once** per artifact, not per view (the one exception
  is an older remote sidecar with no stored type — §10);
- **SCP-created and UI-created stashes are classified identically** (the
  classifier sees bytes, not origin); and
- the browser needs no model download and the UI just reads the stored
  type.

Detection uses **[magika](https://github.com/google/magika)** (Google's
content-type detector) on the artifact's leading bytes, via its official
**Go binding** ([github.com/google/magika/go/magika](https://github.com/google/magika/tree/main/go)) —
so detection stays in-process with the Go daemon, no Python sidecar.
Usage is `scanner := magika.NewScanner(assetsDir, modelName)` once at
startup, then `scanner.Scan(reader, size)` per artifact. The binding
depends on **ONNX Runtime** (via cgo's C API) and a **model assets**
directory (e.g. `standard_v3_3`); both the ONNX Runtime shared library
and the model assets are vendored into the VM during bring-up so
detection has no network dependency at runtime. (cgo + the native
ONNX Runtime library are a build/packaging consideration for the daemon
image.) Detection derives, and the record stores (§10):

- `mimeType` — best-guess MIME type.
- `contentClass` — coarse bucket the UI switches on: `text`, `image`,
  `pdf`, `audio`, `video`, `archive`, `other`.
- `isText` — boolean convenience flag.
- `typeLabel`, `typeScore` — magika's label and confidence (optional,
  for display/diagnostics).

Archives produced by the service (`.yuruna.archive.zip`) are classified
`archive` directly without running magika. When detection fails or is
low-confidence, the artifact falls back to `contentClass = other`
(download-only, §7.5) — the stored extension (SS§6.3) is a secondary
hint, never authoritative.

### 6.2 Text rendering

When `isText`, the content is shown in a read-only text field /
`<pre>` block:

- UTF-8 decoded; rendered as **plain text** (no HTML interpretation).
- **Inline size cap** (default 1 MB, constant §11): larger text shows a
  truncated preview with a clear "truncated — download for full content"
  notice. The download (§7.5) always serves the complete artifact.
- Syntax highlighting is **not** in this version (out of scope, §12).
  Monospace, soft-wrap toggle.

### 6.3 Viewable (non-text) rendering

For browser-renderable binary types, the artifact is embedded so the
browser displays it natively, in the most compatible way:

- **image** (`png`, `jpeg`, `gif`, `webp`, `bmp`) → `<img>`.
- **pdf** → `<embed>`/`<object>` (browser-native PDF viewer), with
  download fallback.
- **audio** → `<audio controls>`; **video** → `<video controls>`.

All of these load the bytes from the **raw/download endpoint** (§7.5),
which sets the correct `Content-Type` and a safety CSP (§7.4) — the bytes
are never inlined into the page's own HTML.

### 6.4 Non-renderable, incomplete, and archive states

- `contentClass = other` → no inline preview; download button only.
- `archive` → ZIP entry listing (§4.3) + download.
- `status = pending` → "still receiving"; `partial` → "incomplete
  upload" with whatever bytes exist available for download; `truncated`
  → preview/download of the 100 MB-capped artifact with a truncation
  notice.

## 7. Serving Artifact Bytes Safely

### 7.1 Raw / download endpoint

Artifact bytes are served only from a dedicated endpoint (§9), never
interpolated into a page. It resolves the artifact through the mounted
share (or, for the local host's not-yet-flushed records, the VM-local
buffer, SS§8.4).

### 7.2 Inline vs. attachment

A `disposition=inline` variant (for `<img>`/`<embed>`/`<audio>`/`<video>`/
text fetch) sets the detected `Content-Type`; the download variant
(§7.5) sets `Content-Disposition: attachment` with the
`originalFilename`.

### 7.3 Correct content type

The endpoint sets `Content-Type` from the stored `mimeType` (§6.1), not
from the URL extension, so the browser renders predictably.

### 7.4 XSS / active-content safety

Untrusted stash bytes must never execute in the operator's browser:

- **SVG and HTML/XHTML are download-only.** They are never rendered
  inline as a document and never injected as `innerHTML`. (If inline SVG
  preview is ever wanted, it must go through a sandboxed `<iframe
  sandbox>` with a restrictive CSP — not in this version.)
- The raw endpoint sends a restrictive `Content-Security-Policy` and
  `X-Content-Type-Options: nosniff`, and serves text/unknown types as
  `text/plain` so a `.html` stash cannot be navigated-to and executed.
- The app's own pages build the DOM via `textContent`/safe DOM APIs;
  stash content is treated strictly as data.

### 7.5 Download is always available

Every stash — any type, any status, any host — has a working **Download**
button serving the complete stored artifact as an attachment, including
`other`-class and archive artifacts.

## 8. Deleting a Stash

The UI supports **hard delete behind a confirmation**, but **only for
stashes owned by the local host**. Deletion of a stash owned by another
host is disabled in the UI and points the operator at that host's own
UI (§8.3). This is a new mutation path that amends the "no
retention/cleanup" stance of SS§12 (§13).

### 8.1 Local-host-only delete

A host may delete only the stashes it owns — those in its own `hostId`
StashFolder, served from its own local index. Rationale:

- It is a clean ownership boundary: a host mutates only its own storage,
  never reaches across `hostId` namespaces to mutate another host's
  artifacts or index.
- It keeps the story **consistent with future per-host
  authentication/authorization**: when auth lands, "you may act on this
  host's stashes" is already the boundary the UI enforces, so adding
  credentials does not change the model — only who is allowed through it.
- It sidesteps cross-host index drift entirely: a delete only ever
  touches the local index, which is authoritative for the local host
  (§3.1), so there is no remote index to reconcile.

### 8.2 Delete semantics (local host)

For a target `(hostId, date, id)` owned by the **local** host, a
confirmed delete removes:

1. the **artifact** on the share (or VM-local buffer if still buffered,
   SS§8.4),
2. its **sidecar** `<id>.yuruna.meta.json` on the share (SS§8.5), and
3. the **index row** in the local SQLite index,

and evicts the entry from the pool-index cache (§3.2). Because the ID is
per-day-per-host (SS§7), it can recur on a later date — delete does not
reserve or tombstone the ID.

Delete requires an explicit in-UI confirmation showing the stash's ID,
name, host, and size before the request is sent. There is no bulk delete
in this version.

### 8.3 Remote-host stashes are read-only here

When the viewed stash is owned by **another** host (§3.3), the Delete
control is **disabled** and labeled with where to go instead — the
owning `hostId`, and a link to that host's stash UI when the
pool-aggregator can resolve it (§3.4): `<stashBaseUrl>/s/<hostId>/<yyyy>/<mm>/<dd>/<id>`.
When resolution is unavailable, the label shows the `hostId` alone. The
operator deletes it from that host's own UI, where it is a local stash.

The server enforces this too, not just the UI: a `DELETE` (§9) whose
`hostId` is not the serving host's own returns **403** with an error
naming the owning host. This makes the ownership boundary a real
contract (and the natural seam for per-host auth later), not just a
greyed-out button.

> Implementation note — the remote stash still **appears** in this
> host's pool view (§3) because the pool view is sidecar-driven for
> remote hosts; a remote delete (performed on the owning host) removes
> the sidecar, and this host drops it from the list on its next pool-
> index rescan (§3.2). No cross-host index reconciliation is needed,
> since no host ever deletes another host's index row.

## 9. HTTP API

JSON REST endpoints consumed by the front-end. All responses are
`no-store`. Errors return `{"ok":false,"error":"…"}` with an
appropriate status code, mirroring the status-server convention.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/stashes` | List/search the merged pool view (§4). Query params: `q`/`id`/`username`/`filename`/`path`/`from`/`to`/`class`/`mime`/`host`/`status`/`limit`/`offset`. Returns rows + paging. Server caps `limit`. |
| `GET` | `/api/stashes/{hostId}/{yyyy}/{mm}/{dd}/{id}` | One stash's metadata (SS§8.1 + §10 fields). |
| `GET` | `/api/stashes/{…}/{id}/archive` | ZIP entry listing for an archive (§4.3). |
| `GET` | `/raw/{hostId}/{yyyy}/{mm}/{dd}/{id}` | Artifact bytes, inline (`Content-Type` from `mimeType`, safety headers §7.4). |
| `GET` | `/download/{hostId}/{yyyy}/{mm}/{dd}/{id}` | Artifact bytes as attachment (`Content-Disposition`, `originalFilename`). |
| `POST` | `/api/stashes` | Create from paste or upload (§5). `multipart/form-data` (files + optional title/author) or a JSON paste body. Returns the new stash's id/permalink. |
| `DELETE` | `/api/stashes/{hostId}/{yyyy}/{mm}/{dd}/{id}` | Hard delete (§8). **Local host only** — returns `403` (naming the owning host) when `{hostId}` is not the serving host's own. |
| `POST` | `/api/refresh` | Force a pool-index rescan (§3.2). |

The static UI pages (`/`, `/new`, `/s/…`) are served from the daemon's
vendored asset tree (§2.3).

## 10. Metadata Additions

The UI requires fields beyond the SS§8.1 set. These are added to the
metadata record **and** the sidecar (SS§8.5), so they are durable and
survive reindex, and so a stash classified on one host renders the same
when viewed from another (§3):

| Field | Description |
|---|---|
| `mimeType` | Detected MIME type (§6.1) |
| `contentClass` | `text` / `image` / `pdf` / `audio` / `video` / `archive` / `other` |
| `isText` | Boolean convenience flag |
| `typeLabel` | magika label (optional, display/diagnostics) |
| `typeScore` | magika confidence 0–1 (optional) |
| `source` | `scp` or `ui` — how the stash was created (§5.3) |

These are populated at upload/flush time (§6.1). When the index is
rebuilt from sidecars (SS§8.5), they come straight from the sidecar. A
pre-existing sidecar that lacks them (an older artifact) is handled per
ownership (honoring the §8.1 boundary that a host never mutates another
host's storage):

- **Owned by the local host:** detection runs once on first access and
  the host backfills its **own** sidecar, so subsequent views are cheap.
- **Owned by a remote host:** the viewing host runs detection
  **on-the-fly** to render, but **never writes** the remote sidecar. The
  owning host backfills it on its own next access/reindex. Until then,
  each remote view re-detects (cheap relative to a cross-host write, and
  it preserves the ownership boundary).

## 11. Configuration and Constants

**Configurable** (defaults shown):

| Setting | Default | Where |
|---|---|---|
| UI HTTP port | `80` | VM-side service config |
| Pool-index rescan interval | `60 s` | VM-side service config |
| Pool-index in-memory window | `30 days` (`poolIndexWindowDays`) | VM-side service config |
| Recent-list default page size | `50` | VM-side service config |
| Inline text preview cap | `1 MB` | VM-side service config |
| Pool-aggregator base URL | unset (host resolution disabled, §3.4) | VM-side service config |

**Constants in code:**

| Setting | Value |
|---|---|
| UI bind interface | `0.0.0.0` |
| Permalink scheme | `/s/<hostId>/<yyyy>/<mm>/<dd>/<id>` (+ local short alias) |
| Max API `limit` per response | bounded (e.g. 500) |
| Active-content types | SVG, HTML/XHTML → download-only (§7.4) |

Inherited from the daemon spec: per-file 100 MB cap, ID format/length,
extension rules, UTC dates (SS§5.5, SS§6.3, SS§7, SS§10).

## 12. Out of Scope (this version)

- Authentication / authorization for the UI (open posture, §2.2,
  matching SS§11).
- Syntax highlighting, diffing, or editing of stash content (a stash is
  immutable once created; there is no "edit" — create a new one).
- Per-entry extraction or preview of files **inside** an archive (entry
  listing only, §4.3).
- Inline rendering of SVG/HTML (download-only, §7.4).
- Bulk delete, retention/expiry policies, and aging (single confirmed
  delete only; SS§12's no-aging stance otherwise stands).
- A standalone cross-host **stash-index** aggregator service — the pool
  *listing/search* scans sidecars directly (§3.2); replacing that with a
  dedicated stash index is future work
  ([opportunities-hostpool.md](../opportunities-hostpool.md)). (Host
  *address* resolution does already reuse the existing pool-aggregator,
  §3.4 — that is the only aggregator dependency, and it is best-effort.)

## 13. Amendments to stash-service.md

This UI introduces changes the daemon spec lists as out of scope or
unspecified. When the daemon is built, fold these in:

- **SS§4.2 / SS§4.6** — the daemon gains an **HTTP listener** (default
  :80) in addition to the SSH sink on :22, in the same process and
  systemd unit (§2.1).
- **SS§8.1 / SS§8.5** — the metadata record and sidecar gain the §10
  fields (`mimeType`, `contentClass`, `isText`, `typeLabel`,
  `typeScore`, `source`).
- **SS§8.2 / SS§8.5** — delete is **local-host-only** (§8.1): a host
  removes the artifact + sidecar + local index row for its own stashes
  only, so no cross-host index reconciliation is introduced. The
  existing rebuild-from-sidecars behavior (SS§8.5) is unchanged. The
  `DELETE` endpoint enforces the ownership boundary server-side (403 on
  a foreign `hostId`, §8.3), which is also the seam for any future
  per-host auth.
- **SS§12** — "The UI for browsing and searching received files" moves
  from out-of-scope to specified here; **UI-initiated hard delete** (§8)
  is carved out of the "no retention/cleanup" item, while automated
  aging/retention remains out of scope.

Beyond stash-service.md, the host-resolution piece (§3.4) touches two
adjacent components:

- **Host status server** — advertises this host's **stash-VM base URL**
  (the host knows its stash VM's guest address from `Start-StashServer`)
  so the pool-aggregator can carry it.
- **pool-aggregator** ([README](../../test/extension/pool-aggregator/README.md)) —
  its per-host record / `/api/v1/pool-status` snapshot gains the host's
  `stashBaseUrl`, so a `hostId` resolves to a reachable stash UI, not
  only the host's status server. Stays read-only, unauthenticated, and
  hostname-free.

## 14. Resolved Decisions

- **Type detection (§6.1):** server-side, at upload, via magika; result
  stored in metadata + sidecar so SCP- and UI-created stashes classify
  identically and the browser needs no model.
- **UI hosting (§2):** an HTTP listener in the existing Go daemon, open
  (no auth), matching the trusted-network posture.
- **Delete (§8):** hard delete (artifact + sidecar + index row) behind a
  confirmation, **local host only**; remote-host stashes show a disabled
  Delete pointing at the owning host, and the endpoint enforces the
  boundary server-side (403) — consistent with future per-host auth.
- **UI create (§5):** paste text **and** file upload, both through the
  same storage pipeline as SCP.
- **Scope (§3):** pool-wide — the UI aggregates this host's live index
  with all hosts' on-share sidecars, bounded to a recent in-memory
  window (default 30 days) with an on-demand deep scan for older queries.
- **Host resolution (§3.4):** reuse the pool-aggregator's existing
  `hostId → current IP` resolution (extended to carry the host's
  stash-VM base URL) rather than storing addresses in stash metadata;
  best-effort, hostname-free labels, no new hard dependency.
- **Type backfill (§10):** a host backfills only its **own** older
  sidecars; viewing a remote host's typeless sidecar detects on-the-fly
  without writing it (honors the §8.1 ownership boundary).
- **Render safety (§7.4):** sandboxed; images/PDF/audio/video/text
  render inline, SVG/HTML are download-only, bytes are never executed.
- **Front-end (§2.3):** vanilla HTML/JS/CSS served by the daemon,
  reusing the `yuruna.common` look-and-feel + a JSON REST API.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.16

Back to [Yuruna](../../README.md)
