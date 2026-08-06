# test.config.yml — runner configuration reference

`test/test.config.yml` is the per-host runner configuration. On first run it is
bootstrapped from `test/test.config.yml.template` (then git-ignored, so your edits
and secrets stay local). Edit it directly, or through the status-page editor
(`config.html`), a schema-driven form that loads/saves via
`GET`/`POST /control/test-config`. The template carries short comments on many
non-obvious knobs and reconciliation renders those into the live file (a save
from the editor round-trips through `ConvertTo-Yaml` and strips them until the
next reconciliation); this document is the fuller reference.

Top-level sections: `configService`, `downloadAgentService`, `guestSequence`,
`logLevel`, `networkStorage`, `notification`, `pool`, `repositories`,
`statusService`, `testCycle`, `vmCommunication`, `vmImage`, `vmStart`. Most are
self-describing; the ones carrying non-obvious behavior are documented below.

## Key names

Only the current key names are accepted: `Test-Config.ps1` fails a config
carrying a retired one and names its replacement, and the pre-cycle gate runs
the same check, so a stale file stops the cycle at startup instead of being
half-honored. To convert a whole file in one step — key renames, the
minutes/hours-to-seconds value conversions, and the `autoRemediation` nesting
move — run:

```
pwsh tools/Update-TestConfigNaming.ps1
```

It keeps the previous file alongside as `test.config.yml.pre-renaming` (which
holds the same secrets the live file does, and is git-ignored for that reason),
is a no-op on an already-converted file, and refuses to guess when a key is
present in both forms. The retired-key table it reads is
`test/modules/Test.ConfigNaming.psm1`; the rules behind the names are in
[naming conventions](design/naming.md).

## Template reconciliation

`test.config.yml.template` is the schema source of truth. `Test-Config`
fully reconciles the live `test.config.yml` to it
(`Sync-TestConfigToTemplate` in `Test.ConfigSync.psm1`): missing template
fields are added with empty/default values; keys the template no longer
defines are removed (a populated removed key first backs the previous file
up to `test.config.yml.backup`); and the file is rewritten with all map
keys and scalar-array elements in alphabetical order so it is byte-stable
and diff-friendly. Operator values that still map are kept and the
out-of-band `secrets` node is untouched.

Outcomes: already canonical → PASS with no rewrite; fields added/re-sorted
→ PASS listing new fields to fill in; populated keys dropped from the
schema → WARN or FAIL per `-OnConfigSchemaDrift` (recover from the
`.backup`). At cycle start the runner runs the same reconciliation via
`Update-TestConfigFromTemplate`, which additionally STOPS the run when a
populated value no longer maps; `-ApplyConfigMigration` runs that
stop-on-unmappable variant immediately.

### The file keeps the template's comments

The reconciled file is rendered **from the template text**, not regenerated
from a parsed object: a `ConvertFrom-Yaml`/`ConvertTo-Yaml` round-trip drops
every comment, so the operator's file would lose every per-knob explanation
the template carries. The template is already both the schema and the
canonical ordering, so it doubles as the rendering skeleton — its comments,
blank lines and key order come through verbatim, with the operator's value
substituted wherever the file has one.

Keys the template no longer defines are written back as commented-out
entries under an `# --- Obsolete keys` block instead of only living in the
`.backup`:

```yaml
# --- Obsolete keys -------------------------------------------------------
# Not defined by test.config.yml.template, so the runner ignores them. Kept
# here (commented) so no value is lost: move anything still needed into the
# keys above, then delete these lines.
#   configService.isEnabled: true
```

A parked key is inert (the runner parses YAML, and these are comments) and
the retired-key check skips comment lines, so it stops failing validation
while its value stays in view for hand-migration. Entries parked by an
earlier run are carried forward, and rendering is deterministic — a second
run reproduces the file byte for byte and writes nothing.

Two consequences: the operator-managed `secrets` node is emitted as real YAML
(never commented) so credentials survive the rewrite; and comments an operator
adds by hand outside the obsolete block are not preserved, because the
template — not the previous file — is the skeleton.

## configService — host mTLS credential service

