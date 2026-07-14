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
aggregator on the caching proxy, which mints a proof valid for **5 minutes** and hands it
to the host page in the URL **fragment** (`#yctl=…`). A fragment is never sent to a server
and never lands in an access log; only the page's own JavaScript reads it. The page keeps
it in `sessionStorage` **for that tab** and presents it as the `X-Yuruna-Control` header on
every control POST. The host recomputes the HMAC with its own copy of the token and accepts
a proof whose expiry is no more than **15 minutes** out.

A host with **no** `pool-auth-token` configured is not broken — it simply accepts control
from loopback only.

## Enabling remote control on a host

Every host **and** the caching proxy must hold the **same** token value: a proof minted by
the proxy can only be verified by a host that shares its token.

**1. Read the shared token from the caching proxy.**

```
ssh yuruna@<proxy> 'sudo cat /etc/yuruna/pool-auth.token'
```

**2. Store that value on the host.**

```
pwsh test/Set-PoolAuthToken.ps1 -Token '<shared-token>' -BounceStatusServer
```

The script is idempotent. It declares the `users.yml` vault key, stores the token, and
verifies the round-trip through the same lookup the control gate performs — so a key that
is stored under one name and read under another (a silent `403`) cannot happen.
`-BounceStatusServer` restarts the status server so the token takes effect immediately
instead of at the next cycle; `-WhatIf` previews without touching the vault.

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

> `forbidden: control route requires a loopback caller or a valid pool control proof`

- **You typed the host URL instead of following the dashboard link.** The proof lives in
  that tab's `sessionStorage`; re-enter through the dashboard host link.
- **The tab has been open longer than the proof's life.** Reload through the link.
- **The host's token does not match the proxy's.** Re-run `Set-PoolAuthToken.ps1` with the
  value from `/etc/yuruna/pool-auth.token`.
- **The host has no `pool-auth-token` vault entry** (or an empty vault key) — non-loopback
  control is refused by design until you set one.
- **The host clock is skewed** by more than the proof window, so the expiry check fails.
  Fix time sync on the host.

A different message — `forbidden: missing X-Yuruna request header` — is the cross-site
request guard, not the proof: it means a non-browser client (`curl`) called a control route
without that header.

## See also

- [pool-admin.md](pool-admin.md) — running a pool and the *Yuruna hosts* dashboard.
- [pool-storage.md](pool-storage.md) — the `pool-auth-token`-gated credential fetch used
  when syncing a new host's config.
- [caching-proxy.md](caching-proxy.md) — the caching-proxy VM that hosts Grafana and the
  pool aggregator.
- [test-config.md](test-config.md) — the host-side config keys, including the vault.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.14

Back to [Yuruna](../README.md)
