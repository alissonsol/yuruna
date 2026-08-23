# Test runner — setup, outer-loop dispatcher, watchdog, and state machine

Please read the **Administrator Risk Warning** section of the
[Yuruna License](../LICENSE.md).

`test/Start-TestRunner.ps1` is the daily-driver loop, meant to run for hours
or days without an operator present. This document covers both halves: what to
do **once per machine** before leaving the runner unattended, then what the
eternal cycle loop it launches actually does.

See [test-config.md](test-config.md) for the `test.config.yml` parameter
reference, including the optional `networkStorage` NAS replication tier and how
to set its SMB password in the vault; [pool-storage.md](pool-storage.md) covers
that tier's architecture and operations. For how `test/` as a whole is put
together, see [Test harness -- architecture](test-harness.md).

The eternal cycle loop in
[`test/modules/Test.RunnerOuterLoop.psm1`](../test/modules/Test.RunnerOuterLoop.psm1)
is what makes the test runner resilient. Each pass pulls the repository,
re-reads `test.config.yml`, refreshes base images on a configurable cadence,
then walks the cycle plan resolved from `test.runner.yml` -- creating a fresh
VM, driving its sequences, and recording results. Concretely, each cycle:

1. `git pull` the framework repo.
2. Reconcile the pool intent when the host belongs to a pool: `drain` stops
   the runner at this cycle boundary, `paused` holds without spawning.
3. Wipe last cycle's `inner.pid` / `runner.stepHeartbeat` /
   `runner.phase` / `last_failure.json` / `break-active.json`.
