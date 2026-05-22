# Sequence actions and host contracts

Authoritative reference for the actions you can use in sequence files
under [`test/sequences/{gui,ssh}/`](../test/sequences/) and `project/<...>/test/{gui,ssh}/`,
plus the per-host [Yuruna.Host](../host) contract functions that
back the ones with non-trivial cross-host divergence.

- Source of truth for action names is the `switch` block in
  [`test/modules/Invoke-Sequence.psm1`](../test/modules/Invoke-Sequence.psm1).
- Schema for the YAML shape is
  [`test/schemas/actions.schema.yml`](../test/schemas/actions.schema.yml).
- Short one-paragraph catalogue (consumed by tooling) is
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

## Action reference

### break

Cooperative breakpoint. Writes `.yuruna-break-<NNN>.lock` under the
per-guest `cycleGuestDataFolder` and busy-waits for one of two resume
signals:

- **Manual** — operator deletes the marker file. Sequence just resumes.
- **UI Continue** — operator clicks the **Continue** button rendered on
  the status page (`http://localhost:8080/status/`) for the running
  guest's card. The button POSTs to `/control/break-continue`; the
  action consumes the flag, calls
  [`Restore-VMDiskSnapshot`](#restore-vmdisksnapshot) with `break.id`
  (skipped silently when `id` is not set), then
  [`Start-VM`](#yurunahost-contract) (snapshot restore always leaves
  the VM stopped), then resumes.

The Continue button is driven by `/runtime/break-active.json`, a sidecar
the action writes on entry and removes on exit. Not a failure — the
step succeeds either way. `YURUNA_BREAK_DISABLED=1` turns the action
into a no-op for unattended runs.

Login after a snapshot-restore is **the sequence author's
responsibility** — the guest boots fresh from the snapshot disk and
will be sitting at the login prompt, so place
[`passwdPrompt`](#passwdprompt) / [`sshWaitReady`](#sshwaitready) /
similar steps after the break.

| Parameter | Type | Notes |
|---|---|---|
| `reason` | string | Optional. Written into the marker file so the operator knows why we stopped. |
| `id` | string | Optional. Snapshot id to restore on Continue. Typically the id of a `saveDiskSnapshot` step earlier in the same sequence. Omit for a "just pause" break with no snapshot restore on Continue. |

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
engine then calls [`Start-VM`](#start-vm) (Hyper-V / KVM / UTM all
implement the contract). No RAM-state is restored — guest boots fresh
from the snapshot disk, so re-DHCP and SSH re-handshake are expected
(gate downstream consumers on `sshWaitReady`, and on-screen consumers
on `waitForText` for the login prompt).

| Parameter | Type | Notes |
|---|---|---|
| `id` | string | Required. Snapshot name previously written by `saveDiskSnapshot`. |

### passwdPrompt

Like `waitForAndEnter`, but `text` is always treated as sensitive — for
PAM prompts (`Current password:`, `Retype new password:`) whose
non-newline-terminated lines get overwritten on the framebuffer by late
console messages (see [memory note on passwd prompt
overwrite](memory.md)). Parameters are the same as
`waitForAndEnter`, minus the explicit `sensitive` flag.

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
(`vmconnect` must be open). UTM: not yet implemented.

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
`Initialize-YurunaHost` (in [`Test.Host`](../test/modules/Test.Host.psm1)).
See [Test harness — architecture](test-harness.md#yurunahost-contract) for the full list.

Below are the contract functions whose **per-host behaviour diverges in
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

#### UTM (macOS) — best-effort

UTM has no first-class rename API. `utmctl` exposes no `rename` verb,
and the AppleScript dictionary marks `name` of `virtual machine` as
`access="r"` in many UTM builds.

- **Snapshot:** stop VM (`utmctl stop`), 2-second settle pause (QEMU
  helper can keep the qcow2 open briefly), then for each `*.qcow2`
  under `~/yuruna/guest.nosync/<vm>.utm/Data/`:
  `qemu-img snapshot -d <id>` (idempotent overwrite) followed by
  `qemu-img snapshot -c <id>`. Multi-disk VMs get the same id on every
  disk so [`Restore-VMDiskSnapshot`](#restore-vmdisksnapshot) reverts
  them as a group.
- **Rename:** `osascript -e 'tell application "UTM" to set name of
  virtual machine "<old>" to "<new>"'`. On UTM versions where `name` is
  read-only the script exits non-zero; the contract function returns
  `$false` with a clear warning explaining the cause. The qcow2
  snapshot is still preserved inside the bundle, so an operator can
  restore it manually even if the VM gets re-created with a different
  display name on the next cycle.

  The heavier alternative (config.plist edit + `utmctl delete` +
  bundle dir rename + re-`open`) was considered and rejected:
  `utmctl delete` may or may not nuke the bundle depending on UTM
  version, and re-import semantics for bundles outside `~/Documents`
  aren't stable enough to ship without a test bed.

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
caching-proxy port maps, host-side proxy, and SSH server lifecycle:
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

Back to [Test harness](test-harness.md) · [Test Modules](../test/modules/README.md) ·
[Yuruna Test ...](../test/README.md) · [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
