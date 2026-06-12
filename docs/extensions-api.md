# Extensions API

The harness defers four classes of swappable behavior to **extension
areas** under [`test/extension/`](../test/extension/) — authentication,
notification transports, caching-proxy log parsing, and host-side 
artifact stashing. An area is a directory with one or more `.psm1` 
files plus a small YAML config naming the active set.

Loader: [`test/modules/Test.Extension.psm1`](../test/modules/Test.Extension.psm1).

## Areas today

| Area                   | Active default | What it controls |
|------------------------|----------------|------------------|
| `authentication`       | `default`      | `${ext:authentication.GetPassword(<user>)}` / `NewRandomPassword()` / `SetPassword()` — vault read/write for sequences. The `default` extension stores per-cycle ephemeral test-VM passwords in plaintext YAML **by design**; see [Authentication — Test-harness vault threat model](authentication.md#test-harness-vault--threat-model) for the trust boundary. Wire a different extension (DPAPI / keyring / external secret manager) before driving any production system from a sequence. |
| `notification`         | `default`      | `Send-Notification -EventCode -EventMessage`; iterates configured transports (Resend, SMTP, etc.). |
| `caching-proxy-parser` | `default`      | Maps a Squid access-log line to a structured record for the test/perf log. Ships a Go sidecar (`main.go` + `caching-proxy-parser.service`) for inside-the-VM parsing; the PowerShell `default.psm1` is the host-side wrapper. |
| `stash-service`        | `default`      | Receives SCP'd guest artifacts (diagnostic bundles, screenshots) into a host-side stash. Ships a Go daemon under [`server/`](../test/extension/stash-service/server/) plus the PowerShell wrapper `default.psm1`. See [`docs/stash-service.md`](stash-service.md) for the contract. |

## Filesystem layout

```
test/extension/
├── authentication/
│   ├── authentication.config.yml       # active: ['default']
│   ├── authentication.contract.yml     # methods + parameter shape this area exports
│   ├── users.yml.template              # vault seed: harness copies on first cycle
│   └── default.psm1                    # exports Get-Password / Set-Password / Initialize-VaultConnection
├── notification/
│   ├── notification.config.yml         # active: ['default']
│   ├── notification.contract.yml       # methods this area exports
│   ├── transports.yml.template         # transport-credentials seed (e.g. Resend API key)
│   └── default.psm1                    # exports Send-Notification
├── caching-proxy-parser/
│   ├── caching-proxy-parser.config.yml # active: ['default']
│   ├── caching-proxy-parser.contract.yml
│   ├── caching-proxy-parser.service    # systemd unit for the in-VM Go sidecar
│   ├── go.mod, main.go                 # Go sidecar source (built into the proxy VM)
│   ├── README.md
│   └── default.psm1                    # host-side wrapper
└── stash-service/
    ├── stash-service.config.yml        # active: ['default']
    ├── server/                         # Go daemon (main.go + internal/{...})
    └── default.psm1                    # host-side wrapper
```

The `<area>.contract.yml` files declare the methods + parameter shape
each area's PowerShell module must export. `Resolve-ExtensionMethod`
does not enforce them today (the contract is implicit in the callers);
they exist as the durable source-of-truth for the JSON Schema
follow-on noted in [Adding a new area](#adding-a-new-area).

Per-area state (vault file, transport credentials) lives under
[`test/status/extension/<area>/`](../test/status/) — git-ignored, never
shipped.

## The loader API

```
Resolve-ExtensionAreaDir   -Area
Read-ExtensionConfig       -Area
Get-ActiveExtensionName    -Area   # ALWAYS wrap in @(...) — single-entry config unrolls to scalar
Import-Extension           -Area [-RequireSingle]
Resolve-ExtensionMethod    -Area -ExtensionName -Method
```

`Resolve-ExtensionMethod` is what makes the `${ext:area.Method(...)}`
substitution in sequence YAML work — it maps the CamelCase method name
to the exported `Verb-Noun` form (e.g. `GetPassword` → `Get-Password`)
and looks up the loaded module by **absolute path**, not module name.
Two areas can ship a `default.psm1`; the path-based lookup means each
area's exports are unambiguous.

## Why `@(Get-ActiveExtensionName)` wrap

PowerShell's pipeline unrolls a single-element array to a scalar. A
config with one `active:` entry returns the string `'default'`; indexing
`$names[0]` returns the character `'d'`, not the name. Always:

```
$names = @(Get-ActiveExtensionName -Area 'authentication')
$extName = $names[0]
```

## Why `Import-Extension` matches by absolute path

When two areas ship a `default.psm1`, both modules register under the
same PowerShell module name `'default'`. `Get-Module -Name default`
returns whichever was imported last, so `Get-Command -Module default
Get-Password` resolves to whichever module loaded most recently — not
the one for the area the caller intended. `Resolve-ExtensionMethod`
matches modules by absolute `.psm1` path instead, so the intended
exports are always found.

## Adding a new extension to an existing area

1. Create `<extname>.psm1` in `test/extension/<area>/`.
2. Add `<extname>` to the `active:` list in `<area>.config.yml`.
3. The loader imports it on the next cycle; sequence YAML references
   to `${ext:<area>.Method(...)}` route to the new module if it
   exports `Method`.

For `notification`, multiple active extensions iterate in declaration
order — every transport sees every event. For `authentication`, the
loader expects **exactly one** active extension and throws on
ambiguity (`-RequireSingle`).

## Adding a new area

1. Create `test/extension/<newarea>/` with a `default.psm1` and a
   `<newarea>.config.yml`.
2. Add the area to the
   [capability matrix](capability-matrix.md) by simply existing —
   `Get-CapabilityExtensionArea` discovers areas by directory, not
   by a hardcoded list.
3. Document the contract the area's `.psm1` files must export. Today
   each area has its own implicit contract enforced by the calling
   code; a future improvement is to publish JSON schemas alongside
   the configs (the
   [`test/schemas/`](../test/schemas/) folder already hosts
   `extension-config.schema.yml` for the common envelope).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.12

Back to [Yuruna](../README.md)
