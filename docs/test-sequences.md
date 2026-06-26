# Sequence actions and host contracts

Authoritative reference for the actions you can use in sequence files
under [`test/sequences/{gui,ssh}/`](../test/sequences/) and `project/<...>/test/{gui,ssh}/`,
plus the per-host [Yuruna.Host](../host) contract functions that
back the ones with non-trivial cross-host divergence.

- Source of truth for action names is the `switch` block in
  [`test/modules/Invoke-Sequence.psm1`](../test/modules/Invoke-Sequence.psm1).
- Schema for the YAML shape is
  [`test/schemas/actions.schema.yml`](../test/schemas/actions.schema.yml).
- Short one-paragraph catalog (consumed by tooling) is
  [`actions.yml`](../test/sequences/actions.yml). This file is the rendered, prose-style
  complement.

## How a sequence step runs

Every step is a YAML map with at least an `action` field plus a free-form
`description` shown in the cycle log. The engine substitutes `${var}`
references (sequence-level `variables`, built-ins `${vmName}`,
`${hostType}`, `${guestKey}`, plus `${ext:area.Method(args)}` extension
calls) before dispatching to the per-action handler. A step succeeds
when its handler returns `$true`; the sequence stops on the first
failure (with retry-wrapping as documented under `retry`).

## Built-in variables

