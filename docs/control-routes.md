# Yuruna control routes — who is allowed to drive a host

> **Who this is for.** An operator who uses a host's **status page** to start a cycle,
> pause a step, or run a host diagnostic — especially from a browser on **another
> machine**. Viewing a host's status needs no setup; *driving* one does — this page
> explains that one-time setup.

## What is gated

The status page's action buttons call **state-changing `/control/*` routes** on the
host's status service. Those routes rewrite the host's `test.config.yml`, start and stop
cycles, and run diagnostics — so anything that can call them owns the host.

A state-changing control request is accepted only when the caller is **one of**:

- **on the host itself** — the request arrives on the loopback interface
  (`http://localhost:<port>`), which no LAN device or guest VM can reach; or
- **carrying a valid control proof** — a short-lived credential the pool hands to the
  page when you arrive through the pool dashboard's host link.

Everything else gets a `403`. **Read routes stay open**: the status page renders for
anyone on the LAN, `status.json` is served, and the config-sync read
(`GET /control/test-config`) a new host pulls from a reference host works.

| Route | Gated |
| --- | --- |
| `control/start-cycle`, `control/cycle-pause`, `control/cycle-resume`, `control/step-pause`, `control/step-resume`, `control/break-continue`, `control/test-caching-proxy-service`, `control/host-diagnostic` | always |
| `control/test-config`, `control/perf-aggregates` | on `POST`/`PUT` — their read path stays open |
| `control/runner-status`, `control/control-status`, `control/host-facts` | never — read-only, and pool services read them |

## Where the proof comes from

The proof is an HMAC over the shared **`lab-auth-token`** — the same token that gates the
aggregator's push-ingest and the cross-host credential fetch, **not a new secret**. The
token itself never travels in a URL.

When you open a host from the *Yuruna hosts* dashboard, the link goes through the pool
aggregator on the caching-proxy service, which mints a proof valid for **15 minutes** and
hands it to the host page in the URL **fragment** (`#yctl=…`). A fragment never reaches a
server or an access log; only the page's own JavaScript reads it. The page keeps it in
`sessionStorage` **for that tab** and presents it as the `X-Yuruna-Control` header on every
control POST. The host recomputes the HMAC with its own copy of the token and accepts a
proof whose expiry is no more than **20 minutes** out — deliberately longer than the mint,
so a host whose clock trails the proxy still accepts a freshly minted proof. The proof is
captured once on arrival and never refreshed, so the config page shows a countdown and warns
before it lapses rather than letting a long edit fail at Save.

A host with **no** `lab-auth-token` is not broken — it accepts control from loopback only.

The **extension service UIs** are handed the same proof the same way. Opening one from the
dashboard's *Extension hosts* table goes through `/go/stash`, which mints a proof and leaves
it in the fragment; the page spends it on `POST /api/unlock-proof` and its actions are
unlocked without copying the rotating code off a dashboard tile. A service VM normally holds no `lab-auth-token` of its own, so it asks the aggregator
(`POST /api/v1/control-proof`) whether the proof is genuine — a verifier, not a mint. No
proof, or an expired one, and the UI's ordinary Lab token prompt is still there.

