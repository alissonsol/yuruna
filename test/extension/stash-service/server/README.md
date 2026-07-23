# Stash Service — Go daemon (`stash-server`)

Spec: [docs/design/stash-service.md](../../../../docs/design/stash-service.md) ·
[yuruna.link/stash-service](https://yuruna.link/stash-service).

A single static binary with TWO listeners:

- **TCP/22** — the SCP/SFTP sink. Accepts any SSH authentication (§4.3
  pass-through) and stores every upload as a content artifact (plus an
  on-share `.yuruna.meta.json` sidecar and a VM-local SQLite index row,
  §6, §8). Serves BOTH the legacy SCP sink-mode wire protocol (§5) and the
  SFTP subsystem (modern scp's default, §4.1).
- **TCP/80** — the browser **UI + JSON API**
  ([stash-service-ui.md](../../../../docs/design/stash-service-ui.md)): pool-wide
  browse/search, create (paste or upload), inline viewing, and
  local-host-only delete. Same process, so create flows through the same
  storage pipeline as SCP (a stash is a stash).

## Layout

```
server/
├── go.mod / go.sum                       # module stash-server (go.sum committed)
├── main.go                               # flags, signals, listener loop, sidecar rebuild
├── internal/
│   ├── config/config.go                  # spec §10 constants in one place
│   ├── id/id.go                          # per-day 4-char allocator, scans share+buffer (§7)
│   ├── store/store.go                    # share/buffer layout, extension extraction, mount probe (§6.3, §8.4, §13)
│   ├── meta/meta.go                      # VM-local SQLite index + sidecars + rebuild (§8, §8.5)
│   ├── scp/scp.go                        # legacy SCP sink-mode wire protocol (§5)
│   ├── sshsrv/{sshsrv,sftp,flush}.go     # crypto/ssh server, SFTP backend, NAS-offline flush (§4, §4.1, §8.4)
│   ├── sshsrv/ingest.go                  # UI-facing ingest (paste/upload) + local delete (ui §5, §8)
│   ├── detect/                           # content-type detection: pure-Go heuristic + magika build-tag adapter (ui §6.1)
│   ├── beacon/                           # presence beacon: self-announce to the pool-aggregator (§4.7)
│   └── httpsrv/                          # UI/API HTTP server, pool-wide index, host resolution, embedded web/ (ui §2–§9)
└── *_test.go                             # unit tests for the pure-logic bits
```

`ui` section references above are [stash-service-ui.md](../../../../docs/design/stash-service-ui.md).

## Build

Pure Go (the SQLite driver is [`modernc.org/sqlite`](https://pkg.go.dev/modernc.org/sqlite),
not the CGo one), so the build needs only `golang-go`. `go.sum` is
committed, so do NOT run `go mod tidy` (it needs the network to recompute
the graph); `go build` verifies against `go.sum` and fetches modules
through the caching proxy:

```bash
sudo apt-get install -y golang-go libcap2-bin
cd ~/yuruna/test/extension/stash-service/server
go build -o stash-server .
sudo install -m 0755 stash-server /usr/local/bin/stash-server
```

### Magika detection backend (optional build)

Content-type detection (`internal/detect`) defaults to a pure-Go heuristic
(extension + content sniff + UTF-8 text check) — no cgo, no model, always
built and tested. The richer **magika** backend
([google/magika](https://github.com/google/magika/tree/main/go),
[stash-service-ui.md](../../../../docs/design/stash-service-ui.md) §6.1,
§14) is built only with `-tags magika` and is EXCLUDED from the default
build, so plain `go build` / `go test` stay pure-Go and offline. Enabling
it requires, in the VM image build, all three of:

- the Go binding: `go get github.com/google/magika/go/magika`
- ONNX Runtime: the native shared library (cgo links against it)
- the model assets: e.g. the `standard_v3_3` model directory

```bash
# In the VM image build only, after vendoring ONNX Runtime + the model:
go get github.com/google/magika/go/magika
go build -tags magika -o stash-server .
```

The assets dir and model name are read from the environment so the image
build can point at the vendored copies: `MAGIKA_ASSETS_DIR` (default
`/usr/local/share/magika`) and `MAGIKA_MODEL` (default `standard_v3_3`).
Any construction or scan failure degrades to the pure-Go heuristic, so a
misconfigured model never breaks classification.

The bring-up script honors `STASH_BUILD_TAGS=magika` to opt in.

The production bring-up (`guest/ubuntu.server.26/ubuntu.server.26.stash-service.sh`,
run by the VM's cloud-init) does all of this plus the mount, systemd unit,
and `/var/lib/stash-server` provisioning — this section is for ad-hoc dev.

## Run (manual / dev)

```bash
# 1. Disable the OS sshd so the custom server can bind :22 (§4.2).
sudo systemctl disable --now ssh

# 2. Allow non-root binding of port 22 (or run the daemon as root).
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/stash-server

# 3. Launch. --share-folder (the mounted stash share, <stashLocalPath>/stash/<hostId>)
#    is required; the metadata index and offline buffer default to
#    /var/lib/stash-server/{metadata,buffer} on the VM's local disk.
/usr/local/bin/stash-server --share-folder /mnt/ystash-nas/stash/<hostId>
```

Logs go to stderr; journald captures them under the `stash-server.service`
unit the bring-up installs (`journalctl -u stash-server`).

## Exercise

The daemon serves BOTH protocols (see the spec §4.1):

```bash
# Modern scp defaults to SFTP -- works, one record per file. Stored on
# the share; the upload ID is logged server-side (SFTP can't echo it).
echo hello > note.pdf
scp note.pdf yuruna@<vm-ip>:/scratch

# Legacy protocol (-O): enables multi/recursive ZIP grouping AND echoes
# the YURUNA-STASH-ID line to your terminal.
scp -O a.txt b.txt yuruna@<vm-ip>:/scratch    # one .yuruna.archive.zip
scp -O -r ./dir    yuruna@<vm-ip>:/scratch    # one .yuruna.archive.zip
```

Under `-O` (legacy), scp renders the daemon's stderr, so each invocation
surfaces a line like:

```
YURUNA-STASH-ID: a1b2
```

The artifact is at `<ShareFolder>/files/<yyyy>/<mm>/<dd>/a1b2[.ext]`
(single) or `a1b2.yuruna.archive.zip` (archive), with an `a1b2.yuruna.meta.json`
sidecar next to it. The matching SQLite row is in the VM-local metadata
index (default `/var/lib/stash-server/metadata/stash.sqlite`).

## UI / API (`:80`)

Open `http://<vm-ip>/` for the pastebin-style UI (browse, search, create,
view, delete). The JSON API it consumes
([stash-service-ui.md](../../../../docs/design/stash-service-ui.md) §9):

| Method | Path | Purpose |
|---|---|---|
| GET | `/healthz` | liveness (`ok`) |
| GET | `/api/stashes` | list/search the pool-wide view (`q`,`id`,`username`,`filename`,`path`,`class`,`status`,`host`,`from`,`to`,`limit`,`offset`) |
| GET | `/api/stashes/{hostId}/{y}/{m}/{d}/{id}` | one stash's metadata |
| GET | `/api/stashes/{…}/{id}/archive` | ZIP entry listing |
| GET | `/raw/{hostId}/{y}/{m}/{d}/{id}` | bytes, inline (safety headers; active content served as text) |
| GET | `/download/{…}` | bytes, attachment |
| POST | `/api/stashes` | create (multipart `files`/`text`/`title`/`author`, urlencoded, or JSON) |
| DELETE | `/api/stashes/{hostId}/{…}` | delete — **source-IP-restricted** to the VM or the deploying host (`--host-ip`), then **local host only** (foreign hostId → 403) |
| POST | `/api/refresh` | force a pool-index rescan |
| GET | `/api/host?host=<id>` | best-effort hostId→stash-UI resolution (pool-aggregator) |

Flags (defaults): `--http-addr` (`0.0.0.0:80`, empty disables the UI),
`--pool-window-days` (`30`), `--pool-refresh-secs` (`60`),
`--list-default-limit` (`50`), `--aggregator-url` (empty), `--listen-addr`
(`0.0.0.0:22`, dev override when the OS sshd holds :22), `--host-id` (empty)
and `--presence-interval` (`15m`, `0` disables) for the presence beacon
(§4.7), and `--host-ip` (empty) — the deploying host's IP, the one non-VM
source allowed to `DELETE` stashes (reads/writes stay open; UI §8.4). The bring-up stamps the framework version via
`-ldflags "-X main.version=<v>"` (shown in the UI header); ad-hoc dev builds
show `vdev`.

## Presence beacon (§4.7)

With `--aggregator-url` + `--host-id` set (the bring-up bakes both from the
host seed), the daemon POSTs `<aggregator>/announce` at startup, every
`--presence-interval`, and (best-effort, `active:false`) at shutdown. This
keeps the pool dashboard's **Extension hosts** row alive **without the owning
host's status server**: the registration path goes dark whenever that server
is down (routinely, after a host reboot), while this VM auto-restarts and
keeps serving. The announce carries only the host's `hostId` + this UI's
port; the aggregator derives the URL from the connection's source address,
so an announcer can only advertise itself. Best-effort throughout — an
unreachable aggregator never affects stash operation.

The UI is pool-wide: this host's live index merged with every other host's
on-share sidecars (bounded to the recent window in memory, with an
on-demand deep scan for older queries). Delete only touches this host's
own stashes; a remote stash shows a disabled Delete pointing at its owner.

## Tests

```bash
go test ./...
```

Coverage focuses on the spec-driven pure-logic bits:

- `internal/store/` — §6.3 extension-extraction rules + §13 boundaries;
  mountinfo parsing (the cifs-nofail trap), DirSize, AtomicCopyFile (§8.4).
- `internal/id/id_test.go` — per-day uniqueness, on-disk scan picks up
  pre-existing IDs incl. sidecars (restart safety), cross-day re-use (§12).
- `internal/meta/` — sidecar write → reimage rebuild round-trip (§8.5);
  buffered lifecycle (UpdateOnComplete preserves the flag, §8.4).
- `internal/sshsrv/` — flush worker (move+sidecar+clear+remove, offline
  no-op, idempotent, §8.4); SFTP ingest (store+sidecar+metadata,
  truncation, offline buffering, §4.1).
- `internal/detect/` — heuristic classification (extension/sniff/text,
  SVG+HTML→download-only) (ui §6.1, §7.4).
- `internal/beacon/` — hello/periodic/goodbye lifecycle, catch-up retry
  until the first success, https→http downgrade only on transport errors
  (§4.7).
- `internal/httpsrv/` — create→list→get→raw→delete round-trip, remote-host
  delete 403, pool-wide remote-sidecar aggregation, html-served-as-text,
  multi-file archive + listing, static pages (ui §3–§9).

The legacy SCP wire protocol and the live SFTP path are exercised against
a real `scp`/`sftp` client only in the in-VM end-to-end (host `:22` is
typically taken by sshd, so a local daemon can't bind it; use
`--listen-addr` to run a dev instance on another port).

## What's not here yet

- The magika detection backend is built only with `-tags magika` (the
  default is the pure-Go heuristic); ONNX Runtime + model vendoring is a
  VM-image-build concern (ui §6.1, §14).
- **Cross-day ID reuse vs the global SQLite PRIMARY KEY**:
  the allocator's uniqueness scope is per-UTC-day (SS§7/§12, IDs may repeat
  across days), but `uploads.id` is a global `PRIMARY KEY`, so a 4-char ID
  reused on a later day collides with a surviving older-day row and fails
  the upload (clean rejection — SCP exit 1 / UI 500 — no corruption). Rare
  at this tool's volume; a proper fix is a composite `(day, id)` key plus
  date-scoped `Get`/`Delete` (resolve is already date-scoped, ui §4.4), or a
  bounded re-allocate-on-collision retry.
- Cleanup / retention / aging (§12).
- Backup / restore beyond the durable share + sidecars (§12).

## Module path note

`go.mod` declares `module stash-server` — short, local, never imported
from outside this directory. Internal packages live under
`stash-server/internal/...`.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.22

Back to [Yuruna](../../../../README.md)