`configService.enabled` / `configService.port` (default `8443`) control the
per-host **config service** — the mTLS endpoint that serves NAS credentials to
the VMs this host provisions so they don't have to ship in each seed. When
enabled, the runner ensures it per cycle (given a Config CA exists); VMs fetch
over the `yuruna-config-fetch.sh` mTLS path and fall back to baked creds only
if it is unreachable.

## downloadAgentService — the pool-wide image downloader

The **download-agent service** VM (`yuruna-download-agent-service`) keeps guest
images on the pool share fresh, so the lab pulls an image from its origin once
instead of once per host. It needs the **pool** tier below configured — that
share is where the Download pool lives — and it is brought up by
`install/setup.ps1` or `pwsh test/Start-DownloadAgentServiceVM.ps1`. Operator
guide: [download-agent.md](download-agent.md); the service section of
[pool-admin.md](pool-admin.md#download-agent-service).

| Key | Type | Meaning |
|---|---|---|
| `autoSeed` | bool | Pre-download the stable image families for the host types the pool aggregator reports, instead of waiting for a host to ask. Default `true`; `false` leaves the pool demand-driven and manual. |
| `enabled` | bool | Master switch. `false` makes `install/setup.ps1` skip the agent's reset+start pair, so a re-run neither rebuilds nor starts it. An absent key reads as enabled. Running `test/Start-DownloadAgentServiceVM.ps1` by hand still starts it — asking for it explicitly overrides the setup default. |
| `freshnessSeconds` | int | How long an image stays fresh after its last successful **direct** origin check. Default `86400` (24 h). |
| `prefetchLeadSeconds` | int | The scanner acts on an image whose freshness expires within this window, rather than waiting for it to go stale. Default `7200` (2 h). |
| `scanIntervalSeconds` | int | How often the agent walks the pool looking for work. Default `900` (15 min). |

The four tunables are read at **VM-create time** and baked onto the daemon's
flag line in the guest seed, so changing one takes effect on the next
stop→start of the agent VM, not on the next cycle. The same defaults are
hardcoded in the daemon (`server/internal/config`), so a host with no
`downloadAgentService` block and a bare daemon behave identically.

## networkStorage — optional NAS-backed durable tiers

Hosts (like guests) are **reimageable at any time**, so local storage stays local,
fast, and ephemeral; optional Network-Attached Storage shares are the durable tier.
`networkStorage` carries the paths/credentials for two **independent** tiers: the
**pool** (cycle-output replication, keys `pool*`; its on/off switch is the pool
behavior `pool.networkReplicate`) and the **stash** (the stash service's own
durable store, keys `stash*`). They use **separate NAS shares and separate NAS
accounts** — the stash does not reuse the pool's share or credential.

When `pool.networkReplicate` is true, each cycle's pool output is copied to
`<poolStorageLocalPath>/<hostId>/` on the share over **SMB3** (uniform across
Windows/macOS/Linux). The squid cache is **not** replicated (rebuildable; left to
squid pools). The stash tier has no replicate flag — the stash daemon writes its
files directly to its own share.

This section is the parameter reference; for the architecture (the async,
fail-fast, atomic, backlog-draining replicator), the on-share layout, the Linux
passwordless-sudo precondition, and operations/troubleshooting, see
[pool-storage.md](pool-storage.md).

### Pool storage (cycle-output replication)

| Key | Type | Meaning |
|---|---|---|
| `pool.networkReplicate` | bool | Master switch for the **pool** tier — it lives under the **`pool:`** node (a pool behavior, not a path/credential). **Default `false`.** `false`, or any of the `networkStorage.pool*` paths empty, ⇒ pool replication OFF (no mount, no copy). |
| `poolStorageNetworkPath` | string | The pool SMB share. Windows `\\server.local\work`; macOS/Linux `//server.local/work` (either form is accepted and normalized). |
| `poolStorageNetworkUser` | string | The **single** SMB account used for **every** pool connection to the share — host-side cycle replication (the host mounts) **and** the caching-proxy-service guest's service replication alike. **Also the vault key** its password is fetched under (see below). Scope it **storage-only** on the NAS (write access to `poolStorageNetworkPath` and nothing else). |
| `poolStorageLocalPath` | string | The host's pool mount point. Windows `'y:'` (**must be quoted** — see below) · macOS `~/Shares/ypool-nas` · Linux `/mnt/ypool-nas`. |

Examples — only `poolStorageLocalPath` and the `poolStorageNetworkPath` slash style differ per
platform (the `stash*` keys, documented below, follow the same per-platform rules):

**Windows:**
```yaml
pool:
  networkReplicate: true
networkStorage:
  poolStorageNetworkPath: \\server.local\work
  poolStorageNetworkUser: yuruna-pool
  poolStorageLocalPath: 'y:'
```

**macOS:**
```yaml
pool:
  networkReplicate: true
networkStorage:
  poolStorageNetworkPath: //server.local/work
  poolStorageNetworkUser: yuruna-pool
  poolStorageLocalPath: ~/Shares/ypool-nas
```

**Ubuntu (Linux):**
```yaml
pool:
  networkReplicate: true
networkStorage:
  poolStorageNetworkPath: //server.local/work
  poolStorageNetworkUser: yuruna-pool
  poolStorageLocalPath: /mnt/ypool-nas
```

macOS expands a leading `~/` to `$HOME` — keep the **slash** (`~/Shares/ypool-nas`, not
`~Shares/ypool-nas`): only `~/…` is expanded, a tilde glued to the next character is left
literal and the mount silently fails. The macOS/Linux mount point needs no quoting
(no trailing colon). On **Ubuntu/Linux** the mount also requires
**passwordless `sudo` for `mount`** (an `/etc/sudoers.d` drop-in) — see
[pool-storage.md](pool-storage.md).

> **YAML quoting — quote a Windows drive-letter `poolStorageLocalPath`/`stashStorageLocalPath`.**
> Write `poolStorageLocalPath: 'y:'`, not `poolStorageLocalPath: y:`. Unquoted, YAML reads the
> trailing colon in `y:` as the start of a nested mapping and the **entire
> `test.config.yml` fails to parse** (`While scanning a plain scalar value, found
> invalid mapping`) — so the runner can't read *any* config, not just
> networkStorage. Single quotes are the safe choice for any value with a trailing
> colon or backslashes. `poolStorageNetworkPath: \\server.local\work` works unquoted because
> YAML treats backslashes in a plain scalar literally, but `'\\server.local\work'` (single
> quotes) is equally fine.

### Stash storage (the stash service's own durable store)

The **stash service** uses an **isolated** storage tier: its own NAS share, its
own NAS account (the `stash*` keys), and **no replicate flag** — the stash daemon
writes files directly. All three `stash*` keys must be set for the stash store to
be active; leave them empty to leave the stash store off. The reader is
`Get-YurunaStashStorageConfig` (the pool tier's reader is
`Get-YurunaPoolStorageConfig`).

| Key | Type | Meaning |
|---|---|---|
| `stashStorageNetworkPath` | string | The stash SMB share — its **own** share, e.g. Windows `\\ystash-nas\work\yuruna.stash`; macOS/Linux `//ystash-nas/work/yuruna.stash` (either form is accepted and normalized). |
| `stashStorageNetworkUser` | string | The stash's **own** SMB account (e.g. `yuruna-stash`), distinct from `poolStorageNetworkUser`. **Also the vault key** its password is fetched under (see below). Scope it **storage-only** on the NAS (write access to `stashStorageNetworkPath` and nothing else). |
| `stashStorageLocalPath` | string | The host's stash mount point. Windows `'z:'` (**must be quoted** — same drive-letter trap as the pool) · macOS `~/Shares/yuruna.stash` · Linux `/mnt/yuruna.stash`. |

Example (Windows; macOS/Linux follow the same slash/mount-point rules as the pool):

```yaml
pool:
  networkReplicate: true
networkStorage:
  poolStorageNetworkPath: \\ypool-nas\work\yuruna.pool
  poolStorageNetworkUser: yuruna-pool
  poolStorageLocalPath: 'y:'
  stashStorageNetworkPath: \\ystash-nas\work\yuruna.stash
  stashStorageNetworkUser: yuruna-stash
  stashStorageLocalPath: 'z:'
```

The passwords are **never** stored in `test.config.yml` — they live in the vault.

### Setting the SMB passwords in the vault

Each SMB password must match the NAS exactly, so it is **never** auto-generated —
you set it once, per host. Because the pool and stash use **separate
accounts**, you set **two** passwords: one for `poolStorageNetworkUser` and one for
`stashStorageNetworkUser`. The vault
(`test/status/extension/authentication/vault.yml`) is git-ignored, plaintext, and
persists across cycles.

**Already done for local storage.** If the shares live on this machine and were
created by `pwsh test/New-LocalLabStorage.ps1`, both passwords are already
generated, mapped to a `vaultKey`, and stored — there is nothing to do here.
The rest of this section is for a NAS or a separate file server, whose accounts
and passwords are owned by that device.

**Easiest (interactive):** run `pwsh test/Test-Config.ps1` from a terminal. When
the pool account has no usable credential, the validator asks for the
`poolStorageNetworkUser` password (typed twice, not echoed), maps the `vaultKey` in
`users.yml`, stores the password, and re-checks — so the run ends with the gate
satisfied instead of a failure to act on later. Run non-interactively (the
unattended runner, a redirected stdin) it never prompts and just reports the
failure. The `stashStorageNetworkUser` password is still set by hand, below.

**Recommended (fail-safe):** map a `vaultKey` so the harness never silently
auto-generates a wrong password, then store the value. Do this for **both** users.

1. In `test/status/extension/authentication/users.yml`, add/edit each user with a
   **non-empty** `vaultKey`:
   ```yaml
   yuruna-pool:
     localOsUser: yuruna-pool
     corporate:   { domain: "", sam: "", upn: "" }
     vaultKey:    "smb.yuruna-pool"
     localOsPasswordRef: ""
   yuruna-stash:
     localOsUser: yuruna-stash
     corporate:   { domain: "", sam: "", upn: "" }
     vaultKey:    "smb.yuruna-stash"
     localOsPasswordRef: ""
   ```
   A non-empty `vaultKey` disables auto-generation: `Get-Password` returns the
   stored value or fails loudly if it is missing (so a random password can never
   silently break the mount).
2. Store each password under its vault key:
   ```powershell
   Import-Module test/extension/authentication/default.psm1
   Set-Password -Username 'smb.yuruna-pool'  -NewPassword '<pool NAS password>'
   Set-Password -Username 'smb.yuruna-stash' -NewPassword '<stash NAS password>'
   ```

**Quick alternative (no users.yml edit):** store directly under each username —
`Set-Password -Username 'yuruna-pool' -NewPassword '<pool NAS password>'` and
`Set-Password -Username 'yuruna-stash' -NewPassword '<stash NAS password>'`. Works
because an unset, vaultKey-less user resolves to the username as its own vault key.
Caveat: if you forget to set one, `Get-Password` auto-generates a random password
and that mount fails with bad credentials — the recommended path above prevents
that.

Verify with `pwsh test/Test-Config.ps1`. Beyond checking that mapped vault
entries exist, when the server is reachable it **actively mounts `poolStorageLocalPath`
and creates the per-host folder `<poolStorageLocalPath>/<hostId>`** — so a wrong password,
a share-name typo, missing Linux passwordless sudo, or a read-only share surfaces
as a gate failure (and, with `networkReplicate: true`, **stops the cycle from
starting**) instead of replication silently never happening. See
[pool-storage.md](pool-storage.md#operating--troubleshooting). Password
characters: `a-z A-Z 0-9` and `! @ # $ % ^ & * ( ) - _ = +`; avoid quotes,
backslash, and YAML/shell separators (``: , < > | ; ~ ` ``).

### Extension services (pool registry) — where THIS host's stash actually is

The `stash*` keys above say this host could build a stash service. A cycle
depends on a different question: which stash service will this host be **sent
to**, and does it answer? That address comes from the pool, so a registration
nobody can reach stops the cycle in its warm-up — after a config check that
reported everything fine.

`Test-Config.ps1`'s **Extension services (pool registry)** section asks the
aggregator (`/api/v1/extension-hosts`) for every stash service the pool knows,
and probes each from this host:

- a registration the **pool itself refuses** (an address it cannot reach — the
  usual cause is a stash VM on a hypervisor-private network: the macOS shared
  vmnet, a Hyper-V Default Switch, libvirt's `virbr0`) is reported as a WARN
  naming the refused address and the reason. Fix it by rebuilding that stash VM
  on a **bridged** interface;
- a registration the pool still advertises but **this host** cannot reach is a
  WARN too: the pool can route to it and this host cannot, so check this host's
  route rather than that VM;
- **no** stash service answering at all is a WARN naming that consequence — a
  project that uploads build output has nowhere to put it, and its cycle stops
  before the provisioning stages. Advisory rather than a gate failure on
  purpose: a FAIL here refuses to start the runner loop, and a service on
  another machine being down must not wedge a lab that would otherwise keep
  cycling and recover.

Several hosts each running their own stash service is normal and reports as
several PASS lines. A host with no caching-proxy service has no aggregator to
ask; the section says so and skips.

## pool — optional multi-host pool intent (default-off)

Joins this host to a **pool**: it PULLs the slow-changing pool intent (membership
+ `desiredState`) from a LAN git repo on the caching-proxy-service each cycle, and the
pool-aggregator service labels its telemetry by the pool it belongs to. **Default-off** —
with `enabled: false` (or no `pool` block) the host behaves exactly as a single
host. Creating pools + assigning test sequences (the operator guide): [pool-admin.md](pool-admin.md).

| Key | Type | Meaning |
|---|---|---|
| `enabled` | bool | Master switch. **Default `false`.** `false` ⇒ no pull, no behavior change. |
| `intentGitUrl` | string | Read-only URL of the bare intent repo on the proxy, e.g. `http://caching-proxy-service.local/pool-intent.git`. Empty ⇒ off. |
| `localClonePath` | string | Where to keep the pulled clone. Empty ⇒ `<runtime>/pool-intent` (default). |
| `pullTimeoutSeconds` | int | Wall-clock cap on each bounded git fetch. Default `30`. |

There is **no `poolId` here** — membership is the single source of truth in the
intent store's `pools.yml` `members[]` (the operator assigns this host's stable
`hostId` via `Add-HostToPool.ps1`); the runner finds its own pool by locating its
`hostId` there. An unreachable intent store degrades gracefully: the host keeps
cycling as a single host (it never blocks on the pull). `desiredState`
(`run`/`paused`/`drain`) gates the cycle — `paused` holds after the in-flight
cycle, `drain` stops after the current one — and any **test-sets** the pool
assigns drive what this host runs.

## testCycle.autoRemediation

```yaml
testCycle:
  autoRemediation:
    enabled: false
    maxAttemptsPerCycle: 2
```

Default-off self-heal. With `enabled: true`, the outer failure-pause ends early
(auto-retry) for a clearly-safe transient failure class (`wait_timeout`,
`instrumentation_failure`, `network_timeout`, `host_io_blocked`) instead of
waiting up to the failure-pause cap for a human commit. Capped per
consecutive-failure streak (`maxAttemptsPerCycle`) so a deterministic failure
still escalates to the normal wait-for-human pause after that many auto-retries.
A pool may override the whole block through its `config.testCycle`.

## vmStart.cachingProxyIp — external cache source (probed first)

Names the external caching-proxy service this host should route guest installs
through. At cycle start `Resolve-CachingProxyServiceEndpoint` (Test.CachingProxyService)
probes this value **first**; it wins when its squid HTTP port `:3128`
answers. `$Env:YURUNA_CACHING_PROXY_SERVICE_IP` is the session-scope **fallback**,
probed only when this key is empty or its probe fails. The winner (from
either source) is published into the env var for the rest of the cycle.
When both sources fail their probes, the env var is cleared and local
discovery runs — a host with its own cache VM falls back to it; a host
with none proceeds without a caching-proxy service.

Empty string means absent (fall through to the env var / local
discovery). The status-page editor validates the value at save time:
it must parse as an IPv4/IPv6 address **and** answer on TCP `:3128`,
so a dead IP is rejected before it is persisted. Full cache-source
story: [caching.md](caching.md#external-cache-override).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.06

Back to [Yuruna](../README.md)
