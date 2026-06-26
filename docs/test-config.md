# test.config.yml — runner configuration reference

`test/test.config.yml` is the per-host runner configuration. On first run it is
bootstrapped from `test/test.config.yml.template` (then git-ignored, so your edits
and secrets stay local). Edit it directly, or through the status-page editor
(`test.config.html`), a schema-driven form that loads/saves via
`GET`/`POST /control/test-config`. The template is intentionally **comment-free**;
this document is its reference (the editor + `ConvertTo-Yaml` round-trip strips
inline comments anyway).

Top-level sections: `guestSequence`, `logLevel`, `networkStorage`,
`notification`, `pool`, `repositories`, `statusService`, `testCycle`,
`vmCommunication`, `vmImage`, `vmStart`. Most are self-describing; the ones
carrying non-obvious behavior are documented below.

## networkStorage — optional NAS-backed durable tiers

Hosts (like guests) are **reimageable at any time**, so local storage stays local,
fast, and ephemeral; optional Network-Attached Storage shares are the durable tier.
`networkStorage` carries the paths/credentials for two **independent** tiers: the
**pool** (cycle-output replication, keys `pool*`; its on/off switch is the pool
behavior `pool.networkReplicate`) and the **stash** (the stash service's own
durable store, keys `stash*`). They use **separate NAS shares and separate NAS
accounts** — the stash no longer reuses the pool's share or credential.

