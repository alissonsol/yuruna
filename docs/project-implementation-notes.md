<a id="42010605-0001"></a>

# Project and test implementation notes

These notes explain constraints shared by workspace test entry points, lab tools,
project examples, and AmisAd guest workloads. Use the same phase names for the
same operation; retain host, application, and transport differences required by
the constraint described below. See [source consistency](https://yuruna.link/42e220c4-0001).

<a id="42010605-0002"></a>

## Runner entrypoints

<a id="42010605-0303"></a>

### Pass the planner's List[object] straight through -- do NOT wrap in @(). Resolve-TestSequencePlan alw

`yuruna/test/Debug-TestSequence.ps1`

Pass the planner's List[object] straight through -- do NOT wrap in @().
Resolve-TestSequencePlan always returns chainEntries as a List (an IList),
which binds directly to the IList parameter. Wrapping a generic List in @()
yields an array that a Mandatory [IList]/[object[]] parameter rejects with
"Argument types do not match" (a PowerShell @()-over-List binding quirk), so
the wrap would break the very single-entry warm path it appears to protect.

<a id="42010605-0304"></a>

### Run each chain entry that overlaps the requested step range

`yuruna/test/Debug-TestSequence.ps1`

Per-entry step-window run + mid-chain rename detection lives in
Test.SequenceRunner.psm1 (Invoke-TestSequenceChain); it runs each entry's real
file via Invoke-Sequence -StartStep/-StopStep, so there are no slice temp
files to sweep. A mid-chain saveDiskSnapshot rename surfaces via the returned
finishedVmName so this script's outer $VMName tracks the rename for the
post-run banner.
Outcome tracker for the finally{} -- script-scope so a mid-try exit
captures the right disposition before Stop-LogFile emits cycle_end.
'unknown' is the safe default if control bails before either of the
success/failure branches assigns.

<a id="42010605-0305"></a>

### Register this run as a cycle in status.json

`yuruna/test/Debug-TestSequence.ps1`

Without this block a Debug-TestSequence run lands under cycle "000000" with
no row in the dashboard's history table, and break-active.json has no live
cycle to anchor the Continue button against. Mirrors
Invoke-TestRunnerInnerLoop's shape but uses a single 'Sequence' step: the
inner runner's fixed phase pills -- New-VM / Start-VM / Start-GuestOS / ...
-- would render four "pending" chips that never animate, since
Debug-TestSequence skips those phase boundaries.
$nestedNodeId is the id of this run's node in the owner's `nested` map; it
stays $null for an owner run and is read again in the finally{} to finalize
the node, so it must live in the script scope BEFORE the branch.

<a id="42010605-0306"></a>

### Ensure VM is running

`yuruna/test/Debug-TestSequence.ps1`

Skipped when the first EXECUTED step (honoring -StartStep, and reading through a
wrapper such as `retry` to the inner step that actually runs) is `loadDiskSnapshot`:
that handler tolerates a stopped VM as input (its host driver gates the pre-restore
Stop-VM on `if running`), runs the restore against the offline disk,
and starts the VM itself on return. Pre-booting here would only force
the handler to immediately Stop-VM again -- a wasted Start+Wait cycle
(~15-20s of boot-delay + Hyper-V cold-stop poll) on every warm-path run.

<a id="42010605-0307"></a>

### Forward -Username / -Hostname when the sequence declares them. Mirrors Invoke-TestRunnerInnerLoop's

`yuruna/test/Debug-TestSequence.ps1`

Forward the planned -Username / -Hostname to New-VM. Resolve-TestSequencePlan
walks the baseline chain and returns the effective username and hostname,
using the same variable cascade as the recurring runner. Empty values fall
through to the per-host New-VM defaults (the account default and the VM name,
respectively).

<a id="42010605-0308"></a>

### Reuse skips the entire New-VM path, so the switch selection that runs there never runs: the VM keeps

`yuruna/test/Debug-TestSequence.ps1`

Reuse skips the entire New-VM path, so the switch selection that runs
there never runs: the VM keeps whatever vNIC attachment it was created
with, and no host-side network change ever reaches it. A Hyper-V vSwitch
object outlives its uplink binding across a host reboot, so the switch
still existing is not evidence that it still bridges -- revalidate the
attachment before the sequence engine spends its step budget on a guest
that can never reach the network. Report only: this script has no
VM-file sweep, so re-creating the VM belongs to the runner's per-guest
iteration, not here. The Get-Command guards keep the whole block inert
on host.ubuntu.kvm and host.macos.utm.

<a id="42010605-0309"></a>

### Resolve caching-proxy service URL

`yuruna/test/Debug-TestSequence.ps1`

Mirror Invoke-TestRunnerInnerLoop: resolve once via Test-CachingProxyServiceAvailable
(honors $Env:YURUNA_CACHING_PROXY_SERVICE_IP for remote caches, falls back to
locally-recorded state) and forward to New-VM so the guest's cloud-init
user-data templates the proxy URL. Without this forward, the per-guest
New-VM.ps1 falls into local Get-VM yuruna-caching-proxy-service discovery and
warns "no cache" even when the operator has a healthy remote cache.

<a id="42010605-000a"></a>

### Resolve the caching-proxy-service endpoint from config + env

`yuruna/test/Debug-TestSequence.ps1`

Invoke-TestRunnerInnerLoop reads BOTH $Config.vmStart.cachingProxyIp (the
persistent UI-edited key, probed first) and $env:YURUNA_CACHING_PROXY_SERVICE_IP
(session-scope fallback, probed only when the config candidate is
absent or fails), keeps the first whose HTTP proxy port is reachable,
and clears the env when none answers. Debug-TestSequence runs the SAME
Resolve-CachingProxyServiceEndpoint so a syntactically valid but dead IP
configured via the status service's Edit-config page can't survive into
guest cidata here either. When neither source is set, the resolver is
a no-op and the local-discovery path in Test-CachingProxyServiceAvailable
below runs unchanged.

<a id="42010605-000b"></a>

### SSH-user override

`yuruna/test/Debug-TestSequence.ps1`

Same cascade registration as Invoke-TestRunnerInnerLoop: Test.Ssh's
Get-GuestSshUser is the lookup point for Save-GuestDiagnostic +
host-driver SSH-mode Send-Text / fetchAndExecute SSH. Standalone
Debug-TestSequence runs the same chain as a one-off, so register the
same override here. Empty $effectiveUser falls through to the
hardcoded per-guest default via Get-GuestSshUser unchanged.

<a id="42010605-000c"></a>

### Concurrent-VM admission

`yuruna/test/Debug-TestSequence.ps1`

Two cycles on one VM set corrupt each other, so the run starts only on a host
it has positively found free of other guests. On some macOS versions
vmnet-shared also assigns a separate host-side bridge per vmnet "session"
(bridge100, bridge101, ...) that don't route between each other, so a foreign
concurrent VM can push the test guests onto a different bridge from the host's
vmnet gateway and break the cloud-init host-proxy URL baked into seed.iso.
The service VMs and the operator's target ($VMName) are exempt; the target may
be left up for another iteration of the same debug sequence.
The admission step stops first and refuses second: a leftover guest is
stopped rather than left to strand the host, and the refusal covers only what
would not stop -- or a host that cannot say what is running.

<a id="42010605-000d"></a>

### Build chain plan

`yuruna/test/Debug-TestSequence.ps1`

Chain planning + warm-path requiresSnapshot probe live in
Test.SequenceRunner.psm1 so they can be unit-tested with fixture
data. Behavior: walk the
baseline chain, build (name,path,sequence,stepCount,globalStart) per
entry, and -- when the top-level declares requiresSnapshot.id and
the snapshot is already on disk -- drop every prereq and run only
the top-level against the persisted VM. effectiveUsername must be
known BEFORE New-VM below, matching the runner's same forward.

<a id="42010605-000e"></a>

### Derive GuestKey from the sequence's baseline map

`yuruna/test/Debug-TestSequence.ps1`

Source of truth is the sequence's `baseline:` field -- whichever OS
key(s) it lists tell us which guest VM the sequence targets. The
filename is NOT authoritative: a typo or rename would otherwise
silently derail the whole chain (and a project sequence like
`ch01.website.example.yml` has no guest token in its name at all).
Same lookup the cycle planner uses in Resolve-CyclePlan
(Test.SequencePlanner.psm1) for Start-TestRunner / Invoke-TestProject,
kept symmetric so Debug-TestSequence behaves the same standalone.

<a id="42010605-000f"></a>

### Same hazard the guest path guards against further down: a foreign running VM can share the host with

`yuruna/test/Debug-TestSequence.ps1`

Same hazard the guest path guards against further down: a foreign running
VM can share the host with this run (and, on macOS, push its guests onto a
second host-side bridge that does not route to the host's vmnet gateway,
breaking the cloud-init host-proxy URL baked into seed.iso). This path
returns before ever reaching that guard, and Test.Orchestrator has none of
its own, so the admission has to run here too. It stops first and refuses
second, so a leftover guest is stopped rather than left to strand the host.
No -ExceptVmName: an orchestration run creates a VM per inner sequence
instead of targeting one named guest, so there is nothing to exempt.

<a id="42010605-0010"></a>

### Orchestration sequence dispatch (InvokeTestSequence steps)

`yuruna/test/Debug-TestSequence.ps1`

An orchestration sequence has no `baseline:` and its steps invoke inner
sequences (guest or host-action) in order. Detected here -- after the
host driver, runtime dirs, single-instance guard and OCR setup are up,
but before the guest-only GuestKey + VM path -- and handed to
Test.Orchestrator, which owns its own status cycle + log and returns an
exit code.

<a id="42010605-0011"></a>

### Sweep the stale inter-cycle control state a freshly-typed Debug-TestSequence command line must not i

`yuruna/test/Debug-TestSequence.ps1`

Sweep the stale inter-cycle control state a freshly-typed Debug-TestSequence
command line must not inherit. -Scope Startup consumes control.cycle-
restart (so Invoke-Sequence Gate #1 doesn't throw YurunaCycleRestart on
our first step and make it look like the SEQUENCE broke) AND archives a
leftover break-active.json + clears leftover pause flags (so the status
UI doesn't show a Continue pending, and the run doesn't start paused,
from a prior session the operator never resumed). The operator typed
THIS command line, so we honor the intent to run over the stale flags.
Nested runs must NOT sweep control state: the pause / cycle-restart flags
belong to the owner's live cycle, and clearing them from a child would drop a
Continue the operator armed on the parent. Owner-only.

<a id="42010605-0012"></a>

### Ctrl+C handler

`yuruna/test/Debug-TestSequence.ps1`

Register a CancelKeyPress handler that flips $script:CancelState['Requested']
instead of letting Ctrl+C tear the runspace down mid-step. The finally{}
block below polls the flag and stops the VM so a half-baked guest
(interrupted during New-VM / Start-VM / a long sequence step) doesn't
linger consuming host CPU + memory. The disk is intentionally kept so
the operator can inspect post-mortem via virsh / vmconnect / utmctl.

<a id="42010605-0013"></a>

### Single-instance guard

`yuruna/test/Debug-TestSequence.ps1`

Refuse to start when a Start-TestRunner already owns the runtime dir.
Debug-TestSequence is a dev entry point: it does not coordinate the runner
state machine, so a concurrent run would race the runner's pidfile,
status.json registrations, and VM operations. Get-RunnerInstanceState
(Test.SingleInstance) does the read; Assert-NoOtherRunner wraps it
with the "refuse + banner" semantics this entry point needs --
Start-TestRunner's takeover path is the opposite (Stop-StaleRunner).
Nested runs skip the guard: they don't own the runtime dir (the outer cycle
owner does), and the owner already passed this same check. Enforcing it here
would make every nested stage refuse to start the moment the owner registered.

<a id="42010605-0014"></a>

### Tolerate operator typing the .yml/.yaml extension on the name form (e.g. via shell tab-completion ag

`yuruna/test/Debug-TestSequence.ps1`

