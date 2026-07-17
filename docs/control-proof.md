# Control proof — fixing "follow guidance at https://yuruna.link/control-proof"

> You opened a host's status page, tried to **start a cycle, pause a step, or save its
> config**, and got **`Save failed: follow guidance at https://yuruna.link/control-proof`**
> (or a bare `403`). This page is the fix.

## Why it happened

Changing a host — starting cycles, pausing steps, rewriting its `test.config.yml` — is
allowed only from **the host itself** (`http://localhost:<port>`) or with a valid **control
proof**: a short-lived credential the pool dashboard hands your browser tab when you open a
host through its *Yuruna hosts* link. Viewing a host is always open; driving one needs the
proof, and your tab had neither.

## Fix it, in order

1. **Re-open the host through the dashboard link.** Open the *Yuruna hosts* dashboard and
   click the host's link — don't type or bookmark the host's `http://<ip>:<port>` URL.
   Arriving through the link is what delivers the proof (in the URL fragment, `#yctl=…`);
   typing the URL never does. This covers the two most common causes: a bookmarked/hand-typed
   URL, and a **proof that expired** (a minted proof lasts about **5 minutes** — just reload
   through the link).

2. **Still failing? The host and the dashboard don't share the same token.** Every host and
   the caching proxy must hold the *same* `pool-auth-token` — a proof minted by the proxy can
   only be verified by a host that shares its token. Read the proxy's value and store it on
   the host:

   ```
   ssh yuruna@<proxy> 'sudo cat /etc/yuruna/pool-auth.token'
   pwsh test/Set-PoolAuthToken.ps1 -Token '<shared-token>' -BounceStatusServer
   ```

   A **stale caching-proxy / dashboard VM** shows the same symptom: an old aggregator can mint
   a proof this host cannot verify, or hand off the link without the `#yctl=…` fragment at all.
   If the token matches and the link still won't drive the host, update the caching-proxy VM
   (see [caching-proxy-migration.md](caching-proxy-migration.md)).

3. **The host may have no token at all.** With no `pool-auth-token` configured, a host accepts
   control from `http://localhost:<port>` **only**, by design. Set one with the command above,
   or drive it from the host console.

4. **Check the host clock.** The proof carries an expiry; if the host's time is skewed past the
   proof window every proof looks expired. Fix time sync on the host.

## Or just drive it from the host

On the host itself, `http://localhost:<port>` has full control with no token and no proof —
the quickest path when you only need to make one change.

## Full model and setup

[control-routes.md](control-routes.md) — who can drive a host, where the proof comes from, and
the one-time `pool-auth-token` setup for a new host.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.17

Back to [Yuruna](../README.md)