4. Arm the [watchdog](#watchdog-and-heartbeat-protocol).
5. Spawn the inner runner via the call operator.
6. On `exitCode == 0`, loop immediately. On non-zero, pause until one of the
   [break-out triggers](#failure-pause-break-out-triggers) fires.

Steps 1-5 run in a **fresh pwsh per cycle** (`Invoke-TestCycleRunner.ps1`), so
the cycle logic and every module it imports are re-read from disk every cycle
and an operator edit takes effect on the next one with no runner restart. The
loop process keeps only what must not be re-derived per cycle: the pidfile,
the boot-recovery sweep, the state machine, the Ctrl+C subscription, and the
cross-cycle counters. It polls that child in slices rather than blocking on
it, which is what makes Ctrl+C observable mid-cycle and able to take the whole
child tree down with it. With no cycle script on disk the loop runs the cycle
in-process instead -- identical behavior except that an edit then needs a
restart, and the shape the unit tests drive. That is why the loop body lives
in a module rather than inline in
[`test/Start-TestRunner.ps1`](../test/Start-TestRunner.ps1): mocking the
call-op + `Set-RunnerState` exercises the state-transition sequence without
spawning a real inner pwsh.

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

## Prepare the host

**Do not run unattended test automation using a personal account.**

Unattended machines are assumed to be in a physically protected
environment, like a test lab, with controlled access. Even so, use test
accounts with limited network access and no access to personal data on
the local machine.

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
    out. If the OS account already exists, `-Force` deletes it -- home
    directory included -- and creates it again; preview that with
    `-Force -WhatIf` before running it.
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
  - **macOS and Windows base images must be downloaded manually.**
    Image-provider limitations keep the runner from fetching them;
    follow the instructions in each `Get-Image.ps1`.

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

## Startup gates

`Start-TestRunner.ps1` refuses to enter the eternal loop when either of
two conditions holds. Both are hard stops rather than warnings, because
the failure mode they guard against is a loop that keeps producing
near-empty cycles -- expensive to notice and diagnose after the fact.

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
transcript simply ignores the field.

`-ExpectStorageConfigured` is a caller telling the gate that shared
storage was supposed to have been stood up before it ran. An absent or
half-populated `networkStorage` pool tier is ordinary on a host that never
asked for shared storage, and is proof that nothing landed on one that
did; the gate cannot tell those apart by reading the file. Only
`install/setup.ps1` passes it, and only when `storage.kind` is not
`none` -- an operator running `Test-Config.ps1` by hand is unaffected.

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
| `FailureCommitPollSeconds` | `[int]` | Trigger-poll cadence inside the pause (default 5 min). |
| `OuterPullErrorSleepSeconds` | `[int]` | Short retry sleep when the outer's own `git pull` fails. |
| `InnerSpawnErrorSleepSeconds` | `[int]` | Short retry sleep when `Start-Process` itself fails. |
| `StepTimeoutSecondsDefault` | `[int]` | Watchdog default (overridden per-cycle by `testCycle.stepTimeoutSeconds`). |
| `WatchdogPollSeconds` | `[int]` | Watchdog poll cadence (default 30 s). |

A missing key throws `Invoke-RunnerOuterLoop: -State is missing
required key '<name>'.` at entry, catching wiring bugs at the
entry-point edit site rather than mid-cycle.

Two more keys are optional, both resolved to a default when absent so an
older caller (or a unit test) that omits them still runs: `CycleScript`, the
path to `Invoke-TestCycleRunner.ps1` -- absent, the cycle runs in-process --
and `PreambleTimeoutSecondsDefault`, the watchdog's tighter preamble bound.

## Failure-pause break-out triggers

After the inner exits non-zero, the loop captures three baselines and
polls five triggers every `FailureCommitPollSeconds` until the cap or one of
them fires. The 5-second slice sleep inside the poll loop keeps
Ctrl+C responsive (`Start-Sleep` cannot be interrupted by our event
handler in long sweeps).

| Trigger | Baseline | Probe |
|---|---|---|
| Framework commit | `git rev-parse HEAD` | `git fetch` + `rev-parse @{u}` |
| Project commit | `git ls-remote <projectUrl> HEAD` | Same `ls-remote` at poll time |
| Local config edit | `Get-OuterConfigMtime` | Same call at poll time; `-ne` comparison handles changed / created / deleted in one shot |
| Status-UI start request | (none) | Existence of `$YURUNA_RUNTIME_DIR/control.cycle-restart` |
| Auto-remediation (default off) | (none) | `last_failure.json`'s class is one the [remediation dispatcher](failure-schema.md#remediation-dispatcher) maps to a clearly-safe retry |

Network / IO failure on any individual probe is treated as "no
change for now" (return `$null` / unchanged baseline) so a flaky
network can't cut a pause short and a missing config file can't
crash the loop.

The auto-remediation trigger is capped per consecutive-failure streak, and
the streak is held in the loop process rather than the per-cycle child: a
fresh process each cycle would reset it to zero every time, so the cap would
never be reached and a deterministic transient would auto-retry forever. A
passing cycle re-arms the budget. Everything the dispatcher does not classify
as clearly-safe keeps the full wait-for-human pause.

## State transitions emitted

The dispatcher calls `Set-RunnerState` at every cycle boundary so a
streaming consumer sees the lifecycle explicitly. Full enum and
transition table live in the
[Runner state machine](#runner-state-machine) section below.

| Cycle phase | Transition |
|---|---|
| Cycle opened, before any per-cycle work | `idle -> cycle-start` |
| Watchdog armed | `cycle-start -> in-cycle` |
| Inner exited 0 | `in-cycle -> cycle-end -> idle` |
| Inner exited non-zero | `in-cycle -> fault` |
| Pool `desiredState=paused` (hold) | `cycle-start -> paused`, then `paused -> cycle-start` on the ~30s intent re-poll |
| Entering failure-pause | `fault -> paused` |
| Pause broke out | `paused -> idle` |

Each `Set-RunnerState` call is `Get-Command`-guarded so a stripped-
down test fixture that did not import `Test.RunnerState` still runs
the loop body.

## Pre-spawn cleanup ordering

Five files are wiped before the watchdog is armed, each for its own reason.

| File | Why it is wiped pre-spawn |
|---|---|
| `inner.pid` | A stale file makes `Start-Watchdog` skip its wait-for-pidfile loop, read the dead PID, fail to capture an identity for it, and lapse within seconds -- leaving the new inner unwatched for the whole cycle. |
| `runner.stepHeartbeat` | The symmetric trap: the watchdog would see an hours-old mtime and kill the new inner before it started its first step. |
| `last_failure.json` | `Invoke-Sequence` removes it at the start of each sequence, but between the previous cycle's failure and the new cycle's first sequence there is a multi-second window where a dashboard or status-service reader sees stale cycle-N failure context attached to cycle N+1. Pre-spawn deletion closes that window. |
| `runner.phase` | It selects the watchdog's TIGHT preamble bound, so a copy left behind by a killed inner would apply that bound to the next cycle's sequence steps and kill healthy long ones. The new inner re-creates it within its first second; until then its absence means the loose bound, which is the safe direction. |
| `break-active.json` | Written by the `break` sequence action when a cooperative breakpoint parks the cycle, and removed on resume. Restarting only `Start-TestRunner.ps1` while a break is parked leaves the file behind, and the first new-cycle step's Gate #1 then hangs the cycle waiting on a breakpoint nobody set. Status-service startup sweeps it too, but the runner can start without the status service, so both startup paths clean it. |

The **pool-storage space check** runs immediately after the `last_failure.json`
wipe, and the ordering is load-bearing. On a host archiving in move mode it
refuses to spawn a cycle whose
results the share has no room for, recording a `pool_storage_full`
`last_failure.json` of its own -- and the failure pause classifies from exactly that
file. Placed *before* the wipe, the previous cycle's record would still be there;
if its class happened to be a transient one, auto-remediation would cut the storage
pause short and the runner would spend the day re-discovering that nobody has
deleted anything yet. The check returns the `storage-full` outcome, which is
deliberately absent from the short-hold list so it takes the full pause.

Order matters elsewhere too: `Remove-Item` first, then a "force-fresh"
`WriteAllText` on `runner.stepHeartbeat`. If `Remove-Item` fails on
the heartbeat (locked file, AV mid-scan, anything), the watchdog
about to arm would read the stale mtime and kill the new inner
within one poll. The unconditional `WriteAllText` defends against
that -- the new inner overwrites it again immediately at startup, so
the force-touch is harmless when the wipe succeeded.

## Why the cycle call must not capture the inner runner's stdout

The cycle process reaches the inner runner through the call operator, and
PowerShell decides the inner's stdout from what happens to the ENCLOSING
function's success stream: let it reach the host and the inner inherits the
console; capture it anywhere up the chain -- assign the call's result, pipe it,
wrap the caller in `$(...)` -- and PowerShell has to create an anonymous pipe
and read it to EOF.

EOF, not the inner's exit, is then what releases the cycle. The inner spawns the
status service, which inherits a duplicate of that write end and holds it for
its whole unbounded life, so the cycle never returns: the inner logs that it is
about to exit with code 0, and the outer's "back in control" line never follows.
One cycle passes and the runner starts no more -- the worst shape an unattended
runner can fail in, because nothing reports an error. Observed on a live Hyper-V
host with the cycle process blocked 44 minutes past a passing cycle, released
within a second of killing the status service.

This is a Windows-only exposure. The POSIX branch of `Start-StatusService.ps1`
detaches through `bash -c "... </dev/null >/dev/null 2>err &"`, whose
redirections replace the descriptors outright, so nothing crosses the exec and
no Linux or macOS host in the pool can reach the condition.

A regression test rebuilds the cycle -> inner -> status-service topology in a
temporary directory and asserts that the cycle process returns once the inner
exits, so a future refactor that captures the stream fails a suite instead of a
lab.

## Watchdog and heartbeat protocol

The test runner survives indefinitely under sustained guest, network,
and host-OS failures because every long-running activity emits a
heartbeat that an out-of-process watchdog reads. When the heartbeat
goes stale, the watchdog kills the wedged process and the outer
runner re-spawns the inner from a clean state.

### Layout under `$YURUNA_RUNTIME_DIR`

| File                     | Writer                  | Reader                | Purpose |
|--------------------------|-------------------------|-----------------------|---------|
| `runner.pid`             | outer runner            | next outer + status service | Single-instance guard; PID of the outer eternal-loop process. |
| `runner.start`           | outer runner            | next outer + status service | StartTime sidecar -- used to confirm a recovered PID belongs to a still-live outer (forgery-resistant: PID reuse has a different StartTime). |
| `inner.pid`              | inner runner per cycle  | outer watchdog        | PID of the current inner cycle. Wiped by the outer before each spawn. |
| `runner.heartbeat`       | C# `System.Threading.Timer` inside inner | (legacy) | Liveness at the process level. Keeps ticking even when the runspace is wedged inside a non-terminating OCR / SSH loop -- therefore **NOT a safe signal for "the cycle is making progress."** |
| `runner.stepHeartbeat`   | `Invoke-Sequence` at the top of each step | outer watchdog | Touched from the runspace itself. The signal the watchdog uses to detect a wedged step. |
| `runner.phase`           | inner runner during its preamble | outer watchdog | Present means the inner has not reached its first sequence step, which selects the tighter preamble bound. |
| `runner.watchdog.lapsed` | outer watchdog          | outer runner          | Durable sentinel written when the watchdog gives up before arming. The outer is blocked on the call-op while that happens, so an unguarded cycle would otherwise be invisible until a post-mortem. |
| `outer.log`              | outer + inner           | post-mortem, status service | Append-only milestone log. Survives a `conhost` output wedge. |

### Why two heartbeats

`runner.heartbeat` is written by a `Yuruna.HeartbeatWriter`
`System.Threading.Timer` callback that fires on a threadpool thread.
This is robust to PowerShell pipeline blocks -- which makes it useful
as "the inner process exists at all," but **blind to in-runspace
hangs**.
A sequence step spinning forever in an OCR loop keeps the threadpool-
written heartbeat fresh.

`runner.stepHeartbeat` is touched from the runspace itself, at the
top of every step iteration inside `Invoke-Sequence`. A wedged step
stops touching it. The watchdog reads this file's mtime and kills the
inner when its age exceeds the bound in force -- once the sequence is
running, `testCycle.stepTimeoutSeconds` (default 2700).

The split was added after the trap recorded in repo memory
`feedback_threadpool_heartbeat_watchdog_blind.md`.

### Watchdog job

The outer's watchdog is a `Start-Job` (own pwsh) -- heavier than an
in-runspace timer but independent of the outer's pipeline, which is
blocked inside the call-operator that waits for the inner; any
in-runspace monitor (`Register-ObjectEvent`, ThreadJob) cannot pump
during that wait. The Start-Job child fires reliably even when the
outer is completely wedged on the spawn.

The watchdog:

1. Waits up to 180 s for `inner.pid` to appear. A loaded host can take
   well past a minute to spawn pwsh and import the runner modules, and
   giving up early runs the whole cycle unguarded while a longer wait
   costs nothing -- the job just idles. If the file never appears it
   reports the lapse and exits without action, preferable to picking a
   PID blindly.
2. Reads `inner.pid` and captures the process's `StartTime` alongside it.
   That pair is the armed identity: a PID alone can be reused mid-cycle,
   and killing the wrong process is worse than a missed kill.
3. Every `WatchdogPollSeconds` (default 30 s) checks both:
   - The armed identity still holds. A negative reading is confirmed
     across three spaced probes before disarming, because `Get-Process`
     fails transiently on a loaded host and acting on one false reading
     would disable hang protection for the rest of the cycle.
   - `runner.stepHeartbeat`'s mtime is younger than the bound in force.
     With no heartbeat file yet, age is measured from arm time, so an
     inner wedged before its first step write is still detected.
4. On a stale heartbeat: re-verifies the identity, appends a `[watchdog]`
   line to `outer.log` with the observed age and bound, then kills the
   inner **and its descendants** -- a wedged step usually has live
   children (console capture, OCR, ssh) that would otherwise orphan,
   keep handles open, and confuse the next cycle's process discovery.

Every early exit above also writes `runner.watchdog.lapsed`. The outer is
blocked inside the call-op while the watchdog gives up, so the sentinel is
what turns "this cycle ran unguarded" into a warning the operator sees when
the outer regains control.

### Two bounds: preamble and step

`runner.phase` selects which bound applies, and the watchdog re-reads it
every poll rather than caching it -- the inner clears the marker the moment a
legitimately long stretch begins, and a cached "still in preamble" would kill
it mid-download.

| `runner.phase` | Bound | Why |
|---|---|---|
| Present | `testCycle.preambleTimeoutSeconds` (default 600) | The inner is still in bootstrap, host detection, the caching-proxy gate, status-service start. None of that is legitimately slow. |
| Absent | `testCycle.stepTimeoutSeconds` (default 2700) | Either the inner cleared it for a legitimately long stretch (the weekly base-image download) or the sequence has taken over. |

The inner *seeds* `runner.stepHeartbeat` at startup, so without the tighter
bound the preamble is nominally guarded but effectively unguarded: a preamble
stall -- the motivating case being a bare `sudo` prompting on the inherited
terminal with nobody present -- burns the full step budget while the dashboard
still shows the previous cycle's green. Absence of the marker restores plain
step-timeout behavior, so the looser bound is always the failure direction.
A preamble bound at or above the step bound, or a non-positive one, collapses
to "no tighter bound"; that is the documented escape hatch for a host whose
preamble is genuinely slow.

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

### Tuning `testCycle.stepTimeoutSeconds`

Default 2700 (45 minutes). It and `testCycle.preambleTimeoutSeconds` are both
re-read on every cycle's spawn, so an operator can edit `test.config.yml`
between cycles without restarting the outer, and a pool can tighten either
one fleet-wide through its `config.testCycle` override without editing each
host. Tightening helps on hosts where genuine slow steps complete
under, say, 1200; loosening protects against a known-slow first-run
image-build step.

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

### States

| State | Meaning |
|---|---|
| `idle` | The runner is alive and ready for the next cycle. |
| `cycle-start` | A new cycle is starting; pre-spawn work (git pull, cleanup) is in flight. |
| `in-cycle` | The inner runner is executing sequence steps. |
| `cycle-end` | The inner exited 0; the outer is in post-cycle cleanup. |
| `fault` | The inner exited non-zero or crashed before exit. |
| `paused` | The failure-pause loop is waiting for a new commit, a config edit, or the cap. |

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
pulled pool intent has `desiredState=paused`, a started cycle moves to
`paused`, and each ~30s intent re-poll re-enters `cycle-start`.

The validator never rejects -- an unrecognized pair logs a
`Write-Warning` and writes the new state anyway. Same contract as the
event-schema validator: catch drift loudly, never lose telemetry.

### Public surface

Two functions carry the lifecycle: `Initialize-RunnerState` at outer startup
and `Set-RunnerState` at every cycle boundary. The rest of the module's
exports are readers -- the canonical state names, the on-disk path, the
current state, and the transition predicate -- for the capability matrix, the
dashboard and the tests. The list is the module's `Export-ModuleMember` block
in [`Test.RunnerState.psm1`](../test/modules/Test.RunnerState.psm1).

### Files on disk

| File | Writer | Reader | Purpose |
|---|---|---|---|
| `runner.state.json` | `Set-RunnerState` (atomic) | Status service, next outer's `Initialize-RunnerState`, post-mortem | Current state and when it was entered, the writing runner's runId and PID, the last 20 transitions, and the most recent cycle's start/number carried forward so a single read has the cycle context without joining to the manifest. |
| NDJSON event stream | `Set-RunnerState` via [`Test.Log`](../test/modules/Test.Log.psm1) | Off-host log shipper | One `runner_state_transition` event per transition, carrying `fromState`, `toState` and the free-text `reason` verbatim so a consumer can pivot on it without joining back to the cycle context. Boot-recovery transitions add `synthetic` plus the crashed runner's identity. |

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

### History depth

`runner.state.json` keeps the last 20 transitions inline as a cheap
"what just happened" cache for `/control/runner-status` and similar
quick lookups. The NDJSON stream is the canonical history.

## Related

- [Remediation dispatcher](failure-schema.md#remediation-dispatcher) -- what runs *after* a `fault`.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.23

Back to [Yuruna](../README.md)
