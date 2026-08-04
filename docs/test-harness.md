# Test harness — architecture

How `test/` is put together. See [Yuruna Architecture](architecture.md) for project-wide
architecture and [Yuruna Test ...](../test/README.md) for operator usage.

## Entry points

| Script | Purpose |
|--------|---------|
| `Invoke-TestRunner.ps1`                            | Continuous test loop (the daily driver) |
| `New-LocalTestUser.ps1`                            | Create a local OS user (Windows / macOS / Ubuntu), optionally with a password and machine-administrator rights, and register it in the default authentication `users.yml` |
| `Remove-TestVMFiles.ps1`                           | Purge test VMs and per-VM artifacts |
| `Repair-CachingProxyServiceForwarder.ps1`                 | macOS/UTM: verify the caching-proxy-service VM is reachable on the LAN and refresh the `yuruna-caching-proxy-service` state file |
| `Start-CachingProxyServiceVM.ps1` / `Stop-CachingProxyServiceVM.ps1` | Expose the Squid VM to remote clients |
| `Start-StatusService.ps1` / `Stop-StatusService.ps1` | Detached HTTP status UI |
| `Test-CachingProxyService.ps1`                            | Preflight a local or remote cache |
| `Test-Config.ps1`                                  | Validate `test.config.yml` + optional notification send |
| `Invoke-TestProject.ps1`                                 | One-shot variant: wipe + re-clone `<RepoRoot>/project`, run a single cycle |
| `Invoke-TestSequence.ps1`                                | Dev helper: single sequence, any start/stop step |
| `Test-TesseractOcr.ps1`                            | OCR sanity check via Tesseract (open-source; independent of WinRT) |
| `Test-WinRtOcr.ps1`                                | OCR sanity check via WinRT — also demonstrates the modern-pwsh "closed access" issue |

## Cycle

Each iteration of `Invoke-TestRunner.ps1`:

1. `git pull`, then re-read `test.config.yml`.
2. Every 24h (configurable): refresh base images via `Get-Image.ps1`.
3. For each entry in `guestSequence`:
   - Verify `host/<short-host>/<guestKey>/` exists — missing folder is a
     per-guest failure; other guests still run unless `testCycle.stopOnFailure`.
   - Clean the previous test VM.
   - `New-VM.ps1` → `Start-VM` → poll until running → screenshot
     checkpoints → YAML sequences dispatched via the cycle planner.
4. On first failure: leave the VM, send a Resend notification, exit.

## Modes

Each sequence declares its own `keystrokeMechanism` (gui|ssh, default
gui), selecting how the harness drives the guest:

- `gui` — keystroke injection (Hyper-V scancodes, UTM VNC/CGEvent).
- `ssh` — routes workloads over SSH using a per-host key under
  `test/status/ssh/` that cloud-init injects into each guest.

Sequences live flat under `sequences/<name>.yml`; an SSH variant is a
distinct `<name>.ssh.yml` sequence selected by its own name.

## Module responsibilities

