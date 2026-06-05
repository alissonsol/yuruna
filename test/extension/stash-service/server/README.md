# Stash Service — Go daemon (`stash-server`)

Spec: [docs/stash-service.md](../../../../docs/stash-service.md) ·
[yuruna.link/stash-service](https://yuruna.link/stash-service).

A single static binary that listens on TCP/22, accepts any SSH
authentication (§4.3 pass-through), implements the SCP sink-mode wire
protocol (§5), and stores every upload as a content artifact plus a
SQLite metadata row under the StashFolder (§6, §8).

## Layout

```
server/
├── go.mod                                # module stash-server
├── main.go                               # flags, signals, listener loop
├── internal/
│   ├── config/config.go                  # spec §10 constants in one place
│   ├── id/id.go                          # per-day 6-char allocator (§7)
│   ├── store/store.go                    # files/ + extension extraction (§6.3, §13)
│   ├── meta/meta.go                      # SQLite schema + CRUD + search (§8)
│   ├── scp/scp.go                        # SCP sink-mode wire protocol (§5)
│   └── sshsrv/sshsrv.go                  # crypto/ssh server, host key, dispatch (§4)
└── *_test.go                             # unit tests for the pure-logic bits
```

## Build

Pure Go (the SQLite driver is [`modernc.org/sqlite`](https://pkg.go.dev/modernc.org/sqlite),
not the CGo one), so the build needs only `golang-go`:

```bash
sudo apt-get install -y golang-go
cd ~/yuruna/test/extension/stash-service/server
go mod tidy        # generates go.sum + fills the module graph
go build -o stash-server .
sudo install -m 0755 stash-server /usr/local/bin/stash-server
```

## Run (manual, v1)

Daemon supervision is out of scope per §4.6. To bring the service up
for testing:

```bash
# 1. Disable the OS sshd so the custom server can bind :22 (§4.2).
sudo systemctl disable --now ssh

# 2. Allow non-root binding of port 22 (or run the daemon as root).
sudo setcap 'cap_net_bind_service=+ep' /usr/local/bin/stash-server

# 3. Launch. By default the StashFolder is $HOME/yuruna/test/status/stash;
#    override with --folder if you have a different layout.
/usr/local/bin/stash-server
```

Logs go to stderr (journald captures them when launched under
systemd; the systemd unit is deferred per §4.6).

## Exercise

```bash
# Single file -- one record, one artifact with extension preserved.
echo hello > note.pdf
scp note.pdf yuruna@<vm-ip>:/scratch

# Multi-file -- one record, one .yuruna.archive.zip.
scp a.txt b.txt yuruna@<vm-ip>:/scratch

# Recursive -- one record, one .yuruna.archive.zip.
scp -r ./dir yuruna@<vm-ip>:/scratch
```

scp prints the daemon's stderr to the operator's terminal, so each
invocation surfaces a line like:

```
YURUNA-STASH-ID: a8b2cz
```

The artifact is at `<StashFolder>/files/<yyyy>/<mm>/<dd>/a8b2cz[.ext]`
(single) or `a8b2cz.yuruna.archive.zip` (archive). The matching SQLite
row is in `<StashFolder>/metadata/stash.sqlite`.

## Tests

```bash
go test ./...
```

Coverage focuses on the spec-driven pure-logic bits:

- `internal/store/store_test.go` — every §6.3 extension-extraction rule
  plus the §13-decision boundaries (option-c: discard on disallowed
  charset).
- `internal/id/id_test.go` — uniqueness within a day, on-disk scan
  picks up pre-existing IDs (restart safety), cross-day re-use is
  permitted (§12).

Wire-protocol and SSH integration are exercised manually with `scp`
above; an in-VM end-to-end test will land with the bring-up
automation step.

## What's not here yet

- Daemon supervision (systemd unit). Manual start only (§4.6, §12).
- The in-VM UI that browses the metadata DB (§2, §12).
- Cleanup / retention / aging (§12).
- Backup / restore (§12).

## Module path note

`go.mod` declares `module stash-server` — short, local, never imported
from outside this directory. Internal packages live under
`stash-server/internal/...`.

---

Copyright (c) 2019-2026 by Alisson Sol et al.
