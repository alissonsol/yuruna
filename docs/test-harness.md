<a id="42d38664-0001"></a>

# Test harness -- architecture

How `test/` is put together. See [Yuruna Architecture](architecture.md) for project-wide
architecture and [Yuruna Test ...](../test/README.md) for operator usage.

<a id="42d38664-0002"></a>

## Entry points

| Script | Purpose |
|--------|---------|
| `Start-TestRunner.ps1`                             | Continuous test loop (the daily driver) |
| `New-LocalTestUser.ps1`                            | Create a local OS user (Windows / macOS / Ubuntu), optionally with a password and machine-administrator rights, and register it in the default authentication `users.yml` |
| `Remove-TestVMFiles.ps1`                           | Purge test VMs and per-VM artifacts |
| `service/Repair-CachingProxyServiceForwarder.ps1`  | macOS/UTM: verify the caching-proxy-service VM is reachable on the LAN and refresh the `yuruna-caching-proxy-service` state file |
| `service/Start-CachingProxyServiceVM.ps1` / `service/Stop-CachingProxyServiceVM.ps1` | Expose the Squid VM to remote clients |
| `service/Start-StatusService.ps1` / `service/Stop-StatusService.ps1` | Detached HTTP status UI |
| `Test-CachingProxyService.ps1`                            | Preflight a local or remote cache |
| `Test-Config.ps1`                                  | Validate `test.config.yml` + optional notification send |
| `Invoke-TestProject.ps1`                                 | One-shot variant: wipe + re-clone `<RepoRoot>/project`, run a single cycle |
| `Debug-TestSequence.ps1`                                 | Dev helper: single sequence, any start/stop step |
| `check/Test-TesseractOcr.ps1`                      | OCR sanity check via Tesseract (open-source; independent of WinRT) |
| `check/Test-WinRtOcr.ps1`                          | OCR sanity check via WinRT -- also demonstrates the modern-pwsh "closed access" issue |

`test/` itself holds the seven entry points an operator reaches for daily. The
rest are grouped by what they act on: `test/lab/` (standing a lab up on this
host -- the four host-neutral entry points, lab creation, local storage, token
enrollment), `test/pool/` (the pool-admin CLI and the sample intent files),
`test/service/` (service VM and host-service lifecycle, plus the
caching-proxy-service operations), `test/check/` (standalone sanity checks), `test/modules/` (harness
internals, not invoked directly). The repo-wide encoding gate lives at
`tools/Test-AsciiNoBom.ps1`.

<a id="42d38664-0003"></a>

## Cycle

Each iteration of `Start-TestRunner.ps1`:

1. `git pull`, then re-read `test.config.yml`.
2. Every 24h (configurable): refresh base images via `Get-Image.ps1`.
3. For each guest in the cycle plan resolved from `test/test.runner.yml` in the
   project repository (`guestSequence` is the fallback, read only when that
   file resolves no plan):
   - Verify `host/<short-host>/<guestKey>/` exists -- missing folder is a
     per-guest failure; other guests still run unless `testCycle.stopOnFailure`.
   - Clean the previous test VM.
   - `New-VM.ps1` -> `Start-VM` -> poll until running -> screenshot
     checkpoints -> YAML sequences dispatched via the cycle planner.
4. On first failure: leave the VM, send a Resend notification, exit.