The **Pool control service** presents the same proof when its *Pool Status* column pauses or
continues every member of a pool at once ([pool-admin.md](pool-admin.md#pool-status--pausing-and-continuing-every-member-at-once)).
It mints one from its own copy of the token when it has one, and otherwise reads the fragment
off `/go/host` without following the redirect — the same proof, obtained as a browser
obtains it. So the enrollment state that decides whether a host's buttons work also
decides whether pool-wide control reaches it, and the `reason` table below explains both.

## Enabling remote control on a host

Every host **and** the caching-proxy service must hold the **same** token value: a proof
minted by the proxy can only be verified by a host that shares its token. The token
originates on the caching-proxy service — building the proxy VM mints one automatically
when the building host has none — and every other host obtains it by **enrolling with the
Lab token**; nobody ever reads or types the secret itself.

**1. Read the Lab token off the dashboard.** Open the *Yuruna hosts* dashboard (Grafana on
the caching-proxy service) and find the **Lab token** tile next to the *Extension hosts*
table: a 6-character code, the **lab connection token**. It rotates every minute (aggregator
`-lab-token-rotate`) and a displayed code stays redeemable for about three minutes, so read
it right before the next step. A tile showing `off` means the aggregator holds no token —
see item 5 in the 403 table below.

**2. Enroll the host.**

```
pwsh test/Set-LabToken.ps1 -LabToken <code> -BounceStatusService
```

The script redeems the code at the aggregator's `POST /api/v1/lab-token` and stores the
shared `lab-auth-token` in this host's vault. The reply is **sealed under the code you
typed**, so only this host can open it: an enrolling host cannot yet verify the proxy's
TLS certificate (it is signed by the proxy's own CA), and the seal stops anything else on
the network from answering the exchange and planting a token of its choosing. The exchange
is audited — the aggregator logs every attempt with the caller's address, to its journal
and to Loki — and per-address throttled. Whoever can **view** the dashboard can enroll a
host: that is the lab's trust model, and the dashboard and the code rotate together.

The caching-proxy service is found from this host's configuration
(`vmStart.cachingProxyIp`, the persisted proxy state, or
`$env:YURUNA_CACHING_PROXY_SERVICE_IP`). Each is probed on the aggregator port `:9400` and
the first that answers is used, so a stale address — the persisted state keeps its last
value on a host that stopped running a proxy of its own — is passed over instead of
consuming the enrollment on a timeout. When none answers, probing continues for up to two
minutes, so a momentary outage does not cost you a code; a claim that loses its probe is
replaced with the address that won, so the next run does not pay for it again. When nothing
answers at all, the script asks for the address (or takes `-CachingProxyService <address>`).
When this host already has a `test/test.config.yml`, that answer is written to
`vmStart.cachingProxyIp` and binds the host to this lab's proxy from then on. On a machine
so new it has no config file yet, the address is used for this enrollment only — the
`Sync-HostConfiguration.ps1` run below brings over a config whose `vmStart.cachingProxyIp`
does the binding.

The script is idempotent — a lost token, a rebuilt proxy, or a doubtful host state is
fixed by reading the current code and running it again. It declares the `users.yml` vault
key, stores the token, and verifies the round-trip through the same lookup the control
gate performs — so a key stored under one name and read under another (a silent `403`)
cannot happen. `-BounceStatusService` restarts the status service so the token takes
effect immediately instead of at the next cycle; `-WhatIf` previews without touching the
vault. The vault writes are sub-second; the restart is the slow part (it re-asserts the
caching-proxy-service port map and waits for the port to answer), so expect tens of
seconds there. It is bounded: if the restart has not finished in 180 s the script says so
and leaves it running, and the token is stored either way — it simply takes effect at the
next cycle instead.

Bringing a **new** host into the pool? Enroll it first, then sync its config — the sync
reads the just-stored token from this host's own vault to fetch credentials:

```
pwsh test/Set-LabToken.ps1 -LabToken <code> -CachingProxyService <proxy> -BounceStatusService
pwsh test/Sync-HostConfiguration.ps1 -ReferenceHost <host>
```

(`Sync-HostConfiguration.ps1 -SharedToken '<raw-token>' -PersistSharedToken` is the
host-to-host path for a lab whose aggregator is unreachable: it takes the raw shared token
from an operator who already holds it and stores it the same way.)

**3. Drive the host from the dashboard.** Open the *Yuruna hosts* dashboard on the caching
proxy and follow the host's link — the **Control** cell in the *Pool hosts* table, or the
timeline's "open host status page" — both route through the aggregator's `/go/host`
redirect. Arriving that way is what carries the proof; typing the host's URL by hand does
not. Host ID cells are plain text in **every** table: exactly one cell per row grants
control, and it is the one that tells you whether control is on offer.

The Pool control service's own tables link host ids at the same redirect. **Every browser
link to `/go/*` is plain http, even where the aggregator has a TLS leaf** — the redirect
lands on a host's plain-http status page, so https protects nothing the next hop does not
already carry in clear, while putting a proxy-CA interstitial in front of every host link
(an operator's browser has no reason to trust that CA). The aggregator answers both
protocols on the same port, so server-to-server callers keep their TLS. Cloud-init
substitutes a plain-http base into the dashboard for this reason, and `goBaseURL` in the
pool-control daemon downgrades the configured URL for the same reason before the UI builds
a link from it.

**The Control cell answers "is this host enrolled?" before you click.** It reads:

| Cell | Meaning |
|---|---|
| **remote** (green) | this host holds the same `lab-auth-token` the proxy mints with, so its control buttons will work |
| **onsite** (grey) | the host holds no token — item 3 below |
| **onsite** (amber) | the host holds a *different* token, or its clock is skewed far enough to expire a fresh proof — items 4 and 6 |
| **unknown** | the host has not answered `/control/control-status`; a framework build older than this route does not serve it |

Following the link opens the host's status page in every state — it is the *control* that
is withheld, not the view. The cell refreshes on the aggregator's poll (30 s), so a host
flips to **remote** within about a minute of `Set-LabToken.ps1` finishing — the same beat
as the *Lab token* tile beside it.

The *Extension hosts* table has no Control cell: its rows include hosts running only an
extension service, which have no status page to open — use their *Pool hosts* row when
they have one.

## What works with no setup

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

**Check the dashboard's Control cell first** — it names most of these conditions *before* a
click ([Drive the host from the dashboard](#enabling-remote-control-on-a-host) above). Once
you are looking at a 403, **read the `reason`: it names the precondition that failed**, so
you can skip straight to the matching item below. The 403 body carries it alongside the
message, and the status pages render it in place of a bare `HTTP 403`:

| `reason` | Meaning |
|---|---|
| `host-token-missing` | This host holds no `lab-auth-token`, so no proof can ever be accepted (item 3). |
| `proof-missing` | The request carried no proof at all — usually item 1 or 2. |
| `proof-expired` | A well-formed proof whose expiry has passed (item 1). |
| `proof-invalid` | A proof that does not verify against this host's token (item 4). |
| `verifier-unavailable` | The status service could not load its verifier; check its log. |

1. **Your browser is not on loopback.** Only a genuine loopback address is exempt.
   Browsing `http://<this-host's-own-LAN-IP>:<port>` **from the host itself is _not_ loopback** —
   the request arrives from the LAN address, so it needs a proof exactly like a remote caller.
   This is the usual reason a control action "fails locally too". Use
   `http://localhost:<port>` for the no-proof path.
2. **You typed the host URL instead of following the dashboard link.** The proof lives in that
   tab's `sessionStorage` and is per-origin: arriving on one of the host's addresses and then
   switching to another loses it. Re-enter through the dashboard host link. A minted proof
   lasts about 15 minutes; the config page shows a countdown and warns before it lapses.
3. **The host has no `lab-auth-token` vault entry** (or an empty vault key) — non-loopback
   control is refused by design until the host is enrolled. Read the current Lab token off
   the dashboard and run `pwsh test/Set-LabToken.ps1 -LabToken <code> -BounceStatusService`
   ([Enabling remote control on a host](#enabling-remote-control-on-a-host) above).
4. **The host's token does not match the proxy's** — typically a host enrolled against a
   proxy since rebuilt with a new token. Re-enroll: read the current Lab token off the
   dashboard and re-run `Set-LabToken.ps1`.
5. **The proxy is minting nothing.** The *Lab token* tile shows `off`, and the aggregator
   holds an empty token — a proxy built by a version that did not auto-mint one, or a build
   whose vault store failed (its warning names this). Confirm from the host —
   `curl -sI '<aggregator>/go/host?host=<hostId>'` shows a `Location:` with **no `#yctl=`
   fragment**, and `curl -sk -X POST '<aggregator>/ingest'` answers `503 ingest disabled`.
   Fix by rebuilding the proxy VM (the build mints and stores a token when none exists), or
   by writing the host's stored value into `/etc/yuruna/lab-auth.token` there. A stale
   aggregator build shows the same symptom
   ([caching.md](caching.md#migrating-to-a-replacement-cache-vm)).
6. **The host clock is skewed** far enough that a fresh proof already looks expired. The
   acceptance window is held above the mint to absorb ordinary drift, so this means a large
   offset; fix time sync on the host.

A different message — `forbidden: missing X-Yuruna request header` — is the cross-site
request guard, not the proof: it means a non-browser client (`curl`) called a control route
without that header.

## Browser refusal notice

A refused control action is surfaced, not swallowed. To a status page's JavaScript a 403
is a *resolved* fetch, not a network error, so a page that only handles fetch failures
falls through to its normal reload and the refused click looks like a silent no-op — which
is what a remote operator without a proof would see on every button.

The status pages therefore show an explicit notice, and lead with **which precondition
failed**: the host names it in the 403 body (`reason`, table above), and "open this page
via the dashboard again" vs "enroll the host first" are different fixes. The notice markup
is static: each `reason` resolves through a fixed map of prewritten texts in
[`test/status/yuruna.common.js`](../test/status/yuruna.common.js), so no server-supplied
text is ever interpolated into the page.

## GET /control/runner-status

An always-open read route that reports whether the outer `Invoke-TestRunner`
process is alive: `{ running: bool, pid: int|null }`. It reads
`<track>/runner.pid` (owned by the outer runner) and verifies the PID really is
the outer runner via two paths:

1. **`<track>/runner.start` sidecar (preferred)** — holds the outer pwsh's
   ISO-8601 StartTime, recorded at launch. The route cross-checks it against
   `Get-Process -Id <pid>`'s live StartTime, so a PID reused by an unrelated
   process (different StartTime) is rejected without depending on argv
   visibility. This is what identifies the documented
   `pwsh ~/git/yuruna/test/Invoke-TestRunner.ps1` launch from an interactive
   REPL on macOS/Linux, where argv is just `pwsh` and a cmdline regex
   false-negatives.
2. **Cmdline regex (fallback)** — for older runners without the sidecar and for
   launches that do carry the script in argv (Windows shortcut,
   `pwsh -File ...`). Same regex the outer runner uses for its own stale-PID
   detection at startup.

The UI shows a "Stopped" banner when `running=false` so stale `status.json`
data is not mistaken for a live runner. The pool aggregator asks every host the
same question on every poll: the *Pool hosts* Status column reads **runner
stopped** above every other reading, so a host whose runner is gone stops
showing its last cycle's green to the whole lab. Only an explicit
`running=false` counts — a host predating the route answers `404`, which is not
evidence of a stopped runner and leaves the cycle status showing.

## GET /control/control-status

An always-open read route that answers "can this host be driven remotely, and by
whose token?" — the input behind the dashboard's **Control** column:

```json
{ "ok": true, "tokenConfigured": true, "tokenTag": "<base64>", "utcNow": "2026-07-29T12:34:56Z" }
```

`tokenTag` is `base64(HMAC-SHA256(lab-auth-token, "yuruna-control|tag|v1"))` — a
non-secret **name** for the token, not the token and not a hash of it. The aggregator
derives the same tag from its own copy and compares: equal means a proof it mints will
verify here, unequal means this host was enrolled against a different (usually rebuilt)
proxy. Neither end ever discloses the token, and the comparison happens inside the
aggregator — the tag is **never** exported to Prometheus, because `/metrics` and the
dashboard are unauthenticated by design.

Reading the tag does not help forge a proof: a proof signs `yuruna-control|proof|<expiry>`
and the tag signs a fixed message whose label segment is `tag`, so no expiry can produce
it. `utcNow` lets the aggregator spot the clock skew of item 6 without minting anything. A
host holding no token answers `tokenConfigured: false` with an empty tag; a runspace that
cannot load the verifier answers the same way, so a tag is never published by a host that
would refuse every proof anyway.

The route is deliberately outside the cross-site request guard and the loopback-or-proof
gate: it changes nothing, and the aggregator must be able to ask a host it may share no
token with. That is also why it is a **live** route rather than a field in
`host.registration.json` — that record is written once per cycle, so a host enrolled
between cycles (or one not running cycles at all) would report stale for hours.

## File serving: URL-prefix dispatch and deny-list

The status service's file-serving side dispatches by URL prefix:
`yuruna-repo/<rel>` maps to the repo working tree (deny-listed),
`runtime/<name>` to the runtime dir (pids, `status.json`, control flags,
`ipaddresses.txt`, `caching-proxy-service.txt`, `current-action.json`, `server.err`,
`yuruna-caching-proxy-service.yml`, `host.uuid`), `log/<name>` to the log dir (HTML
transcripts, OCR/screenshot debug, failure captures), and anything else to the
status dir (`index.html`, template, static assets, `perf/`, `extension/`,
`captures/`, `ssh/`). Each branch pins the resolved path under its mount root
with a StartsWith check, so traversal such as `runtime/../../../etc/passwd`
cannot escape. A unified deny-list then applies to every served path, so
secrets under `status/` (`vault.yml`, `transports.yml`, `events.log`, the SSH
private key, the caching-proxy-service state file) are blocked regardless of which
route reached them.

`archive/<cycle-folder>.zip` is dispatched *before* this by-prefix step and
never reaches it: it names a folder to pack rather than a file to serve, and it
carries its own grammar in place of the StartsWith pin (see below).

## Short per-cycle links: `/cycle/<number>`

`GET /cycle/004062` redirects (302) to that cycle's HTML transcript. It exists
because the transcript's real path repeats the cycle folder name twice, and that
name carries a timestamp and host id — too long to paste into a message, and
nothing a reader can recognize. The cycle number is the part an operator reads
off the runner console or a dashboard row, so it is the part the link uses.

The number is resolved against the log dir at request time: the recent cycles at
the top level first, then the dated `history.<date>/` rotation buckets. That
resolution lets one stable link survive the folder's lifecycle renames
(`<base>.incomplete` while running, `<base>` on clean close,
`<base>.aborted.<UTC>` after a crash-recovery sweep) and rotation moving the
folder later. The redirect is deliberately 302 with `no-store` rather than 301:
the target moves, so a cached redirect would pin a reader to a path that no
longer exists. An unknown or rotated-out number answers 404 with a plain-text
reason; only a 1-6 digit segment matches the route, so nothing else reaches the
directory lookup.

The outer runner prints one of these per finished cycle, e.g.
`Cycle 004062 - FAIL: http://192.168.7.101:8080/cycle/004062`.

## Sharing one cycle: `/archive/<cycle-folder>.zip` and `share-cycle.html`

A cycle folder is a tree — the HTML transcript, the events feed, the host
diagnostic, a subfolder per guest — so sending one to a colleague meant picking
files out of a directory listing one at a time. `GET
/archive/000724.2026-08-05.01-47-56.<hostId>.zip` packs the whole folder,
recursively, and serves it as one attachment-dispositioned file named
`<short host id>.<UTC start>T<UTC time>Z.zip`. Both halves of that name come
out of the folder, which already carries the host id and the cycle's UTC start.

Zip is the format because of where this file goes: out through a browser
download and into a mail attachment. Both stages recognize a `.zip` — download
reputation checks see a common type, mail scanners can read what is inside it,
and Windows and macOS open one with nothing installed — where a gzipped tarball
is an opaque blob that gets flagged or quarantined unread.

The URL leaf is matched against the cycle-folder grammar rather than sanitized.
There is exactly one legal form — one results folder directly under `log/`,
optionally with the `.incomplete` suffix a running cycle carries — so anything
else is a 404 rather than something to clean up, and no path separator survives
the match. Packing is in-process (`System.IO.Compression`), so the route needs
no archiver installed on the host, and each file is read with `ReadWrite`
sharing because a cycle that is still running is being written to while it is
packed. The archive is written to a temp file under the runtime dir and the
response serves that, so a pack that fails halfway answers 500 naming the
failure instead of a truncated download; the temp file is removed in a
`finally`, so a failed pack leaks nothing.

`share-cycle.html?cycle=log/<folder>` is the page that drives it, reached from
the **Share cycle results** link on the dashboard's cycle timeline by way of the
aggregator's `/go/cycle-share` (which resolves host and cycle exactly as
`/go/cycle` does, so the archive can never be a different cycle than the one the
click would have opened). One button packs the folder and hands it to the
operator's mail client, with subject `Yuruna Host <short id> at <UTC time>` and
the body `Yuruna cycle results are attached`. The body says so because the
fallback below leaves the attaching to the operator: a mail client that reads
its own draft for that word is the last warning before a message that promises
a file and carries none.

How it hands it over depends on what the browser offers. `navigator.share` can
carry the file itself, so where it is available the message arrives with the
archive attached. It is secure-context gated and the status service speaks plain
HTTP over the LAN, so on a lab host it is normally absent — then the archive
downloads and the draft opens with subject and body filled in, for the operator
to attach it. `mailto:` cannot carry an attachment ([RFC 6068
§5](https://www.rfc-editor.org/rfc/rfc6068#section-5)); that is a property of the
scheme, not a gap to work around, which is why the fallback asks for one manual
step instead of appearing to do it.

The route is open, like the file tree it archives: every byte in that archive is
already readable file by file from the same server, so gating the convenient
form of a read that is otherwise ungated would only be theatre.

## See also

- [pool-admin.md](pool-admin.md) — running a pool and the *Yuruna hosts* dashboard.
- [pool-storage.md](pool-storage.md) — the `lab-auth-token`-gated credential fetch used
  when syncing a new host's config.
- [caching.md](caching.md#caching-proxy-service--test-harness-operator-reference) — the caching-proxy-service VM that hosts Grafana and the
  pool-aggregator service.
- [test-config.md](test-config.md) — the host-side config keys, including the vault.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.07

Back to [Yuruna](../README.md)
