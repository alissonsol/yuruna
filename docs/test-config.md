# test.config.yml — runner configuration reference

`test/test.config.yml` is the per-host runner configuration. On first run it is
bootstrapped from `test/test.config.yml.template` (then git-ignored, so your edits
and secrets stay local). Edit it directly, or through the status-page editor
(`test.config.html`), a schema-driven form that loads/saves via
`GET`/`POST /control/test-config`. The template is intentionally **comment-free**;
this document is its reference (the editor + `ConvertTo-Yaml` round-trip strips
inline comments anyway).

Top-level sections: `guestSequence`, `logLevel`, `notification`, `pool`,
`poolStorage`, `repositories`, `statusService`, `testCycle`, `vmCommunication`,
`vmImage`, `vmStart`. Most are self-describing; the ones carrying non-obvious
behavior are documented below.

## poolStorage — optional NAS-backed durable tier (ypsp)

Hosts (like guests) are **reimageable at any time**, so local storage stays local,
fast, and ephemeral; an optional Network-Attached Storage share — the *yuruna pool
storage path* (**ypsp**) — is the durable tier. When `replicate` is true, each
cycle's output is copied to `<localPath>/<hostId>/` on the share over **SMB3**
(uniform across Windows/macOS/Linux). The squid cache is **not** replicated
(rebuildable; left to squid pools).

This section is the parameter reference; for the architecture (the async,
fail-fast, atomic, backlog-draining replicator), the on-share layout, the Linux
passwordless-sudo precondition, and operations/troubleshooting, see
[pool-storage.md](pool-storage.md).

| Key | Type | Meaning |
|---|---|---|
| `replicate` | bool | Master switch. **Default `false`.** `false`, or any of the paths empty, ⇒ feature OFF (no mount, no copy). |
| `networkPath` | string | The SMB share. Windows `\\server.local\work`; macOS/Linux `//server.local/work` (either form is accepted and normalized). |
| `networkUser` | string | The **single** SMB account used for **every** connection to the share — host-side cycle replication (the host mounts) **and** the caching-proxy guest's service replication alike. **Also the vault key** its password is fetched under (see below). Scope it **storage-only** on the NAS (write access to `networkPath` and nothing else). |
| `localPath` | string | The host's mount point. Windows `'y:'` (**must be quoted** — see below) · macOS `~/Shares/ypsp` · Linux `/mnt/ypsp`. |

Examples — only `localPath` and the `networkPath` slash style differ per platform:

**Windows:**
```yaml
poolStorage:
  replicate: true
  networkPath: \\server.local\work
  networkUser: yurunanet
  localPath: 'y:'
```

**macOS:**
```yaml
poolStorage:
  replicate: true
  networkPath: //server.local/work
  networkUser: yurunanet
  localPath: ~/Shares/ypsp
```

**Ubuntu (Linux):**
```yaml
poolStorage:
  replicate: true
  networkPath: //server.local/work
  networkUser: yurunanet
  localPath: /mnt/ypsp
```

macOS expands a leading `~/` to `$HOME` — keep the **slash** (`~/Shares/ypsp`, not
`~Shares/ypsp`): only `~/…` is expanded, a tilde glued to the next character is left
literal and the mount silently fails. The macOS/Linux mount point needs no quoting
(no trailing colon). On **Ubuntu/Linux** the mount also
requires **passwordless `sudo` for `mount`** (an `/etc/sudoers.d` drop-in) — see
[pool-storage.md](pool-storage.md).

> **YAML quoting — quote a Windows drive-letter `localPath`.** Write `localPath: 'y:'`,
> not `localPath: y:`. Unquoted, YAML reads the trailing colon in `y:` as the start of
> a nested mapping and the **entire `test.config.yml` fails to parse** (`While scanning
> a plain scalar value, found invalid mapping`) — so the runner can't read *any*
> config, not just poolStorage. Single quotes are the safe choice for any value with a
> trailing colon or backslashes. `networkPath: \\server.local\work` works unquoted because
> YAML treats backslashes in a plain scalar literally, but `'\\server.local\work'` (single
> quotes) is equally fine.

The password is **never** stored in `test.config.yml` — it lives in the vault.

### Setting the networkUser password in the vault

The SMB password must match the NAS exactly, so it is **never** auto-generated —
you set it once, per host. The vault
(`test/status/extension/authentication/vault.yml`) is git-ignored, plaintext, and
persists across cycles.

**Recommended (fail-safe):** map a `vaultKey` so the harness never silently
auto-generates a wrong password, then store the value.

1. In `test/status/extension/authentication/users.yml`, add/edit the user with a
   **non-empty** `vaultKey`:
   ```yaml
   yurunanet:
     localOsUser: yurunanet
     corporate:   { domain: "", sam: "", upn: "" }
     vaultKey:    "smb.yurunanet"
     localOsPasswordRef: ""
   ```
   A non-empty `vaultKey` disables auto-generation: `Get-Password` returns the
   stored value or fails loudly if it is missing (so a random password can never
   silently break the mount).
2. Store the password under that vault key:
   ```powershell
   Import-Module test/extension/authentication/default.psm1
   Set-Password -Username 'smb.yurunanet' -NewPassword '<your NAS password>'
   ```

**Quick alternative (no users.yml edit):** store directly under the username —
`Set-Password -Username 'yurunanet' -NewPassword '<your NAS password>'`. Works
because an unset, vaultKey-less user resolves to the username as its own vault key.
Caveat: if you forget to set it, `Get-Password` auto-generates a random password
and the mount fails with bad credentials — the recommended path above prevents
that.

Verify with `pwsh test/Test-Config.ps1`. Beyond checking that mapped vault
entries exist, when the server is reachable it **actively mounts `localPath` and
creates the per-host folder `<localPath>/<hostId>`** — so a wrong password, a
share-name typo, missing Linux passwordless sudo, or a read-only share surfaces
as a gate failure (and, with `replicate: true`, **stops the cycle from starting**)
instead of replication silently never happening. See
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
