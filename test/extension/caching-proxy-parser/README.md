# caching-proxy-parser

A ~300-line Go tail-server that replaces loki + promtail for the single
"Recent 100 requests" panel on the caching-proxy Grafana dashboard.
Optimized for that one scenario — no tenancy, no persistence, no
LogQL, no plugin dependencies.

## Why it exists

The earlier stack (loki + promtail + Grafana logs panel) wedged with
the ingester rejecting pushes ("Ingester is shutting down") while the
process reported healthy by every nominal probe. Diagnostic notes are
in the diff that introduced this extension; the short version is that
a single-host, single-source, ~25 k requests/day workload doesn't
need the loki ingester lifecycle to view its own access log.

This extension trades the loki stack for a memory-only ring buffer of
the last 100 parsed lines from `/var/log/squid/yuruna_access.log`,
served as JSON + a self-contained HTML page.

## Files

| File | Purpose |
|---|---|
| `main.go` | The Go service. Tail + ring + HTTP. No external deps. |
| `go.mod` | Standard-library-only module file. |
| `caching-proxy-parser.service` | systemd unit. Runs as `proxy`, read-only `/var/log/squid`, fully sandboxed. |
| `caching-proxy-parser.config.yml` | Extension config (single provider). |
| `default.psm1` | Harness-side metadata helper. |

## How it gets onto the caching-proxy VM

The caching-proxy VM's cloud-init `runcmd` (in 
[user-data](../../../host/vmconfig/caching-proxy.base.user-data)):

1. wgets `main.go`, `go.mod`, `caching-proxy-parser.service` from the
   harness's yuruna-repo HTTP server (with the GitHub raw fallback
   the rest of the user-data already uses).
2. `go build` produces a static binary; the toolchain is the same
   `golang-go` apt package already pulled in to compile
   `squid-exporter`.
3. Installs the binary at `/usr/local/bin/caching-proxy-parser` (0755)
   and the unit at `/etc/systemd/system/caching-proxy-parser.service`
   (0644).
4. `systemctl daemon-reload && systemctl enable --now
   caching-proxy-parser.service`.
5. `golang-go` is still purged at the end of `runcmd` — the static
   binary needs no toolchain at runtime.

## Endpoints

The service binds `:9302` on every interface (matching apache + grafana
on the caching-proxy VM):

- `GET /recent-requests` — JSON array of the last 100 parsed entries,
  newest first. Fields: `ts`, `ts_iso`, `client_ip`, `status`, `bytes`,
  `method`, `url`, `ua`. `Cache-Control: no-store`, `CORS: *`.
- `GET /` — self-contained dark-mode HTML page; auto-refreshes
  every 5 s; no external resources (works offline).
- `GET /healthz` — a single line beginning `ok`, followed by follower
  diagnostics: `ok parsed=<N> skipped=<M> fielderr=<K> last_read=<iso|never> last_open_err=<msg|empty>`.
  `parsed`/`skipped` are the matched vs. logformat-drift line counts,
  `fielderr` counts matched lines with an unparseable `ts`/`bytes`,
  `last_read` is when a line was last read, and `last_open_err` is the
  most recent open/stat failure (empty while the log is open) — so a
  wedged tailer is distinguishable from a healthy-but-quiet one.

## Operating notes

- Backfill on first open: scans the last 64 KB of the log so the panel
  is non-empty within ~1 s of boot.
- Logrotate handling: re-opens by inode comparison; the next post-
  rotation line lands in the ring without restart.
- Ring buffer is in memory only. A service restart starts cold; that's
  intentional — there's nothing worth persisting for a "last 100"
  view.
- All log fields are passed as `textContent` (not `innerHTML`) in the
  HTML view; URL + User-Agent are attacker-controlled and would
  otherwise be a defacement vector.

## Verifying after install

```
ssh yuruna@<cache-ip>
systemctl status caching-proxy-parser
curl -s http://localhost:9302/healthz             # → begins "ok parsed=… skipped=… last_open_err=…"
curl -s http://localhost:9302/recent-requests | jq '. | length'
xdg-open http://<cache-ip>:9302/                  # the live HTML view
```

## Limits

- One log path, hard-coded default (`/var/log/squid/yuruna_access.log`)
  with a `-log` override flag for testing.
- One ring of fixed size (100).
- No retention, no aggregation, no historical view — those still
  belong to Prometheus + Grafana.
- Parses only the yuruna logformat declared in
  `/etc/squid/conf.d/yuruna.conf`; the stock squid access.log layout
  is silently skipped.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.07

Back to [Yuruna](../../../README.md)