Tolerate operator typing the .yml/.yaml extension on the name form
(e.g. via shell tab-completion against a sibling project working tree
whose path the Resolve-Path branch couldn't resolve from this cwd).
Resolve-SequencePath unconditionally appends .yml, so a trailing
extension here would search for `Name.yml.yml` and miss. Same strip
Test.SequencePlanner already does when reading baseline entries from
YAML, kept symmetric so CLI callers and YAML callers behave the same.

<a id="42010605-0015"></a>

### Resolve sequence file

`yuruna/test/Debug-TestSequence.ps1`

Sequences live flat under test/sequences/ in the framework and
project/<...>/test/ in the per-cycle clone; an ssh variant is its own
<name>.ssh sequence. Resolve-SequencePath checks the project tree first,
then the framework, host-specific variant before the plain file. If
nothing matches, list everything available across both trees.

Convenience: when $SequenceName is a path to an existing .yml file (shell
tab-completion produces this naturally), use it verbatim and reduce the
name to its basename for downstream planning. GuestKey comes from the
sequence's baseline map unless explicitly supplied. The operator
pointed at a specific file -- honor it, don't second-guess into a
host-variant from the tier search.

<a id="42010605-0016"></a>

### Pre-cycle config gate

`yuruna/test/Debug-TestSequence.ps1`

Mirror Start-TestRunner: refuse to bring up a VM when test.config.yml /
vault.yml / users.yml / transports.yml are in a state Test-Config.ps1
would reject. Without this gate a sequence can "pass" under Debug-TestSequence
(extension quirks-mode covers misconfig) while the runner refuses to even
start the cycle on the same config -- exactly the kind of confusing
surprise this gate guards against. Bypass with -NoConfigGate for
ad-hoc / in-progress edits.
Spawn a fresh pwsh so an Out-Of-Order ::Stop early-exit inside Test-Config
cannot unwind this script. -SkipSend stops the smoke-test email from
flooding subscribers["config.smoke"] on every Debug-TestSequence invocation.
Test.ConfigPreflight was imported by Initialize-YurunaEntryPointModuleSet above.

A NESTED run inherits its owner's verdict instead of re-gating. The owner
cleared this same host and config when it opened the cycle; a nested run is
one stage of that cycle, so re-validating per stage buys nothing and costs
something real. The gate reaches github.com, and remote state is not a
property of the config it is checking: a credential that expires between two
stages turns a preflight into a mid-flight abort, killing a cycle over
something none of its remaining work depends on and discarding every stage
already built. A preflight belongs at the front of the flight. A standalone
run (no inherited cycle context) is unaffected and still gates for itself.

<a id="42010605-0017"></a>

### Pre-flight: elevation

`yuruna/test/Debug-TestSequence.ps1`

Ahead of the project checkout replacement below. Assert-HostConditionSet makes
the same check much later, and with -NoConfigGate nothing catches it before
<RepoRoot>/project has already been refreshed. Self-gating: Assert-Elevation
short-circuits to true whenever Test-ElevationRequired is false, and only
host.windows.hyper-v registers RequiresElevation -- so this is a no-op on
macOS and Linux and cannot introduce a UAC or sudo demand.

<a id="42010605-0018"></a>

### Nested-cycle detection

`yuruna/test/Debug-TestSequence.ps1`

When this Debug-TestSequence was started inside another run's process tree -- a
host-action step re-entering us in a child pwsh (e.g. Set-Resource.ps1 fanning
out per-stage guest builds) -- it inherits the owner's cycle-context handle
($env:YURUNA_CYCLE_CONTEXT). Its presence means THIS run is NESTED: it attaches
a node to the owner's ONE status.json cycle instead of owning its own. A nested
run must NOT reset status.json, restart the status service, take the single-
instance lock, sweep the owner's control flags, allocate a top-level cycle
number, or finalize the cycle -- all owner-only. Absence of the handle ==
standalone owner, the unchanged classic behavior. See Test.Status.psm1
"Nested-cycle support" for the ownership model.

<a id="42010605-0019"></a>

### Canonical module set for the Sequence entry-point

`yuruna/test/Debug-TestSequence.ps1`

Includes Test.LogLevel + Test.Config + Test.SequenceAction + Test.HostIO +
Test.HostContract + Test.Log + Test.SequenceEngine + Test.SequencePlanner +
Test.YurunaDir + Test.OcrEngine + Test.Tesseract +
Test.ConfigPreflight. Order matters: planner AFTER engine so the
engine's -Force re-import inside the planner doesn't evict the
just-imported engine.

<a id="42010605-001a"></a>

### Build the parameter set Invoke-TestProject must pass to the inner. -NoGitPull and -NoProjectClone ar

`yuruna/test/Invoke-TestProject.ps1`

Build the parameter set Invoke-TestProject must pass to the inner. -NoGitPull
and -NoProjectClone are *always* forced here -- Invoke-TestProject does a fresh
clone itself and tests the local tree as-is; a mid-test framework update
would conflate signals. logLevel is forwarded only if the operator passed
it on this script's command line (PSBoundParameters), so the inner falls
back to its config-file default otherwise.
-NoConfigGate is forced too: the gate above already cleared this same config
seconds ago, ahead of the fresh checkout replacement this entry point
performs. The inner gating again would re-probe every remote for a verdict
nothing has had a chance to invalidate.

<a id="42010605-001b"></a>

### Step 3: spawn one inner cycle

`yuruna/test/Invoke-TestProject.ps1`

Invoke-TestProject uses the shared typed-argument builder to invoke a fresh
inner process directly; the recurring runner launches it from a cycle worker:
  * call operator (not Start-Process) -- this one-shot entry point's inner
    inherits its environment, stdio, and signal context
  * -Command (not -File) -- pwsh -File coerces every argv to [string],
    which would break [switch] / [int] parameters
  * -NoProfile -- $PROFILE can't clobber YURUNA_* env vars
  * YURUNA_RUNNER_RELAUNCH=1 -- inner skips its own pidfile-takeover guard
    (it can't safely take over us; we're the legitimate parent)
  * -NoProjectClone -- step 1+2 already produced a fresh tree; the
    inner trusts it and skips Update-ProjectClone
  * -NoGitPull -- Invoke-TestProject is a project test, not a framework test;
    a mid-test framework update would conflate signals

<a id="42010605-001c"></a>

<a id="step-12-wipe--re-clone-project"></a>

### Step 1+2: clone, verify, and swap the project checkout

`yuruna/test/Invoke-TestProject.ps1`

Update-ProjectClone is the same helper Invoke-TestRunnerInnerLoop uses every
cycle -- by calling it here, a regression in checkout replacement, git clone
itself, or the safety check (refuse to delete outside RepoRoot) surfaces
in Invoke-TestProject before it ever bites Start-TestRunner. The function
clones beside the current checkout, verifies the clone, then swaps it in; a
failed clone leaves the previous checkout in place. Splitting those operations
in Invoke-TestProject would duplicate the safety check without adding value.
Test.HostContract was imported by Initialize-YurunaEntryPointModuleSet above.

<a id="42010605-001d"></a>

### Sweep the parked interactive control state before handing off to the inner. -Scope PreSpawn archives

`yuruna/test/Invoke-TestProject.ps1`

Sweep the parked interactive control state before handing off to the
inner. -Scope PreSpawn archives a leftover break-active.json and clears
leftover pause flags (control.step-pause / .cycle-pause) so the spawned
inner doesn't inherit the parked break state -- the status UI would
otherwise keep the previous run's Continue button live. Invoke-TestProject
spawns Invoke-TestRunnerInnerLoop directly (bypassing the outer
Start-TestRunner that normally hosts Invoke-YurunaBootRecovery), so
this sweep has to happen here. PreSpawn deliberately leaves
control.cycle-restart for the child inner to consume as ITS own restart.

<a id="42010605-001e"></a>

### Refuse to start when a Start-TestRunner already owns the runtime dir. Invoke-TestProject spawns its

`yuruna/test/Invoke-TestProject.ps1`

Refuse to start when a Start-TestRunner already owns the runtime dir.
Invoke-TestProject spawns its own inner with YURUNA_RUNNER_RELAUNCH=1 below,
which tells inner to skip its own pidfile-takeover guard -- safe only
when Invoke-TestProject itself is the legitimate parent. If a real
Start-TestRunner is already running, that contract would let our inner race
the live cycle's runner.pid + status.json updates. Assert-NoOtherRunner
(Test.Prelude, backed by Test.SingleInstance) reads runner.pid +
runner.start and refuses; Start-TestRunner's takeover path is the
opposite (Stop-StaleRunner) and stays in the outer.

<a id="42010605-001f"></a>

### Pre-flight: elevation

`yuruna/test/Invoke-TestProject.ps1`

Ahead of the checkout replacement. Without this, an operator who forgot the
elevated shell has <RepoRoot>/project refreshed, and only then hits
the check inside the spawned inner cycle. Self-gating: Assert-Elevation returns
true whenever Test-ElevationRequired is false, and only host.windows.hyper-v
registers RequiresElevation -- so this is a no-op on macOS and Linux and cannot
introduce a UAC or sudo demand on a path that never needed one.

<a id="42010605-0020"></a>

<a id="exit-code-contract-0--success-1--anything-else-a-binary-code-is-what-passfail-consumers-want"></a>

### Exit-code contract: setup failure is 1; completed cycles forward the inner exit code

`yuruna/test/Invoke-TestProject.ps1`

Preflight, clone and inner-spawn failures exit with 1; a completed inner
cycle forwards its exact exit code, with 0 meaning success. A CI consumer
that needs to discriminate between "preflight" / "clone failed" / "inner
spawn failed" reads the Stop-WithReason banner ("STOP (exit 1) at <Step>").
The $Step + $Reason in the banner carry the "why".

<a id="42010605-0021"></a>

<a id="one-shot-project-test-wipe-reporootproject-re-clone-from-repositories"></a>

### One-shot project test: prepare the project clone and invoke the inner runner

`yuruna/test/Invoke-TestProject.ps1`

Each step is gated and reports its own reason on failure:

  Step 1+2 verify a fresh clone and replace <RepoRoot>/project via the same
            Test.HostContract\Update-ProjectClone helper Invoke-TestRunnerInnerLoop
            calls every cycle. A failure here stops with a clear
            "what + why" line; the inner is never spawned.

  Step 3   spawns Invoke-TestRunnerInnerLoop.ps1 in a fresh pwsh using
            Test.InnerSpawn's shared typed-argument builder,
            with -NoProjectClone (the clone is already fresh) and
            -NoGitPull (Invoke-TestProject tests the project as it stands
            locally; a mid-test framework update would muddle the
            signal). The inner does the full cycle, records it as a
            regular cycle in status.json, and exits.

  Step 4   surface the inner's exit code as our own and stop. Not
            resumed; the operator (or CI) re-invokes Invoke-TestProject
            explicitly if they want another pass.

By calling Update-ProjectClone + Invoke-TestRunnerInnerLoop directly,
Invoke-TestProject exercises the same code paths Start-TestRunner does --
a regression in either surfaces here first.

<a id="42010605-0022"></a>

### Register in the runtime users.yml

`yuruna/test/New-LocalTestUser.ps1`

YAML literal preserves the exact formatting used by the committed
users.yml.template entries (2-space indent under `users:`, inline-
flow `corporate: { domain: "", sam: "", upn: "" }`, padded keys for
vaultKey / localOsPasswordRef). Appending text rather than round-
tripping through ConvertTo-Yaml keeps the file's existing comments
and entry formatting intact.

<a id="42010605-0023"></a>

### -WindowStyle, not -NoNewWindow: -Credential belongs to a parameter set that has no -NoNewWindow. -Wo

`yuruna/test/New-LocalTestUser.ps1`

-WindowStyle, not -NoNewWindow: -Credential belongs to a parameter
set that has no -NoNewWindow.
-WorkingDirectory: without it the child inherits the caller's
directory, and an elevated operator's directory is regularly one
the new account cannot read -- which fails the launch itself,
before any of the command runs.

<a id="42010605-0024"></a>

### Let the new Windows account run scripts

`yuruna/test/New-LocalTestUser.ps1`

A fresh Windows account starts at the shell default -- Restricted on
client SKUs -- so the first .ps1 the operator runs interactively as this
account is refused. The CurrentUser policy lives inside the account's own
profile (PowerShell 7 keeps it in
Documents\PowerShell\powershell.config.json, Windows PowerShell 5.1 in
HKCU), and neither store exists until the account has signed in once:
setting it from this elevated session would only change the policy of the
operator running the script. So it is set from a session that really runs
as the new account -- a one-shot logon here when the account has a usable
password, and a first-sign-in scheduled task when it does not.

This policy applies to the account's own interactive script sessions.
A child launched with -ExecutionPolicy Bypass uses that explicit override;
framework entry points do not all supply it.

<a id="42010605-0025"></a>

### Get-LocalGroupMember fails to enumerate a group that still holds a SID no longer resolvable to a pri

`yuruna/test/New-LocalTestUser.ps1`

Get-LocalGroupMember fails to enumerate a group that still holds a
SID no longer resolvable to a principal (a deleted domain account,
a removed local user). Add-LocalGroupMember above already throws on
a real failure, so an unreadable group is a verification gap, not a
failed grant -- say so instead of aborting a successful run.
$null means "could not enumerate", which is distinct from $false
("enumerated, and the account is not there") -- only the latter is
an actual failed grant.

<a id="42010605-0026"></a>

### Recreating is the whole point of running this against a name that already exists, so the run offers

`yuruna/test/New-LocalTestUser.ps1`

Recreating is the whole point of running this against a name that
already exists, so the run offers it rather than refusing and telling
the operator which switch to add. What it cannot do is decide on their
behalf: the account may be a stale test account or one in use, and only
the operator can tell which. -Force is that answer given in advance,
which is what makes an unattended recreate possible.

<a id="42010605-0027"></a>

### A path at or beside the filesystem root is a damaged account record rather than a home directory --

`yuruna/test/New-LocalTestUser.ps1`

A path at or beside the filesystem root is a damaged account record
rather than a home directory -- '/', '/home' and C:\Users hold every
other account's files, and a recursive delete of one of those is not
recoverable. DirectoryInfo rather than Split-Path: Split-Path errors
on a root path instead of returning nothing, and the error abandons
the statement that was supposed to be the guard. Anything the check
cannot resolve is refused for the same reason.

<a id="42010605-0028"></a>

### An account with a password is the point of the tool, so a run that names no password asks for one ra

`yuruna/test/New-LocalTestUser.ps1`

An account with a password is the point of the tool, so a run that names
no password asks for one rather than producing a locked account nobody can
log into. -NoPassword is the explicit opt-out.

The prompt itself is deliberately NOT here. On Windows an unelevated run
relaunches itself through UAC and the password is never forwarded on the
command line, so asking now would ask again in the elevated window. It is
asked once, after the elevation gate and after the preflight checks -- no
point collecting a secret for an account that already exists.

<a id="42010605-0029"></a>

### Re-create the default test account without stopping to ask: an existing `yurunatest` OS account and

`yuruna/test/New-LocalTestUser.ps1`

Re-create the default test account without stopping to ask: an
existing `yurunatest` OS account and its home directory are deleted
first, while the Yuruna users.yml entry and any vault password it
points at are reused. The same run without -Force does the same
thing, after confirming the deletion with the operator. Add -WhatIf
the first time to see exactly what would be removed.

<a id="42010605-002a"></a>

### One entry per host -- the CurrentUser policy is stored per host, so setting one leaves the other at

`yuruna/test/New-LocalTestUser.ps1`

One entry per host -- the CurrentUser policy is stored per host, so
setting one leaves the other at its default -- and whether the new
account can execute it at all.

A PowerShell installed for a single user lives under that user's
profile: a per-user MSI under AppData\Local\Programs, or a Store
execution alias under AppData\Local\Microsoft\WindowsApps. No other
account can run it. Handing such a path to a logon as the new
account fails with "Access is denied" before the command starts,
and a scheduled task pointed at the same path fails the same way at
that account's own sign-in -- so a path under a profile is reported
to the operator, never used.

<a id="42010605-002b"></a>

### Second pass over the home directory, because every platform's account delete has a way of leaving it

`yuruna/test/New-LocalTestUser.ps1`

Second pass over the home directory, because every platform's
account delete has a way of leaving it behind: a Windows profile
whose ProfileList entry is unreadable, `userdel` reporting exit 12,
a macOS home with files still open in it. What survives is not
cosmetic -- the recreated account cannot read files owned by an id
that no longer resolves, and on Windows it is handed a second,
`.000`-suffixed profile directory beside the old one.

The path comes from the OS itself (Win32_UserProfile.LocalPath,
the passwd record, dscl), never from the account name, so this
removes the directory the account really had.

<a id="42010605-002c"></a>

### Create a local OS account on the host, optionally with a password and local-machine-administrator ri

`yuruna/test/New-LocalTestUser.ps1`

Creates a local OS user with the supplied display name and account
name. The account name defaults to `yurunatest`, so the common case is
a single switch: `.\New-LocalTestUser.ps1 -Admin`.

The password is set at creation and is immediately usable, so an
unattended test host can log in without an interactive first-login
rotation standing in the way. Three shapes:

  * Default: the password is asked for interactively (twice,
    confirmed), on the elevated side, so it never reaches shell
    history or a process argument vector.

  * With -Password: the supplied password is used instead of asking.

  * With -NoPassword: the account is created WITHOUT a usable
    password. It exists but cannot log in until the operator sets one
    out-of-band.

When the authentication vault already holds a local-OS password for
this account name, that password is reused instead of asking, so a
re-created account still matches the credential Yuruna hands out for
it. -Password overrides the stored one; -PromptForPassword asks
anyway, and warns that the stored copy stops matching.

-ForcePasswordChange makes the password a one-shot initial credential
and demands a change at the first interactive login. It is opt-in --
without it the account logs in unattended.

-Admin additionally makes the account a local machine administrator:
the built-in Administrators group on Windows (resolved by SID, so it
works on non-English installs), the `admin` group on macOS, and the
`sudo` group on Ubuntu.

On Windows the account is also left able to run scripts: its CurrentUser
execution policy is set to RemoteSigned. That policy lives in the
account's own profile, so it is set from a session that runs as the new
account -- a one-shot logon here when the password is usable, and a
first-sign-in scheduled task when -NoPassword or -ForcePasswordChange
rules a logon out.

The same logical account name is registered in the runtime
authentication mapping, status/extension/authentication/users.yml,
with empty corporate / vault fields so the entry behaves as a
purely-local Yuruna user (cf.
test/extension/authentication/users.yml.template). A host whose
runtime file does not exist yet gets one seeded from the committed
template first; the template itself is never written to, so
registering a machine-local account never dirties a tracked file.

A name already declared in users.yml is reused, not refused: the
entry stays exactly as it is, along with whatever vault credential
it points at, and the run continues. An OS account that already
exists is not a stop either: the run reports what deleting it takes
with it and asks to confirm, then deletes the account -- home
directory and everything under it -- and creates it again from
scratch. -Force answers that confirmation in advance, which is what
lets an unattended run recreate the account in one call. Three cases
are refused outright, -Force included: a system account, the account
running the script, and an account with an open login session.

Elevation is requested before anything is changed. On Windows an
unelevated run asks for consent and then relaunches itself through
UAC; the elevated window prompts for the password rather than
receiving it on the command line, so the secret never appears in
the process list. On macOS / Ubuntu the script pre-authenticates
sudo up front, so there is a single clearly-labeled prompt.

<a id="42010605-002d"></a>

### Always run the orphan-file sweep -- even if some VMs survived the registry-removal step. Their on-di

`yuruna/test/Remove-TestVMFiles.ps1`

Always run the orphan-file sweep -- even if some VMs survived the
registry-removal step. Their on-disk files are still claimed by the
surviving registration so the orphan script will skip them, but
files left over from earlier failures (the actual symptom on
long-running hosts) get reclaimed. The "Running orphaned VM file
cleanup: <path>" line stays Write-Output (unconditional) so an
automated caller running with -Quiet still sees a single line that
proves the orphan sweep was attempted; -Quiet propagates down so
Remove-OrphanedVMFiles itself emits no chatter.

<a id="42010605-002e"></a>

### Release the per-cycle display surface this host attaches for screen-capture (the Hyper-V usbmmidd vi

`yuruna/test/Remove-TestVMFiles.ps1`

Release the per-cycle display surface this host attaches for screen-capture
(the Hyper-V usbmmidd virtual display). The cycle-start path attaches it via
Initialize-HostDisplay; tearing it down here cleans up a stale/duplicate
monitor left by a mid-cycle KVM switch so it doesn't linger once the machine
stops running tests. Dispatcher no-ops on hosts that attach nothing
(macOS/Linux) and never throws.

<a id="42010605-002f"></a>

### Track every VM we attempted, with a final disposition. Per-VM ops MUST NOT abort the whole loop: on

`yuruna/test/Remove-TestVMFiles.ps1`

Track every VM we attempted, with a final disposition. Per-VM ops MUST
NOT abort the whole loop: on a long-running host, a single stuck VM
(locked .vhdx, wedged vmms, UTM helper holding a file handle) would
otherwise throw under $ErrorActionPreference='Stop' and skip every later
matching VM, so survivors accumulate cycle after cycle. Each VM is wrapped
in try/catch with its own continue-on-failure path; survivors are reported
at the end and the orphan-file cleanup still runs so we reclaim disk
even when one VM resists deletion.

<a id="42010605-0030"></a>

### Resolve $Prefix: explicit -Prefix wins, then test.config.yml's vmStart.cleanupVmNamePrefixes, then v

`yuruna/test/Remove-TestVMFiles.ps1`

Resolve $Prefix: explicit -Prefix wins, then test.config.yml's
vmStart.cleanupVmNamePrefixes, then vmStart.testVmNamePrefix, then the
"test-" fallback. Reading the config matters when the operator runs this
script directly after a stopped runner -- the runner passes -Prefix from
the same config, so a manual invocation that fell back to "test-" would
miss VMs whenever the operator had customized the prefixes.

<a id="42010605-0031"></a>

### Eternal loop

`yuruna/test/Start-TestRunner.ps1`

Cycle body lives in Test.RunnerOuterLoop.psm1 so it can be unit-tested
without spawning a real inner pwsh. The State hashtable threads
everything the loop needs (paths, tunables, ShutdownState reference,
the call-op argv) so the function reads no caller-scope variables
implicitly. ShutdownState is reference-shared with the Ctrl+C handler
above; flipping ['Requested'] there ends the loop here.

<a id="42010605-0032"></a>

### Pre-flight: elevation

`yuruna/test/Start-TestRunner.ps1`

Resolve elevation ONCE, here, while an operator is still at the console --
the only moment a password can be answered. Every cycle after this runs in a
fresh pwsh with a cold sudo timestamp, and the inner inherits this terminal,
so a prompt raised mid-cycle would park the host with the dashboard still
green. Assert-RunnerElevation returns $false only after printing the exact
/etc/sudoers.d commands to run; refusing to start is the correct outcome
because a host that needs a password typed needs hands on it, exactly like a
host with a broken network. No-op on Windows/macOS and when already covered
by a drop-in, in which case nothing prints and nothing prompts.
Get-Command-guarded so a runner whose framework clone predates the module
degrades to the previous behavior rather than failing to launch.

<a id="42010605-0033"></a>

### Helpers

`yuruna/test/Start-TestRunner.ps1`

git / config / watchdog / Sync-ForwardEnv / Write-OuterLog helpers all
live in sibling modules so the entry point stays thin and the
heartbeat-watchdog + cycle dispatcher are unit-testable independent of
this file. See modules/Test.RunnerWatchdog.psm1,
modules/Test.RunnerOuterLoop.psm1 and modules/Test.OuterLog.psm1; all three
were loaded with -Global -Force by Initialize-YurunaEntryPointModuleSet
-For Outer above.

<a id="42010605-0034"></a>

### Every switch here forwards, -NoConfigGate included: the inner gates each cycle it runs, so an operat

`yuruna/test/Start-TestRunner.ps1`

Every switch here forwards, -NoConfigGate included: the inner gates each
cycle it runs, so an operator who bypassed the startup gate for an
in-progress edit would otherwise be stopped by that same check one layer
down, on the very run they asked to bypass it for.
The refresh transport parameters are this script's own and never reach the
inner, whose strict binding would refuse them.

<a id="42010605-0035"></a>

### Ctrl+C handler

`yuruna/test/Start-TestRunner.ps1`

Shared registration lives in Test.Prelude (Register-EntryPointCancelHandler): a
Register-ObjectEvent CancelKeyPress subscription that flips the returned hashtable's
'Requested' flag on the pipeline thread (a raw .NET delegate would fire on a
Runspace-less thread-pool thread). During a spawned cycle, the outer runner polls
$script:ShutdownState['Requested'] between one-second child-process waits and
stops the whole cycle process tree when cancellation is requested. The eternal
loop and the failure-pause loop also poll the flag before continuing.

<a id="42010605-0036"></a>

### Sync-ForwardEnv lives in [Test.RunnerOuterLoop](../test/modules/Test.RunnerOuterLoop.psm1) and Write-OuterLo

`yuruna/test/Start-TestRunner.ps1`

Sync-ForwardEnv lives in [Test.RunnerOuterLoop](../test/modules/Test.RunnerOuterLoop.psm1)
and Write-OuterLog in [Test.OuterLog](../test/modules/Test.OuterLog.psm1), which the
outer loop re-exports, so the loop body and the entry-point script see the
same implementations. Sync-ForwardEnv takes the snapshot as a parameter (no
script-scope read); Write-OuterLog reads YURUNA_RUNTIME_DIR from env at call
time (resolved by Initialize-YurunaRuntimeDir above).

<a id="42010605-0037"></a>

### Host-refresh gate at startup

`yuruna/test/Start-TestRunner.ps1`

A normal start refuses while a host refresh holds this host's runner: it
would race the repair, and the repair restarts the runner itself when it
finishes. A resumed start (launched by the refresh worker) must present a
handoff token that validates for this runtime; a refused token writes a
failed acknowledgment the worker is waiting for, when the gate still holds
that token.

<a id="42010605-0038"></a>

### Auto-relaunch under `sg libvirt -c "..."` on host.ubuntu.kvm when this shell's running supplementary

`yuruna/test/Start-TestRunner.ps1`

Auto-relaunch under `sg libvirt -c "..."` on host.ubuntu.kvm when this
shell's running supplementary group set lacks libvirt. Done BEFORE we
spawn any inner pwsh -- the inner inherits the outer's group set, so
fixing it here means every cycle's virt-install / virsh call inside
the inner runner reaches /var/run/libvirt/libvirt-sock cleanly. No-op
on macOS/Windows and on shells that already have libvirt in the
effective set. See Invoke-LibvirtGroupReExecIfNeeded for the full
rationale (sg + initgroups, why $env: would leak, etc.).

<a id="42010605-0039"></a>

### Publish the resolved config path so every cross-module reload site (Sync-RuntimeConfig in the inner

`yuruna/test/Start-TestRunner.ps1`

Publish the resolved config path so every cross-module reload site
(Sync-RuntimeConfig in the inner runner, Update-TransportDefault in
Test.Transport, future similar callers) reads the SAME file when the
operator passes -ConfigPath <elsewhere>. Without this, Test.Transport
falls back to the in-tree template and the operator's dashboard edits
to vmCommunication.* never take effect.

<a id="42010605-003a"></a>

### Resilient outer runner

`yuruna/test/Start-TestRunner.ps1`

The normal path uses a resident outer (this file), a fresh per-cycle worker
(modules/Invoke-TestCycleRunner.ps1), and the inner runner
(modules/Invoke-TestRunnerInnerLoop.ps1). The worker runs the cycle orchestration
and invokes the inner; the outer retains cross-cycle state. If the cycle-worker
script is absent, the outer falls back to running the cycle orchestration in-process.
Why the split:
  * fresh pwsh per cycle on every host -- cycle logic and its modules reload
    without restarting the resident outer
  * O(1) resident memory; outer is the only process retained across cycles and
    waits for the cycle worker in one-second slices
  * backoff with commit polling stops infinite-failure burn

See test/README.md for cycle flow, config, notifications, and the
YURUNA_CACHING_PROXY_SERVICE_IP knob; docs/test-harness.md for harness architecture.

<a id="42010605-003b"></a>

### Optional: promote to machine-wide host proxy

`yuruna/test/Test-CachingProxyService.ps1`

Only runs when every FAIL-level check passed -- WARN-level (missing :80 /
missing CA cert) is compatible with a working HTTP proxy, so we don't
block promotion on it.

Auto-wipe before promotion: Remove-HostProxy unconditionally clears any
leftover WinINet ProxyServer string and HTTP_PROXY/HTTPS_PROXY/NO_PROXY
env vars BEFORE Set-HostProxy writes the new ones. The snapshot-and-restore
alternative preserves whatever proxy state was on the host when the FIRST
Set-HostProxy ran -- which on a host that had a pre-existing (or older-cycle)
HTTP_PROXY env var means Stop-CachingProxyServiceVM faithfully restores it,
leaking a stale IP into every subsequent Test-CachingProxyService probe.
Wiping first means each promotion lands on a guaranteed-clean baseline;
Stop-CachingProxyServiceVM similarly wipes definitively rather than restoring.
No user-action -ClearHostProxy required.

<a id="42010605-003c"></a>

### Effective proxy for outbound calls

`yuruna/test/Test-CachingProxyService.ps1`

Read process env vars DIRECTLY rather than asking
[System.Net.WebRequest]::DefaultWebProxy.GetProxy(). DefaultWebProxy
is a per-AppDomain singleton -- HttpEnvironmentProxy gets constructed
from env vars on the FIRST .NET HTTP call and is then cached for the
life of the process, with no refresh path. So once Test-CachingProxyService.ps1
(or any earlier script in the same pwsh) has touched .NET HTTP, the
singleton is stuck at whatever HTTP_PROXY said at that moment, even
after Set-WindowsHostProxy updates $env:HTTP_PROXY in the same session.
That is why two consecutive -SetHostProxy runs in one pwsh kept warning
despite the underlying state being correct.

Reading env vars directly reflects what NEW child processes will
inherit (Start-TestRunner spawns fresh pwsh per cycle on Windows;
child gets the parent's process env block at fork time, builds its
own DefaultWebProxy from THOSE values). $env: hits the live process
env block on every read.

<a id="42010605-003d"></a>

### Host system-proxy check

`yuruna/test/Test-CachingProxyService.ps1`

A stale system proxy (e.g. a previous -SetHostProxy promotion
against an IP that has since moved) will silently redirect every
Invoke-WebRequest / curl in Start-TestRunner. .NET on macOS reads
networksetup; .NET on Windows reads WinINet per-user (what the
driver's Set-WindowsHostProxy writes) and WinHTTP machine-wide. Env vars are
only consulted as a fallback, which is why a stale system setting
doesn't show up by dumping env vars alone.

<a id="42010605-003e"></a>

### Port probes + CA cert fetch

`yuruna/test/Test-CachingProxyService.ps1`

Shared with the cycle-start gate in Invoke-TestRunnerInnerLoop.ps1 via
Invoke-CachingProxyServiceProbe in Test.CachingProxyService.psm1 -- both callers see
the same PASS/WARN/FAIL classification:
  :3128 / :3129 / :3000 -- FAIL on unreachable (hard requirements)
  :80, CA cert          -- WARN (HTTPS caching disabled on guests but
                           HTTP still works)
Lines and counters are folded back into this script's $script:* state
so the Summary line and exit code match the cycle-start gate's
PASS/WARN/FAIL classification (single source of truth in
Invoke-CachingProxyServiceProbe).

<a id="42010605-003f"></a>

### -SetHostProxy ends this script with Remove-HostProxy then Set-HostProxy, both of which reach Invoke-

`yuruna/test/Test-CachingProxyService.ps1`

-SetHostProxy ends this script with Remove-HostProxy then Set-HostProxy, both
of which reach Invoke-MacElevationIfNeeded and prompt for a password -- after
the port probes and CA fetch have already burned a minute or more. The
requirement is knowable from the parameter binding alone, so surface it here.
Idempotent and silent when already root (sudo -E), when the sudo timestamp is
warm, or on Windows, where Set-HostProxy writes per-user WinINet and needs no
elevation. A run without -SetHostProxy is a read-only probe and never prompts.

<a id="42010605-0040"></a>

### Resolve the cache IP

`yuruna/test/Test-CachingProxyService.ps1`

Priority mirrors Start-TestRunner's cycle-start resolution:
  -CacheIp parameter            (explicit override, this script only)
  vmStart.cachingProxyIp        (test/test.config.yml, probed first)
  $Env:YURUNA_CACHING_PROXY_SERVICE_IP  (probed when config absent/unreachable)
  local discovery via Test-CachingProxyServiceAvailable
The config/env legs run through Resolve-CachingProxyServiceEndpoint -- the SAME
resolver Invoke-TestRunnerInnerLoop.ps1 and Debug-TestSequence.ps1 use -- so the
acceptance policy (first source whose HTTP proxy port answers) cannot
drift from the runner's. Two differences, both deliberate: this
diagnostic never publishes the winner into $env:YURUNA_CACHING_PROXY_SERVICE_IP
(read-only probe, no session mutation), and a rejected source is
surfaced as a WARN before falling back to local discovery exactly as
the runner would.

<a id="42010605-0041"></a>

<a id="canonical-path-bundle--cachingproxyservice-module-kind-loads-the-trio-testvmutility-testcachin"></a>

### Canonical path bundle and caching-proxy-service module imports

`yuruna/test/Test-CachingProxyService.ps1`

Canonical path bundle + CachingProxyService module kind. Loads the trio
(Test.VMUtility, Test.CachingProxyService, Test.HostContract) shared by the four
caching-proxy-service scripts:
  * Test.VMUtility -- Get-CachingProxyServicePort / Test-IpAddress, used by the
    port-probe block below and the env-var / -CacheIp branches that
    bypass Test-CachingProxyServiceAvailable's transitive imports.
  * Test.CachingProxyService -- Invoke-CachingProxyServiceProbe (shared with the cycle-
    start gate in Invoke-TestRunnerInnerLoop.ps1).
  * Test.HostContract -- Invoke-LibvirtGroupReExecIfNeeded + Initialize-YurunaHost.

<a id="42010605-0042"></a>

### Summary

`yuruna/test/Test-Config.ps1`

Exit-WithSummary prints the PASS/WARN/FAIL tally AND the repeated
FAILURES block (every Write-Fail's message + full path, grouped by
section). Centralized so every early-exit site upstream (missing
config file, YAML parse error, network probe failure, abort-before-
network-checks) lands on the same final layout -- the operator never
has to scroll up to find what failed.

<a id="42010605-0043"></a>

### -Bootstrap, not the gate's default. The default is deliberately wider -- every file type that is ASC

`yuruna/test/Test-Config.ps1`

-Bootstrap, not the gate's default. The default is deliberately wider --
every file type that is ASCII by policy -- because a developer or a merge
check wants drift surfaced anywhere it lands. This call is different: it
decides whether a runner may START, so its scope stays the set where a
stray byte genuinely breaks first-install on a fresh host. Widening it
here would let one character in any stylesheet or YAML file stop every
runner in the pool, a blast radius the defect does not warrant.

<a id="42010605-0044"></a>

### Section 13: Bootstrap script encoding (ASCII, no BOM)

`yuruna/test/Test-Config.ps1`

The PS 5.1 `irm | iex` installer and the guest/windows.11 scripts the fresh
Windows guest runs the same way are parsed byte-for-byte before any
BOM-tolerant shell exists, so a UTF-8 BOM or non-ASCII byte aborts them at
line 1. Fold the shared Test-AsciiNoBom guard into this pre-cycle gate so an
accidental re-encode blocks the cycle here instead of breaking first-install
on the guest. See feedback_bootstrap_installer_no_bom.md.

<a id="42010605-0045"></a>

### Section 9d: Pool (configuration sync)

`yuruna/test/Test-Config.ps1`

Validate the optional pool-configuration PULL when configured: enabled implies a
non-empty configurationGitUrl, and the LAN configuration store answers a bounded git
ls-remote. Reachability is a WARN (the runner degrades to single-host when the
store is down), so a momentarily-offline proxy never blocks a healthy cycle.
The configuration-store CONTENT (pools.yml shape) is validated by Test-PoolConfiguration.ps1;
this gate only checks the LOCAL config block + reachability.

<a id="42010605-0046"></a>

### Probe from HERE too: the pool answering for an address only says the aggregator can reach it, and th

`yuruna/test/Test-Config.ps1`

Probe from HERE too: the pool answering for an address only
says the aggregator can reach it, and this host is the one
that has to. 'host' is the bare address the aggregator
already parsed out; an older one that does not send it
leaves the URL to parse here, and a value that will not
parse is skipped rather than thrown out of the section.

<a id="42010605-0047"></a>

### Section 9c2: Extension services registered with the pool

`yuruna/test/Test-Config.ps1`

The stash storage checks above prove this host could BUILD a stash service.
This one asks the opposite question, and the one a cycle actually depends on:
which stash service will this host be sent to, and does it answer?

A cycle resolves that address from the pool, so an unreachable registration
stops the cycle in its warm-up -- after the config check said everything was
fine. Two hosts advertising the same area is normal (each may run its own);
an advertised address that nothing answers is not, and it is invisible from
this host until the moment a cycle needs it.

Advisory throughout. This gate refuses to START the runner loop on a FAIL, so
a service on another machine being down would wedge a lab that could otherwise
keep cycling and recover; and whether a stash is needed at all is the
project's business, not the framework's. Visibility is the goal: the operator
reads this before a cycle spends its budget discovering the same thing.

<a id="42010605-0048"></a>

### ACTIVE write-path pre-flight: the stash share is configured as a SUBFOLDER ('\\server\share\yuruna.s

`yuruna/test/Test-Config.ps1`

ACTIVE write-path preflight: the stash share is configured as a SUBFOLDER
('\\server\share\yuruna.stash'); New-SmbMapping to a missing subfolder fails
with a vague "network name cannot be found", so ensure the target folder
exists (create it via the parent share when missing), then verify an actual
mount of it. Advisory throughout -- the stash is optional and Start-StashServiceVM
hard-fails at build time -- but this catches the "reachable NAS, credential
stored, yet the mount still fails because the folder was never created" class
the passive checks above cannot see. Only attempted when a credential is
stored AND the server answered, so a merely-offline NAS stays the WARN above.

<a id="42010605-0049"></a>

### Free space, checked ONLY behind a succeeded pre-flight. On Linux/macOS `df` against an existing-but-

`yuruna/test/Test-Config.ps1`

Free space, checked ONLY behind a succeeded preflight. On
Linux/macOS `df` against an existing-but-unmounted localPath
succeeds and reports the PARENT filesystem, so running this
on any path where the mount was skipped or failed would
measure the local disk and pass or fail the gate on the
wrong number entirely.

<a id="42010605-004a"></a>

### ACTIVE write-path pre-flight: actually mount localPath and create the per-host folder '<localPath>/<

`yuruna/test/Test-Config.ps1`

ACTIVE write-path preflight: actually mount localPath and create the
per-host folder '<localPath>/hosts/<hostId>'. This is the check that catches
the "reachable NAS, paths configured, but replication silently never
happens" class -- a wrong SMB password, a share-name typo, missing
Linux passwordless sudo, or a read-only share -- which the passive
reachability probe above cannot see (the host-side drain runs detached
and only records the failure in the ledger, where no operator sees it).
Only attempted when a credential is configured AND the server is
reachable, so a merely-offline NAS stays the transient WARN above.
FAIL (block the cycle) when moveLogsToPoolStorage is on; advisory WARN when off.

<a id="42010605-004b"></a>

### mount(8) execs the external mount.cifs helper from cifs-utils, which nothing else in the harness pul

`yuruna/test/Test-Config.ps1`

mount(8) execs the external mount.cifs helper from cifs-utils, which
nothing else in the harness pulls in. Establish it BEFORE the active
preflight: without the helper every mount fails with the same exit
code a credential rejection produces, so reporting the missing
package is both the accurate finding and the only actionable one.
The doomed mount attempt is then skipped rather than raising a second
finding for the same cause.

<a id="42010605-004c"></a>

### An absent or unpopulated pool tier is only "optional" to someone who never asked for shared storage

`yuruna/test/Test-Config.ps1`

An absent or unpopulated pool tier is only "optional" to someone who never
asked for shared storage. -ExpectStorageConfigured is the caller saying it
just tried to stand storage up, and then the same absence is the proof that
nothing landed -- the local-shares script writes these three keys as it
builds the shares, and a NAS mount refuses to start without them, so a run
that gets here without them has no storage at all while every step after it
behaves as though it has.

<a id="42010605-004d"></a>

### Section 9c: networkStorage pool (ypool-nas) archiving

`yuruna/test/Test-Config.ps1`

Validate the optional NAS archiving tier: all three paths set, a usable vault
credential (so the mount won't silently auto-generate a junk SMB password), that
the SMB server answers on :445, and -- when both of those pass -- an ACTIVE mount
of localPath plus creation of the per-host folder '<localPath>/hosts/<hostId>',
then the free space that folder's next cycle will need. The active step is what
proves archiving will actually work (credentials, share name, Linux sudo, write
permission) instead of silently failing later; in MOVE mode a failure FAILs the
gate (stopping the cycle) because the local copy is about to be deleted, while in
copy mode it is advisory. The reachability probe stays a WARN either way, so a
merely-offline NAS -- which the loop retries each cycle -- never blocks a healthy
run.

The space check runs ONLY behind a succeeded mount: on Linux/macOS `df` against an
existing-but-unmounted localPath succeeds and reports the PARENT filesystem, so
checking it on any other path would judge the share by the local disk's free space.

<a id="42010605-004e"></a>

### Show-NetworkStorageFieldSwapWarning

`yuruna/test/Test-Config.ps1`

A bare drive-letter (e.g. 'z:') is a localPath value, never a valid SMB
username -- finding one in <prefix>NetworkUser means <prefix>NetworkUser and
<prefix>LocalPath were transposed in test.config.yml. A value swap keeps the
schema valid (both are strings), so nothing else flags it; the only visible
symptom is a misleading "no stored vault credential" warning keyed on the
drive letter, while the real account's password sits unused in the vault.

<a id="42010605-004f"></a>

### Invoke-PoolStorageVaultCredentialOffer

`yuruna/test/Test-Config.ps1`

Interactive only: collect the missing pool NAS password and store it in the
vault, so an operator who has the secret in hand ends the run with a working
credential instead of a gate failure that points at a doc plus a second
command. The password is the one value the harness must never invent -- the SMB
account already exists on the NAS, so an auto-generated one is always junk it
rejects (cifs mount error(13)). Returns $true ONLY when a credential was
stored; the caller then re-runs the read-only pre-check rather than trusting
the write. Where nobody can be asked -- the pre-cycle config gate, the
unattended runner -- it returns $false at once and keeps the printed
instructions, which name the manual equivalent.

<a id="42010605-0050"></a>

### Invoke-LinuxSudoInstallOffer

`yuruna/test/Test-Config.ps1`

Linux + interactive only: offer to install the passwordless-sudo drop-in the
mount needs, right now, prompting once for sudo. Returns $true ONLY when the
drop-in was actually installed (so the caller retries the mount); a decline, a
session where nobody can be asked, or any non-install outcome returns $false
and the caller falls through to Show-LinuxSudoHintOnce. The unattended runner
never reaches the offer and must not self-elevate.

<a id="42010605-0051"></a>

### Linux-only: print the EXACT one-time passwordless-sudo setup the mount path needs (resolved to this

`yuruna/test/Test-Config.ps1`

Linux-only: print the EXACT one-time passwordless-sudo setup the mount path
needs (resolved to this account + binary paths) the first time a mount-stage
preflight fails. Once per run -- the pool and stash shares share one drop-in.
The unattended RUNNER cannot self-apply it (`sudo -n` never prompts and
/etc/sudoers.d needs root), so this hint is its fallback; an INTERACTIVE
operator is offered the install directly by Invoke-LinuxSudoInstallOffer.

<a id="42010605-0052"></a>

### Section 9b3: Stale SMB alias mappings (Windows)

`yuruna/test/Test-Config.ps1`

A persistent Windows drive mapping can outlive the hosts-file alias it points
at: after a NAS alias is renamed/removed, the mapping still shows Status OK from
its cached connection, yet the dead-name session it holds BLOCKS a fresh mount
of the same physical NAS under a current alias (the redirector refuses a second
credentialed session to a server it is already stale-connected to). Mapping two
aliases of ONE NAS to the SAME IP is intentional and fine -- an UNRESOLVABLE
alias is the actual blocker. List them and, only with an operator at the
keyboard, offer to unmount each so the pool/stash mounts below are not
preempted. Headless runs never prompt: advisory WARN + the one-line manual fix.

<a id="42010605-0053"></a>

### Section 9b2: Sequence files (parse + snippet expansion)

`yuruna/test/Test-Config.ps1`

Read every sequence in the framework AND the default test project through the
same loader the runner uses (Read-SequenceFile, which splices `snippet:`
references from the _snippets.yml libraries). A YAML error, an unknown or
duplicate snippet name, or a snippet cycle FAILs the gate here -- before a
cycle starts -- instead of dropping steps or aborting mid-guest. Snippet
libraries are also shape-checked directly so a broken-but-unreferenced library
doesn't hide until first use.

<a id="42010605-0054"></a>

### Strict-mode completeness: every logical username referenced by an active sequence must be declared.

`yuruna/test/Test-Config.ps1`

Strict-mode completeness: every logical username referenced
by an active sequence must be declared. Scan framework
sequences under test/sequences/ AND project-tree sequences,
which the flat project shape keeps directly in any directory
named 'test' under <repoRoot>/project/ (e.g.
`project/example/website/test/*.yml`) -- the same shape
Get-ProjectFlatTestSearchDir walks at runtime, replicated here so
Test-Config stays standalone and doesn't have to import the
sequence engine module.

<a id="42010605-0055"></a>

### github.com answered, and it rejected the credential -- so the URL is very likely fine and the generi

`yuruna/test/Test-Config.ps1`

github.com answered, and it rejected the credential -- so the URL
is very likely fine and the generic causes below are a wrong
trail. Say so, and carry the remedy INSIDE the FAIL: the
pre-cycle gate re-emits only the FAILURES block to the console,
so anything written outside it never reaches the operator who
is looking at a refused cycle.

<a id="42010605-0056"></a>

<a id="no-git----could-be-the-in-tree-project-layout-files-committed-to-the-framework-repo-or-the-post-f"></a>

### Missing .git: in-tree project layout or empty/damaged project directory

`yuruna/test/Test-Config.ps1`

No .git -- could be the in-tree project layout (files committed to
the framework repo) OR an empty or damaged project directory.
Update-ProjectClone now clones beside the previous checkout and verifies
the replacement, so a failed clone leaves the previous checkout in place.
When no archive can be served, the status service 404s
/yuruna-project-archive.tar.gz and guests fall through to their
own clone, which can fail for the same repository-access problem.

<a id="42010605-0057"></a>

### Section 5d: Storage filter stack (guest throughput)

`yuruna/test/Test-Config.ps1`

A guest install is tens of thousands of small writes with a flush behind
each one, and every one of them passes through whatever the host has
attached to the volume holding the VHDX. That cost is invisible from
inside the guest and invisible in the harness's own logs: what surfaces is
a package step that runs long and a step budget that expires, both of
which name the guest. Raising the budget then treats the symptom on the
wrong machine.

Reported, never enforced, and reported even when it is fine. The host that
runs the lab is often also somebody's workstation, so a scanner on that
volume is a legitimate configuration rather than a defect -- but it has to
be a known one, because it silently rescales every duration the harness
records and every budget derived from them.

Windows-only by nature: filesystem minifilters and volume shadow copies
are Windows constructs, and a KVM or UTM host's qcow2 has nothing
equivalent in the path.

<a id="42010605-0058"></a>

### Section 5c: Display scaling (OCR)

`yuruna/test/Test-Config.ps1`

A host desktop above 100% scale composes a VM console window through a
scaled compositor, so the glyphs a window capture hands OCR arrive
resampled instead of at native resolution. Nothing errors when that bites:
the step spends its whole timeoutSeconds and reports 'pattern not found'
while the saved frame looks perfectly readable to a person, which is the
most expensive way for this to be discovered.

Scoped per host family because the exposure is not uniform. The OCR wait
loop reads the guest framebuffer directly -- WMI on Hyper-V, VNC on UTM,
virsh on KVM -- and host scaling cannot reach any of those. It reaches OCR
only through the window-capture paths: the tapOn loop, which always asks
for a window, and the fallbacks each family drops to when its framebuffer
read fails. On KVM there is no such path at all, so the honest answer
there is that the setting does not apply rather than that it passed.

WARN, never FAIL, and deliberately unlike Section 5a2 above: no per-cycle
assertion refuses a cycle over scaling, so a report that failed one here
would be inventing a gate the harness does not have -- and a health report
that can fail a run is one operators stop running.

<a id="42010605-0059"></a>

### Apply the pin rather than print it. The remedy is set at bridge-build time and nobody rebuilds a wor

`yuruna/test/Test-Config.ps1`

Apply the pin rather than print it. The remedy is set at bridge-build
time and nobody rebuilds a working bridge, so a printed command reaches
only the operator who happens to run this report by hand -- while this
gate runs on every host at every runner start and its transcript is
discarded when it passes. Safe unattended because the call writes the
stored profile without reactivating it: the address in use does not
move, and nothing drops. Only the NetworkManager backend is touched;
see Set-HostBridgeDhcpIdentity for why netplan is reported instead.

<a id="42010605-005a"></a>

### Section 5b: Host address stability

`yuruna/test/Test-Config.ps1`

A host that draws a new lease on every renewal spends addresses at a rate the
lease time sets, not the machine count -- so the same fault is survivable on a
short lease and exhausts the pool within days on a long one, and the guests it
starves report "no IPv4 address", which reads as their own fault. The check
pairs what the address log observed with what the bridge asked for, because
a pin the DHCP server ignores looks like a working pin from the config and
like no pin at all from the log. Reported, never fatal: by the time this runs
the drift has already cost what it was going to cost, and a health report that
can fail a run is one operators stop running.

<a id="42010605-005b"></a>

### Section 5a3: UTM app lifetime

`yuruna/test/Test-Config.ps1`

Its own section rather than a tail on the screen-lock findings above: neither
of these settings is a screen setting and neither needs sudo, so filing them
under a heading about display sleep -- beside a remedy that announces it will
ask for a password -- sends the operator into System Settings looking for a
pane that has no such knob. They are read from Get-MacUtmLifetimeIssue, which
is also what the per-cycle assertion prints, so the report and the gate cannot
describe the same host differently.

FAIL, like 5a2: every line it returns is one the gate refuses to start on.

<a id="42010605-005c"></a>

### Section 5a2: macOS screen lock / display sleep

`yuruna/test/Test-Config.ps1`

Checked here for the same reason the operator grants above are: this script IS
the pre-cycle gate, and the per-cycle assertion refuses a cycle on exactly
these settings. A host this report passes and the runner then stops teaches
the operator nothing -- they meet the refusal one entry point later, with a
runner already waiting, in a warning this report never showed them.

The findings come from Get-MacScreenLockIssue, which is also what the
per-cycle assertion prints, so the report and the gate cannot describe the
same host differently. FAIL rather than WARN: every line it returns is one the
gate refuses to start a cycle on.

<a id="42010605-005d"></a>

### Section 5a: macOS permissions only a person can give

`yuruna/test/Test-Config.ps1`

Checked HERE and not only inside the cycle. This script IS the pre-cycle gate,
so a host it passes and Assert-HostConditionSet then refuses has learned
nothing from the gate: the operator finds out one entry point later, with a
runner already waiting, from a message the gate never showed them.

Detection and every word of the repair come from the operator-grant registry
that the per-cycle assertion uses, so the two cannot describe the same
permission differently -- which is the failure mode that costs an operator
most, because following one set of instructions and being refused by the other
gives no way to tell which is stale.

None of these can be granted by a script, with or without a password: macOS
keeps them in SIP-protected TCC databases and only an MDM-delivered PPPC
profile can pre-authorize one. The gate does what is left -- name the exact
grant, the exact pane, and the exact application to enable.

<a id="42010605-005e"></a>

<a id="utm-installs-correctly-and-still-leaves-this-failing-the-cli-lives-inside-the-app-bundle-and-nothin"></a>

### UTM CLI in the app bundle is not automatically on PATH

`yuruna/test/Test-Config.ps1`

UTM installs correctly and still leaves this failing: the CLI lives
inside the app bundle and nothing puts that directory on PATH. Both
repairs are printed because they are not interchangeable -- the
first also applies the rest of the host settings and needs an
interactive sudo, the second is one line an operator can paste into
a session that already has a warm sudo timestamp.

<a id="42010605-005f"></a>

### Section 3c: Host setup freshness

`yuruna/test/Test-Config.ps1`

The settings Enable-TestAutomation applies survive a reboot, but not reliably
a major OS upgrade: app preference domains are rebuilt from their defaults and
privacy grants are re-asked. The host then presents as one that was never set
up -- several unrelated-looking settings gone at once, each reported in its own
section further down, none of them naming the event they share. Said once,
here, ahead of the sections that report the consequences, the whole set reads
as one thing with one fix.

WARN, never FAIL: an upgraded host whose settings all survived still runs, and
the ones that did not survive are refused on their own terms below. A second
refusal for the same host state would only make the first harder to find.

<a id="42010605-0060"></a>

### Invoke-HostClockSyncOffer

`yuruna/test/Test-Config.ps1`

Interactive only: offer to resynchronize the clock right now. Returns $true
only when a sync actually succeeded (the caller then re-measures rather
than trusting the attempt). Where nobody can be asked -- the pre-cycle config
gate, an unattended runner -- it returns $false immediately and keeps the
printed instructions, because declining to offer is a complete outcome here
while blocking on a prompt is not.

This is the one place a clock repair is attempted with an operator present,
so it is also the only place that may ask for a credential. A running cycle
never syncs -- it measures and warns (Write-HostClockDriftWarning).

<a id="42010605-0061"></a>

### Section 3b: Host clock

`yuruna/test/Test-Config.ps1`

Every hypervisor here seeds a guest's clock from the host at power-on, so
a drifting host starts every VM equally wrong and the guest's own NTP
client steps it to real time seconds into the boot -- mid-startup for
whatever that guest is bringing up. On a Kubernetes guest that leaves pods
Running but never Ready and every NodePort refusing, with nothing in the
picture pointing back at a clock. Cheap to measure here; expensive to
diagnose later.

<a id="42010605-0062"></a>

### Capture Test-HostRequirement's Write-Warning lines via -WarningVariable and re-emit them through Wri

`yuruna/test/Test-Config.ps1`

Capture Test-HostRequirement's Write-Warning lines via -WarningVariable
and re-emit them through Write-Warn so they land under the current
section in Test.Output's state. Without this, those warnings reach
the host's Warning stream directly and never make it into the
FAILURES-summary block, leaving the operator with a bare "see
warnings above" pointer at content that has scrolled off.

<a id="42010605-0063"></a>

### Section 3: Host requirements (quick)

`yuruna/test/Test-Config.ps1`

Imports Test.HostContract.psm1 and runs the same fast preflight that
operator-facing helpers (Remove-TestVMFiles.ps1, ...) call: detects
the host type and verifies the absolute minimum (Administrator +
vmms on Hyper-V, virsh + /dev/kvm on Ubuntu, UTM.app + utmctl on
macOS). The pointer Write-Information inside Test-HostRequirement
is suppressed here because THIS script IS the deeper check it would
otherwise advertise.

<a id="42010605-0064"></a>

### Helpers

`yuruna/test/Test-Config.ps1`

Write-Pass / Write-Fail / Write-Warn / Write-Info / Write-Section /
Write-Summary / Exit-WithSummary are exported by Test.Output.psm1.
Test-IsSet / Test-AgainstSchema / Test-RepoFreshness are exported by
Test.ConfigValidator.psm1. Both modules share a $global: counters
anchor so every Write-Fail / Write-Pass from either module lands in
the same end-of-run summary.

<a id="42010605-0065"></a>

### Alternative OCR option using Tesseract (open-source), independent of WinRT

`yuruna/test/check/Test-TesseractOcr.ps1`

Test-WinRtOcr.ps1 demonstrates the WinRT Windows.Media.Ocr engine, which
requires shelling out to PowerShell 5.1 due to .NET 6+ dropping WinRT support.

This script demonstrates a completely different approach: Tesseract OCR, an
open-source engine that runs as a standalone executable. It works directly
from pwsh (no powershell.exe shim), runs on Windows/macOS/Linux, and does
not depend on any Windows Runtime API.

Install Tesseract via any of:
  winget install UB-Mannheim.TesseractOCR
  choco install tesseract
  scoop install tesseract
  brew install tesseract          (macOS)
  sudo apt install tesseract-ocr  (Linux)

<a id="42010605-0066"></a>

### Demonstrates the "closed access" problem with Microsoft AI/OCR on modern PowerShell

`yuruna/test/check/Test-WinRtOcr.ps1`

Windows ships a capable OCR engine (Windows.Media.Ocr) as part of the Windows
Runtime (WinRT). However, .NET 6+ removed built-in WinRT projection support,
which means PowerShell 7+ (pwsh) cannot load WinRT types directly.

The only two ways to use Windows.Media.Ocr are:

1. Shell out to Windows PowerShell 5.1 (powershell.exe), which still has
   native WinRT interop. This is what yuruna's Test.OcrEngine.psm1 does
   (see the WinRT provider block).

2. Add the Microsoft.Windows.SDK.NET.Ref NuGet package to a C# project
   and compile against it. This package is not redistributable and requires
   a Windows SDK installation.

Neither option works as a simple "Add-Type" or "Import-Module" from pwsh.
The types exist on every Windows machine, but the runtime bridge is gone.

This script proves the point: it tries to load the OCR engine from pwsh
(which fails), then falls back to powershell.exe (which succeeds).
If an image path is provided, it also runs OCR on that image via
powershell.exe and displays the extracted text.

<a id="42010605-0003"></a>

## Lab storage and enrollment

<a id="42010605-0068"></a>

### Loopback exemption and aliases

`yuruna/test/lab/Clear-LocalLabStorage.ps1`

The aliases go only when they still point at THIS machine. After a conversion
the sync has usually repointed them at the lab's NAS -- same name, different
address -- and dropping one then would leave the mount with a name nothing
resolves. Get-PoolWorkerAliasPlan owns that rule; here the configured-server
list is empty on purpose, so a name that resolves off-box is reported as
someone else's and kept either way.

<a id="42010605-0069"></a>

### The probes ask questions and change nothing, so -WhatIf is suppressed across them. It has to be supp

`yuruna/test/lab/Clear-LocalLabStorage.ps1`

The probes ask questions and change nothing, so -WhatIf is suppressed across
them. It has to be suppressed HERE rather than inside the module: preference
propagation follows the invocation chain, not the module's scope chain, so an
assignment in the callee is invisible to the cmdlet it wraps. Without this, the
first Get-SmbShare autoloads the SmbShare module and its own New-Alias calls
narrate five "What if: Set Alias" lines into the middle of the report.

<a id="42010605-006a"></a>

### What this machine still serves

`yuruna/test/lab/Clear-LocalLabStorage.ps1`

Asked of the OS share table rather than of test.config.yml, for the reason
Get-LocalLabStorageServedPath exists: the config a machine carries for a NAS is
identical in every key to the config for shares served here, so only the share
table can tell them apart -- and after a conversion the config names the NAS,
which would make a config-driven answer say "nothing local" on a machine still
serving both shares.

<a id="42010605-006b"></a>

### Stop this machine from serving its own pool and stash shares: withdraw the SMB shares, delete the st

`yuruna/test/lab/Clear-LocalLabStorage.ps1`

The inverse of New-LocalLabStorage.ps1, for a machine that has joined a lab
and now mounts the lab's storage instead of its own. Everything that made
this machine a storage SERVER comes down; nothing that it stored does.

That split is deliberate and is the whole design of this script. The folders
under the storage root hold finished cycle archives, stash artifacts, the lab
vault, and the pool-configuration repository -- content whose only copy may be here,
and which no automated rule can judge. So the bytes are reported, never
deleted: sizes per folder, what each one holds, and the exact command for
the operator to run once they have decided. Everything else -- the share
definitions, the accounts scoped to them, the Windows loopback exemption,
the hosts-file aliases -- is machine configuration that is wrong the moment
this host stops serving, and that comes down without asking beyond one
confirmation.

Leaving the accounts behind is not the safe option it looks like. The lab's
NAS has accounts with the SAME names (yuruna-pool, yuruna-stash) and the
vault now holds the NAS's passwords for them; a local account of that name
that no longer matches is a credential an operator can spend a long time
believing is the one being rejected.

Idempotent. A machine that never served its own storage, or one already
cleared, reports 'absent' for every step and changes nothing.

Run it AFTER the conversion, not before: test/pool/Convert-ToPoolWorker.ps1 needs
the lab's mounts working, and this script's alias removal is scoped by the
post-conversion configuration. Convert-ToPoolWorker prints the invitation to
run this as its closing step.

<a id="42010605-006c"></a>

### Put this host's settings back the way Enable-TestAutomation found them

`yuruna/test/lab/Disable-TestAutomation.ps1`

Host-neutral entry point, mirroring Enable-TestAutomation.ps1. Detects the
host type and runs that host's Disable-TestAutomation.ps1 in a child pwsh
rooted in its own folder; arguments are forwarded verbatim and the child's
exit code is returned.

What is restored comes from the capture Enable wrote before it changed
anything (status/runtime/host.pre-automation.json). On a host enabled before
that capture existed, only what is additive AND provably ours is reversed --
the status-port firewall rule and the Yuruna ICMP rule. Everything else is
printed as a command to run by hand rather than guessed at.

Deliberately NOT reversed, and reported instead: installed packages, PSGallery
modules, macOS TCC grants, the credential vault, cloned repos / VM images /
history, the vmms service, and everything the networkStorage
questionnaire wrote (config keys, vaulted credential, mounts). Tearing down
storage on a "disable settings" is a surprise, so it is offered as explicit
commands.

    host/windows.hyper-v/Disable-TestAutomation.ps1   (needs Administrator)
    host/macos.utm/Disable-TestAutomation.ps1         (asks for sudo)
    host/ubuntu.kvm/Disable-TestAutomation.ps1        (asks for sudo)

Idempotent: safe to re-run.

<a id="42010605-006d"></a>

### Common-parameter relay

`yuruna/test/lab/Enable-TestAutomation.ps1`

The per-host Enable-TestAutomation.ps1 is an advanced script and narrates
each decision under -Verbose, so pass the switch on when it was asked for;
it binds to this redirector as a common parameter and would otherwise stop
here. A level of Verbose or Debug asks for the same narration by another
name, and the switch is what the child binds -- the env var alone would only
reach the per-host script's own preferences, not its -Verbose-gated output.

<a id="42010605-006e"></a>

### Prepare THIS host to run yuruna automated VM tests, whatever host it is

`yuruna/test/lab/Enable-TestAutomation.ps1`

Host-neutral entry point. Detects the host type and runs that host's
Enable-TestAutomation.ps1 in a child pwsh rooted in its own folder; this
shell stays in test/. Arguments are forwarded verbatim and the child's exit
code is returned.

What actually gets configured -- display sleep, screen lock, the hypervisor
service, host firewall rules -- differs per host and is documented and owned
by the per-host script:

    host/windows.hyper-v/Enable-TestAutomation.ps1   (needs Administrator)
    host/macos.utm/Enable-TestAutomation.ps1         (asks for sudo)
    host/ubuntu.kvm/Enable-TestAutomation.ps1        (asks for sudo)

Idempotent, because they are: safe to re-run.

<a id="42010605-006f"></a>

### Force this host's bridge to take a fresh DHCP lease on an interval, so a cycle can be shown to survi

`yuruna/test/lab/Invoke-HostAddressChurn.ps1`

A canary host proves nothing on a quiet network. Waiting for the site
router to renumber the host makes the evidence a matter of luck: the lease
is what it is, the changes fall where they fall, and a green cycle may
simply have run through a calm half hour. This drives the renumbering
instead, so "the cycle passed through N address changes" is a statement
about the harness rather than about the router's mood.

Each tick asks NetworkManager to re-run DHCP on the bridge. Whether the
address actually changes is still the server's decision -- this cannot
manufacture a new address, only a new lease negotiation -- so the script
reports what it observed rather than what it intended, and a server that
hands back the same address produces an honest "no change" line rather than
a silent success.

--- REGION: https://yuruna.link/4220a755-0048

<a id="42010605-0070"></a>

### Repair a wedged local hypervisor and leave the runner, its services and the listener running again -

`yuruna/test/lab/Invoke-HostRefresh.ps1`

One bounded repair attempt, the same implementation every channel uses:
an operator's shell, the macOS bootstrap's refresh dispatch, the status
listener, a pool-control request and the outer runner's automatic
trigger. It climbs a ladder of rungs (probe, reclaim, start-if-stopped,
restart-if-hung, ...) up to the requested ceiling, running only rungs
this checkout can execute on this platform, re-probing after each, and
then converges services, the listener and the runner on a separate
reserve of time.

Safety properties:
  * One repair per host account at a time (a held-open lifetime lock),
    one durable request journal and recovery record under
    $HOME/.yuruna/host-refresh, outside every served directory.
  * Nothing prompts: no console question, no consent dialog, no
    interactive sudo. Every native call is bounded by the invocation's
    915-second budget (60 s startup, 600 s ladder, 240 s convergence,
    15 s reporting).
  * Only proven-owned runner processes are ever signaled; the status
    listener, its beacon and another account's processes never are.
    Operator pauses, holds and restart requests survive the repair.
  * Restarting UTM can suspend running guests, and a hard stop can power
    them off uncleanly; a hard stop happens only with -AllowHardStop on a
    local request.
  * -WhatIf is a read-only plan: nothing is created, locked, written,
    signaled or started.

Everything an attempt disrupted stays an outstanding obligation until
verified or disposed; -Resume retries the one unresolved request and
-DisposeObligation records, audited, that an obligation was handled by
hand.

<a id="42010605-0071"></a>

### Show, step by step, where a Lab token exchange stops

`yuruna/test/lab/Lab-Diag.ps1`

Set-LabToken reports one sentence when the exchange fails, and for the
commonest failure that sentence is misleading: it blames a stale code or the
wrong proxy, which are the two things that produce a clean 403 rather than
the message it prints. When the aggregator SEALED the reply and the client
could not open it, the cause is on the client and none of that advice
applies.

This script prints every step between the code and the recovered token, so
the failing one names itself:

  - which runtime and OS are asking, because the client is the half that
    varies across the hosts in a lab;
  - the HTTP status, which separates a refusal (403 -- the code really was
    wrong or expired) from a seal the client then failed to open (200);
  - the raw reply and how this PowerShell parsed it, since the envelope is
    read by key and a parser that returns a different dictionary type is
    the kind of difference that only shows up on one host;
  - the four envelope fields with their lengths, because
    Unprotect-LabTokenEnvelope returns an empty string SILENTLY when any of
    them is missing, which is indistinguishable from a failed decrypt in
    the message the operator sees;
  - the decrypt itself, with the real exception rather than the swallowed
    one.

Read-only. It redeems a code, which the aggregator counts as an `ok`
exchange and audits like any other, but stores nothing: no vault write, no
config change, no token kept. The code stays redeemable until it rotates,
so running this does not cost the operator the enrollment they were about
to perform.

<a id="42010605-0072"></a>

### Pool-configuration repository

`yuruna/test/lab/New-Lab.ps1`

'pool-configuration.git' is the name every consumer already resolves to and cannot
discover: the apache Alias the caching proxy publishes, the guest mount path
the pool-control service commits to, and the writable path setup.ps1 hands
New-Pool. A lab-name-derived name would be reachable by none of them, so the
store would exist and nothing would ever open it. The lab name does not need
to be in the name -- each lab owns its own -Root, so the pool folder is
already lab-scoped.

<a id="42010605-0073"></a>

### Create a lab: its storage folders, its credential vault, and its pool-configuration repository

`yuruna/test/lab/New-Lab.ps1`

A lab is a physically local set of hosts, which are then grouped into pools;
each pool can carry the framework and project repositories its hosts run.
Bringing one up by hand -- create two folders, share them, set ACLs, put
passwords in a vault -- leaves nothing to check the result. This creates all
three consistently and is safe to re-run.

What it creates under -Root:
  <Root>/yuruna.pool          cycle-output replication + the configuration repository
  <Root>/yuruna.stash         the stash service's own durable store
  <Root>/yuruna.pool/pool-configuration.git
                              bare pool-configuration repository, seeded schema-valid.
                              caching-proxy-service VM serves this over HTTP and that URL
                              becomes the lab's configurationGitUrl.

The vault it writes is plain YAML protected by filesystem permissions. That is
deliberate and is the reason this script exists rather than reusing
Export-Clixml: a lab vault has to be COPYABLE to the other hosts in the lab, and
DPAPI-bound files do not decrypt on the machine they are copied to. See
test/schemas/lab.vault.schema.yml.

Sharing the folders over SMB is left to the operator: it is per-platform, needs
elevation, and the account it grants is a decision this script should not make.
The guide covers it. On a machine that serves its own storage,
test/lab/New-LocalLabStorage.ps1 does that half and calls this script for this one.

ADDING A LAB TO A MACHINE THAT ALREADY HAS STORAGE. The share accounts are
machine-wide, not per-lab: one `yuruna-pool` OS account serves every lab whose
storage lives here. So a credential this machine already has is REUSED rather
than regenerated -- a fresh random password would be recorded in the new lab
vault while the OS account, the SMB server, and the other machines in the lab
all still hold the old one, and every mount using the new vault would fail
against a share that never had that password.

Reuse reads the host vault (the store the harness itself reads) through the
same vaultKey indirection Get-Password uses. It is strictly read-only: a user
with no stored credential gets a freshly generated one, and no existing value
is ever overwritten. -Force regenerates the lab vault file but still reuses
the machine's credentials; rotating a password is a deliberate, separate act
(Set-Password) that has to reach the OS account and the share too.

-Root may be omitted once storage exists here: the root is read back from the
lab vault of a lab already on this machine, so a second lab does not have to
re-specify where the first one put its folders.

<a id="42010605-0074"></a>

### Clear what would otherwise serve this mount from the wrong place. Two kinds, and the second is the o

`yuruna/test/lab/New-LocalLabStorage.ps1`

Clear what would otherwise serve this mount from the wrong place. Two
kinds, and the second is the one that is invisible: an SMB client keeps
ONE session per server name and reuses it, so while any share from the
old NAS is still mounted under 'ypool-nas', a mount of the repointed
'ypool-nas' is answered by the OLD session -- it looks for our share on
the NAS, does not find it, and mount_smbfs says "No such file or
directory". Step 5 repointing the alias does not undo that; only
dropping the session does, and the session goes when its mounts do.

<a id="42010605-0075"></a>

### The cifs mount runs `sudo -n`, which never prompts; without the drop-in it fails and the runner buff

`yuruna/test/lab/New-LocalLabStorage.ps1`

The cifs mount runs `sudo -n`, which never prompts; without the drop-in it
fails and the runner buffers locally instead of archiving.

-NonInteractive is bound from the same predicate every other question in
this script uses, because installing the drop-in writes /etc/sudoers.d
through a bare `sudo tee`. sudo takes its password from /dev/tty, so under
a caller that has taken the console -- stdin closed, stdout captured -- that
write raises a prompt nothing displays and nothing answers, and the run
stops there having already created the accounts and the shares. Declined,
the call returns the exact commands to install the drop-in by hand.

<a id="42010605-0076"></a>

### Step 8 -- mount

`yuruna/test/lab/New-LocalLabStorage.ps1`

Mounted through Connect-YurunaPoolStorage rather than a mount call of its own:
it is the same code the unattended cycle runs, so a share that mounts here is
a share the cycle can mount, and a failure here is a failure the cycle would
otherwise have hit later with nobody watching.

The tier records are re-read from the written config through the harness's own
readers, which is also what applies the '~' expansion the macOS mount point
needs -- passed through unexpanded, mount_smbfs would create a directory
literally named '~' and the mount check would never match it again.

<a id="42010605-0077"></a>

### Step 3 writes the credential, verifies it, and rebuilds the account when it cannot -- so reaching he

`yuruna/test/lab/New-LocalLabStorage.ps1`

Step 3 writes the credential, verifies it, and rebuilds the
account when it cannot -- so reaching here means the account has
the record and smbd still refuses it, which is not something the
operator can fix by repeating what this script already did.
Stop rather than continue: the mount at step 8 would fail with
"No such file or directory", a message about a missing share for
a credential that was never accepted.

<a id="42010605-0078"></a>

### Step progress

`yuruna/test/lab/New-LocalLabStorage.ps1`

Almost every second this script spends is inside a native tool that prints
nothing until it is finished: `sysadminctl -addUser`, `pwpolicy`, `apt-get
install`, a nested `sudo pwsh` for the hosts file, and two SMB mounts each
bounded by a multi-second timeout. Announcing the work BEFORE it starts, and
timing it, is what separates a slow step from a hung one for the operator
watching it -- the same reason the module's own OS calls narrate themselves.

<a id="42010605-0079"></a>

### Honor the caller's logLevel, published as $env:YURUNA_LOG_LEVEL by whatever entry point started this

`yuruna/test/lab/New-LocalLabStorage.ps1`

Honor the caller's logLevel, published as $env:YURUNA_LOG_LEVEL by whatever
entry point started this script (install/setup.ps1, a runner cycle). After the
line above on purpose: an explicit level is the operator's choice and replaces
this script's own default. $InformationPreference is then re-read from the
global the cascade writes, because the script-scoped assignment above shadows
it for the rest of this file. See docs/loglevels.md.

<a id="42010605-007a"></a>

### Turn THIS machine into its own pool and stash storage server: create the folders, the two storage ac

`yuruna/test/lab/New-LocalLabStorage.ps1`

A lab with no NAS still needs the pool and stash tiers. Standing them up by
hand is a dozen elevated, per-platform steps -- create two folders, create
two accounts, enable a file server, publish two shares, set ACLs, add host
aliases, store two passwords in a vault, mount two shares, edit six config
keys -- with nothing to check the result. This does all of it, on Windows,
macOS, and Ubuntu, and is safe to re-run.

FOR LOCAL MACHINES ONLY. The accounts and permissions it creates are local
to this machine. A real NAS or a separate file server owns its own accounts
and its own access control, and neither can be configured from here: on
those, create the users and grant the share permissions ON THE REMOTE
DEVICE, then point networkStorage.* at it (docs/test-config.md). The script
says this and asks for confirmation before it changes anything.

The shares are LOCAL but are consumed as if they were REMOTE. Each tier gets
a host alias (ypool-nas, ystash-nas) resolving to the loopback address, and
the share is mounted over SMB through that name by the same
Connect-YurunaPoolStorage the unattended cycle uses. The benefit is
uniformity: the runner, the config gate, the replication drain, and the
guest seeds all take the one network path, so a single-machine lab exercises
the same code as a lab with a NAS -- and moving to real hardware later
changes the alias and nothing else.

The storage root is resolved first (prompted, with the platform's convention
offered as the default: /srv/yuruna on Ubuntu, /Users/Shared/yuruna on macOS,
<drive>\Shares\yuruna on Windows -- the first fixed drive that is not the
system drive). The eight numbered steps then run in this order:

  1. Folders, lab vault, and pool-configuration repository, by calling New-Lab.ps1.
     The two share passwords are the ones it generates; a lab that already
     exists keeps the passwords it has, so a re-run does not rotate the
     credentials the lab's other machines are using.
  2. SMB server. Started (Windows), enabled (macOS File Sharing), or
     installed and configured (Ubuntu: samba + cifs-utils). Before the
     accounts so step 4 can publish and probe in the same run.
  3. Storage accounts. One local account per tier, each scoped to its own
     share: not an administrator, no interactive shell, and on Ubuntu the
     OS password stays locked (the SMB credential lives in Samba's passdb).
     On macOS the SMB-NT hash type is enabled and the password re-set, which
     is the only thing that makes the account usable over SMB at all.
  4. Shares. One per tier, each granting only that tier's account; on macOS
     each credential is then proved against the running SMB server.
  5. Loopback. Host aliases for both server names, plus, on Windows, the
     NTLM loopback exemption and EnableLinkedConnections.
  6. Vault. Each password is mapped to a vaultKey in users.yml and stored,
     so the harness never auto-generates a password the share would reject.
  7. Config. The six networkStorage keys in test/test.config.yml.
  8. Mount. Both shares, at the platform's conventional mount points --
     after the config, so what mounts is what the runner will later read.
     A share already standing at one of those points is unmounted first,
     so what is mounted is what step 5's alias now resolves to.

Account names are deliberately NOT parameters -- they are the two script
variables below. They have to agree with the accounts on a NAS if this lab
ever moves to one, so they are a lab-wide constant to be edited once, not a
per-run choice that could differ between machines.

<a id="42010605-007b"></a>

### Delete VM files on THIS host that no longer belong to a registered VM

`yuruna/test/lab/Remove-OrphanedVMFiles.ps1`

Host-neutral entry point. Detects the host type and runs that host's
Remove-OrphanedVMFiles.ps1 in a child pwsh rooted in its own folder; this
shell stays in test/. Arguments are forwarded verbatim and the child's exit
code is returned.

What counts as orphaned differs per host and is owned by the per-host
script:

    host/windows.hyper-v/Remove-OrphanedVMFiles.ps1  (needs Administrator)
    host/macos.utm/Remove-OrphanedVMFiles.ps1
    host/ubuntu.kvm/Remove-OrphanedVMFiles.ps1

DESTRUCTIVE, and it prompts for confirmation unless -Force is given.

This only sweeps FILES left behind by VMs that are already gone. To tear
down the test VMs themselves and then sweep, use Remove-TestVMFiles.ps1 in
this folder -- it stops and unregisters every VM matching the test prefix
and calls this same per-host script afterwards.

<a id="42010605-007c"></a>

### Provision the secrets remote host refresh needs: the signing authority and operator credential for p

`yuruna/test/lab/Set-HostRefreshCredential.ps1`

Remote refresh is authorized by secrets of its own, never by the lab
token, a lab session or the internal authentication key, all of which are
reachable from the dashboard's enrollment path. This script creates and
moves them, and prompts for nothing:

  1. -NewAuthority, on the operator's machine: creates authority.key
     (the signing authority) and operator.credential (what callers send
     in X-Yuruna-Refresh-Credential), owner-only, under the private root's
     authority directory. Copy both to pool-control's
     /etc/yuruna/host-refresh/ with owner-only permissions; never copy them
     to a pool host.
  2. -ExportHostKey -HostId <id> -OutputPath <file>, on the same machine:
     derives one host's verifier key and writes it for transport.
  3. -InstallHostKey -KeyPath <file>, on that host: installs the key into
     the host's private root. A host that is also the authority machine
     can use -InstallHostKey -AuthorityDirectory <dir> instead.
  4. -RemoveHostKey on a host withdraws it from remote refresh.

Without a switch, the script reports the host's key state and the
authority state. Secrets never reach the output: only tags (non-secret
names) and paths do. The host id is read from runtime/host.uuid and is
never minted here. Exit code 0 on success, 1 on a refusal.

<a id="42010605-007d"></a>

### An existing value is normally the operator's and is never touched. The exception is a value THIS blo

`yuruna/test/lab/Set-LabToken.ps1`

An existing value is normally the operator's and is never touched.
The exception is a value THIS block wrote on an earlier run: the
proxy is addressed by a DHCP lease, so its address moves, and a
url pinned to the address it held last time points at nothing --
or worse, at whatever guest now holds that lease. That is not an
operator decision to preserve, and left alone it never self-heals:
every later run sees a non-empty value and skips. Recognize only
the exact shape this block emits (scheme, host, repo name), so
anything the operator actually chose still wins.

<a id="42010605-007e"></a>

### Seed the pool configuration store binding

`yuruna/test/lab/Set-LabToken.ps1`

A host that has just enrolled its lab token is a host the operator intends to
manage from the lab. The configuration store it should pull from is served by the very
proxy they just named, so bind it now: enrollment is the one moment an operator
is present, authenticated, and has already supplied the address.

Runs for EVERY resolved address, not only an operator-supplied one -- a host
whose cachingProxyIp was already in config still needs the pool binding, and
that is the common case on a re-enrollment.

An existing non-empty configurationGitUrl is retained unless it matches the auto-seeded
http://<host>/pool-configuration.git shape and differs from the resolved proxy URL. That
shape is refreshed to the current proxy address; other operator-selected URLs
remain unchanged. Best-effort throughout -- the token is already stored, and
failing to seed an optional binding must not fail the enrollment.

<a id="42010605-007f"></a>

### Resolve the aggregator base URL

`yuruna/test/lab/Set-LabToken.ps1`

An explicit -CachingProxyService wins; else the host's own configuration (the
probe-and-discard resolution Get-PoolAggregatorServiceSeedUrl owns, which believes
a stored address only once it answers); else ask. $addressSource records
where the address came from so only an operator-supplied one is persisted
below.

The wait budget is what separates this caller from a seed render: an
operator is holding a code that stays redeemable for about three minutes,
so riding out a momentary outage costs a wait they would spend anyway,
while resolving '' costs them the enrollment and a trip back to the
dashboard for a fresh code.

<a id="42010605-0080"></a>

### Enroll THIS host in the lab: redeem the dashboard's Lab token for the internal authentication key an

`yuruna/test/lab/Set-LabToken.ps1`

The Yuruna hosts dashboard (Grafana on the caching-proxy service) shows a "Lab
token" tile with a 6-character code that rotates about once a minute.
This script redeems that code at the pool-aggregator service's
POST /api/v1/lab-token, receives the internal authentication key, and stores it
in this host's vault -- enabling the status-service control routes (the
Grafana deep-link control proofs) and cross-host config-sync. The secret
itself never has to be read off the proxy or typed by the operator.

The reply is sealed under the code that was typed, so only this host can
open it: a host being enrolled cannot yet verify the aggregator's TLS
leaf (the proxy's own CA signs it), and the seal is what keeps anything
else on the network from answering the exchange and planting a token.

The caching-proxy service is found from this host's configuration (the persisted
caching-proxy-service state, $env:YURUNA_CACHING_PROXY_SERVICE_IP, or
vmStart.cachingProxyIp in test.config.yml). Each is probed on the
aggregator port and the first that answers is used, so an address left
behind by a proxy that has since moved is passed over instead of
swallowing the enrollment; when none answers, the probing continues for
up to two minutes before giving up, so a momentary outage does not cost
the operator a code. When no address answers at all, pass -CachingProxyService
or answer the prompt. That address is written to
vmStart.cachingProxyIp when test.config.yml exists, binding the host to
this lab's proxy for later runs; on a machine with no config file yet it
serves this enrollment only, and Sync-HostConfiguration.ps1 brings over
the config that binds it.

Safe to re-run at any time: a lost or rotated token, a rebuilt proxy, or
a doubtful host state is fixed by reading the current code off the
dashboard and running this again.

<a id="42010605-0081"></a>

### Internal authentication key

`yuruna/test/lab/Sync-HostConfiguration.ps1`

-PersistInternalAuthKey is host-neutral: storing the internal authentication key in
this host's vault is the identical vault operation on every platform (unlike
the config conversion the per-host script owns), so it runs here in the
redirector -- before the per-host config-sync, which can then also read the
token from the local vault. Handled by the module's Set-InternalAuthKey
in-process (test/lab/Set-LabToken.ps1 takes only the dashboard's 6-char code,
never the raw token); the persist switches are excluded from the forwarded
arguments (the per-host script has no such parameter).
Persisting is the DEFAULT once a token is supplied and the host is joining the
pool: a host that syncs a pool config but stores no token accepts control only
from loopback, so the dashboard's own deep link into it fails with a 403 that
looks like a bug rather than an unfinished setup. -NoPersistInternalAuthKey keeps
the token transient for a host that should stay locally-driven, and -NoPool
already means "not joining", so it does not persist either.

<a id="42010605-0082"></a>

### Common-parameter relay

`yuruna/test/lab/Sync-HostConfiguration.ps1`

The per-host Sync-HostConfiguration.ps1 is an advanced script and narrates
each decision (kept local path, added alias, stored credential) under
-Verbose, so pass the switch on when it was asked for; it binds to this
redirector as a common parameter and would otherwise stop here.
-WhatIf rides along for the same reason and needs the same explicit relay:
ConvertTo-HostScriptArgument deliberately drops the optional common
parameters, so a bound -WhatIf would otherwise stop at this shell while the
per-host script -- which supports it -- ran for real.
A level of Verbose or Debug asks for the same narration by another name, and
the switch is what the child binds -- the env var alone would only reach the
per-host script's own preferences, not its -Verbose-gated output.

<a id="42010605-0083"></a>

### Elevation check

`yuruna/test/lab/Sync-HostConfiguration.ps1`

Elevation before anything happens. Invoke-YurunaHostScript makes the same
check, but only at line-of-delegation -- by then this redirector has already
rewritten the vault's internal-auth-key and bounced the status service (a wait of
up to three minutes), so an unelevated Windows operator pays for work that
cannot finish. Test-IsAdministrator lives in Yuruna.Common: Yuruna.HostRedirect
imports it into its own scope only, so this entry point imports it too.
Windows-only, exactly as the redirector has it -- '#requires -RunAsAdministrator'
exists only in the Hyper-V per-host script; the macOS and Ubuntu variants ask
for sudo themselves, per operation, with a reason.