| Name | Value |
|---|---|
| `${vmName}` | Current VM name. Updated mid-sequence by `saveDiskSnapshot` after a successful rename — see [saveDiskSnapshot](#savedisksnapshot). |
| `${hostType}` | `host.windows.hyper-v` / `host.macos.utm` / `host.ubuntu.kvm`. |
| `${guestKey}` | `guest.<os>` key the sequence is bound to. |

### Variable substitution rules

- **Sequence-level `variables`** are evaluated **eagerly in YAML order**
  at sequence start. Each entry can reference any variable declared
  above it plus the built-ins; the resolved value is stored and reused
  on every later `${name}` reference. This is the "stable value across
  multiple steps" path — for example, when a "New password:" must be
  typed and then re-typed at "Retype:", assign the `${ext:...}` call
  to a sequence variable so both prompts see the same string.
- **Inline `${ext:area.Method(args)}` references in a step's args** are
  **invoked fresh on every reference** (no per-step memoization).
  Inner `${var}` placeholders inside the args are resolved first.
- **Escape `$`** by doubling: `$$` produces a literal `$`. In
  particular `$${foo}` yields the four-character literal `${foo}`
  (no substitution). To embed two literal dollars, write `$$$$`.

## Failure artifacts

When a step fails, the engine writes the following under the cycle's
log directory (`$env:YURUNA_LOG_DIR`):

| File | What it carries |
|---|---|
| `last_failure.json` | Schema-v2 record of the failed step (`stepNumber`, `action`, `description`, `vmName`, `guestKey`, `failureClass`, `severity`, `suggestedRecoveries`, `actionVerb`, `context`). The parent runner reads it; `Send-Notification`'s `-EventData` payload is built from it. See [`test/modules/Invoke-Sequence.psm1`](../test/modules/Invoke-Sequence.psm1) for the writer and [`test/modules/Test.Notify.psm1`](../test/modules/Test.Notify.psm1) for the consumer. |
| `failure_screenshot_<VM>.png` | Last VM screenshot captured at time of failure. Present for every failing step that has a host-IO backend. |
| `failure_ocr_<VM>.txt` | Last OCR text. Written only by `waitForText` family failures. |

The per-cycle `manifest.json` ([`Stop-LogFile`](../test/modules/Test.Log.psm1)) enumerates every artifact in the cycle folder with `kind`, `sizeBytes`, `sha256`, and `modifiedUtc` — a single well-known entry point for autonomous remediators.

---

## Sequence-level fields

Top-level keys in a sequence YAML, complementing `description:`, `baseline:`,
`variables:`, and `steps:`. Full schema:
[`test/schemas/sequence.schema.yml`](../test/schemas/sequence.schema.yml).

### requiresSnapshot

Declares that this sequence is a CONSUMER of a disk snapshot produced
by an earlier sequence in its `baseline:` chain (typically a sibling
`.baseline.yml` that ends in [`saveDiskSnapshot`](#savedisksnapshot)).
The runner uses it for two related decisions:

1. **VM-name override.** The runtime VM name becomes `id` (instead of
   the default `test-<guestKey>`). Because [`saveDiskSnapshot`](#savedisksnapshot)
   already renames `test-*` → `id`, pre-naming the VM as `id` on the
   warm path lets the runner target the persisted VM directly; on the
   cold path the chain still creates `test-<guestKey>` first and the
   rename happens at `saveDiskSnapshot` time, with the runner detecting
   the rename and swapping its `$VMName` for subsequent chain entries.

2. **Chain skip.** Before walking the `baseline:` chain, the runner
   probes the host driver via [`Test-VMDiskSnapshot`](#test-vmdisksnapshot).
   Hit: skip every prereq sequence and run only this top-level (the
   first [`loadDiskSnapshot`](#loaddisksnapshot) reverts the disk).
   Miss: walk the full chain so the prereqs build the snapshot.

| Parameter | Type | Notes |
|---|---|---|
| `id` | string | Required. Must match exactly the [`saveDiskSnapshot`](#savedisksnapshot) `id` produced by the chain's terminal snapshot step — the runner uses this both as the snapshot lookup key AND as the persisted VM name. |

**Operator's responsibility — on-disk state must match.** The snapshot
freezes whatever is on disk at capture time. Any `variables:` entry
that influences what gets baked into the VM (`username`, hostname,
anything templated into cloud-init / `/etc/passwd` / ssh keys) MUST
match the value the snapshot-producing sequence used. On the cold path,
the cascade hands this sequence's variables down to the prereqs and
everything aligns; on the warm path the prereqs don't re-run, so a
mismatched variable here will reference state that doesn't exist on
disk (e.g. a [`passwdPrompt`](#passwdprompt) for a username the
snapshot's `/etc/passwd` never had). When redefining a baked-in
variable, delete the persisted VM + snapshot to force a cold rebuild.

---

## Snippets (reusable step lists)

A **snippet** is a named, reusable list of steps spliced into a sequence
wherever a `snippet:` step appears — so a common preamble lives in one
place instead of being copied across every sequence. The classic case is
the cold-agetty login prime (see [`firstLoginPrime`](#firstloginprime)
below), shared by all `workload.guest.*` sequences.

Reference one with a step whose only key is `snippet:` (it has no
`action:`). It works at the top level **and inside `retry.steps`**:

```yaml
steps:
  - action: retry
    maxAttempts: 2
    steps:
      - snippet: firstLoginPrime        # spliced out to the 3 primed steps
      - action: passwdPrompt
        pattern: "login:"
        text: "${username}"
```

### Where snippets live

Snippets are defined in a `_snippets.yml` library — a map of
`name → [steps]` — sitting in the same mode dir as sequences:

- **Framework:** `test/sequences/gui/_snippets.yml`,
  `test/sequences/ssh/_snippets.yml`
- **Project:** `project/<…>/test/gui/_snippets.yml` (any example's test tree)

```yaml
# test/sequences/gui/_snippets.yml
firstLoginPrime:
  - action: waitForText
    pattern: "login:"
    description: "OCR: login:"
  - action: pressKey
    name: Enter
  - action: waitForSeconds
    seconds: 2
```

Schema: [`test/schemas/snippets.schema.yml`](../test/schemas/snippets.schema.yml).

### Resolution and rules

- **Project overrides framework.** A snippet name defined in a project
  `_snippets.yml` wins over the same name in the framework library —
  mirroring how a project sequence overrides a framework sequence of the
  same name. Defining the same name in **two project** libraries is a
  fatal ambiguity (the cycle aborts before any guest runs).
- **Variables resolve in the consumer's scope.** A snippet may use
  `${username}` and other tokens; they expand against the sequence that
  references the snippet, at execute time. Snippets are parameter-free.
- **Snippets may reference snippets.** Nesting is expanded recursively;
  a reference cycle is a fatal error.
- **Expansion is invisible downstream.** Splicing happens at file-read
  time, so step windows (`-StartStep`/`-StopStep`), perf step rows, and
  the executor all see the already-expanded steps — identical to writing
  the steps inline.
- An **unknown snippet name** is a fatal error listing the available
  names, so a typo fails fast instead of silently dropping steps.

Every sequence in the framework and the project tree is read (and thus
snippet-expanded) by [`Test-Config.ps1`](../test/Test-Config.ps1), so a
broken or missing snippet reference is caught before a cycle starts.

#### firstLoginPrime

The bundled gui snippet. Wakes a freshly-rebooted agetty before a
username is typed: the first keystroke into a cold `login:` prompt is
swallowed while the tty input layer drains, so on KVM (one
`virsh send-key` per char, no lead-in) the leading character of the
username is lost. Pressing Enter (a harmless empty submit at a `login:`
prompt) and pausing lets the prompt settle before the
[`passwdPrompt`](#passwdprompt) types the username.

---

## Action reference

### break

Cooperative breakpoint, and the framework's canonical
**resume-from-step-N** primitive. Authors place a `break` at the
boundary they want to be able to resume from; the runner pauses there
and waits for an operator decision. The same code path covers
"investigate a guest while it's still alive" and "skip the long
bring-up cycle next time and re-run only the last few steps".

Writes `.yuruna-break-<NNN>.lock` under the per-guest
`cycleGuestDataFolder` and busy-waits for one of two resume signals:

By default a `break` is a plain breakpoint: on either resume signal the
sequence picks up at the next step **in place** — no snapshot restore,
no VM restart. The `id` field is a label only (shown in the marker file
and the status UI); it does NOT trigger a restore, even when it matches
a real snapshot name such as the workload's `requiresSnapshot` /
[`loadDiskSnapshot`](#loaddisksnapshot) `id`.

- **Manual** — operator deletes the marker file. Always resumes in
  place. The VM stays exactly as it was when the break fired, so the
  operator's mid-pause edits carry forward. Use this when you want to
  inspect or fix something on the live guest before continuing.
- **UI Continue** — operator clicks the **Continue** button rendered on
  the status page (`http://localhost:8080/status/`) for the running
  guest's card. The button POSTs to `/control/break-continue`; the
  action consumes the flag and resumes. By default this also resumes in
  place; only when the step set `restoreOnContinue: true` (and `id`
  names an existing snapshot) does it call
  [`Restore-VMDiskSnapshot`](#restore-vmdisksnapshot) with `break.id`
  then [`Start-VM`](#yurunahost-contract) (snapshot restore always
  leaves the VM stopped) before resuming.

#### restoreOnContinue (opt-in rewind)

Set `restoreOnContinue: true` on a `break` to make UI Continue rewind
the disk to `break.id` and restart the VM before resuming — the
**resume-from-known-good-state** use case where you're iterating on the
steps after a checkpoint (pair it with a prior
[`saveDiskSnapshot`](#savedisksnapshot) `-Id <same>`). Without it, the
`id` is purely a label and Continue resumes in place. Marker-delete
always resumes in place regardless of this flag.

The Continue button is driven by `/runtime/break-active.json`, a sidecar
the action writes on entry and removes on exit. Not a failure — the
step succeeds either way. `YURUNA_BREAK_DISABLED=1` turns the action
into a no-op for unattended runs.

#### Programmatic Continue (matches the UI button)

The UI button has a one-to-one programmatic equivalent — useful for CI
hooks, scripted iteration loops, or remote-debug sessions that don't
have a browser handy. All three paths produce the same on-disk state
(`<runtimeDir>/control.break-continue` exists), which the running
sequence's `break` handler polls for:

```
# HTTP (mirrors the UI button exactly; refuses with 409 when no break
# is active, so a stray POST cannot arm the NEXT break).
curl -fsS -X POST http://localhost:8080/control/break-continue

# Direct flag-file write (no status server required; useful on a
# headless host or when the dashboard isn't running).
#   pwsh: Set-Content -Path "$env:YURUNA_RUNTIME_DIR/control.break-continue" -Value (Get-Date -Format o)
#   bash: date -u +%FT%TZ > "$YURUNA_RUNTIME_DIR/control.break-continue"

# Marker-delete (always resumes in place; see "Manual" above).
rm "$(cat <cycleGuestDataFolder>/.yuruna-break-NNN.lock | grep marker | ...)"
```

The HTTP and direct-write paths behave exactly like the UI Continue
button — indistinguishable to the sequence — so they honor
`restoreOnContinue` the same way: in place by default, snapshot-restore +
`Start-VM` only when the step opted in. The marker-delete path always
resumes in place.

Login after a snapshot-restore is **the sequence author's
responsibility** — the guest boots fresh from the snapshot disk and
will be sitting at the login prompt, so place
[`passwdPrompt`](#passwdprompt) / [`sshWaitReady`](#sshwaitready) /
similar steps after the break.

| Parameter | Type | Notes |
|---|---|---|
| `reason` | string | Optional. Written into the marker file so the operator knows why we stopped. |
| `id` | string | Optional. Snapshot id to restore on Continue. Typically the id of a `saveDiskSnapshot` step earlier in the same sequence. Omit for a "just pause" break with no snapshot restore on Continue. |

> **On "resume from step N" generally.** Yuruna does not expose a
> `--resume-from N` flag on the runner. The reason is that mid-sequence
> resumption is only safe when the author has guaranteed the
> precondition state for step N — Yuruna can't infer that automatically
> from the YAML. A `break` (optionally paired with a
> [`saveDiskSnapshot`](#savedisksnapshot)) is the author's explicit
> assertion that "resumption here is well-defined", which is also what
> snapshot-restore + Start-VM materialises at runtime. For ad-hoc dev
> iteration on a specific step, [`Test-Sequence.ps1`](../test/Test-Sequence.ps1)
> takes `-StartStep` / `-StopStep` and indexes into the concatenated
> baseline chain.

### callExtension

Side-effecting call into the active extension for a given area (the
write counterpart to `${ext:...}` substitution, which must be
side-effect-free).

| Parameter | Type | Notes |
|---|---|---|
| `method` | string | `'area.Method'`; the `area` selects which extension family loads. |
| `args` | object | Named parameters forwarded to the extension method; string values support `${var}` and `${ext:...}` substitution. |

### fetchAndExecute

Type a command + Enter, then wait for `waitPattern` to appear on screen
(OCR poll, `freshMatch` semantics).

| Parameter | Type | Notes |
|---|---|---|
| `text` | string | Command to type. |
| `charDelayMs` | number | Default `50`. |
| `delaySeconds` | number | Drain pause before Enter; default `2`. |
| `waitPattern` | string | Required completion marker. |
| `timeoutSeconds` | number | Default `vmCommunication.timeoutSeconds`. |
| `pollSeconds` | number | Default `vmCommunication.pollSeconds`. |

### inputText

Type a text string.

| Parameter | Type | Notes |
|---|---|---|
| `text` | string | |
| `sensitive` | boolean | Masks output in logs. |
| `charDelayMs` | number | Default `50`. Hyper-V uses `Msvm_Keyboard.TypeText`. |

### inputTextAndEnter

Type, wait, press Enter.

| Parameter | Type | Notes |
|---|---|---|
| `text` | string | |
| `sensitive` | boolean | |
| `charDelayMs` | number | Default `50`. |
| `delaySeconds` | number | Default `2`. |

### loadDiskSnapshot

Revert the VM to a previously saved disk-only snapshot via the
[`Restore-VMDiskSnapshot`](#restore-vmdisksnapshot) contract, then start
the VM so the next step interacts with a live guest. The host driver
stops the VM first if running, restores the disk, and the sequence
engine then calls [`Start-VM`](#other-contract-surface) (Hyper-V / KVM / UTM all
implement the contract). No RAM-state is restored — guest boots fresh
from the snapshot disk, so re-DHCP and SSH re-handshake are expected
(gate downstream consumers on `sshWaitReady`, and on-screen consumers
on `waitForText` for the login prompt).

| Parameter | Type | Notes |
|---|---|---|
| `id` | string | Required. Snapshot name previously written by `saveDiskSnapshot`. |

### networkRelease

Release the guest DHCP lease and network resources at the end of a
sequence so the address returns to the pool instead of lingering until
lease expiry (keeps a churning fleet from exhausting a shared LAN's DHCP
pool). In GUI mode types `bash /usr/local/lib/yuruna/yuruna-network.sh
release` on the guest console for Ubuntu / Amazon Linux guests;
Windows.11 is a no-op reminder (TODO). Uses the `Send-Text` and
`Send-Key` host I/O contracts.

| Parameter | Type | Notes |
|---|---|---|
| `text` | string | Optional override of the typed command. Default `bash /usr/local/lib/yuruna/yuruna-network.sh release` (Ubuntu / Amazon only). |
| `charDelayMs` | number | Default `50`. Character typing delay in milliseconds. |

### passwdPrompt

Like `waitForAndEnter`, but `text` is always treated as sensitive — for
PAM prompts (`Current password:`, `Retype new password:`) whose
non-newline-terminated lines get overwritten on the framebuffer by late
console messages (see [memory note on passwd prompt
overwrite](memory.md)). Parameters are the same as
`waitForAndEnter`, minus the explicit `sensitive` flag.

### recoverFromSnapshot

Declarative auto-recovery primitive. Place AFTER a step whose failure
should trigger a restore-from-snapshot. The Handler is a no-op when
the prior step succeeded; on prior-step failure, it validates the
snapshot exists (and matches the
[snapshot manifest](#restore-vmdisksnapshot), if one was written), runs
[`Restore-VMDiskSnapshot`](#restore-vmdisksnapshot), then `Start-VM`,
and clears the engine's `LastFailed*` markers so the sequence
continues with a clean guest.

| Parameter | Type | Notes |
|---|---|---|
| `id` | string | Required. Snapshot name previously written by `saveDiskSnapshot`. |

Missing snapshot is a hard refuse (emits `snapshot_missing` event).
Manifest mismatch is a hard refuse (`snapshot_manifest_mismatch`);
missing manifest is warn-only (`snapshot_manifest_missing`, legacy
snapshots). On any restore failure the step returns failure and
downstream steps see the prior-failure markers untouched.

### pressKey

Send a single keystroke. Supported names: `Enter`, `Tab`, `Space`,
`Escape`, `Up`, `Down`, `Left`, `Right`, `F1`–`F12`.

| Parameter | Type | Notes |
|---|---|---|
| `name` | string | |

### retry

Failure-recovery wrapper around a block of inner steps. Re-runs the
block from its first inner step on any failure, up to `maxAttempts`.
The block succeeds when one attempt completes every inner step; if all
attempts fail, the deepest inner-failure label is wrapped with
`retry exhausted (N attempts)` in `last_failure.json`. `retry` blocks
may nest.

| Parameter | Type | Notes |
|---|---|---|
| `maxAttempts` | integer | Default `3`, must be `>= 1`. |
| `steps` | array | Step objects, recursive (same shape as a top-level `steps:`). |

### saveDiskSnapshot

Disk-only snapshot of the sequence's VM via the
[`Save-VMDiskSnapshot`](#save-vmdisksnapshot--rename-vm) contract. Then
RENAMES the VM (and relocates its storage, where supported) to the
snapshot id so the next cycle's
[`Remove-TestVMFiles.ps1`](../test/Remove-TestVMFiles.ps1) — which sweeps
every VM whose name matches the `test-*` prefix — leaves the persisted
VM alone. After a successful rename the engine updates its internal
`$VMName` to the snapshot id, so subsequent steps target the persisted
VM transparently.

| Parameter | Type | Notes |
|---|---|---|
| `id` | string | Required. **Snapshot name AND the new VM name** — must be valid as a VM name on every host you target. Dots, dashes, underscores, alphanumerics are safe; `/`, `:`, embedded `"` are not. |

VM is stopped before the snapshot (graceful → `Stop-VMForce` fallback)
and left stopped — a sequence wanting to keep going must explicitly
start the VM. Pre-existing snapshots with the same id are overwritten.

Per-host backend and rename support: see
[Save-VMDiskSnapshot + Rename-VM](#save-vmdisksnapshot--rename-vm).

### saveSystemDiagnostic

Mid-sequence checkpoint dump. SSHes into the guest, runs
`automation/Get-SystemDiagnostic.ps1`, writes the captured text to
`<cycleGuestDataFolder>/yyyy-MM-dd.HH-mm.system.diagnostic.<id>.txt`.
Soft-failing — unreachable guest or missing pwsh does not break the
sequence. Capture is opt-in; the runner does not auto-invoke it.

| Parameter | Type | Notes |
|---|---|---|
| `id` | string | Required. Appended to the saved filename so two captures in the same cycle don't collide. |

### sshExec

Run a command on the guest over SSH. Non-zero exit fails the step
unless `allowFailure=true`.

| Parameter | Type | Notes |
|---|---|---|
| `command` | string | |
| `timeoutSeconds` | number | Default `vmCommunication.timeoutSeconds`. |
| `allowFailure` | boolean | If true, non-zero exit logs a warning instead of failing. |
| `sensitive` | boolean | Masks command in logs. |

### sshFetchAndExecute

Long-lived command over SSH (SSH counterpart to `fetchAndExecute`). No
OCR polling, no password-prompt handling — sudo must be passwordless or
the command handles its own auth.

| Parameter | Type | Notes |
|---|---|---|
| `command` | string | |
| `timeoutSeconds` | number | Default `vmCommunication.timeoutSeconds`. |

### sshWaitReady

Wait until the guest accepts SSH with the yuruna harness key —
handshakes to an authenticated shell, not just TCP/22. Use after a
reboot or a snapshot restore before any consumer that talks SSH.

| Parameter | Type | Notes |
|---|---|---|
| `timeoutSeconds` | number | Default `vmCommunication.timeoutSeconds`. |
| `pollSeconds` | number | Default `vmCommunication.pollSeconds`. |

### takeScreenshot

Capture a screenshot for debugging.

| Parameter | Type | Notes |
|---|---|---|
| `label` | string | Used in filename; default `step<n>`. |

### tapOn

Wait for a button label to appear on the VM screen via OCR, then click
at the label's centre. Hyper-V uses `vmconnect` + SendInput
(`vmconnect` must be open). UTM uses CGEvent mouse-click synthesis
(requires Accessibility permission on macOS).

| Parameter | Type | Notes |
|---|---|---|
| `label` | string or string[] | Candidate labels. |
| `timeoutSeconds` | number | Default `vmCommunication.timeoutSeconds`. |
| `pollSeconds` | number | Default `vmCommunication.pollSeconds`. |
| `offsetX`, `offsetY` | number | Pixel offset from the centre; default `0`. |

### waitForAndEnter

Wait for a text pattern via OCR, then type a string + Enter. Parameters
are `waitForText`'s set plus `text`, `sensitive`, `tabCount`,
`charDelayMs`, `delaySeconds` (same defaults as `inputTextAndEnter`).

### waitForSeconds

Wait a fixed number of seconds.

| Parameter | Type | Notes |
|---|---|---|
| `seconds` | number | |

### waitForText

Capture + OCR the VM screen until `pattern` appears. `freshMatch=true`
waits for the pattern to clear first if already on screen (avoids
matching the previous step's residue). `failurePatterns` short-circuits
the wait if an anti-pattern matches — canonical use: subiquity's
`install_fail.crash` / `Press enter to start a shell` so an installer
crash fails the cycle in ~20s instead of waiting the full
`timeoutSeconds` for a login prompt that will never come.

| Parameter | Type | Notes |
|---|---|---|
| `pattern` | string or string[] | OR-matched. |
| `timeoutSeconds` | number | Default `vmCommunication.timeoutSeconds`. |
| `pollSeconds` | number | Default `vmCommunication.pollSeconds`. |
| `freshMatch` | boolean | |
| `freshMatchTailLines` | number | Default `12`. |
| `failurePatterns` | string or string[] | Anti-patterns; matching any fails the step with a label naming the matched pattern. |

---

## Yuruna.Host contract

Actions that touch the VM lifecycle, snapshots, screen I/O, networking,
or proxy plumbing don't talk to Hyper-V / virsh / utmctl directly —
they go through a per-host driver under
[`host/<short-host>/modules/Yuruna.Host.psm1`](../host). The driver
exports a fixed surface; the engine resolves the active driver via
`Initialize-YurunaHost` (in [`Test.HostContract`](../test/modules/Test.HostContract.psm1)).
See [Test harness — architecture](test-harness.md#yurunahost-contract) for the full list.

Below are the contract functions whose **per-host behavior diverges in
operationally significant ways** — i.e. where a sequence author needs
to know what actually happens on each host.

### `Save-VMDiskSnapshot` + `Rename-VM`

Backs the [`saveDiskSnapshot`](#savedisksnapshot) action. Two distinct
operations executed sequentially: capture a disk-only point, then move
the VM out of the `test-*` namespace so it survives the next cycle's
cleanup sweep. The rename is **part of the contract** — calling the
contract function commits to both legs and returns `$false` if either
fails.

#### Hyper-V — full support

- **Snapshot:** stop VM (`Stop-VM` graceful, `Stop-VMForce` fallback
  that escalates to killing `vmwp.exe`), drop any prior checkpoint with
  the same id, call `Hyper-V\Checkpoint-VM` on the offline guest. With
  no RAM to capture, the resulting `.avhdx` differencing disk + `.vmrs`
  pair is effectively a disk-only point.
- **Rename:** `Hyper-V\Rename-VM -Name <old> -NewName <id>` followed by
  `Hyper-V\Move-VMStorage -DestinationStoragePath
  <VirtualHardDiskPath>\<id>\`. The storage move is essential —
  Hyper-V's rename only touches the registry, leaving VHDX files at the
  old path. Without the move,
  [`Remove-OrphanedVMFiles.ps1`](../host/windows.hyper-v/Remove-OrphanedVMFiles.ps1)
  on the next cycle would reclaim the orphan dir and kill the persisted
  snapshot.

#### KVM (Ubuntu / libvirt) — full support

- **Snapshot:** stop VM, drop any prior snapshot with the same name,
  `virsh snapshot-create-as --atomic --domain <vm> --name <id>` on the
  offline domain. `--atomic` rolls back partial snapshots on failure.
- **Rename:** `virsh domrename <old> <new>` (libvirt ≥ 1.2.19; safely
  available on the Ubuntu baseline). Followed by:
  - `Rename-Item ~/yuruna/vms/<old>/` → `<new>/`
  - Per-file rename for files whose basename starts with `<old>`
    (qcow2, seed.iso, autounattend.iso, nvram), so `ls` is
    self-consistent.
  - `virsh dumpxml | <path replace> | virsh define` to fix
    `<disk source file=...>` references that still point at the old
    dir.

  The XML rewrite uses literal string `Replace` on `$oldDir` and
  `"$VMName."` (with the trailing dot to bound the match). Safe for the
  cloud-init naming convention used by the test harness; would
  over-replace if a guest's name happened to be a substring of an
  unrelated XML token.

#### UTM (macOS) — full support via plist surgery

UTM has no first-class rename API, and macOS 26 builds mark the
AppleScript `name` property of `virtual machine` as read-only.
To bypass this limitation, Rename-VM performs direct on-disk surgery while
UTM is offline:

- **Snapshot:** stop VM (`utmctl stop`), 2-second settle pause (QEMU
  helper can keep the qcow2 open briefly), then for each `*.qcow2`
  under `~/yuruna/guest.nosync/<vm>.utm/Data/`:
  `qemu-img snapshot -d <id>` (idempotent overwrite) followed by
  `qemu-img snapshot -c <id>`. Multi-disk VMs get the same id on every
  disk so [`Restore-VMDiskSnapshot`](#restore-vmdisksnapshot) reverts
  them as a group.
- **Rename:** with UTM quit, `killall cfprefsd` to drop the
  preference daemon's cache; renames `~/yuruna/guest.nosync/<old>.utm`
  -> `<new>.utm` (qcow2 disks + snapshots ride the directory); then
  PlistBuddy sets `:Information:Name` in the new bundle's
  `config.plist`, and both `:Registry:<UUID>:Name` and
  `:Registry:<UUID>:Package:Path` in
  `~/Library/Containers/com.utmapp.UTM/Data/Library/Preferences/com.utmapp.UTM.plist`;
  one more `killall cfprefsd` so UTM re-reads our edits on next launch;
  `open -a UTM`; poll `utmctl` until the new name surfaces.
  `:Registry:<UUID>:Package:Bookmark` is left untouched because macOS
  file bookmarks resolve via catalog inode + volume UUID, so a
  same-volume directory rename continues to resolve to the new path.
  Source VM must be stopped (UTM holds an exclusive lock on the bundle
  while running); `Save-VMDiskSnapshot` stops it before calling.

### `Restore-VMDiskSnapshot`

Backs the [`loadDiskSnapshot`](#loaddisksnapshot) action.

| Host | Implementation |
|---|---|
| Hyper-V | Verifies checkpoint exists, stops VM, `Hyper-V\Restore-VMCheckpoint`. |
| KVM | Verifies snapshot via `virsh snapshot-info`, stops domain, `virsh snapshot-revert`. |
| UTM | For each `*.qcow2` in the bundle's `Data/`: `qemu-img snapshot -a <id>`. |

All three leave the VM stopped on return — callers must explicitly
start the VM again, and gate any SSH/console step on
[`sshWaitReady`](#sshwaitready) because a fresh-from-snapshot boot
re-DHCPs and re-handshakes SSH.

### `Test-VMDiskSnapshot`

Probe used by Test-Sequence's [`requiresSnapshot`](#requiressnapshot)
warm-path detection: returns `$true` when snapshot `Id` is present on
VM `VMName`, `$false` otherwise (including when the VM does not exist).
Pure read; never stops the VM, never mutates state.

| Host | Implementation |
|---|---|
| Hyper-V | `Hyper-V\Get-VMCheckpoint -VMName <name> -Name <id>` after a `Get-VMState`-not-`absent` guard. |
| KVM | `virsh snapshot-info --domain <name> --snapshotname <id>` after a `Get-VMState`-not-`absent` guard; exit 0 means present. |
| UTM | `qemu-img snapshot -l` on every `*.qcow2` in the bundle's `Data/`; all disks must list `<id>` for the answer to be true. |

### `Send-Text`, `Send-Key`, `Send-Click`

Back the keystroke and click actions. The mechanism differs sharply
per host (and per `keystrokeMechanism` mode):

| Host | GUI mode | SSH mode |
|---|---|---|
| Hyper-V | `Msvm_Keyboard.TypeText` / scancodes via WMI; mouse via vmconnect + `SendInput`. | OpenSSH to the per-host harness key in `test/status/ssh/`. |
| KVM | `virsh send-key` / `virsh screenshot`; mouse via VNC (libvirt). | Same. |
| UTM | AXUI via accessibility events on the UTM app window; VNC fallback for some keys. | Same. |

Sequence authors don't choose between these — `vmCommunication.keystrokeMechanism`
in [`test.config.yml`](../test/test.config.yml) selects, and the per-host
driver routes.

### Other contract surface

For VM lifecycle (`New-VM`, `Start-VM`, `Stop-VM`, `Remove-VM`,
`Get-VMState`), image fetch (`Get-Image`, `Get-ImagePath`),
discovery (`Wait-VMIp`, `Get-VMIp`, `Get-VMMac`), networking,
caching-proxy port maps, and host-side proxy:
see [Test harness — Yuruna.Host contract](test-harness.md#yurunahost-contract) for the per-function
summary, and each driver's source under
[`host/<short-host>/modules/Yuruna.Host.psm1`](../host) for the
canonical signatures.

---

## Naming collisions to watch

`Yuruna.Host` exports `New-VM`, `Start-VM`, `Stop-VM`, `Remove-VM`,
`Rename-VM` — every one of these is also a cmdlet name in Windows'
`Hyper-V` module. Per-guest scripts under
[`host/windows.hyper-v/`](../host/windows.hyper-v) that import
`Yuruna.Host.psm1` AND call those cmdlets directly to drive Hyper-V
must qualify with `Hyper-V\` (e.g. `Hyper-V\Rename-VM -Name ...`).
`Get-VM`, `Set-VM`, `Set-VMMemory`, `Add-VMDvdDrive`, `Enable-VMTPM`
are NOT in `Yuruna.Host`'s exports and remain safe unqualified.

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.26

Back to [Yuruna](../README.md)
