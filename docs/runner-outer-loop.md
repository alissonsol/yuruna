<a id="42f909ad-0001"></a>

# Test runner -- setup, outer-loop dispatcher, watchdog, and state machine

Please read the **Administrator Risk Warning** section of the
[Yuruna License](../LICENSE.md).

`test/Start-TestRunner.ps1` is the daily-driver loop, meant to run for hours
or days without an operator present. This document covers both halves: what to
do **once per machine** before leaving the runner unattended, then what the
eternal cycle loop it launches does.

See [test-config.md](test-config.md) for the `test.config.yml` parameter
reference, including the optional `networkStorage` NAS replication tier and how
to set its SMB password in the vault; [pool-storage.md](pool-storage.md) covers
that tier's architecture and operations. For how `test/` as a whole is put
together, see [Test harness -- architecture](test-harness.md).

The eternal cycle loop in
[`test/modules/Test.RunnerOuterLoop.psm1`](../test/modules/Test.RunnerOuterLoop.psm1)
is what makes the test runner resilient. Each pass updates the repository,
re-reads `test.config.yml`, refreshes base images on a configurable cadence,
then walks the cycle plan resolved from `test.runner.yml` -- creating a fresh
VM, driving its sequences, and recording results. Concretely, each cycle:

1. Fetch the framework's configured upstream and install its exact revision.
   Rewritten history and remote rewinds are supported. Preserve the previous
   revision in a backup ref; refuse dirty tracked files and collisions with
   untracked operator data. Detached version pins and `-NoGitPull` keep their
   existing revision.
2. Reconcile the pool configuration when the host belongs to a pool: `drain` stops
   the runner at this cycle boundary, `paused` holds without spawning.
3. Wipe last cycle's `inner.pid` / `inner.start` / `runner.stepHeartbeat` /
   `runner.phase` / `last_failure.json` / `break-active.json`.
