# Yuruna control routes — who is allowed to drive a host

> **Who this is for.** An operator who uses a host's **status page** to start a cycle,
> pause a step, or run a host diagnostic — especially from a browser on **another
> machine**. Viewing a host's status needs no setup and never did; *driving* one now
> does, and this page explains the one-time setup.

## What changed

The status page's action buttons call **state-changing `/control/*` routes** on the
host's status server. Those routes rewrite the host's `test.config.yml`, start and stop
cycles, and run diagnostics — so anything that can call them owns the host.

A state-changing control request is now accepted only when the caller is **one of**:

- **on the host itself** — the request arrives on the loopback interface
  (`http://localhost:<port>`), which no LAN device or guest VM can reach; or
- **carrying a valid control proof** — a short-lived credential the pool hands to the
  page when you arrive through the pool dashboard's host link.

Everything else gets a `403`. **Read routes are unchanged**: the status page still
renders for anyone on the LAN, `status.json` is still served, and the config-sync read
(`GET /control/test-config`) that a new host pulls from a reference host still works.

| Route | Gated |
| --- | --- |
| `control/start-cycle`, `control/cycle-pause`, `control/cycle-resume`, `control/step-pause`, `control/step-resume`, `control/break-continue`, `control/test-caching-proxy`, `control/host-diagnostic` | always |
| `control/test-config`, `control/perf-aggregates` | on `POST`/`PUT` — their read path stays open |

## Where the proof comes from

The proof is an HMAC over the shared **`pool-auth-token`** — the token that already gates
the aggregator's push-ingest and the cross-host credential fetch. It is **not a new
secret**, and the token itself never travels in a URL.

When you open a host from the *Yuruna hosts* dashboard, the link goes through the pool
aggregator on the caching proxy, which mints a proof valid for **15 minutes** and hands it
to the host page in the URL **fragment** (`#yctl=…`). A fragment is never sent to a server
and never lands in an access log; only the page's own JavaScript reads it. The page keeps
it in `sessionStorage` **for that tab** and presents it as the `X-Yuruna-Control` header on
every control POST. The host recomputes the HMAC with its own copy of the token and accepts
a proof whose expiry is no more than **20 minutes** out — deliberately longer than the mint,
so a host whose clock trails the proxy still accepts a freshly minted proof. The proof is
captured once on arrival and never refreshed, so the config page shows a countdown and warns
before it lapses rather than letting a long edit fail at Save.

A host with **no** `pool-auth-token` configured is not broken — it simply accepts control
from loopback only.

## Enabling remote control on a host

Every host **and** the caching proxy must hold the **same** token value: a proof minted by
the proxy can only be verified by a host that shares its token.

**1. Read the shared token from the caching proxy.**

```
ssh caching-proxy-admin@<proxy> 'sudo cat /etc/yuruna/pool-auth.token'
```

This will ask you for the caching proxy VM password, which is recorded on the proxy VM's host under `test/status/runtime/yuruna-caching-proxy.yml` (and printed in `New-VM.ps1`'s ready banner). This completes the "secure path" to set the authorization token: the operator has access to the host for the caching process.

**2. Store that value on the host.**

```
pwsh test/Set-PoolAuthToken.ps1 -Token '<shared-token>' -BounceStatusService
```

The script is idempotent. It declares the `users.yml` vault key, stores the token, and
verifies the round-trip through the same lookup the control gate performs — so a key that
is stored under one name and read under another (a silent `403`) cannot happen.
`-BounceStatusService` restarts the status server so the token takes effect immediately
instead of at the next cycle; `-WhatIf` previews without touching the vault.

It reports each step as it runs — vault key, store, verify, then the restart — and streams
the status server's own start-up output through while it waits. The vault writes are
sub-second; the restart is the slow part (it re-asserts the caching-proxy port map and
waits for the port to answer), so expect that step to take tens of seconds. It is bounded:
if the restart has not finished in 180 s the script says so and leaves it running, and the
token is already stored either way — it simply takes effect at the next cycle instead.

Bringing a **new** host into the pool? One command does the token and the config sync:

```
pwsh test/Sync-HostConfiguration.ps1 -ReferenceHost <host> -SharedToken '<shared-token>' -PersistSharedToken
```

**3. Drive the host from the dashboard.** Open the *Yuruna hosts* dashboard on the caching
proxy and follow the host's link. Arriving that way is what carries the proof; typing the
host's URL by hand does not.

## What still works with no setup at all

- **The on-host operator** — `http://localhost:<port>` on the host has full control, before
  any token exists.
- **Read-only viewing** from any browser on the LAN.
- **Unattended cycles** — the runner never calls the control routes, so pool automation is
  untouched.

## When a control button returns 403

> `follow guidance at https://yuruna.link/control-proof`

In the config editor this reads `Save failed: …`; the short link lands on this section. The
underlying condition is always the same: the caller was neither on loopback nor carrying a
valid control proof.

**Read the `reason` first — it names the precondition that actually failed**, so you can skip
straight to the matching item below. The 403 body carries it alongside the message, and the
status pages render it in place of a bare `HTTP 403`:

