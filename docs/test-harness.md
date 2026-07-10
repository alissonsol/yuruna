# Test harness — architecture

How `test/` is put together. See [Yuruna Architecture](architecture.md) for project-wide
architecture and [Yuruna Test ...](../test/README.md) for operator usage.

## Entry points

| Script | Purpose |
|--------|---------|
| `Invoke-TestRunner.ps1`                            | Continuous test loop (the daily driver) |
| `New-LocalTestUser.ps1`                            | Create a local OS user (cross-platform: Windows / macOS / Linux) and register it in the default authentication `users.yml` |
| `Remove-TestVMFiles.ps1`                           | Purge test VMs and per-VM artifacts |
| `Repair-CachingProxyForwarder.ps1`                 | macOS/UTM: verify the caching-proxy VM is reachable on the LAN and refresh the `yuruna-caching-proxy` state file |
| `Start-CachingProxy.ps1` / `Stop-CachingProxy.ps1` | Expose the Squid VM to remote clients |
| `Start-StatusService.ps1` / `Stop-StatusService.ps1` | Detached HTTP status UI |
| `Test-CachingProxy.ps1`                            | Preflight a local or remote cache |
| `Test-Config.ps1`                                  | Validate `test.config.yml` + optional notification send |
| `Test-Project.ps1`                                 | One-shot variant: wipe + re-clone `<RepoRoot>/project`, run a single cycle |
| `Test-Sequence.ps1`                                | Dev helper: single sequence, any start/stop step |
| `Test-TesseractOcr.ps1`                            | OCR sanity check via Tesseract (open-source; independent of WinRT) |
| `Test-WinRtOcr.ps1`                                | OCR sanity check via WinRT — also demonstrates the modern-pwsh "closed access" issue |

## Cycle

Each iteration of `Invoke-TestRunner.ps1`:

1. `git pull`, then re-read `test.config.yml`.
2. Every 24h (configurable): refresh base images via `Get-Image.ps1`.
3. For each entry in `guestSequence`:
   - Verify `host/<short-host>/<guestKey>/` exists — missing folder is a
     per-guest failure; other guests still run unless `testCycle.shouldStopOnFailure`.
   - Clean the previous test VM.
   - `New-VM.ps1` → `Start-VM` → poll until running → screenshot
     checkpoints → JSON sequences dispatched via the cycle planner.
4. On first failure: leave the VM, send a Resend notification, exit.

## Modes

`vmCommunication.keystrokeMechanism` in `test.config.yml` selects how the
harness drives guests:

- `"GUI"` — keystroke injection (Hyper-V scancodes, UTM VNC/CGEvent).
  Sequences loaded from `sequences/gui/<name>.yml`.
- `"SSH"` — routes workloads over SSH using a per-host key under
  `test/status/ssh/` that cloud-init injects into each guest.
  `sequences/ssh/<name>.yml`, falling back to `gui/` when no SSH variant
  exists.

Invalid values are normalized to `"GUI"` on startup.

## Module responsibilities