When `pool.networkReplicate` is true, each cycle's pool output is copied to
`<poolLocalPath>/<hostId>/` on the share over **SMB3** (uniform across
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
| `poolNetworkPath` | string | The pool SMB share. Windows `\\server.local\work`; macOS/Linux `//server.local/work` (either form is accepted and normalized). |
| `poolNetworkUser` | string | The **single** SMB account used for **every** pool connection to the share — host-side cycle replication (the host mounts) **and** the caching-proxy guest's service replication alike. **Also the vault key** its password is fetched under (see below). Scope it **storage-only** on the NAS (write access to `poolNetworkPath` and nothing else). |
| `poolLocalPath` | string | The host's pool mount point. Windows `'y:'` (**must be quoted** — see below) · macOS `~/Shares/ypool-nas` · Linux `/mnt/ypool-nas`. |

Examples — only `poolLocalPath` and the `poolNetworkPath` slash style differ per
platform (the `stash*` keys, documented below, follow the same per-platform rules):

**Windows:**
```yaml
pool:
  networkReplicate: true
networkStorage:
  poolNetworkPath: \\server.local\work
  poolNetworkUser: yuruna-pool
  poolLocalPath: 'y:'
```

**macOS:**
```yaml
pool:
  networkReplicate: true
networkStorage:
  poolNetworkPath: //server.local/work
  poolNetworkUser: yuruna-pool
  poolLocalPath: ~/Shares/ypool-nas
```

**Ubuntu (Linux):**
```yaml
pool:
  networkReplicate: true
networkStorage:
  poolNetworkPath: //server.local/work
  poolNetworkUser: yuruna-pool
  poolLocalPath: /mnt/ypool-nas
```

macOS expands a leading `~/` to `$HOME` — keep the **slash** (`~/Shares/ypool-nas`, not
`~Shares/ypool-nas`): only `~/…` is expanded, a tilde glued to the next character is left
literal and the mount silently fails. The macOS/Linux mount point needs no quoting
(no trailing colon). On **Ubuntu/Linux** the mount also
requires **passwordless `sudo` for `mount`** (an `/etc/sudoers.d` drop-in) — see
[pool-storage.md](pool-storage.md).

> **YAML quoting — quote a Windows drive-letter `poolLocalPath`/`stashLocalPath`.**
> Write `poolLocalPath: 'y:'`, not `poolLocalPath: y:`. Unquoted, YAML reads the
> trailing colon in `y:` as the start of a nested mapping and the **entire
> `test.config.yml` fails to parse** (`While scanning a plain scalar value, found
> invalid mapping`) — so the runner can't read *any* config, not just
> networkStorage. Single quotes are the safe choice for any value with a trailing
> colon or backslashes. `poolNetworkPath: \\server.local\work` works unquoted because
> YAML treats backslashes in a plain scalar literally, but `'\\server.local\work'` (single
> quotes) is equally fine.

### Stash storage (the stash service's own durable store)

The **stash service** uses an **isolated** storage tier: its own NAS share and its
own NAS account, configured under the `stash*` keys. It does **not** reuse the
pool's share or `poolNetworkUser` credential, and it has **no replicate flag**
(the stash daemon writes files directly). All three `stash*` keys must be set for
the stash store to be active; leave them empty to leave the stash store off. The
reader is `Get-YurunaStashStorageConfig` (the pool tier's reader is
`Get-YurunaPoolStorageConfig`).

| Key | Type | Meaning |
|---|---|---|
| `stashNetworkPath` | string | The stash SMB share — its **own** share, e.g. Windows `\\ystash-nas\work\yuruna.stash`; macOS/Linux `//ystash-nas/work/yuruna.stash` (either form is accepted and normalized). |
| `stashNetworkUser` | string | The stash's **own** SMB account (e.g. `yuruna-stash`), distinct from `poolNetworkUser`. **Also the vault key** its password is fetched under (see below). Scope it **storage-only** on the NAS (write access to `stashNetworkPath` and nothing else). |
| `stashLocalPath` | string | The host's stash mount point. Windows `'z:'` (**must be quoted** — same drive-letter trap as the pool) · macOS `~/Shares/yuruna.stash` · Linux `/mnt/yuruna.stash`. |

Example (Windows; macOS/Linux follow the same slash/mount-point rules as the pool):

```yaml
pool:
  networkReplicate: true
networkStorage:
  poolNetworkPath: \\ypool-nas\work\yuruna.pool
  poolNetworkUser: yuruna-pool
  poolLocalPath: 'y:'
  stashNetworkPath: \\ystash-nas\work\yuruna.stash
  stashNetworkUser: yuruna-stash
  stashLocalPath: 'z:'
```

The passwords are **never** stored in `test.config.yml` — they live in the vault.

### Setting the SMB passwords in the vault

Each SMB password must match the NAS exactly, so it is **never** auto-generated —
you set it once, per host. Because the pool and stash now use **separate
accounts**, you set **two** passwords: one for `poolNetworkUser` and one for
`stashNetworkUser`. The vault
(`test/status/extension/authentication/vault.yml`) is git-ignored, plaintext, and
persists across cycles.

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
entries exist, when the server is reachable it **actively mounts `poolLocalPath`
and creates the per-host folder `<poolLocalPath>/<hostId>`** — so a wrong password,
a share-name typo, missing Linux passwordless sudo, or a read-only share surfaces
as a gate failure (and, with `networkReplicate: true`, **stops the cycle from
starting**) instead of replication silently never happening. See
[pool-storage.md](pool-storage.md#operating--troubleshooting). Password
characters: `a-z A-Z 0-9` and `! @ # $ % ^ & * ( ) - _ = +`; avoid quotes,
backslash, and YAML/shell separators (`: , < > | ; ~ \``).

## pool — optional multi-host pool intent (default-off)

Joins this host to a **pool**: it PULLs the slow-changing pool intent (membership
+ `desiredState`) from a LAN git repo on the caching-proxy each cycle, and the
pool aggregator labels its telemetry by the pool it belongs to. **Default-off** —
with `enabled: false` (or no `pool` block) the host behaves exactly as a single
host. Creating pools + assigning test sequences (the operator guide): [pool-admin.md](pool-admin.md).

| Key | Type | Meaning |
|---|---|---|
| `enabled` | bool | Master switch. **Default `false`.** `false` ⇒ no pull, no behavior change. |
| `intentGitUrl` | string | Read-only URL of the bare intent repo on the proxy, e.g. `http://caching-proxy.local/pool-intent.git`. Empty ⇒ off. |
| `localClonePath` | string | Where to keep the pulled clone. Empty ⇒ `<runtime>/pool-intent` (default). |
| `pullTimeoutSeconds` | int | Wall-clock cap on each bounded git fetch. Default `30`. |

There is **no `poolId` here** — membership is the single source of truth in the
intent store's `pools.yml` `members[]` (the operator assigns this host's stable
`hostId` via `Add-HostToPool.ps1`); the runner finds its own pool by locating its
`hostId` there. An unreachable intent store degrades gracefully: the host keeps
cycling as a single host (it never blocks on the pull). `desiredState`
(`run`/`paused`/`drain`) gates the cycle — `paused` holds after the in-flight
cycle, `drain` stops after the current one — and any **test-sets** the pool
assigns drive what this host runs (operator guide: [pool-admin.md](pool-admin.md)).

## testCycle.autoRemediationEnabled (+ autoRemediationMaxAttemptsPerCycle)

Default-off self-heal. When `true`, the outer failure-pause ends early
(auto-retry) for a clearly-safe transient failure class (`wait_timeout`,
`instrumentation_failure`, `network_timeout`, `host_io_blocked`) instead of
waiting up to the failure-pause cap for a human commit. Capped per
consecutive-failure streak (`autoRemediationMaxAttemptsPerCycle`) so a
deterministic failure still escalates to the normal wait-for-human pause after
that many auto-retries.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.26