| `reason` | Meaning |
|---|---|
| `host-token-missing` | This host holds no `pool-auth-token`, so no proof can ever be accepted (item 3). |
| `proof-missing` | The request carried no proof at all — usually item 1 or 2. |
| `proof-expired` | A well-formed proof whose expiry has passed (item 1). |
| `proof-invalid` | A proof that does not verify against this host's token (item 4). |
| `verifier-unavailable` | The status server could not load its verifier; check its log. |

1. **Your browser is not actually on loopback.** Only a genuine loopback address is exempt.
   Browsing `http://<this-host's-own-LAN-IP>:<port>` **from the host itself is _not_ loopback** —
   the request arrives from the LAN address, so it needs a proof exactly like a remote caller.
   This is the usual reason a control action "fails locally too". Use
   `http://localhost:<port>` for the no-proof path.
2. **You typed the host URL instead of following the dashboard link.** The proof lives in that
   tab's `sessionStorage`, and it is per-origin: arriving on one of the host's addresses and
   then switching to another loses it. Re-enter through the dashboard host link. A minted proof
   lasts about 15 minutes; the config page shows a countdown and warns before it lapses.
3. **The host has no `pool-auth-token` vault entry** (or an empty vault key) — non-loopback
   control is refused by design until you set one. `Sync-HostConfiguration` stores it for you
   when a host joins the pool with `-SharedToken`; `-NoPersistSharedToken` opts out.
4. **The host's token does not match the proxy's.** Re-run `Set-PoolAuthToken.ps1` with the
   value from `/etc/yuruna/pool-auth.token` (both commands are in
   [Enabling remote control on a host](#enabling-remote-control-on-a-host) above).
5. **The proxy is minting nothing.** If the caching proxy was built on a host that had no
   `pool-auth-token`, it baked an **empty** token: it then mints no proof at all and every
   host 403s. Confirm from the host — `curl -sI '<aggregator>/go/host?host=<hostId>'` shows a
   `Location:` with **no `#yctl=` fragment**, and `curl -sk -X POST '<aggregator>/ingest'`
   answers `503 ingest disabled`. Fix by setting the token and rebuilding the proxy VM, or by
   writing the same value into `/etc/yuruna/pool-auth.token` there. A stale aggregator build
   shows the same symptom ([caching.md](caching.md#migrating-to-a-replacement-cache-vm)).
6. **The host clock is skewed** far enough that a fresh proof already looks expired. The
   acceptance window is held above the mint to absorb ordinary drift, so this means a large
   offset; fix time sync on the host.

A different message — `forbidden: missing X-Yuruna request header` — is the cross-site
request guard, not the proof: it means a non-browser client (`curl`) called a control route
without that header.

## GET /control/runner-status

An always-open read route that reports whether the outer `Invoke-TestRunner`
process is actually alive: `{ running: bool, pid: int|null }`. It reads
`<track>/runner.pid` (owned by the outer runner) and verifies the PID really is
the outer runner via two paths:

1. **`<track>/runner.start` sidecar (preferred)** — holds the outer pwsh's
   ISO-8601 StartTime, recorded at launch. The route cross-checks it against
   `Get-Process -Id <pid>`'s live StartTime, so a PID reused by an unrelated
   process (different StartTime) is rejected without depending on argv
   visibility. This is what correctly identifies the documented
   `pwsh ~/git/yuruna/test/Invoke-TestRunner.ps1` launch from an interactive
   REPL on macOS/Linux, where argv is just `pwsh` and a cmdline regex
   false-negatives.
2. **Cmdline regex (fallback)** — for older runners without the sidecar and for
   launches that do carry the script in argv (Windows shortcut,
   `pwsh -File ...`). Same regex the outer runner uses for its own stale-PID
   detection at startup.

The UI shows a "Stopped" banner when `running=false` so stale `status.json`
data is not mistaken for a live runner.

## File serving: URL-prefix dispatch and deny-list

The status server's file-serving side dispatches by URL prefix:
`yuruna-repo/<rel>` maps to the repo working tree (deny-listed),
`runtime/<name>` to the runtime dir (pids, `status.json`, control flags,
`ipaddresses.txt`, `caching-proxy.txt`, `current-action.json`, `server.err`,
`yuruna-caching-proxy.yml`, `host.uuid`), `log/<name>` to the log dir (HTML
transcripts, OCR/screenshot debug, failure captures), and anything else to the
status dir (`index.html`, template, static assets, `perf/`, `extension/`,
`captures/`, `ssh/`). Each branch pins the resolved path under its mount root
with a StartsWith check, so traversal such as `runtime/../../../etc/passwd`
cannot escape. A unified deny-list is then applied to every served path so
secrets under `status/` (`vault.yml`, `transports.yml`, `events.log`, the SSH
private key, the caching-proxy state file) are blocked regardless of which
route reached them.

## See also

- [pool-admin.md](pool-admin.md) — running a pool and the *Yuruna hosts* dashboard.
- [pool-storage.md](pool-storage.md) — the `pool-auth-token`-gated credential fetch used
  when syncing a new host's config.
- [caching.md](caching.md#caching-proxy--test-harness-operator-reference) — the caching-proxy VM that hosts Grafana and the
  pool aggregator.
- [test-config.md](test-config.md) — the host-side config keys, including the vault.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.26

Back to [Yuruna](../README.md)
