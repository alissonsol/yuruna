# stash service -- Go daemon (`stash-service`)

A single static binary with TWO listeners:

- **TCP/22** -- the SCP/SFTP sink. Accepts any SSH authentication (section 4.3
  pass-through) and stores every upload as a content artifact (plus an
  on-share `.yuruna.meta.json` sidecar and a VM-local SQLite index row,
  section 6, section 8). Serves BOTH the legacy SCP sink-mode wire protocol (section 5) and the
  SFTP subsystem (modern scp's default, section 4.1).
- **TCP/80** -- the browser **UI + JSON API**
  (docs/stash-guide.md): pool-wide
  browse/search, create (paste or upload), inline viewing, and gated
  delete. Same process, so create flows through the same storage
  pipeline as SCP (a stash is a stash).

## Layout

```
server/
+-- go.mod / go.sum                       # module stash-service (go.sum committed)
+-- main.go                               # flags, signals, listener loop, sidecar rebuild
+-- internal/
|   +-- config/config.go                  # spec section 10 constants in one place
|   +-- fsutil/fsutil.go                  # crash-durability primitives (SyncDir, AtomicCommit) shared by store + meta
|   +-- id/id.go                          # 4-char allocator, scans share+buffer, checks the index (section 7)
|   +-- store/store.go                    # share/buffer layout, extension extraction, mount probe (section 6.3, section 8.4, section 13)
|   +-- meta/meta.go                      # VM-local SQLite index + sidecars + rebuild (section 8, section 8.5)
|   +-- scp/scp.go                        # legacy SCP sink-mode wire protocol (section 5)
|   +-- sshsrv/{sshsrv,sftp,flush}.go     # crypto/ssh server, SFTP backend, NAS-offline flush (section 4, section 4.1, section 8.4)
|   +-- sshsrv/ingest.go                  # UI-facing ingest (paste/upload) + local delete (ui section 5, section 8)
|   +-- detect/                           # content-type detection: pure-Go heuristic + magika build-tag adapter (ui section 6.1)
|   +-- yex/                              # mirrored extension SDK: beacon (section 4.7), labgate, pool
|   +-- httpsrv/                          # UI/API HTTP server, pool-wide index, host resolution, embedded web/ (ui section 2-section 9)
|       +-- gate.go                       # the lab-token gate in front of DELETE
|       +-- delete.go                     # one stash or a selection, on any host in the pool
|       +-- reconcile.go                  # drops index rows whose share files are gone
+-- *_test.go                             # unit tests for the pure-logic bits
```

`ui` section references above are docs/stash-guide.md.

## Build

Pure Go (the SQLite driver is [`modernc.org/sqlite`](https://pkg.go.dev/modernc.org/sqlite),
not the CGo one), so the build needs only `golang-go`. `go.sum` is
committed, so do NOT run `go mod tidy` (it needs the network to recompute
the graph); `go build` verifies against `go.sum` and fetches modules
through the caching-proxy-service:

```bash
sudo apt-get install -y golang-go libcap2-bin
cd ~/yuruna/test/extension/stash-service/server
go build -o stash-service .
sudo install -m 0755 stash-service /usr/local/bin/stash-service
```

### Magika detection backend (optional build)

Content-type detection (`internal/detect`) defaults to a pure-Go heuristic
(extension + content sniff + UTF-8 text check) -- no cgo, no model, always
built and tested. The richer **magika** backend
([google/magika](https://github.com/google/magika/tree/main/go)) is built only with `-tags magika`,
so plain `go build` / `go test` stay pure-Go and offline. Enabling it
requires, in the VM image build, all three of:

- the Go binding: `go get github.com/google/magika/go/magika`
- ONNX Runtime: the native shared library (cgo links against it)
- the model assets: e.g. the `standard_v3_3` model directory

```bash
# In the VM image build only, after vendoring ONNX Runtime + the model:
go get github.com/google/magika/go/magika
go build -tags magika -o stash-service .
```

The assets dir and model name are read from the environment so the image
build can point at the vendored copies: `MAGIKA_ASSETS_DIR` (default
`/usr/local/share/magika`) and `MAGIKA_MODEL` (default `standard_v3_3`).
Any construction or scan failure degrades to the pure-Go heuristic, so a
misconfigured model never breaks classification.

The bring-up script honors `STASH_BUILD_TAGS=magika` to opt in.

The production bring-up (`guest/ubuntu.server.26/ubuntu.server.26.stash-service.sh`,
run by the VM's cloud-init) does all of this plus the mount, systemd unit,
and `/var/lib/stash-service` provisioning -- this section is for ad-hoc dev.

## Run (manual / dev)

```bash
# 1. Disable the OS sshd so the custom server can bind :22 (section 4.2).
sudo systemctl disable --now ssh

# 2. Allow non-root binding of port 22 (or run the daemon as root).
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/stash-service

# 3. Launch. --share-folder (the mounted stash share, <stashStorageLocalPath>/stash/<hostId>)
#    is required; the metadata index and offline buffer default to
#    /var/lib/stash-service/{metadata,buffer} on the VM's local disk.
/usr/local/bin/stash-service --share-folder /mnt/ystash-nas/stash/<hostId>
```

Logs go to stderr; journald captures them under the `stash-service.service`
unit the bring-up installs (`journalctl -u stash-service`).

## Exercise

The daemon serves BOTH protocols (see the spec section 4.1):

```bash
# Modern scp defaults to SFTP -- works, one record per file. Stored on
# the share; the upload ID is logged server-side (SFTP can't echo it).
echo hello > note.pdf
scp note.pdf stash-admin@<vm-ip>:/scratch

# Legacy protocol (-O): enables multi/recursive ZIP grouping AND echoes
# the YURUNA-STASH-ID line to your terminal.
scp -O a.txt b.txt stash-admin@<vm-ip>:/scratch    # one .yuruna.archive.zip
scp -O -r ./dir    stash-admin@<vm-ip>:/scratch    # one .yuruna.archive.zip
```

Under `-O` (legacy), scp renders the daemon's stderr, so each invocation
surfaces a line like:

```
YURUNA-STASH-ID: a1b2
```

The artifact is at `<ShareFolder>/files/<yyyy>/<mm>/<dd>/a1b2[.ext]`
(single) or `a1b2.yuruna.archive.zip` (archive), with an `a1b2.yuruna.meta.json`
sidecar next to it. The matching SQLite row is in the VM-local metadata
index (default `/var/lib/stash-service/metadata/stash.sqlite`).

## UI / API (`:80`)

Open `http://<vm-ip>/` for the pastebin-style UI (browse, search, create,
view, delete). The JSON API it consumes:

| Method | Path | Purpose |
|---|---|---|
| GET | `/healthz` | liveness (`ok`) |
| GET | `/api/stashes` | list/search the pool-wide view (`q`,`id`,`username`,`filename`,`path`,`class`,`status`,`host`,`from`,`to`,`sort`,`dir`,`limit`,`offset`) |
| GET | `/api/stashes/{hostId}/{y}/{m}/{d}/{id}` | one stash's metadata |
| GET | `/api/stashes/{...}/{id}/archive` | ZIP entry listing |
| GET | `/raw/{hostId}/{y}/{m}/{d}/{id}` | bytes, inline (safety headers; active content served as text) |
| GET | `/download/{...}` | bytes, attachment |
| POST | `/api/stashes` | create (multipart `files`/`text`/`title`/`author`, urlencoded, or JSON) |
| DELETE | `/api/stashes/{hostId}/{...}` | delete one stash, on any host -- **gated** |
| POST | `/api/stashes/delete` | delete a selection: `{"stashes":[{hostId,year,month,day,id}]}` -> per-stash verdicts -- **gated** |
| GET | `/api/session` | which ways through the delete gate exist, and whether this browser is through one |
| POST | `/api/login` | exchange the dashboard's 6-character Lab token for a session |
| POST | `/api/unlock-proof` | exchange a dashboard control proof for a session |
| POST | `/api/refresh` | force a pool-index rescan |
| GET | `/api/host?host=<id>` | best-effort hostId->stash-UI resolution (pool-aggregator-service) |
| GET | `/api/hostinfo` | host id, version, this daemon's own IPs |
| GET | `/v/{id}` | short URL: 302 to the canonical `/s/{hostId}/{y}/{m}/{d}/{id}` permalink |
| GET | `/{id}` | the same redirect without the prefix, so `http://stash-service/h775` opens the stash. A single-segment wildcard and the catch-all of last resort: every literal route above is more specific and still wins, and a segment that is not an id simply 404s |

Flags (defaults): `--http-addr` (`0.0.0.0:80`, empty disables the UI),
`--pool-window-days` (`30`), `--pool-refresh-secs` (`60`),
`--list-default-limit` (`50`), `--aggregator-url` (empty), `--listen-addr`
(`0.0.0.0:22`, dev override when the OS sshd holds :22), `--host-id` (empty)
and `--presence-interval` (`2m`, `0` disables) for the presence beacon
(section 4.7). It must stay under the aggregator's five-minute extension health
grace: a re-announce is also how a renumbered service reports its new address.

**Delete authorization.** Reads and creates are open on the LAN; `DELETE` needs
a session, unlocked either with the dashboard's rotating Lab token or with the
short-lived control proof the *Extension hosts* link carries in its URL
fragment. This VM holds no internal authentication key, so `--aggregator-url` is what makes
either possible -- without it every delete answers `503`, and the UI says so
instead of offering a button. A delete reaches **any** host's stash, not only
this one's: the share is mounted with write access to all of them.

An aggregator that is configured but **unreachable** is a third state, distinct
from both a good code and a wrong one: `/api/login` answers `503` with reason
`lab-token-unavailable`, never `401`. Sessions already granted are unaffected --
the cookie is verified against a key this process holds, so an unlocked browser
keeps deleting for its 7-day life -- but no new unlock can be made until the
aggregator answers. The signing key is generated per start, so a restart also
ends every session: restarting while the aggregator is down leaves nobody able
to unlock.

Diagnosing a refused delete: `/api/session` is what the UI reads to decide
whether to render the controls, every unlock attempt is logged with its source
address and outcome -- `ok` / `refused` / `unavailable` (`journalctl -u
stash-service | grep unlock`) -- and each delete logs its target and source. The
launch line records the gate once at startup (`grep 'delete authz'`). The bring-up stamps the framework version via
`-ldflags "-X main.version=<v>"` (shown in the UI header); ad-hoc dev builds
show `vdev`.

## Presence beacon (section 4.7)

With `--aggregator-url` + `--host-id` set (the bring-up bakes both from the
host seed), the daemon POSTs `<aggregator>/announce` at startup, every
`--presence-interval`, and (best-effort, `active:false`) at shutdown. This
keeps the pool dashboard's **Extension hosts** row alive **without the owning
host's status service**: the registration path goes dark whenever that server
is down (routinely, after a host reboot), while this VM auto-restarts and
keeps serving. The announce carries only the host's `hostId` + this UI's
port; the aggregator derives the URL from the connection's source address,
so an announcer can only advertise itself. Best-effort throughout -- an
unreachable aggregator never affects stash operation.

The UI is pool-wide: this host's live index merged with every other host's
on-share sidecars (bounded to the recent window in memory, with an
on-demand deep scan for older queries). Delete reaches every host in it:
a peer's stash is unlinked directly on the share, and that host drops the
now-orphaned index row on its own next reconcile pass, so reclaiming disk
never depends on another VM being reachable. The list adds a per-row
Delete plus a checkbox selection driving **Delete selected**, which is one
`POST /api/stashes/delete` for the whole selection (ui section 8.5).

Column sorting is served, not scripted: a header click re-requests the list
with `sort`/`dir` rather than reordering the rows the browser holds. The page
is one window onto a larger merged set, so only the daemon can order the whole
of it -- a browser could only rank the page it was given. Every ordering is
total (ties break on created-then-id, in a fixed direction), which is what lets
`offset` name a stable window: without it, two stashes of equal size could swap
between requests and a "Load more" would skip or repeat one.

## Tests

```bash
go test ./...
```

Coverage focuses on the spec-driven pure-logic bits:

- `internal/store/` -- section 6.3 extension-extraction rules + section 13 boundaries;
  mountinfo parsing (the cifs-nofail trap), DirSize, AtomicCopyFile (section 8.4).
- `internal/id/id_test.go` -- per-day uniqueness, on-disk scan picks up
  pre-existing IDs incl. sidecars (restart safety), and the index check that
  keeps an ID an older day's row still owns out of a later day's draws.
- `internal/meta/` -- sidecar write -> reimage rebuild round-trip (section 8.5);
  buffered lifecycle (UpdateOnComplete preserves the flag, section 8.4);
  a duplicate ID is reported as such and a schema violation is not.
- `internal/sshsrv/` -- the redraw ladder that keeps an upload alive when an
  ID is claimed between the draw and the index write, and the categorical
  reason every post-ID abort owes the client; flush worker (move+sidecar+clear+remove, offline
  no-op, idempotent, section 8.4); SFTP ingest (store+sidecar+metadata,
  truncation, offline buffering, section 4.1).
- `internal/detect/` -- heuristic classification (extension/sniff/text,
  SVG+HTML->download-only) (ui section 6.1, section 7.4).
- [`extension-sdk`](../../extension-sdk/) -- the shared SDK, resolved as a
  sibling module rather than copied in here, so its suite is the one that runs:
  `beacon` covers the hello/periodic/goodbye lifecycle, catch-up retry until the
  first success, and the https->http downgrade only on transport errors
  (section 4.7); `pool` is the aggregator read behind the remote-stash
  deep-link (section 3.4).
- `internal/httpsrv/` -- create->list->get->raw->delete round-trip, the delete
  gate (locked/unlocked/unconfigured), cross-host delete on the share, bulk
  delete with partial failure, the reconcile predicate (including the
  offline-share case that must prune nothing), pool-wide remote-sidecar
  aggregation, html-served-as-text, multi-file archive + listing, static
  pages (ui section 3-section 9).

The front-end has two framework-free unit files run by hand (there is no JS
runner in the repo -- `node internal/httpsrv/web/assets/common.test.js` and
`node internal/httpsrv/web/assets/index.test.js`, exit 0 = pass). They cover
the shared helpers' URL/timeout guards and the list page's selection +
delete surface (ui section 8.5) against a minimal DOM/fetch shim.

The legacy SCP wire protocol and the live SFTP path are exercised against
a real `scp`/`sftp` client only in the in-VM end-to-end (host `:22` is
typically taken by sshd, so a local daemon can't bind it; use
`--listen-addr` to run a dev instance on another port).

## What's not here yet

- The magika detection backend is built only with `-tags magika` (the
  default is the pure-Go heuristic); ONNX Runtime + model vendoring is a
  VM-image-build concern (ui section 6.1, section 14).
- Cleanup / retention / aging (section 12).
- Backup / restore beyond the durable share + sidecars (section 12).

## Module path note

`go.mod` declares `module stash-service` -- short, local, never imported
from outside this directory. Internal packages live under
`stash-service/internal/...`.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.13

Back to [Yuruna](../../../../README.md)
