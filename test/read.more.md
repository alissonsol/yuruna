# Test Runner — Nerd-Level Details

The crisp version lives in [Yuruna Test ...](README.md); this file holds the
full configuration table, sequence development, screenshot training,
status server details, and SSH-server controls.

## Configuration keys

`test.config.yml` uses a nested layout — related settings are grouped
under `vmStart`, `vmImage`, `vmCommunication`, `repositories`, and
`testCycle` nodes. The dotted paths below are the YAML node + key.

| Key | Default | Description |
|-----|---------|-------------|
| `guestSequence` | _required_ | Array of guest keys; each must correspond to `host/<short-host>/<guestKey>/` |
| `testCycle.cycleDelaySeconds` | `300` | Pause between cycles |
| `testCycle.shouldStopOnFailure` | `false` | `true` = stop on first failure and preserve VM; `false` = clean up and continue. Failure artifacts always copied to `status/log/` |
| `testCycle.recentDisplayCount` | `30` | Runs kept in status history |
| `vmStart.startTimeoutSeconds` | `120` | Wait for VM to reach running state |
| `vmStart.bootDelaySeconds` | `15` | Extra wait after running, before tests |
| `vmStart.testVmNamePrefix` | `"test-"` | Prefix for test VM names |
| `vmImage.refreshHours` | `168` | Hours between automatic re-downloads |
| `vmImage.alwaysRedownload` | `false` | Force re-download even if image exists |
| `vmCommunication.characterDelayMs` | `20` | ms between keystrokes in `inputText`/`inputTextAndEnter` (per-step `charDelayMs` in sequences/ overrides this default) |
| `vmCommunication.allowGuiFallback` | `false` | When `false` (default) `gui/` and `ssh/` are **independent** mechanisms: under `keystrokeMechanism="SSH"` a missing `ssh/` sequence is a hard error, never a silent run on the OCR `gui/` sibling (which an SSH-only host could not drive). Set `true` to restore the legacy degrade-to-`gui/` behavior |
| `vmCommunication.keystrokeMechanism` | `"GUI"` | `"GUI"` keystroke injection (OCR), `"SSH"` over ssh. Selects `sequences/gui/` or `sequences/ssh/` as independent mechanisms (see `allowGuiFallback`). Any other value normalized to `"GUI"` |
| `vmCommunication.pollSeconds` | `5` | Default poll interval (seconds) for wait-style actions (`waitForText`, `passwdPrompt`, `waitForAndEnter`, `sshWaitReady`, …). A step's own `pollSeconds` overrides this default |
| `vmCommunication.timeoutSeconds` | `180` | Default timeout (seconds) for wait-style actions (`waitForText`, `passwdPrompt`, `fetchAndExecute`, `sshExec`, `sshWaitReady`, …). A step's own `timeoutSeconds` overrides this default |
| `vmCommunication.vncPort` | `5900` | Fallback VNC port when no VM name is given. Per-VM ports (5910..5989) are derived from the VM name by `Get-VncDisplayForVm` (`host/macos.utm/modules/Yuruna.Host.psm1`); each QEMU-backed UTM guest gets a unique port so concurrent VMs can't poach each other's framebuffer |
| `repositories.frameworkUrl` | `https://github.com/alissonsol/yurunadev` | URL of the framework repo. Used by status page for commit links AND polled by the outer runner during a failure-pause to break out early when a new commit lands upstream. |
| `repositories.projectUrl` | `https://github.com/alissonsol/yurunadev-project` | URL of the project-under-test repo. Polled alongside `repositories.frameworkUrl` during a failure-pause, so a fix pushed to the project also breaks out of the 1-hour wait. Empty value disables the project clone (in-tree `project/` is used instead). |
| `statusService.isEnabled` | `true` | Start built-in HTTP status server |
| `statusService.port` | `8080` | Port for status server |

### Format enforcement and auto-reset

At cycle start the runner overlays `test.config.yml.template` to pick up
any newly added keys. If the on-disk `test.config.yml` no longer matches
the nested node layout above — for example a checkout left over from the
old flat layout — the runner does **not** silently migrate it. Instead it:

1. Copies the current file to `test.config.yml.backup`.
2. Resets `test.config.yml` to the template defaults.
3. Warns and stops the test.

Copy any custom values from `test.config.yml.backup` into the new
`test.config.yml` by hand, then restart — the test will proceed normally.

### Guest ordering and skipping

Omit a guest from `guestSequence` to skip it. Listing one with no folder
marks a per-guest failure; others still run unless `testCycle.shouldStopOnFailure`.

### Notifications (Resend) — full setup