Ahead of each chain entry and each sequence step the
[lab-health gate](failure-schema.md#the-lab-health-gate-lab_health_-events) checks
the lab's declared services and **holds** the cycle -- the same parked state the
*Pause* button produces -- while one that was answering is away, resuming when it
returns. A service this host has never reached never holds, so a host with no
stash still fails fast rather than parking.

<a id="42d38664-0004"></a>

## Modes

Each sequence declares its own `keystrokeMechanism` (gui|ssh, default
gui), selecting how the harness drives the guest:

- `gui` -- keystroke injection (Hyper-V scancodes, UTM VNC/CGEvent).
- `ssh` -- routes workloads over SSH using a per-host key under
  `test/status/ssh/` that cloud-init injects into each guest.

Sequences live flat under `sequences/<name>.yml`; an SSH variant is a
distinct `<name>.ssh.yml` selected by its own name.

<a id="42d38664-0005"></a>

## Module responsibilities

Cross-host harness modules live in `test/modules/`. All host-specific
code (VM lifecycle, image fetch, screenshots, port maps, host proxy)
is delegated to a per-host driver module -- see [Yuruna.Host
contract](#yurunahost-contract).

Every module in `test/modules/` appears below, grouped by the question it
answers, so a new function can be placed without grepping the tree. Where a
family has one sibling per host or per platform, the siblings share a row: they
hold no logic beyond wiring their platform into the family's registry, so they
are never the right home for anything new.

**Sequence engine and cycle planning** -- what a step is, and which steps a
cycle runs:

| Module | Purpose |
|--------|---------|
| `Test.SequenceEngine`  | Engine driver: the step loop, `Wait-ForText`, and the two stateful verbs (`retry`, `recoverFromSnapshot`) -- see [Sequence engine layering](#sequence-engine-layering) |
| `Test.SequenceHandler` | Catalog of built-in verb Handler scriptblocks |
| `Test.SequenceAction`  | Per-verb metadata registry (FailureLabel, capability requirements, engine-behavior flags) consumed by the engine and the capability gate |
| `Test.SequenceVariable`| `${var}` and `${ext:area.Method(...)}` substitution in step text |
| `Test.SequenceResolve` | Parses a sequence YAML and resolves a sequence name to a file across the flat search path |
| `Test.SequencePlanner` | Builds the per-cycle plan from `test.runner.yml` plus each sequence's `resource` chain |
| `Test.SequenceRunner`  | Chain planning + chain execution helpers for `Debug-TestSequence.ps1` |
| `Test.SequenceFailureState` | The single `$global:`-anchored failure-slot store that the engine and the handler catalog both read and write |
| `Test.Orchestrator`    | Runs an orchestration sequence's inner sequences in-process under one `status.json` cycle |
| `Test.Start-GuestOS` / `Test.Start-GuestWorkload` | The two runner tiles: the planner walks each top-level resource chain, sends `start.*` sequences to the first, and sends everything else to the second |
| `Test.Capability`      | [Capability matrix](#capability-matrix-and-cycle-plan-gate) and cycle-plan gate (refuses cycles whose sequences need an unwired host I/O backend) |
| `Test.WarmResume`      | Which failure classes an in-place resume is sound for, plus the checkpoint that says which step to resume at |
| `Test.Backoff`         | Shared poll-delay math (exponential, jittered) for every filesystem-state wait loop |

Dispatcher modules use the `Test.<exported-cmdlet>.psm1` filename convention so
source searches and status-UI click-throughs land on their exported entry point.

**Driving and perceiving the guest** -- keyboard, mouse, screen, OCR, SSH:

| Module | Purpose |
|--------|---------|
| `Test.HostIO`          | Per-host I/O provider registry for `Send-Key` / `Send-Text` / `Send-Click` -- see [Host I/O registry](host-io.md) |
| `Test.HostIO.{HyperV,Kvm,Utm}` | Registration-only wiring: bind each host type to its backends. No logic |
| `Test.Transport`       | The backend bodies themselves -- PS/2 scancodes, VNC/RFB, AppleScript/CGEvent -- and the settle windows they need |
| `Test.KeyCodeRegistry` | Per-transport key-code and character tables the transports look up |
| `Test.VncProvider`     | VNC connection registry + `Repair-VncConnection`, which forces the next call to re-handshake after a cached handle goes stale |
| `Test.ScreenshotProvider` | Screenshot-capture provider registry + `Repair-ScreenshotRing` |
| `Test.OcrEngine` / `Test.Tesseract` | Pluggable [OCR providers](ocr.md) and the Tesseract locate / install / invoke helpers |
| `Test.OcrMatch`        | OCR-tolerant normalization and matching (confusion groups) + the multi-engine combiner |
| `Test.Ssh`             | Per-guest SSH keys, the mandatory host-key options, and the `ssh` / `scp` helpers |

**Host platform** -- what this machine is, and what it must be for a cycle to run:

| Module | Purpose |
|--------|---------|
| `Test.HostContract`    | Thin facade re-exporting the four `Test.Host*` siblings; new code imports the sibling directly |
| `Test.HostDetection`   | Host-type discovery, host-folder mapping, test VM-name derivation, minimum-requirement checks |
| `Test.HostBootstrap`   | `Initialize-YurunaHost` -- imports the matching `Yuruna.Host` driver into the runner's session |
| `Test.HostCondition` (+ `.Mac`, `.Windows`, `.Linux`) | Facade + per-platform Set/Assert/AssertMinimum triplets -- see [Host-condition registry](#host-condition-registry) |
| `Test.HostGit`         | Cycle-start framework update (`Invoke-GitPull`), HEAD short hashes, project wipe-and-re-clone, Windows file-locker PID diagnosis after `Remove-Item` failures (Restart Manager / PEB current-directory scanner), repository-access answers for pool UIs (`Get-HostRepositoryAccess`), and on-demand PSGallery installs (`powershell-yaml`, `PSScriptAnalyzer`) PowerShell 7 does not ship |
| `Test.HostAutomationState` | Records each host knob's prior value before `Enable-TestAutomation` writes it, so `Disable` can restore rather than guess |
| `Test.HostFacts`       | The machine's own hardware facts in the shape `/control/host-facts` serves them, including the storage-counting rules |
| `Test.HostIdentity`    | Hardware fingerprint + the operator-confirmed uuid reclaim that keeps a reimaged host's pool history from forking |
| `Test.HostAddressBeacon` | Push half of address discovery: re-announces this host when its address changes instead of waiting for the aggregator's pull |
| `Test.VMUtility`       | Cross-host VM helpers shared by every Yuruna.Host driver |
| `Test.ServiceVm`       | Service-VM roster and the reachability probe that brings them back after a host reboot |
| `Test.StatusFirewall`  | Per-OS allow rule that makes the status-service port reachable from the LAN |
| `Test.RootArtifact`    | Finds and clears the root-owned state a `sudo` run of an entry point leaves behind (Unix only) |

**Runner lifecycle** -- starting, supervising and recovering the loop:

| Module | Purpose |
|--------|---------|
| `Test.Prelude`         | The canonical path bundle, module-set bootstrap and exit-code contract every entry point starts from |
| `Test.RunnerOuterLoop` | The eternal loop -- see [Runner outer loop](runner-outer-loop.md) |
| `Test.RunnerInnerLoop` | Per-cycle helpers threaded through one cycle by the inner runner |
| `Test.RunnerWatchdog`  | Out-of-process step-heartbeat watchdog; kills a wedged inner |
| `Test.RunnerHeartbeat` | Threadpool-timer process heartbeat, which keeps ticking while the runspace blocks |
| `Test.RunnerState`     | Explicit outer-runner state machine with persisted state + NDJSON transition events |
| `Test.RunnerElevation` | Launch-time elevation contract: resolve it once while an operator is present, or refuse to start |
| `Test.SingleInstance`  | Pidfile guard shared by the runner trio (`Get-RunnerInstanceState`, `Stop-StaleRunner`) |
| `Test.InnerSpawn`      | `New-InnerRunnerArgList` -- type-preserving `pwsh -Command` argv builder for the outer->inner spawn and `Invoke-TestProject` |
| `Test.Recovery`        | Boot-time sweep that detects and archives every stale state class a crashed cycle left behind |

**Configuration**:

| Module | Purpose |
|--------|---------|
| `Test.Config`          | Cached YAML reader (`Read-TestConfig`, `Get-TestConfigValue`) used by every runner / entry point |
| `Test.ConfigValidator` | `Test-AgainstSchema`, `Test-IsSet`, `Test-RepoFreshness` -- the rules layer, reusable by any check script |
| `Test.ConfigPreflight` | `Invoke-ConfigGate` -- pre-cycle `Test-Config.ps1` gate shared by every entry point |
| `Test.ConfigSync`      | Live `test.config.yml` <-> shipped-template reconciliation at cycle start |
| `Test.ConfigNaming`    | The retired-key table: old dotted path -> new path + unit factor, shared by the validator and the rewriter |
| `Test.ConfigServiceSync` | Copies a reference pool host's configuration onto this host, converting the host-type-specific values |
| `Test.ConfigServiceCA` | Per-host Config CA (mTLS) backing the config service: one server leaf, one client leaf per VM |
| `Test.LogLevel`        | Canonical log-level cascade (`Resolve-LogLevel`, `Use-LogLevelFromEnv`) -- see [Log-level cascade](loglevels.md) |

**Logging, status and telemetry**:

| Module | Purpose |
|--------|---------|
| `Test.Log`             | Cycle-filesystem owner: cycle folder, per-guest subfolders, `cycle.events.ndjson`, `manifest.json` |
| `Test.Output`          | Per-script PASS/FAIL/WARN tally + `Write-Summary` banner, reused across `Test-Config` and the check scripts |
| `Test.LogRotation`     | Byte-bounded N-file rotation for the cycle-independent append-only files |
| `Test.YurunaDir`       | Resolves and creates `$env:YURUNA_LOG_DIR` / `$env:YURUNA_RUNTIME_DIR` |
| `Test.Status`          | `status.json` lifecycle, including the nested-cycle lock |
| `Test.EventSchema`     | Validates every NDJSON record at the emit site, so a field typo is caught before it lands on disk |
| `Test.Perf`            | One JSONL perf row per step execution, one file per cycle |
| `Test.Provenance`      | Reads the base-image provenance sidecar `Get-Image.ps1` writes |
| `Test.FrameworkSource` | Which framework snapshot a service VM was built from, and whether the guest fell back to the public mirror |
| `Test.PortOwner`       | `Get-PortListenerPid` (Windows HTTP.sys + Unix lsof) + `Resolve-PortOrphan` for the status-service port |
| `Test.Notify`          | Thin dispatcher to the active notification extension(s) (`Send-Notification -EventCode -EventMessage -EventNote`); the default extension delivers email via Resend |

**Failure classification and recovery**:

| Module | Purpose |
|--------|---------|
| `Test.FailureTaxonomy` | Canonical `FailureClass` / `Severity` arrays; a leaf module every other consumer reads from |
| `Test.Remediation`     | Failure-class -> recovery dispatcher (`Register-RecoveryHandler`) -- see [Failure schema](failure-schema.md) |
| `Test.GuestQuarantine` | Per-guest circuit breaker: N same-class failures quarantine that guest, with host-scoped classes excluded |
| `Test.Diagnostic`      | Post-failure guest capture and its strategy chain -- see [Per-cycle diagnostic capture](#per-cycle-diagnostic-capture) |
| `Test.SnapshotManifest`| Snapshot sidecars, so a restore can refuse a snapshot it does not recognize |
| `Test.CredentialProvider` | Test-only inspection / repair helpers over the [component-login registry](authentication.md#component-registry-login) |

**Pool and lab** -- everything that is only meaningful with more than one machine:

| Module | Purpose |
|--------|---------|
| `Test.PoolSync`        | Pulls the pool intent (membership + desiredState) and reconciles it into the outer loop |
| `Test.PoolPlanner`     | Turns the pool's assigned test-sets into the subset of guests this host can actually run |
| `Test.PoolAdmin`       | Helpers behind the pool-admin CLI; every change is schema-validated before it is committed |
| `Test.PoolStorage`     | Optional SMB3 share as the durable tier for cycle output, plus the drain that commits and reclaims |
| `Test.PoolPush`        | Pushes a cycle's NDJSON to the aggregator over CA-pinned HTTPS, closing the between-poll gap |
| `Test.PoolNotifier`    | Delivers the aggregator's pool-degraded alerts through the notification extension, spooled on the share |
| `Test.PoolWorker`      | Converting a standalone host into a pool worker, and retiring the local services that would otherwise win the lookup |
| `Test.Lab`             | Lab-vault format and the machine-credential lookup; read-only, and never mints a credential |
| `Test.LocalLabStorage` | Turns one machine into its own SMB pool/stash server so a single-host lab exercises the network path |

**Extensions and service VMs**:

| Module | Purpose |
|--------|---------|
| `Test.Extension`       | Loader for the pluggable extension areas under `test/extension/<area>/`, plus `Get-ExtensionHostAddress` -- where a service area is reachable for this host -- see [Extensions API](extensions-api.md) |
| `Test.ExtensionService`| The `service:` manifest an area declares about itself, and the runtime marker saying this host runs it |
| `Test.DownloadAgentService` | Host-side download-agent lifecycle: the marker, the readiness probe, the published address |
| `Test.CachingProxyService` | Cross-cycle state for the caching-proxy-service VM (admin password + IP) -- see [Caching](caching.md) |
| `Test.CachingProxyServiceLock` | The serialization lock around caching-proxy-service rebuild / port-map writes, and the adopt-if-healthy decision |

**Shared primitives** -- leaf modules with no harness dependencies:

| Module | Purpose |
|--------|---------|
| `Test.Registry`        | `New-YurunaRegistry` -- the closure-bundle + global-anchor primitive every registry above is built on |
| `Test.StateFile`       | Atomic sidecar writer -- see [State sidecars](#state-sidecars) |
| `Test.Hash`            | Byte array -> lowercase hex, so every hashing caller shares one encoding |
| `Test.Assert`          | The suite assertion vocabulary and test scaffolds -- see [One assertion vocabulary](#one-assertion-vocabulary). Imported by suites only, never by harness code |

<a id="42d38664-0006"></a>

### Test.Config* role pyramid

The three `Test.Config*` modules in the table split by role:
`Test.Config` is the mtime-cached YAML reader (the data layer);
`Test.ConfigValidator` holds the schema + freshness primitives (the
rules layer), reusable across callers; `Test.ConfigPreflight` is the
pre-cycle gate that spawns `Test-Config.ps1` and refuses the cycle on
FAIL items (the policy layer).

<a id="42d38664-0007"></a>

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
Start-GuestOS step; everything else runs during Start-GuestWorkload. The cycle
planner collects them by walking each top-level resource chain; no per-OS
`.ps1` glue is required. Full architecture:
[Test Modules](../test/modules/README.md).

<a id="42d38664-0008"></a>

## Runtime directories

```
test/
+-- sequences/
|   +-- actions.yml             Action catalog (YAML, machine-readable)
|   +-- _snippets.yml           Shared step snippets
|   +-- <name>[.ssh].yml        Flat sequence files (SSH variant = .ssh.yml suffix)
+-- schemas/                    JSON Schema files (YAML-encoded) for extension/* configs + vault
+-- extension/                  Pluggable extension areas (Test.Extension loader; committed code only)
|   +-- authentication/         default.psm1, authentication.config.yml
|   +-- notification/           default.psm1, notification.config.yml, transports.yml.template
|   +-- ...                       8 areas total -- see [extensions-api.md](extensions-api.md)
+-- screenshots/<guestKey>/     [Optional -- operator-populated; absent by default]
|   +-- schedule.json           Capture checkpoints + thresholds (create if using screenshot validation)
|   +-- reference/*.png         Trained reference screenshots (commit manually per checkpoint)
+-- status/                     Status dashboard + ALL harness runtime state
    +-- index.html, diagnostics.html, config.html, yuruna.common.{css,js},
    |                           status.json.template     (committed UI)
    +-- runtime/                $env:YURUNA_RUNTIME_DIR -- pids,
    |                           status.json, control flags, ipaddresses.txt,
    |                           caching-proxy-service.txt, server.err, host.uuid,
    |                           yuruna-caching-proxy-service.yml, .status-service.ps1
    +-- log/                    $env:YURUNA_LOG_DIR -- HTML transcripts,
    |                           OCR debug, failure screenshots
    +-- perf/                   JSONL perf rows + content-addressed
    |                           host/guest dumps
    +-- extension/
    |   +-- authentication/     vault.yml, vault.lock, events.log (plaintext by design -- ephemeral test-VM credentials only; threat model: docs/authentication.md)
    |   +-- notification/       transports.yml (Resend API key)
    +-- captures/
    |   +-- sequences/          takeScreenshot debug PNGs
    |   +-- training/           per-cycle training captures, guest-prefixed
    +-- ssh/                    yuruna_ed25519(.pub) -- generated per host
```

Per-action reference (verb-by-verb behavior and per-host contract
notes) lives in [Test Sequences](test-sequences.md).

<a id="42d38664-0009"></a>

### Extension areas

Each area under `test/extension/<area>/` ships a committed
`<area>.config.yml` naming the active `<name>.psm1` modules
(authentication uses exactly `active[0]`; notification iterates the
list). To override, drop a sibling `<name>.psm1` next to
`default.psm1` and edit the area's `<area>.config.yml`.

- **authentication** -- credential vault simulating an external auth
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
- **notification** -- per-event-code dispatch (`cycle.failure`,
  `config.smoke`). Subscribers and transport credentials live in
  `test/status/extension/notification/transports.yml` (gitignored
  runtime state); template (`transports.yml.template`) ships in-tree
  under `test/extension/notification/`.

Override runtime and log directories via `$env:YURUNA_RUNTIME_DIR` and
`$env:YURUNA_LOG_DIR` before launch; the status service remaps the URL
prefixes.

<a id="42d38664-000a"></a>

## Pester discovery and file-scope variables

A suite that stands up a throwaway `$env:YURUNA_RUNTIME_DIR` names it from
`$PID` and holds that name in an UNQUALIFIED (not `$script:`-qualified)
file-scope variable. Both details are load-bearing, and both failures are
silent:

- The file's body is executed during Pester's DISCOVERY pass -- and, when the
  file is run as the entry script, once more before that.
  `$env:YURUNA_RUNTIME_DIR` is process-global, so the last body execution wins,
  while the `It` blocks read the name captured by the first. A per-execution
  GUID would therefore point the module under test at one directory and the
  assertions at another; a `$PID`-derived name is identical in every pass, so
  the two cannot diverge.
- An `It` block runs in a fresh script scope. A `$script:`-qualified read from a
  test resolves to THAT scope and comes back `$null` even though the file
  assigned the name. Only an unqualified name walks the scope chain out to the
  file's own variables.

Cleanup belongs in `AfterAll` for the same reason, never at the end of the file:
file-level code runs during discovery, BEFORE any `It`, so a trailing
`Remove-Item` deletes the directory the tests are about to mint into rather than
cleaning up after them.

Fixtures and helper functions belong in a `BeforeAll` -- the scope Pester shares
with every `It`. A file-scope assignment resolves under `pwsh -File <suite>` and
binds as EMPTY under `Invoke-Pester -Path <suite>`, so a suite written that way
reports green one way and red the other. See
[Pester file-scope fixtures](memory.md#pester-file-scope-fixtures) for the full
rule, including the three placements that look like the trap and are correct.
`Test.SuiteHelperAdoption.Tests.ps1` fails any suite that declares no
`BeforeAll`.

<a id="42d38664-000b"></a>

## Running the suites

The suites are **not** part of a test cycle. They run beside the harness:

```
pwsh -NoProfile -File tools/Invoke-TestSuite.ps1            # everything
pwsh -NoProfile -File tools/Invoke-TestSuite.ps1 -Filter 'Test.Pool*'
pwsh -NoProfile -File tools/Invoke-TestSuite.ps1 -ListOnly  # discovery only
```

One process per suite, so one suite's imports, global state or crash cannot
color another's result. Each child sets a `PesterConfiguration` and then invokes
the suite with the call operator rather than `Invoke-Pester -Path`, which is
what keeps the file-scope-fixture suites working while still emitting NUnit XML.

**The exit code of a single suite is not a pass/fail signal.** Pester's
standalone path does not propagate a failing run through the call operator: a
suite whose tests fail still returns 0, and one that discovers nothing returns 0
with zero tests. The runner therefore reads the result file and fails on five
conditions -- no result file (crash, parse error, timeout), failures or errors,
zero tests, a suite in the baseline missing from the run, or a suite's test
count below its baseline. The last two are what catch SILENT test loss: a
deleted suite and a `Describe` that quietly stopped discovering half its cases.

`test/modules/suite-baseline.json` is that reference and is tracked. Re-record
it with `-UpdateBaseline` only as a deliberate, reviewed change -- it is the only
thing standing between the suite set and a slow leak of coverage.

`tools/Invoke-GoTest.ps1` is the same idea for the extension services: `go
build`, `go vet` and `go test` per module, discovered by walking for `go.mod`.

<a id="42d38664-000c"></a>

## One assertion vocabulary

Suites import [`Test.Assert.psm1`](../test/modules/Test.Assert.psm1) rather than
declaring their own helpers -- `Assert-True/False/Equal/StringEqual/NotEqual/
Null/NotNull/Match/Throw/NoFinding`, plus `Get-YurunaTestRepoRoot`,
`New-YurunaTestTempDir` and the AST loaders. `Test.SuiteHelperAdoption.Tests.ps1`
fails a suite that redeclares any of them; without that guard the count grew from
234 to 296 hand-rolled definitions, in three mutually incompatible meanings for
`Assert-Equal`.

`Assert-Equal` compares **by value**; `Assert-StringEqual` compares string
renderings. They are separate exports because they genuinely differ -- on leading
zeros, whitespace, float rendering, `$null` against an empty string, and, most
sharply, on arrays, where `-ne` filters element-wise instead of comparing and so
REJECTS two identical arrays. They are NOT separated by type strictness:
`1 -ne '1'` is false in both.

<a id="42d38664-000d"></a>

## Self-healing extension points

The harness exposes five registries that the operator, a project,
or a future recovery loop can extend without forking the framework.
Each is enumerated at startup by the [capability matrix](#capability-matrix-and-cycle-plan-gate);
four of the five share the
[`New-YurunaRegistry`](../test/modules/Test.Registry.psm1) primitive
and surface through `Get-YurunaRegistryDirectory`.
`New-YurunaRegistry -Name '<DomainName>'` returns a closure-bundle
hashtable (`Register` / `Get` / `Has` / `GetMatrix` / `Clear`
scriptblocks) closing over a shared backing store anchored under
`$global:__YurunaRegistry__<DomainName>`, so a `-Force` re-import of
the calling module does not evict already-registered entries. Domain
modules wrap the bundle with their own `Register-*`/`Get-*` names; the
primitive itself stays generic so future per-cycle registries can
reuse it. The exception is the
component-login credential-provider registry, which uses the same
eviction-safe global-anchor pattern but is hand-rolled in
[`automation/Yuruna.CredentialProvider.psm1`](../automation/Yuruna.CredentialProvider.psm1)
(so it stays out of `test/` and is not in `Get-YurunaRegistryDirectory`):

- [OCR providers](ocr.md) -- `Register-OcrProvider`
- [Host I/O registry](host-io.md) -- `Register-HostIOProvider`
- Sequence actions -- `Register-SequenceAction` (see
  [`Test.SequenceAction.psm1`](../test/modules/Test.SequenceAction.psm1))
- [Component registry login](authentication.md#component-registry-login) -- `Register-CredentialProvider`
- [Host-condition registry](#host-condition-registry) -- `Register-HostConditionProvider`

Plus the [remediation dispatcher](failure-schema.md#remediation-dispatcher) (`Register-RecoveryHandler`,
failure-class to recommendation), and the file-based
[Extensions API](extensions-api.md) under
`test/extension/<area>/` for authentication, notification transports,
and caching-proxy-service log parsing.

Lab availability is its own extension point in practice, though it registers
nothing: [`Test.LabHealth.psm1`](../test/modules/Test.LabHealth.psm1) derives what
to probe from the `service:` manifests under `test/extension/<area>/`, so an area
that declares a `healthPort` is gated with no framework edit at all.

The runner lifecycle is observable through the
[runner state machine](runner-outer-loop.md#runner-state-machine) (`Set-RunnerState` at every
cycle boundary; NDJSON `runner_state_transition` events). The
outer-runner loop and its heartbeat-watchdog are split
into [Test.RunnerOuterLoop](runner-outer-loop.md) and
[Test.RunnerWatchdog](runner-outer-loop.md#module-testrunnerwatchdog) so both can be unit-tested
independently of the entry-point script.

Cloud-init seed rendering goes through the
[cloud-init template pipeline](vmconfig.md#how-user-data-is-rendered) -- shared base
+ per-host overlay + placeholder safety net.

<a id="42d38664-000e"></a>

## Sequence engine layering

Three modules share the sequence-engine surface:

- `Test.SequenceAction.psm1` -- the registry primitive
  (`Register-SequenceAction`, per-verb FailureLabel + capability metadata).
- `Test.SequenceHandler.psm1` -- the catalog of built-in verb Handler
  scriptblocks. Adding a verb is a local edit here, not a merge-conflict
  magnet on the engine. Every handler in this module talks to the
  engine purely through the `$Context` hashtable and the standard
  `Yuruna.Host` / `Test.Ssh` / `Test.Extension` / `Test.Log` exports.
- `Test.SequenceEngine.psm1` -- the engine driver. Two stateful verbs
  (`retry` and `recoverFromSnapshot`) deliberately stay here because
  they coordinate the engine's `$script:LastFailure*` state with the
  recursive `$invokeStepBlock` dispatch. Lifting that state into a
  shared module would cost more complexity than the merge-conflict
  surface it buys back.

<a id="42d38664-000f"></a>

## Capability matrix and cycle-plan gate

At every cycle start the inner runner publishes a single banner naming
what the harness can do on the current host -- which OCR engines are
available, which host I/O actions are wired, which extensions are
active in each area. The same matrix is cross-referenced against the
per-cycle sequence plan: cycles that reference an unimplemented host
I/O action fail before any VM is touched, with a message naming the
missing backend instead of failing late inside a step with
"Unknown host: ...".

Implementation:
[`test/modules/Test.Capability.psm1`](../test/modules/Test.Capability.psm1).
Surfaces three underlying registries:
[OCR providers](ocr.md),
[host I/O providers](host-io.md), and
[extension areas](extensions-api.md).

<a id="42d38664-0010"></a>

### The banner

```
---------------------------------------------------------
Yuruna capability matrix (host.windows.hyper-v)
---------------------------------------------------------
  Host I/O:   Send-Click, Send-Key, Send-Text
  OCR:        winrt, tesseract
  Recovery:   VNC reconnect (built-in (clear cached handle)), screenshot (legacy capture)
  Extensions:
    authentication         default
    caching-proxy-parser-service   default
    notification           default
---------------------------------------------------------
```

Printed once per cycle, right after `Resolve-CyclePlan` succeeds. Lands
in the per-cycle HTML log via the Information stream, so post-mortem
readers see what was wired at cycle start without re-running.

<a id="42d38664-0011"></a>

### The cycle-plan gate

After printing the banner the inner calls
`Test-CyclePlanCapabilityFromPlan`, which:

1. Walks every sequence in the cycle plan (including nested `retry`
   blocks) and collects the action verbs used.
2. For each verb, looks up its requirements via
   [`Test.SequenceAction\Get-SequenceActionRequirementMap`](../test/modules/Test.SequenceAction.psm1) --
   each verb declares which host I/O actions it needs and whether OCR
   is required.
3. Cross-references the requirements against the live
   `Test.HostIO`/`Test.OcrEngine` matrices.

When a required host I/O action is missing the cycle aborts with:

```
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  CAPABILITY GATE FAILED -- cycle aborted on 'host.ubuntu.kvm'.
  Sequences reference host I/O actions this host has no backend for:
    - Send-Click
  Wire a backend via Register-HostIOProvider in Test.SequenceEngine.psm1,
  or drop the requiring action from the cycle's sequence YAMLs.
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
```

A required OCR engine but no enabled+available provider produces the
parallel:

```
  Sequences require OCR but no OCR provider is enabled+available.
  Install tesseract or wire a per-host provider via Register-OcrProvider.
```

The cycle does NOT spin up a VM after a capability-gate failure;
`$GuestList` is emptied so the per-guest loop runs zero iterations,
and the cycle finalizes with `$OverallPassed=false`. This bumps
`ConsecutiveFailures` and fires notifications on the same threshold
as any other failure.

<a id="42d38664-0012"></a>

### Unknown verbs are warnings, not failures

When a sequence references a verb not registered in
`Test.SequenceAction`, the gate emits a `Write-Warning` listing the
unknown verbs but does NOT abort the cycle. The engine's action
switch in
[`Test.SequenceEngine.psm1`](../test/modules/Test.SequenceEngine.psm1)
throws at runtime; the warning surfaces the typo / new-verb-in-progress
before the slow path.

<a id="42d38664-0013"></a>

### What's in the requirements table

Today (see the `Register-SequenceAction` calls in
[`Test.SequenceHandler.psm1`](../test/modules/Test.SequenceHandler.psm1)):

| Verb                     | HostIO required           | OCR required |
|--------------------------|---------------------------|--------------|
| `pressKey`               | `Send-Key`                | no           |
| `inputText`              | `Send-Text`               | no           |
| `inputTextAndEnter`      | `Send-Text`, `Send-Key`   | no           |
| `tapOn`                  | `Send-Click`              | yes          |
| `waitForText`            | _(none)_                  | yes          |
| `waitForTextWithNudge`   | `Send-Key`                | yes          |
| `waitForAndEnter`        | `Send-Text`, `Send-Key`   | yes          |
| `passwdPrompt`           | `Send-Text`, `Send-Key`   | yes          |
| `fetchAndExecute`        | `Send-Text`, `Send-Key`   | yes          |
| `networkRelease`         | `Send-Text`, `Send-Key`   | no           |
| `sshExec` / `sshFetchAndExecute` / `sshWaitReady` | _(none)_ | no |
| `saveDiskSnapshot` / `loadDiskSnapshot` / `saveSystemDiagnostic` / `takeScreenshot` / `break` / `callExtension` / `recoverFromSnapshot` / `retry` / `waitForSeconds` | _(none)_ | no |

Adding a new verb means one `Register-SequenceAction` call that
declares its capabilities -- the gate picks it up on the next cycle.

<a id="42d38664-0014"></a>

### Guest coverage caveats

One Apple-licensing exception breaks the harness's assumption that
every guest can run on every host: **macOS 26** can only be
virtualized on a macOS host. `host/windows.hyper-v/guest.macos.26/`
and `host/ubuntu.kvm/guest.macos.26/` do not exist by design;
`host/macos.utm/guest.macos.26/` is the only path. Cycle plans that
target `guest.macos.26` on a non-macOS host fail at planner time,
when the guest folder proves undiscoverable, not deep inside a step.

<a id="42d38664-0015"></a>

### Calling the matrix outside a cycle

The matrix is queryable programmatically:

```
Import-Module test/modules/Test.Capability.psm1 -Global -Force
Import-Module test/modules/Test.SequenceEngine.psm1 -Global -Force   # populates the registries

$matrix = Get-HostCapabilityMatrix -HostType 'host.windows.hyper-v'
$matrix.hostIO        # @('Send-Key','Send-Text','Send-Click')
$matrix.ocr           # @('winrt','tesseract')
$matrix.extensions    # ordered dict: area -> [active...]
```

Used by future health-checks, CI smoke tests, and the upcoming
`/control/capability` endpoint on the status service.

<a id="42d38664-0016"></a>

## Host-condition registry

Each supported host platform (Windows Hyper-V, macOS UTM, Ubuntu KVM)
exposes the same three-method contract:

- `Set-<Platform>HostConditionSet` -- apply settings the unattended
  runner needs (display timeout, screen lock, sudo cache, libvirt
  group membership, ...). Called by `Enable-TestAutomation.ps1`.
- `Assert-<Platform>HostConditionSet` -- gate every test cycle on
  those settings still being in effect.
- `Test-<Platform>HostMinimum` -- quick check for one-off operator
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

The registry replaces parallel per-host dispatch chains: inline
dispatch needs two edits in two files per new host; the registry needs
one `Register-HostConditionProvider` call. Callers keep
`Import-Module Test.HostCondition` and resolve names as before.

<a id="42d38664-0017"></a>

### Public surface

| Function | Used by |
|---|---|
| `Register-HostConditionProvider -HostType -Set -Assert -AssertMinimum [-RequiresElevation] [-Display] [-DisplayTeardown] [-ClockSync]` | Facade loader; external host plugins |
| `Get-HostConditionProvider -HostType` | Dispatchers; introspection |
| `Get-HostConditionProviderMatrix` | Startup capability matrix |
| `Clear-HostConditionProvider` | Tests only |
| `Assert-HostConditionSet -HostType` | Outer runner per-cycle gate |
| `Get-HostClockSkew` / `Get-HostClockSkewLimit` | Host-clock measurement (direct NTP over UDP) |
| `Write-HostClockDriftWarning -HostType` | Every platform's `Assert` -- measures once per process and warns |
| `Reset-HostClockReport` | Tests only (re-arms the once-per-process latch) |
| `Sync-HostClock -HostType` | `Test-Config` fix offer; `Enable-TestAutomation.ps1` -- never a running cycle |
| `Test-ElevationRequired -HostType` | Cleanup helpers ([`Test.HostDetection`](../test/modules/Test.HostDetection.psm1)) |
| `Test-HostRequirement -HostType [-Quiet]` | One-off operator helpers ([`Test.HostDetection`](../test/modules/Test.HostDetection.psm1)) |

<a id="42d38664-0018"></a>

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

<a id="42d38664-0019"></a>

### Three platforms today

| HostType | RequiresElevation | What `Assert` gates on | `ClockSync` |
|---|---|---|---|
| `host.windows.hyper-v` | `$true` | Administrator elevation, vmms service, display timeout, lock screen | W32Time -> Automatic + started + `w32tm /resync /force` |
| `host.macos.utm` | `$false` | Accessibility + Screen Recording TCC grants, display sleep, screen lock | `systemsetup -setusingnetworktime on` + `sntp -sS` |
| `host.ubuntu.kvm` | `$false` | `/dev/kvm` present, libvirtd active, virsh round-trip, current shell's group set includes `libvirt` | `timedatectl set-ntp true` + step the active daemon |

Every `Assert` also reports the host clock, but never gates on it --
see below.

The Linux `Assert` diagnostic distinguishes "kvm missing" from
"libvirtd down" from "stale group set" from "not in libvirt group at
all" so the operator gets actionable steps, not a generic
"permission denied".

<a id="42d38664-001a"></a>

### The host clock

Every hypervisor here seeds a guest's clock from the host at
power-on, so a host that has drifted starts every VM equally wrong --
and the guest's own NTP client steps it to real time seconds into the
boot, landing in the middle of whatever that guest is bringing up. A
Kubernetes guest survives that step looking healthy from every angle
except the one that matters: pods `Running` but never `Ready` (their
status timestamps sit in the future, so `kubectl` prints their age as
`<invalid>`), Services with no endpoints, every NodePort refusing,
while a `curl` straight at the pod IP answers `200`. Nothing in that
picture points back at a clock.

A cycle reports the clock; only an operator repairs it. Every
platform's fix is a privileged call -- Administrator, or a sudo
credential nobody is present to type -- so an unattended loop can
neither perform it nor stop to ask, and a host that refused cycles
over a clock would run none until someone noticed.

| Level | What happens |
|-------|--------------|
| `Write-HostClockDriftWarning`, in every platform's `Assert` | Measures **once per process** (a fresh process runs each cycle, so once per cycle) and warns past `Get-HostClockSkewLimit` (120s) with the symptom spelled out. The cycle continues. An **unmeasurable** clock says nothing -- an isolated lab has no route to a time server and is a normal deployment. |
| `Test-Config.ps1` | Reports the skew, then offers the repair -- only to a console that can answer. Accepting primes the sudo credential cache (`Initialize-SudoCache`) before `Sync-HostClock`, because every platform's sync is `sudo -n` and would otherwise fail on the answer just given. |
| `Set-*HostConditionSet` / `Enable-TestAutomation.ps1` | The durable fix: enable the platform's time service so it stays disciplined. |

`Get-HostClockSkew` speaks NTP directly over UDP rather than shelling
out to the platform's time client: on a drifting host that client is
usually broken or absent, its output is localized, and its timeouts
are not ours to choose. It returns `$null` -- never `0` -- when nothing
answers, so "unreachable network" can never be mistaken for
"disciplined clock".

<a id="42d38664-001b"></a>

### Registry shape

The facade calls
[`New-YurunaRegistry -Name 'HostCondition' -AnchorVar
'YurunaHostConditionProviders'`](../test/modules/Test.Registry.psm1)
and exposes thin wrappers around `Register` / `Get` / `GetMatrix` /
`Clear`. The provider entries survive `-Force` re-imports of the
facade because the backing store is anchored under
`$global:YurunaHostConditionProviders` -- the same eviction-safety
pattern `Test.HostIO`, `Test.SequenceAction`, and `Test.CredentialProvider`
use. `Assert-HostConditionSet`, `Test-ElevationRequired`, and
`Test-HostRequirement` are therefore pure registry lookups.

<a id="42d38664-001c"></a>

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
   -- without it the platform reports a drifted clock but offers the
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
-- same eviction-safe global-anchor pattern, hand-rolled rather than
built on `New-YurunaRegistry`; [Host I/O registry](host-io.md) -- the older
two-level registry that established the pattern. Per-platform deep
dives: [macOS host](host-macos.md), [Hyper-V host](host-hyperv.md).

<a id="42d38664-001d"></a>

## State sidecars

Every harness state sidecar (pidfile, JSON sidecar, runtime marker) goes
through the atomic writer in
[`modules/Test.StateFile.psm1`](../test/modules/Test.StateFile.psm1)
(`Write-YurunaStateFile`, `Write-YurunaStateFileJson`). The contract:

1. Write payload to `<Path>.<PID>-<GUID>.tmp` as UTF-8 (no BOM by
   default; `-WithBom` for PowerShell scripts that must satisfy
   `PSUseBOMForUnicodeEncodedFile`).
2. `Move-Item -Force` into `<Path>` -- atomic on same-volume NTFS / ext4
   / APFS, a single rename syscall.
3. Return `$true` on success, `$false` on failure. The helper itself is
   silent -- high-frequency callers do not flood `Verbose`. Callers log
   the specific reason at the call site if they need to.

A concurrent reader sees either the prior file (if any) or the new
file in full -- never a partial write, so the boot-recovery sweep can
trust every sidecar it finds on disk.

**Per-writer unique temp name.** A fixed `$Path.tmp` lets two processes
writing the same destination (e.g. the runner and the status service
both flushing `status.json`) rename each other's half-written temp.
`PID + GUID` keeps each writer's temp private; the rename to the final
path stays atomic. The `.tmp` suffix is preserved so any `*.tmp`
cleanup/ignore rules still match.

<a id="42d38664-001e"></a>

## Single-instance locks

Several harness processes must have at most one instance per runtime directory
-- the host-address beacon, the pool push forwarder, and the pool-storage drain.
Two lock shapes are in use, and every detail of both closes a failure that was
otherwise silent.

**An OS-held handle, where the kernel can be the lock.** The beacon opens its
lock file with `FileShare::None` and keeps the handle open for the whole run: a
second beacon simply cannot open it, and the kernel releases it when the process
dies -- including on a kill, where no cleanup code would have run. Nothing parses
the file; its contents are diagnostics only.

**A PID record, where a stale lock has to be reclaimable.** The forwarder and
the drain create the file with `[System.IO.File]::Open` in `CreateNew` mode -- an
OS create-if-not-exists -- and record the holder's PID together with its process
start time. Acquisition being atomic is what makes concurrent starters safe: a
check-then-write loses to a starter that reads the zero-byte file the winner has
created but not yet filled, fails to parse it, concludes the lock is stale, and
reclaims it.

**Identity is PID AND start time.** The liveness check requires both a live PID
and a matching start time, so OS PID reuse after a crash cannot let a stale lock
masquerade as a running holder -- which would break the guarded work forever
without ever saying so.

**Start time is recorded as ticks, never as a formatted timestamp.**
`ConvertFrom-Json` materializes an ISO-8601 field as a `[datetime]`, and
rendering that back to a string yields a culture-formatted value
(`08/11/2026 19:07:24`) that can never equal the `'o'` round-trip form it was
written as. Every comparison mismatches, every start judges a LIVE lock stale
and reclaims it, and the single-instance guarantee evaporates with nothing in
the log. A number survives the round trip unchanged.

**Claim the slot before the expensive work.** The beacon takes its lock ahead of
the module imports beneath it: those pull in the host driver and take seconds,
and two beacons spawned seconds apart would otherwise both clear the check
before either had written anything.

**Where the lock lives is part of the design.** The pool-storage lock is held by
the orchestrator rather than by the detached wrapper script, because move mode
calls the function directly and in-process -- a lock held only by the script
would leave the synchronous mover free to race a detached drain still working
through an earlier backlog, one deleting local folders the other is mid-copy
from.

<a id="42d38664-001f"></a>

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

Each history entry also carries a `sequenceSummary` array --
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

The cycle-opening NDJSON event carries that same `gitCommits` array, so a
consumer reading only the event stream can identify the framework and project
revisions used by a cycle without fetching the host's status.json -- which by the time the
stream is read describes whichever cycle is running now, not the one those
events belong to. Framework entry first, project entry second, short SHAs, and
the key is absent entirely on a cycle whose commits could not be resolved.

<a id="42d38664-0020"></a>

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
Unix) and stops it -- **only** if it is a `pwsh` process plausibly
ours. Unknown owners (dev server, another tool) get a clear error
and the launch bails. Keeping the helper in `Test.PortOwner.psm1`
makes the dispatch reusable by future callers (health-check,
`Stop-StatusService`, `Test-CachingProxyService`) without pulling in the
status service's full module.

<a id="42d38664-0021"></a>

## Status-service port and the host firewall

`Start-StatusService` binds `http://*:<port>/` (every interface), but a
host firewall silently DROPs inbound TCP on non-loopback interfaces
unless an allow rule exists -- so localhost answers while a LAN client
(the pool-aggregator service, an operator's browser) times out. One host with
this gap disappears from the pool dashboard and drops its extension-host
deep-link. `Test.StatusFirewall.psm1` centralizes the per-OS allow-rule
logic used by BOTH the one-time elevated host setup
(`Set-WindowsHostConditionSet` / `host/ubuntu.kvm/Enable-TestAutomation.ps1`)
and the best-effort self-heal at every status-service start. Managed:
Windows Defender Firewall (`New-NetFirewallRule`) and Linux ufw.
Reported but never touched: nftables/iptables without ufw, and the macOS
application firewall (application-scoped, not port-scoped -- the port is
not blocked by default).

<a id="42d38664-0022"></a>

## Per-cycle diagnostic capture

`Save-GuestDiagnostic` (Test.Diagnostic.psm1) runs at end-of-cycle to
pull a guest snapshot to the host. It uses a three-rung strategy
chain: **keyed SSH -> password SSH -> console**. SSH is the default
because it works the same on every host (Linux / macOS / Windows)
without a per-host keyboard injector, a guest-reachable status
service, or an interactive shell on `tty1`. The console rung is the
emergency fallback for when SSH itself is the bug (sshd down, host-key
mismatch, auth failure); when SSH is healthy the diagnostic ships
immediately, skipping console-typing latency and keystroke corruption
(character-table misses, host-specific Shift handling).

Earlier rungs' text output is not discarded -- `$lastResult` keeps the
most informative one, so a partial-and-failed earlier capture is still
written when every later rung ends up empty.

**Wait-SshReady preflight.** Sequences often end with "Reboot the
VM", so the guest may be mid-reboot when `Save-GuestDiagnostic` runs.
Without a real-handshake gate, the call would either bail at
`Get-GuestAddress` (empty per-guest folder) or write a near-useless
file whose body is just the SSH connection error (a port-22-open but
sshd-still-binding "half-up sshd" race -- see
`feedback_save_diag_post_reboot.md`). `Wait-SshReady` polls a real
`echo yuruna-ssh-ready` handshake and re-resolves `Get-GuestAddress`
each iteration, so a late-binding KVP entry on the Hyper-V External
vSwitch is picked up automatically. On timeout we skip: an empty cycle
folder beats a header-only error file.

The wait budget is capped by `min(180, remaining-of-total-budget)`,
so a near-deadline call cannot push the cycle past the
`$SaveGuestDiagnosticTotalTimeoutSeconds` cap. 180 s covers ARP probe
(~5 s) + typical Linux post-reboot bring-up (60-120 s) + slack.

<a id="42d38664-0023"></a>

## Watchdog and per-cycle resilience

The outer runner's job is to keep the inner running forever. Stale
heartbeat detection, single-instance guard, and the failure-pause
backoff protocol all live in
[Watchdog](runner-outer-loop.md#watchdog-and-heartbeat-protocol). Per-step
log-stream visibility is controlled by [Log levels](loglevels.md).

<a id="42d38664-0024"></a>

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | All guests passed (runner was interrupted or completed) |
| `1` | One or more guests failed, or preflight error |

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.13

Back to [Yuruna](../README.md)