<a id="42010605-0084"></a>

### SupportsShouldProcess is load-bearing, not decoration: this script performs a state change of its ow

`yuruna/test/lab/Sync-HostConfiguration.ps1`

SupportsShouldProcess is load-bearing, not decoration: this script performs a
state change of its own (storing the internal-auth-key in the vault and bouncing
the status service) before delegating. Without it, -WhatIf binds to
-RemainingArguments as a plain string instead of a common parameter, so the
rehearsal reaches only the per-host script -- and the vault write it was meant
to rehearse happens for real.

<a id="42010605-0085"></a>

### Copy another pool host's test

`yuruna/test/lab/Sync-HostConfiguration.ps1`

Host-neutral entry point. Detects the host type and runs that host's
Sync-HostConfiguration.ps1 in a child pwsh rooted in its own folder; this
shell stays in test/. Arguments are forwarded verbatim and the child's exit
code is returned.

The conversion is what differs per host -- share paths, local mount-point
conventions, and where a host alias gets written -- and it is owned by the
per-host script:

    host/windows.hyper-v/Sync-HostConfiguration.ps1  (needs Administrator)
    host/macos.utm/Sync-HostConfiguration.ps1        (sudo for /etc/hosts)
    host/ubuntu.kvm/Sync-HostConfiguration.ps1       (sudo for /etc/hosts)