Notifications are dispatched by the active extension(s) under
[`test/extension/notification/`](extension/notification/). The shipped
default delivers email via Resend; subscribers are configured per
event code (`cycle.failure`, `config.smoke`).

1. Create a free account at [resend.com](https://resend.com).
2. Create an [API key](https://resend.com/api-keys) (starts with `re_`).
3. Add and verify a sender domain under
   [Domains](https://resend.com/domains), or use `onboarding@resend.dev`
   for testing.
4. Copy
   [`extension/notification/transports.yml.template`](extension/notification/transports.yml.template)
   to `test/status/extension/notification/transports.yml` and fill in:
    - `transports.resend.apiKey`
    - `transports.resend.fromEmail`
    - `subscribers["cycle.failure"][].address` (one entry per recipient)
    - `subscribers["config.smoke"]` — leave empty unless you want
      `Test-Config.ps1` smoke runs to deliver mail.
5. Run `pwsh test/Test-Config.ps1` to validate the config and dispatch a
   `config.smoke` event end-to-end. The file is gitignored.

Legacy `secrets.resend` and `notification.toEmailAddress` keys in
`test.config.yml` are no longer read; the runner warns at cycle start
when it sees populated legacy values that need a manual move.

### Authentication vault (external-provider simulation)

VM passwords come from the active extension under
[`test/extension/authentication/`](extension/authentication/). The
default extension keeps a YAML vault (`vault.yml`, gitignored) that
SIMULATES an external authentication provider: users are never
deleted and passwords never change without an explicit Set-Password
call. The vault is persisted across cycles -- the "fake" behavior
is the lazy-create branch in Get-Password (first reference for a
username generates+stores a password; every later call returns the
same stored value).

- `Initialize-VaultConnection` ensures vault.yml exists. Idempotent:
  a no-op when the file is already present.
- `Get-Password -Username <name>` returns the stored value or
  generates+stores one on first call.
- `New-RandomPassword` is a pure helper used by the rotation flow.
- `Set-Password -Username <name> -NewPassword <value>` commits a
  rotation (the only path that changes an existing password).
- A named system mutex serialises read-modify-write so multiple guests
  provisioning in parallel cannot race.

The caching-proxy `yuruna` user persists across cycles via
[`test/status/runtime/yuruna-caching-proxy.yml`](status/runtime/)
(host-agnostic, gitignored, managed by
[`test/modules/Test.CachingProxy.psm1`](modules/Test.CachingProxy.psm1)),
which the caching-proxy `New-VM.ps1` writes back to the vault on each
cycle start. The same file also carries the cache VM's IP, replacing
the older per-platform `cache-ip.txt` breadcrumb near the VHD/raw
image.

The test user is configured per-guest in `test/sequences/**/*.yml`
(under `variables.username`) and mirrored as the `-Username` default
in each host's `guest.<type>/New-VM.ps1`. Ubuntu guests carry the
major version in the suffix so 24.04 and 26.04 don't collide in shared
logs: `yuuser24` for ubuntu.server.24, `yuuser26` for ubuntu.server.26.
Other guests use the greppable `y[aw]user1` form encoding the family in
the second character: `yauser1` for amazon.linux.2023, `ywuser1` for
windows.11 -- intentionally unique/greppable versus the cloud-image
defaults `ubuntu` and `ec2-user`. Trailing digits anticipate the
multi-user future (a second user per guest, etc.) which will be defined
in a manifest, not created on the fly.

Sequence steps fetch live values via the inline `${ext:area.Method(args)}`
substitution form, e.g. `${ext:authentication.GetPassword(${username})}` and
`${ext:authentication.NewRandomPassword()}`. Each `${ext:...}` is invoked
fresh on every reference — there is no caching. To pin a generated
value across multiple steps (e.g. `New password:` and the matching
`Retype:`), assign the call to a variable in the sequence's `variables:`
block:

```
variables:
  username: yuuser24
  currentPassword: ${ext:authentication.GetPassword(${username})}
  newPassword: ${ext:authentication.NewRandomPassword()}
```

Entries there are evaluated eagerly at sequence start, in file order, so
each entry can reference earlier entries and the built-ins
(`${vmName}`, `${hostType}`, `${guestKey}`). Use `$$` for a literal `$`
(in particular `$${foo}` stores the four-character literal `${foo}`).

### Username cascade + corporate identity mapping

A top-level workload's `variables.username` propagates down through its
entire dependency chain. Example:

  - `start.guest.ubuntu.server.26.yml` declares `username: yuuser26`
    (the baseline default for any chain rooted here).
  - `workload.guest.ubuntu.server.26.k8s.website.yml` declares
    `username: webuser`. As the cycle's top-level, it wins.
  - The planner injects `webuser` as the effective username across
    the entire chain (`start.*` → `workload.*` → workload-website).
  - Cloud-init creates a local OS account named `webuser`, **not**
    `yuuser26`. Every `${username}` substitution in every sequence
    of the chain renders as `webuser`. The baseline `start.*.yml`
    keeps its `username: yuuser26` line as the stand-alone-invocation
    default (used only by `Test-Sequence.ps1` runs outside a
    workload context).

The cascade applies to **any** key declared under `variables:` (not
just `username`). For each key, the first non-empty value encountered
walking the chain top-down wins. Sequences lower in the chain can
declare defaults; sequences higher in the chain redefine them.

Logical usernames map to corporate identities (Active Directory /
Entra / SSSD-against-LDAP / ...) via
`test/status/extension/authentication/users.yml`. The committed
template at `test/extension/authentication/users.yml.template` ships
pre-seeded with the four bundled logical users (`yuuser24`,
`yuuser26`, `yauser1`, `ywuser1`) plus the cache-VM `yuruna` user,
all with empty corporate fields → out of the box, behavior is
identical to today's local-only flow (`${loginUser}` = `${username}`,
vault auto-generates passwords).

```
# Example users.yml entry that maps the logical user 'webuser' to a
# corporate AD identity (DOMAIN\sam form). Sequence-login steps render
# ${loginUser} as "CORP\alisson.sol"; ${ext:authentication.GetPassword(${username})}
# returns vault[corp.alisson.sol].password (must be pre-populated --
# the vault NEVER auto-generates for an operator-supplied vaultKey).
# The LOCAL OS account on the transient test VM is decoupled: it
# receives a fresh auto-gen password from vault[webuser] so the
# corporate plaintext never lands in the guest's /etc/shadow.
webuser:
  localOsUser: webuser
  corporate:
    domain: "CORP"
    sam:    "alisson.sol"
  vaultKey:           "corp.alisson.sol"
  localOsPasswordRef: ""
```

Inside sequences, use:

  - `${username}` — logical/local-OS user name (cascade-resolved).
    Use this for shell-side references (`/home/${username}`, `whoami`).
  - `${loginUser}` — rendered corporate identity from `users.yml`
    (`CORP\alisson.sol` or `user@upn.domain`); falls back to
    `${username}` when no corporate mapping is set. Use this for
    interactive login prompts.
  - `${ext:authentication.GetPassword(${username})}` — password for
    the sequence-login prompt. Routed through `users.yml`'s `vaultKey`.
  - `${ext:authentication.GetLocalOsPassword(${username})}` — password
    for the local OS account at cloud-init time. Routed through
    `users.yml`'s `localOsPasswordRef`.

`users.yml` is validated with `strict: true` by default. Every logical
username referenced by an active sequence MUST be declared, and every
populated `vaultKey` MUST exist in `vault.yml` -- `Test-Config.ps1`
blocks the cycle on the first violation, and `Invoke-TestRunner.ps1`
runs `Test-Config.ps1` automatically as a pre-cycle gate (bypass with
`-NoConfigGate` for ad-hoc / in-progress edit runs).
Side-effecting commits (e.g. `authentication.SetPassword`) use the
`callExtension` action verb.

## Developing test sequences

[`Test-Sequence.ps1`](Test-Sequence.ps1) runs a single
sequence without downloading images or recreating a VM:

```
pwsh test/Test-Sequence.ps1 -SequenceName "workload.guest.ubuntu.server.24"
pwsh test/Test-Sequence.ps1 -SequenceName "workload.guest.ubuntu.server.24" -StartStep 5
pwsh test/Test-Sequence.ps1 -SequenceName "workload.guest.ubuntu.server.24" -StartStep 3 -StopStep 7
pwsh test/Test-Sequence.ps1 -SequenceName "workload.guest.ubuntu.server.24" -VMName "private-ubuntu"
pwsh test/Test-Sequence.ps1 ..\project\example\text-to-sql\test\gui\workload.guest.ubuntu.server.24.k8s.text-to-sql.baseline.yml
```

`-SequenceName` accepts either a **name** (no folder, no `.yml`, no
`.ssh.` suffix) or a **path** to an existing `.yml` file -- the path
form is shell-tab-completion friendly and supplies the top-level file
directly (useful when `yuruna-project` is mounted as a sibling working
tree, not cloned under `<RepoRoot>/project/`), skipping mode/host-variant
resolution. Both forms still walk the baseline chain. Name form
resolves against `keystrokeMechanism`; under `"SSH"` it falls back to
`gui/` only when `vmCommunication.allowGuiFallback: true` (otherwise the
mechanisms are independent and a missing `ssh/` sequence is an error).
Missing sequence → listing from `sequences/gui/` and `sequences/ssh/`.
When the path form points to a generic `.yml` and a
`<name>.<hostShort>.yml` sibling exists, Test-Sequence warns -- the
runner would have picked the variant on this host, so the path form is
hiding a tier the runner sees.

Guest folder lookup walks dotted prefixes longest-first so cascade-child
sequences (e.g. `workload.guest.ubuntu.server.24.k8s.text-to-sql.baseline`)
auto-resolve to the existing `guest.ubuntu.server.24` folder. Pass
`-GuestKey` to override the walk.

To minimise surprises when a sequence is later wired into the runner,
Test-Sequence mirrors the relevant runner-side resolutions:

* **Baseline chain walk** -- the same `Resolve-CyclePlan` logic the runner
  uses. When a sequence's `baseline:` field declares prereqs, every
  prereq is run in dependency order (deepest first, top-level last)
  before the named sequence. `-StartStep`/`-StopStep` index into the
  CONCATENATED step list across the whole chain, so step 1 is always
  the first step of the deepest prereq -- not the named sequence's
  step 1. Both name form and path form walk the chain; the path form
  just supplies the top-level file directly. Prereqs still resolve via
  the standard search (framework `test/sequences/` and project
  `<RepoRoot>/project/...`).
* `Test-Config.ps1` runs as a pre-cycle gate (same as Invoke-TestRunner).
  Pass `-NoConfigGate` to skip while iterating on test.config.yml,
  vault.yml, or users.yml edits.
* The chain's `effectiveUsername` (cascaded top-down from the named
  sequence's `variables.username` through every prereq) is forwarded as
  `-Username` to `New-VM`, matching the runner's same forward. The
  full `effectiveVariables` map is passed as `-EffectiveVariables` to
  each `Invoke-Sequence` call so a workload-level `username: webuser`
  propagates into the baseline's `${username}` substitutions.
* `Test-CachingProxyAvailable` is consulted and the resolved URL is
  forwarded as `-CachingProxyUrl` to `New-VM`. `vmStart.cachingProxyIP`
  from test.config.yml is promoted to `$Env:YURUNA_CACHING_PROXY_IP`
  before the probe (same precedence the runner uses).
* `control.cycle-restart` is consumed at startup so leftover state from a
  Ctrl-C'd runner can't make a clean Test-Sequence run look broken.
* `-ShowSensitive` is OFF by default (matches Invoke-TestRunner's masked
  output). Add the switch when local debugging actually needs cleartext.

The script prints a numbered step list with run markers, grouped under
each sequence in the chain; `-StopStep` leaves the VM running.

Parameters: `-SequenceName` (required), `-StartStep` (default 1),
`-StopStep`, `-ConfigPath`, `-VMName`, `-GuestKey`, `-ShowSensitive`,
`-NoConfigGate`, `-logLevel`.

## Logging knobs

`-logLevel` accepts `Error|Warning|Information|Verbose|Debug`. Each level
shows itself plus all higher-priority streams (Error is highest); the
default is `Information`, so the runner's progress narration reaches the
console. Three-state resolution (cmdline > `test.config.yml` >
`Information`): omit the flag to read [test.config.yml](test.config.yml)'s
`logLevel`, or pass `-logLevel <level>` to override for the lifetime of
the runner. The level maps to PowerShell's preference variables:

| Level | Stream | Cmdlet | Use it for |
|-------|--------|--------|-----|
| Error       | 2 | `Write-Error`       | non-terminating errors only (silent narrative) |
| Warning     | 3 | `Write-Warning`     | + potential issues that don't stop execution |
| Information | 6 | `Write-Information` | + general progress (the runner's default narrative) |
| Verbose     | 4 | `Write-Verbose`     | + per-poll OCR hits, network re-applies (use when a `waitForText` hangs) |
| Debug       | 5 | `Write-Debug`       | + VNC capture ticks, screen-diff, AppleScript/CGEvent results |

## Status page details

`http://localhost:8080/status/` polls `status.json` every 30s and
shows pass/fail, per-guest step status (New-VM, Start-VM,
New-VM.Resource, Start-GuestOS, Screenshots, Start-GuestWorkload),
history, and clickable Cycle IDs. Stop
the detached server with `pwsh test/Stop-StatusService.ps1`.

## Adding a test sequence

Drop a YAML sequence under `test/sequences/{gui,ssh}/` (framework
generic) or `project/<...>/test/{gui,ssh}/` (project-specific), wire
its `baseline` to declare prerequisites, then reference the top-level
sequence from the `project/test/test.runner.yml` `sequences` list. Full
architecture: [Test Modules ...](modules/README.md).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.26

Back to [Yuruna](../README.md)