Cross-host harness modules live in `test/modules/`. All host-specific
code (VM lifecycle, image fetch, screenshots, port maps, host proxy)
is delegated to a per-host driver module — see [Yuruna.Host
contract](#yurunahost-contract).

| Module | Purpose |
|--------|---------|
| `Test.HostContract`    | Platform detection, git, host-condition guards, `Initialize-YurunaHost` dispatcher |
| `Test.HostIO`          | Per-host I/O provider registry for `Send-Key` / `Send-Text` / `Send-Click` — see [Host I/O registry](host-io.md) |
| `Test.SequenceAction`  | Per-verb metadata registry (FailureLabel + capability requirements) consumed by the engine and the capability gate |
| `Test.SequenceHandler` | Catalog of built-in verb Handler scriptblocks — see [Sequence engine layering](#sequence-engine-layering) |
| `Test.HostCondition`   | Cross-platform facade over `Test.HostCondition.{Mac,Windows,Linux}.psm1` — see [Host-condition registry](#host-condition-registry) |
| `Test.Capability`      | [Capability matrix](capability-matrix.md) and cycle-plan gate (refuses cycles whose sequences need an unwired host I/O backend) |
| `Test.Config`          | Cached YAML reader (`Read-TestConfig`, `Get-TestConfigValue`) used by every runner / entry-point |
| `Test.ConfigPreflight` | `Invoke-ConfigGate` — pre-cycle `Test-Config.ps1` gate shared by every entry point |
| `Test.LogLevel`        | Canonical log-level cascade (`Resolve-LogLevel`, `Use-LogLevelFromEnv`) — see [Log-level cascade](loglevels.md) |
| `Test.InnerSpawn`      | `New-InnerRunnerArgList` — type-preserving pwsh -Command argv builder for the outer→inner spawn and `Invoke-TestProject` |
| `Test.Output`          | `Write-Pass`/`Fail`/`Warn`/`Section`/`Summary` + counters; reused across `Test-Config` and other check scripts |
| `Test.ConfigValidator` | `Test-AgainstSchema`, `Test-IsSet`, `Test-RepoFreshness` — pieces of `Test-Config.ps1` reusable by future check scripts |
| `Test.PortOwner`       | `Get-PortListenerPid` (Windows HTTP.sys + Unix lsof) + `Resolve-PortOrphan` for the status-service port |
| `Test.Status`          | `status.json` lifecycle |
| `Test.Extension`       | Loader for the pluggable extension areas under `test/extension/<area>/` (authentication, notification), plus `Get-ExtensionHostAddress` — where a service area (stash, pool-control service) is reachable for this host — see [Extensions API](extensions-api.md) |
| `Test.Notify`          | Thin dispatcher to the active notification extension(s) (`Send-Notification -EventCode -EventMessage -EventNote`); default extension delivers email via Resend |
| `Test.Log` / `Test.YurunaDir` | Transcript and state directories |
| `Test.Start-GuestOS`        | Start-GuestOS tile: start.guest.* sequence orchestration |
| `Test.Start-GuestWorkload`  | Start-GuestWorkload tile: post-OS workload sequence orchestration |
| `Test.OcrEngine` / `Test.Tesseract` | Pluggable [OCR providers](ocr.md) |
| `Test.Ssh`             | Per-guest SSH keys + `ssh`/`scp` helpers |
| `Test.Provenance`      | Artifact provenance metadata |
| `Test.VMUtility`       | Cross-host VM helpers shared by every Yuruna.Host driver |

### Test.Config* role pyramid

The three `Test.Config*` modules in the table split by role:
`Test.Config` is the mtime-cached YAML reader (the data layer);
`Test.ConfigValidator` holds the schema + freshness primitives (the
rules layer), reusable across callers; `Test.ConfigPreflight` is the
pre-cycle gate that spawns `Test-Config.ps1` and refuses the cycle on
FAIL items (the policy layer). "Preflight" names the *when* (before
each cycle) instead of the *mechanism* (a gate).

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
`Test-CacheVMOnExternalNetwork`), caching-proxy-service port maps
(`Add-PortMap`, `Remove-PortMap`, `Test-CachingProxyServiceAvailable`,
`Get-CachingProxyServiceVmIp`), host-side proxy (`Set-HostProxy`,
`Clear-HostProxy`, `Remove-HostProxy`), and virtualization checks
(`Assert-Virtualization`). Per-host notes for the contracts that
diverge in operationally significant ways (snapshot + rename, screen
I/O):
[Sequence actions and host contracts](test-sequences.md#yurunahost-contract).

Per-cycle dispatch is YAML-driven: each cycle reads
`project/test/test.runner.yml` to get the top-level workload sequence
names, walks each sequence's `resource` field (object keyed by guest
OS; the legacy `baseline` spelling is rejected with a migration error)
to derive a dependency-ordered chain, and dispatches each chain
entry through [`modules/Test.SequenceEngine.psm1`](../test/modules/Test.SequenceEngine.psm1).
Sequences whose name starts with `start.` run during the runner's
Start-GuestOS step; everything else runs during Start-GuestWorkload. No
per-OS `.ps1` glue is required. Full architecture:
[Test Modules](../test/modules/README.md).

## Runtime directories

```
test/
├── sequences/
│   ├── actions.yml             Action catalog (YAML, machine-readable)
│   ├── _snippets.yml           Shared step snippets
│   └── <name>[.ssh].yml        Flat sequence files (SSH variant = .ssh.yml suffix)
├── schemas/                    JSON Schema files (YAML-encoded) for extension/* configs + vault
├── extension/                  Pluggable extension areas (Test.Extension loader; committed code only)
│   ├── authentication/         default.psm1, authentication.config.yml
│   ├── notification/           default.psm1, notification.config.yml, transports.yml.template
│   └── …                       7 areas total — see [extensions-api.md](extensions-api.md)
├── screenshots/<guestKey>/     [Optional — operator-populated; absent by default]
│   ├── schedule.json           Capture checkpoints + thresholds (create if using screenshot validation)
│   └── reference/*.png         Trained reference screenshots (commit manually per checkpoint)
└── status/                     Status dashboard + ALL harness runtime state
    ├── index.html, host.html, config.html, yuruna.common.{css,js},
    │                           status.json.template     (committed UI)
    ├── runtime/                $env:YURUNA_RUNTIME_DIR -- pids,
    │                           status.json, control flags, ipaddresses.txt,
    │                           caching-proxy-service.txt, server.err, host.uuid,
    │                           yuruna-caching-proxy-service.yml, .status-service.ps1
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
list). To override, drop a sibling `<name>.psm1` next to
`default.psm1` and edit the area's `<area>.config.yml`.

- **authentication** — credential vault simulating an external auth
  provider. The default extension's vault.yml persists across cycles
  (Initialize-VaultConnection is a no-op when the file already
  exists); the "fake" behavior is the lazy-create branch in
  Get-Password (first reference for a username generates+stores a
  password, every later call returns the same stored value). Sequence
  steps fetch live values via
  `${ext:authentication.GetPassword(${username})}` /
  `${ext:authentication.NewRandomPassword()}` substitutions; commits go
  through the `callExtension` action verb (`authentication.SetPassword`). A
  named system mutex serializes read-modify-write across parallel guests.
- **notification** — per-event-code dispatch (`cycle.failure`,
  `config.smoke`). Subscribers and transport credentials live in
  `test/status/extension/notification/transports.yml` (gitignored
  runtime state); template (`transports.yml.template`) ships in-tree
  under `test/extension/notification/`.

Override track and log directories via `$env:YURUNA_RUNTIME_DIR` and
`$env:YURUNA_LOG_DIR` before launch; the status service remaps the URL
prefixes.

## Self-healing extension points

The harness exposes five registries that the operator, a project,
or a future recovery loop can extend without forking the framework.
Each is enumerated at startup by the [capability matrix](capability-matrix.md);
four of the five share the
[`New-YurunaRegistry`](../test/modules/Test.Registry.psm1) primitive
and surface through `Get-YurunaRegistryDirectory`. The exception is the
component-login credential-provider registry, which uses the same
eviction-safe global-anchor pattern but is hand-rolled in
[`automation/Yuruna.CredentialProvider.psm1`](../automation/Yuruna.CredentialProvider.psm1)
(so it stays out of `test/` and is not in `Get-YurunaRegistryDirectory`):

- [OCR providers](ocr.md) — `Register-OcrProvider`
- [Host I/O registry](host-io.md) — `Register-HostIOProvider`
- Sequence actions — `Register-SequenceAction` (see
  [`Test.SequenceAction.psm1`](../test/modules/Test.SequenceAction.psm1))
- [Component registry login](authentication.md#component-registry-login) — `Register-CredentialProvider`
- [Host-condition registry](#host-condition-registry) — `Register-HostConditionProvider`

Plus the [remediation dispatcher](failure-schema.md#remediation-dispatcher) (`Register-RecoveryHandler`,
failure-class to recommendation), and the file-based
[Extensions API](extensions-api.md) under
`test/extension/<area>/` for authentication, notification transports,
and caching-proxy-service log parsing.

The runner lifecycle is observable through the
[runner state machine](runner-outer-loop.md#runner-state-machine) (`Set-RunnerState` at every
cycle boundary; NDJSON `runner_state_transition` events). The
outer-runner loop and its heartbeat-watchdog are split
into [Test.RunnerOuterLoop](runner-outer-loop.md) and
[Test.RunnerWatchdog](runner-outer-loop.md#module-testrunnerwatchdog) so both can be unit-tested
independently of the entry-point script.

Cloud-init seed rendering goes through the
[cloud-init template pipeline](vmconfig.md#how-user-data-is-rendered) — shared base
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
- `Test.SequenceEngine.psm1` — the engine driver. Two stateful verbs
  (`retry` and `recoverFromSnapshot`) deliberately stay here because
  they coordinate the engine's `$script:LastFailure*` state with the
  recursive `$invokeStepBlock` dispatch. Lifting that state into a
  shared module would cost more complexity than the merge-conflict
  surface it buys back.

## Host-condition registry

Each supported host platform (Windows Hyper-V, macOS UTM, Ubuntu KVM)
exposes the same three-method contract:

- `Set-<Platform>HostConditionSet` — apply settings the unattended
  runner needs (display timeout, screen lock, sudo cache, libvirt
  group membership, ...). Called by `Enable-TestAutomation.ps1`.
- `Assert-<Platform>HostConditionSet` — gate every test cycle on
  those settings still being in effect.
- `Test-<Platform>HostMinimum` — quick check for one-off operator
  helpers (`Remove-TestVMFiles.ps1`, `Remove-OrphanedVMFiles.ps1`,
  ...) where the full Assert would be a false positive during
  interactive maintenance.

The facade
[`test/modules/Test.HostCondition.psm1`](../test/modules/Test.HostCondition.psm1)
holds the registry; each platform sibling
([`.Mac`](../test/modules/Test.HostCondition.Mac.psm1),
[`.Windows`](../test/modules/Test.HostCondition.Windows.psm1),
[`.Linux`](../test/modules/Test.HostCondition.Linux.psm1))
is imported `-Global -Force` so the facade can re-export their
function names, and exports the matched triplet plus a few
platform-specific helpers (TCC grants on macOS, firewall rules on
Windows, libvirt diagnostics on Linux). Pure detection / VM-name
derivation lives in `Test.HostDetection.psm1`.

The registry replaces parallel per-host dispatch chains — an
`if/elseif` on `$HostType` inside `Assert-HostConditionSet` plus a
`switch ($HostType)` in `Test-HostRequirement`
([`Test.HostDetection`](../test/modules/Test.HostDetection.psm1)):
inline dispatch needs two edits in two files per new host; the
registry needs one `Register-HostConditionProvider` call. Callers keep
`Import-Module Test.HostCondition` and resolve names as before.

### Public surface

| Function | Used by |
|---|---|
| `Register-HostConditionProvider -HostType -Set -Assert -AssertMinimum [-RequiresElevation] [-Display] [-DisplayTeardown] [-ClockSync]` | Facade loader; external host plugins |
| `Get-HostConditionProvider -HostType` | Dispatchers; introspection |
| `Get-HostConditionProviderMatrix` | Startup capability matrix |
| `Clear-HostConditionProvider` | Tests only |
| `Assert-HostConditionSet -HostType` | Outer runner per-cycle gate |
| `Get-HostClockSkew` / `Get-HostClockSkewLimit` | Host-clock measurement (direct NTP over UDP) |
| `Write-HostClockDriftWarning -HostType` | Every platform's `Assert` — measures once per process and warns |
| `Reset-HostClockReport` | Tests only (re-arms the once-per-process latch) |
| `Sync-HostClock -HostType` | `Test-Config` fix offer; `Enable-TestAutomation.ps1` — never a running cycle |
| `Test-ElevationRequired -HostType` | Cleanup helpers ([`Test.HostDetection`](../test/modules/Test.HostDetection.psm1)) |
| `Test-HostRequirement -HostType [-Quiet]` | One-off operator helpers ([`Test.HostDetection`](../test/modules/Test.HostDetection.psm1)) |

### Provider record shape

Each registration carries an eight-field ordered dict:

```
@{
    HostType          = 'host.windows.hyper-v'
    Set               = { param([string]$HostType) ... }
    Assert            = { param([string]$HostType) ... [bool] }
    AssertMinimum     = { param() ... [bool] }
    RequiresElevation = $true   # consumed by Test-ElevationRequired
    Display           = { param() ... }   # optional: per-cycle display-surface ensure (e.g. attach a virtual monitor on headless Hyper-V); $null when unneeded. Invoked by Initialize-HostDisplay.
    DisplayTeardown   = { param() ... }   # optional inverse: tear the surface down; $null when unneeded. Invoked by Remove-HostDisplay.
    ClockSync         = { param() ... @{ Succeeded; Message } }   # optional: put this host's clock back under NTP discipline. Invoked by Sync-HostClock from the operator-facing paths only -- it needs privileges an unattended cycle cannot obtain.
}
```

`Set` and `Assert` are paired; both take `-HostType` and may be
called multiple times per cycle. `AssertMinimum` is lighter than
`Assert` (no display-timeout / screen-lock / TCC-grant checks), for
cleanup helpers that legitimately run during interactive maintenance.

### Three platforms today

| HostType | RequiresElevation | What `Assert` gates on | `ClockSync` |
|---|---|---|---|
| `host.windows.hyper-v` | `$true` | Administrator elevation, vmms service, display timeout, lock screen | W32Time → Automatic + started + `w32tm /resync /force` |
| `host.macos.utm` | `$false` | Accessibility + Screen Recording TCC grants, display sleep, screen lock | `systemsetup -setusingnetworktime on` + `sntp -sS` |
| `host.ubuntu.kvm` | `$false` | `/dev/kvm` present, libvirtd active, virsh round-trip, current shell's group set includes `libvirt` | `timedatectl set-ntp true` + step the active daemon |

Every `Assert` also reports the host clock, but never gates on it —
see below.

The Linux `Assert` diagnostic distinguishes "kvm missing" from
"libvirtd down" from "stale group set" from "not in libvirt group at
all" so the operator gets actionable steps, not a generic
"permission denied".

### The host clock

Every hypervisor here seeds a guest's clock from the host at
power-on, so a host that has drifted starts every VM equally wrong —
and the guest's own NTP client steps it to real time seconds into the
boot, landing in the middle of whatever that guest is bringing up. A
Kubernetes guest survives that step looking healthy from every angle
except the one that matters: pods `Running` but never `Ready` (their
status timestamps sit in the future, so `kubectl` prints their age as
`<invalid>`), Services with no endpoints, every NodePort refusing,
while a `curl` straight at the pod IP answers `200`. Nothing in that
picture points back at a clock.

A cycle reports the clock; only an operator repairs it. Every
platform's fix is a privileged call — Administrator, or a sudo
credential nobody is present to type — so an unattended loop can
neither perform it nor stop to ask, and a host that refused cycles
over a clock would run none until someone noticed.

| Level | What happens |
|-------|--------------|
| `Write-HostClockDriftWarning`, in every platform's `Assert` | Measures **once per process** (a fresh process runs each cycle, so once per cycle) and warns past `Get-HostClockSkewLimit` (120s) with the symptom spelled out. The cycle continues. An **unmeasurable** clock says nothing — an isolated lab has no route to a time server and is a normal deployment. |
| `Test-Config.ps1` | Reports the skew, then offers the repair — only to a console that can answer. Accepting primes the sudo credential cache (`Initialize-SudoCache`) before `Sync-HostClock`, because every platform's sync is `sudo -n` and would otherwise fail on the answer just given. |
| `Set-*HostConditionSet` / `Enable-TestAutomation.ps1` | The durable fix: enable the platform's time service so it stays disciplined. |

`Get-HostClockSkew` speaks NTP directly over UDP rather than shelling
out to the platform's time client: on a drifting host that client is
usually broken or absent, its output is localized, and its timeouts
are not ours to choose. It returns `$null` — never `0` — when nothing
answers, so "unreachable network" can never be mistaken for
"disciplined clock".

### Registry shape

The facade calls
[`New-YurunaRegistry -Name 'HostCondition' -AnchorVar
'YurunaHostConditionProviders'`](../test/modules/Test.Registry.psm1)
and exposes thin wrappers around `Register` / `Get` / `GetMatrix` /
`Clear`. The provider entries survive `-Force` re-imports of the
facade because the backing store is anchored under
`$global:YurunaHostConditionProviders` — the same eviction-safety
pattern `Test.HostIO`, `Test.SequenceAction`, and `Test.CredentialProvider`
use. `Assert-HostConditionSet`, `Test-ElevationRequired`, and
`Test-HostRequirement` are therefore pure registry lookups.

### Adding a new host

1. Implement the three functions for your platform:
   - `Set-<Platform>HostConditionSet -HostType <id>`
   - `Assert-<Platform>HostConditionSet -HostType <id>`
   - `Test-<Platform>HostMinimum`
2. Add a sibling module under `test/modules/Test.HostCondition.<Platform>.psm1`
   and export the triplet.
3. Add the sibling to the facade's `Import-Module` block; add the
   `Register-IfAvailable` line listing the new HostType + function
   names + `RequiresElevation`. Add `-ClockSyncFn` pointing at a
   `Sync-<Platform>HostClock` that returns `@{ Succeeded; Message }`
   — without it the platform reports a drifted clock but offers the
   operator no way to fix it.
4. Add the matching `HostType` token to
   [`Test.HostDetection`](../test/modules/Test.HostDetection.psm1)'s
   `Get-HostType` discovery so the new platform is detectable.
5. Provide a host driver under
   `host/<short>/modules/Yuruna.Host.psm1`
   matching the `Yuruna.Host` contract (`New-VM`, `Start-VM`,
   `Stop-VM`, `Remove-VM`, `Get-VMState`, ...).
6. The startup capability matrix picks the new entry up
   automatically.

Related registries: [Component registry login](authentication.md#component-registry-login)
— same eviction-safe global-anchor pattern, hand-rolled in
`automation/Yuruna.CredentialProvider.psm1` rather than on
`New-YurunaRegistry`; [Host I/O registry](host-io.md) — the older
two-level registry that established the pattern. Per-platform deep
dives: [macOS host](host-macos.md), [Hyper-V host](host-hyperv.md).

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
file in full — never a partial write, so the boot-recovery sweep can
trust every sidecar it finds on disk.

**Per-writer unique temp name.** A fixed `$Path.tmp` lets two processes
writing the same destination (e.g. the runner and the status service
both flushing `status.json`) rename each other's half-written temp.
`PID + GUID` keeps each writer's temp private; the rename to the final
path stays atomic. The `.tmp` suffix is preserved so any `*.tmp`
cleanup/ignore rules still match.

## status.json history schema

Each history entry's `guestSummary` is an `[ordered]@{}` so the JSON
preserves `guestSequence` order. A plain `@{}` is a `[hashtable]`
whose enumeration is bucketed and arbitrary, which would scramble the
pill order in the dashboard's "Recent Cycles" table even though the
cycle ran in order.

Per-guest value shape (backward-compatible):

| Shape | Meaning |
|-------|---------|
| `"pass"` / `"fail"` (bare string) | Older history rows pre-dating `stepDurationsSeconds` / `failureArtifacts`. Older dashboards still render these. |
| `{ status, stepDurationsSeconds, [failureArtifacts] }` | Current form. |

- `stepDurationsSeconds` is a per-step wall-clock seconds map, one entry
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

The detached child logs that to `$RuntimeDir/server.err` and exits, so
the outer script *appears* to start cleanly while nothing is serving,
and any orphan bound to a stale control-file directory (`$StatusDir`
or `$StatusDir/track` instead of `$RuntimeDir`) keeps writing there,
silently breaking the dashboard's Pause / Cycle buttons.

`Resolve-PortOrphan` (in `test/modules/Test.PortOwner.psm1`) probes
with a throwaway `HttpListener`. If that succeeds the detached
launch will too. If not, it resolves the real owner via OS tools
(`netstat`/`Get-NetTCPConnection` on Windows HTTP.sys, `lsof` on
Unix) and stops it — **only** if it is a `pwsh` process plausibly
ours. Unknown owners (dev server, another tool) get a clear error
and the launch bails. Keeping the helper in `Test.PortOwner.psm1`
makes the dispatch reusable by future callers (health-check,
`Stop-StatusService`, `Test-CachingProxyService`) without pulling in the
status service's full module.

## Status-service port and the host firewall

`Start-StatusService` binds `http://*:<port>/` (every interface), but a
host firewall silently DROPs inbound TCP on non-loopback interfaces
unless an allow rule exists — so localhost answers while a LAN client
(the pool-aggregator service, an operator's browser) times out. One host with
this gap disappears from the pool dashboard and drops its extension-host
deep-link. `Test.StatusFirewall.psm1` centralizes the per-OS allow-rule
logic used by BOTH the one-time elevated host setup
(`Set-WindowsHostConditionSet` / `host/ubuntu.kvm/Enable-TestAutomation.ps1`)
and the best-effort self-heal at every status-service start. Managed:
Windows Defender Firewall (`New-NetFirewallRule`) and Linux ufw.
Reported but never touched: nftables/iptables without ufw, and the macOS
application firewall (application-scoped, not port-scoped — the port is
not blocked by default).

## Per-cycle diagnostic capture

`Save-GuestDiagnostic` (Test.Diagnostic.psm1) runs at end-of-cycle to
pull a guest snapshot to the host. It uses a three-rung strategy
chain: **keyed SSH → password SSH → console**. SSH is the default
because it works the same on every host (Linux / macOS / Windows)
without a per-host keyboard injector, a guest-reachable status
service, or an interactive shell on `tty1`. The console rung is the
emergency fallback for when SSH itself is the bug (sshd down, host-key
mismatch, auth failure); when SSH is healthy the diagnostic ships
immediately, skipping console-typing latency and keystroke corruption
(character-table misses, host-specific Shift handling).

Earlier rungs' text output is not discarded — `$lastResult` keeps the
most informative one, so a partial-and-failed earlier capture is still
written when every later rung ends up empty.

**Wait-SshReady pre-flight.** Sequences often end with "Reboot the
VM", so the guest may be mid-reboot when `Save-GuestDiagnostic` runs.
Without a real-handshake gate, the call would either bail at
`Get-GuestAddress` (empty per-guest folder) or write a near-useless
file whose body is just the SSH connection error (a port-22-open but
sshd-still-binding "half-up sshd" race — see
`feedback_save_diag_post_reboot.md`). `Wait-SshReady` polls a real
`echo yuruna-ssh-ready` handshake and re-resolves `Get-GuestAddress`
each iteration, so a late-binding KVP entry on the Hyper-V External
vSwitch is picked up automatically. On timeout we skip: an empty cycle
folder beats a header-only error file.

The wait budget is capped by `min(180, remaining-of-total-budget)`,
so a near-deadline call cannot push the cycle past the
`$SaveGuestDiagnosticTotalTimeoutSeconds` cap. 180 s covers ARP probe
(~5 s) + typical Linux post-reboot bring-up (60-120 s) + slack.

## Watchdog and per-cycle resilience

The outer runner's job is to keep the inner running forever. Stale
heartbeat detection, single-instance guard, and the failure-pause
back-off protocol all live in
[Watchdog](runner-outer-loop.md#watchdog-and-heartbeat-protocol). Per-step
log-stream visibility is controlled by [Log levels](loglevels.md).

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | All guests passed (runner was interrupted or completed) |
| `1` | One or more guests failed, or pre-flight error |

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.04

Back to [Yuruna](../README.md)