Cross-host harness modules live in `test/modules/`. All host-specific
code (VM lifecycle, image fetch, screenshots, port maps, host proxy)
is delegated to a per-host driver module — see [Yuruna.Host
contract](#yurunahost-contract) below.

| Module | Purpose |
|--------|---------|
| `Test.HostContract`    | Platform detection, git, host-condition guards, `Initialize-YurunaHost` dispatcher |
| `Test.HostIO`          | Per-host I/O provider registry for `Send-Key` / `Send-Text` / `Send-Click` — see [Host I/O registry](host-io.md) |
| `Test.SequenceAction`  | Per-verb metadata registry (FailureLabel + capability requirements) consumed by the engine and the capability gate |
| `Test.SequenceHandler` | Catalog of built-in verb Handler scriptblocks — see [Sequence engine layering](#sequence-engine-layering) |
| `Test.HostCondition`   | Cross-platform facade over `Test.HostCondition.{Mac,Windows}.psm1` — see [Host-condition facade](#host-condition-facade) |
| `Test.Capability`      | [Capability matrix](capability-matrix.md) and cycle-plan gate (refuses cycles whose sequences need an unwired host I/O backend) |
| `Test.Config`          | Cached YAML reader (`Read-TestConfig`, `Get-TestConfigValue`) used by every runner / entry-point |
| `Test.ConfigPreflight` | `Invoke-ConfigGate` — pre-cycle `Test-Config.ps1` gate shared by every entry point |
| `Test.LogLevel`        | Canonical log-level cascade (`Resolve-LogLevel`, `Use-LogLevelFromEnv`) — see [Log-level cascade](loglevels.md) |
| `Test.InnerSpawn`      | `New-InnerRunnerArgList` — type-preserving pwsh -Command argv builder for the outer→inner spawn and `Test-Project` |
| `Test.Output`          | `Write-Pass`/`Fail`/`Warn`/`Section`/`Summary` + counters; reused across `Test-Config` and other check scripts |
| `Test.ConfigValidator` | `Test-AgainstSchema`, `Test-IsSet`, `Test-RepoFreshness` — pieces of `Test-Config.ps1` reusable by future check scripts |
| `Test.PortOwner`       | `Get-PortListenerPid` (Windows HTTP.sys + Unix lsof) + `Resolve-PortOrphan` for the status-service port |
| `Test.Status`          | `status.json` lifecycle |
| `Test.Extension`       | Loader for the pluggable extension areas under `test/extension/<area>/` (authentication, notification) — see [Extensions API](extensions-api.md) |
| `Test.Notify`          | Thin dispatcher to the active notification extension(s) (`Send-Notification -EventCode -EventMessage -EventNote`); default extension delivers email via Resend |
| `Test.Log` / `Test.YurunaDir` | Transcript and state directories |
| `Test.Start-GuestOS`        | Start-GuestOS tile: start.guest.* sequence orchestration |
| `Test.Start-GuestWorkload`  | Start-GuestWorkload tile: post-OS workload sequence orchestration |
| `Test.OcrEngine` / `Test.Tesseract` | Pluggable [OCR providers](ocr.md) |
| `Test.Ssh`             | Per-guest SSH keys + `ssh`/`scp` helpers |
| `Test.Provenance`      | Artifact provenance metadata |
| `Test.VMUtility`       | Cross-host VM helpers shared by every Yuruna.Host driver |

### Yuruna.Host contract

`Initialize-YurunaHost` (in `Test.HostContract`) imports the matching driver
based on host type:

| Host type | Driver |
|-----------|--------|
| `host.windows.hyper-v` | [`host/windows.hyper-v/modules/Yuruna.Host.psm1`](../host/windows.hyper-v/modules/Yuruna.Host.psm1) (real) |
| `host.macos.utm`       | [`host/macos.utm/modules/Yuruna.Host.psm1`](../host/macos.utm/modules/Yuruna.Host.psm1) (real) |
| `host.ubuntu.kvm`      | [`host/ubuntu.kvm/modules/Yuruna.Host.psm1`](../host/ubuntu.kvm/modules/Yuruna.Host.psm1) (real) |

The driver exports a fixed set of contract functions covering VM
lifecycle (`New-VM`, `Start-VM`, `Stop-VM`, `Remove-VM`, `Rename-VM`,
`Get-VMState`), snapshot management (`Save-VMDiskSnapshot`,
`Restore-VMDiskSnapshot`), image fetch (`Get-Image`, `Get-ImagePath`),
VM I/O (`Send-Text`, `Send-Key`, `Send-Click`, `Get-VMScreenshot`),
discovery (`Wait-VMIp`, `Get-VMIp`, `Get-VMMac`), networking
(`Get-ExternalNetwork`, `New-ExternalNetwork`,
`Test-CacheVMOnExternalNetwork`), caching-proxy port maps
(`Add-PortMap`, `Remove-PortMap`, `Test-CachingProxyAvailable`,
`Get-CachingProxyVMIp`), host-side proxy (`Set-HostProxy`,
`Clear-HostProxy`, `Remove-HostProxy`), and virtualization checks
(`Assert-Virtualization`). Per-host implementation notes for the
contracts whose behavior diverges in operationally significant ways
(snapshot + rename, screen I/O):
[Sequence actions and host contracts](test-sequences.md#yurunahost-contract).

Per-cycle dispatch is YAML-driven: each cycle reads
`project/test/test.runner.yml` to get the top-level workload sequence
names, walks each sequence's `baseline` field (object keyed by guest
OS) to derive a dependency-ordered chain, and dispatches each chain
entry through [`modules/Invoke-Sequence.psm1`](../test/modules/Invoke-Sequence.psm1).
Sequences whose name starts with `start.` run during the runner's
Start-GuestOS step; everything else runs during Start-GuestWorkload. No
per-OS `.ps1` glue is required. Full architecture:
[Test Modules](../test/modules/README.md).

## Runtime directories

```
test/
├── sequences/
│   ├── actions.yml             Action catalog (YAML, machine-readable)
│   ├── gui/                    GUI-mode sequences
│   └── ssh/                    SSH-mode sequences (falls back to gui/)
├── schemas/                    JSON Schema files (YAML-encoded) for extension/* configs + vault
├── extension/                  Pluggable extension areas (Test.Extension loader; committed code only)
│   ├── authentication/         default.psm1, authentication.config.yml
│   └── notification/           default.psm1, notification.config.yml, transports.yml.template
├── screenshots/<guestKey>/     [Optional — operator-populated; absent by default]
│   ├── schedule.json           Capture checkpoints + thresholds (create if using screenshot validation)
│   └── reference/*.png         Trained reference screenshots (commit manually per checkpoint)
└── status/                     Status dashboard + ALL harness runtime state
    ├── index.html, hostinfo.html, test.config.html, yuruna.common.{css,js},
    │                           status.json.template     (committed UI)
    ├── runtime/                $env:YURUNA_RUNTIME_DIR -- pids,
    │                           status.json, control flags, ipaddresses.txt,
    │                           caching-proxy.txt, server.err, host.uuid,
    │                           yuruna-caching-proxy.yml, .status-service.ps1
    ├── log/                    $env:YURUNA_LOG_DIR -- HTML transcripts,
    │                           OCR debug, failure screenshots
    ├── perf/                   JSONL perf rows + content-addressed
    │                           host/guest dumps
    ├── extension/
    │   ├── authentication/     vault.yml, vault.lock, events.log (plaintext by design — ephemeral test-VM credentials only; threat model: docs/authentication.md)
    │   └── notification/       transports.yml (Resend API key)
    ├── captures/
    │   ├── sequences/          takeScreenshot debug PNGs
    │   └── training/           per-cycle training captures, guest-prefixed
    └── ssh/                    yuruna_ed25519(.pub) -- generated per host
```

Per-action reference (verb-by-verb behavior and per-host contract
notes) lives in [Test Sequences](test-sequences.md).

### Extension areas

Each area under `test/extension/<area>/` ships a committed
`<area>.config.yml` naming the active `<name>.psm1` modules
(authentication uses exactly `active[0]`; notification iterates the
list). A user override is to drop a sibling `<name>.psm1` next to
`default.psm1` and edit the area's `<area>.config.yml`.

- **authentication** — credential vault simulating an external auth
  provider. The default extension's vault.yml persists across cycles
  (Initialize-VaultConnection is a no-op when the file already
  exists); the "fake" behavior is the lazy-create branch in
  Get-Password (first reference for a username generates+stores a
  password, every later call returns the same stored value). Sequence
  steps fetch live values via
  `${ext:authentication.GetPassword(${username})}` /
  `${ext:authentication.NewRandomPassword()}` substitutions; commits are done
  via the `callExtension` action verb (`authentication.SetPassword`). A named
  system mutex serialises read-modify-write across parallel guests.
- **notification** — per-event-code dispatch (`cycle.failure`,
  `config.smoke`). Subscribers and transport credentials live in
  `test/status/extension/notification/transports.yml` (gitignored
  runtime state); template (`transports.yml.template`) ships in-tree
  under `test/extension/notification/`.

Override track and log directories via `$env:YURUNA_RUNTIME_DIR` and
`$env:YURUNA_LOG_DIR` before launch; the status server remaps the URL
prefixes.

## Self-healing extension points

The harness exposes five registries that the operator, a project,
or a future recovery loop can extend without forking the framework.
Each is enumerated at startup by the [capability matrix](capability-matrix.md);
all five share the
[`New-YurunaRegistry`](../test/modules/Test.Registry.psm1) primitive
and surface through `Get-YurunaRegistryDirectory`:

- [OCR providers](ocr.md) — `Register-OcrProvider`
- [Host I/O registry](host-io.md) — `Register-HostIOProvider`
- Sequence actions — `Register-SequenceAction` (see
  [`Test.SequenceAction.psm1`](../test/modules/Test.SequenceAction.psm1))
- [Component registry login](component-registry.md) — `Register-CredentialProvider`
- [Host-condition registry](host-condition-registry.md) — `Register-HostConditionProvider`

Plus the [remediation dispatcher](remediation.md) (`Register-RecoveryHandler`,
failure-class to recommendation), and the file-based
[Extensions API](extensions-api.md) under
`test/extension/<area>/` for authentication, notification transports,
and caching-proxy log parsing.

The runner lifecycle itself is observable through the explicit
[runner state machine](runner-state.md) (`Set-RunnerState` at every
cycle boundary; NDJSON `runner_state_transition` events). The
operational outer-runner loop and its heartbeat-watchdog are split
into [Test.RunnerOuterLoop](runner-outer-loop.md) and
[Test.RunnerWatchdog](runner-watchdog.md) so both can be unit-tested
independently of the entry-point script.

Cloud-init seed rendering goes through the
[cloud-init template pipeline](cloud-init-template.md) — shared base
+ per-host overlay + placeholder safety net.

## Sequence engine layering

Three modules share the sequence-engine surface:

- `Test.SequenceAction.psm1` — the registry primitive
  (`Register-SequenceAction`, per-verb FailureLabel + capability metadata).
- `Test.SequenceHandler.psm1` — the catalog of built-in verb Handler
  scriptblocks. Adding a verb is a local edit here, not a merge-conflict
  magnet on the engine. Every handler in this module talks to the
  engine purely through the `$Context` hashtable and the standard
  `Yuruna.Host` / `Test.Ssh` / `Test.Extension` / `Test.Log` exports.
- `Invoke-Sequence.psm1` — the engine driver. Two stateful verbs
  (`retry` and `recoverFromSnapshot`) deliberately stay here because
  they coordinate the engine's `$script:LastFailure*` state with the
  recursive `$invokeStepBlock` dispatch. Lifting that state into a
  shared module would be more complex than the merge-conflict surface
  it would buy back.

## Host-condition facade

`Test.HostCondition.psm1` applies *and* asserts per-host preconditions
for unattended VM testing — display sleep / screen lock (macOS,
Windows), Accessibility + Screen Recording TCC grants (macOS), sudo
cache priming, Hyper-V service / firewall / display-scale (Windows),
libvirtd reachability (Ubuntu KVM). The `Set-*` mutators are
operator-facing host-prep; the `Assert-*` gates run every test cycle.
Pure detection / VM-name derivation lives in `Test.HostDetection.psm1`.

Per-platform implementations live in sibling modules
(`Test.HostCondition.Mac.psm1`, `Test.HostCondition.Windows.psm1`,
`Test.HostCondition.Linux.psm1`), imported `-Global -Force` so the
facade can re-export their function names. Each sibling exports a
matched triplet: `Set-<Platform>HostConditionSet` (Enable-TestAutomation
side), `Assert-<Platform>HostConditionSet` (long-running runner gate),
and `Test-<Platform>HostMinimum` (quick check for one-off helpers).
The facade calls `New-YurunaRegistry` and then registers each
platform's triplet via `Register-HostConditionProvider`, so
`Assert-HostConditionSet`, `Test-ElevationRequired`, and
`Test-HostRequirement` are pure registry lookups -- no `switch
($HostType)` chains. Adding a new host is one
`Register-HostConditionProvider` call; existing callers can keep
`Import-Module Test.HostCondition` and resolve names exactly as
before.

## State sidecars

Every harness state sidecar (pidfile, JSON sidecar, runtime marker) goes
through the atomic writer in
[`modules/Test.StateFile.psm1`](../test/modules/Test.StateFile.psm1)
(`Write-YurunaStateFile`, `Write-YurunaStateFileJson`). The contract:

1. Write payload to `<Path>.<PID>-<GUID>.tmp` as UTF-8 (no BOM by
   default; `-WithBom` for PowerShell scripts that must satisfy
   `PSUseBOMForUnicodeEncodedFile`).
2. `Move-Item -Force` into `<Path>` — atomic on same-volume NTFS / ext4
   / APFS, a single rename syscall.
3. Return `$true` on success, `$false` on failure. The helper itself is
   silent — high-frequency callers do not flood `Verbose`. Callers log
   the specific reason at the call site if they need to.

A concurrent reader sees either the prior file (if any) or the new
file in full — never a partial write.

**Per-writer unique temp name.** A fixed `$Path.tmp` lets two processes
writing the same destination (e.g. the runner and the status server
both flushing `status.json`) rename each other's half-written temp.
`PID + GUID` keeps each writer's temp private; the rename to the final
path stays atomic. The `.tmp` suffix is preserved so any `*.tmp`
cleanup/ignore rules still match.

When this helper is used consistently, the boot-recovery sweep can
trust that any sidecar found on disk is either fully-written (current)
or fully-written (previous, awaiting overwrite). A half-written
sidecar is impossible.

## status.json history schema

Each history entry's `guestSummary` is an `[ordered]@{}` so the JSON
preserves `guestSequence` order. A plain `@{}` is a `[hashtable]`
whose enumeration is bucketed and arbitrary, which would scramble the
pill order in the dashboard's "Recent Cycles" table even though the
cycle itself ran in order.

Per-guest value shape (backward-compatible):

| Shape | Meaning |
|-------|---------|
| `"pass"` / `"fail"` (bare string) | Older history rows pre-dating `stepDurationsSec` / `failureArtifacts`. Older dashboards still render these. |
| `{ status, stepDurationsSec, [failureArtifacts] }` | Current form. |

- `stepDurationsSec` is a per-step wall-clock seconds map, one entry
  per step in the guest's step list (`New-VM`, `Start-VM`,
  `Start-GuestOS`, `New-VM.Resource`, optionally `Screenshots` /
  `Start-GuestWorkload`). Unlocks p50/p95 trend analysis across
  history without log-grep.
- `failureArtifacts` is present only when a debug folder exists, so
  pass-only cycles keep the payload tight.

The dashboard reads `.status` off the object form and falls back to
the whole value as a string, so both shapes still render.

Each history entry also carries a `sequenceSummary` array —
`[{ name, status, folderUrl }]`, one element per test.runner.yml
sequence the cycle ran, in runner-list order. The dashboard's "Recent
Cycles" table renders one button per element, linking `folderUrl` to
that sequence's results folder (the driven guest's per-VM folder for a
1:1 sequence; the cycle folder when a sequence fans out to more than
one guest). `status` is the worst of the sequence's guests
(`fail > running > pass > skipped > pending`). The field is `[]` on
the legacy `guestSequence` path (no sequences) and absent from rows
recorded before it existed; the dashboard falls back to per-guest
pills from `guestSummary` in both cases.

Each history entry also carries its own `gitCommits` snapshot so a
row written months ago still links to the right framework + project
commits even if the runner has since picked up a new repo URL or
added/removed a project clone.

## Status-service port-orphan resolution

The PID-file checks in `Start-StatusService.ps1` know only about the
last server *we* launched. A prior detached `pwsh` can still hold the
HttpListener on the configured port if a previous run survived a
terminal close, or a failed launch overwrote `server.pid` with a
stillborn PID. New launches then die with:

```
Failed to listen on prefix 'http://*:<port>/' because it conflicts
with an existing registration on the machine.
```

The detached child logs that to `$RuntimeDir/server.err` and exits,
so the outer script *appears* to start cleanly — nothing is serving,
and any orphan process bound to a stale control-file directory
(`$StatusDir` or `$StatusDir/track` instead of `$RuntimeDir`) keeps
writing there, silently breaking the dashboard's Pause / Cycle
buttons.

`Resolve-PortOrphan` (in `test/modules/Test.PortOwner.psm1`) probes
with a throwaway `HttpListener`. If that succeeds the detached
launch will too. If not, it resolves the real owner via OS tools
(`netstat`/`Get-NetTCPConnection` on Windows HTTP.sys, `lsof` on
Unix) and stops it — **only** if it is a `pwsh` process plausibly
ours. Unknown owners (dev server, another tool) get a clear error
and the launch bails. Sharing the helper out of `Test.PortOwner.psm1`
keeps the same dispatch reusable by future callers (health-check,
`Stop-StatusService`, `Test-CachingProxy`) without depending on the
status server's full module.

## Per-cycle diagnostic capture

`Save-GuestDiagnostic` (Test.Diagnostic.psm1) runs at end-of-cycle to
pull a guest snapshot to the host. It uses a three-rung strategy
chain: **keyed SSH → password SSH → console**. SSH is the default
because it works the same on every host (Linux / macOS / Windows)
without depending on a per-host keyboard injector, the status server
being reachable from the guest, or the guest having an interactive
shell on `tty1`. The console rung is the emergency fallback for the
cases where SSH itself is the bug (sshd down, host-key mismatch, auth
failure) — when SSH is healthy the diagnostic ships immediately
without paying the console-typing latency or risking keystroke
corruption (character-table misses, host-specific Shift handling).

Earlier rungs' outputs are not discarded if they produced text —
`$lastResult` keeps the most informative one so a partial-and-failed
earlier capture is still written when every later rung ends up empty.

**Wait-SshReady pre-flight.** Sequences often end with "Reboot the
VM", so the guest may be mid-reboot when `Save-GuestDiagnostic` runs.
Without a real-handshake gate, the call would either bail at
`Get-GuestAddress` (empty per-guest folder) or write a near-useless
file whose body is just the SSH connection error (a port-22-open but
sshd-still-binding "half-up sshd" race — see
`feedback_save_diag_post_reboot.md`). `Wait-SshReady` polls a real
`echo yuruna-ssh-ready` handshake and re-resolves `Get-GuestAddress`
each iteration, so a late-binding KVP entry on the Hyper-V External
vSwitch is picked up automatically. On timeout we skip without
leaving a useless error file — an empty cycle folder beats a
header-only error file.

The wait budget is capped by `min(180, remaining-of-total-budget)`,
so a near-deadline call cannot push the cycle past the
`$SaveGuestDiagnosticTotalTimeoutSeconds` cap. 180 s covers ARP probe
(~5 s) + typical Linux post-reboot bring-up (60-120 s) + slack.

## Watchdog and per-cycle resilience

The outer runner's job is to keep the inner running forever. Stale
heartbeat detection, single-instance guard, and the failure-pause
back-off protocol all live in [Watchdog](watchdog.md). Per-step
log-stream visibility is controlled by [Log levels](loglevels.md).

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | All guests passed (runner was interrupted or completed) |
| `1` | One or more guests failed, or pre-flight error |

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.10

Back to [Yuruna](../README.md)