Idempotent, because they are: a repeat run with nothing to change writes
nothing.

<a id="42010605-0004"></a>

## Pool transitions

The shared `ConvertTo-PoolConfigurationSchemaV4` reader normalizes schema versions
2 and 3 in memory. It moves version 2 repository declarations into `repositories`
and renames `desiredState` to `configuredState` without changing its value.
Matching duplicate state values collapse only in legacy documents; conflicting
values are rejected before mutation. Version 4 rejects the retired field.
Reading alone never writes the stored document.

<a id="42010605-0087"></a>

### Re-asked in-process rather than read off the sync. The sync ran the same convergence, but behind the

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

Re-asked in-process rather than read off the sync. The sync ran the same
convergence, but behind the redirector's child pwsh, so its per-user records
never came back here -- only an exit code, which is 0 for a sync that reported
an unconverged credential as a warning. Asking again is idempotent (an entry
that already matches is a no-op and no write) and it is the only way this
script can name the users that did not converge in its verdict.

<a id="42010605-0088"></a>

### Order is load-bearing, and each step is the precondition of the next. RELEASE first: this host's mou

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

Order is load-bearing, and each step is the precondition of the next.

RELEASE first: this host's mounts of its own shares stand on the very mount
points the synced config names, and their sessions own the server names it
resolves through. Nothing else can mount until they are gone. Released
while their server is still up, too -- unmounting a share whose sharepoint
has just been withdrawn can wedge on I/O that never completes.