4. Arm the [watchdog](#watchdog-and-heartbeat-protocol).
5. Spawn the inner runner through `Diagnostics.Process.Start` and wait for its exit.
6. On `exitCode == 0`, loop immediately. On non-zero, pause until one of the
   [break-out triggers](#failure-pause-break-out-triggers) fires.

Steps 1-5 run in a **fresh pwsh per cycle** (`Invoke-TestCycleRunner.ps1`), so
the cycle logic and every module it imports are re-read from disk every cycle
and an operator edit takes effect on the next one with no runner restart. The
loop process keeps only what must not be re-derived per cycle: the pidfile,
the boot-recovery sweep, the state machine, the Ctrl+C subscription, and the
cross-cycle counters. It polls that child in slices rather than blocking on
it, which keeps Ctrl+C observable mid-cycle and able to take the whole
child tree down with it. With no cycle script on disk the loop runs the cycle
in-process instead -- identical behavior except that an edit then needs a
restart, and the shape the unit tests drive. That is why the loop body lives
in a module rather than inline in
[`test/Start-TestRunner.ps1`](../test/Start-TestRunner.ps1): mocking the
call-op + `Set-RunnerState` exercises the state-transition sequence without
spawning a real inner pwsh.

While a host refresh repairs the host, every one of these steps is held; see
[Host refresh and the runner](#host-refresh-and-the-runner).

A framework update failure in the outer loop is a yellow preflight failure. Its retained attempt
record explains the failed update, while the previous completed cycle keeps its
original verdict and counters. The runner retries without starting a guest cycle.
An ordinary update follows the configured branch rather than comparing CalVer
strings, so an intentionally pinned release is never silently advanced.

<a id="42f909ad-0002"></a>

## Why unattended cycles

Continuous validation across hours or days catches intermittent
failures -- timing-sensitive UI hangs, transient network issues,
cumulative resource leaks, upstream-mirror rate limits, OS auto-update
windows -- that a single interactive run misses. The unattended runner
trades human monitoring for coverage breadth: it
runs the same cycle plan every cycle, surfaces every
fault through the same `last_failure.json` + NDJSON event channels,
and absorbs each transient via the
[failure-pause loop](#failure-pause-break-out-triggers)
without operator intervention. The lab environment described below
(test account, isolated network, no personal data) is what makes that
unattended-by-design contract safe to leave running.

<a id="42f909ad-0003"></a>

## Prepare the host

**Do not run unattended test automation using a personal account.**

Unattended machines are assumed to be in a physically protected
environment, like a test lab, with controlled access. Even so, use test
accounts with limited network access and no access to personal data on
the local machine.

<a id="42f909ad-0004"></a>

### Create a test account

  - Use `test/New-LocalTestUser.ps1` to create a local test account. It creates
    the account, sets the password, and grants machine-administrator rights in
    one step, on Windows, macOS, and Ubuntu alike:

    ```
    pwsh test/New-LocalTestUser.ps1 -Admin
    ```

    The account name defaults to `yurunatest`; pass `-AccountName <name>` for a
    different one. The password is prompted for on the elevated side, so it
    never reaches shell history, and the account can log in immediately.
    `-Password <value>` is the non-interactive equivalent for a scripted run,
    `-NoPassword` creates the account locked to have a password set out-of-band,
    and `-ForcePasswordChange` makes the password a one-shot credential that
    must be changed at first login. An account name the authentication vault
    already holds a password for is re-created with that same password rather
    than a new one, so Yuruna's copy keeps working; `-PromptForPassword` opts
    out. If the OS account already exists, the run reports what deleting it
    removes -- home directory included -- and asks to confirm before
    recreating it; `-Force` answers that in advance for an unattended run,
    and `-Force -WhatIf` previews what would go.
  - **Do not leave the password in open text files and sticky notes.**
  - Log in using the test account.
  - Execute the install script one-liners for your host, per the [install](../install/README.md) instructions.
  - Run the `Enable-TestAutomation.ps1` script that ships under your host type:

    | Host type | Script |
    |-----------|--------|
    | `host.windows.hyper-v` | [`host/windows.hyper-v/Enable-TestAutomation.ps1`](../host/windows.hyper-v/Enable-TestAutomation.ps1) |
    | `host.macos.utm`       | [`host/macos.utm/Enable-TestAutomation.ps1`](../host/macos.utm/Enable-TestAutomation.ps1) |
    | `host.ubuntu.kvm`      | [`host/ubuntu.kvm/Enable-TestAutomation.ps1`](../host/ubuntu.kvm/Enable-TestAutomation.ps1) |

    You may be asked for the administrator (sudo) password (multiple
    times, depending on the operating system).

    Each variant configures the host-side settings that would otherwise
    interrupt a long run -- display timeout, machine inactivity lock, lock
    screen on resume, ICMP / status-service firewall rules, display scale
    (HiDPI laptops up-scale screenshots and break Tesseract OCR). The
    scripts are idempotent; re-running them is safe.

<a id="42f909ad-0005"></a>

## First interactive run

Before the first unattended run, execute `test/Start-TestRunner.ps1`
at least once **interactively** on the machine. Two things only the
operator can do happen on that run:

- **Approve runtime permissions.** Some platform prompts (Hyper-V
  service, accessibility / screen-recording on macOS, virsh / libvirt
  group membership on Linux) only fire on first use and cannot be
  pre-accepted from a script.
- **Seed the base-image cache.** The runner's image-refresh step
  downloads each guest's base image on first execution; subsequent
  cycles reuse the cached copy and re-download only on the configured
  refresh cadence. Pre-seeding lets the unattended loop recover from a
  later failure (or a step that needs manual intervention) without
  blocking on a multi-gigabyte download mid-cycle.
  - **The Windows 11 ISO may need a manual download** (an image-provider
    limitation): if neither a download agent nor Fido (Hyper-V and UTM
    only) can fetch it, follow the instructions in each `Get-Image.ps1`.

<a id="42f909ad-0006"></a>

## Run unattended

With the host prepared and the first interactive cycle complete,
launch the runner:

```
pwsh test/Start-TestRunner.ps1
```

The script self-supervises: stale-heartbeat detection and the single-instance
guard are described under
[Watchdog](#watchdog-and-heartbeat-protocol), the backoff after a failed
cycle under
[Failure-pause break-out triggers](#failure-pause-break-out-triggers).
Per-step visibility is controlled by [Log levels](loglevels.md).

<a id="42f909ad-0007"></a>

### What a `test.runner.yml` entry can be

Each name under `sequences:` is one of two shapes, and the runner picks
its cycle model from the sequence itself:

- A **guest sequence** (declares a `resource:` map keyed by guest OS).
  The cycle planner (`Resolve-CyclePlan`) walks its prerequisite chain and
  the runner drives the per-guest VM lifecycle (create -> start -> run) for
  each supported OS. This is the common case; a `test.runner.yml` may list
  several of them.
- An **orchestration sequence** (`InvokeTestSequence` steps, no
  `resource:`). It owns the whole cycle: the runner detects it via
  `Get-CycleOrchestrationList` and delegates to `Invoke-OrchestrationSequence`
  (Test.Orchestrator), which runs each inner sequence -- guest chains and
  `host:` actions -- under one `status.json` cycle, one dashboard row per inner
  sequence. This is the same path `pwsh test/Debug-TestSequence.ps1 <name>` takes
  standalone; the amisad POC's `amisad.end-to-end` is the reference example.

The two models can't share one cycle: a `test.runner.yml` may hold **one**
orchestration entry **or** any number of guest entries, not a mix. A mixed
or multi-orchestration config is rejected as a `plan_invalid` cycle failure
rather than silently running a subset.

<a id="42f909ad-0008"></a>

## Startup gates

`Start-TestRunner.ps1` refuses to enter the eternal loop when either of
two conditions holds. Both are hard stops rather than warnings, because
the failure mode they guard against is a loop that keeps producing
near-empty cycles -- expensive to notice and diagnose after the fact.

A fresh start runs every refusal -- these two, the elevation check, and
the one-shot lease below -- before the boot recovery and before it stops
the runner it would replace: a start that is going to refuse must leave
the other runner and its runtime state as they were. A start resumed by a
host refresh runs them once it owns `runner.pid`.
Either way a refusal records that the start's launch ended cleanly, so a refresh
does not take it for a crashed runner to restart -- except while a live
runner owns `runner.pid`, whose launch record is that runner's.

An `Invoke-TestProject` or `Debug-TestSequence` run holds the runtime's
one-shot lease (`oneshot.pid` + `oneshot.start`) from before its first
side effect until it exits, and the runner refuses to start while a live
process holds it, naming the PID and the lease file. It reads the lease
again right after it writes `runner.pid`, because the one-shot entry
points take the lease first and then look for `runner.pid`: of two starts
at the same moment, at least one sees the other. A lease whose holder
cannot be proven alive or gone is reported and does not block the runner.
A host refresh reads the lease each time it has closed the refresh gate
before a repair step, and runs no step while a live process holds it
(reason code `oneshot-active`); an unproven holder is reported once and
does not stop the repair.

<a id="42f909ad-0009"></a>

### powershell-yaml must be installed

The cycle planner (`Test.SequencePlanner.Resolve-CyclePlan`) parses
`project/test/test.runner.yml` through `powershell-yaml`. When the module
is missing, the inner runner's `try`/`catch` turns the throw into a
`Write-Warning` -- a stream the per-cycle log does not capture -- and falls
back to the legacy `guestSequence` list. That fallback leaves
`Start-GuestOS` with no sequence names, so the step is recorded as
`skipped` in `status.json` with no line in the cycle log.

The condition is not transient, so the outer runner surfaces it once at
startup and exits instead of spinning an eternal loop of degraded cycles.
The reason goes through `Write-OuterLog` so it lands in `outer.log`, not
only the transient console Warning stream. Fix with:

```
Install-Module powershell-yaml -Scope CurrentUser
```

or re-run `host/<host type>/Enable-TestAutomation.ps1`.

<a id="42f909ad-000a"></a>

### Pre-cycle config gate

The gate blocks startup when `test.config.yml`, the extension configs,
`vault.yml`, or `users.yml` are in a state that would make the first
cycle's `New-VM`/`Start-GuestOS` fail in a confusing way.
[`Test-Config.ps1`](../test/Test-Config.ps1) is the single source of
validation rules -- schema, completeness, and cross-references -- and
calling it as a startup gate turns it from an operator tool into a hard
production guardrail (`users.yml` strict mode, the
vaultKey-resolves-in-`vault.yml` check, and the rest).

The gate always runs `Test-Config.ps1` with `-SkipSend`. Its notification
path is a smoke test for an operator-initiated run, not a cycle event;
delivering an email on every outer relaunch would flood the
`subscribers["config.smoke"]` list.

It runs at two points, and only those two: once at outer startup, and once
at the front of each cycle the inner runner opens. Startup alone would say
nothing about hour nine of an eternal loop, where a credential expires or a
config is edited mid-run. Re-checking any deeper would be worse than
useless: the gate reaches the network, so a remote that stops answering
between two stages of a running cycle would abort work that was succeeding
and discard every stage already built. Nested `Debug-TestSequence` stages
spawned by host actions therefore inherit the cycle's verdict rather than
re-gating -- a standalone `Debug-TestSequence` still gates for itself.

Bypass with `-NoConfigGate` for ad-hoc runs and dev iteration against
an in-progress edit. It forwards from the outer runner to the cycle, so
one switch covers both:

```
pwsh test/Start-TestRunner.ps1 -NoConfigGate
```

A failed gate logs the raw `Test-Config.ps1` exit code for diagnostics but
exits through the canonical Ok/Failure contract, like every other exit
path in the entry point: the exit surface is binary (0 = ran a cycle loop,
1 = refused or failed) so CI consumers need no per-script code lookup.

`Invoke-ConfigGate` returns the child's whole transcript as `lines` on
every path, including a green one. The console still sees nothing on a
pass -- a green gate is silent, like every other preflight -- but a caller
that keeps a run log can file it there. `install/setup.ps1` does exactly
that, at `CHILD` level, so the warnings the gate raised about the machine
(an unreachable server, a missing vault credential, a skipped active
preflight) survive the terminal. A caller with nowhere to file a
transcript ignores the field.

`-ExpectStorageConfigured` is a caller telling the gate that shared
storage was supposed to have been stood up before it ran. An absent or
half-populated `networkStorage` pool tier is ordinary on a host that never
asked for shared storage, and is proof that nothing landed on one that
did; the gate cannot tell those apart by reading the file. Only
`install/setup.ps1` passes it, and only when `storage.kind` is not
`none` -- an operator running `Test-Config.ps1` by hand is unaffected.

<a id="42f909ad-000b"></a>

## Public surface

`Invoke-RunnerOuterLoop -State <hashtable>` is the entry point: it returns
when `State.ShutdownState['Requested']` flips. Everything else the module
exports -- the git probes, the config readers, the pool-storage helpers, the
outer log writer -- is exported so a future test fixture or alternate driver
(a one-shot CI variant) can reuse them instead of re-implementing them.

The authoritative list is the `Export-ModuleMember` block at the end of
[`Test.RunnerOuterLoop.psm1`](../test/modules/Test.RunnerOuterLoop.psm1), and
each function carries its own comment-based help. A hand-copied table here
would only drift from it.

<a id="42f909ad-000c"></a>

## State hashtable

`Invoke-RunnerOuterLoop` reads no caller-scope variables implicitly.
Every value the loop needs is threaded through `-State`. The 14
required keys, validated at entry:

| Key | Type | Purpose |
|---|---|---|
| `RepoRoot` | `[string]` | Framework repo root for the `git pull` calls. |
| `ConfigPath` | `[string]` | Resolved `test.config.yml` path. |
| `InnerScript` | `[string]` | Absolute path to `Invoke-TestRunnerInnerLoop.ps1`. |
| `PwshExe` | `[string]` | `pwsh` binary to invoke (operator's choice). |
| `ArgList` | `[string[]]` | Argv built by `Test.InnerSpawn\New-InnerRunnerArgList`. |
| `ForwardEnvSnapshot` | `[hashtable]` | Launch-time `YURUNA_*` env-var snapshot. |
| `ShutdownState` | `[hashtable]` | Reference-shared with the caller's Ctrl+C handler. Flipping `['Requested']` ends the loop. |
| `NoGitPull` | `[bool]` | Skip the framework pull (operator's `-NoGitPull` switch). |
| `FailurePauseMaxSeconds` | `[int]` | Failure-pause cap (default 60 min). |
| `FailureCommitPollSeconds` | `[int]` | Trigger-poll cadence inside the pause (default 30 s). |
| `OuterPullErrorSleepSeconds` | `[int]` | Short retry sleep when the outer's own `git pull` fails. |
| `InnerSpawnErrorSleepSeconds` | `[int]` | Short retry sleep when `Start-Process` itself fails. |
| `StepTimeoutSecondsDefault` | `[int]` | Watchdog default (overridden per-cycle by `testCycle.stepTimeoutSeconds`). |
| `WatchdogPollSeconds` | `[int]` | Watchdog poll cadence (default 30 s). |

A missing key throws `Invoke-RunnerOuterLoop: -State is missing
required key '<name>'.` at entry, catching wiring bugs at the
entry-point edit site rather than mid-cycle.

The timing keys (the failure-pause cap, the poll and retry sleeps, the
watchdog and cycle bounds) come from one table, `Get-RunnerTunableDefault` in
`Test.RunnerOuterLoop.psm1`: the resident runner and the per-cycle process
both build their state from it, so the value tuned there is the one the
per-cycle process -- which arms the watchdog -- uses. The `testCycle` keys
of `test.config.yml` still override the three timeouts.

Three more keys are optional, each resolved to a default when absent so an
older caller (or a unit test) that omits them still runs: `CycleScript`, the
path to `Invoke-TestCycleRunner.ps1` -- absent, the cycle runs in-process --
`PreambleTimeoutSecondsDefault`, the watchdog's tighter preamble bound, and
`RunnerInstanceId`, 32 lowercase hex characters naming this runner process,
minted at loop entry when absent. Before each dispatch the loop writes
`CycleGeneration` = `<RunnerInstanceId>:<cycle>`; the cycle process receives
it as `-CycleGeneration` and hands it to the inner as
`YURUNA_CYCLE_GENERATION`, so evidence an inner writes can be matched to the
cycle that produced it and never counted for another.

Three keys carry [host-refresh](#host-refresh-and-the-runner) state between
dispatches, and all three may be absent:

| Key | Type | Purpose |
|---|---|---|
| `RefreshHandoff` | `[hashtable]` | A handoff the next dispatch runs as a preflight chain: `TokenId`, `RequestId`, `Purpose`, `Generation`. `Start-TestRunner.ps1` sets it on a resumed start; the automatic refresh decision sets it for the resident runner. |
| `RefreshBarrierRequestId` | `[string]` | The request whose held-control barrier the next ordinary cycle carries. Cleared once a cycle completes. |
| `RefreshGateHoldSeconds` | `[int]` | The interruptible hold between dispatches while a refresh holds the runner (default 15). |

<a id="42f909ad-000d"></a>

## Failure-pause break-out triggers

After the inner exits non-zero, the loop captures three baselines and
polls six triggers every `FailureCommitPollSeconds` until the cap or one of
them fires. The 5-second slice sleep inside the poll loop keeps
Ctrl+C responsive (`Start-Sleep` cannot be interrupted by our event
handler in long sweeps). The pause and its poll interval are measured on a
monotonic clock (`Get-OuterMonotonicTime`), so a daylight-saving change or
a clock correction neither ends the pause early nor stretches it by an hour.

| Trigger | Baseline | Probe |
|---|---|---|
| Framework commit | `git rev-parse HEAD` | `git fetch` + `rev-parse @{u}` |
| Project commit | `git ls-remote <projectUrl> HEAD` | Same `ls-remote` at poll time |
| Local config edit | `Get-OuterConfigMtime` | Same call at poll time; `-ne` comparison handles changed / created / deleted in one shot |
| Status-UI start request | (none) | Existence of `$YURUNA_RUNTIME_DIR/control.cycle-restart` |
| Auto-remediation (default off) | (none) | The failure's class is one the [remediation dispatcher](failure-schema.md#remediation-dispatcher) maps to a clearly-safe retry, the [recovery ledger](failure-schema.md#recovery-result-and-ledger) still has budget for the failure's fingerprint, and the class has runner-minutes left in its 24 h budget |
| Recovery probe (default off, with auto-remediation) | (none) | The probe registered for a host condition (`hypervisor_unresponsive`, `host_network_degraded`, `pool_storage_full`) says it has cleared |

Network / IO failure on any individual probe is treated as "no
change for now" (return `$null` / unchanged baseline) so a flaky
network can't cut a pause short and a missing config file can't
crash the loop.

The auto-remediation trigger is one of the bounded repairs described under
[Recovery after a failed cycle](#recovery-after-a-failed-cycle). Its attempt budget
is kept in the recovery ledger (`runtime/recovery.ledger.ndjson`), keyed by the
failure's fingerprint, and not in the loop process: a runner restart does not hand
a deterministic transient a fresh set of retries. A passing cycle re-arms the
budget, and so does the passage of 24 hours. Everything the dispatcher does not
classify as clearly-safe keeps the full wait-for-human pause.

The early end is a real backoff: it waits one poll interval after the first
failure, then doubles with each early end the ledger already holds for the same
fingerprint, to at most 15 minutes, and a pass re-arms it with the budget. A
class also has a runner-minute budget per rolling 24 hours (`RetryMinutesPerDay`
in `Test.FailureTaxonomy`, 180 by default): the runner cycles that failed with
it add their `durationSeconds`, and once the sum reaches the budget no pause of
that class ends early -- neither by this trigger nor by a recovery probe --
until older failures leave the window. A hang that the watchdog killed is filed
as a `wait_timeout`, whose repair is the retry; without the budget the same
hang would repeat after every early end. A wait that ended on a wedged guest
kernel is filed as `guest_kernel_stalled`, whose budget is its own (180
minutes, written in its route), so a host whose guests keep wedging spends
that class's minutes and not the ones real step timeouts are retried on.

The automatic host-refresh decision runs after every dispatch, through
`Test.HostRefreshTrigger` when that module is present (it is off by default;
[test-config.md](test-config.md) describes `testCycle.autoRefreshAfterStalls`).
Every outcome first consumes the cycle's evidence file,
`runner.refresh-evidence.json`; only a completed cycle counts. The decision then
has three call sites in the loop. A passing cycle asks it on the success branch
before looping. A failing cycle asks it on the failure branch after the streak
and crash-gating accounting and before the pause: when the repair reports the
host `repaired`, the pause is skipped (the state machine goes `fault -> idle`
and `outer.log` says so) and the next cycle starts at once. Either branch may
return a handoff for this runner, which the next dispatch runs as a
[preflight chain](#handoff-and-preflight). A held cycle asks it on its own
`gated` branch, and a pool drain withdraws an automatic request no worker has
started. A failure inside the decision is logged to `outer.log` and never
changes what the loop does.

<a id="42f909ad-000e"></a>

## State transitions emitted

The dispatcher calls `Set-RunnerState` at every cycle boundary so a
streaming consumer sees the lifecycle explicitly. Full enum and
transition table live in
[Runner state machine](#runner-state-machine) below.

| Cycle phase | Transition |
|---|---|
| Cycle opened, before any per-cycle work | `idle -> cycle-start` |
| Watchdog armed | `cycle-start -> in-cycle` |
| Inner exited 0 | `in-cycle -> cycle-end -> idle` |
| Inner exited non-zero | `in-cycle -> fault` |
| Pool `configuredState=paused` (hold) | `cycle-start -> paused`, then `paused -> cycle-start` on the ~30s configuration re-poll |
| Entering failure-pause | `fault -> paused` |
| Pause broke out | `paused -> idle` |
| Host refresh holds the dispatch or the cycle start | none: the cycle changes nothing |
| Host refresh holds the cycle after its pull (before the wipe) | `cycle-start -> paused`, then `paused -> cycle-start` on the next dispatch |
| Inner held at one of its own gate sites | `in-cycle -> cycle-end -> idle` |
| Refresh preflight cycle exited | `in-cycle -> cycle-end -> idle` |
| Automatic refresh repaired the host after a failure | `fault -> idle` (the failure pause is skipped) |

Each `Set-RunnerState` call is `Get-Command`-guarded so a stripped-
down test fixture that did not import `Test.RunnerState` still runs
the loop body.

<a id="42f909ad-000f"></a>

## Pre-spawn cleanup ordering

Six files are wiped before the watchdog is armed, each for its own reason.

| File | Why it is wiped pre-spawn |
|---|---|
| `inner.pid` | A stale file makes `Start-Watchdog` skip its wait-for-pidfile loop, read the dead PID, fail to capture an identity for it, and lapse within seconds -- leaving the new inner unwatched for the whole cycle. |
| `inner.start` | The start-time sidecar of `inner.pid`, which the host-refresh identity checks read with it. It goes with its pidfile, so a new inner's PID is never paired with the previous inner's start time. |
| `runner.stepHeartbeat` | The symmetric trap: the watchdog would see an hours-old mtime and kill the new inner before it started its first step. |
| `last_failure.json` | `Invoke-Sequence` removes it at the start of each sequence, but between the previous cycle's failure and the new cycle's first sequence there is a multi-second window where a dashboard or status-service reader sees stale cycle-N failure context attached to cycle N+1. Pre-spawn deletion closes that window. |
| `runner.phase` | It selects the watchdog's TIGHT preamble bound, so a copy left behind by a killed inner would apply that bound to the next cycle's sequence steps and kill healthy long ones. The new inner re-creates it within its first second; until then its absence means the loose bound, which is the safe direction. |
| `break-active.json` | Written by the `break` sequence action when a cooperative breakpoint parks the cycle, and removed on resume. Restarting only `Start-TestRunner.ps1` while a break is parked leaves the file behind, and the first new-cycle step's Gate #1 then hangs the cycle waiting on a breakpoint nobody set. Status-service startup sweeps it too, but the runner can start without the status service, so both startup paths clean it. |

A [refresh preflight cycle](#handoff-and-preflight) wipes only `inner.pid`,
`inner.start`, `runner.stepHeartbeat` and `runner.phase`. It keeps
`last_failure.json` and `break-active.json`, which still describe the cycle the
refresh interrupted, and skips the pool-storage check below, because it
archives nothing.

The **pool-storage space check** runs immediately after the `last_failure.json`
wipe, and the ordering is load-bearing. On a host archiving in move mode it
refuses to spawn a cycle whose
results the share has no room for, recording a `pool_storage_full`
`last_failure.json` of its own -- and the fault status in `status.json` reads exactly that
file. Placed *before* the wipe, the previous cycle's record would still be there and
would name the wrong cause. The check returns the `storage-full` outcome, which is
deliberately absent from the short-hold list so it takes the full pause. The
recovery planner does not depend on the order: a `storage-full` result is classed
`pool_storage_full` from the outcome itself, and no repair covers that class, so
the runner does not spend the day re-discovering that nobody has deleted anything
yet.

Order matters elsewhere too: `Remove-Item` first, then a "force-fresh"
`WriteAllText` on `runner.stepHeartbeat`. If `Remove-Item` fails on
the heartbeat (locked file, AV mid-scan, anything), the watchdog
about to arm would read the stale mtime and kill the new inner
within one poll. The unconditional `WriteAllText` defends against
that -- the new inner overwrites it again immediately at startup, so
the force-touch is harmless when the wipe succeeded.

<a id="42f909ad-0028"></a>

## VM admission at cycle start

Two cycles on one VM set corrupt each other, so every entry point that starts
cycles -- the runner's inner, the project run through it, and
`Debug-TestSequence.ps1` (its orchestration and single-sequence paths alike) --
asks the same function before it touches the host: `Invoke-HostVmAdmission`.
Its answer has three states, because "could not look" is not "nothing there":

| State | Meaning | The entry point |
|---|---|---|
| `clear` | The inventory was read and nothing outside the service VMs is running. | Proceeds. |
| `occupied` | A VM outside the allow-list is running and did not stop. | Exits 1. |
| `unknown` | The inventory failed, no host driver is loaded, or some VM's state could not be determined, on every read. | Exits 2 (cannot run). |

A running guest is stopped first and the host read again: a guest left behind by
a cycle that died before its teardown is the common case, and refusing over it
strands the host, since the sweep that would remove it only runs once a cycle
starts. Stopping never deletes. The inventory is re-read up to three times, a few
seconds apart, because a hypervisor CLI that is merely slow answers the second
time and one that is wedged does not; a VM seen running ends the reads at once.

`unknown` refuses. Proceeding with a warning when the inventory cannot be read is
how a cycle ends up sharing a host it never looked at. The cost is one refused
cycle on a host whose hypervisor tooling is broken and says so; the failure pause then gives it time to recover or be fixed,
and the next loop asks again.

Every verdict, `clear` included, is written to `runtime/vm-admission.json`
(`state`, `reason`, `occupants`, `probes`, `detail`, `hostType`, `observedUtc`)
so a later verdict replaces an earlier refusal. After a failed cycle the loop
reads the record when it is newer than the cycle's spawn and names the fault for
what it is: `status.json` carries `lastFailure.failureClass`
`vm_admission_unknown` or `vm_admission_occupied`, and `runnerStateReason` reads
"VM admission unknown (inventory-failed); inner exited 2" instead of a bare exit
code that points at the tests.

<a id="42f909ad-0022"></a>

## Host refresh and the runner

A host refresh -- `test/lab/Invoke-HostRefresh.ps1` run by hand, the
`POST /control/host-refresh` route in [control-routes.md](control-routes.md), or
the automatic repair above -- repairs a stalled runner or hypervisor. While it
reclaims processes or restarts the hypervisor, no runner process may start a
cycle, pull, or sweep VMs; when it is done, it hands the host back to a runner
without an operator. Three mechanisms carry that: the refresh gate, the handoff,
and the held-control barrier. The gate and handoff records live in
`Test.SingleInstance`, which the loop, the cycle process and the inner all
consult; the barrier runs in the inner (`Test.RunnerInnerLoop`).

<a id="42f909ad-0023"></a>

### The refresh gate

The gate is one record per user, `runner-gate.record` under
`$HOME/.yuruna/host-refresh/`, because a hypervisor repair disrupts every
runtime directory the user owns. Every write takes `runner-gate.lock`: the
refresh worker opens, closes and hands off the gate, and the designated runner
writes it once, to complete its handoff; everything else in the runner only
reads it. Its state is `open`, `closed`, `recovery-pending` or `handoff`. A
gate that cannot be read -- damaged, from a newer schema, or under a private
directory that fails its safety checks -- holds exactly like a closed one.
Nothing expires a gate by age: one left behind by a worker that died stays held
until `test/lab/Invoke-HostRefresh.ps1 -Resume` resolves it, and the runner's
hold line says so. A refresh an earlier boot left unfinished is the one case the
runner resumes itself: when the gate is orphaned and its owner started before
the current boot (a power loss or a reboot in the middle of the refresh), the
first `Start-TestRunner.ps1` start of each boot runs that same `-Resume` once for
that request, detached, and still refuses; the refresh's own handoff starts the
runner when it completes. The marker `boot-resume.json` beside the gate names
the request and the boot, so a resume that fails is not retried until the next
boot, and the worker's stderr is kept in `boot-resume.err`. A gate whose owner
died in this boot, or whose owner's start time was not recorded, stays with the
operator.

An orphaned gate -- its owner proven dead or recycled, with no live handoff
token -- still holds the runner, but not the observational status service:
both a refused `Start-TestRunner.ps1` start and the outer's failure-pause
re-ensure bring that service back for an orphaned gate, where a gate with a
live owner defers (its worker may be restarting the listener itself). Without
this, a dead worker's hold would also take down the dashboard that carries the
unresolved request's state and resume controls, leaving a remote operator
nothing but connection errors.

Six sites read it, each before anything it guards can change:

| Site | Process | Guards |
|---|---|---|
| Dispatch | loop | Spawning the cycle process at all |
| Cycle start | cycle | The `git pull`, the pool-configuration sync and the first state transition |
| Before the wipe | cycle | The pre-spawn wipe and the inner spawn, which can be reached after the gate closed during the pull |
| Cycle start | inner | The per-cycle host-condition re-check and everything after it |
| Before the pull | inner | The auth vault, the status reset and the framework pull |
| Before the cycle-start sweep | inner | `Remove-CycleStartOrphanVM` and everything after it |

A held dispatch or cycle returns the outcome `refresh-gated`. An inner held at
its own sites exits 0 and leaves `runner.refresh-gated.json` naming itself and
its parent; the cycle process accepts that file only from its own inner during
this spawn, deletes it, and reports `refresh-gated` too, skipping every
cycle-end hook. An inner held before the cycle-start sweep has already opened
the cycle log, so it closes it as aborted and records the cycle as `skipped`
in the status history, which the fleet counters do not tally. `refresh-gated` is neither a pass nor a failure: no fault state,
no crash gating or streak, no failure pause, no failure notification, and no
completed cycle for the automatic decision to count. The loop holds for
`RefreshGateHoldSeconds` (sliced, so Ctrl+C still lands within seconds) and
dispatches again. It logs the hold to the console and `outer.log` once per
change of request, gate state or orphaned worker, and logs one line when the
gate releases. The status-service re-ensure before a failure pause is skipped
while the gate holds, so the runner never restarts a service the repair is
restoring.

A normal `Start-TestRunner.ps1` start refuses while the gate holds -- it would
race the repair, which restarts the runner itself -- and so does the
single-instance banner (`Assert-NoOtherRunner`) of the other entry points.

<a id="42f909ad-0024"></a>

### Handoff and preflight

When the repair is done, the worker hands the host back through a handoff token
recorded in the gate: 32 hex characters, a purpose, the designated runner, and
an expiry measured on the boot clock (a reboot expires it). The purpose names
which runner receives it:

- **`new-outer`**: the worker restarts the runner itself -- see
  [A runner restarted by a refresh](#a-runner-restarted-by-a-refresh) -- and the
  new runner's first dispatch is the preflight chain.
- **`resident-outer`**: the runner that called an automatic repair was never
  stopped. The token comes back in the repair's result, and that runner's next
  dispatch is the preflight chain.

The gate admits only the preflight chain of the designated runner. A preflight
cycle skips the pull and the pool-configuration sync, wipes only the four files named
under [Pre-spawn cleanup ordering](#pre-spawn-cleanup-ordering), and carries the
token to its inner in the environment (`YURUNA_REFRESH_PREFLIGHT`,
`YURUNA_REFRESH_HANDOFF_TOKEN`). The preflight inner is bounded (120 seconds)
and changes nothing: no git, no VM, no control sweep, no status document. It
probes the hypervisor from the final process ancestry -- the one that matters
for per-process permissions -- and writes a readiness acknowledgment,
`runner-handoff.<token>.ack.json` under `$HOME/.yuruna/host-refresh/`, carrying
the three chain identities and the operator controls it found. An
acknowledgment is written only while the gate holds that token.

A `new-outer` preflight inner then parks, refreshing its step heartbeat, while
the worker verifies the acknowledgment against the live chain and completes the
handoff; it exits once the gate is released, the handoff revoked, or the token
expired. A
`resident-outer` preflight inner exits at once, because the runner that must
verify it is waiting on it: that runner checks the acknowledgment against the
cycle it spawned and completes the handoff itself, `released` when it verified
readiness and `recovery-pending` otherwise. Either way the cycle reports the
outcome `refresh-preflight`, which runs no cycle-end hook and never counts as a
completed cycle. A successful preflight arms the barrier below; a failed one
keeps the runner held, so no inner starts into the same fault.

A `resident-outer` token names that runner as the gate's owner, and the worker
that issued it has already exited, so nobody else would complete it. When the
token expires (or the host reboots) before the runner dispatched its preflight,
the runner completes the handoff `recovery-pending` itself and reports
readiness failed (`handoff-expired`) to the repair's request record. A gate
this runner owns in that state -- or after its own preflight failed -- is
logged like a gate whose worker died, naming
`test/lab/Invoke-HostRefresh.ps1 -Resume` as the way out.

<a id="42f909ad-0025"></a>

### Held-control barrier

A refresh preserves the operator's controls: `control.cycle-pause`,
`control.step-pause`, `control.pause`, a lab hold and its release, and
`control.cycle-restart` all survive it. The first ordinary cycle after a
handoff carries the barrier (`YURUNA_REFRESH_BARRIER`, the request id), and its
inner stops right after host detection, before anything can touch a VM or the
host. While a pause flag exists it parks, refreshing its step heartbeat, until
the status page's resume removes the flag. A preserved lab hold goes to its
normal consumer, the lab-health gate, which re-probes, holds, honors a release,
and ends the cycle as a failure when the hold gives up. The barrier never
deletes a pause flag, and leaves `control.cycle-restart` for the inner's normal
startup consumer.

<a id="42f909ad-0026"></a>

### A runner restarted by a refresh

A refresh that had to reclaim the runner restarts it from its launch record:
`runner-launch.<runtime key>.record` under `$HOME/.yuruna/host-refresh/`,
written by `Start-TestRunner.ps1` after it wins its pidfile. The record holds
the six operator options with their resolved values (`-ConfigPath`,
`-NoGitPull`, `-NoStatusService`, `-NoConfigGate`, `-CycleDelaySeconds`,
`-logLevel`), the working directory, the runtime directory and the forwarded
`YURUNA_*` environment. It is validated against the runner script's own
parameter metadata before any launch, so it never replays a command line. A
runner that could not write one says so at startup; a later refresh then cannot
restart it and reports that the operator must start it. A runner whose last
exit was clean (Ctrl+C) is not restarted either. A runner still running from an
older checkout has no launch record, and a refresh cannot hand the host back to
it: restart it once so it writes one.

The worker starts `Start-TestRunner.ps1 -RefreshResume -RefreshHandoffToken
<token>` detached, with the recorded options. Both parameters are internal and
travel together; neither reaches the inner or the launch record. A resumed
start:

- refuses when the token does not validate for this runtime, writing a failed
  acknowledgment the worker is waiting for;
- never takes over a runner: a live or unidentifiable `runner.pid` refuses the
  start, and only the exact runner generation proven dead is removed;
- only once it holds `runner.pid`, runs the boot-recovery sweep in
  preservation mode and resets the runner state, so a refused start never
  touches a live runner's state: pause flags, lab holds and the restart request
  stay for their normal consumers; `inner.pid` goes only when its process is
  proven gone; `runner.pid`, `server.pid` and `config-server.pid` are left
  alone; and `break-active.json` is archived only for the inner the refresh
  reclaimed;
- never prompts: a host whose elevation check would ask for a password
  refuses the start, as an unattended start does;
- runs the preflight chain as its first dispatch, then the barrier cycle.

A startup refusal after the launch record is written -- `powershell-yaml`
missing, elevation, the config gate -- marks the record as a clean exit, like
Ctrl+C, so a later refresh does not restart the runner into the same refusal.
The worker watches the runner it launched: one that exits before
acknowledging ends the wait at once as a failed launch instead of holding the
repair until its deadline.

A refresh recognizes this checkout's runner however it was started: by an
absolute path, by a path relative to the directory it was started from
(`pwsh test/Start-TestRunner.ps1`, a `./test/Start-TestRunner.ps1` shebang
launch), through a symbolic link to the checkout, or, failing all of those, by
the process identity its launch record names.

**Stopping a resumed runner.** A restarted runner has no console: its stdout is
discarded, its stderr goes to `runner.<request id>.err` in the refresh's private
directory (captures untouched for a week are pruned at the next restart, the
four newest always kept), and `outer.log` and the per-cycle logs remain the
durable record.
Ctrl+C cannot reach it, and the `test/service/Stop-*` scripts stop services,
not the runner. To take it back into a terminal, start `test/Start-TestRunner.ps1`
there as usual: the single-instance takeover stops the detached runner and its
whole process tree first. To stop it outright, arm **Pause after cycle** so the
current cycle finishes and tears its guests down, then stop the process tree
rooted at the PID in `runtime/runner.pid`, children first -- stopping only that
PID leaves its cycle process and inner running. The next start's boot recovery
treats the result as a crashed runner, which is the designed path.

<a id="42f909ad-0010"></a>

## Why the cycle call must not capture the inner runner's stdout

The cycle process now starts the inner through `Diagnostics.ProcessStartInfo`
and `Diagnostics.Process.Start`, with native stdout attached to the console,
and waits on that process with `WaitForExit()`. Capturing the cycle function's
typed result therefore does not put the inner's stdout in a PowerShell
success-stream pipe.

The earlier call-operator launch let the enclosing function's success stream
determine the inner's stdout: capture the result anywhere up the chain -- assign
it, pipe it, or wrap the caller in `$(...)` -- and PowerShell created an anonymous
pipe and read it to EOF.

With that launch, EOF rather than the inner's exit released the cycle. The
inner's status-service descendant inherited a duplicate of the write end and
held it for its unbounded lifetime, so the cycle never returned: the inner
logged that it was about to exit with code 0, and the outer's "back in control"
line never followed. One cycle passed and the runner started no more, without
reporting an error. This was observed on a live Hyper-V host with the cycle
process blocked 44 minutes past a passing cycle, released within a second of
killing the status service.

This is a Windows-only exposure. The POSIX branch of `Start-StatusService.ps1`
detaches through `bash -c "... </dev/null >/dev/null 2>err &"`, whose
redirections replace the descriptors outright, so nothing crosses the exec and
no Linux or macOS host in the pool can reach the condition.

A regression test rebuilds the cycle -> inner -> status-service topology in a
temporary directory and asserts that the cycle process returns once the inner
exits, so a future refactor that captures the stream fails a suite instead of a
lab.

<a id="42f909ad-0027"></a>

## A cycle is scored from its outcome record

The cycle process reports through `runtime/runner.cycle.outcome.json`, a small
JSON object with an `outcome` name, an integer `exitCode` and the
`cycleGeneration` the loop issued, plus, when the cycle knows them, a
`failureClass` and a redacted `detail` that never decide validity. The record is
required: the loop counts a
cycle as a pass only when a record exists, parses, carries both fields, and
names the generation of the cycle it just ran. An exit code of 0 is not
evidence, because a process can exit 0 having failed to say anything, and
reading an absent file as `completed` turns every failure to record into a
green host.

Anything else is the outcome `outcome-unrecorded`, with the reason on the
result: `missing` (no file), `malformed` (not a JSON object, or a field absent
or of the wrong kind) or `stale-generation` (another cycle's record, or one with
no stamp). It is an infrastructure fault of the runner on that host, not a test
verdict, so it takes the failure branch: the state machine goes to `fault`,
`status.json` carries `lastFailure.failureClass` `outcome_unrecorded` (unless the
inner left a classified failure of its own, which wins) with the reason in
`runnerStateReason`, and the failure pause applies. The auto-remediation
shortcut can end that pause early only for a failure the inner itself
classified; the unrecorded outcome alone gives it nothing to match. A non-zero
child exit code is kept as the exit code (a failure stays a failure whether or
not it was recorded); a clean one is replaced by 70, so nothing downstream reads
the cycle as a success. A rejected record is kept as
`runtime/runner.cycle.outcome.rejected.json` for diagnosis.

A child that dies within seconds of its spawn, with a non-zero exit and no
record, remains `cycle-aborted`: it never ran a cycle, and the loop holds briefly
and retries instead of pausing.

The hold after an attempt that produced no verdict -- `pull-error`,
`spawn-failed` or `cycle-aborted` -- starts at its base (30 seconds) and doubles
for each such attempt in a row, up to 15 minutes; the first cycle that runs to
a verdict ends the streak. A cycle process that could not be started is
published as a runner fault (`cycle_spawn_failed`, stage `CycleSpawn`), the
same way a failed framework pull already is, so the pool sees a host that
cannot start its cycles.

`status.json` holds only the current `runnerFault`, so each fault the runner
publishes is also queued once per attempt generation as a `runner_fault` event
with the same fields; the fault and the pause that republishes it are one
event. A fault published without an attempt generation (an escape from the
outer loop, a diagnostic hold) is an event each time. The next cycle writes it
into its stream, which reaches the pool's event log. A runner keeps the code it
started with, so one started before runners queued these events never queues
them; the cycle process, which loads the current code each cycle, also queues from
`runtime/runner-attempts/index.json` each failed attempt that finished after
the newest passing attempt and that no `runner_fault` carried yet, marking it
with `runner-fault.queued` beside its record. A fault the runner queued itself
gets the marker and no second event, and a failure before the newest passing
attempt is not sent late: its line would be more than an hour behind the
stream, which Loki refuses. A fault without an attempt generation has no record
there, so only a runner that queues it sends it.
`runtime/runner-attempts/index.json` lists the latest 20 attempts in
`attempts` and, in `olderFailures`, up to 30 older failed attempts that a later
attempt passed after, with their evidence: on a host that recovers, the
passing cycles after a failure would otherwise retire it within hours.

The cycle process writes the record through `Publish-CycleOutcomeRecord`, which
reads it back through the same validator (`Read-CycleOutcomeRecord`, both in
[`Test.RecoveryContract`](../test/modules/Test.RecoveryContract.psm1)) before it
lets the process exit cleanly. When the write or the read-back fails, the process exits 70, not 0.
A cycle that returned without publishing any result is recorded as
`no-cycle-result` with a failing exit code instead of defaulting to a clean
completion, and the fault it raises carries the same `outcome_unrecorded` class
and says the cycle returned no result.

<a id="42f909ad-0029"></a>

## Recovery after a failed cycle

After every dispatch the loop records the cycle's typed result in
`runtime/recovery.result.json` (the fields are in the
[failure schema](failure-schema.md#recovery-result-and-ledger)). It is built from the
dispatch outcome, the outcome record, `last_failure.json` and `vm-admission.json`;
the outcomes that say no cycle ran to a conclusion (`drain`, `refresh-gated`,
`refresh-preflight`, `paused`, `shutdown`) produce none. A `passed` result appends a
`resolved` line to the recovery ledger, which re-arms every repair budget.

Bounded repairs run at three points, all gated by `testCycle.autoRemediation.enabled`
(default off; with it off the result says `advised` and nothing is written to the
ledger):

1. **A failed framework pull** (`pull-error`), before the short hold. The pull runs in
   the cycle process, so its redacted failure text reaches the loop through the
   outcome record's `detail`; a stale `.git/index.lock` is the case this serves.
2. **The failure branch**, after the fault accounting, the host-refresh decision and
   the status-service check, and before the pause. A repair that applied replaces the
   pause: the state machine goes `fault -> idle`, `outer.log` names the repair, and the
   next cycle is its proof.
3. **Inside the pause**, as the auto-remediation trigger above: the early end for a
   transient class, which waits for its doubling hold and is decided once per pause;
   and, for a host condition that clears on its own (`hypervisor_unresponsive`,
   `host_network_degraded`, `pool_storage_full`), the probe that
   `Test.RecoveryProbe` registers for the class. The pause runs it at most once per
   probe interval, in a short-lived process (`test/modules/Invoke-RecoveryProbe.ps1`
   loads the host driver and the checks the cycle uses to raise the class, which
   the resident never loads), and a probe that says the condition cleared ends the
   pause through `end_failure_pause_on_probe`. A probe that says it still holds
   writes nothing to the ledger.

The pool's `autoRemediation` override reaches these decisions too: the cycle
process resolves the pool's `testCycle` block and records it in the cycle's
outcome record (`poolTestCycle`), and the resident reads it from there, because
the resident never syncs the pool configuration itself.

A cycle that failed nothing but skipped a planned guest (a quarantined one) is
degraded, not a pass. The inner exits 75 (`Get-DegradedCycleExitCode`, from
sysexits `EX_TEMPFAIL`), the recovery result says `degraded`, and the cycle
summary line reads `DEGRADED (n of m guests skipped)`. It raises no fault and
takes no failure pause, but it has none of a pass's effects: it re-arms no
repair budget, ends no failure streak, counts toward no alert re-arm and gives
the automatic host refresh no success, because the skipped guest proves
nothing. The status page and the history row still show the guests that ran as
passing and the skipped guest as `skipped`.

The ledger decides every time, so a restart between two identical failures changes
nothing. What each repair does, and the ledger's rules, are in the
[failure schema](failure-schema.md#the-repairs). `Debug-TestSequence` and
`Invoke-TestProject` never run repairs: an operator-driven run should not change the
machine behind the operator's back, so their results are `advised` or `none`.

<a id="42f909ad-002a"></a>

## When the resident runner itself is the problem

Three faults sit above everything the cycle process can repair, because each one
stops the cycle process from running or from being bounded. The resident runner
handles them itself, with the code it loaded when it started.

- **An exception escapes the loop.** `Start-TestRunner.ps1` runs the loop under
  `Invoke-RunnerOuterSupervisor`. An exception that escapes, for example a
  `test.config.yml` saved half-edited while the failure pause polls the
  configured sources, is written to `outer.log` with its type and script line,
  published to `status.json` as a `runnerFault` (`script_error`), and counted
  toward the crash alert. The loop is entered again after a hold that starts at
  30 seconds and doubles with each repeat within an hour, up to 15 minutes. A
  cycle process the escaped loop left running is stopped first, and the cycle
  counter continues, so no cycle generation is issued twice. The two source polls
  of the failure pause never throw: an unreadable configuration is a logged
  "no answer". Ctrl+C and a shutdown request still end the runner.
- **The framework cannot start its own cycle process.** The framework pull runs
  inside the cycle process, after that process imports the framework, so a
  commit that breaks the import also stops every pull that would bring the fix.
  `runtime/runner.framework-health.json` keeps the last commit whose cycle
  process produced a valid outcome record, and a streak of dispatches at the
  current commit that ended without one (`cycle-aborted`, or
  `outcome-unrecorded` with no record behind it). From the second such dispatch
  the resident pulls the framework itself, logs the result (`updated`,
  `unchanged` or `failed`), and for `cycle-aborted`, which skips the failure
  pause, publishes the fault and counts it toward the alert. The hold after a
  repeated abort doubles to at most 15 minutes. A runner started with
  `-NoGitPull` does not pull.
- **A cycle has no bound.** The step watchdog is armed inside the cycle process
  and stands down when it cannot prove the inner runner's identity, leaving
  `runtime/runner.watchdog.lapsed` with the step and preamble bounds it would
  have applied. The resident notices that file while it waits, says so at once,
  and takes over the watchdog's job with those bounds: the preamble bound while
  `runner.phase` exists, the step bound after, measured from the last change it
  saw in `runner.stepHeartbeat` on a monotonic clock. When a bound runs out it
  writes `runtime/runner.watchdog-kill.json` with the class the watchdog would
  have used (`wait_timeout`, or `preamble_stall` with the phase), stops the
  cycle process and every descendant, and reports the outcome as unrecorded
  with reason `resident-watchdog`; the recovery result is `aborted` with that
  class and stage `ResidentWatchdog`. The status page shows a cycle running
  without its step watchdog, or one whose heartbeat is past its bound, with an
  amber banner instead of "Test in progress".
  Every cycle is also bounded by `testCycle.maxCycleSeconds` (default 21600, 0
  disables), enforced by the resident on the cycle process it spawned and
  measured on a monotonic clock. Only working time counts: while a step pause,
  a cycle pause, a lab hold or a debug break is in place the clock stops, so a
  cycle an operator held is not stopped soon after it resumes. Once the cycle
  publishes its plan in `status.json`, the ceiling rises to two step timeouts
  for each planned run when that is more than the configured value; the
  default is three runs at the template's one-hour step timeout. At the
  ceiling the resident writes `runtime/runner.watchdog-kill.json` with
  `failureClass: cycle_killed` and stops the cycle process and every
  descendant, so a wedged capture, OCR engine or ssh below the inner runner
  goes too. The recovery result for that cycle is `aborted`
  (`cycle_killed`, stage `CycleCeiling`).

The resident keeps the modules it imported when it started until it exits: a
host pull changes what each later cycle process loads, but never the resident's
own handling of these faults, of the failure pause and of the repairs. So the
runner publishes, as it starts and once its startup refusals are behind it, the
framework commit it started on and the moment it started, as `runnerResident`
(`commitSha`, `startedAtUtc`) in `status.json`. Every cycle start carries the
field forward, and only the next runner start changes it. The host status page
shows it in the "Runner attempt failures" section, and `/control/host-facts`
relays it (`runnerCommitSha`, `runnerStartedAtUtc`) to the pool Hosts page's
Runner column. For a runner started before the report existed, the status page
says it has not reported, and the column shows `--` with that reason as its
title. It is a report, not a gate: a runner whose commit is older than its
host's checkout keeps running, and a restart is what brings it the newer code.

<a id="42f909ad-0011"></a>

## Watchdog and heartbeat protocol

The test runner survives indefinitely under sustained guest, network,
and host-OS failures because every long-running activity emits a
heartbeat that an out-of-process watchdog reads. When the heartbeat
goes stale, the watchdog kills the wedged process and the outer
runner respawns the inner from a clean state.

<a id="42f909ad-0012"></a>

### Layout under `$YURUNA_RUNTIME_DIR`

| File                     | Writer                  | Reader                | Purpose |
|--------------------------|-------------------------|-----------------------|---------|
| `runner.pid`             | outer runner            | next outer + status service | Single-instance guard; PID of the outer eternal-loop process. |
| `runner.start`           | outer runner            | next outer + status service | StartTime sidecar -- used to confirm a recovered PID belongs to a still-live outer (forgery-resistant: PID reuse has a different StartTime). |
| `inner.pid`              | inner runner per cycle  | outer watchdog        | PID of the current inner cycle. Wiped by the outer before each spawn. |
| `runner.heartbeat`       | C# `System.Threading.Timer` inside inner | (legacy) | Liveness at the process level. Keeps ticking even when the runspace is wedged inside a non-terminating OCR / SSH loop -- therefore **NOT a safe signal for "the cycle is making progress."** |
| `runner.stepHeartbeat`   | `Write-RunnerStepHeartbeat`, from the runspace as work completes | outer watchdog | The signal the watchdog uses to detect a wedged step. Its one writer counts failed writes and reports them, at most once a minute, as a warning and in `runner.stepHeartbeat.errors.log`. |
| `runner.phase`           | inner runner during its preamble | outer watchdog | Present means the inner has not reached its first sequence step, which selects the tighter preamble bound. |
| `runner.watchdog.lapsed` | outer watchdog          | resident runner, cycle process, status service | Durable sentinel written when the watchdog gives up before arming, ending in the bounds it would have applied (`[stepSeconds=N preambleSeconds=M]`). The resident guards the cycle with those bounds while it runs, the status page shows the cycle as unguarded, and the cycle process reports it and removes the file once the inner returns. |
| `inner.start`            | inner runner per cycle  | host refresh, boot recovery | StartTime sidecar of `inner.pid`, written before it. Wiped with `inner.pid` before each spawn. |
| `runner.cycle.json`      | outer runner            | host refresh, inner (preflight) | PID, start time, cycle number and generation of the running cycle process, plus the outer's own identity; removed once the cycle exits. Lets a refresh identify the whole runner chain. |
| `runner.refresh-gated.json` | inner runner         | cycle process         | Written when the inner stops at one of its host-refresh gate sites, naming itself and its parent. Consumed by the cycle process that spawned it. |
| `runner.refresh-evidence.json` | inner runner (service-VM restore) | outer runner | Hypervisor evidence for the automatic refresh decision, stamped with the cycle generation. Read and consumed by the outer after every dispatch. |
| `outer.log`              | outer + inner           | post-mortem, status service | Append-only milestone log. Survives a `conhost` output wedge. |
| `cycle-events.pending.json` | outer runner (boot recovery, runner faults) | next cycle's `Start-LogFile` | Events raised while no cycle is open, written into the next cycle's `cycle.events.ndjson` ahead of `cycle_start`. See [queued events](definition.md#42fa6f45-0030). |

<a id="42f909ad-0013"></a>

### Why two heartbeats

`runner.heartbeat` is written by a `Yuruna.HeartbeatWriter`
`System.Threading.Timer` callback that fires on a threadpool thread.
This is robust to PowerShell pipeline blocks -- which makes it useful
as "the inner process exists at all," but **blind to in-runspace
hangs**.
A sequence step spinning forever in an OCR loop keeps the threadpool-
written heartbeat fresh.

`runner.stepHeartbeat` is touched from the runspace itself: at the top
of every step iteration inside `Invoke-Sequence`, and inside the waits
that make progress on their own clock -- each finished `Wait-ForText`
poll, each `Wait-VmStopped` probe, and the debug break, which also has a
bound (the step's `timeoutSeconds`, else `YURUNA_BREAK_MAX_SECONDS`, else
`testCycle.stepTimeoutSeconds`, 2700 s without one) and ends as a
graceful timeout instead of a watchdog kill. A wedged step stops touching
it. The watchdog reads this file's mtime and kills the
inner when its age exceeds the bound in force -- once the sequence is
running, `testCycle.stepTimeoutSeconds` (2700-second fallback; 3600 in the
shipped template).

<a id="42f909ad-0014"></a>

### Watchdog job

The outer's watchdog is a `Start-Job` (own pwsh) -- heavier than an
in-runspace timer but independent of the outer's pipeline, which is
blocked inside the call-operator that waits for the inner; any
in-runspace monitor (`Register-ObjectEvent`, ThreadJob) cannot pump
during that wait. The Start-Job child fires reliably even when the
outer is completely wedged on the spawn.

The watchdog:

1. Waits up to 180 s for `inner.pid` to appear. The cycle process writes
   `inner.start` and `inner.pid` itself the moment it starts the inner, so
   the identity is there before the inner has loaded a module; the inner
   rewrites the same values. The wait covers a cycle process that could
   not write them. If the file never appears it reports the lapse and
   exits without action, preferable to picking a PID blindly.
2. Reads `inner.pid` and captures the process's `StartTime` alongside it.
   That pair is the armed identity: a PID alone can be reused mid-cycle,
   and killing the wrong process is worse than a missed kill.
3. Every `WatchdogPollSeconds` (default 30 s) checks both:
   - The armed identity still holds. A negative reading is confirmed
     across three spaced probes before disarming, because `Get-Process`
     fails transiently on a loaded host and acting on one false reading
     would disable hang protection for the rest of the cycle.
   - `runner.stepHeartbeat` changed within the bound in force. Its age is
     the heartbeat's UTC age when the job first saw it plus time on a
     monotonic clock since it last changed: an age taken in local time
     moves by an hour at a daylight-saving change, which would kill healthy
     inners each spring. With no heartbeat file yet, age is measured from
     arm time, so an inner wedged before its first step write is still
     detected.
4. On a stale heartbeat: re-verifies the identity, appends a `[watchdog]`
   line to `outer.log` with the observed age and bound, then kills the
   inner **and its descendants** -- a wedged step usually has live
   children (console capture, OCR, ssh) that would otherwise orphan,
   keep handles open, and confuse the next cycle's process discovery.

Every early exit above also writes `runner.watchdog.lapsed`, ending in the
step and preamble bounds the watchdog would have applied. The cycle process
is blocked inside the call-op while the watchdog gives up, but the resident
runner is not: it reads the sentinel while the cycle runs and applies those
bounds to `runner.stepHeartbeat` itself, so a cycle the watchdog cannot guard
still stops when its heartbeat does. The bounds ride in the sentinel because
the pool's `testCycle` overrides that shape them are resolved only in the
cycle process. See [When the resident runner itself is the
problem](#42f909ad-002a).

<a id="42f909ad-0015"></a>

### Two bounds: preamble and step

`runner.phase` selects which bound applies, and the watchdog re-reads it
every poll rather than caching it -- the inner clears the marker the moment a
legitimately long stretch begins, and a cached "still in preamble" would kill
it mid-download.

| `runner.phase` | Bound | Why |
|---|---|---|
| Present | `testCycle.preambleTimeoutSeconds` (default 600) | The inner is still in bootstrap, host detection, the caching-proxy-service gate, status-service start. None of that is legitimately slow. |
| Absent | `testCycle.stepTimeoutSeconds` (2700-second fallback; 3600 in the shipped template) | Either the inner cleared it for a legitimately long stretch (the weekly base-image download) or the sequence has taken over. |

The inner *seeds* `runner.stepHeartbeat` at startup, so without the tighter
bound the preamble is nominally guarded but effectively unguarded: a preamble
stall -- the motivating case being a bare `sudo` prompting on the inherited
terminal with nobody present -- burns the full step budget while the dashboard
still shows the previous cycle's green. Absence of the marker restores plain
step-timeout behavior, so the looser bound is always the failure direction.
A preamble bound at or above the step bound, or a non-positive one, collapses
to "no tighter bound"; that is the documented escape hatch for a host whose
preamble is genuinely slow.

<a id="42f909ad-0016"></a>

### Detecting a watchdog kill after the fact

When the inner exits non-zero AND `runner.stepHeartbeat`'s mtime is
older than the threshold, the cause was almost certainly the watchdog
(the application-level failure path cannot run after a `SIGKILL` /
`TerminateProcess`). The outer prints:

```
[outer cycle N] inner exited non-zero AND runner.stepHeartbeat is
<age>s stale (threshold <thresh>s) -- watchdog likely killed the
inner. See runtime/outer.log for the kill line.
```

This stops operators from chasing an application-level bug that
never happened.

<a id="42f909ad-0017"></a>

### Tuning `testCycle.stepTimeoutSeconds`

The shipped `test/test.config.yml.template` sets 3600 seconds (60 minutes);
the runner falls back to 2700 (45 minutes) when no valid override is configured.
It and `testCycle.preambleTimeoutSeconds` are both
re-read on every cycle's spawn, so an operator can edit `test.config.yml`
between cycles without restarting the outer, and a pool can tighten either
one fleet-wide through its `config.testCycle` override without editing each
host. Tightening helps on hosts where genuine slow steps complete
under, say, 1200; loosening protects against a known-slow first-run
image-build step.

While an edit leaves `test.config.yml` unparsable -- a save caught half
written, a typo in the YAML -- every resident decision (these timeouts, the
cycle ceiling, automatic recovery and its budget, the automatic refresh
threshold, the pool-storage checks) keeps the last configuration that parsed,
and the runner warns once per broken content (`Read-TestConfig
-LastGoodOnError`). Without the fallback, a broken file would read as no configuration,
and the decisions would fall back to their defaults, automatic recovery off among
them. The next cycle's own configuration gate still refuses to start on a file
that does not parse.

<a id="42f909ad-0018"></a>

### Module: Test.RunnerWatchdog

[`test/modules/Test.RunnerWatchdog.psm1`](../test/modules/Test.RunnerWatchdog.psm1)
holds the arm/teardown pair the cycle calls, plus the shared
armed-identity predicate. Keeping them in their own
module -- rather than inline in
[`test/Start-TestRunner.ps1`](../test/Start-TestRunner.ps1) --
makes the heartbeat-kill logic testable in isolation: a unit test can
`Start-Watchdog`, write a stale `runner.stepHeartbeat`, and observe
the kill without spinning up an inner runner. Its exports and their
parameters are in the module's `Export-ModuleMember` block and
comment-based help; the cycle arms one per spawn and tears it down in a
`finally` on cycle end, spawn failure, or a throw in between.

`Start-Watchdog` returns a `System.Management.Automation.Job` whose
own child pwsh runs the polling scriptblock. `Stop-Watchdog` is
safe with `$null` and safe after the watchdog has already exited
(both `Stop-Job` and `Remove-Job` are `SilentlyContinue`).

The identity predicate is exported as *source text* and rebuilt inside the
job, because a `Start-Job` child is a separate process that cannot see this
module's functions. The tests and the live watchdog therefore exercise one
definition rather than two that can drift apart.

<a id="42f909ad-0019"></a>

#### `$using:` scope discipline

The scriptblock passed to `Start-Job` reads its inputs -- the runtime dir,
both timeout bounds, the poll cadence and the identity-predicate source --
via `$using:` rather than
`-ArgumentList`. The `$using:` form pulls each variable straight from
the enclosing function's scope at job-dispatch time -- cleaner than
threading them through a positional argument list, and dodges a
PSScriptAnalyzer false positive on
`PSUseUsingScopeModifierInNewRunspaces` when the scriptblock has its
own `param()` declaration.

The function carries an explicit
`[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'PollSeconds')]`
because PSSA's static analyzer does not follow `$using:` references
back to the enclosing function's param block.

<a id="42f909ad-001a"></a>

## Runner state machine

The outer test runner's lifecycle is an explicit six-state machine in
[`test/modules/Test.RunnerState.psm1`](../test/modules/Test.RunnerState.psm1).
Every transition writes `$YURUNA_RUNTIME_DIR/runner.state.json`
atomically and emits a `runner_state_transition` NDJSON event so a
dashboard or off-host consumer can follow the runner without
reconstructing what it is doing from heartbeat mtimes and pidfile
presence.

Without it, a watchdog or dashboard has to guess: "if `inner.pid`
exists and `runner.stepHeartbeat` is fresh then a cycle is running,
unless the inner just exited and we're between cycles, unless..." The
explicit machine gives the lifecycle a single observable shape.

<a id="42f909ad-001b"></a>

### States

| State | Meaning |
|---|---|
| `idle` | The runner is alive and ready for the next cycle. |
| `cycle-start` | A new cycle is starting; pre-spawn work (git pull, cleanup) is in flight. |
| `in-cycle` | The inner runner is executing sequence steps. |
| `cycle-end` | The inner exited 0; the outer is in post-cycle cleanup. |
| `fault` | The inner exited non-zero or crashed before exit. |
| `paused` | The failure-pause loop is waiting for a new commit, a config edit, or the cap. |

<a id="42f909ad-001c"></a>

### Valid transitions

```
idle         -> cycle-start, fault   (fault when boot recovery sees a stale prior state)
cycle-start  -> in-cycle, fault, paused
in-cycle     -> cycle-end, fault
cycle-end    -> idle
fault        -> paused, idle
paused       -> idle, cycle-start
```

The `cycle-start <-> paused` pair is the healthy pool-hold loop: when a
pulled pool configuration has `configuredState=paused`, a started cycle moves to
`paused`, and each ~30s configuration re-poll re-enters `cycle-start`.

The validator never rejects -- an unrecognized pair logs a
`Write-Warning` and writes the new state anyway. Same contract as the
event-schema validator: catch drift loudly, never lose telemetry.

<a id="42f909ad-001d"></a>

### Public surface

Two functions carry the lifecycle: `Initialize-RunnerState` at outer startup
and `Set-RunnerState` at every cycle boundary. The rest of the module's
exports are readers -- the canonical state names, the on-disk path, the
current state, and the transition predicate -- for the capability matrix, the
dashboard and the tests. The list is the module's `Export-ModuleMember` block
in [`Test.RunnerState.psm1`](../test/modules/Test.RunnerState.psm1).

<a id="42f909ad-001e"></a>

### Files on disk

| File | Writer | Reader | Purpose |
|---|---|---|---|
| `runner.state.json` | `Set-RunnerState` (atomic) | Status service, next outer's `Initialize-RunnerState`, post-mortem | Current state and when it was entered, the writing runner's runId and PID, the last 20 transitions, and the most recent cycle's start/number carried forward so a single read has the cycle context without joining to the manifest. |
| NDJSON event stream | `Set-RunnerState` via [`Test.Log`](../test/modules/Test.Log.psm1) | Off-host log shipper | One `runner_state_transition` event per transition, carrying `fromState`, `toState` and the free-text `reason` verbatim so a consumer can pivot on it without joining back to the cycle context. Boot-recovery transitions add `synthetic` plus the crashed runner's identity. |

<a id="42f909ad-001f"></a>

### Boot recovery

On outer startup, `Initialize-RunnerState` reads the prior
`runner.state.json`. If it shows a runId other than ours AND a state
that isn't `idle`, the previous outer crashed mid-lifecycle. The
function synthesizes a `<stale-state> -> fault -> idle` transition
pair so a downstream consumer sees the crash explicitly, not as a
silent gap in the stream. Then it writes a fresh `idle` state under
the new runId.

This pairs with [`Test.Recovery`](../test/modules/Test.Recovery.psm1)'s
boot sweep, which archives orphan `.incomplete` cycle folders, deletes
pidfiles whose PID is no longer live, and archives a `break-active.json`
no live runner can honor. The state machine
synthesizes the *narrative*; `Test.Recovery` cleans the *state*.

Before archiving an orphaned cycle, the sweep compares the newest write
time of any file in its folder with the host's boot time (`btime` in
`/proc/stat` on Linux, `kern.boottime` on macOS, the time since boot on
Windows). A host that froze leaves files whose data never reached the disk
but whose entries did, so that newest write is within seconds of the
freeze. The host counts as restarted under the cycle when it booted after
both that write and the start in the cycle's marker, within five seconds;
a runner killed and started again without a reboot finds a boot from
before the cycle and never counts. The archived `.aborted.<UTC>.json`
carries `lastWriteUtc`, `bootUtc`, `hostRestarted` and `downSeconds` (boot
minus last write).

For a host restart the sweep also writes into the aborted folder
`host-restart.json` (what each command returned, the hardware-error lines,
any crash reports, and whether the system journal was readable) and
`host-restart.txt` (the output). On Linux: `journalctl --list-boots`, the
previous boot's last 300 journal lines and its kernel warnings, the
current boot's kernel lines naming BERT, a hardware error, a machine check,
EDAC, AER or a watchdog, and the head of `last -x -F`. journalctl reads
only the runner's own journal unless the account is in `systemd-journal`
or `adm`; the evidence says so instead of failing. A host in deep
diagnostics mode writes one bundle per boot to
`/var/log/yuruna/deep-diagnostics/`; bundles written since the cycle's
last write are copied in as `host-restart.deep-diagnostics.<name>`, or the
reason they could not be read is recorded. On Windows: the System log's
Kernel-Power 41, 6008 and BugCheck 1001 events and the minidumps written
since then. On macOS: the panic reports written since then and the head of
`last reboot`. Every command is bounded, and a failure is recorded, never
thrown.

No cycle is open during the sweep, so its events -- one `host_restart` per
cycle the host restarted under, then `boot_recovery_completed` -- wait in
`runtime/cycle-events.pending.json` and are written into the next cycle's
event stream ahead of its `cycle_start`, where the pool collects them
(see [queued events](definition.md#42fa6f45-0030)).

<a id="42f909ad-0020"></a>

### History depth

`runner.state.json` keeps the last 20 transitions inline as a cheap
"what just happened" cache for `/control/runner-status` and similar
quick lookups. The NDJSON stream is the canonical history.

<a id="42f909ad-0021"></a>

## Related

- [Remediation dispatcher](failure-schema.md#remediation-dispatcher) -- what runs *after* a `fault`.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.11.05

Back to [Yuruna](../README.md)
