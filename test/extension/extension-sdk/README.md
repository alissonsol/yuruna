# extension-sdk

The shared half of the Yuruna extension interface: the things every extension
service needs, written once -- three Go packages for the daemon, and one that
carries the browser runtime its UI is built on.

| Package | What it is |
|---|---|
| [`beacon`](beacon/) | The presence beacon. A hello at startup (retried on a doubling catch-up cadence until it first lands), a re-announce every interval, an `active:false` goodbye at shutdown &mdash; so the dashboard's **Extension hosts** row survives the owning host's status service being down. |
| [`pool`](pool/) | The read client for the pool-aggregator service: `Status`, `ExtensionHost(s)`, `ExtensionTarget`, `Healthz`, plus `Get`/`GetURL` for the routes it does not type. One TLS posture, one timeout policy, one snapshot cache, and `SanitizeBaseURL` applied to every URL-valued field a response carries. |
| [`labgate`](labgate/) | The write gate. A session unlocked with the dashboard's rotating Lab token, or the internal authentication key as a bearer, in front of any route that changes host or pool configuration. Ships `Require`, `RequireBearer`, `HandleLogin` and `Session`. |
| [`webui`](webui/) | The browser assets every service UI shares, embedded and handed over through `Asset(name)`. Today that is [`yuruna.core.js`](webui/assets/yuruna.core.js): the page chrome (header, menu, footer, countdown), the JSON client, the table furniture, and the shims the browser baseline needs. |

Each package is self-contained: none imports another, and none imports anything
outside the standard library.

## The browser runtime, and why it is a Go package

A service embeds its own pages and page scripts and serves them as before; it
asks `webui` only for the names it does not have, so a service overrides a
shared asset simply by shipping a file of that name itself.

The indirection through Go exists because `//go:embed` cannot reach outside a
module. The shared assets could not be referenced in place from three separate
service modules, so they are embedded HERE and handed over across the boundary:

```go
shared, contentType, ok := webui.Asset("yuruna.core.js")
```

That there is one copy is the point, and it is not only about duplication.
These assets carry a browser baseline -- Safari iOS 9.3, see the [browser
baseline](../../../docs/definition.md#defining-the-status-page-browser-baseline)
-- and a service holding its own copy of the runtime is a service that can fall
off that baseline on its own. The failure is silent: an iOS 9 parser rejects a
file carrying one arrow function outright, so the page serves its static shell
and renders as merely empty. `tools/Invoke-Es5Check.ps1` is what holds the line;
run it before shipping a change to anything under `webui/assets/`.

## Why the services stage it instead of vendoring it

There are no copies. Each service is its own Go module, compiled **inside its
own VM** at bring-up, and the bring-up stages this directory beside `server/`
in the build dir so the module resolves with

```
require yuruna.com/test/extension/extension-sdk v0.0.0
replace yuruna.com/test/extension/extension-sdk => ../extension-sdk
```

One copy of this code, shared by every service that asks for it.

Mirroring it into each `server/internal/yex/` instead would mean 4,290
duplicated lines kept honest only by a byte-identity check. A `go.work` file is
no substitute for the staging: only `server/` and this directory are copied
into the guest's build dir, so a workspace file left in the enlistment never
reaches the build that needs it. (In the enlistment itself the layout differs
-- the SDK is one directory further out than `../extension-sdk` -- which is why
`tools/Invoke-GoTest.ps1` reproduces the guest's arrangement in a throwaway
directory rather than running the modules where they sit.)

`Test.ExtensionService.Tests.ps1` guards the three pieces that make it resolve:
no service carries a reintroduced mirror, every service that imports the SDK
also requires and replaces it, and every guest bring-up stages the SDK beside
`server/`. A service missing any one of them fails to build ON THE GUEST, which
is why the check lives here rather than in a build script.

## Using it

```go
import (
    "yuruna.com/test/extension/extension-sdk/beacon"
    "yuruna.com/test/extension/extension-sdk/labgate"
    "yuruna.com/test/extension/extension-sdk/pool"
)

// Presence: appear in the dashboard's Extension hosts table. The interval must
// stay under the aggregator's five-minute health grace -- a re-announce is also
// how a renumbered service reports its new address.
bcn := beacon.New(aggregatorURL, hostID, "myservice", uiPort, 2*time.Minute)
if bcn.Enabled() {
    go bcn.Run(ctx)
}

// Reads: ask the information provider about the rest of the lab.
p := pool.New(pool.Options{BaseURL: aggregatorURL})
status, err := p.Status(ctx)
where, err := p.ExtensionHost(ctx, "stash-service") // ErrAreaNotServed when nobody does

// Writes: the lab-token gate on anything that changes configuration.
gate := labgate.New(labgate.Options{
    AggregatorURL: aggregatorURL,
    BearerToken:   authToken,
    CookieName:    "yuruna_myservice",
    Audit:         auditUnlock,
})
mux.HandleFunc("POST /api/login", gate.HandleLogin)
mux.HandleFunc("POST /api/change", gate.Require(handleChange))
```

## Building

```
go vet ./... && go test ./...
```

There is nothing to mirror afterwards -- the services resolve this module by
path. Confirm the wiring still holds:

```
pwsh -NoProfile -File test/modules/Test.ExtensionService.Tests.ps1
pwsh -NoProfile -File tools/Invoke-GoTest.ps1
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Back to [Extensions API](../../../docs/extensions-api.md)