<a id="42010605-0089"></a>

### The sync runs in THIS session and re-imports Test.ConfigServiceSync with -Force, which unloads the T

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

The sync runs in THIS session and re-imports Test.ConfigServiceSync with
-Force, which unloads the Test.HostDetection instance Test.HostContract's
re-exports point at -- so Get-HostType stops resolving from here on. The
contract is re-imported for the same reason it is imported last above: after
everything that pulls its nested dependencies. The -WhatIf suppression is
needed for the same reason too, since New-YurunaRegistry builds the contract's
module-level state under ShouldProcess.

<a id="42010605-008a"></a>

### By-name (hashtable) splatting is REQUIRED here. Array splatting binds every element POSITIONALLY --

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

By-name (hashtable) splatting is REQUIRED here. Array splatting binds every
element POSITIONALLY -- a literal '-ReferenceHost' string element is never
re-parsed as a parameter name, so it lands in $ReferenceHost and the real
address, the port and the token all fall through to the sync's
ValueFromRemainingArguments catch-all. That catch-all is why the mistake is
silent on this path: the sync binds and runs, and only its own child rejects
the doubled '-ReferenceHost -ReferenceHost' with a binding error that names a
script the operator never typed.

-SkipValidation is passed UNCONDITIONALLY, and the validation is run by this
script at the end instead. Test-Config's storage checks mount the lab's shares,
and at this point in a conversion they cannot mount: this machine is still
serving its own shares under the same names and still holds the SMB sessions
that decide where those names lead. Validating here reports a FAILURE that the
next two steps exist to remove, which is the worst possible moment to show it
-- the operator reads a hard failure from a run that has not finished.

<a id="42010605-008b"></a>

### 2. Sync configuration from the reference host

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

Through the documented redirector rather than the module function, so this
conversion gets the per-host conversion, the elevation checks, and the
freshness gate exactly as an operator running the sync by hand would.

-InternalAuthKey is passed explicitly even when it came from this host's own vault:
the sync would find it again, but passing it makes the value this script
preflighted the value the sync uses, so the two cannot disagree about which
token the run is built on. Supplying it also makes the sync store it in this
host's vault and bounce the status service, which is what a converting host
needs: a worker that syncs a pool config but holds no token accepts control
only from loopback, and the dashboard's deep link into it answers 403.

<a id="42010605-008c"></a>

### Read from the config this host carries NOW. The synced one names the same share leaf for each tier -

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

Read from the config this host carries NOW. The synced one names the same
share leaf for each tier -- '//ypool-nas/work/yuruna.pool' and the
'//ypool-nas/yuruna.pool' a local bring-up publishes both end in
'yuruna.pool' -- so the preflight answer holds for the post-sync config too.

The YAML import is $WhatIfPreference-suppressed: powershell-yaml registers two
aliases at load, New-Alias supports ShouldProcess, and a rehearsal would
otherwise narrate "What if: New Alias" twice into the middle of a report that
only READS. Reading a config file changes nothing under either preference.

<a id="42010605-008d"></a>

### Same $WhatIfPreference suppression, and for the same reason, as the imports above: the host driver's

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

Same $WhatIfPreference suppression, and for the same reason, as the imports
above: the host driver's module-level state is built with Set-Variable under
ShouldProcess, so an inherited -WhatIf makes the anchor a no-op and the first
read of that state throws "Cannot find a variable" -- a dry run failing on the
state it needs to LOOK at the plan, before it has rehearsed anything. Loading a
driver changes nothing on the host; the gates that do are all below.

<a id="42010605-008e"></a>

### Elevation is asserted before anything happens rather than at the line that needs it: the sync rewrit

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

Elevation is asserted before anything happens rather than at the line that
needs it: the sync rewrites the hosts file and the teardown deletes VMs, and an
unelevated operator would otherwise pay the reference fetch, the credential
probes and the config replacement before the first thing that cannot finish.

A rehearsal is exempt. -WhatIf writes nothing, and demanding an Administrator
shell to LOOK at the plan is what makes an operator skip the preview and run
the real thing first.

<a id="42010605-008f"></a>

### LAST, and that ordering is load-bearing. Test.HostContract re-exports Test.HostDetection's Get-HostT

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

LAST, and that ordering is load-bearing. Test.HostContract re-exports
Test.HostDetection's Get-HostType / Initialize-YurunaHost, and a later
`-Force` import of Test.HostDetection by any other module -- which
Test.ConfigServiceSync above does -- unloads the instance those exports
point at, leaving Get-HostType unresolvable. Importing the contract after
every module that pulls its nested dependencies keeps the host functions
this script needs for the service-state probe in scope.

<a id="42010605-0090"></a>

### $WhatIfPreference is suppressed across the imports and restored immediately after. The host contract

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

$WhatIfPreference is suppressed across the imports and restored immediately
after. The host contract's module-level state is built by New-YurunaRegistry,
whose Set-Variable is under ShouldProcess, so an inherited -WhatIf makes the
anchor a no-op and the very next line indexes a null array -- a dry run failing
on module load, three steps before the first thing it was asked to rehearse.
Only the imports are covered; every ShouldProcess gate this script owns still
honors the operator's switch.

<a id="42010605-0091"></a>

### Convert a standalone machine into a pool worker: sync the lab's configuration onto it, retire the lo

`yuruna/test/pool/Convert-ToPoolWorker.ps1`

Sync-HostConfiguration copies a reference host's configuration and reconciles
the two side channels it depends on. That is the right operation for a
machine joining a lab, and it is not sufficient for one LEAVING standalone,
because a standalone machine has running counterparts to everything the new
configuration now names elsewhere -- and one of them silently wins.

Extension areas resolve as: operator pin, then a VM on THIS host, then the
pool's record (Get-ExtensionHostAddress). So a converted host that still has
its own stash VM keeps using it, forever, and its cycles PASS while doing so.
The pool's stash is never consulted, no warning is emitted, and the artifacts
the lab expects to collect are written to a share only this machine can read.
Stopping the VM does not help either: Restore-YurunaServiceVM starts every
registered-but-stopped service VM at each cycle start, by design, so the
service comes back on the next cycle.

Hence this script, in order:

  1. Pre-flight   -- reference host reachable, internal authentication key available.
  2. Sync         -- test/lab/Sync-HostConfiguration.ps1, with the credential
                     convergence made mandatory.
  3. Teardown     -- every local service VM retired through its own
                     Stop-*ServiceVM.ps1, which clears that service's own
                     marker and deletes the VM's files.
  4. Advertise    -- every runtime marker STILL claimed after step 3
                     withdrawn, and host.registration.json regenerated so
                     this host drops off the dashboard. Driven by the
                     markers rather than by the teardown, because a marker
                     outlives the VM it describes: a host whose service VMs
                     are already gone has no stop script left to run and
                     would go on advertising them forever.
  5. Storage      -- the mounts this machine held of its OWN shares released,
                     the shares and their accounts withdrawn, and the lab's
                     storage mounted in their place.
  6. Aliases      -- hosts-file entries that named a retired local service.
  7. Verify       -- test/Test-Config.ps1, then the question it cannot
                     answer: is the end state actually a worker.

The internal authentication key is REQUIRED. Without one nothing can be fetched
from the reference, and the vault entries this machine minted for the shares
it used to serve itself would survive the conversion -- a password the lab's
NAS has never seen, on a host whose configuration now points at that NAS.
That failure surfaces later as a mount error nobody connects to this step.
Enroll first with test/lab/Set-LabToken.ps1, or pass -InternalAuthKey.

Step 5 is the one whose necessity is least visible. A standalone machine
mounts its own shares at exactly the mount points the synced configuration
now points at the lab's storage, and an SMB client keeps ONE session per
server name -- so while those mounts stand, a mount of the repointed
'ypool-nas' is answered by the session to THIS machine, does not find the
lab's share there, and fails with "No such file or directory" while the
alias, the share path, the account and the mount point are all correct.

DATA is never deleted. Step 5 withdraws the share definitions and the
accounts scoped to them -- machine configuration that is wrong the moment
this host stops serving -- and leaves every byte under the storage root
alone: cycle archives, stash artifacts, the lab vault and the pool-configuration
repository all live there, and no automated rule can judge which of them is
the only copy. The closing output prints what remains and the one command
that reclaims it. Pass -KeepLocalShares on a machine other hosts still mount
from.

Idempotent. A second run finds every service absent, nothing advertised,
nothing of this machine's own standing in the way of the lab's storage,
every alias already dropped and every credential already converged, and
changes nothing.

<a id="42010605-0092"></a>

### autoEnrollment is projected alongside pools because this CLI is the ONLY read path the pool-control

`yuruna/test/pool/Get-PoolConfiguration.ps1`

autoEnrollment is projected alongside pools because this CLI is
the ONLY read path the pool-control service has into configuration. Without it
the sweep cannot see `excluded[]` -- the list that stops it re-adding a
host an operator deliberately removed -- and the operator and a 60-second
timer would fight forever. Emitted as an empty object when absent so a
consumer never has to distinguish "missing" from "unset".

<a id="42010605-0093"></a>

### Evict from the live dashboard view (aggregator forget-host, best-effort)

`yuruna/test/pool/Remove-PoolHost.ps1`

The "Yuruna hosts" panel is the pool-aggregator-service's in-memory view (Prometheus
yuruna_pool_host_info), NOT the NAS records above -- a host it discovered by
POLLING status services lingers there for the aggregator's host TTL (-host-ttl, default 24h) after last contact, so the
deletions so far do not clear it. When an internal authentication key + caching-proxy-service are
configured, ask the aggregator to forget the host NOW. Opt-in + best-effort: a
missing token, unknown proxy, or unreachable aggregator is a silent skip (pull +
TTL still converge) and never fails the purge or throws.

<a id="42010605-0094"></a>

### Purge a stale host from the pool: delete its NAS records (identity + replicated cycles) and strip it

`yuruna/test/pool/Remove-PoolHost.ps1`

Pool garbage-collection CLI. Given a stable hostId, removes the host's entire
footprint so it stops showing up in the "Yuruna hosts" / Extension-hosts set:

  1. STORAGE. Deletes, under networkStorage.poolStorageLocalPath (read from
     test.config.yml):
       * <poolStorageLocalPath>/hosts/info.<hostId>.yml  -- the identity record the
         aggregator lists a host from.
       * <poolStorageLocalPath>/hosts/<hostId>/          -- the host's current
         cycle archives, plus the legacy <poolStorageLocalPath>/<hostId>/
         root when present (reclaims NAS disk).
  2. MEMBERSHIP. Strips the hostId from EVERY pool's members[] in the configuration
     store (pools.yml), then commits + pushes.

Ephemeral hosts (a disposable nested-host cycle, a reimaged box) mint a fresh
hostId each rebuild, so without cleanup each run leaves a dead entry behind.

Guards: refuses to remove THIS host's own uuid (runtime/host.uuid) or a
record last seen < 24h ago (it may still be live) unless -Force. Idempotent;
SupportsShouldProcess (-WhatIf / -Confirm). Distinct from Remove-HostFromPool,
which only edits ONE named pool's membership and never touches storage.

<a id="42010605-0095"></a>

### The auto-enrollment target pool can NEVER carry repositories. Hosts arrive there automatically, with

`yuruna/test/pool/Set-PoolRepository.ps1`

The auto-enrollment target pool can NEVER carry repositories. Hosts arrive
there automatically, without anyone choosing it for them, so a project set
here would silently repoint every auto-enrolled host in the lab on its
next cycle -- the single largest blast radius in the whole pool layer.

Bound to autoEnrollment.targetPoolId rather than the literal 'default', so
renaming the target carries the protection with it. This lives in code
because it is a cross-field constraint that JSON Schema cannot express;
Test-PoolConfiguration.ps1 re-checks it as the authoritative validator. The id
compared is the one stored on the pool found above, not -PoolId as typed:
the lookup ignores case, so a differently cased id must not slip past.

<a id="42010605-0096"></a>

### Set or clear the framework and project repositories a pool's hosts run

`yuruna/test/pool/Set-PoolRepository.ps1`

Pool admin CLI. With -FrameworkUrl and -ProjectUrl it sets the pool's
`repositories` in pools.yml, replacing any previous pair; with -Clear it
removes them. A pooled runner overrides its own repositories.frameworkUrl /
repositories.projectUrl with the pool's pair for the cycle and runs that
project's own test.runner.yml. A pool without repositories leaves each host
on its own configured repositories. GH_TOKEN is never part of pool configuration --
it stays host-local.

Both URLs are trimmed and must be non-empty, free of whitespace and control
characters, and must not start with '-'. The auto-enrollment target pool
(autoEnrollment.targetPoolId) can never carry repositories, so setting them
there is refused; clearing them there is allowed, because that is how an
configuration store that breaks the rule gets repaired.

<a id="42010605-0097"></a>

### Push the repo's canonical Yuruna hosts dashboard onto a RUNNING caching-proxy service VM, so a dashb

`yuruna/test/pool/Sync-PoolDashboardOnProxy.ps1`

test/extension/pool-aggregator-service/grafana-pool-dashboard.json is the
canonical dashboard. The proxy VM does not read it: cloud-init carries a
byte-identical inline copy and writes it once, at build time, to
/var/lib/grafana/dashboards/pool.json. A correction to the canonical file
therefore reaches a running proxy only by rebuilding the VM -- which costs
roughly a quarter hour and takes the cache, the aggregator, Grafana, Loki
and Prometheus down with it, all to replace one JSON file.

This runs from the HOST, not from the proxy: the host already holds the
harness SSH key, while a guest carries only an authorized PUBLIC key. Doing
it guest-side would mean baking a private key that grants sudo-capable
access to the proxy into the VM it administers.

Three things the push has to get right, because the baked copy gets them
right and a naive `scp` would not:

  * The dashboard ships with the literal AGGREGATOR_BASE_PLACEHOLDER in its
    `aggregator` variable. Cloud-init rewrites it to http://<vm-ip>:9400
    after the VM has an address. The same rewrite runs here, in the guest,
    from the guest's own `hostname -I` -- so the address is the one the VM
    actually has, not one this host guessed.
  * Grafana's file provider re-reads the dashboards directory every 30 s
    (updateIntervalSeconds), so a replaced file is picked up on its own.
    Nothing is restarted: a restart would blank every panel for the length
    of a Grafana start to achieve what a provisioner poll achieves anyway.
  * yuruna-fit-pool-dashboard.timer owns the three per-host panels'
    gridPos.h on the proxy -- it sizes them to the live host count, and the
    canonical file's heights are only pre-collector defaults. An overwrite
    resets them, and the timer would not correct that for up to 5 minutes.
    The fitter is therefore run once, immediately, right after the push.

Idempotent: the candidate is compared against what the proxy already serves
with the fitter-owned geometry (the three per-host panels and the row
panels) taken from the live file, so a proxy that is already current is
left untouched instead of being rewritten into a re-fit every run.

Safe to re-run, and non-destructive on failure: the new file is written to
a temporary path in the dashboards directory and moved into place only
after it parses as JSON in the guest, so a truncated transfer never
replaces a working dashboard.

<a id="42010605-0098"></a>

### The auto-enrollment target pool must carry NO repositories. This is the AUTHORITATIVE check: the CLI

`yuruna/test/pool/Test-PoolConfiguration.ps1`

The auto-enrollment target pool must carry NO repositories. This is
the AUTHORITATIVE check: the CLI refuses and the UI disables, but only
this one catches a hand-edited file or a store written by an older
release. It is a cross-field constraint (a pool named by ANOTHER
field), which JSON Schema cannot express. It is defined against the
v4 shape, so it runs only on a store at schemaVersion 4.

A violation FAILS rather than being silently stripped: stripping it
would change what a lab is running without anyone deciding to.

<a id="42010605-0099"></a>

### Validate every file in the pool configuration store against its schema

`yuruna/test/pool/Test-PoolConfiguration.ps1`

Pool admin CLI / CI gate. Clones/pulls the configuration store and validates
pools.yml (schema v4) and guests.compatibility.yml (when present) against
test/schemas/*, enforces the cross-pool invariant that a host belongs to at
most one pool, and checks that the auto-enrollment target pool carries no
repositories. pools.yml is judged as stored: a store below schemaVersion 4
gets one schema-version finding that names test/pool/Update-PoolConfigurationSchema.ps1.
Exit 0 when all valid, 1 on any error. Never writes. Run before relying on
freshly authored configuration (the runners pull whatever is committed, so a
malformed file would silently misconfigure the whole pool).

<a id="42010605-009a"></a>

### Migrate the pool configuration store to pools

`yuruna/test/pool/Update-PoolConfigurationSchema.ps1`

Migration preserves `run`, `paused`, and `drain` while renaming `desiredState`
to `configuredState`. Conflicting duplicate values are rejected; version 4
accepts only the new field. Upgrade every runner as well as every writer before
migrating the shared store.


Pool admin CLI. Clones/pulls the WRITABLE configuration repository and reads pools.yml as
stored. Below schemaVersion 4 it upgrades the document with
ConvertTo-PoolConfigurationSchemaV4: each pool's testSet framework and project URLs
become its `repositories`, and the testSet name and sequences are dropped. It
also deletes a leftover test-sets.yml, which nothing reads. It then validates
pools.yml against test/schemas/pools.schema.yml, commits and pushes. The
commit subject names what changed: "Migrate pool configuration to schemaVersion 4"
when the stored version moves, or "pool: remove test-sets.yml" when the store
is already at schemaVersion 4 and only that leftover file goes.

Idempotent: a store already at schemaVersion 4 with no test-sets.yml is
reported as already current and left untouched. A store at a NEWER version
is refused -- update this checkout first. The migration keeps every value
it finds, including repositories on the auto-enrollment target pool; run
Test-PoolConfiguration.ps1 afterwards, which reports that as a violation to clear
with Set-PoolRepository.ps1 -Clear.

Every other admin CLI performs the same upgrade in memory and persists it on
its next write; this script makes the migration an explicit, reviewable
commit of its own. Run it after every checkout that writes the store (the
pool-control-service VM included) runs the schemaVersion 4 code: a checkout
that still validates against schemaVersion 2 refuses to write a v4 store.

<a id="42010605-009b"></a>

###  Example pool configuration (schema v4). Validates against test/schemas/pools.schema.yml. This is the file

`yuruna/test/pool/examples/pools.yml`

Example pool configuration (schema v4). Validates against test/schemas/pools.schema.yml.
This is the file the pool admin CLI authors and each runner pulls from the
bare git repo on the caching-proxy-service. `members[]` is the single source of truth
for membership (a host belongs to at most one pool): replace the example
hostIds with your hosts' real runtime/host.uuid values (42-prefixed 32-hex).
`poolGuid` is the stable pool GUID. `repositories` holds the
framework and project repository URLs every pooled host runs; omit it and each
host runs its own configured repositories (GH_TOKEN stays host-local, never
here). `configuredState` controls run/pause/drain; `config` overrides cycle knobs
and `gating` sets the advisory pool-alert thresholds.

<a id="42010605-0005"></a>

## Example workload execution

<a id="42010605-009d"></a>

### Acquire base images

`yuruna-project/tools/example-workload.sh`

Acquire images missing from the local store. Candidates in priority
order: the zot pull-through cache (LAN, absorbs upstream TLS jitter),
then mcr.microsoft.com as the survival path when the cache VM is
absent or cannot serve the tag. Each candidate is probe-gated first;
the pull itself is stall-bounded (PULL_STALL, set above) as a backstop
for mid-stream wedges.

<a id="42010605-009e"></a>

### Every attempt warms before it pulls. The warm-up is what holds the request open past dockerd's fixed

`yuruna-project/tools/example-workload.sh`

Every attempt warms before it pulls. The warm-up is what holds the
request open past dockerd's fixed response-header patience while the
cache completes its sync, so an attempt that skips it cannot build
on progress made by the preceding attempt's background sync: it is
bounded by that patience alone, which a cache still syncing cannot
answer inside.

<a id="42010605-009f"></a>

### No HTTP status at all has several causes that send the operator to different places, and curl's exit

`yuruna-project/tools/example-workload.sh`

No HTTP status at all has several causes that send the operator to
different places, and curl's exit code is the only thing that
separates them. Reporting all of them as the timeout wording sends
every reader after a sync that is still running -- which is the
wrong place to look for a cache that refused the connection in
milliseconds because nothing is listening on the port yet.

<a id="42010605-00a0"></a>

### The container image carries no certificate and no password. Kestrel reads the PFX from a Kubernetes

`yuruna-project/tools/Example.Build.psm1`

The container image carries no certificate and no password. Kestrel reads the
PFX from a Kubernetes Secret volume and its password from the same Secret
through secretKeyRef. The Secret is created for each deployment, with a newly
generated password, by Invoke-ExampleCertificateSecret.

The developer's own PFX password arrives in the variable Kestrel itself reads.
Reusing that name lets `docker run -e <name>` pass the value through by name,
so it never appears on a command line or in an echoed batch file. When the
variable is unset or empty, the sidecar file beside the PFX (<pfx>.password, one line)
supplies it: the guest provisioning scripts export their PFX under a random
password and keep it there, so a guest run needs no variable.

<a id="42010605-00a1"></a>

### Create the Kubernetes Secret that carries a pod's HTTPS certificate, protected by a new random passw

`yuruna-project/tools/Example.Build.psm1`

The Secret holds two keys: aspnetapp.pfx and password. The workload mounts the first
as a file and reads the second through secretKeyRef.

The certificate is the developer's PFX re-exported under the generated password, or,
when -SelfSigned is given or YURUNA_EXAMPLE_SELF_SIGNED_CERT=1, a throwaway self-signed
certificate that is never written to disk. The developer's PFX is opened with the password
in ASPNETCORE_Kestrel__Certificates__Default__Password or, when that is unset or empty, in the
sidecar file '<CertificatePath>.password'. The generated password exists only in memory and in
the Secret: it is not placed in a command line, a file, a variable the deployment
engine would log, or any output. The manifest reaches kubectl on standard input.

Failures are written to the error stream, which the deployment engine records
at every log level, and reported by the returned exit code.

<a id="42010605-00a2"></a>

### Run by the workloads configuration immediately before the chart is installed, like create-cert-secre

`yuruna-project/example/text-to-sql/components/frontend/text-to-sql-ui/create-db-secret.ps1`

Run by the workloads configuration immediately before the chart is installed, like
create-cert-secret.ps1. The database setup step generates the read-only role's password
for each deployment and leaves it in an owner-only file; this script carries that password
into the cluster as a Secret the pod reads through secretKeyRef. The script form (rather
than a module call in the configuration) lets a failure reach the deployment engine as an
exit code. The password is not placed in a command line, in output, or in a variable the
engine logs: the manifest reaches kubectl on standard input.

<a id="42010605-00a3"></a>

### Notice that the 'registryName' variable is used to find the name of another variable, requiring the

`yuruna-project/example/text-to-sql/workloads/frontend/text-to-sql-ui/templates/01-text-to-sql-ui.yml`

Notice that the 'registryName' variable is used to find the name of another variable,
requiring the dual indirection.
`required` is a deliberate guardrail against rendering
"/text-to-sql-ui/text-to-sql-ui:latest" (leading slash, empty registry) when the
resources.output.yml componentsRegistry block is missing or does not
propagate to values.yaml, producing an InvalidImageName pod.

<a id="42010605-00a4"></a>

### The registry provisioned here is ECR, whose repository URL is <account>.dkr.ecr.<region>.amazonaws.c

`yuruna-project/example/website/config/aws/workloads.yml`

The registry provisioned here is ECR, whose repository URL is
<account>.dkr.ecr.<region>.amazonaws.com/<repository>. The pull secret
authenticates against the registry host, so the repository path is dropped,
and the region -- the fourth dotted segment of that host -- has to be
spelled out for the token request. ECR has no static password: the token is
short-lived and always pairs with the fixed 'AWS' username.

<a id="42010605-00a5"></a>

### Notice that the 'registryName' variable is used to find the name of another variable, requiring the

`yuruna-project/example/website/workloads/frontend/website/templates/01-website.yml`

Notice that the 'registryName' variable is used to find the name of another variable,
requiring the dual indirection.
`required` is a deliberate guardrail against rendering
"/website/website:latest" (leading slash, empty registry) when the
resources.output.yml componentsRegistry block is missing or does not
propagate to values.yaml, producing an InvalidImageName pod.

<a id="42010605-00a6"></a>

### TO-SET: deploy your component(s). A Helm chart under workloads/, e.g.: - chart: "frontend/yourcompon

`yuruna-project/template/config/localhost/workloads.yml`

TO-SET: deploy your component(s). A Helm chart under workloads/, e.g.:
  - chart: "frontend/yourcomponent"
    variables:
      installName: "yourcomponent-${env:runId}"
or a raw manifest / command:
  - kubectl: "apply -f workloads/yourcomponent/manifest.yml"

<a id="42010605-0006"></a>

## AmisAd host orchestration

`Initialize-Lab.ps1` prepares a topology for an enclosing orchestration cycle;
`run-tests.ps1` first clears the standalone lab and then runs its scenario list.
Their shared stages use the same host contract, phase names, and admission rules.
Both call `Start-AmisAdEdge`: start both edges before waiting, discard reports
from previous boots, require a fresh valid IP address for each edge, and stop
before scenarios if either edge fails. Failure reasons stay attached to the edge.
The public-key handoff uses those verified addresses rather than re-reading an
unconfirmed report. `-WhatIf` leaves report files and VMs untouched.

<a id="42010605-00a8"></a>

### Locate the Yuruna framework checkout, without hard-coding a path

`amisad.dev/test/AmisAd.HostCommon.ps1`

Tried in order, first one that actually looks like a checkout wins:

  1. -Explicit (the caller's -YurunaRoot), so an operator override
     always beats discovery.
  2. $env:YURUNA_ROOT, for a host whose layout matches nothing below.
  3. $env:YURUNA_CONFIG_PATH -- the runner publishes the resolved
     '<root>/test/test.config.yml' before every step and the host
     action inherits it, which makes this exact in-cycle.
  4. <this file>/../.. -- the cycle clones the project to
     '<root>/project', so the project's test/ dir sits two levels
     under the framework root.
  5. $HOME/git/yuruna, for a standalone run outside any cycle (an
     operator invoking the teardown by hand). That is where the
     bootstrap installers clone on every platform, Windows included,
     so one candidate covers all three hosts and no drive letter is
     written down anywhere.

A candidate counts only if test/modules/Test.HostContract.psm1 is
there: that is the module both host actions import, so validating on
it means a match can never resolve to a checkout too old or too
partial to drive.

<a id="42010605-00a9"></a>

### Shared host-portability helpers for the AmisAd host-action scripts (Clear-Lab

`amisad.dev/test/AmisAd.HostCommon.ps1`

A host action that calls `Hyper-V\Get-VM` directly, or defaults its root to
a drive-letter path, cannot run on host.ubuntu.kvm or host.macos.utm: the
Hyper-V module is absent, and a leading 'c:' is read as a PSDrive name
there, so Join-Path fails with "Cannot find drive".

Yuruna solves this: host/<host-type>/modules/Yuruna.Host.psm1 exports ONE
contract (New-VM / Start-VM / Stop-VMForce / Remove-VM / Get-VMState /
Save-VMDiskSnapshot / ...) implemented per hypervisor, and
Initialize-YurunaHost imports the right driver for the detected host. These
helpers wire the project into that contract so the host actions carry no
hypervisor branches of their own.

<a id="42010605-00aa"></a>

### Authorize the PUBLIC half of vm-core's demo key on the edge VMs, over the harness SSH channel, and p

`amisad.dev/test/AmisAd.Lab.psm1`

vm-core generates the core->edge keypair inside itself and keeps the
private half there. Only the public half is read out (over SSH with the
harness key, the channel every other harness action on a guest uses) and
written into each edge's authorized_keys the same way. Nothing private is
ever copied, uploaded or served, and nothing about the key travels over
the status service's HTTP.

Ordering is why this runs here and not inside the edge sequences: the
edges are provisioned before vm-core exists, so the key they must trust
does not exist yet when they are built.

vm-core is started when it is not running and left running. The
scenarios restore its snapshot before they use it, and the key lives in
that snapshot, so a restore keeps it.

Progress and the verdict are returned rather than written: a module
function does not see the caller's script-scoped $InformationPreference,
so printing here would silently drop the report that explains a stop.

<a id="42010605-00ab"></a>

### Delete a core->edge demo key that an earlier lab run left in the status service's served tree

`amisad.dev/test/AmisAd.Lab.psm1`

A host that ran an older version of this lab holds the demo keypair
under test/status/handoff: that design generated it on the host and had
the guests download it, private half included, from the status service,
which hands its files to every machine that can reach the port. A key
that sat there is exposed no matter how long ago it was made, so it is
deleted rather than kept for reuse; vm-core generates its own pair
instead. Removing the file stops it being served. It does not make a
long-lived VM that still trusts the key safe: that VM must be rebuilt,
or its authorized_keys line ending in "amisad-demo" removed, which
Sync-AmisAdDemoKey does on the edges it reaches.

<a id="42010605-00ac"></a>

### Every leg of this resolution rides the host's link, and that link is not continuously up: a DHCP ren

`amisad.dev/test/AmisAd.StashService.psm1`

Every leg of this resolution rides the host's link, and that link is not
continuously up: a DHCP renew alone takes it away for a few seconds, and a
renew that returns the SAME address still does, so nothing downstream even
reports an address change. Inside that window the pool lookup answers with
nothing and a perfectly healthy stash fails /healthz -- both shaped exactly
like a stash that does not exist. Answering on the first attempt therefore
converts a blip into a hard stop before any VM starts, and the pass dies
for a condition that cured itself seconds later.

So ask across a window that outlasts a renew rather than at one instant.
Discovery is redone per attempt, not just the probe: the empty answer is
the more common symptom, and a cached candidate list would keep replaying
it. Only an environment still silent at the end of the window really has
no stash, and that still stops the pass.

<a id="42010605-00ad"></a>

### Find the stash service, verify it answers, and publish the address for the rest of the cycle to reso

`amisad.dev/test/AmisAd.StashService.psm1`

The build uploads its binaries to the stash and vm-core downloads them,
so a stash nobody can reach makes the whole pass pointless -- but the
guests only discover that from inside their own long chains, tens of
minutes in. Resolving here, before any VM starts, turns that into an
immediate stop.

A pin (-Pin, or $env:YURUNA_STASH_SERVICE_HOST for the address a pool handed
this host) is the ONLY candidate when present -- a pass told to use a
particular stash must fail rather than quietly exercise a different one.
Otherwise every address the framework can find for the area
(Get-ExtensionHostAddress -HostType 'stash-service') is tried in order
and the first that answers /healthz wins: an operator pin for the area,
a stash VM on THIS host at its current address, and the address the pool
reports for a stash running on another host entirely. The pool answer is
what keeps a lab working after its stash is rebuilt onto a new IP -- the
service announces itself, and this host reads that back.

Both the discovery and the probe are re-asked over a short backoff
rather than answered once. A host whose link is briefly away -- a DHCP
renew is enough, even one that hands back the same address -- produces
an empty directory answer and a failed /healthz that are indistinguish-
able from having no stash at all, and this runs before any VM starts,
so a single unlucky instant would end the pass. A stash that is really
absent stays absent for the whole window and still stops it.

Publishing the winner makes every later
${ext:stash-service.ResolveHost(...)} expansion return the address that
was actually verified, instead of each sequence re-probing for a VM this
host may not run and warning when it finds none. Nothing answering
CLEARS the published address, so a pass can never inherit one a previous
cycle proved and this one did not.

Progress is returned as Lines rather than written here: a module
function does not see the caller's script-scoped $InformationPreference,
so printing inside would silently drop the very report an operator needs
when the preflight is what stopped the pass.

<a id="42010605-00ae"></a>

### Stash-service pre-flight shared by the AmisAd entry points that build the topology (test/Initialize-

`amisad.dev/test/AmisAd.StashService.psm1`

A module rather than a dot-sourced helper so both drivers run ONE
implementation: the address a pass uploads its binaries to must not depend
on which entry point started it.

This project states no stash address of its own. A site's stash address is
that site's -- naming one here would leak it and would go stale the first
time the service moved -- so every candidate is either discovered through
the Yuruna framework or stated by the operator, and an environment that can
produce neither has no stash as far as a pass is concerned.

<a id="42010605-00af"></a>

### Refuse concurrent runner

`amisad.dev/test/Clear-Lab.ps1`

Only when run standalone. Inside a runner cycle the orchestration invokes this
as its teardown step (initialize-lab), so the runner IS expected to be live:
$env:YURUNA_CYCLE_CONTEXT -- published by the orchestrator before each step and
inherited by this child pwsh (its absence == standalone; see Get-CycleContext)
-- marks that in-cycle invocation and skips the guard. Absent it, an operator
ran this by hand and the guard still refuses to race an active cycle's VMs.

<a id="42010605-00b0"></a>

### Tear down the AmisAd POC lab to a known-clean host: remove every amisad-* VM (and its storage), then

`amisad.dev/test/Clear-Lab.ps1`

The teardown half of the end-to-end pass (Initialize-Lab.ps1 builds it back
up). Steps, in order:

  1. Assert this host can drive its own hypervisor at all (see PRIVILEGE
     below), so a missing right fails here with the fix rather than
     inside the first removal with the hypervisor's raw message.
  2. Refuse to run if a Yuruna runner owns runner.pid -- it would race the
     live cycle's VMs.
  3. Close lab consoles that would steal GUI keystroke focus (Hyper-V only;
     see Stop-LabConsole).
  4. Hand the whole teardown to the framework's Remove-TestVMFiles.ps1
     with the lab's VM-name prefix.

All VM removal lives in the framework: Remove-TestVMFiles.ps1 enumerates,
force-stops and removes every VM whose name starts with the prefix, then
runs the orphaned-file sweep, and it exits non-zero when anything
survived. That single path is exercised by every project on every host
type, so this project keeps no VM list and no removal logic of its own --
a teardown bug gets fixed once, in the framework, for all of them.

PRIVILEGE is asserted at runtime against the DETECTED host rather than
declared with '#requires -RunAsAdministrator': what removing a VM takes
differs per host -- Administrator on Hyper-V, libvirt group membership on
KVM, the invoking user's own utmctl session on UTM -- and a static
requirement reads as "root" on Linux/macOS, which would refuse exactly the
hosts this script claims to run on. Test-HostRequirement asks the host
driver what applies and explains what is missing.

<a id="42010605-00b1"></a>

### Authorize demo public key

`amisad.dev/test/Initialize-Lab.ps1`

vm-core generated the keypair during its deploy, after the edges were built, so
the edges could not be given the key when they were provisioned. Only the PUBLIC
half moves, read out of vm-core and written into each edge's authorized_keys
over the harness SSH channel (the one every other guest action uses); the
private half stays in vm-core, and nothing about the key touches the status
service's HTTP. The login is then proved from vm-core, for the same reason the
edges' IP reports are awaited above: a scenario cannot report a missing trust
usefully, only fail at its first ssh to an edge.

<a id="42010605-00b2"></a>

### Where a stage's stdout/stderr are written. A stage log is the only record of the provisioning half o

`amisad.dev/test/Initialize-Lab.ps1`

Where a stage's stdout/stderr are written. A stage log is the only
record of the provisioning half of that stage -- base-image check, VM
creation, first boot -- because the sequence transcript a guest run
writes begins at the sequence banner, after all of it. That evidence
decides guest-side boot and media failures, so it has to survive to
wherever the cycle's artifacts are read: a system temp dir is not part
of what an operator ships when a cycle fails, and is the first thing
gone when the machine reboots.

The cycle folder comes from the YURUNA_CYCLE_CONTEXT handle the
framework publishes to the child processes of a host action; its
absence means this is a standalone run with no cycle to write into, so
the temp dir stands as the fallback. The cycle's own manifest
enumerates the folder recursively, so nothing has to be registered.

<a id="42010605-00b3"></a>

### Build + start the AmisAd POC topology on a clean host (the "warm-up" half of the end-to-end pass; Cl

`amisad.dev/test/Initialize-Lab.ps1`

Ports the build stages of poc/build/run-tests.ps1 (everything except the
scenario loop, which the amisad.end-to-end.yml orchestration sequence drives).
Assumes the host is already clean (Clear-Lab.ps1 ran) and <RepoRoot>/project
is already cloned (Debug-TestSequence, running the orchestration sequence, clones
once, so guest builds run with -NoProjectClone). Stages, in order:

  0. Delete a demo private key that sits in the status service's served
     tree (it is exposed; vm-core generates its own pair and keeps the
     private half).
  1. Resolve the stash service and publish its address for the cycle
     (discovered or pinned; no stash found stops the pass immediately).
  2. Build once: compile + upload binaries to the stash (amisad-build).
  3. Edge VMs: provision + snapshot amisad-edge-a / -b, shrink to 4GB.
  4. vm-core: k8s + PostgreSQL + NATS + deploy 10 services + demo users,
     including the core->edge demo keypair (generated inside vm-core).
  5. Start both edges and wait for their boot-time IP reports (the fresh
     handoff/*.ip.txt the scenarios resolve the edge from).
  6. Authorize the PUBLIC half of vm-core's demo key on both edges over
     the harness SSH channel, and prove vm-core can log in to each.

Leaves amisad-core + both edges live.

PRIVILEGE is asserted at runtime against the DETECTED host rather than
declared with '#requires -RunAsAdministrator': what building a VM takes
differs per host -- Administrator on Hyper-V, libvirt group membership on
KVM, the invoking user's own utmctl session on UTM -- and a static
requirement reads as "root" on Linux/macOS, which would refuse exactly the
hosts this script claims to run on. Test-HostRequirement asks the host
driver what applies and explains what is missing.

PORTABILITY. VM lifecycle goes through the Yuruna host contract
(Get-VMState / Start-VM / Stop-VMForce, loaded by Initialize-AmisAdHost),
so no step names a hypervisor. Two Hyper-V-specific TUNINGS remain, each
guarded and each a no-op elsewhere by design rather than omission:

  * Install-media stripping + checkpoint retake. A renamed/restored Hyper-V
    VM keeps ABSOLUTE references into the autoinstall DVD dir; later cycles
    overwrite it with files ACL'd to a newer VM and the older VM then fails
    to start with 0x80070005. KVM and UTM attach the cloud-init seed by
    path per boot with no ACL inheritance, so there is nothing to strip.
  * The 4GB edge shrink. Hyper-V has a live Set-VM; on KVM/UTM the guest
    size is a provisioning-time property (the sequence's memoryStartupBytes
    variable), so it cannot -- and need not -- be changed after the fact.

<a id="42010605-00b4"></a>

### Resolved relative to this file's folder (test/), run in order; the pass stops if either script exits

`amisad.dev/test/initialize-lab.yml`

Resolved relative to this file's folder (test/), run in order; the pass
stops if either script exits non-zero.

elevated: true is the orchestrator's Windows-side pre-check -- it refuses
an unelevated shell before spawning the child pwsh, so a Hyper-V operator
is told at once rather than after the first VM call fails. It is a no-op
on KVM/UTM by design (elevation there means sudo/polkit, not an
Administrator token): each script asserts what its OWN detected host
actually requires via Test-HostRequirement.

<a id="42010605-00b5"></a>

### Authorize demo public key

`amisad.dev/poc/build/run-tests.ps1`

amisad-core generated the keypair during its deploy, after the edges were built,
so only now can the edges be given it. Only the PUBLIC half moves, read out of
amisad-core and written into each edge's authorized_keys over the harness SSH
channel; the private half stays in amisad-core. The login is proved from
amisad-core so a missing trust stops the run here, not at the first scenario's
ssh to an edge.

<a id="42010605-00b6"></a>

### Clean start

`amisad.dev/poc/build/run-tests.ps1`

The whole sweep is the framework's: Remove-TestVMFiles.ps1 enumerates,
force-stops and removes every VM whose name starts with one of the prefixes
through the host contract, then runs the orphaned-file sweep that clears the
leftover per-VM storage dirs an unregister leaves behind (a stranded dir would
make the next chain's saveDiskSnapshot rename collide). Current 'amisad-' and
legacy 'amisad.' cover the topology; 'test-' covers the framework's transient
provisioning VMs. Keeping no VM list and no removal logic here means a
teardown bug gets fixed once, in the framework, for every host type.

<a id="42010605-00b7"></a>

### AmisAd POC test automation driver: builds the design topology and runs every scenario against a shar

`amisad.dev/poc/build/run-tests.ps1`

On fail the run stops with everything left up for debugging; green leaves
amisad-core + both edges live as the demo environment. Stage logs land
under -LogDir.

PORTABILITY. VM lifecycle goes through the Yuruna host contract
(Get-VMState / Start-VM / Stop-VMForce, loaded by Initialize-AmisAdHost)
and the clean-start sweep goes through the framework's
Remove-TestVMFiles.ps1, so no stage names a hypervisor. Two Hyper-V-
specific TUNINGS remain, each guarded and each a no-op elsewhere by design
rather than omission:

  * Install-media stripping + checkpoint retake. A renamed/restored Hyper-V
    VM keeps ABSOLUTE references into the autoinstall DVD dir; later cycles
    overwrite it with files ACL'd to a newer VM and the older VM then fails
    to start with 0x80070005. KVM and UTM attach the cloud-init seed by
    path per boot with no ACL inheritance, so there is nothing to strip.
  * The 4GB edge shrink. Hyper-V has a live Set-VM; on KVM/UTM the guest
    size is a provisioning-time property (the sequence's memoryStartupBytes
    variable), so it cannot -- and need not -- be changed after the fact.

ELEVATION is asserted at runtime against the DETECTED host rather than
declared with '#requires -RunAsAdministrator': only host.windows.hyper-v
registers RequiresElevation, and a static requirement would demand root on
KVM/UTM, where the framework deliberately uses libvirt group membership and
the invoking user's utmctl session instead.

<a id="42010605-0007"></a>

## AmisAd guest readiness and scenarios

<a id="42010605-00b9"></a>

###  AmisAd POC - vm-edge-a (region A slice VM): install a boot-time IP reporter (posts <hostname>.ip.tx

`amisad.dev/poc/test/workload.guest.ubuntu.server.24.amisad-edge-a.baseline.yml`

AmisAd POC - vm-edge-a (region A slice VM): install a boot-time IP reporter
(posts <hostname>.ip.txt to the host status service) so amisad-core can locate
this edge. Snapshotted as "amisad-edge-a"; slice-runtime itself is delivered
per scenario run. The core->edge demo key is not installed here: vm-core
generates it after the edges exist, and the lab driver authorizes its public
half on this VM over the harness SSH channel (poc/usernames.md).

<a id="42010605-00ba"></a>

### The snapshot carries deployment and pod status frozen at snapshot time, so every readiness signal in

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.ready.sh`

The snapshot carries deployment and pod status frozen at snapshot time, so
every readiness signal in it describes containers the reboot has already
replaced. Waiting on that status can pass while the pod network is still
moving, and a NodePort rule still pointing at a departed pod answers the next
dial with "No route to host". Restarting first is what makes the wait mean
something: rollout status then reports against a generation created after
this restore, so it completes only once pods that exist NOW are ready and the
endpoints behind those rules are theirs. Peers are addressed by cluster DNS
name, so CoreDNS has to answer from live pods as well; both restarts are
issued before either is awaited so the two roll in parallel.

<a id="42010605-00bb"></a>

### AmisAd POC - s001.fulfillment run on amisad-core: start slice-runtime on the real edge (amisad-edge-

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s001.fulfillment.sh`

AmisAd POC - s001.fulfillment run on amisad-core: start slice-runtime on
the real edge (amisad-edge-a, resolved via its status-service IP report),
seed Elena's offers, drive Maya's auto-close happy path, and assert the FULL
Target Verification Point. The ten services are already deployed (amisad-core
snapshot); the prebuilt binaries are on disk from the deploy step.
EDGE_HOST (optional override): ssh target for slice-runtime; unset -> resolve
amisad-edge-a; unresolved requires AMISAD_ALLOW_SINGLE_VM=1 for local execution.

<a id="42010605-00bc"></a>

### AmisAd POC - s002.fitting run against the deployed amisad-core cluster: start slice-runtime, seed El

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s002.fitting.sh`

AmisAd POC - s002.fitting run against the deployed amisad-core cluster:
start slice-runtime, seed Elena's dresses (one dusty blue) + a second seller's
out-of-range/past-deadline offers + fitting slots, drive Maya's MANUAL-policy
dress need, and assert the FULL Target Verification Point: shortlist honors
every constraint incl. exclusions; nothing commits before the explicit
booking; buyer and seller hold consistent identity-free appointment records;
notification log length is exactly two.

<a id="42010605-00bd"></a>

### AmisAd POC - s003.silence run on amisad-core: consent revocation and the right to silence. Seed one

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s003.silence.sh`

AmisAd POC - s003.silence run on amisad-core: consent revocation and the
right to silence. Seed one in-flight order and two open needs, pause
participation (consent ledger revocation), prove a perfectly fitting new
offer produces NOTHING (no environment, no match, no notification), settle
the pre-revocation order normally, withdraw (aggregation loses her
contribution), resume (open needs served again immediately), and assert the
FULL Target Verification Point incl. the immutable grant-revoke-regrant
history. EDGE_HOST (optional override): ssh target for slice-runtime.

<a id="42010605-00be"></a>

### AmisAd POC - s004.failover run on amisad-core: sovereign slice allocation, isolation fault, attested

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s004.failover.sh`

AmisAd POC - s004.failover run on amisad-core: sovereign slice
allocation, isolation fault, attested failover. Both edges run
slice-runtime with their region identity; Tom's policy pins the restricted
jurisdiction to region-a although region-b is roomier; two injected
isolation faults abort two environments SAFELY (attested abort with reason,
before the envelope is ever opened); the fabric's automatic retry completes
the match with exactly one settlement; both incidents queue for Tom, and
the systemic pattern escalates to Priya's cross-party platform case.
This scenario REQUIRES both edges - there is no degraded fallback.

<a id="42010605-00bf"></a>

### AmisAd POC - s005.attribution run on amisad-core: campaign-boosted match, edge creative serving, and

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s005.attribution.sh`

AmisAd POC - s005.attribution run on amisad-core: campaign-boosted match,
edge creative serving, and attribution credit. Marcel creates a campaign and
brief; Kai produces an approved asset; Marcel activates it; Maya's need in
the campaign category matches Elena's offer boosted with Kai's creative
(rendered INSIDE the sealed environment); on accept the settlement carries
non-zero agency + creator credit; the campaign budget decrements by the
per-match commitment; and no buyer signal appears on the campaign side.
EDGE_HOST (optional override): ssh target for slice-runtime.

<a id="42010605-00c0"></a>

### AmisAd POC - s006.mandate run on amisad-core: delegated procurement under a scoped mandate. Maya gra

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s006.mandate.sh`

AmisAd POC - s006.mandate run on amisad-core: delegated procurement under a
scoped mandate. Maya grants Pat a household-goods mandate with a per-item
cap; Pat closes an in-scope under-cap match on his own authority (dual
attribution on Maya's trail); an over-cap match is HELD until Maya approves;
an out-of-scope need is refused at submission with zero environments and
zero ledger entries; revocation removes delegated authority immediately.
EDGE_HOST (optional override): ssh target for slice-runtime.

<a id="42010605-00c1"></a>

### AmisAd POC - s007.inventory run on amisad-core: enterprise integration onboarding and inventory-trut

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s007.inventory.sh`

AmisAd POC - s007.inventory run on amisad-core: enterprise integration
onboarding and inventory-truth matching. Alex registers + certifies a
connector; Elena grants scoped credentials; the connector syncs the ERP
catalog and an inventory delta that zeroes the last unit of one item; a
buyer need then matches only the in-stock alternative; order-lifecycle
events mirror to the ERP idempotently; an out-of-scope call is refused and
logged; and revocation kills the credentials. EDGE_HOST (optional override).

<a id="42010605-00c2"></a>

### AmisAd POC - s008.mediation run on amisad-core: zero-knowledge dispute mediation and settlement adju

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s008.mediation.sh`

AmisAd POC - s008.mediation run on amisad-core: zero-knowledge dispute
mediation and settlement adjustment. From a settled order, Maya reports
non-delivery; a support case opens carrying operational metadata only (no
buyer identity); Sam requests and Maya grants a scoped, time-boxed
disclosure; the refund posts as compensating settlement entries referencing
the case (original history untouched); and after the grant expires the
disclosed artifact is no longer accessible. EDGE_HOST (optional override).

<a id="42010605-00c3"></a>

### AmisAd POC - s009.suppression run on amisad-core: aggregate insight publication and the demand-plann

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s009.suppression.sh`

AmisAd POC - s009.suppression run on amisad-core: aggregate insight
publication and the demand-planning loop. Seed demand across a high-volume
region (above the anonymity threshold) and a below-threshold region; prove
the below-threshold region is SUPPRESSED (absent, not zeroed) from Dana's
workbench, the published versioned outlook, and Elena's seller +
Marcel's ads views - which carry identical figures. No edge/matching.

<a id="42010605-00c4"></a>

### AmisAd POC - s010.certification run on amisad-core: independent certification of the full evidence t

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s010.certification.sh`

AmisAd POC - s010.certification run on amisad-core: independent certification
of the full evidence trail. Because each scenario restores a fresh snapshot,
this run SELF-SEEDS a representative corpus exercising all four audit
dimensions - a completed match plus an injected abort (attestation +
residency), consent grant/revoke and a mandate (consent, all grant types),
and a disclosure grant + settlement adjustment (consent + settlement
conservation) - then Ingrid's audit-svc independently re-verifies the hash
chains, localizes a deliberate tamper, and proves it only ever read.
EDGE_HOST (optional override): ssh target for slice-runtime.

<a id="42010605-00c5"></a>

### AmisAd POC - vm-core demo users: add the non-administrator persona accounts (maya, elena buyers/sell

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.users.sh`

AmisAd POC - vm-core demo users: add the non-administrator persona accounts
(maya, elena buyers/sellers; tom, priya operators; marcel, kai ad agency +
creator - s005; pat delegate - s006; alex integration partner - s007; sam
support - s008; dana analyst - s009; ingrid auditor - s010) and
generate the core->edge demo SSH keypair for the admin so scenario scripts
can scp/ssh slice-runtime to the edge VMs. The keypair is created HERE and the
private key never leaves this VM: it is not fetched from, or uploaded to, the
host status service (which serves its files to the whole LAN). Only the public
half crosses to the edges, carried by the host over the harness SSH channel
once both exist (test/AmisAd.Lab.psm1 Sync-AmisAdDemoKey). Passwords are set by
a separate sensitive sshExec sequence step (vault-rendered, masked), never
passed to this script. Runs as the admin (passwordless sudo).

<a id="42010605-00c6"></a>

### Boot-only reporting publishes the address this VM had when it started, and amisad-core reads that fi

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-edge.setup.sh`

Boot-only reporting publishes the address this VM had when it started, and
amisad-core reads that file to find the edge for the whole cycle. Under a
short DHCP lease neither end stays put for a cycle, so a report that is never
repeated is a report that goes stale and strands the scenario -- which
refuses to degrade to a single-VM run rather than quietly pretending it
passed. Re-reporting is one small PUT; the interval is well inside the gap
between a renumber and the next scenario needing the address.

<a id="42010605-00c7"></a>

### AmisAd POC - edge VM setup (shared by amisad-edge-a/b): install a boot-time IP reporter that posts <

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-edge.setup.sh`

AmisAd POC - edge VM setup (shared by amisad-edge-a/b): install a boot-time IP
reporter that posts <hostname>.ip.txt to the host status service so
amisad-core can locate this edge. The slice runtime itself is delivered per
scenario run - the edge VM stays stateless.

The core->edge demo key is NOT installed here. vm-core generates that keypair
(after the edges are built) and keeps the private half; the host then
authorizes the PUBLIC half in this VM's authorized_keys over the harness SSH
channel (test/AmisAd.Lab.psm1 Sync-AmisAdDemoKey). Nothing about the key is
fetched over the status service's HTTP, where an answer from anything on the
LAN would be believed.

<a id="42010605-0008"></a>

## Verified downloads and stash delivery

The three `amisad_host_fetch` copies re-read the host coordinates per attempt.
A forced resolver failure stops the retry and keeps its stderr in the guest log;
it must not retry an old coordinate while hiding the failure to discover a new one.

<a id="42010605-00c9"></a>

### The stash records the upload (username=amisad-poc, filename=amisad-<arch>-binaries.tgz) for later in

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-build.compile.sh`

The stash records the upload (username=amisad-poc, filename=amisad-<arch>-binaries.tgz)
for later investigation; amisad-core locates it by that label. scp only (the
stash SSH server accepts the drop); no key needed - it is a write-only sink.
STASH_HOST was reachable at the preflight above, which is weaker than it
sounds: that was an HTTP GET, not this transfer.

Bounded retry, in the shape amisad_host_fetch above already uses. Every way
this drop can fail reaches the client as scp's generic "lost connection" --
the server closes the channel without stating a reason, so a transport drop
and a server-side refusal of the upload are indistinguishable from here.
A retry is the right answer to both: it gets a fresh connection, and the
server allocates a fresh identifier for the new session. Bounded at three so
a sink that is genuinely gone still fails the step instead of looping.

scp's stderr is captured per attempt and replayed under the attempt label
because the cycle transcript interleaves several guests: a bare
"lost connection" in that stream cannot be traced to the attempt that
emitted it, and a silent retry reads as a hang.

<a id="42010605-00ca"></a>

### What this establishes: the address is populated and the host answers on the bridged LAN from this gu

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-build.compile.sh`

What this establishes: the address is populated and the host answers on the
bridged LAN from this guest's NAT. That is the failure worth catching before
a ~20-minute build -- a wrong or unroutable address costs the whole build.
What it does NOT establish: /healthz is served by the HTTP listener alone and
says nothing about sshd on :22, the share the drop lands on, or the metadata
index that records it. A few-byte GET is also nowhere near a multi-megabyte
transfer. A green probe here still leaves the upload able to fail, which is
why the upload carries its own retry rather than trusting this result.
No default address: the caller supplies one it already verified, and guessing
here would send a build's binaries at whatever answers on someone's network.

<a id="42010605-00cb"></a>

### amisad_sha256

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-build.compile.sh`

fetch-and-execute verified THIS script against a SHA-256 the host typed into
the launch command. Whatever this script downloads and then extracts, installs
or feeds to a program is a plain HTTP answer from a LAN service, so it is
checked here against a SHA-256 carried by the same launch command (the
sequence's command: text, filled in by ${ext:digest....} on the host) BEFORE
it is used. The digest is the trust boundary; the transport is not. An empty
digest refuses the download; AMISAD_ALLOW_UNVERIFIED=1 is the loud override
for a hand run, and no sequence sets it. poc/test/download_contracts.py holds the
three copies equal.

<a id="42010605-00cc"></a>

### AmisAd POC - amisad-build compile step: build every release binary and upload the tarball to the sta

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-build.compile.sh`

AmisAd POC - amisad-build compile step: build every release binary and
upload the tarball to the stash service, for amisad-core to download and
deploy. This VM has the Rust toolchain but no Kubernetes; it produces
artifacts, it does not run them. STASH_HOST: the stash service the binaries
are dropped into. REQUIRED, and with no default -- the sequence supplies it
from ${ext:stash-service.ResolveHost(...)}, which returns the address the
cycle's warm-up resolved and confirmed answers /healthz. A run that reaches
this script with no published address stops immediately rather than shipping
a build's binaries at a guessed host.
AMISAD_PROJECT_ARCHIVE_SHA256: the SHA-256 of the project tarball this script
downloads and builds. The sequence supplies it from ${ext:digest.GetArchiveSha256(project)};
the tarball is verified before it is extracted (see poc/test.md "Verified
nested downloads"). AMISAD_ALLOW_UNVERIFIED=1 waives an absent digest for a
hand run.

<a id="42010605-00cd"></a>

### Retried for the same reason the rustup install above is: a single "empty reply from server" through

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-build.tools.sh`

Retried for the same reason the rustup install above is: a single "empty
reply from server" through the lab proxy -- a transient the lab does
produce -- would exit the script under `set -e` and cost the whole cycle,
after rust had already installed cleanly.

The fetch is unprivileged and the install is the only privileged step. sudo
inside the retried unit would put the privilege where the retry cannot see
whether it was the download or the elevation that failed, and curl writing
straight to /usr/local/bin leaves a truncated binary on a partial transfer.

bazelisk is pinned to a release, not to whatever "latest" is on the day of the
run, because an executable installed as root is only worth checking if there
is one file to check it against. Bump the version and both digests together;
the release page lists each asset's SHA-256. The download sits in a private
directory so no other local user can swap it between the check and the install.

<a id="42010605-00ce"></a>

### amisad_verify_pinned

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-build.tools.sh`

rustup-init, bazelisk and the NATS server are downloaded from their publishers
and then executed or installed as root, so each is checked against a SHA-256
pinned in THIS script before use. The pins are the publishers' own values (the
.sha256 file beside each rustup-init, the digest on each bazelisk release
asset, the release's SHA256SUMS for NATS), recorded when the version was
chosen. They live in a script that fetch-and-execute verified against the
digest the host typed into the launch command, so they are as trustworthy as
the script. A mismatch deletes the download, so a retried unit fetches afresh.

<a id="42010605-00cf"></a>

### AmisAd POC - create the amisad database, load the schema, and open the instance to in-cluster pods:

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.db.sh`

AmisAd POC - create the amisad database, load the schema, and open the
instance to in-cluster pods: role 'amisad' (fixed lab password, rides in
DATABASE_URL - see poc/test.md), listen_addresses '*', pg_hba for the pod
and node networks. The role gets NO UPDATE/DELETE on ledger tables - the
database itself enforces append-only. The schema is fetched from the host
status service into a private directory and fed to psql on stdin, because the
postgres user cannot read the login user's 0750 home and a world-readable
copy in /tmp could be swapped after its digest was checked.
AMISAD_SCHEMA_SHA256: the SHA-256 of poc/db/schema.sql as the host serves it.
The sequence supplies it from ${ext:digest.GetFileSha256(project/poc/db/schema.sql)};
the schema runs as the postgres superuser, so it is verified before psql sees
a byte of it (see poc/test.md "Verified nested downloads").
AMISAD_ALLOW_UNVERIFIED=1 waives an absent digest for a hand run.

<a id="42010605-00d0"></a>

### `wait` reports only that the condition never arrived, so on its own a failure here says a deployment

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.deploy.sh`

`wait` reports only that the condition never arrived, so on its own a
failure here says a deployment is stuck and nothing about why -- and the
VM is torn down before anyone can look. Dump what the cluster already
knows: the pod phase, the scheduling/pull events, and whatever the
container wrote before dying are each enough to name the cause on their
own. Every probe is best-effort; the exit below is the real result.

<a id="42010605-00d1"></a>

### --noproxy '*': the stash IP is not in the guest no_proxy list, so an HTTP GET would otherwise be sen

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.deploy.sh`

--noproxy '*': the stash IP is not in the guest no_proxy list, so an HTTP GET
would otherwise be sent through squid. The label carries the architecture
(amisad-<arch>-binaries; see poc/test.md "Stash artifact naming"): match our
own uname -m and nothing else. /api/stashes returns newest-first, and the
build this pass made is the newest upload under that label unless another
pass or host uploaded since; amisad_fetch_stash_binaries picks it by digest.
No default address: the caller supplies one it already verified, and guessing
here would pull executables from whatever answers on someone's network.

<a id="42010605-00d2"></a>

### amisad_fetch_stash_binaries

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.deploy.sh`

amisad_fetch_stash_binaries <stash base url> <label> <dest file>
Fetches the newest stash upload under <label> whose SHA-256 is the one the host
read from the build VM (AMISAD_BINARIES_SHA256), looking back through the ten
newest: the stash is shared by the whole lab, so another pass or host may have
uploaded the same label since this pass's build. Returns 3 when the stash lists
nothing for the label and 7 when no upload verifies. With no digest set, only
the newest is a candidate and amisad_verify_download decides whether it may be
used at all.

<a id="42010605-00d3"></a>

### AmisAd POC - amisad-core deploy step: download the prebuilt binaries from the stash service (produce

`amisad.dev/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.deploy.sh`

AmisAd POC - amisad-core deploy step: download the prebuilt binaries from the
stash service (produced by amisad-build), build thin distroless images from
them, and deploy the ten services to the in-VM Kubernetes cluster. This VM has
the runtime stack (Docker+containerd+kubeadm K8s+Helm+PostgreSQL+NATS from the
amisad-core-k8s baseline) plus python3 - but NO Rust toolchain and no source build.
STASH_HOST: the stash service to pull binaries from. REQUIRED, and with no
default -- the sequence supplies it from ${ext:stash-service.ResolveHost(...)},
which returns the address the cycle's warm-up resolved and confirmed answers
/healthz. A run that reaches this script with no published address stops
immediately rather than fetching executables from a guessed host.
AMISAD_PROJECT_ARCHIVE_SHA256 and AMISAD_BINARIES_SHA256: the SHA-256 of the
project tarball and of the binaries tarball this script downloads and then
extracts. The sequence supplies the first from ${ext:digest.GetArchiveSha256(project)}
and the second from ${ext:digest.GetPublishedSha256(amisad-binaries)} (the
digest the host read from the build VM after it uploaded); each download is
verified before it is extracted, and the binaries run in pods as root, which
is why that one matters most (see poc/test.md "Verified nested downloads").
AMISAD_ALLOW_UNVERIFIED=1 waives an absent digest for a hand run.

<a id="42010605-0009"></a>

## Demo credentials and request serving

<a id="42010605-00d5"></a>

### The vault passwords are the one thing here that must not travel further than the operator intends, s

`amisad.dev/poc/demo/data-view/serve-data-view.ps1`

The vault passwords are the one thing here that must not travel further than
the operator intends, so they are gated per REQUEST, not per binding: opening
the console to the network still leaves the host's own browser fully
featured, and remote viewers see the cards without the secrets.
The journal: append-only in memory, monotonic sequence. Clients poll with the
highest seq they hold; a 'latest' lower than that tells them this process
restarted and their view must be rebuilt from scratch.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.
