<a id="4213a0b3-0001"></a>

# Framework implementation notes

These notes retain the rationale linked from shared automation and test-runner
sources. Follow the source-consistency contract when changing corresponding blocks.

<a id="4213a0b3-0002"></a>

## automation/Check-DependencyVersion.ps1: Host-tool floors from Yuruna.Requirement.yml

Host-tool floors from Yuruna.Requirement.yml. These are the versions a host is
probed against, not versions anything installs, so upstream moving ahead is
informational: it never fails the run. Without them nothing watches the host
side at all, and a floor can trail for months unnoticed.

Only tools with an unambiguous upstream release feed are listed. Docker and
Docker buildx are deliberately absent: both track what Docker Desktop bundles
rather than the newest upstream tag, so comparing them to upstream would report
drift on a correctly provisioned machine every time.

<a id="4213a0b3-0003"></a>

## automation/Set-HostAlias.ps1: 2. Elevation / root assertion

Writing the file is not the end of the change. The operating system
resolves names out of an in-memory cache that goes on answering with the
PREVIOUS address after the hosts-file line under it has changed, and on
macOS that window is wide enough to matter: mDNSResponder re-reads
/etc/hosts on a schedule of its own, so a consumer that resolves within a
few hundred milliseconds of the write still reaches the old host.

The damage is worst for exactly the edit this script exists to make --
repointing a name from another machine to this one. The caller believes it
is dialing a local service; the connection instead leaves over the LAN to
the machine the name USED to mean, and fails there against a credential,
a share, or a certificate that only makes sense locally. Every visible
detail (hostname, share path, account, mount point) is correct while that
happens, which is what makes it so hard to read backwards from the error.

Best-effort by design, and never fatal: a cache that cannot be flushed is
slow to converge rather than broken, and a host with no caching resolver
at all (common on Linux) has nothing to flush. The write has already
succeeded by the time this runs, so nothing here may fail it.

<a id="4213a0b3-0004"></a>

## automation/windows-guest-bootstrap.ps1: git does NOT read GH_TOKEN -- that name is a gh(1) convention -- so the token

git does NOT read GH_TOKEN -- that name is a gh(1) convention -- so the token
alone leaves a private-repo `git clone` prompting for a username, which hangs
an unattended guest. GIT_ASKPASS is what makes clone/fetch/pull authenticate
with no change at any call site; the .cmd shim exists only because GIT_ASKPASS
must name an executable, not a PowerShell function.

This half is gated and the coordinate work above is not, in that order: a lab
with no token configured is exactly the lab whose guests most need to be able
to reach their host.
Suppress the prompt BEFORE the token gate, never after it. Windows is the
worst platform to get this wrong on: Git Credential Manager answers a missing
credential with a GUI dialog, which the OCR that drives this guest cannot read
at all -- so the step times out on a screenshot that shows nothing wrong.
Machine scope for the same reason the token uses it below: a non-interactive
SSH command reads no profile.

<a id="4213a0b3-0005"></a>

## automation/yuruna-host-locate.ps1: How hard to press the directory once the baked coordinate is dead

How hard to press the directory once the baked coordinate is dead. The
directory learns the host's new address from the host itself, so a guest
that starts resolving at the moment of a renumber can be told the address
that just died -- both ends are racing the same change. Spacing a few
re-asks over roughly ten seconds covers that gap, against a cycle that
otherwise ends. The names and defaults are the shell library's, so one
override drives both peers; a value that is not a whole number is ignored
rather than raised, because nothing in this file may throw at its caller.

<a id="4213a0b3-0006"></a>

## automation/yuruna-host-locate.ps1: Invoke-YurunaHostLocate

The directory learns a new address from the host, so asking the instant
the host renumbers returns the address that just died -- the guest and
the directory are racing the same change. One shot loses that race and
sends the caller to a fallback that cannot help it. Re-ask a few times
instead, spaced so the directory has time to catch up. This costs
nothing on the common path: the baked coordinate answered its livecheck
above and returned before reaching here, so the only callers that pay
are the ones already out of other options.

<a id="4213a0b3-0007"></a>

## automation/Yuruna.Clear.psm1: Clear-Configuration

Teardown reads resources.output.yml (the deployed-state manifest, gated by
Test-Path below) and destroys from the deployed .yuruna work folders -- NOT
the forward resources.yml and its referenced template folders. Blocking
destroy on forward validation would let post-deploy source drift (a
template folder renamed/deleted, a variable now expanding empty) strand the
operator with resources they cannot destroy, defeating idempotent cleanup;
so the forward check is only a warning here, and the resources.output.yml
gate below is the real precondition.

<a id="4213a0b3-0008"></a>

## automation/Yuruna.Clear.psm1: Clear-Configuration

The deployed resource names are the top-level keys of resources.output.yml
other than globalVariables: Set-Resource writes that map plus one
`<resourceName>: <tofu outputs>` block before applying each owned resource.
There is no `resources:` list here -- that shape belongs to the forward
resources.yml, and reading it would silently find nothing and report a
successful teardown that destroyed no resource. Two properties of the key
set matter: a resource declared with an empty template is never written
here (it only names an already-existing resource and owns no work folder),
so the keys include partial applies that still need teardown; and the keys are
already variable-expanded, matching the .yuruna work folder names verbatim,
so they must not be expanded a second time.

<a id="4213a0b3-0009"></a>

## automation/Yuruna.CloudInitTemplate.psm1: New-CloudInitUserData

The two identities that let a guest repair a host address that has gone
stale. Defaulted here rather than per-caller for the same reason the
script bodies are: every seed wants the identical answer, and a
per-caller copy is a per-caller chance to seed a guest that cannot find
its way home. A caller with a better answer still wins -- the
service-VM seeds pass a hostId they already resolved.

Both are read from the ambient environment rather than resolved through
the harness modules that own them, keeping this leaf dependency-free
(the same soft, call-time convention Get-PortMapStatePath documents).
Empty is a supported outcome, not a failure: a lab with no pool
directory seeds empty values and its guests behave exactly as they did
before this indirection existed.

<a id="4213a0b3-000a"></a>

## automation/Yuruna.Common.psm1: Get-ServiceVmMemoryVerdict

What this operator can actually change, taken from the plan itself. A lever
that does not apply to the run in front of them costs the whole sentence its
credibility: a lab may not set storage.kind = none -- the stash and the
intent store both need the shares -- so a lab is never offered it.

Read off EVERY planned row, not only the sized ones: a service whose builder
could not be read is still a service this run starts, and still a service the
operator can decline.

<a id="4213a0b3-000b"></a>

## automation/Yuruna.Common.psm1: Invoke-BoundedNativeCommand

Both streams and the exit signal are pumped from this one thread via
WaitAny, never a background thread: PowerShell scriptblocks are
runspace-affinitized and cannot safely run on an arbitrary .NET
thread-pool thread the way a raw Task.Run delegate would need to.
Task.WaitAny below never blocks past the millisecond count it is given,
and only a task that call has already confirmed finished ever has its
GetAwaiter().GetResult() (equivalently .Result) read; reading an
unfinished task's result would block this thread for as long as a
descendant holds the pipe.

<a id="4213a0b3-000c"></a>

## automation/Yuruna.HostRedirect.psm1: Runs a host-specific script from a host-neutral entry point: detect the host,

Runs a host-specific script from a host-neutral entry point: detect the host,
resolve host/<short>/<name>.ps1, and run it in a child pwsh whose working
directory IS that host folder -- the same shell an operator gets by cd'ing
there and calling ./<name>.ps1 by hand. The caller's own location is restored
on the way out.

Host detection is NOT reimplemented here. Get-HostType / Get-HostFolder
(test/modules/Test.HostDetection.psm1) are the one definition the whole
harness resolves against; this module imports them on demand and never keeps
a second copy, because a second copy is a second answer the day a new host
type is added.

Nothing here is specific to the four scripts that use it today: -ScriptName
takes any script that exists in all (or some) of the host folders.

<a id="4213a0b3-000d"></a>

## automation/Yuruna.Log.psm1: The one definition of what a step rule looks like.

The one definition of what a step rule looks like.

The transcript's document outline is built from these lines, and until this
was shared the shape lived twice: once in the orchestrator that writes the
rule and once in a regex here that recovers it. Two copies of a format drift,
and the failure is silent in the worst way -- the transcript still renders,
it has no headings, so a reader navigating tens of kilobytes of one
<pre> loses every landmark and nothing reports a problem.

Recovering structure from rendered text is the weaker half of the answer and
is kept only for the accessibility affordance on the page itself. The
machine-readable outline is emitted as structured events beside the
transcript, where a consumer never has to read prose at all.

<a id="4213a0b3-000e"></a>

## automation/Yuruna.Log.psm1: Write-Error

Splat the caller's own bound parameters straight through. This proxy's
parameter sets mirror Write-Error's (NoException = Message,
WithException = Exception [+ optional Message]), so $PSBoundParameters
is always a valid Write-Error invocation and never a Message+Exception
combination Write-Error rejects. Copying it preserves
the common parameters (-ErrorAction, -ErrorVariable, ...) that an
explicit per-set reconstruction would silently drop. (There is no
InputObject parameter here to strip -- this is Write-Error, not the
Write-Output proxy.) Supply the effective ErrorAction when omitted.

<a id="4213a0b3-000f"></a>

## automation/Yuruna.Resource.psm1: Publish-ResourceListHelper

Retry on a transient signal only; a real plan or null_resource
provisioner error does not match the shared classifier and fails
fast. docs/architecture.md#shared-transient-failure-retry-policy

The closures capture the command and predicate by value because the
retry scriptblock runs in the Yuruna.Retry module scope, which
cannot see this module's private Invoke-DynamicExpression import
by name -- so capture its CommandInfo here and invoke it via &.

<a id="4213a0b3-0010"></a>

## automation/Yuruna.Retry.psm1: Shared transient-failure classifier: the single source of truth for "is

Shared transient-failure classifier: the single source of truth for "is
this failure worth retrying?" across every network-touching phase.
What each token covers, why a bare 500 is in the list, and the per-phase
gating: docs/architecture.md#shared-transient-failure-retry-policy

Status codes and EOF are matched as word-bounded tokens (\b429\b ... \b504\b,
\bEOF\b) so each matches standing alone in any surrounding context ("HTTP 500",
a bare 500; "unexpected EOF", a trailing ": EOF") while embedded digits
("1500", "2500") and EOF inside an unrelated token (EOFError in a stack trace)
do not.

A refused connection reaches this classifier in two unrelated wordings, and
matching only the Go-runtime one leaves the tool this policy exists to cover
failing fast on the very symptom it is meant to ride out. Go prints the
errno form, "connect: connection refused"; kubectl catches the same errno
and reformats it around the URL's host -- "The connection to the server
<host> was refused - did you specify the right host or port?" -- which shares
no contiguous substring with the first. Both name a peer that was not
listening, which is what a restarting proxy or registry looks like.

"server misbehaving" is the Go resolver's wording for an upstream that
answered with neither a record nor a clean NXDOMAIN. It is transient for the
same reason "no such host" beside it is: a resolver that is coming back
answers on a later attempt.

<a id="4213a0b3-0011"></a>

## automation/Yuruna.Validation.psm1: Confirm-WorkloadList

Two workloads sharing a kube context collide: Publish-WorkloadList wipes
.yuruna/<subfolder>/workloads/<context> at the start of EACH workload, so
the second silently clobbers the first's staged charts/values. A chart also
deploys as helm release <installName> into <context>, so two chart
deployments sharing both keys hit the same release and the second upgrades
over the first instead of installing a distinct workload -- caught here as
defense-in-depth (the helm install lands before any folder is reused),
turning a confusing in-cluster overwrite into a clear config error. Reject
raw copy-paste duplicates and post-expansion collisions (distinct raw
values that resolve to the same string), mirroring the resources.yml dedup.

<a id="4213a0b3-0012"></a>

## test/modules/Invoke-PoolStorageDrain.ps1: One-shot poolStorage drain, fired DETACHED by the outer loop at each cycle end

One-shot poolStorage drain, fired DETACHED by the outer loop at each cycle end
(Test.RunnerOuterLoop.psm1) on a host in COPY mode. It drains the backlog of
not-yet-archived cycle folders to the optional SMB share (ypool-nas): fail-fast on
an unreachable NAS, atomic per cycle, single-instance via a lock file the
orchestrator takes. Runs in its own fresh process so a slow/absent NAS never delays
the cycle loop and module imports start from a clean global scope. Env
(YURUNA_CONFIG_PATH / YURUNA_RUNTIME_DIR / YURUNA_LOG_DIR) is inherited from the
spawning runner; HostId is passed in (with a fallback).

A MOVE-mode host does not use this script on the cycle path: the mover has to run
synchronously so its verdict can fail the cycle, so the outer loop calls
Invoke-PoolStorageDrain in-process instead. Run by hand it still works, and honors
whichever mode the config names -- -MoveLogs is resolved from the config here so a
manual run cannot archive under different rules than the runner would.

<a id="4213a0b3-0013"></a>

## test/modules/Invoke-TestCycleRunner.ps1: Host-refresh transport

Invoked without capturing the success stream; the typed outcome is read through
`Get-LastOuterCycleResult`, leaving the cycle's output on the operator's console.
The cycle worker launches the inner with `Process.Start`, inherits the console
without redirecting stdout or stderr, and uses `WaitForExit` to track process exit.

With the earlier call-operator launch, capturing `$result = Invoke-RunnerOuterCycle
...` gave the inner an anonymous stdout pipe. The call operator waited for EOF,
and the status service could hold that pipe open after the inner exited:
`Start-Process -RedirectStandard*` enabled handle inheritance, duplicating the
write end into the service. The Windows symptom was one completed cycle, an
inner log saying "about to exit with code 0", and no subsequent "outer runner back
in control". The POSIX detach replaced those descriptors. The current process
wait does not depend on pipe EOF.

<a id="4213a0b3-0014"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Resolve paths

The Inner-kind module set includes Test.SingleInstance, Test.YurunaDir,
Test.Extension, Test.HostContract, Test.Status, Test.Notify, Test.Provenance,
Test.Start-GuestOS, Test.Start-GuestWorkload, Test.Log, Test.SequencePlanner,
Test.CachingProxyService, Test.Perf, Test.HostIO, Test.Capability and Test.Transport.
One helper loads both the early-bootstrap modules and the per-cycle workhorses,
replacing per-site inline Import-Module lists. Test.Prelude.psm1 defines the
canonical set; the inner loads it once at file top. Each cycle starts a fresh
inner process, so source changes propagate without a mid-cycle refresh loop.

<a id="4213a0b3-0015"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Resolve paths

Defensive: if another Start-TestRunner.ps1 (the outer) is running,
stop it and wipe stranded test VMs. The normal call path is the
outer spawning THIS inner with YURUNA_RUNNER_RELAUNCH=1 -- in which
case this whole block is skipped (the outer owns the pidfile). This
branch only fires when an operator invokes
modules/Invoke-TestRunnerInnerLoop.ps1 directly (which they shouldn't --
it lives under modules/ for that reason, but the guard is the safety net
for when they do).
Shared implementation in Test.SingleInstance.psm1 -- same identity-
probe logic as outer, with the inner-specific cmdline pattern below
(matches only Start-TestRunner.ps1, never a sibling inner). Imported
by the Inner kind at file top.

<a id="4213a0b3-0016"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Inner PID + heartbeat

Companion file to runner.heartbeat. The threadpool-timer-driven
runner.heartbeat is proof of life at the process level but stays
fresh even when the runspace is wedged inside a non-terminating
OCR / SSH loop -- it can't catch in-runspace hangs. runner.stepHeartbeat
is touched from the runspace itself at the top of every
step in Invoke-Sequence; the outer watchdog reads its mtime to
detect a single step that has exceeded testCycle.stepTimeoutSeconds.
Seed here so the first watchdog poll sees a fresh file even before
the first sequence step runs.

<a id="4213a0b3-0017"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Inner PID + heartbeat

inner.pid: atomic temp-file + rename via the shared state-file
helper so a crash mid-write can't leave a truncated PID for the
outer watchdog to misread. UTF-8 no-BOM is correct here:
ASCII-clean digits, and the outer reads via [int]::Parse which
would reject a BOM prefix.
Check the write: a failed inner.pid leaves the inner un-targetable by the
outer's watchdog, so a hung inner would run unguarded. That is a degraded
(unmonitored) run, not a fatal one -- warn and continue. The console
Write-Warning here is only inherited by the outer (the Yuruna.Log Write-Warning
proxy is not imported yet, and the Process.Start spawn does not redirect stderr), so
also mirror it to outer.log via Write-InnerLog where it stays durable and
diagnosable next to the outer/watchdog entries.
The start record goes first, so a reader never pairs a new PID with an old
start time: inner.start + inner.pid are the exact identity a host refresh
checks before it may reclaim this inner.

<a id="4213a0b3-0018"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Inner PID + heartbeat

The cycle worker spawns this inner with `Process.Start` and no standard-stream
redirection, so the inner inherits the launch terminal. Any prompt it raises therefore blocks the entire host until
the watchdog kills it -- and because runner.heartbeat is written by a
threadpool timer that keeps ticking through a blocked runspace, the dashboard
stays GREEN throughout. Neutralize every prompt this process can raise itself.

NOT covered here, deliberately: `sudo` reads /dev/tty, NOT this process's
stdin, so redirecting or closing stdin does not stop a bare `sudo` in a host
driver from prompting. Those call sites move to `sudo -n` behind a shared
wrapper; until they do, the runner.phase bound below is what converts such a
stall into a fast, attributable kill instead of 45 minutes of green silence.

YURUNA_NONINTERACTIVE is normally inherited from the outer; set it here too so
a direct-invoke inner (modules/Invoke-TestRunnerInnerLoop.ps1 run by hand) gets
the same contract rather than a different one that can hang.

<a id="4213a0b3-0019"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: The Inner kind import set covers Test.HostContract, Test.Status, Test.Notify,

The Inner kind import set covers Test.HostContract, Test.Status, Test.Notify,
Test.Provenance, Test.Start-GuestOS, Test.Start-GuestWorkload, Test.Log,
Test.SequencePlanner, Test.CachingProxyService, Test.Perf, Test.HostIO,
Test.Capability, Test.Transport (plus the early-bootstrap imports). The
file-top pass via Initialize-YurunaEntryPointModuleSet -For Inner loads
this set once. The outer dispatches fresh cycle and inner pwsh processes
on every platform, so their module caches reload with each cycle and pick
up source changes without an in-process refresh loop.

<a id="4213a0b3-001a"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Read config (syncs against template first)

One gate, at the front of the cycle, before any host work: the outer runner
gates once at startup, but it then runs cycles for days, so a startup-only
check says nothing about a config -- or a GitHub credential -- that went bad
in hour nine. Validating here means a cycle that cannot succeed is refused
in its first seconds, with Test-Config's FAILURES block naming what to fix,
instead of surfacing later as an opaque step failure partway through the
lab's VM builds.

This is also the ONLY gate the cycle runs. Nested Debug-TestSequence stages
spawned by host actions inherit this verdict rather than re-running the
check per stage: the gate reaches the network, and a remote that stops
answering between two stages would otherwise abort a healthy cycle
mid-flight and discard every stage already built.
A preflight inner skips the gate: the resumed outer ran its startup gate in
the same chain seconds earlier, and the first ordinary cycle gates again.

<a id="4213a0b3-001b"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Held-control barrier

Two cycles on one VM set corrupt each other, so a cycle starts only on a host
it has positively found free of other guests. On some macOS versions
vmnet-shared also puts each vmnet session on a separate host-side bridge
(bridge100, bridge101, ...) that don't route between each other, so a foreign
concurrent VM can split the test guests onto a different bridge from the
host's vmnet gateway and break the cloud-init host-proxy URL baked into
seed.iso.
The admission step stops first and refuses second: a leftover guest from a
cycle that died before its teardown is the common case here, and refusing over
it strands the host, because the sweep that would remove it only runs once a
cycle starts. Service VMs are exempt because the cycle consumes them.
A host that cannot say what is running is refused too: exit "cannot run", with
the reason in vm-admission.json for the outer runner to name.

<a id="4213a0b3-001c"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Concurrent-VM admission

A virtual-switch object outlives its uplink binding across a host reboot, so
the object's survival is not evidence that the bridge still carries traffic:
every guest attaches to a switch with no carrier while the host itself is
online and every other host check passes. Nothing else in the preamble asks
whether a guest created right now could reach anything, so the answer is
named here -- at cycle start -- instead of being inferred from a fleet of
identical guest failures a quarter of an hour later.

Reports; it almost never refuses. A host that still has ANY usable path (a
working External vSwitch, or a Default Switch address -- NAT + DHCP, the
permanent steady state of every Wi-Fi host here) runs the full cycle on the
path it has and PASSES; the notification gate turns a persistent degradation
into one alert per streak rather than one per cycle. Only TOTAL loss, where
every guest is guaranteed to fail identically, can refuse.

Placed after the VM admission so a refusal never strands guests the previous
cycle left running: refusing before the stop leaves the host dirtier than a
normal cycle, and the leftovers are exactly what keeps the condition from
clearing. The refusal path runs the VM sweep for the same reason.

<a id="4213a0b3-001d"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Cycle-start host guest-network gate

host-network.txt is ready-to-embed HTML the status page appends verbatim;
host-network.json is the machine-readable twin Write-HostRegistrationRecord
advertises to the pool. Same observation, two audiences -- so ONE writer owns
both, and it is this gate: the probe above is the only thing that looks at the
host's guest-network state exactly once per cycle, which is what lets a
consecutive-cycle count mean anything.

"File present == degraded, file absent == healthy" is the entire contract, so
recovery DELETES both files. Blanking them leaves a degraded host in every
consumer that only tests for existence.

<a id="4213a0b3-001e"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Degraded-host pair -> runtime/host-network.txt + host-network.json

control.cycle-restart is written by the worker behind the status service's
/control/start-cycle endpoint. The inter-cycle delay loop consumes it on its next tick;
the per-step gate in Test.SequenceEngine.psm1 honors it too. But if a prior
session was killed mid-cycle before consuming the flag (operator Ctrl+C,
outer-runner restart, process crash), the file persists. A freshly
starting inner IS the restart the operator asked for, so consume the
flag here -- otherwise the brand-new cycle's first step would immediately
throw YurunaCycleRestart, mark the cycle failed, and loop until
ConsecutiveCrashes aborts the runner. The flag's job is to wake a
running inner, not to nag a fresh one.
-SkipInteractiveState: the inner's break-active + pause flags are the
parent's to sweep (the outer's boot recovery, or Invoke-TestProject's PreSpawn
handoff). A direct-invoke inner keeps a pause the operator set here, so
the inner never re-sweeps that class.

<a id="4213a0b3-001f"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Stale cycle-restart flag sweep

Re-import Test.CachingProxyService with -Global -Force AFTER Initialize-YurunaHost.
Yuruna.Host.psm1 force-imports Test.CachingProxyService during its
module load; per the eviction pattern,
that nested -Force pulls Test.CachingProxyService out of the global session,
so Invoke-CachingProxyServiceProbe stops resolving from this script even
though the Inner-kind bootstrap import above ran first. -Global -Force
here puts it back; same fix used by Start-StatusService.ps1 immediately
after its own Initialize-YurunaHost.

<a id="4213a0b3-0020"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Stale cycle-restart flag sweep

A host reboot leaves every service VM registered with the hypervisor and
powered OFF, and nothing else in the cycle turns them back on. The two
failures that produces do not look alike: the caching proxy merely degrades to
direct downloads, while the stash service is fatal -- the warm-up resolves it,
finds nothing, and skips every workload stage. So a rebooted host burns cycle
after cycle that cannot pass until an operator starts the VMs by hand.

BEFORE the caching-proxy gate below, so a proxy restarted here is detected by
the very next probe instead of being reported absent for one more cycle. Runs
every cycle rather than only at boot: a service can also be stopped mid-session,
and on a healthy host this costs one state query per service.

Starts only what is already built -- never rebuilds. A rebuild is ~15 minutes
and discards a warm squid cache; a start is seconds and keeps it.

<a id="4213a0b3-0021"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Cycle-start service-VM restore

HERE, and nowhere else in the cycle. A rebind takes carrier from every guest
on the switch and drops host networking on the target NIC for a moment -- both
are fine at a cycle boundary with no guests up, and neither is fine between
two guest builds. The switch helper called during a build stays detect-only.

Get-Command-guarded because only the Hyper-V driver defines this: a vSwitch that
outlives its uplink binding is a Windows-specific failure. The repair declines
itself on anything but a stale binding, caps its own attempts, and rolls back
if the host loses its default route -- see Repair-YurunaExternalSwitch.

Best-effort by construction. A host that cannot repair its bridge still runs
the cycle on the Default Switch with port-forwarders, which is what it has
been doing; the repair only tries to win back the bridged path.

<a id="4213a0b3-0022"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Cycle-start External vSwitch repair (Hyper-V only)

The gate above wrote the degraded pair from a probe taken BEFORE this
repair ran, so a switch fixed here would keep advertising a fault it no
longer has for the rest of the cycle -- on the status page and in the
pool record alike, a quarter of an hour of wrong. Re-probe and clear.

This branch only ever CLEARS. The gate stays the sole writer of a degraded
pair, which is what lets its consecutive-cycle count mean anything; a
repair can only move a host toward healthy, so there is nothing here to
write. Gated on the record file so a host that was already healthy does
not pay for a second probe every cycle.

<a id="4213a0b3-0023"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Cycle-start External vSwitch repair (Hyper-V only)

Probe the two operator sources in priority order (persistent
vmStart.cachingProxyIp config key, then the session env var) --
source priority and probe policy are documented on
Resolve-CachingProxyServiceEndpoint (Test.CachingProxyService.psm1). Acceptance is
:3128 reachability ONLY: keying on full probe Success would reject
barebones-squid caches that lack Grafana/ssl-bump and silently
destroy $env:YURUNA_CACHING_PROXY_SERVICE_IP for downstream code. With no
source set the env var is untouched (local discovery below runs
unchanged); with sources set but :3128 unreachable on each, the env
var is cleared so the same local-discovery fallback applies.
The port-map refresh below is the one preamble step that shells out to sudo,
and it is where an unanswerable password prompt actually stalled a host.
Naming the phase puts 'caching-proxy-gate' in the watchdog's kill line.

<a id="4213a0b3-0024"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Cycle-start caching-proxy-service gate

Port-map dispatch (external / Yuruna-External fast path /
Default-Switch fallback) and the Windows-vs-macOS port-list shape:
https://yuruna.link/42f6b05f-003c

Serialize this per-cycle port-map write against a caching-proxy-service
bring-up. Try-once (non-blocking): if Start-CachingProxyServiceVM holds the lock (a
rebuild), skip this cycle's port-map -- the rebuild owns the maps and the
cache is down mid-rebuild anyway; the next cycle re-applies once it releases.
Get-Command-guarded so a long-running runner that predates the lock module
degrades to the unlocked behavior instead of erroring.

<a id="4213a0b3-0025"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Cycle-start caching-proxy-service gate

There is deliberately NO sudo prime here any more. Elevation for an
unattended host is a launch-time concern (Assert-RunnerElevation, run once by
Start-TestRunner.ps1 before the loop) or an /etc/sudoers.d drop-in -- never
mid-cycle, where nobody is at the console to answer.

A prime gated on Test-CacheVMOnExternalNetwork would be wrong as well: that
asks "is the LOCAL cache VM bridged?" and returns false BOTH for a NAT'd
local cache that needs forwarders AND for a host whose cache is a different
machine entirely. On the latter a prime would fire every cycle while the
dispatch below takes the external branch, where Remove-PortMap finds no units
and issues no sudo at all: a password prompt, every cycle, for work that
never happens.

<a id="4213a0b3-0026"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Cycle-start caching-proxy-service gate

External handling below removes this host's forwarders,
so it may only run when the endpoint is POSITIVELY not this
host. 'local': the "external" endpoint is this host's own
forwarder set fronting its NAT'd cache VM -- removing it severs
the very listeners that just answered the probe (self-teardown).
'unknown': NIC churn from per-cycle VM start/stop can blank the
enumeration for a moment, and a wrong 'external' verdict tears
the forwarders down while a wrong 'local' verdict merely
re-asserts a port map -- so unknown must land on the local side.

<a id="4213a0b3-0027"></a>

## test/modules/Invoke-TestRunnerInnerLoop.ps1: Cycle-start caching-proxy-service gate

The exposed-port set (incl. 9302 caching-proxy-parser-service live tail)
comes from Get-CachingProxyServiceExposedPort so it cannot drift from
Start-CachingProxyServiceVM's install list; Add-PortMap is clear-all-first,
so a dropped port goes dark on reinstall. macOS re-maps only the two
ports an operator opens by hand: Grafana, and 80 -- which is where
the caching-proxy VM's landing page lives, and therefore where the
host status pages' Dashboards link points. Without 80 that link
reaches nothing from a Mac host.

<a id="4213a0b3-0028"></a>

## test/modules/Test.CachingProxyService.psm1: Invoke-CachingProxyServiceProbe

Connect policy for the shared probe. 3 attempts because a single deadline
spuriously FAILs a cache that is actually up: on Wi-Fi a cold radio plus an
ARP-over-air round trip can burn most of the budget, and one AP retransmit
or roam pushes it past the cliff (the first attempt warms ARP / wakes the
radio; a follow-up connects in milliseconds). 3s/attempt because a remote /
cross-host cache (e.g. UTM/macOS squid over bridged networking) routinely
takes 600ms-1s+ to ACCEPT; the cap is free for a fast local cache -- connect
returns the instant the port accepts.

<a id="4213a0b3-0029"></a>

## test/modules/Test.CachingProxyService.psm1: Get-PoolAggregatorServiceSeedUrl

Repair a stored address that lost to a live one, so the next call pays
no probe to disprove it again. Only an address this host already
recorded is rewritten: an empty key means "I run no proxy of my own",
and filling it with a proxy someone else runs would assert an ownership
this host does not have.

ShouldProcess, not $WhatIfPreference: preference variables resolve in the
module's OWN session state, where $WhatIfPreference reads $false however
the caller was invoked, and an unbound -WhatIf is not forwarded across
that boundary either. A caller that must not write has to pass -WhatIf by
hand, and this gate is what gives that pass an effect.

<a id="4213a0b3-002a"></a>

## test/modules/Test.CachingProxyServiceLock.psm1: Caching-proxy serialization lock + adopt-if-healthy decision.

Caching-proxy serialization lock + adopt-if-healthy decision.

The lock is a drain-style PID+StartTime mutex so the destructive VM lifecycle
and the host port-map writes cannot interleave; the two hold profiles
('rebuild' and 'portmap') differ only in their acquire timeout. Lock identity,
the stale-holder drain, the self-owned reclaim, the abandoned-age ceiling, the
hold-profile table, and the adopt-or-rebuild
decision shape: docs/caching.md#rebuild-adopt-if-healthy-and-the-bring-up-lock

<a id="4213a0b3-002b"></a>

## test/modules/Test.CachingProxyServiceLock.psm1: Age past which a recorded lock is ABANDONED rather than slow, so it is drained

Age past which a recorded lock is ABANDONED rather than slow, so it is drained
on acquire (and by Clear-CachingProxyServiceLock). Draining takes the lock away
from whoever recorded it, so the ceiling is set from the rebuild's real worst
case and then multiplied out:
  * BOUNDED phases total ~36 min -- host/ubuntu.kvm/guest.caching-proxy-service/
    New-VM.ps1 waits up to 20 min for the VM's IP and 15 min for squid on :3128;
    the macOS UTM path in Start-CachingProxyServiceVM.ps1 waits 15 min for
    MAC/ARP discovery plus ~1 min of register + start retries.
  * The Step 2 base-image fetch is the only UNBOUNDED phase (~600 MB, and
    nothing in Yuruna.Image sets a download timeout). 6 h leaves >5 h for it --
    600 MB at ~250 kbit/s -- which is slower than any link a lab host has.
So this cannot fire during a legitimate slow rebuild. It is also the LAST
recovery resort: a self-owned leftover is reclaimed immediately on acquire, and
Stop-CachingProxyServiceVM.ps1 clears an abandoned lock on demand.

<a id="4213a0b3-002c"></a>

## test/modules/Test.CachingProxyServiceLock.psm1: Enter-CachingProxyServiceLock

OUR OWN leftover from an earlier invocation in THIS process -- not a
live peer. A .ps1 runs inside the caller's pwsh, so a bring-up that
exited without releasing recorded the operator's long-lived
interactive shell as the holder; that shell stays alive, so the
liveness drain above never fires and every later run is refused.
Safe because one pwsh process never holds two bring-up locks at
once: the only other caller (Invoke-TestRunnerInnerLoop.ps1's
'portmap' hold) is try/finally-scoped and never starts a bring-up
inside its window, and Start-CachingProxyServiceVM.ps1 is never
dot-sourced or run as a job. A self-owned lock is therefore stale
by definition. Warned (not Verbose): it means an earlier bring-up
in this shell died, which the operator should know about.

<a id="4213a0b3-002d"></a>

## test/modules/Test.Capability.psm1: Write-HostRegistrationRecord

poolId: this host's pool, DERIVED by the outer loop's pool-sync from
pools.yml members[] (the single source of truth) and persisted to
runtime/pool.state.json -- the cross-process channel, since this writer
runs in the FRESH inner process that does not inherit the outer's
$global. null when unpooled or intent not yet pulled (the aggregator then
falls back to its own pool label). Read inline so Test.Capability keeps no
dependency on Test.PoolSync.
gating: the pool's advisory alert policy, carried alongside poolId in
pool.state.json (null when the pool authored none). Forwarded verbatim so the
aggregator parses the thresholds; a null/absent gating tells it to observe the
pool's gauges but never page it.
poolGuid: the pool's stable 42-GUID, carried
alongside poolId in pool.state.json. Advertised so the aggregator can
label host_info with it. null when unpooled.

<a id="4213a0b3-002e"></a>

## test/modules/Test.Capability.psm1: Write-HostRegistrationRecord

activeExtensions: the extension areas this host is ACTIVELY running right
now (distinct from capabilities.extensions, which is what it COULD run --
true for every host). The pool-aggregator-service reads this to populate the
dashboard's Extension hosts table WITHOUT mounting ystash-nas (no cross-host
config service / NAS-credential dependency). Driven by per-service runtime
markers a host writes when it brings a service up -- Start-StashServiceVM.ps1
writes runtime/stash-service.json; Stop-StashServiceVM.ps1 removes it.
extensionTargets carries the per-area deep-link the host advertises for its
service (the service VM's UI base URL the host resolved via Get-VMIp), so the
aggregator can redirect to it without an address store of its own. On a
Shared-NAT UTM bundle that base URL is the HOST's forwarded address, not the
guest IP, because the guest address is unreachable from the rest of the LAN.

One loop over the markers rather than one block per service: a hardcoded
copy per area would put an edit to this writer in the path of every new
extension service that wants to be visible to the pool.

<a id="4213a0b3-002f"></a>

## test/modules/Test.Capability.psm1: Write-HostRegistrationRecord

projectUrl / projectCommit: the project this host's last cycle cloned,
published as host facts next to its identity, so a registration reader
learns what a member runs without cloning anything -- the host already
has the clone, and its GH_TOKEN never has to leave it.

Read from the project clone that the cycle already produced; local git
reads only, matching this function's resolution policy. Best-effort: a
clone that cannot be read reports nulls, because these facts must never
be able to fail a registration write.

NOTE (ordering): this record is written in Phase 0, BEFORE the pooled
repos override and the project clone refresh, so both fields describe
the PREVIOUS cycle's clone. After a pool's Project URL changes, the
first registration still names the old project.

<a id="4213a0b3-0030"></a>

## test/modules/Test.Capability.psm1: Write-HostRegistrationRecord

network: this host's guest-network topology when it is NOT the healthy
one. A Hyper-V vSwitch object outlives its uplink binding across a host
reboot, so a host can be fully online, pass every host check, and still
attach every guest to a switch with no carrier -- a state the cycle
verdict alone cannot express, because such a host keeps running and
passing on the Default Switch (NAT + DHCP). Absent marker = healthy, so
the field stays null and an aggregator that never learned about it is
unaffected. Read as a file, matching this function's resolution policy.

<a id="4213a0b3-0031"></a>

## test/modules/Test.Catalog.psm1: Render a message from the compiled catalog, in the locale a run resolved.

Render a message from the compiled catalog, in the locale a run resolved.

The catalog compiler emits a table per locale and domain, already broken into
the pieces a renderer walks: a message with no arguments is a plain string, a
message with arguments is an alternating list of literal text and argument
descriptors, and a message that varies by count carries its variants beside
the argument that selects them. Nothing here parses a message grammar or
scans a format string, because the parsing already happened at build time --
which is what keeps this cheap enough to sit in a per-line transcript loop.

Loading is lazy and cached for the process. A command that renders no text
pays nothing; a command that renders a thousand messages reads each domain
once. Import-PowerShellDataFile is the loader on purpose: it parses the file
in PowerShell's restricted language, so a generated artifact is data and
cannot execute.

A missing key is a build error, not a runtime one -- a supported catalog is
complete by definition, and the compiler fails on a gap. At runtime the key
itself is returned so the surface still says something identifiable, and the
caller sees it in the one place a wrong key can be noticed.

<a id="4213a0b3-0032"></a>

## test/modules/Test.Catalog.psm1: Format-CatalogArgument

In a right-to-left locale every argument is isolated, so the bidi
algorithm cannot reorder a number or an external string into the
sentence around it. A number, duration or timestamp reads left to
right (LRI); an external string decides its own direction (FSI). An
empty argument stays empty: an isolate around nothing is two invisible
characters a reader cannot delete. The Go SDK and the browser kernel
write the same bytes.
A value the caller isolated already opens with an isolate and ends with
its close; a second pair would only nest.

<a id="4213a0b3-0033"></a>

## test/modules/Test.Config.psm1: Publish-TestConfigSnapshot

The snapshot is a verbatim copy of everything parsed, and it lands in the
runtime directory the status service publishes over HTTP. The credential
files under the authentication extension carry passwords and the lab auth
token in the clear, and the server's deny-list keys on FILE NAMES -- so it
protects vault.yml while a copy of vault.yml under a different name is
served happily. Never producing the copy is the only form of that
protection which cannot be outflanked by a new name. Consumers lose
nothing: every snapshot miss already falls through to a full YAML parse.

<a id="4213a0b3-0034"></a>

## test/modules/Test.ConfigNaming.psm1: Test-RetiredConfigKeyLine answers "does this FILE still say it the old way",

Test-RetiredConfigKeyLine answers "does this FILE still say it the old way",
which is what a local reconcile needs. A config fetched from another host
arrives already parsed, and the question there is different: rewrite the
retired spellings onto the current paths so the consumer -- which only ever
looks for current names -- sees the values instead of nothing.

Nothing did that rewrite, and "sees nothing" is not inert: the networkStorage
converter reads a missing poolStorageNetworkPath as "the reference has no pool
storage" and CLEARS the tier, taking the usernames with it and leaving the
credential sync with an empty user list. A reference host one rename behind
therefore erased the section it was supposed to supply.

<a id="4213a0b3-0035"></a>

## test/modules/Test.ConfigPreflight.psm1: Pre-cycle config gate: spawn Test-Config.ps1 in a fresh pwsh so an

Pre-cycle config gate: spawn Test-Config.ps1 in a fresh pwsh so an
Out-Of-Order ::Stop / early exit inside Test-Config can't unwind the
caller's eternal loop. -SkipSend is mandatory in this gating context:
the notification path inside Test-Config is a smoke test, and
delivering an email on every outer relaunch / dev iteration would
flood the subscribers["config.smoke"] list.

Centralizing the gate here keeps Start-TestRunner outer-startup,
Debug-TestSequence, and Invoke-TestProject agreeing on the same gate semantics --
a new gate parameter reaches every caller from one place instead of
drifting between near-identical copy-pastes.

<a id="4213a0b3-0036"></a>

## test/modules/Test.ConfigPreflight.psm1: Invoke-ConfigGate

Hidden-mode invocation: Test-Config's ~80-line transcript is captured
silently and reaches the CONSOLE only when the gate fails (the failures
block is re-emitted under the gate-failed banner below), so a green gate
shows the operator nothing -- matching every other preflight check in the
harness. It is returned to the caller either way; see .OUTPUTS.
The capture includes 2>&1 so child stderr joins the same list and the
FAILURES-block extractor sees the full transcript whichever stream
Test-Config wrote to.
Resolve the running pwsh via the shared, macOS-hardened resolver: a
bare (Get-Process -Id $PID).Path is null on macOS (no /proc) and a
null child-pwsh path makes the spawn below throw. The Sequence entry
point loads this gate WITHOUT Test.InnerSpawn, so import it on demand;
-Global avoids the nested-import global-eviction class
(feedback_module_force_import_evicts_global.md). The call is module-
qualified because the Windows host module exports a same-named
Get-PwshExePath with different semantics.

<a id="4213a0b3-0037"></a>

## test/modules/Test.ConfigPreflight.psm1: Invoke-ConfigGate

Pull the FAILURES block (the section between the "FAILURES (N) --"
header and the matching "END OF FAILURES (N)" footer, including
the === banner lines around them) so we can repeat it under the
gate-failed banner. Test.Output's Write-Summary already includes
per-section WARN messages there, so this single excerpt carries
the full reason chain (FAIL + the warnings it pointed at).
Collected as it is written so what the caller gets back and what the
console showed cannot drift apart.

<a id="4213a0b3-0038"></a>

## test/modules/Test.ConfigServiceCA.psm1: Per-host Config CA backing the config service (mTLS): one SERVER leaf

Per-host Config CA backing the config service (mTLS): one SERVER leaf
for the service, one CLIENT leaf per VM (baked into its cloud-init seed) --
proof the VM was created by THIS host. Persisted under
$env:YURUNA_RUNTIME_DIR/host-config-ca/ (gitignored).
See docs/test-config.md.

Crypto is operator-approved security posture (do not change without sign-off,
see feedback_no_unauthorized_security_changes): EC P-256, SHA-256, CA 10y,
leaves 2y. The server leaf's SAN is a STABLE dns name (ConfigServerSan); guests
reach the host's current IP via `curl --connect-to <san>:<port>:<hostIp>:<port>`
so a host DHCP change never invalidates the leaf (it only invalidates the baked
host IP, the same staleness the status-service fetch already has).

<a id="4213a0b3-0039"></a>

## test/modules/Test.ConfigServiceCA.psm1: X509 key-storage flags for loading the CA signing material (ca.pfx)

X509 key-storage flags for loading the CA signing material (ca.pfx). On Windows
and Linux, EphemeralKeySet keeps the private key purely in memory, so the
frequent per-VM signing leaves no residue in the host key store. macOS does NOT
support EphemeralKeySet -- the loader throws "This platform does not support
loading with EphemeralKeySet" -- so it loads with Exportable instead, the same
flag the server leaf already uses. The CA key is already at rest in ca.pfx
(chmod 600), so the macOS path adds no new at-rest exposure; the EC P-256 /
SHA-256 crypto posture is unchanged on every platform.

<a id="4213a0b3-003a"></a>

## test/modules/Test.ConfigServiceCA.psm1: Get-YurunaConfigCaPublicCertificate

Load from the DER bytes parsed out of the PEM, NOT the X509Certificate2 file
constructor: that constructor auto-detects the file format via the platform
crypto backend, which reads PEM on Windows but NOT on macOS -- there it throws,
which killed the detached -Serve process before it could listen (the launcher
never loads ca.crt as a cert, so the failure showed up only in the service).
DER bytes load identically on every platform. (CreateFromPem takes a
ReadOnlySpan<char> that PowerShell cannot reliably bind a [string] to across
versions -- see Test.ConfigServiceCA.Tests.ps1; the .Tests file uses the same
strip-headers -> base64 -> DER reconstruction.)

<a id="4213a0b3-003b"></a>

## test/modules/Test.ConfigServiceSync.psm1: Pure conversion helpers (no I/O; unit-tested directly)

Both ends hold the internal authentication key; nothing else is shared.
The request carries an HMAC proof-of-knowledge (the token itself never
crosses the wire) and the response password is AES-256-GCM encrypted with
an HKDF key derived from token + a fresh per-response salt, with the user
and the client's nonce bound into the derivation -- a captured response
cannot be decrypted without the token nor replayed for a different user.
The status service is plain HTTP on a trusted LAN; this keeps the secret
confidential in transit without a TLS dependency.

<a id="4213a0b3-003c"></a>

## test/modules/Test.ConfigServiceSync.psm1: Get-ConfigSyncHmac

The unary comma is load-bearing. A bare `return $bytes` writes the array to
the pipeline ELEMENT BY ELEMENT, and the caller collects the pieces back
into an [object[]] -- not the [byte[]] the OutputType above advertises
(that attribute documents, it does not coerce). Most callers never notice,
because a [byte[]]-typed parameter converts the object[] back. Test-ConfigSyncProof
does notice: it passes this value to a ReadOnlySpan<byte> parameter, and a
ByRef-like type is the one thing PowerShell cannot convert an object[] into,
so the comparison throws instead of returning a verdict.

<a id="4213a0b3-003d"></a>

## test/modules/Test.ConfigServiceSync.psm1: Invoke-ConfigSyncHostAlias

-n (never block on a password prompt) and, on macOS, -E: a Homebrew
PowerShell cannot start under sudo's stripped environment and exits
131 before reading the script. See Get-SudoPwshArgumentList.
The prompt names the account and the reason. Reaching this point
means the run has just finished narrating vault keys and the
storage-account credentials it fetched from the reference host, so
a bare "Password:" arrives looking like a continuation of that and
invites one of those credentials as the answer. What is wanted is
this machine's own login password, and nothing but the prompt can
say so.

<a id="4213a0b3-003e"></a>

## test/modules/Test.ConfigServiceSync.psm1: Side-channel reconciliation (hosts file + vault)

Converges every networkStorage server name in the converted config onto the
address the REFERENCE host resolves it to: the reference is the source of
truth for the sync, so its answer is consulted for every name, not only for
the ones that fail to resolve here. Skipping the lookup whenever a name
resolves locally would make the sync a one-shot bootstrap: a NAS that moved to
a new address leaves a stale hosts entry that still "resolves", so no re-run
could ever repair it and the mounts would keep failing against the old IP. A
re-run therefore rewrites a mapping that disagrees with the reference and
writes nothing when they already agree. Operator prompt remains the last resort.

<a id="4213a0b3-003f"></a>

## test/modules/Test.ConfigServiceSync.psm1: Sync-ConfigSyncHostAlias

Latched on the first elevation this loop cannot get, so the operator is
asked at most once. sudo caches a successful authentication for a few
minutes, so a run that gets the password right already prompts only for
the first name; without the latch a run that gets it WRONG prompts again
for every remaining name, and each prompt is a fresh three-attempt round
of the same rejection. Two names turn one mistake into six refusals, which
reads like the machine disagreeing with itself rather than one wrong
answer -- and the second prompt invites the operator to conclude a
DIFFERENT password must be wanted.

<a id="4213a0b3-0040"></a>

## test/modules/Test.ConfigServiceSync.psm1: Sync-ConfigSyncVaultCredential

No internal authentication key to fetch a possibly-rotated value with, and a working
entry is already here: keep it, with no network round-trip and no prompt.
Fetching (hence refreshing) is impossible without the key by design, so
there is nothing the reference could tell us that would change the outcome.
Pass -InternalAuthKey (or store an internal authentication key here) to have re-runs refresh
this against the reference.

-RequireReferenceValue takes this branch off the table. The caller has
said an unchecked entry is not acceptable, and on a host converting away
from standalone it is actively wrong: the entry it would keep was minted
here, for a share this host used to serve itself.

<a id="4213a0b3-0041"></a>

## test/modules/Test.ConfigServiceSync.psm1: Sync-HostConfiguration

Rewrite them onto the current paths BEFORE anything reads the config.
Every consumer downstream looks up current names only, so a value parked
under a retired one is indistinguishable from a value that is not there --
and "not there" is not inert: Convert-ConfigSyncNetworkStorage reads a
missing poolStorageNetworkPath as "the reference has no pool storage" and
CLEARS the tier, which takes the usernames with it and leaves the
credential sync iterating an empty list. A reference one rename behind
would erase exactly the section it was fetched to supply.

Ahead of the freshness gate, so a reference whose only drift is spelling
syncs cleanly -- including unattended, where that gate is a hard failure.
The operator is still told, because the fix belongs at the source: this
rewrite is per-sync and the reference keeps serving the old names to
everyone else until it is reconciled.

<a id="4213a0b3-0042"></a>

## test/modules/Test.ConfigServiceSync.psm1: Sync-HostConfiguration

On Linux the poolStorage mount runs `sudo -n mount/mkdir/umount`, which
fails without an /etc/sudoers.d drop-in granting those NOPASSWD -- the
WARN the operator saw at the end of validation, after which the runner
buffers locally. The unattended runner cannot self-elevate, but THIS is
an interactive operator session, so offer to install the drop-in now
(one sudo prompt) rather than let the mount fail. Idempotent (a no-op
when already configured), Linux-only (macOS mounts via mount_smbfs -N and
Windows via SMB mappings need no sudo), and gated on a configured mount.

<a id="4213a0b3-0043"></a>

## test/modules/Test.ConfigServiceSync.psm1: Reference freshness gate

Run Start-StatusService.ps1 -Restart in a child pwsh, streaming its output back
as it lands, WITHOUT handing that child -- or the status service it detaches --
a handle to any pipe this process is reading.

On Windows the spawn shape below is load-bearing: adding -Redirect* or
-NoNewWindow here turns on handle inheritance, the detached status service
inherits and pins the caller's stdout pipe, and the bounce hangs silently and
unboundedly. Full trap description and why file redirection does not fix it:
docs/workarounds.md#a-detached-grandchild-pins-the-callers-pipe-on-windows
(also captured in feedback_windows-detached-grandchild-pins-pipe.md).

<a id="4213a0b3-0044"></a>

## test/modules/Test.ConfigSync.psm1: Update-TestConfigFromTemplate

Notification config (including secrets) lives at
test/status/extension/notification/transports.yml. The template
ships in-tree at test/extension/notification/transports.yml.template.
The legacy keys secrets.resend and notification.toEmailAddress in
test.config.yml are no longer schema-valid. The merge
(ConvertTo-MergedHashtable) drops template-orphan keys, so any
populated legacy values would vanish silently -- warn the operator
to move them by hand. Soft migration: do NOT auto-move credentials
across files.

<a id="4213a0b3-0045"></a>

## test/modules/Test.ConfigSync.psm1: Update-TestConfigFromTemplate

The on-disk file no longer matches the template's nested shape (the schema
changed). Back the previous file up, then write the value-preserving merge
(NOT a bare template reset): every field that still maps to the same path in
the new schema has its value carried forward from the previous file, and
template-only nodes are filled with their defaults. Fields that genuinely no
longer map (top-level orphans, or values under a node whose shape changed)
cannot be carried -- if any carried a real value, stop the run so the
operator can hand-migrate them from the .backup; otherwise (a purely
additive schema change -- a new node the file lacked) continue, since
nothing was lost and the unattended loop must not halt on a benign bump.

<a id="4213a0b3-0046"></a>

## test/modules/Test.ConfigSync.psm1: Schema migration (shape departed)

Rendering the live config from the TEMPLATE TEXT, not from ConvertTo-Yaml.
YAML was chosen for this file so each knob could carry its explanation, but a
ConvertFrom-Yaml/ConvertTo-Yaml round-trip drops every comment -- an operator's
test.config.yml ended up with none of the template's 29 comment lines. The
template is already the schema source of truth AND canonically ordered, so it
doubles as the rendering skeleton: walk its lines, keep comments/blank
lines/order verbatim, and substitute the operator's value wherever the file has
one. Keys the template no longer defines are written back as commented-out
`#   path: value` entries instead of vanishing, so a rename leaves its old value
in view for hand-migration (Test.ConfigNaming's scanner skips comment lines, so a
key parked there stops failing the retired-key check).

<a id="4213a0b3-0047"></a>

## test/modules/Test.ConfigValidator.psm1: Reusable validation primitives -- schema validation, emptiness check,

Reusable validation primitives -- schema validation, emptiness check,
git-tree freshness -- that any check script (Test-Config.ps1 included)
can call without re-implementing.

All callers reach Write-Pass / Write-Fail / Write-Warn / Write-Info
from Test.Output.psm1, which this module imports at load time. The
PASS/FAIL counters survive across Test.Output's $global: anchor so
Test-Config's summary at end-of-run reflects every Test-AgainstSchema
and Test-RepoFreshness call regardless of import order.

<a id="4213a0b3-0048"></a>

## test/modules/Test.CredentialProvider.psm1: Clear-CredentialProvider

Mutate the shared dictionary; do NOT rebind the names to a fresh one.
Yuruna.CredentialProvider aliases this same object into its own
$script:Providers at import, and that alias is what Get-CredentialProvider
and Register-CredentialProvider actually read and write. Rebinding here
would leave that alias pointing at the original dictionary: the matrix
would report an empty registry while lookups kept resolving the live
built-ins, and a provider registered after the clear would land in the
orphaned copy where nothing can see it. A test that believed it had
isolated the registry would then be exercising the real providers -- and
Repair-Credential would invoke a real `az acr login`.

<a id="4213a0b3-0049"></a>

## test/modules/Test.CriticalRecord.psm1: Checksummed, generation-numbered private records with a retained previous

Checksummed, generation-numbered private records with a retained previous
generation, for state that authorizes a mutation: a request journal, a
recovery record, a runner gate, a budget reservation. Best-effort progress
files (Test.StateFile) may lose a write and only degrade reporting; losing
or tearing one of these must instead refuse the mutation it guarded, so the
contract is stricter:

  * A write goes to a new temporary file, is flushed and read back before
    it replaces the record, and the replaced generation is kept as
    <Path>.prev. A crash at any point leaves either the old generation or
    the new one readable, never a torn mix.
  * Every record carries its kind, a generation number and a SHA-256 of its
    payload, so a truncated or bit-flipped file is detected and the reader
    falls back to the previous generation instead of trusting it.
  * A writer states the generation it read (compare-and-set); a stale
    writer is refused rather than silently overwriting a newer decision.
  * A newer format version or another record's kind is never replaced by an
    older generation: that is a refusal, not a fallback.

Atomic replacement protects against a process crash. Surviving a power cut
also needs the data and the directory entry flushed to stable storage; the
flushes are issued (fsync on Linux, F_FULLFSYNC on macOS, write-through
rename on Windows) and reported through FlushesConfirmed, but no platform
claims power-loss durability until a power-cut test has shown it holds, so
Get-YurunaCriticalRecordDurability declares process-crash everywhere.

Every blocking file operation runs on a compiled helper's task and is waited
on with a bounded Task.Wait, so a wedged filesystem turns into io-timeout
instead of a hang. A timed-out task keeps its pool thread (a blocked kernel
call cannot be canceled); the per-step caps keep that count small.

<a id="4213a0b3-004a"></a>

## test/modules/Test.Diagnostic.psm1: OCR is used only to verify the echo of the console one-liner before it is

OCR is used only to verify the echo of the console one-liner before it is
submitted. It is strictly an accuracy aid on a best-effort debugging path,
so the import is allowed to fail: a host without the OCR chain must still
be able to collect diagnostics, just without the pre-Enter check. Every
consumer re-probes with Get-Command and degrades to 'unknown', so a failed
import here costs verification and nothing else.

-Global is required, not stylistic. A bare -Force re-import evicts an
already-global module into THIS module's private scope, and the next
Get-EnabledOcrProvider call from any other caller then fails with "not
recognized" (feedback_module_force_import_evicts_global.md).

<a id="4213a0b3-004b"></a>

## test/modules/Test.Diagnostic.psm1: Longest tolerated run of consecutive normalized characters, counted only

Longest tolerated run of consecutive normalized characters, counted only
once the command's own echo has been recognized (see AnchorMinRun below),
that the expected command cannot account for. Calibrated against real
captures: a correctly typed line -- even with a screenful of unrelated
scrollback above it -- keeps this run under 40, while a real autorepeat-
corrupted capture measures ~860 and a synthetic stuck key runs into the
thousands. 80 sits roughly 2x above the healthy ceiling and an order of
magnitude below observed corruption.

<a id="4213a0b3-004c"></a>

## test/modules/Test.Diagnostic.psm1: How many consecutive explained positions mark where the command's echo

How many consecutive explained positions mark where the command's echo
genuinely begins on screen. Until that many have been seen in a row, an
explained position is treated as a coincidental OCR gram hit inside
unrelated scrollback rather than the command itself, and the unexplained
stretch that follows such a hit is NOT counted toward corruption. This is
what lets a login banner, a boot log, or earlier command output printed
ahead of the command sit on screen -- legitimately unexplained and
unbounded -- without being scored as a stuck key. 12 is comfortably longer
than the incidental run a shell prompt or log line shares with the command,
and far shorter than the command's own contiguous echo.

<a id="4213a0b3-004d"></a>

## test/modules/Test.Diagnostic.psm1: Invoke-RemoteDiagnosticsConsole

Pre-type: discard anything already sitting in the tty's line
buffer. Without this, residue concatenates with the first
characters of the one-liner and the command is malformed before
it is ever submitted. The result is deliberately discarded: a
clear that did not land is not a reason to skip the payload, and
the echo check below is what decides whether the line is usable.
It must still be captured: an uncaptured [bool] joins this
function's output stream and turns the returned hashtable into a
two-element array, whose .success then reads $null.

<a id="4213a0b3-004e"></a>

## test/modules/Test.Diagnostic.psm1: Invoke-RemoteDiagnosticsConsole

Neither chord nor text reached the guest, so the console
still holds exactly the characters the first verdict
read. Asking for a second verdict here would re-measure
an unchanged screen and is therefore guaranteed to
return 'corrupt' again -- a verdict about the transport
wearing the costume of a verdict about the guest. Report
the transport instead: "the retype never happened" and
"the guest echoed a malformed command" need different
fixes, and conflating them sends the reader to the
console when the keystroke path is what is broken.

<a id="4213a0b3-004f"></a>

## test/modules/Test.Diagnostic.psm1: Invoke-RemoteDiagnosticsConsole

TimeoutSeconds is the caller's budget for the whole rung, not just
for the upload wait. Echo verification and a possible retype run
before that wait, so their measured cost is deducted from the
budget rather than added on top -- otherwise a verified-and-
retyped capture would overrun the per-command budget that
Save-GuestDiagnostic derives from the cycle's total.

The floor exists because the deduction must not be able to starve
the wait: the guest still has to fetch, run and POST the capture
after Enter, and a wait shorter than that is a guaranteed false
timeout on a line that was successfully repaired.

<a id="4213a0b3-0050"></a>

## test/modules/Test.Diagnostic.psm1: Select-MoreInformativeDiagResult

Fallback picker for the all-rungs-failed manifest: keep whichever failed
rung produced the longer captured error text. In practice this ranks only
the two SSH rungs (key-ssh, password-ssh) -- they are the only rungs whose
failed result carries .output. The console rung POSTs its capture straight
to the failure folder and returns output='' (see
Invoke-RemoteDiagnosticsConsole), so its candidate is always ignored here.
Preferring rung order alone would pin the manifest to key-ssh even when the
later password-ssh rung captured the fuller stderr, so length is the
content proxy between the two. Length is only a proxy: a verbose low-signal
capture (e.g. the pwsh exit-64 usage banner) can outrank a concise real
error -- acceptable for a post-mortem debugging aid. A tie keeps the
incumbent so an equally sized later rung does not churn the choice; a
candidate with no output is ignored, so an empty capture never replaces a
real one.

<a id="4213a0b3-0051"></a>

## test/modules/Test.Diagnostic.psm1: Invoke-GuestDiagnosticCapture

Preflight: ask the driver to warm the host's neighbor cache before any
address lookup. Wherever the host is not the DHCP server for the guest
network -- an External vSwitch, a bridge-forward libvirt network -- there
is no in-band source to ask, and a passive cache read finds the guest only
while it happens to be talking to us. Without this, address resolution
hands back the VM name and Wait-SshReady spends its whole budget on
"Could not resolve hostname", which names nothing about the real fault.
(memory note: hyperv_external_vswitch_arp_discovery)

A contract verb rather than a probe-by-name: every driver answers, and
each decides what warming means for it. A driver whose Get-VMIp already
escalates internally declines here, so its own bounded, memoized sweep
is not duplicated by an unbounded one from out here.

<a id="4213a0b3-0052"></a>

## test/modules/Test.Diagnostic.psm1: Invoke-GuestDiagnosticCapture

Resolve the host status-service URL once and feed it to BOTH SSH
rungs as their curl-bootstrap fallback -- a console-rung-only
bootstrap leaves a gap when SSH is healthy but the guest has not
yet extracted the yuruna tarball (e.g. cycle watchdog fired
mid-update.sh during the apt-get phase): the SSH command exits 64
from pwsh's usage banner and the diagnostic file captures that
banner instead of real state. Soft-fail to $null if the endpoint
can't be resolved -- the rungs degrade to the bare `pwsh -File`
command and the console rung is still the final fallback.

<a id="4213a0b3-0053"></a>

## test/modules/Test.DownloadAgentService.psm1: A first boot installs the Go toolchain, builds the daemon, and mounts the pool

A first boot installs the Go toolchain, builds the daemon, and mounts the pool
share before anything binds :80. Minutes, not seconds -- and slower still when
the apt traffic goes through a cold caching proxy: measured at roughly half an
hour on an Apple Silicon UTM guest against a cold mirror, against the ten to
fifteen a warm x86 host takes.

Sized for the slow end rather than the typical one. The probe returns the
instant :80 accepts, so a budget the fast host never spends costs it nothing,
while one sized for the fast host fails the slow host over a build that was
progressing normally. The wait extends itself past this while cloud-init
reports it is still working, so this is the floor rather than the whole story.

<a id="4213a0b3-0054"></a>

## test/modules/Test.EventSchema.psm1: Test-CycleEventSchema

$null is accepted as a valid empty array because PowerShell's
if-pipeline flattens both single-element AND empty arrays out
of an if-statement's output; `[string[]]$x = if (...) { @() }`
yields $null on the empty branch even though the emitter's
intent was "no entries". Treating $null as an empty array in
the validator is the durable fix -- emission sites that hit
the trap stay valid without needing to be hunted down one
at a time. A truly missing field (key absent from the
hashtable) is still caught by the required-field loop above.

<a id="4213a0b3-0055"></a>

## test/modules/Test.Extension.psm1: Import-Extension

Skip re-import if the same .psm1 path is already loaded. -Force
on Import-Module evicts any module sharing the basename
('default') -- so a second area's default.psm1 gets re-loaded
over the first, and the first's exports disappear from the
global table even though the first call site never asked for
a refresh. Match by absolute path so dev-time edits still
re-import (operator hits Ctrl+C, makes a change, re-runs --
the file mtime change isn't checked here, but explicit
Remove-Module + re-Import-Extension still works).

<a id="4213a0b3-0056"></a>

## test/modules/Test.ExtensionService.psm1: The host side of the extension interface: what an area DECLARES about itself,

The host side of the extension interface: what an area DECLARES about itself,
and the runtime marker that says this host is running it.

The declaration -- which VM, which health port, which start script, which
label -- belongs in the area's own <area>.config.yml `service:` block
(schema: test/schemas/extension-config.schema.yml), and every marker is
written through one function, which always emits the uniform base-URL key
whatever else an area declares. Neither may be spread across per-service
Start scripts, a hardcoded host roster, or a per-service block in the
registration writer: that shape makes the services unenumerable and puts a
framework edit in the path of every new one. A new extension service is
discovered by existing.

Every read here is best-effort and file-only: a malformed manifest or an
unreadable marker reports nothing rather than throwing, because a discovery
nicety must never be able to fail a bring-up, a teardown, or a registration
write.

<a id="4213a0b3-0057"></a>

## test/modules/Test.FailureTaxonomy.psm1: Canonical FailureClass + Severity taxonomy: the single source of truth for

Canonical FailureClass + Severity taxonomy: the single source of truth for
the Register-SequenceAction ValidateSet (Test.SequenceAction.psm1) and the
schema validator's enum check (Test.EventSchema.psm1). A ValidateSet
ATTRIBUTE argument must be a constant expression and cannot reference these
arrays, so Test.SequenceAction keeps a literal copy and calls
Assert-FailureTaxonomyInSync at module load to catch silent drift; every
OTHER consumer reads the arrays here. Leaf module: imports nothing, so it is
safe to load first in any module set.

<a id="4213a0b3-0058"></a>

## test/modules/Test.FrameworkSource.psm1: Which framework snapshot an extension service VM is built from.

Which framework snapshot an extension service VM is built from.

The service daemons are Go binaries whose version is stamped at COMPILE time
(`go build -ldflags "-X main.version=$VERSION_STR"`, read from the VERSION
file of whatever enlistment the guest fetched). Nothing re-reads it later:
the guest builds once and the number it prints on its UI, in /api/hostinfo,
and in every diagnostics payload is frozen at that moment for the life of
the VM.

That makes the FETCH the whole story. The cloud-init seed pulls this host's
enlistment from the status service (/yuruna-archive.tar.gz) and falls back to
cloning the public GitHub mirror when the host does not answer. The mirror is
a release snapshot -- it lags the working enlistment by however long since
the last publish -- so the fallback silently swaps the code being deployed
for an older codebase, and the only evidence left behind is one line in the
guest's cloud-init log.

This module makes that visible from both ends:

  * BEFORE the build, Assert-GuestFrameworkSource refuses a bring-up whose
    guest could not possibly reach this host's enlistment. It is a cheap
    early stop -- it saves the half-hour in-guest build, nothing more. It
    cannot prove which address the seed will end up baking, because that is
    resolved per host type inside New-VM.ps1.

  * AFTER the daemon serves, Assert-ServiceVmFrameworkSource reads what the
    guest ACTUALLY did (/etc/yuruna/framework-source, written by the seed)
    and what the daemon actually reports (/api/hostinfo). That one is
    authoritative, and it is the check that fails a bring-up.

The split matters: the preflight is a prediction and the post-boot check is
an observation, so only the second may be trusted to say a deployed service
is running current code.

<a id="4213a0b3-0059"></a>

## test/modules/Test.GuestQuarantine.psm1: Failure classes whose cause lives on the HOST, not in any one guest

Failure classes whose cause lives on the HOST, not in any one guest. The
circuit breaker counts a per-guest same-class streak, so a host-scoped fault
-- which produces the identical class on every network-touching guest at the
same time -- would trip quarantine on all of them within failuresToQuarantine
cycles and then SKIP them, leaving a green cycle over a broken host. These
classes therefore never start or extend a streak: the breaker exists to
suppress a guest that is individually broken, and a host fault is neither
suppressible nor attributable to the guest that reported it.

<a id="4213a0b3-005a"></a>

## test/modules/Test.HostAddressBeacon.psm1: Two pieces of state, not one, because they answer different questions and a

Two pieces of state, not one, because they answer different questions and a
single field conflates them destructively. LastRecorded is "what the local
records already say", and advances as soon as they are rewritten.
LastAnnounced is "what the pool has accepted", and advances only on a
confirmed announce so an unreachable directory is retried on the next tick
rather than after a whole beacon interval.

Sharing one field makes an unreachable directory re-log the address change
and rewrite the same files on EVERY tick, forever: the announce never
succeeds, the field never advances, and nothing downstream can tell a host
that keeps moving from a host that cannot reach the pool.

<a id="4213a0b3-005b"></a>

## test/modules/Test.HostAddressBeacon.psm1: Renumbering-rate warning

Renumbering-rate warning. The beacon is the only thing that sees every
address change, so it is the only place that can tell "the host moved once"
from "the host is being handed a different address every lease". The second
is a lab misconfiguration the discovery path merely survives -- it costs a
directory round trip per guest per move, and it strands any guest whose
network cannot reach the directory at all -- so it is worth naming once,
with the remedy, rather than leaving the operator to infer it from a cycle
log full of repaired addresses.

Latched: said once per beacon process. A warning repeated every renewal is
a warning nobody reads.

<a id="4213a0b3-005c"></a>

## test/modules/Test.HostAddressBeacon.psm1: Get-HostAddressChangeCount

-1, never 0, when there is nothing to read. A cycle that met no address
change and a cycle whose record was never written are different facts, and
only one of them is evidence about surviving churn. Collapsing them is how
five cycles were read as "no churn happened" when three of them had churn.

The baseline row is what keeps that distinction honest in the other
direction. It parses -- so a host whose beacon is running and whose
address has never moved reports a real 0 -- but it is not a change, so it
never counts. Without it the file appeared only once a host had already
moved, and the most stable hosts in the lab were the ones reporting that
they could not be measured.

<a id="4213a0b3-005d"></a>

## test/modules/Test.HostAddressBeacon.psm1: Get-HostAddressStabilityReport

Reports the rate and stops there. Turning "N addresses a day" into
a drain -- let alone into exhaustion -- needs the lease period and
the scope size, and this beacon is handed NEITHER: it sees only its
own host's address log. The same rate is unremarkable on a short
lease and fatal on a long one, so asserting the fatal reading is a
guess wearing the costume of a measurement, and it sends whoever
reads it to the DHCP server to fix a pool that may be mostly free.
State the observation; name the two numbers that would settle it.

<a id="4213a0b3-005e"></a>

## test/modules/Test.HostAddressBeacon.psm1: Get-HostAddressStabilityReport

"Changed address N times" is only sayable when more than one
address was actually seen. A window whose changes all report the
same current address records a host that kept LOSING and
REACQUIRING one address, not one that renumbered -- no second
address was ever observed and no extra lease was drawn. Saying it
moved 62 times invents a renumbering that leaves no trace anywhere
else, and it buries the signal that is really there: something is
dropping this host's address and handing the same one back.

<a id="4213a0b3-005f"></a>

## test/modules/Test.HostAddressBeacon.psm1: Get-HostAddressStabilityReport

No address history. Which of two situations that is depends on
whether the status service was ever started here: starting it
materializes .status-service.ps1 into the runtime directory, and
the detached host-address beacon writes its first row the first time
it observes an address. No marker is the expected state of a host
that was just configured -- say so in plain terms and ask for
nothing, because there is nothing to do -- and also the steady
state of a host deliberately run with the status service disabled
(statusService.enabled false, or -NoStatusService), so the
message must not claim no cycle has run, only that recording has
not started. A marker with no history means a started service
never recorded, and that is worth a warning rather than an
advisory: an unwatched host is exactly where unbounded
renumbering hides.

<a id="4213a0b3-0060"></a>

## test/modules/Test.HostAutomationState.psm1: The version of the capture FORMAT, and equally of what its readers mean

The version of the capture FORMAT, and equally of what its readers mean. Bump
it whenever a reader starts being able to see something it could not see
before, because "present = $false" is the answer a reader gives BOTH when the
knob was genuinely unset and when it could not read the knob at all. A capture
written by an older reader is trustworthy about the values it holds and not
trustworthy about the ones it calls absent, and Invoke-HostKnobRestore is
where that distinction has to be enforced -- removal is the branch an
unreadable knob lands in, and a removal cannot be undone.

<a id="4213a0b3-0061"></a>

## test/modules/Test.HostAutomationState.psm1: Get-MacPreAutomationState

The host selector belongs AHEAD of the verb; emitted verb-first,
`defaults` binds '-currentHost' as the domain and reports every ByHost
knob as absent -- so a capture built that way records "there was
nothing here" for three knobs that hold real values, and the restore
then deletes them.

The argv is assembled INSIDE the reader so that resolving the builder
is covered by Invoke-CaptureRead's catch. This capture runs in the
seconds before the host is changed, and an install that cannot reach
the apply-side module has to record "could not be read" and let the
setup continue, not abort the setup for the sake of recording it.

<a id="4213a0b3-0062"></a>

## test/modules/Test.HostAutomationState.psm1: Get-WindowsPreAutomationState

Two performance decisions, both worth a minute of an operator's day:

  -PolicyStore ActiveStore -- the effective runtime policy, which is
  also what "is this rule enabled right now" means. Measured on a
  318-rule host: 2.6 s here against 43 s for the default store, which
  merges the persistent and GPO stores on every association traversal.
  Both stores select the identical rule set.

  ONE batched pipeline into Get-NetFirewallPortFilter, joined on
  InstanceID (which equals the rule's Name), rather than a filter call
  per rule inside Where-Object. Per-rule costs one CIM association
  traversal each -- 318 of them, 55 s.

<a id="4213a0b3-0063"></a>

## test/modules/Test.HostBootstrap.psm1: Import the three sibling modules so a caller that only imports

Import the three sibling modules so a caller that only imports
Test.HostBootstrap (or Test.HostContract -- the facade re-imports
Bootstrap) still gets the full Test.Host* surface area. -Global so the
names land in the caller's session; -DisableNameChecking because Get-* /
Test-* / Assert-* / Set-* / Update-* / Install-* span many noun families.
NOT -Force: these are SHARED siblings other modules pull in transitively,
and a -Force re-import would evict/reinitialize them (and their $script:
state) out from under those callers -- import only when absent.

<a id="4213a0b3-0064"></a>

## test/modules/Test.HostCondition.Mac.psm1: Get-MacPmsetGuardList

AlwaysApply: macOS does not list disablesleep in `pmset -g custom`
until it has been written at least once, so on a Mac that never had
it set -- the exact host that needs it -- absence would otherwise read
as "already 1" and the write would never happen. With disablesleep 0 a
MacBook suspends the moment its lid closes, taking every running guest
and the rest of the cycle down with it.
AbsentEquivalent 0: a Mac that has never had disablesleep written
behaves exactly as one holding 0 -- it suspends on lid close -- so 0
is what returns the host to where it was, not a guess at a default.

<a id="4213a0b3-0065"></a>

## test/modules/Test.HostCondition.Mac.psm1: Get-MacScreenLockIssue

7. System sleep + disk sleep -> Never. Display sleep alone (the "Display sleep -> Never" region) isn't
   enough: a system/disk-sleep wake re-locks the screen on Ventura+
   regardless of screensaver settings. Set-MacHostConditionSet disables
   both, so the gate must re-verify them.
8. Extended pmset guards (Power Nap, standby, autopoweroff, hibernate, ...)
   that Set-MacHostConditionSet applies. The gate re-verifies them from the
   same Get-MacPmsetGuardList Set- applies, so the asserted set is exactly
   the applied set and a drifted host fails here instead of blanking UTM
   mid-run. A key absent from 'pmset -g custom' (macOS-version dependent) is
   skipped here even when Set- force-writes it (AlwaysApply): a Mac with no
   lid never surfaces disablesleep at all, and failing the gate on a key
   that host cannot have would block a perfectly good desktop test host.
   A laptop that drifts back to 0 does list the key, so it still fails here.

<a id="4213a0b3-0066"></a>

## test/modules/Test.HostCondition.Mac.psm1: Initialize-SudoCache

A caller already took this run's ONE authorization and said so
(install/<host>.sh, install/setup.ps1). The timestamp is cold anyway --
it expired, or a brew cask post-install ran `sudo -k` -- and asking again
here would break the "you will be prompted ONCE" promise that caller
printed, for elevation this function does not itself need. Return $false
silently; every privileged write downstream probes for itself with
Test-MacSudoAvailable and reports the exact command to run when it cannot
elevate, which is an answer the operator can act on rather than a second
password box with no context.

<a id="4213a0b3-0067"></a>

## test/modules/Test.HostCondition.Mac.psm1: Initialize-SudoCache

Unattended: nobody is at the console to type a password. The test runner
launches its inner with native stdout attached to the console, so the inner
inherits the launch terminal -- `sudo -v` here would print its prompt to that terminal and
block the whole host until the watchdog killed it, with the status page
still showing the previous cycle's green. Decline exactly as the
wrapper-primed path does: return $false silently and let the caller
either skip the elevated work or fail it with an actionable message.
Elevation for an unattended host is a LAUNCH-time concern (or an
/etc/sudoers.d drop-in), never a mid-cycle one.

<a id="4213a0b3-0068"></a>

## test/modules/Test.HostCondition.Mac.psm1: Initialize-SudoCache

Cache cold AND no wrapper context: print the friendly notice, then prompt.

Write-Host, not Write-Output: every caller wraps this function as
`[void](Initialize-SudoCache ...)`, and that cast discards the whole
success stream -- a Write-Output notice would be swallowed, leaving the
operator with a bare "[sudo] password for ..." and no explanation. It also
keeps the [OutputType([bool])] contract honest: box lines on the success
stream make the return an ARRAY, and a non-empty array is always truthy,
so `if (-not (Initialize-SudoCache ...))` in test/Test-Config.ps1 would
never fire on the cold path.

<a id="4213a0b3-0069"></a>

## test/modules/Test.HostCondition.Mac.psm1: UTM ships its command-line interface INSIDE the app bundle, and no installer

UTM ships its command-line interface INSIDE the app bundle, and no installer
-- neither the cask nor the .dmg -- puts that directory on anyone's PATH.
Every VM operation the harness performs shells out to `utmctl`, so a host with
UTM.app correctly installed still cannot start a single cycle until the binary
is reachable by name. The link goes in /usr/local/bin because that directory is
listed in the stock /etc/paths, which means a login shell, a LaunchAgent and an
`ssh host command` all see it; Homebrew's bin only reaches shells that ran
`brew shellenv`.

<a id="4213a0b3-006a"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

Every privileged block below probes `sudo -n true` immediately before it
writes, and every write goes out with -n. The two facts an environment
variable could carry -- who started this run, whether somebody typed a
password minutes ago -- do not answer whether root is reachable NOW: the
timestamp may have expired during a long step, a brew cask post-install
may have run `sudo -k`, or an /etc/sudoers.d rule may grant the write
with no timestamp involved at all.

Initialize-SudoCache still runs first so an operator at a terminal is
asked once, visibly, with the reasons on screen, instead of meeting a
bare password prompt in the middle of a block. It declines silently when
nobody is there to ask, and the probes below then route each block to its
warn-with-the-exact-command arm. Skipped entirely without GUI disruption:
the prime can raise a password prompt, and the per-block probes already
cover a host where root is not reachable.

<a id="4213a0b3-006b"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

Display-sleep alone isn't enough: system sleep -> display locks on
wake regardless of screensaver settings. Disk sleep is the same story --
its wake re-checks lock state and on Ventura+ can engage the unified
screen lock even with askForPassword=0.

Each key is decided on its own value, through the same helper that decides
the extended guards, because the two drift apart: a host holding sleep=0
and disksleep=10 is exactly what the gate refuses, and one shared decision
read from `sleep` would report "already Never" and write nothing on every
single run -- leaving the operator re-running a setup script that cannot
reach the setting the gate is stopping on.

<a id="4213a0b3-006c"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

ONLY the pending keys. `pmset` has no delete, so a key this host never
carried can never be taken back off it: the pre-automation capture
records it as absent, and the restore has nothing to write except a
value nobody chose. Get-MacPmsetGuardPending already draws exactly the
right line -- a key present with the wrong value, plus the AlwaysApply
keys whose absence carries no information and which the guard list
gives an AbsentEquivalent so the restore can undo them. Everything it
leaves out is a name this macOS release does not surface, and writing
one buys nothing but a host setting that outlives the automation.
Key names come from the pending set so this message cannot drift away
from what is actually written.

<a id="4213a0b3-006d"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

UTM's default is to terminate once its last window closes, and its
termination path SAVES THE STATE of every VM still running rather
than leaving them alone: they come back `suspended`, not `started`.
The service VMs (caching proxy, stash, pool-control) are long-lived
infrastructure that guests consume for the whole cycle, so closing a
VM window -- or the library window -- silently takes the cycle's
dependencies offline and every guest that needs the proxy or the
stash then fails. Keeping the app resident removes the window-close
route into that state. UTM reads this at launch, so a UTM already
running keeps its old behavior until it is next started.

<a id="4213a0b3-006e"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

`sysadminctl -screenLock` is the modern (macOS 13+) unified control
that System Settings > Lock Screen > "Require password after screen
saver begins or display is turned off" writes to.
CRITICAL: overrides legacy askForPassword / askForPasswordDelay.
A machine with idleTime=0, askForPassword=0, and
askForPasswordDelay=MAX_INT can still lock after minutes because
sysadminctl reports e.g. "screenLock delay is 300 seconds".

"off" sets delay to -1 (disabled). sysadminctl requires the user's
password (not sudo) because it touches the secure keyring entry
backing lock-screen policy. `-password -` reads from stdin -- a
second prompt appears after the sudo prompt.
Get-MacScreenLockDisabled strips the NSLog prefix and applies the
shared "off" test (also used by Assert-ScreenLock's gate) so the
apply and assert paths agree on what counts as disabled.

<a id="4213a0b3-006f"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

This block needs two different things and only one of them is root.
`-password -` reads the ACCOUNT password from stdin, so a run that
cannot put a question in front of a person cannot do this at all:
under a captured child stdin is closed, the read returns EOF, and the
attempt would be reported as a FAILED disable rather than one that was
never possible. Name the one-time command instead -- also when the
caller asked for no GUI disruption, since the password read is itself
a prompt in the session's terminal.

<a id="4213a0b3-0070"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

`com.apple.autologout.AutoLogOutDelay` (system-level) is the
"Log out after N minutes of inactivity" toggle in Lock Screen /
Security. macOS kicks the user back to loginwindow after the
delay -- indistinguishable from a lock ("demands password"), but
no screen-saver / pmset key we control would prevent it. System
level (/Library/Preferences/.GlobalPreferences); the WRITE
requires sudo, but the plist is mode 644 so the READ does not --
reading it through sudo would spend an elevation on a value anyone can
see, and on a host that cannot elevate it would hide the state entirely.

<a id="4213a0b3-0071"></a>

## test/modules/Test.HostCondition.Mac.psm1: Set-MacHostConditionSet

When the harness calls `tell application "UTM" to activate` (the
AVF-guest keystroke fallback in Send-KeyUTM / Send-TextUTM), macOS
by default yanks the operator across Spaces to UTM's window -- which
is hostile when the operator has switched to VS Code on a different
Space to investigate something while a long test runs.
AppleSpacesSwitchOnActivation=false keeps the activation on the
current Space; UTM still becomes frontmost (so keystrokes route to
it), but the operator's view stays put. Dock must be restarted for
the change to take effect.

<a id="4213a0b3-0072"></a>

## test/modules/Test.HostCondition.Mac.psm1: Host clock

Permissions the harness cannot run without and that NO amount of root can
supply. macOS keeps them in the TCC databases, System Integrity Protection
guards those against every writer including root, `tccutil` can only RESET a
decision and never grant one, and the single supported way to pre-authorize
any of them is a Privacy Preferences Policy Control payload delivered by an
MDM server the Mac is enrolled with. An administrator password buys nothing
here, so no amount of elevation turns this into an unattended step.

What IS possible, and what this region does: detect each grant WITHOUT raising
a dialog, raise the system dialog and open the exact settings pane while an
operator is present, name the application they actually have to enable, and
wait for them to do it so the answer is confirmed rather than assumed.

One registry, because the same grants are reported from two places -- the
pre-cycle config gate and the per-cycle assertion. Instructions maintained
twice drift, and an operator who follows one set and is then refused by the
other has no way to tell which of the two is the stale one.

<a id="4213a0b3-0073"></a>

## test/modules/Test.HostCondition.psm1: Register-HostConditionProvider

Optional per-cycle convergence for this host's metrics exporter:
install one where there is none, then give it the collectors, port
and firewall rule the host publishes. Signature: `param()`, returns a
record with Status and Reason. Invoked by
Initialize-HostMetricsExporter.

Its own slot rather than part of Assert for the reason Assert and Set
are separate everywhere else here: Assert decides whether a cycle may
run and says so with a bool, and a host mutation hidden behind that
answer is invisible to every reader of the call.

$null for a host where this work would have to ask for its privilege.
That is the line: the unattended loop makes no repair that stops to
ask, because a loop waiting on a credential nobody is present to type
is a hang. A host registers this slot only when the cycle already
holds what the repair needs -- which is why the caller is placed after
the elevation gate rather than before it.

<a id="4213a0b3-0074"></a>

## test/modules/Test.HostCondition.Windows.psm1: Windows sibling of Test.HostCondition.psm1: applies AND asserts the

Windows sibling of Test.HostCondition.psm1: applies AND asserts the
per-host preconditions for unattended VM testing on host.windows.hyper-v
(Hyper-V service, display timeout, inactivity lock, host clock, firewall
rules for ICMPv4 + the status-service TCP port, and -- when
YURUNA_VIRTUAL_DISPLAY is set -- display/text scale = 100% so HiDPI
doesn't defeat OCR on VM screenshots), plus the report-only guest-network
probe the facade dispatches through its NetworkHealth slot. Loaded by the
Test.HostCondition.psm1 facade; callers continue to import the facade
and resolve these names through its Export-ModuleMember. See
Test.HostCondition.psm1 for the per-platform split rationale.

<a id="4213a0b3-0075"></a>

## test/modules/Test.HostCondition.Windows.psm1: Install-YurunaVirtualDisplay

Opt-in gate: the virtual display (usbmmidd attach + clone / resolution /
scale enforcement) runs only when YURUNA_VIRTUAL_DISPLAY is truthy.
Unset/false makes this a complete no-op -- no virtual display is
attached and the host's topology, resolution, and scaling are left
untouched. Test-YurunaVirtualDisplayEnabled also honors a value persisted
to the User/Machine scope so a runner launched from a shell that set it
there (and thus has a stale process block) still attaches the display.
See docs/host-hyperv.md.

<a id="4213a0b3-0076"></a>

## test/modules/Test.HostCondition.Windows.psm1: Install-YurunaVirtualDisplay

the OCR resolution floor.
The virtual display must DUPLICATE (not extend) the physical one and be the
primary so the captured surface stays alive when the physical monitor is
removed (a cable unplug hot-removes the primary; if that were the physical
the capture would freeze). Because the topology is a clone, host windows
(Display Settings, etc.) still show on the physical monitor while it is
attached. The clone source must be >=1920x1080 or OCR on the captured frame
fails. Best-effort: a topology / resolution failure must not fail the cycle
(the attached monitor is the load-bearing part), so warn and keep the
monitor status.

<a id="4213a0b3-0077"></a>

## test/modules/Test.HostCondition.Windows.psm1: Set-YurunaDisplayCloneAndResolution

The VIRTUAL display is made the primary so the surface the runner
captures is anchored to the always-present display; unplugging the
physical monitor then only drops a secondary and the guest-console
capture never freezes. A clone binds only when every active display
shares one identical mode; the virtual display is fixed at 1920x1080
(the "Force every VIRTUAL display to the 1920x1080 floor" region), so the physical monitor is normalized to 1920x1080 as well --
downscaled if it was running higher. Downscaling a high-resolution
monitor for the duration of a test run is the accepted cost of an
always-duplicated surface; the alternative (leaving a high-res monitor
extended) strands host windows on a separate desktop region. Because
the topology is a clone, the operator still sees the identical image on
the physical monitor while it is attached.

<a id="4213a0b3-0078"></a>

## test/modules/Test.HostCondition.Windows.psm1: Remove-YurunaVirtualDisplay

Tear down in escalating strength, stopping as soon as no usbmmidd monitor
remains. `enableidd 0` disables the monitor surface but leaves the device
staged for a fast `enableidd 1` next cycle. If a monitor still lingers (a
wedged devnode, or a mid-cycle KVM switch that left it present-but-
unhealthy), escalate to `stop usbmmidd`, which detaches the device node --
the vendor's own uninstall step. The signed driver INF stays in the
ProgramData cache either way, so the next run re-attaches without a
re-download (Install-YurunaVirtualDisplay re-stages the devnode if `stop`
removed it).

<a id="4213a0b3-0079"></a>

## test/modules/Test.HostCondition.Windows.psm1: Set-WindowsHostConditionSet

A refused VM memory allocation is decided by the host's commit charge
against its commit limit at that instant, and neither number survives in
any artifact the harness writes -- the only host-side record is an
Information-level Windows event nothing collects. A scraped exporter is
what makes that measurable after the fact, and carries the host's CPU,
disk and VM census with it.

Never an unmet condition, however it turns out. Telemetry that exists to
explain a failure must not become a reason for one, and a host reported
degraded over a missing metrics endpoint -- while it provisions its guests
perfectly -- is what teaches an operator to stop reading the degraded
state that matters. It warns, naming the command that fixes it, and from
then on the scrape target going down is the standing signal.

<a id="4213a0b3-007a"></a>

## test/modules/Test.HostCondition.Windows.psm1: Test-WindowsGuestNetworkHealth

The uplink classifier is private to the Hyper-V driver module,
which the operator-facing callers of this module (Test-Config,
Enable-TestAutomation) never load. Its absence means the switch
was not evaluated, which counts as usable.
Call it with -SwitchName ONLY: binding any of its record
parameters puts it in injected mode for all of them at once, so a
partially-seeded call would judge the switch against adapter and
address records nobody supplied.

<a id="4213a0b3-007b"></a>

## test/modules/Test.HostContract.psm1: Thin facade for the Test.Host* family

Thin facade for the Test.Host* family. The Test.Host* surface is
split into four siblings along feature boundaries (detection,
condition-set, git/project, host-driver bootstrap). Importing this
file imports all four siblings with -Global so callers that only
know the facade -- the runner, Debug-TestSequence.ps1, sequence
extensions -- get every export reachable. New code should import
the matching sibling directly.
Aligned with host/Yuruna.Host.Contract.psm1: the test-harness side
of the host-contract boundary.

<a id="4213a0b3-007c"></a>

## test/modules/Test.HostContract.psm1: Test.HostDetection carries the Test.VMUtility -Global self-heal at its

Test.HostDetection carries the Test.VMUtility -Global self-heal at its
own module scope, so importing it (first in the list below) re-lands
Wait-VMRunning / Test-IpAddress / Format-IpUrlHost in the caller's
session on every facade load. Keeping the self-heal only in the sibling
also covers the callers that import Test.HostDetection directly without
going through this facade.
Yuruna.Common carries Get-YurunaServiceVmName, which Stop-ConcurrentVM's
exemption list resolves at parameter-binding time. Imported here rather than
relied on from a host driver's -Global import: the default has to bind even
when the caller reached this facade without loading a driver.

<a id="4213a0b3-007d"></a>

## test/modules/Test.HostDetection.psm1: Host detection + per-host preflight: identifies the platform

Host detection + per-host preflight: identifies the platform
(host.macos.utm / host.windows.hyper-v / host.ubuntu.kvm),
maps host type to repo folder, derives test VM names, asserts
the minimum runtime requirements (elevation on Windows, /dev/kvm
on Linux, UTM bundle on macOS), and handles the libvirt-group
re-exec dance for fresh Ubuntu installs. Deliberately excludes
anything that mutates host configuration (Set-*HostConditionSet
lives in Test.HostCondition.psm1) or that imports host drivers
(Initialize-YurunaHost lives in Test.HostBootstrap.psm1).

<a id="4213a0b3-007e"></a>

## test/modules/Test.HostDetection.psm1: Module-level self-healing: re-import Test.VMUtility.psm1 with -Global

Module-level self-healing: re-import Test.VMUtility.psm1 with -Global
every time this module is loaded. The inner imports Test.HostContract in a
fresh process each cycle, and the facade imports this sibling;
the -Global import here keeps Wait-VMRunning / Test-IpAddress /
Format-IpUrlHost (and the other cross-host helpers) in the runner's
session even when something mid-cycle has wiped the global module table
-- e.g. a sequence step calling `Get-Module | Remove-Module`, or a
transitive Import-Module without -Global. Without this, a caller's runspace
could lose Wait-VMRunning at an unrelated moment
and crash at the next New-VM.Resource step. This module (not the
Test.HostContract facade) owns the self-heal so it also fires for the
callers that import Test.HostDetection directly. -ErrorAction
SilentlyContinue: a missing sibling is non-fatal here;
Initialize-YurunaHost still fails loudly later if truly broken.

<a id="4213a0b3-007f"></a>

## test/modules/Test.HostDetection.psm1: Get-TestVMName

Shell-safety guard at the composition ingest point. The VM name flows
into interpolated commands downstream -- a KVM `bash -c` virt-viewer
invocation and hypervisor CLIs on every platform. The HostId segment is
reduced to [A-Za-z0-9] above, but neither the operator-configurable prefix
(vmStart.testVmNamePrefix) nor the guest key is: either one carrying a
space or shell metacharacter would ride through the interpolation. Reject
here so a metacharacter name can never reach a command string, whichever
host type ends up running it.

<a id="4213a0b3-0080"></a>

## test/modules/Test.HostDetection.psm1: Test-HostRequirement

Quiet mode: suppress the trailing "There may be more host-health
recommendations available..." pointer. Existing failure
Write-Warning lines are NEVER quieted -- a missing requirement
is always shown. The pointer is the only banner this switch
silences; an automated caller (Remove-TestVMFiles.ps1 -Quiet)
passes -Quiet so the cycle teardown emits no host-health noise.
The inner Write-Information's hardcoded -InformationAction
Continue otherwise overrides any caller -InformationAction
SilentlyContinue, which is why an explicit switch is needed.

<a id="4213a0b3-0081"></a>

## test/modules/Test.HostGit.psm1: Invoke-GitPull

Fetch without modifying working tree. Linear-backoff retry on
failure: on macOS the Application Firewall stalls outbound TCP
connects right after a process opens a new listening socket
(status service, caching-proxy-service forwarders). Shows up as "Couldn't
connect / No route to host" on the first fetches of a fresh
runner and has recovered past a 5s wait in observed runs. 5
retries with 10/20/30/40/50s waits cover ~2.5 min of blip without
masking a genuine outage.

<a id="4213a0b3-0082"></a>

## test/modules/Test.HostIdentity.psm1: Host identity for the pool: a reimageable host loses its local runtime/ (and

Host identity for the pool: a reimageable host loses its local runtime/ (and
with it host.uuid), so without a way to re-recognize the same physical box its
pool history would fork under a fresh uuid every reinstall. After each
poolStorage drain a host publishes <networkPath>/hosts/info.<uuid>.yml carrying
its uuid + a hardware fingerprint. On the next Enable-TestAutomation a host with
NO local uuid scans those records and, when a fingerprint matches strongly
enough, offers to RECLAIM the prior uuid (operator confirms -- never silent).

The strong fingerprint keys (SMBIOS product UUID, baseboard serial) are
root-only on Linux, which the unprivileged per-cycle drain cannot read. So the
fingerprint is gathered ONCE, PRIVILEGED, at Enable-TestAutomation (sudo is
primed there) and cached to runtime/host.hwid.json; the drain reads the cache.

<a id="4213a0b3-0083"></a>

## test/modules/Test.HostIdentity.psm1: Invoke-PoolStorageSetupAndReclaim

A config sync from a reference host writes all three pool values and
stores the matching vault credential. Asking for them again after that is
not a harmless confirmation: the questionnaire is the ONLY way this
function reaches the mount and the identity reclaim below, so the operator
has to retype -- by hand, from the reference host -- values the sync
already fetched, and a typo silently replaces a working configuration.

Completeness is judged on the config AND the credential, because either
alone still leaves a mount that cannot work. Changing a configured host is
the sync's job (or an edit to test.config.yml); this path exists to
configure one that is not.

<a id="4213a0b3-0084"></a>

## test/modules/Test.HostIO.psm1: Host I/O provider registry

Host I/O provider registry. The model mirrors Test.OcrEngine.psm1: each
(HostType, Action) pair is a registered scriptblock; the dispatcher
looks the pair up and invokes it. A single lookup table replaces what
would otherwise be parallel if/elseif chains on $HostType inside every
action (Send-Key, Send-Text, Send-Click, ...), and a missing backend
is surfaced via the capability matrix rather than as "Unknown host:
$HostType" deep in the sequence run.

The capability matrix (Get-HostIOProviderMatrix) provides startup-time
visibility of what each host can actually do -- see docs/host-io.md.

<a id="4213a0b3-0085"></a>

## test/modules/Test.HostIO.psm1: Two-level table: { HostType -> { Action -> scriptblock } }

Two-level table: { HostType -> { Action -> scriptblock } }. Ordered so
Get-HostIOProviderMatrix returns hosts and actions in the registration
order, which (today) puts the local host first in any matrix dump.

The outer table is backed by the shared Test.Registry primitive
(New-YurunaRegistry). The $global:YurunaHostIOProviders anchor name
is the documented entry point for cross-module readers that inspect
the registry directly. Inner per-host hashtables remain plain
[ordered]@{} (the primitive holds them as opaque values).

<a id="4213a0b3-0086"></a>

## test/modules/Test.HostMetricsExporter.psm1: The collectors this host must publish, and why each one is on the list:

The collectors this host must publish, and why each one is on the list:
  memory       -- committed bytes and the commit limit, the pair that
                  explains a refused allocation; nothing else exposes them.
  os           -- host identity and operating-system information.
  cpu          -- per-core time, to separate a stalled host from a busy one.
  logical_disk -- free space, which fails a guest's disk creation the same
                  silent way a commit ceiling fails its memory.
  hyperv       -- per-VM state, so a host's VM census at an incident is a
                  recorded series rather than a memory of what was running.
Kept deliberately short: every collector is scraped on every interval, and
the exporter's defaults differ between releases, so the set is stated rather
than inherited.

<a id="4213a0b3-0087"></a>

## test/modules/Test.HostMetricsExporter.psm1: How long one unattended install attempt may run before it is stopped, and the

How long one unattended install attempt may run before it is stopped, and the
only place that number is written. The work behind it is a package download of
a few tens of megabytes and a service registration, so three minutes is
several times what it costs -- reaching this bound is evidence that something
is wrong rather than slow. It is a ceiling on what a cycle can lose to
telemetry it does not need to run, which is the only reason it is
bounded at all. Callers do not carry a second copy of it: two owners of one
bound is how a bound stops being enforced without anybody noticing.

<a id="4213a0b3-0088"></a>

## test/modules/Test.HostMetricsExporter.psm1: Get-YurunaHostMetricsInstallAttempt

ConvertFrom-Json recognizes a round-trip timestamp and hands back a
[datetime], already carrying the right instant and Kind. Formatting
that back into a string to re-parse it is what breaks: the default
format drops the zone marker, so the re-parse reads a UTC instant as a
local one and the record lands one whole UTC offset away -- which on a
host west of the meridian reads as an attempt in the FUTURE and
cancels the interval, and east of it silences the install for hours
longer than intended. So the typed value is used as the typed value,
and only a value that really is text is parsed as text.

<a id="4213a0b3-0089"></a>

## test/modules/Test.HostMetricsExporter.psm1: Invoke-YurunaWingetInstall

The install call itself, kept as its own seam so every caller above can be
exercised without a package manager. The argument list it runs -- and the
reason nothing in that list can lead to a prompt -- is
Get-YurunaHostMetricsInstallArgument.

The streams are deliberately NOT redirected, and neither -Wait nor the
parameterless WaitForExit() is used. Redirecting any stream turns on
handle inheritance for the whole subtree, which is how a descendant that
outlives this call pins the pipe an enclosing process is reading and hangs
it with no output and no timeout (see feedback_windows-detached-grandchild-
pins-pipe). Passing no streams makes this a ShellExecute spawn, which
hands down no inheritable handles at all; the timed WaitForExit overload
waits on this process alone; and the package manager's own log file is
where the diagnostic goes instead.

Killing on the deadline stops this process waiting -- it does not stop an
installer already handed to the operating system's own installer service.
That is why the caller decides the outcome by looking for the service
afterward rather than by trusting the exit code: an install that lands a
minute after the deadline is found by the next cycle's presence check.

<a id="4213a0b3-008a"></a>

## test/modules/Test.HostRefresh.psm1: Host refresh: the repair-ladder declaration, the local repair worker and

Host refresh: the repair-ladder declaration, the local repair worker and
everything a caller needs around it (budget, verdict and exit code, public
progress projection, context and identity resolution, command closure).

The module holds no driver import. The generated status-server child loads
it through Import-RouteModule to advertise the capability without ever
calling Initialize-YurunaHost; loading a driver there would force-import
Test.CachingProxyService and run that driver's contract-coverage check
inside the listener. Every driver, service-evidence and runner-protocol
command the worker uses is therefore resolved by name at call time, and a
missing one is a structured refusal or a skipped rung, never a crash.

<a id="4213a0b3-008b"></a>

## test/modules/Test.HostRefreshAuth.psm1: Write-HostRefreshSecretFile

Writes one or more secret lines owner-only from the first byte. Each
temporary file is created beside its destination with mode 0600 (Unix)
or an owner-only ACL (Windows) and verified private before any secret
byte is written, then flushed. Only once every file is staged are they
renamed into place, in order: a failure while creating, checking or
writing leaves every destination as it was, and only a rename failing
after an earlier one succeeded leaves the set partly replaced, which its
own refusal names. Every refusal names paths, never content, and removes
each temporary file not yet renamed.

<a id="4213a0b3-008c"></a>

## test/modules/Test.HostRefreshIntent.psm1: The private request journal for host refresh: who asked for a repair, with

The private request journal for host refresh: who asked for a repair, with
which immutable policy, what each attempt did, what it disrupted and still
owes, and which request ids are closed for good.

  * Everything lives under the private state root ($HOME/.yuruna/host-refresh),
    which is outside every tree the status service serves; the public
    progress file in the runtime directory is a projection and never
    authoritative.
  * One checksummed, generation-numbered record (Test.CriticalRecord) holds
    the whole journal, and every read-modify-write happens under one short
    admission lock. The lock order is the lifetime repair lock, then the
    admission lock, and never the reverse: a worker claims under both, the
    listener and the outer runner take only the admission lock.
  * Age never evicts anything alive. Liveness is decided by process identity
    (pid plus start time); an identity that cannot be read is unknown, and
    unknown is treated as alive.
  * A request that disrupted something keeps its obligations until they are
    verified or explicitly disposed by a local operator; no verdict silently
    discharges them.

<a id="4213a0b3-008d"></a>

## test/modules/Test.HostRefreshTrigger.psm1: The automatic host-refresh policy: when the resident runner may start a

The automatic host-refresh policy: when the resident runner may start a
hypervisor repair on its own, and how it proves the repair ran.

Three processes are involved and only files cross between them. The inner
runner observes the hypervisor (the service-VM restore sweep) and writes one
evidence file per cycle, stamped with the generation the resident outer
minted for that cycle; the per-cycle process only relays its exit; the
resident outer consumes the file right after the dispatch, keeps the
timeout count in a private file and decides. A sidecar from any other
cycle is rejected by its generation, so a stale observation can never
count twice or count for the wrong cycle.

The count and the daily budget live in separate private files on purpose:
a responsive observation clears the count, but nothing but the passage of
a UTC day frees the budget, and a clock set back never does. The budget
ledger is a checksummed critical record written under the admission lock
before any request exists, so a crash after the reservation still counts
the day as used -- the fail-safe direction for an unattended restart.

Every platform is declared unqualified until a native canary proves the
repair on it; the runner still reads the knob, counts the evidence and says
once why it does not act. The module joins no entry-point module set: the
resident outer and the inner import it guarded at their call sites, and
everything heavy (the repair journal, the lock, the critical record, the
private-root helpers, the refresh-gate reader the journal's admission
consults) resolves lazily by name, so a missing piece yields a
structured 'dependency-missing:<module>' refusal instead of an exception in
a loop that must keep running.

<a id="4213a0b3-008e"></a>

## test/modules/Test.InnerSpawn.psm1: Two launch shapes for a fresh child pwsh live here.

Two launch shapes for a fresh child pwsh live here.

New-InnerRunnerArgList builds the -Command vector the runner uses for its
inner and per-cycle children:
Why -Command (not -File):
  pwsh's -File parameter binder coerces every argv token to [string],
  which breaks [bool]/[int] inner parameters. -Command parses the line
  as PowerShell so $true/$false/0/1 keep their types.
Why -NoProfile:
  $PROFILE in the launching shell can re-set YURUNA_* env vars in the
  child AFTER the parent's snapshot pinned the right values.
Why a helper module:
  Start-TestRunner.ps1, Invoke-TestProject.ps1 and Invoke-TestCycleRunner.ps1
  all need the same single-quote escaping + -Command construction; duplicated,
  a quoting-edge-case fix in one would not reach the others.

Start-YurunaDetachedProcess launches a worker that must outlive its
launcher -- a host-refresh worker, a restarted runner -- with -File, one
argument per element, -NonInteractive, and all three streams detached from
the launcher. On POSIX the stream paths travel in the environment and every
argument is a positional parameter of a fixed `set -m; nohup "$@"` body, so
no caller value is ever interpolated into shell text; `set -m` rather than
setsid gives the child its own process group, because macOS has no setsid.
On Windows a first hop, started without redirected handles, launches the
final worker with the redirections: a launcher that redirects hands every
inheritable handle it holds to its child, which is what keeps a caller's
wait from ever returning.

<a id="4213a0b3-008f"></a>

## test/modules/Test.KeyCodeRegistry.psm1: Maps owned by this module

Control chords need their own map family: the *-Named maps hold a SCALAR
code per name and every backend dereferences them as a scalar, so an array
entry there would be read as a truthy object rather than a chord. A chord
is also not a character, so the *-Char maps (keyed on the literal char and
carrying a needsShift flag) cannot express it either.

Naming a chord ('CtrlU') instead of widening Send-Key with a -Modifier
parameter keeps the whole keystroke stack untouched: the host facade
contract, the Invoke-Sequence dispatcher and the per-host registry
scriptblocks all forward a single KeyName string, so a named chord needs
no signature change anywhere.

The two chords the harness relies on are the canonical-mode tty controls:
Ctrl+U is VKILL (discard the current input line) and Ctrl+C is VINTR
(interrupt the foreground process group).

<a id="4213a0b3-0090"></a>

## test/modules/Test.Lab.psm1: Lab-level knowledge shared by the lab entry points: what a lab vault records,

Lab-level knowledge shared by the lab entry points: what a lab vault records,
where a machine's labs put their storage, and which credentials the machine
already holds. One module owns the lab-vault format so a reader and a writer
cannot drift on it.

The two vaults this module touches are NOT interchangeable:
  * the LAB vault (lab.<name>.vault.yml) is per-lab and deliberately COPYABLE
    to the lab's other machines;
  * the HOST vault (vault.yml) is per-machine and is what the harness reads.
Where they carry the same credential they must agree, which is the reason
Get-YurunaMachineCredential exists -- see its description.

Everything here is READ-ONLY. Nothing in this module creates, rotates, or
stores a credential.

<a id="4213a0b3-0091"></a>

## test/modules/Test.LabHealth.psm1: The lab-health gate: before a chain entry and before each sequence step, check

The lab-health gate: before a chain entry and before each sequence step, check
the services this lab declares, and hold the cycle while one that WAS
answering has stopped answering.

The probe set is DERIVED, never configured: every extension area already
declares healthPort/healthPath in its <area>.config.yml `service:` block, and
Get-ExtensionServiceManifestAll walks them. An area that ships tomorrow is
gated the day it lands; an area that declares no health surface is out of
scope. A per-service list here would have to be edited for each one and would
be wrong the first time it was not.

The gate arms on a CHANGE of condition, not on absolute state. A service this
host has never reached is not a change -- holding for it would park a fresh
host forever, where the caller's own preflight gives a fast, accurate "there
is no stash here". So a hold needs a lastOkUtc inside the arming window, and
that record is kept ACROSS cycles: a service stopped for a rebuild is already
gone when the next cycle starts, so a baseline captured at cycle start would
never see the transition it exists to catch.

Leaf module. Every cross-module dependency (Get-PollDelay, the extension
readers, Send-CycleEventSafely, Write-YurunaStateFileJson) is resolved at CALL
time and Get-Command-guarded, so a probe degrades to "cannot tell" rather than
throwing inside a step gate.

<a id="4213a0b3-0092"></a>

## test/modules/Test.Locale.psm1: Which language a reader gets, decided once and then carried.

Which language a reader gets, decided once and then carried.

Every runtime that renders text has to answer the same question, and they
have to answer it the SAME way: a page in one language beside a transcript
in another is worse than either language alone. So the answer is defined by
a fixture corpus (globalization/fixtures/locale-matching.json) that this
module, the browser and Go each run, rather than by three implementations
that were written from the same paragraph of prose.

The rules that are easy to get wrong, and why they are what they are:

  q=0 is a refusal. RFC 9110 says a zero quality means "not acceptable",
  so a tag carrying it is removed from consideration rather than ranked
  last -- otherwise a client that explicitly rejected a language is served
  it whenever nothing else matches.

  A bare wildcard selects no candidate. "*" states no preference, so later
  inputs or the default decide; answering it with the first supported tag
  would make the served language depend on a table's order.

  An undeclared region falls back. pt-AO is not pt-BR: guessing that any
  Portuguese is Brazilian Portuguese hands a reader a dialect no reviewer
  approved. Only aliases the manifest declares are followed.

  The resolved tag names a FILE. It is matched against the supported set and
  never used as a path fragment, because the input reaching this function
  arrives from an HTTP header.

The context this produces is immutable and scoped to one cycle, one command
or one request. There is deliberately no process-global "current locale":
a service answering two readers at once must not have one.

<a id="4213a0b3-0093"></a>

## test/modules/Test.LocalLabStorage.psm1: Local lab storage: turn ONE machine into its own pool/stash SMB server and

Local lab storage: turn ONE machine into its own pool/stash SMB server and
then consume those shares over the network stack, exactly as it would consume
a NAS. The point of the loopback is uniformity -- the runner, the config gate,
the drain, and the guest seeds all take the SMB path, so a single-machine lab
exercises the same code as a lab with a real NAS and can later be pointed at
one by changing only the host alias.

This module owns the per-OS half of that (accounts, the SMB server, the
shares, the loopback exemptions); the mount itself is Test.PoolStorage's
Connect-YurunaPoolStorage, unchanged, so there is exactly one mount
implementation in the tree.

The pure helpers (path composition, drive selection, smb.conf text, registry
merge) are separated from the OS calls so they are unit-testable on any
platform -- the OS calls are integration-verified, since they mutate the host.

<a id="4213a0b3-0094"></a>

## test/modules/Test.LocalLabStorage.psm1: Runs a native command, returning its merged stdout+stderr and throwing on a

Runs a native command, returning its merged stdout+stderr and throwing on a
non-zero exit with that output attached. The output is the whole diagnostic
value here: `sharing`, `smbpasswd`, `sysadminctl`, and `testparm` all exit 1
for a wide range of unrelated causes, so the exit code alone never says what
to fix. -AllowFailure turns it into a probe that returns the result instead.

The sudo path goes through Invoke-YurunaSudo rather than running sudo here.
sudo reads its password from /dev/tty, so a run whose console belongs to a
parent cannot stop a bare `sudo` from prompting where nobody can see it --
Invoke-YurunaSudo adds -n on exactly that path and recognizes sudo's own
refusal signatures. That distinction is what -AllowFailure must NOT swallow:
most of the calls below are probes whose non-zero exit is the answer ("no such
sharepoint", "package absent"), but "sudo would not run this at all" is not an
answer to any of them, and treating it as one is how half a storage
configuration gets built and then reported as the tiers it did create.

<a id="4213a0b3-0095"></a>

## test/modules/Test.LocalLabStorage.psm1: Set-MacSmbCredential

`dscl -passwd`, NOT `sysadminctl -resetPasswordFor`. Both set the password
and both leave OpenDirectory accepting it -- `dscl -authonly` passes either
way -- but only the directory-level write regenerates the stored hashes
through the hash list that was just changed. Via sysadminctl the account
ends up with a correct password and no NT hash, which is precisely the
split this failure has: OpenDirectory says yes, smbd says
"server rejected the authentication", and the mount that follows reports
the rejection as "No such file or directory".

<a id="4213a0b3-0096"></a>

## test/modules/Test.LocalLabStorage.psm1: Set-LocalLabStorageAccount

sysadminctl takes the password on its argument vector, briefly exposing
it to `ps`. There is no stdin-capable equivalent on macOS; the same
residual exposure is accepted (and documented) by New-LocalTestUser and
by the macOS branch of the poolStorage mount.

sysadminctl has no '--' end-of-options marker, so a leading '-' would be
parsed as an option and the account would end up with a password the
vault does not agree with. New-Lab reuses a host-vault credential when
one is already present, and a hand-populated entry carries no
leading-character guarantee, so this is reachable -- same guard as
New-LocalTestUser.

<a id="4213a0b3-0097"></a>

## test/modules/Test.LocalLabStorage.psm1: Set-YurunaHostAlias

Re-launched under sudo because the hosts file is root-owned and
Set-HostAlias refuses to run as an unprivileged user. The argument
vector comes from Get-SudoPwshArgumentList: a bare 'pwsh' under
sudo's stripped environment dies with a .NET "libhostfxr not found"
exit 131, three steps before the vault and the config are written.
The prompt names whose password and what for: sudo's default says
neither, and this elevation lands in the middle of a run that has
been generating and storing lab credentials, so an unnamed
"Password:" reads as a request for one of those.

<a id="4213a0b3-0098"></a>

## test/modules/Test.LocalLabStorage.psm1: A machine that served its own shares and now consumes a lab's has to stop

A machine that served its own shares and now consumes a lab's has to stop
being a storage server, and every step above needs an inverse for that. They
are grouped here rather than beside their creators so the destructive half of
this module is one region an operator can read end to end before running it.

The DATA is never touched by anything in this region. The folders under the
storage root hold finished cycle archives, stash artifacts, the lab vault, and
the pool-intent repository -- content whose only copy may be there. What comes
down is the SERVING configuration: the share definitions, the accounts scoped
to them, the loopback exemptions, and the aliases. That split is what makes the
teardown safe to run before the operator has decided anything about the bytes.

<a id="4213a0b3-0099"></a>

## test/modules/Test.Log.psm1: One of THREE Yuruna logger modules with disjoint responsibilities --

One of THREE Yuruna logger modules with disjoint responsibilities --
see test/modules/README.md "Three loggers, three jobs" before adding
helpers here. This module owns ONLY the cycle-filesystem layout:
Start-LogFile, Stop-LogFile, Get-CycleGuestDataFolder, Get-CycleScreenDir,
Write-CycleNdjsonEvent, Write-CycleManifest. Sibling modules: Yuruna.Log
(stream interceptor) and Test.Output (per-script PASS/FAIL tally).
Don't add Write-* cmdlet wrappers or PASS-counting helpers here -- they
belong in the other two.

Two cross-module channels are intentionally process-wide: __YurunaLogFile
(set here, read by the Yuruna.Log proxy) and __YurunaCycleFolder (the
cycle's folder under test/status/log/, read by failure / diagnostics
helpers so the path doesn't have to thread through every call site).

<a id="4213a0b3-009a"></a>

## test/modules/Test.Log.psm1: Start-LogFile

Allocate the cycle folder with a `.incomplete` suffix so a
crashed cycle is visible at the folder-name level (in addition to
the in-folder marker file). Stop-LogFile renames to the bare
<base>/ on clean close; boot recovery renames to
<base>.aborted.<UTC>/ when it sees the crash on startup. Every
NDJSON event records the bare <base> as `cycleFolder` (the
cycle's stable identity) regardless of which suffix is on disk
at emit time -- consumers join events across the rename boundary
without seeing the suffix flip mid-cycle.

<a id="4213a0b3-009b"></a>

## test/modules/Test.Log.psm1: Start-LogFile

The OWNING cycle's identity, held separately from the folder
events are written into. A nested run repoints __YurunaCycleFolder
at its own subfolder so its transcript and events land beside it,
and deriving the cycleFolder stamp from that would label a child's
events with the child's leaf -- splitting one cycle into as many
apparent cycles as it has nested nodes, none of them joinable to
the cycle that actually ran. This handle is what the stamp comes
from, and a nested run inherits rather than replaces it.

<a id="4213a0b3-009c"></a>

## test/modules/Test.Log.psm1: Start-LogFile

Stable run-correlator stamped on every NDJSON record by Write-
CycleNdjsonEvent. cycleFolder alone IS unique on a single host,
but a multi-host pool consumer joining live streams off three
boxes would otherwise have to parse the leaf name to recover
the originating cycle time. cycleStartUtc is the ISO timestamp the
outer assigned at cycle start. Pool consumers combine it with hostId to
identify each host's cycle; the timestamp alone cannot distinguish cycles
that start at the same instant on different hosts.

<a id="4213a0b3-009d"></a>

## test/modules/Test.Log.psm1: Start-LogFile

Which code produced this cycle, carried on the event itself: a
consumer reading the stream off-host has only these lines, and the
host's status document by then describes whatever cycle is running
now rather than the one these events belong to. Same {sha, repoUrl}
shape the status document and each of its history rows use, so one
reader parses commits everywhere. Omitted rather than emitted empty --
a cycle whose commits were never resolved must not arrive looking
like a cycle that ran no code.

<a id="4213a0b3-009e"></a>

## test/modules/Test.Log.psm1: Write-CycleManifest

Save-StepFailureEvidence copies the ring-buffer frames and the
failure pair into <VM>/failed_<label>/, so they arrive carrying
a path prefix that the anchored patterns above and below cannot
match, and without these they are filed as 'other'.
The relocated ring frames keep the RAW kinds: they are the
same frames, only copied, and the raw kinds are the ones the
manifest skips hashing. Hashing a whole ring per failed
attempt costs seconds of cycle time and tells an operator
nothing the frame itself does not.

<a id="4213a0b3-009f"></a>

## test/modules/Test.Log.psm1: Stop-LogFile

cycle_end emitted BEFORE the manifest so the manifest's
artifact scan picks up the now-completed
cycle.events.ndjson. NDJSON write is best-effort; the
gap-sentinel inside Write-CycleNdjsonEvent surfaces
any failure.
How many times this host's address moved while the cycle ran. On a
host whose lease is deliberately short, that number is what makes
the verdict mean something: a pass with three changes inside it is
evidence the harness survives IP instability, and a pass with none
is evidence only that the network was quiet. Without it the two are
the same word in the same place. The beacon module is a soft dependency:
an absent module reports -1 (unmeasured), while a measured host whose
address did not move reports 0. Neither case fails to close the cycle.
-1, not 0, when the count cannot be taken. Zero is a MEANINGFUL
answer here -- it is the one that says this cycle ran on a quiet
network and proves nothing about surviving churn -- so a failure to
measure must not be able to imitate it. Reporting an unmeasured
cycle as zero is worse than reporting nothing: it reads as evidence.

<a id="4213a0b3-00a0"></a>

## test/modules/Test.Log.psm1: Stop-LogFile

The count above says what this ONE cycle met. The verdict says
whether the host is bounded at all, which is the question a
week-long lease makes urgent and which no single cycle can answer.
Emitted as its own event so it reaches the same log the dashboard
already reads: the periodicity verdict existed for a while with no
route off the host, which made it detection nobody could act on.
Best-effort and never fatal -- a cycle must still close if the
bridge cannot be interrogated.

<a id="4213a0b3-00a1"></a>

## test/modules/Test.Log.psm1: Stop-LogFile

Mirror the cycle's last_failure.json into the cycle folder BEFORE
the manifest sweep, so the full schema-v2 record -- matched
pattern, label, OCR tail, repro, inner cause -- persists with the
cycle for post-hoc analysis, not just the flattened step_failure
event in cycle.events.ndjson. Write-CycleManifest classifies both
the cycle-level copy and each guest's own, so the mirrored files
are cataloged automatically.

This is the refresh pass, not the only chance: every writer of the
record mirrors it at classification time through
Copy-CycleFailureRecord, because the root copy under
$env:YURUNA_LOG_DIR is cleared at every sequence start and is
routinely gone by the time a cycle ends.

A cycle that recovered -- a warm resume re-ran the failed sequence
and it passed -- reaches a pass outcome with the first attempt's
mirrors still in the folder. A record anywhere under the cycle
folder means "this cycle failed", and the manifest catalogs it as
such, so a pass clears every copy, the per-guest ones included; the
step_failure event keeps the recovered attempt observable in the
stream.

<a id="4213a0b3-00a2"></a>

## test/modules/Test.Log.psm1: Stop-LogFile

The remediation dispatcher's decision (Invoke-Remediation) rides
the same archive path as the failure it routed on, so the cycle
folder -- and the pool copy of it -- carries the recommendation
next to the failure. Only on a non-pass outcome: a passing cycle
has no remediation of its own, so any file present is stale.

A non-pass outcome alone is not enough to prove ownership. The
source sits in the log ROOT, shared by every cycle, and the
dispatcher does NOT run for every failure -- one that stops
before classification (a preflight refusing to start the
cycle) leaves the root file untouched. Copying on presence
then hands this cycle the PREVIOUS cycle's recommendation,
which reads as a diagnosis of a failure it never saw and sends
the operator after the wrong cause. Match the run stamp
instead; an unstamped record predates the stamp and is
likewise not ours.

<a id="4213a0b3-00a3"></a>

## test/modules/Test.Log.psm1: Telemetry is best-effort by design: a cycle never fails because an event could

Telemetry is best-effort by design: a cycle never fails because an event could
not be written. That policy hides one thing every consumer needs -- whether the
stream it is reading is complete. A remediation loop that finds the stream quiet
cannot tell "nothing happened" from "the writer broke", and a writer that was
never loaded leaves no trace at all.

So every emission is counted, and every loss is recorded with its reason in
cycle.events.delivery.json beside the stream, where the manifest catalogs it.
The first loss in a cycle is also a warning. None of this changes what a
failed write does to the cycle: the original failure keeps its own reason, and
the ledger only says how much of the evidence around it made it to disk.

<a id="4213a0b3-00a4"></a>

## test/modules/Test.Log.psm1: Write-CycleNdjsonEvent

Stamp cycleFolder + cycleStartUtc on every record so off-host consumers
can join events back to their cycle without reparsing the file
path or the leaf-name format. Existing values from the caller win
(cycle_start in particular already carries both); only set when
missing. Pool consumers use hostId together with cycleStartUtc as the
cycle key, so equal timestamps from different hosts remain separate cycles.

Stamp cycleFolder as the cycle's stable IDENTITY, not the
on-disk leaf -- the on-disk folder transitions
<base>.incomplete/ -> <base>/ -> <base>.aborted.<UTC>/, and the
NDJSON stream must NOT flip the cycleFolder field across those
renames or a streaming consumer's join would break. Get-CycleFolderIdentity
strips any of the three suffixes.

<a id="4213a0b3-00a5"></a>

## test/modules/Test.LogLevel.psm1: Canonical log-level cascade

Canonical log-level cascade. Why this lives in its own module: it is
the single source for the rank table + preference-cascade logic shared
by Invoke-TestRunnerInnerLoop.ps1, Debug-TestSequence.ps1, Test.SequenceEngine.psm1,
and every host/<platform>/guest.<x>/{Get-Image,New-VM}.ps1 (28+
consumers). A new level (or a tweak to ProgressPreference) is a single
edit here instead of a hand edit in every copy.

See docs/loglevels.md for the cascade semantics and why env-var
propagation is the only way to reach child pwsh processes.

<a id="4213a0b3-00a6"></a>

## test/modules/Test.LogLevel.psm1: The two values below are deliberately NOT in module scope

The two values below are deliberately NOT in module scope. `Import-Module
-Force` builds a fresh module instance with fresh session state, so a guard
kept in $script: stops guarding the moment a nested in-process script
re-imports this module (feedback_module_force_import_evicts_global) -- and
both of these describe the process, not a module instance. The $global: scope
belongs to the runspace and a forced re-import leaves it intact, so it is the
widest variable scope reachable from here; module load must therefore never
overwrite a value an earlier instance left behind.
Test-Path over the variable drive rather than Get-Variable: the probe runs on
every import, and a Get-Variable miss records a "Cannot find a variable" entry
in $Error even under -ErrorAction SilentlyContinue, which is noise in exactly
the postmortem this module exists to make readable.

<a id="4213a0b3-00a7"></a>

## test/modules/Test.LogLevel.psm1: Path this process is transcribing to, or $null when it is not, paired with

Path this process is transcribing to, or $null when it is not, paired with
the pid that opened it -- the same key the file name is built from, so a
value that does not describe THIS process can never suppress its
transcript. Without the guard a second Start-Transcript succeeds (PS 7
allows concurrent transcripts): both writers open the one path in Append
mode, each seeks to end-of-file once at construction and then advances its
own offset, so the later writer overwrites the earlier one's lines instead
of following them, and the file ends with one start block and N end blocks.

<a id="4213a0b3-00a8"></a>

## test/modules/Test.Notify.psm1: Send-YurunaNotification is a thin dispatcher to the active extensions

Send-YurunaNotification is a thin dispatcher to the active extensions
under test/extension/notification/. Each extension exports the contract verb
  Send-Notification -EventCode <string> -EventMessage <string> -EventNote <string>
and the dispatcher invokes it.

The dispatcher is deliberately NOT called Send-Notification. Extensions are
imported into the GLOBAL scope, so a dispatcher sharing the contract verb's
name would be shadowed by the extension the moment the first one loads -- and
every unqualified caller from then on would reach the transport directly,
skipping the dispatch loop, the -EventData gate, and the delivery ledger. That
failure is silent by construction: the caller's own try/catch swallows the
parameter-binding error and the alert is never sent. Two distinct names
make the collision impossible rather than merely unlikely.

Format-FailureMessage stays here so callers can build the EventNote
body from structured fields without re-implementing the format.

<a id="4213a0b3-00a9"></a>

## test/modules/Test.Notify.psm1: Send-YurunaNotification

Fire-and-forget; the cycle's failure path returns immediately.
The thread job inherits the runspace's module table so $cmd
resolves the same way as the synchronous branch.

Delivery outcome is persisted to <cycleFolder>/notification.delivery.json
(append-only JSON Lines) from inside the thread job so an
autonomous remediator can see whether the escalation channel
actually received the alert. Without this, a Resend HTTP 503
is swallowed at Write-Warning and the cycle's transcript looks
like the operator was notified when no one was.

<a id="4213a0b3-00aa"></a>

## test/modules/Test.Notify.psm1: Get-FailureEventData

Where the record IS depends on when we are asked. While a cycle runs, the
engine and the infra stages write last_failure.json to the log ROOT
($env:YURUNA_LOG_DIR) and mirror it under the cycle folder; the root copy
is cleared at every sequence start. Looking in either place alone finds
nothing at some moment a live caller needs the classified cause, and every
consumer then silently receives the synthesized 'unknown' payload below.

Most specific first: the failing guest's own mirror, which provably
belongs to THIS cycle and THIS guest; then the cycle-folder copy, which
provably belongs to this cycle but to whichever guest failed last; then
the live root, shared across cycles as well as guests.

A caller that names its guest also refuses a shared copy naming a
different one. A host that runs several guests per cycle and does not stop
at the first failure leaves one guest's record in both shared places, so
without this a later guest whose own failure produced no record -- a
warm-resume target that is not in the list, a missing sequence file for
the second or a later sequence -- would be handed its predecessor's cause,
on the dashboard summary and in the per-guest quarantine streak. A record
that names no guest at all is a host-level failure and is still offered to
everyone.

<a id="4213a0b3-00ab"></a>

## test/modules/Test.Notify.psm1: Get-FailureEventData

Cycle folder URL: the cycle log's basename appended to the status
service's mount. Consumers can deep-link from the notification
straight to the HTML transcript + artifacts.

Base URL precedence:
  1. $env:YURUNA_STATUS_PUBLIC_URL -- explicitly published reachable
     address (operator sets this on hosts whose dashboard is
     exposed via a reverse proxy, a tunneled hostname, or a LAN
     IP). An off-host LLM remediator can follow the link.
  2. http://<HOST_FQDN>:8080 -- best guess from the
     cycle's recorded hostname + the default status-service port,
     when the hostname is known. Works on most LANs where the dashboard
     hostname resolves.
  3. http://localhost:8080/ -- last-resort fallback. Only useful
     to a consumer running on the same host as the runner.

<a id="4213a0b3-00ac"></a>

## test/modules/Test.OcrEngine.psm1: Get-EnabledOcrProvider

host.macos.utm -- Apple Vision is the native engine, fastest path
to a match. Invoke-MacVisionOcr's x-axis crop handles the
silent-empty case for the framebuffer captures the runner
actually feeds it. Tesseract sits behind as a fallback
for the few cases Vision still returns nothing (sparse glyphs in
unusual fonts, very low contrast bands). With combine mode 'Or'
tesseract only runs when Vision did NOT match the search
pattern, so the common case is one OCR call per poll. winrt is
omitted entirely -- it is Windows-only and would be filtered out
at runtime anyway; listing it here only adds confusing log
lines about a provider that can't run.

<a id="4213a0b3-00ad"></a>

## test/modules/Test.OcrEngine.psm1: Provider registry

-Global is mandatory: a bare -Force re-import of an already-global
Test.Tesseract yanks it out of the global session into this module's
private scope (legacy module-eviction regression class). Because this
line re-runs every time Test.OcrEngine is re-imported -- and the
Invoke-Sequence -> Test.OcrMatch -> Test.OcrEngine chain re-imports it
on each Initialize-SequenceEngineRegistry -- the eviction would leave
Tesseract's exports (Assert-TesseractInstalled, ...) invisible to the
entry point's global scope even though Test.OcrEngine's own exports
stay resolvable. Keep -Global so Tesseract stays globally visible.

<a id="4213a0b3-00ae"></a>

## test/modules/Test.OcrEngine.psm1: Built-in provider: WinRT (Windows only, via powershell.exe 5.1)

Read deadline for the persistent worker. StandardOutput.ReadLine() has no
timeout, so a worker that spawned fine but then wedges (WinRT/COM stall,
GPU-driver hang -- never emits its end-of-response marker) would block the OCR
call until the full Wait-ForText timeout (minutes), turning a recoverable glitch
into a full-timeout burn with no fast-fail. Bounding the read lets
Invoke-WinRtOcr fall back to a one-shot spawn within seconds. Generous vs the
ms-scale normal OCR: a rare false-timeout only costs one slower one-shot call
plus a fresh worker, never a wrong OCR result. Override with a positive
YURUNA_OCR_WORKER_TIMEOUT_SECONDS.

<a id="4213a0b3-00af"></a>

## test/modules/Test.OcrEngine.psm1: Invoke-WinRtOcr

powershell.exe -File exits 0 even when the script it ran threw, so the
exit code alone cannot separate a blank screen from a helper that never
reached its OCR call. Stderr is what separates them: a screen with no
text produces neither stdout nor stderr, so text-less output carrying a
diagnostic is a failed read and must throw. Returning '' instead is the
silent case -- the caller is told the console is empty, no warning and
no ocr_provider_failed event is raised, and anything waiting for that
console to change waits out its whole budget against a dead reader.

<a id="4213a0b3-00b0"></a>

## test/modules/Test.OcrEngine.psm1: Built-in provider: WinRT (Windows only, via powershell.exe 5.1)

Lazy-compile cache for the Vision OCR Swift source. `swift script.swift`
re-runs the Swift frontend on every invocation -- empirically 1-2s per
call on Apple Silicon, which dominates Wait-ForText latency on macOS
UTM hosts when Vision is the primary engine (the macOS default).
`swiftc -O` compiles once to a native binary; subsequent invocations
are pure exec, ~50-150ms. We key the binary path by SHA-256 of the
source so an in-place edit triggers a fresh compile, and so multiple
parallel cycles don't fight over the same path.

Returns $null when swiftc is unavailable or compilation fails;
Invoke-MacVisionOcr falls back to the original `swift script.swift`
code path so behavior is preserved (just slower) on those hosts.

<a id="4213a0b3-00b1"></a>

## test/modules/Test.OcrMatch.psm1: OCR-tolerant matching

Characters that are stripped entirely during normalization.
OCR engines frequently insert em/en dashes, smart quotes, or other
Unicode substitutions for ASCII punctuation on terminal screens.
Stripping these (along with their ASCII equivalents) prevents
mismatches when the pattern uses plain ASCII.

'@' is NOT in this list -- it lives in the oO0@ confusion group
(above) because OCR mistakes for '0' are more common in this codebase
than '@' being dropped from a prompt. With '@' canonicalized to 'o',
a pattern with literal '@' (e.g. "[ec2-user@host]$") still matches
OCR text that reads '@' as '@' OR as '0' -- both canonicalize the same.

<a id="4213a0b3-00b2"></a>

## test/modules/Test.OcrMatch.psm1: Test-OCRMatch

Matched chars must fall inside the pattern's own length plus the same
error budget the threshold grants: a pattern that forgives N dropped
characters tolerates about N inserted ones, and no more. A budget tied
to the pattern's whole length instead lets a long line of prose satisfy
a short prompt pattern by scattering it -- the notice a guest prints
before "New password:" spells that pattern in order once the confusion
groups fold n->m and e->c, and a wait that accepts the notice types the
secret into a terminal that has not switched off echo yet.

<a id="4213a0b3-00b3"></a>

## test/modules/Test.OcrMatch.psm1: Test-OCRMatch

OCR may reorder parts of a line (e.g. "[ec2-user@test-amazon-linux01 ~]$"
becomes "test-amazon-I inux01 login: ecZ-user").  Split the original pattern
at segment delimiters (@, -, etc.) to get
meaningful segments, normalize each, and check that every segment appears
somewhere in the full normalized text (across all lines).

Unlike the two strategies above this one is bounded by nothing: no line,
no order, no span. Every segment merely has to exist somewhere. A caller
matching a prompt or deciding that something has gone wrong skips it:
a coincidence must not send input early or fail a healthy guest.

<a id="4213a0b3-00b4"></a>

## test/modules/Test.OcrPath.psm1: Windows passes a path of 260 characters or more to a process only when that

Windows passes a path of 260 characters or more to a process only when that
process is manifested long-path aware. The OCR engines are native and are not:
tesseract's reader answers "cannot read input file ... No such file or
directory" and WinRT's StorageFile.GetFileFromPathAsync throws, both for a file
that is plainly on disk. .NET *is* long-path aware, so PowerShell's own
Test-Path, Get-VMScreenshot and Copy-Item over the same path all succeed --
which is what makes this quiet. Every guard the harness can write in PowerShell
passes and only the engine at the end of the chain cannot open the file, so the
capture is written, confirmed present, and then read as a blank screen.

MAX_PATH counts the terminating NUL, so 259 characters is the longest path
those engines accept and 260 is the first they refuse. The trigger is that
boundary rather than a margin below it: the engines are handed the capture and
read it to stdout, never deriving a longer name from it, and a margin would
copy paths that are demonstrably readable -- on every poll, for every frame.

<a id="4213a0b3-00b5"></a>

## test/modules/Test.Orchestrator.psm1: Orchestration-sequence execution for Debug-TestSequence.ps1: runs every

Orchestration-sequence execution for Debug-TestSequence.ps1: runs every
`InvokeTestSequence` inner sequence IN-PROCESS under ONE status.json
cycle, one dashboard row per inner sequence. See
docs/runner-outer-loop.md#what-a-testrunneryml-entry-can-be.

Known duplication: Invoke-OrchestratorGuestRun below mirrors the per-guest
prep + chain-run Debug-TestSequence.ps1 performs inline for a standalone run
(plan -> caching-proxy service -> ssh-user override -> VM ensure/start ->
Invoke-TestSequenceChain). The two are kept separate so a change here cannot
regress the standalone path; folding them onto one helper needs a full-lab
run to re-verify both.

<a id="4213a0b3-00b6"></a>

## test/modules/Test.Orchestrator.psm1: Invoke-OrchestratorHostAction

Pipe to Write-OrchestratorLine, not the success stream: this
function returns the exit code, so un-piped stdout would be swallowed
into that value instead of shown. The information stream (rather than
the console host) is what reaches the cycle artifacts, since the log
proxy tees the Write-* cmdlets and nothing else -- a host action whose
output bypassed it would fail with its reason on the terminal only,
and "FAIL" alone in the transcript and the event log. 2>&1 folds in
the child's stderr, which is where a failing host script explains
itself.

<a id="4213a0b3-00b7"></a>

## test/modules/Test.Orchestrator.psm1: Invoke-OrchestrationSequence

Nested-cycle awareness. An orchestration is normally the cycle OWNER, but
it can itself run nested inside another cycle (an orchestration referenced
as an inner sequence). When $ctx is present this run is NESTED: it attaches
ONE node for the whole orchestration and skips every owner-only status op
(Reset/Initialize/Set-Guest*/Complete-Run/Start-LogFile). Either way, the
step loop publishes a cycle-context handle before each step so a child
PROCESS the step spawns (a host action re-entering Debug-TestSequence.ps1)
attaches as a nested node under the right parent. See Test.Status.psm1
"Nested-cycle support".

<a id="4213a0b3-00b8"></a>

## test/modules/Test.Orchestrator.psm1: Invoke-OrchestrationSequence

The registry leg is charged to the cycle preamble on purpose. The
cache's container registry comes up after squid on a rebuild, and a
guest that starts in that gap spends its entire step budget
discovering the registry is absent and then fails the cycle -- the
same wait, paid in the one place where it is fatal. Waiting here
costs the preamble and fails nothing.

Opt-in with a configurable budget because absence and restarting
are indistinguishable from a probe: a lab that fronts no registry
sets this to 0 rather than paying the budget every cycle for
something that is never coming.

<a id="4213a0b3-00b9"></a>

## test/modules/Test.Orchestrator.psm1: Invoke-OrchestrationSequence

Put a failure record on disk for the failing entry. A GUEST
entry's sequence engine writes its own, far richer record and
this call deliberately never overwrites one; a HOST action has
no such writer at all, so without this a cycle that dies in a
preflight ends with no last_failure.json -- the dashboard and
the remediation dispatcher then see an unclassified failure and
the cycle folder carries nothing naming what stopped it.
Soft by contract: the outcome is already decided, so failing to
RECORD it must not change it. Test.RunnerInnerLoop is imported
lazily because a passing orchestration never needs it.

<a id="4213a0b3-00ba"></a>

## test/modules/Test.Orchestrator.psm1: Invoke-OrchestrationSequence

Adopt the class the nested run already established, rather
than announcing 'unknown' over the top of it. A host action
that drives a guest sequence fails BECAUSE that sequence
did, and the sequence engine has already written a
precisely classified record; hard-coding 'unknown' here
threw that away at exactly the layer the dashboard reads,
so a whole class of failures arrived pre-anonymized and
cross-host incident correlation -- which requires a shared
class -- could never group them.
'unknown' remains the honest answer when there is no inner
record: a host action that failed on its own has nothing
more specific to say, and guessing would be worse.

<a id="4213a0b3-00bb"></a>

## test/modules/Test.Output.psm1: Reusable PASS / FAIL / WARN reporter for check-style scripts

Reusable PASS / FAIL / WARN reporter for check-style scripts. Lets
check scripts (Test-Config, Test-CachingProxyService, future health-checks)
share the same operator-facing format without copy-pasting the
counters and Write-Summary banner.

One of THREE Yuruna logger modules with disjoint responsibilities. See
../../docs/loglevels.md and test/modules/README.md "Three loggers, three
jobs" before adding helpers here -- this module owns ONLY the per-script
PASS/FAIL tally + Write-Summary banner + Exit-WithSummary helper.

Eviction-safe counters: $global:YurunaOutputState anchors the live
state so Test-Config's helpers and any module that imports this one
(e.g. Test.ConfigValidator) share the same PASS/FAIL/WARN tally
regardless of -Force re-imports. See repo-memory
feedback_module_force_import_evicts_global.md.

<a id="4213a0b3-00bc"></a>

## test/modules/Test.PoolAdmin.psm1: One admin command at a time may work in a given admin clone

One admin command at a time may work in a given admin clone. Every admin CLI is its own process
and they all share <runtime>/pool-intent-admin, so without this the clone is opened by several
processes at once: two first uses both find no .git and clone into the same directory (one
wins, the rest fail), and a read's reset --hard can land between a writer's edit and its
commit, so the writer finds nothing to stage and reports success for a change that never
happened. The lock therefore covers the whole command: it is taken when the clone is opened and
kept until the process exits (the operating system frees it even after a crash) or
Unlock-YurunaPoolIntentClone runs. Admins on other hosts work in their own clones and still meet
at the remote, where Publish-YurunaPoolIntent rebases a lost push race.

<a id="4213a0b3-00bd"></a>

## test/modules/Test.PoolAdmin.psm1: Open-YurunaPoolIntent

Refuse to reset --hard unless the remote provably contains our HEAD: a
local commit the remote lacks is committed-but-unpushed pool intent (a
prior Publish reached the commit but not the push), and a silent reset
would erase it with no trace. merge-base --is-ancestor: rc==0 means HEAD
IS contained in FETCH_HEAD (a safe fast-forward -- reset only adds
commits); rc==128 is an unborn HEAD / missing ref where reset IS the
recovery. Any other rc -- 1 (local-ahead / diverged), 124 (timeout), -1
(git unrunnable) -- cannot prove containment, so refuse rather than
green-light a destructive reset.

<a id="4213a0b3-00be"></a>

## test/modules/Test.PoolNotifier.psm1: Invoke-PoolNotifierDelivery

Reclaim orphaned claims: a drain that died (e.g. a watchdog SIGKILL) between the
claim-rename and the terminal move strands a message in sending/ -- otherwise lost
forever (only outgoing/ is scanned below). Move any sending/ entry whose claim is
older than the reclaim grace back to outgoing/ so it is retried. The grace avoids
stealing a genuinely in-flight claim from a second notifier (the shared-queue
belt-and-suspenders). Age is measured from the claimedUtc the claimer stamps into
the message (claim loop below), NOT the file's LastWriteTime: the claim-rename
preserves the message's content-write mtime, so a message enqueued long ago and
claimed a moment ago would look instantly stale and be reclaimed + double-delivered,
and a NAS whose clock differs from this host's could reclaim never or always.
claimedUtc shares the same UtcNow clock as the cutoff. A message with no claimedUtc
(an older drain, or one that died between the rename and the stamp) falls back to the
file mtime in UTC -- coarser, but still bounded.

<a id="4213a0b3-00bf"></a>

## test/modules/Test.PoolPlanner.psm1: Pool planner: Read-YurunaPoolManifest reads runtime/pool.manifest.json (the

Pool planner: Read-YurunaPoolManifest reads runtime/pool.manifest.json (the
pool's framework and project repositories) for the inner runner. The
guests.compatibility.yml helpers below evaluate a project's per-guest
hypervisor rules. The runner does not call them, because every pool member
runs its project's whole plan; Test.PoolPlanner.Tests.ps1 is their only
caller, and Test-PoolIntent.ps1 validates the store's copy of that file
through Test.PoolAdmin instead. See ../../docs/pool-admin.md#what-a-pool-is
for the decentralized, best-effort model. -- Test.PoolPlanner.psm1

<a id="4213a0b3-00c0"></a>

## test/modules/Test.PoolPush.psm1: Invoke-PoolEventPush

A cycle that ran host-action stages keeps its child runs' events in
nested/<node>/cycle.events.ndjson, written there so each sub-run's
transcript and its stream stay together. Those records describe
work done inside THIS cycle and carry its identity, so reading only
the top-level file drops the bulk of such a cycle's telemetry --
and drops it invisibly, because the top-level file is always
present and a short stream looks like a short cycle rather than a
truncated one.

<a id="4213a0b3-00c1"></a>

## test/modules/Test.PoolStorage.psm1: Move-mode policy

Move-mode policy. Code constants by design -- the same call as
CycleHistoryLimit and FailurePauseMaxSeconds: an operator greps and tunes them
in one place, without a config-schema migration and without two hosts on one
share disagreeing about how full "full" is.

Reserve: what must STILL be free after a copy lands. The share is not this
feature's alone -- the guest-image download pool, the proxy's observability
archive and pool-intent.git all live on it -- so archiving is not allowed to
take the share to zero and break them.
Headroom: slack over the measured folder size, for the copy's own overhead.
Projection: the pre-spawn check has to guess what the NEXT cycle will cost.
It takes the MAX of the recent sample rather than the mean, because the cost of
guessing high is one skipped cycle while the cost of guessing low is a cycle
that runs to completion and then cannot be archived.

<a id="4213a0b3-00c2"></a>

## test/modules/Test.PoolStorage.psm1: Invoke-PoolStorageProcessResult runs a native command bounded by a wall-clock cap

Invoke-PoolStorageProcessResult runs a native command bounded by a wall-clock cap
and kills the whole process tree on timeout, so a hung mount/copy can never block
the loop. stdin is redirected + closed immediately, so a child that would
otherwise prompt (e.g. sudo asking for a password) gets EOF and fails fast
instead of stalling. Returns @{ ExitCode; StdOut; StdErr }, where ExitCode is 124
on timeout (conventional) or -1 if the process could not be started. Mirrors the
bounded Process.Start + WaitForExit + Kill($true) idiom used in Test.Ssh.psm1.

The child's stderr has to be REDIRECTED (an un-drained pipe deadlocks a chatty
child), so it is captured either way -- returning it costs nothing and is the
difference between "sudo mount -t cifs rc=32" plus a guess at the cause and the
verbatim kernel/mount.cifs reason ("unknown filesystem type 'cifs'", "Permission
denied", "Host is down"), each of which needs a completely different fix.

<a id="4213a0b3-00c3"></a>

## test/modules/Test.PoolStorage.psm1: Invoke-PoolStorageBoundedScript runs a scriptblock under a wall-clock cap via a

Invoke-PoolStorageBoundedScript runs a scriptblock under a wall-clock cap via a
thread job, so a slow cmdlet (the Windows SMB redirector has no -TimeoutSec and
can stall for tens of seconds on an unreachable NAS) cannot block the loop. On
timeout it abandons the job and returns immediately; the orphaned call releases
itself when the redirector's own internal timeout fires. Returns a hashtable
@{ TimedOut; Result; Error }. Falls back to inline execution when Start-ThreadJob
is unavailable (still bounded by the redirector's internal timeout, just not the
tighter cap).

<a id="4213a0b3-00c4"></a>

## test/modules/Test.PoolStorage.psm1: Who is actually serving a mount

Resolve-YurunaConfigDoc loads test.config.yml for the no-Config path of the
storage config readers: resolve $env:YURUNA_CONFIG_PATH, require it to exist AND
Read-TestConfig to be loaded, then read it inside a try/catch. Returns the parsed
config document, or $null when the feature is effectively off (no resolvable
path, Read-TestConfig unloaded, or the read threw). Read-TestConfig is ALWAYS
called with the RESOLVED $Path -- never by-name with $Path omitted -- because its
Mandatory $Path would stall forever on the interactive parameter prompt under the
headless runner (see feedback_byname_detection_mandatory_param_prompt_hang). The
Read-TestConfig-unloaded fallback keeps a caller that never imported Test.Config
(a storage reader can be dot-sourced standalone) from throwing. CallerName only
tags the verbose diagnostic so each reader's log line stays self-identifying.

<a id="4213a0b3-00c5"></a>

## test/modules/Test.PoolStorage.psm1: Connect-YurunaPoolStorage

Reaching here with an entry STILL in the mount table means the entry exists
but the mount does not answer -- a dead SMB session whose server went away,
whose credential was rotated, or that was left by another account. Tear it
down before mounting: macOS mount_smbfs refuses an occupied mount point with
"File exists" and Linux mount reports it busy, and that failure is then
reported by the callers as a credential problem, which sends the operator to
reset a password that was never wrong. Windows does not need this (Connect
already drops the mapping first) but the call is harmless and keeps the three
platforms on one path.

<a id="4213a0b3-00c6"></a>

## test/modules/Test.PoolStorage.psm1: Connect-YurunaPoolStorage

Create the mount point. Try unprivileged first -- it succeeds when
the parent is user-writable (e.g. a localPath under $HOME). A
root-owned parent like /mnt rejects it, so fall back to
`sudo -n mkdir -p`: the SAME passwordless-sudo precondition the
cifs mount below already needs, so no new privilege surface. `mount`
does not create its target, so a missing mount point otherwise
fails the mount with a misleading error. The unprivileged attempt
is silenced: its denial on a root-owned parent is expected and
handled by the fallback, so an error record there would be noise.

<a id="4213a0b3-00c7"></a>

## test/modules/Test.PoolStorage.psm1: Connect-YurunaPoolStorage

A refusal means mount never ran, so the NAS never saw the
credential -- say so, because the callers that only get a
bool otherwise report this as a rejected password and send
the operator to reset one that was always correct.

Whether the NOPASSWD drop-in answers for mount is resolved
HERE, while the failure is happening: sudo-rs writes no log
entry for a refused `sudo -n`, so nothing on the host records
this moment and the question cannot be answered afterwards.

<a id="4213a0b3-00c8"></a>

## test/modules/Test.PoolStorage.psm1: Who is actually serving a mount

Join-PoolStoragePath combines a localPath base with a relative subpath. A
Windows drive-qualified base ('y:' or 'y:\...') is composed by pure string via
[IO.Path]::Combine, NOT Join-Path: Join-Path resolves the base's drive
qualifier against the PSDrive table, so a drive letter for an SMB mount the
current runspace has not yet enumerated -- referenced before the mount, or
after the mapping silently dropped mid-cycle -- throws a NON-TERMINATING
DriveNotFoundException ("A drive with the name 'y' does not exist"); the call
then returns $null and the empty path surfaces downstream as a misleading
"null Path argument" folder-creation failure. A bare drive letter is also
drive-RELATIVE, so anchor it to the root ('y:' -> 'y:\') first or the join
targets the per-process CWD on that drive. Any other base (a '/'-rooted
macOS/Linux mount point) carries no drive qualifier, so Join-Path is safe there
and keeps its separator normalization. SubPath is taken verbatim; callers
normalize any embedded separators before passing it in.

<a id="4213a0b3-00c9"></a>

## test/modules/Test.PoolStorage.psm1: Merge-PoolStorageLedger

Carry forward the prior scalar fields before overlaying $Status: a failure
run supplies a $Status that omits lastCopied (only a successful copy sets
it), so rebuilding purely from $Status would erase the prior run's
lastCopied/lastConnectOk. Seeding from $Ledger first preserves an omitted
key while a key present in $Status still overwrites it. 'replicated' is
skipped -- it is already rebuilt (and pruned to LocalNames) above. This
carries EVERY other ledger key forward (today all status scalars); a ledger
key that must NOT persist across runs would need an explicit exclusion here.

<a id="4213a0b3-00ca"></a>

## test/modules/Test.PoolStorage.psm1: Replicator: async, fail-fast, atomic, backlog-draining

Copy-PoolStorageCycle copies one cycle folder to
<localPath>/hosts/<HostId>/test-cycles/<CycleName>/ and commits it with a
.yuruna-complete sentinel written LAST. Any pre-existing copy WITHOUT a sentinel
(a crashed prior attempt) is deleted first and recopied, so a partial is never
trusted. Returns $true only when every step succeeds. Private; assumes the share
is already mounted.

-Verify (move mode) compares the copy against its source BEFORE the sentinel is
written. The order matters twice over: the sentinel lives INSIDE the destination,
so a comparison made after writing it is always off by one file and one stamp's
worth of bytes; and the sentinel is what every reader treats as "committed", so
writing it over an unverified tree would publish a half-copy. A failed
verification removes the destination -- it is sentinel-less, so it is nobody's
archive -- and leaves the source untouched for the next run.

<a id="4213a0b3-00cb"></a>

## test/modules/Test.PoolStorage.psm1: Get-PoolStorageDrainOrder

Accumulate into a typed List, NOT `$x = if (...) { @(...) }` slices: a single-
element `@(...)` emitted from an if-statement unwraps to a scalar (and an
empty branch to $null), so `$newest + $oldest` would string-CONCATENATE when
newestCount==1 and silently fuse/drop cycle names. The List is unwrap-proof.
Newest FIRST: the drain commits in list order and breaks on the first copy
failure (treated as a lost connection), so copying today's cycles before the
oldest backfill guarantees recent data lands even if an old cycle later stalls
the run. The oldest remainder follows and backfills across subsequent drains.

<a id="4213a0b3-00cc"></a>

## test/modules/Test.PoolSync.psm1: Invoke-PoolSyncGitCapture (and its exit-code wrapper Invoke-PoolSyncGit)

Invoke-PoolSyncGitCapture (and its exit-code wrapper Invoke-PoolSyncGit)
runs a git command bounded by a wall-clock cap and kills the
whole process tree on timeout, so a hung/unreachable remote can never block the
loop. stdin is closed immediately and the credential-prompt env is neutralized
(GIT_TERMINAL_PROMPT=0 + empty GIT_ASKPASS + GCM_INTERACTIVE=never), so a remote
that would otherwise prompt for a password fails fast instead of stalling.
Returns the exit code, 124 on timeout, or -1 if git could not be started.
Mirrors Invoke-PoolStorageProcess; kept local so Test.PoolSync has no dependency
on Test.PoolStorage.

<a id="4213a0b3-00cd"></a>

## test/modules/Test.PoolWorker.psm1: Get-LocalLabStorageSharePath: whether this machine still PUBLISHES a share can

Get-LocalLabStorageSharePath: whether this machine still PUBLISHES a share can
only be answered by the OS share table -- the configuration of a machine backed
by a NAS and one serving its own shares is identical in every key.

-Global is load-bearing here, unlike the two imports above. Test.LocalLabStorage
is a module ENTRY POINTS import for their own use, and a bare `-Force` import
from inside this one unloads the instance their exports resolve through: the
caller keeps running with the commands it loaded a moment ago no longer
defined, and fails on the first call with "not recognized as a name of a
cmdlet". Re-importing globally keeps one instance that both scopes see.

<a id="4213a0b3-00ce"></a>

## test/modules/Test.PortOwner.psm1: Get-PortListenerPid

Windows: HTTP.sys hides the real owner from Get-NetTCPConnection
(OwningProcess reports 4, the System kernel account), so netsh is
the only reliable source for url-group -> PID mapping. Output is
grouped per "Request queue name:" block; within a block,
`Processes: ID: <pid>` lists user-mode PIDs and `Registered URLs:`
lists URL prefixes. Flush a block's PIDs to the result set when
its URL list contains :$Port. The regex matches both
"HTTP://*:8080/" and the rarer "HTTP://127.0.0.1:8080:127.0.0.1/"
host-binding form.

<a id="4213a0b3-00cf"></a>

## test/modules/Test.PortOwner.psm1: Get-PortHolderServiceInfo

Require the field COMBINATION a Yuruna status.json always emits, not
any single common key: schemaVersion + overallStatus together are a
Yuruna signature present in EVERY served doc (both live per-cycle docs
and the bootstrap status.json.template the server answers with before
the first cycle), whereas 'host' / 'hostname' / 'schemaVersion' alone
appear in plenty of unrelated JSON and would misclassify a foreign
service on this port as ours. hostId is deliberately NOT required: the
bootstrap template omits it, so requiring it would drop the owner name
from the conflict banner for a peer that has just launched.

<a id="4213a0b3-00d0"></a>

## test/modules/Test.PortOwner.psm1: Internal: a live sudo authorization for the takeover, or $false.

Internal: a live sudo authorization for the takeover, or $false.

sudo reads its password from /dev/tty, NOT from stdin -- so a prompt raised
from a run whose output is captured (every service bring-up called through
Start-YurunaStatusServiceIfEnabled, every runner cycle) prints into a log
nobody is watching and then waits for a keystroke nobody knows to press. The
probe is therefore always `-n`, and the one place that may actually ask is
gated on Test-YurunaCanPrompt: a person who can both SEE the question and
ANSWER it. Everywhere else this returns $false and the caller reports instead.

<a id="4213a0b3-00d1"></a>

## test/modules/Test.Prelude.psm1: Canonical exit codes

Canonical exit codes. Stop-WithReason / Write-Summary surface the "why"
in stdout; the numeric code stays coarse so a consumer does not need a
per-script lookup.

2 is not a softer 1. It says the gate could not reach a verdict at all --
a missing tool, a missing input, an absent browser -- and it exists so
that state stops reading as success. A gate that cannot run has proved
nothing, so a caller that requires full evidence must treat 2 as fatal;
a caller that is deliberately advisory may let it through, but only by
naming that choice.

<a id="4213a0b3-00d2"></a>

## test/modules/Test.Prelude.psm1: Initialize-YurunaEntryPointModuleSet

Boot-time recovery sweep + atomic state-file helper + runner
state machine. Order matters: Test.EventSchema before
Test.Log so Send-CycleEventSafely validates emits at module
load; Test.StateFile before Test.Recovery so Resolve-Orphan-
IncompleteCycle resolves the helper at load time; Test.Log
before Test.RunnerState so state-transition emits land
cleanly; Test.RunnerState last so Initialize-RunnerState's
synthetic transitions reach a fully-loaded emit path.

<a id="4213a0b3-00d3"></a>

## test/modules/Test.Prelude.psm1: Initialize-YurunaEntryPointModuleSet

The Inner core set loads early-bootstrap modules and per-cycle
workhorses through one Initialize-YurunaEntryPointModuleSet -For Inner
call at bootstrap. The inner entry point also imports OCR/Tesseract and SSH
after the cycle gate. Test.Prelude.psm1 declares the canonical set, and
the outer dispatches a fresh inner process each cycle so source changes
load on the next cycle. Import order preserves dependency edges
(Test.HostContract depends on Test.VMUtility, etc.).

<a id="4213a0b3-00d4"></a>

## test/modules/Test.Prelude.psm1: Initialize-YurunaEntryPointModuleSet

Test.Recovery is loaded so Invoke-TestProject can archive any stale
break-active.json left over from a prior Debug-TestSequence /
Start-TestRunner that crashed mid-break. Without this sweep,
the inner runner inherits the parked breakpoint state and the
status UI shows a "Continue" button for the previous cycle.
Test.Recovery's Send-CycleEventSafely / Write-YurunaStateFileJson
callers are Get-Command-guarded, so we do not need to pre-load
Test.EventSchema / Test.StateFile here; the archive path
remains best-effort either way.

<a id="4213a0b3-00d5"></a>

## test/modules/Test.Prelude.psm1: Initialize-YurunaEntryPointModuleSet

Modules the parent (non-detached-server) status-service
code needs: Test.YurunaDir for Initialize-YurunaRuntimeDir /
Initialize-YurunaLogDir, Test.VMUtility for IP / port helpers,
Test.CachingProxyService for state-file + probe helpers, Test.HostContract
for Get-HostType + Initialize-YurunaHost. Test.PortOwner is
consumed later in the file (Resolve-PortOrphan) so it is
included here too -- one bootstrap pass loads every module
the parent needs. The detached status-service child process
imports its own modules from a here-string and is not
affected by this set.

<a id="4213a0b3-00d6"></a>

## test/modules/Test.Prelude.psm1: Initialize-YurunaEntryPointModuleSet

Union of the inline imports in the five caching-proxy entry
scripts under test/ -- Start-CachingProxyServiceVM.ps1,
Stop-CachingProxyServiceVM.ps1, Move-CachingProxyService.ps1,
Test-CachingProxyService.ps1 and
Repair-CachingProxyServiceForwarder.ps1. This set must stay a
superset of all five: Test.HostContract (for Initialize-YurunaHost, Get-HostType,
Invoke-LibvirtGroupReExecIfNeeded, Add-PortMap / Remove-PortMap,
Test-CacheVMOnExternalNetwork, Remove-HostProxy / Set-HostProxy,
Initialize-SudoCache), Test.CachingProxyService (Get-CachingProxyServiceState-
Path, Save-/Read-CachingProxyServiceState, Test-CachingProxyServiceAvailable,
Invoke-CachingProxyServiceProbe, Get-CachingProxyServiceVmIp), Test.VMUtility
(Test-IpAddress, Get-CachingProxyServicePort, Format-IpUrlHost) for
the env-var / -CacheIp branches that bypass Test-CachingProxyService-
Available's transitive imports. Per-host Yuruna.Host.psm1 lives
under host/<short>/modules/ and is loaded by Initialize-Yuruna-
Host via the contract layer -- not part of this set.

<a id="4213a0b3-00d7"></a>

## test/modules/Test.Recovery.psm1: Cycle-folder name patterns

Cycle-folder name patterns. Two shapes:

  Bare:           NNNNNN.YYYY-MM-DD.HH-mm-ss.HOSTID
                  (clean close)
  With suffix:    NNNNNN.YYYY-MM-DD.HH-mm-ss.HOSTID.incomplete
                  (in progress, OR crashed before Stop-LogFile's rename)

Anything else under status/log/ is left alone (operator-created
folders, history.YYYY-MM-DD buckets, prior .aborted.<UTC> archives,
etc.).

<a id="4213a0b3-00d8"></a>

## test/modules/Test.Recovery.psm1: Clear-StalePidFile

The PID is live, but the OS may have recycled a dead prior
occupant's PID onto an unrelated process. Trust the pidfile as
live only when the live process's StartTime matches the recorded
companion StartTime (runner.start, written by Write-RunnerPidFile
as ToString('o')). 2s tolerance matches Get-RunnerInstanceState:
DateTimeOffset.Parse + StartTime can lose precision across the
round-trip on some kernels, but the window is far narrower than
any real recycle. When identity cannot be established (no
companion StartTime, or the live StartTime is unreadable), stay
conservative and treat it as live.

<a id="4213a0b3-00d9"></a>

## test/modules/Test.Registry.psm1: New-YurunaRegistry

When a global anchor already exists (a -Force re-import, or a second caller
sharing an AnchorVar) the store built here is discarded and the live one reused.
If the caller explicitly asked for a comparer that disagrees with the live store,
honoring only the live store would silently keep the looser case-sensitivity a
caller was trying to tighten -- a policy downgrade. Migrate instead: build a fresh
store under the requested comparer and copy the existing entries into it under the
new key-equality rules, then rebind the anchor. Migrating (not throwing) keeps
every current caller working; they all request the store's own comparer, so this
branch never fires for them.

<a id="4213a0b3-00da"></a>

## test/modules/Test.Remediation.psm1: WHICH failures the runner may retry without an operator, and HOW MANY times.

WHICH failures the runner may retry without an operator, and HOW MANY times.
The list lives here, beside the registry that classifies failures, because
keeping it beside the registry prevents the set that CLASSIFIES a failure
from drifting away from the set that may ACT on one. In particular, all
classes whose handlers recommend a harmless retry must be represented here.

A class earns a place here only when retrying is the whole repair and a
repeat is harmless. Everything else -- a bad plan, a missing payload, an
expired vault, a full disk -- stays advisory, because retrying it either
cannot help or destroys the evidence an operator needs.

credential_expired is deliberately absent: an expired vault stays advisory.
No production path calls the available re-authentication primitive, and the
class's registered handler asks for an operator rather than a retry.
Membership does not dispatch a repair in any case; its only
effect is to end the post-failure pause early, which is the wrong answer for
a credential nobody has fixed yet.

<a id="4213a0b3-00db"></a>

## test/modules/Test.Remediation.psm1: Invoke-Remediation

Inner-cause routing. An exhausted `retry` reports the outer class
'retry_exhausted', which masks the deepest verb's actionable cause the
record preserved in innerFailureClass. Route on the inner class when it is
present AND has its own registered handler, so the recommendation targets
the real failure instead of the generic retry wrapper. Severity /
suggestedRecoveries follow the routed class; the outer class is preserved as
$routedFromClass (surfaced as RoutedFromFailureClass / outerFailureClass) so
the audit trail still shows the masking.

<a id="4213a0b3-00dc"></a>

## test/modules/Test.Remediation.psm1: Register-BuiltinRecoveryHandler

Deliberately NOT restart_from_snapshot, which is what ocr_timeout above
recommends. The two look alike in the record -- a wait that ended without
its pattern -- but the assumption behind replaying from a snapshot is that
the screen diverged from the recorded path and a clean run will follow it
again. Here the screen never became readable: something filled the console
faster than the pattern could be matched off it, and a replay reproduces
that at the same rate. The console content is the evidence and a person has
to read it, so this class stops rather than spending another full timeout.

<a id="4213a0b3-00dd"></a>

## test/modules/Test.Remediation.psm1: Register-BuiltinRecoveryHandler

Two screens reach this class. One is still moving: a line repeating
faster than the pattern can be read off it, where the answer is to fix
what is repeating. The other stopped moving a long time ago and only
LOOKS like a flood, because the repeat count is measured within a single
frame -- a wall of already-scrolled text on a guest that is waiting for
something. Naming a churning network on the second sends the reader
after a fault that is not there, so the static reading decides which
cause is described.

<a id="4213a0b3-00de"></a>

## test/modules/Test.RootArtifact.psm1: Get-YurunaRootHomeArtifact

Unprivileged first: on a host where root's home is traversable this answers
without involving sudo at all.

-ErrorAction SilentlyContinue because a DENIED probe is an expected answer
here, not a fault. macOS keeps /var/root at 0700, so an unprivileged
Test-Path returns $false AND writes a red "Access to the path is denied"
error to the caller's console -- during setup, in the middle of the step
list, on a check that goes on to succeed by asking sudo instead. The
sudo-backed probe below is the one that decides; this branch is only the
shortcut for hosts where the answer is free.

<a id="4213a0b3-00df"></a>

## test/modules/Test.RunnerElevation.psm1: Per-host-type command manifest for the PER-CYCLE path

Per-host-type command manifest for the PER-CYCLE path. A host driver may take
ownership by exporting Get-HostElevationCommand (resolved first, below); until
one does, this table is the single place the list lives, so a new sudo call
site in the cycle path has exactly one place to register itself.

ubuntu.kvm: the caching-proxy port map (Add-PortMap / Remove-PortMap) writes
and removes /etc/systemd/system/yuruna-cacheproxy-p<port>.{socket,service} and
reloads systemd. That is the whole per-cycle elevation surface on KVM.

<a id="4213a0b3-00e0"></a>

## test/modules/Test.RunnerHeartbeat.psm1: Clear-RunnerPhase

The delete goes FIRST, and it is verified and retried. Two reasons, and
this is the one place in the module where a best-effort file operation
would otherwise fail toward the TIGHT bound:

 * Ordering. A .NET exception is TERMINATING in PowerShell, so if the
   stepHeartbeat write below sat ahead of this and threw (disk full, an
   AV/backup handle -- the failure class the heartbeat timer's own catch
   block already exists for), control would jump past the delete and the
   marker would survive into the cycle.
 * Contention. The watchdog polls the marker with Get-Content, whose
   handle is taken without FILE_SHARE_DELETE, so a Remove-Item landing in
   that window fails -- and -ErrorAction SilentlyContinue makes it a
   non-terminating error the try/catch never sees. That handle lives
   microseconds against a multi-second poll, so one retry effectively
   always wins.

Either miss would leave the 600 s preamble bound in force over the whole
cycle and false-kill the weekly base-image download at ~10 minutes.

<a id="4213a0b3-00e1"></a>

## test/modules/Test.RunnerInnerLoop.psm1: /yuruna-archive.tar.gz and /yuruna-project-archive.tar.gz are built via

/yuruna-archive.tar.gz and /yuruna-project-archive.tar.gz are built via
`git archive HEAD`, so guests only ever see COMMITTED content. If the host
process is running working-tree code that references new file paths not yet
committed (rename in progress, new automation script staged but not pushed),
the host SSH/console calls invoke the new names while the guest still has
the old HEAD content -- the symptom is a baffling "script not found" with
the correct-looking command line. Write-Warning bypasses logLevel filtering
so this surfaces regardless of test.config.yml's logLevel setting.

<a id="4213a0b3-00e2"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Cycle-start guard: warn on working-tree drift vs HEAD

Background: a real-world failure mode is the host's Wi-Fi roaming to a
different SSID/subnet mid-cycle. The caching-proxy-service VM is on the host's
Default Switch (Hyper-V) / VZ shared-NAT (UTM) and remains routable from
the host, BUT the URL injected into guest cidata at New-VM time may have
pointed at the IP the host had on the prior network -- which guests can
no longer reach. Symptom: fetch-and-execute.sh times out on /livecheck
and silently falls back to GitHub, masking the broken proxy path.

This helper TCP-probes the proxy URL detected at runner startup before
each step, so the operator sees the moment connectivity is lost. State
is tracked to keep the log readable: a one-shot loud "LOST" warning on
the down transition, terse "still unreachable" notes during a sustained
outage, and a "recovered" note when it comes back. No-op when no proxy
was detected at startup (nothing to lose) or when the URL doesn't parse
as http://ip:port. The down/up state is module-scoped: every probe goes
through this one function so the transition log stays coherent.

<a id="4213a0b3-00e3"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Per-cycle config reload

Per-step config-reload hook for the inner loop: re-read test.config.yml into
$State (Sync-RunnerCycleConfig) and refresh the per-step log level
(Resolve-RunnerLogLevel) in one call, so a step boundary is a single call plus
the knob mirror rather than the reload/log-level pair repeated after every step.
It also captures Sync-RunnerCycleConfig's result to track a sustained reload
outage: the primitive warns per failed reload, but a run of consecutive failures
means the runner is coasting on the last good config, so that is surfaced once,
loudly, instead of degrading silently.

<a id="4213a0b3-00e4"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Copy-FailureArtifactsToStatusLog

Optional GuestKey: when supplied, the URL of the per-guest
data folder produced is recorded on the live status doc via
Set-GuestFailureArtifact so Complete-Run can promote it into
history.guestSummary, and the dashboard hyperlinks the per-guest
pill straight to the artifacts. The folder is created at the
top of each guest iteration (so success cycles also have a
place to land saveSystemDiagnostic output) -- this function just
populates it with failure-specific files.

<a id="4213a0b3-00e5"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Copy-FailureArtifactsToStatusLog

Three artifact sources, written by different code paths:
  * screens_<VM>/raw_*.png         -- Wait-ForText ring buffer (GUI mode)
  * failure_screenshot_<VM>.png    -- single frozen-moment shot from
                                     non-waitForText failures (any
                                     sequence step that isn't
                                     waitForText/waitForAndEnter,
                                     including sshExec)
  * failure_ocr_<VM>.txt           -- last OCR text from waitForText

All files land flat inside cycleGuestDataFolder (the per-guest
folder under cycleFolder). At most one failure per guest per
cycle in practice, so the raw_<stamp>.png filenames already
encode their own ordering and don't need an additional prefix.
Same cycle-folder-nested location Wait-ForText writes into via
Get-CycleScreenDir. Falls back to $env:YURUNA_LOG_DIR for the
no-cycle-folder edge case (defensive; shouldn't happen here
because Start-LogFile ran upstream).

<a id="4213a0b3-00e6"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Copy-FailureArtifactsToStatusLog

Last fetch-and-execute log capture. The guest's fetch-and-execute.sh
tees every inner-script run to /tmp/yuruna-last-fetch-and-execute.log
(truncated at each invocation), so this file holds the full stdout/
stderr of whatever wrapper was running when the sequence failed --
invaluable for the class of failure where the wrapper's `set -e`
bailed silently while the OCR/screen capture was still focused on a
downstream poll loop. Soft-failing like the other rungs: an SSH-down
guest or a never-written log just logs a Verbose line.
Save-GuestDiagnostic already proved SSH works via Wait-SshReady, so
we can call Invoke-GuestSsh without redoing the readiness handshake.

<a id="4213a0b3-00e7"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Copy-FailureArtifactsToStatusLog

Host system-diagnostics capture. Separate from the guest snapshot
above (Save-GuestDiagnostic SSHs into the guest); this one runs
automation/Get-SystemDiagnostic.ps1 against the test-runner host
itself so the operator can correlate host-side state (docker,
kubectl, disk pressure, listening sockets, recent kernel events)
with the failure. Forked into a child pwsh so the script's
Start-Transcript and global $script:Problems list don't leak
into the runner. Soft-failing in line with the guest path.

<a id="4213a0b3-00e8"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Copy-FailureArtifactsToStatusLog

Hypervisor-app crash reports (macOS). When UTM (or its per-VM QEMU
launcher) dies mid-cycle, everything above records only symptoms --
console I/O stops answering, screenshots stop landing, IP discovery
goes quiet -- while the actual "why" is the .ips report macOS writes
under ~/Library/Logs/DiagnosticReports. Copy the reports written
since this cycle began (folder creation time is the cycle start) so
the crash cause travels with the failure evidence instead of aging
out on the host. Soft-failing like its neighbors.

<a id="4213a0b3-00e9"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Copy-FailureArtifactsToStatusLog

DHCP wire capture (drivers that arm one at Start-VM). The guest-side
network diagnostic can only say "no lease"; whether the DISCOVER
never left the guest, died crossing the vSwitch or uplink, or went
out unanswered is only visible on the host's packet path, and each
of those shapes indicts a different machine. Guarded by Get-Command
because only some host drivers implement it, and soft-failing like
its neighbors: a diagnostic must never turn a failed step into a
failed collection.

<a id="4213a0b3-00ea"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Update-CycleModuleImport

Re-call Initialize-YurunaHost so the host driver (Yuruna.Host.psm1)
is re-imported with -Global -Force on every cycle. The cross-host helpers
(Test.VMUtility.psm1 -- Wait-VMRunning, Test-IpAddress, ...) are imported
with -Global only when that module is not already loaded.
Without this, anything that wipes the runner's session mid-cycle
(a sequence step calling Get-Module | Remove-Module, a transitive
Import-Module without -Global, etc.) leaves the runner unable to
find Wait-VMRunning at the next New-VM.Resource step -- a
long-running in-process runner will eventually crash with
"Wait-VMRunning is not recognized" without this defense.

<a id="4213a0b3-00eb"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Complete-CycleRun

A guest that was rebuilt under its own identity and came back on a
different address has broken the one property that makes a long lease
survivable, and it has already spent the address by the time anyone could
look. Folded in HERE, at the single point that decides pass/fail, because
a cycle whose guests each took a fresh lease is not a cycle that passed --
it is one that worked while draining the pool it needs next time.

A cycle already failing keeps the failure it has: the earlier one is the
richer record and the one that names a step, and Write-CycleInfraFailure
will not clobber it in any case. This only ever turns a pass into a fail.

<a id="4213a0b3-00ec"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Get-CycleGuestAndSequenceList

Write-Information, not Write-Output: this function's return value is
assigned by its caller, and PowerShell hands the assignment EVERY
success-stream object. A Write-Output progress line here makes the
result an Object[] of [String, Hashtable] instead of the hashtable --
member access still reads through it, so nothing looks broken, but an
empty GuestList then enumerates to $null rather than @() and the line
itself never reaches the transcript. Neither does this one: plan
resolution runs before the cycle transcript is opened, so the count is
a console breadcrumb only, and the guest set a log reader needs is
written beside the config echo further into the cycle.

<a id="4213a0b3-00ed"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Start-CycleHostDiagnostic

The child also drops a machine-readable sibling next to the prose
dump (<OutFile>.json, schema yuruna.diagnostic.problems/v1) whose
per-class tallies are the only structured statement of what the
host diagnostic actually found. Without reading it back the whole
verdict lives in an artifact nobody opens until a post-mortem, so
a host-scoped problem present at cycle start (a virtual switch
whose uplink no longer forwards, disk pressure, a stopped
service) stays invisible while the cycle burns its full budget.
Console only, no alert: a per-cycle notification would fire on a
standing condition every ~18 minutes. Its own catch inside the
capture's catch, so a malformed sidecar reads as what it is
instead of borrowing the "capture failed" wording from a capture
that plainly succeeded -- and never fails a cycle either way.

<a id="4213a0b3-00ee"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Wait-CyclePauseFlag

Refresh runner.stepHeartbeat each iteration: the outer watchdog
reads only this file's mtime and kills the inner after
testCycle.stepTimeoutSeconds (2700-second fallback; the shipped template
sets 3600) of staleness. A deliberate pause has no step boundaries to refresh it via
Invoke-Sequence's normal path, so without this the watchdog
would TerminateProcess the inner mid-pause, drop the outer into
its failure backoff, and leave /control/cycle-resume and
/control/start-cycle from index.html with nothing to talk to.

<a id="4213a0b3-00ef"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Ordering invariant for last_failure.json: Write-CycleInfraFailure never
overwrites an existing record, and that rule exists to protect the
RICHER engine-written record produced later in the SAME cycle. But
$env:YURUNA_LOG_DIR is the log ROOT shared by every cycle, so a record
sitting there at this point -- the first gate, before any cycle work --
was left by an EARLIER cycle and is exactly what the outer loop's
auto-remediation and warm resume would keep routing on. Clearing it is
correct ONLY here, where nothing in this cycle can have written yet;
moving this any later inverts the rule and destroys live evidence.

<a id="4213a0b3-00f0"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Converge this host's metrics exporter -- a MUTATION, not a check, and
placed here rather than inside the gate above for two reasons.

The gate decides whether a cycle may run and reports that as a bool; a
host change folded into it would be invisible to every reader of that
call, and Assert-*/Set-* are kept apart everywhere else here.

And this position is what makes an unattended privileged repair safe at
all. The unattended loop makes no repair that has to ask for its
privilege -- a loop waiting on a credential nobody is present to type is a
hang, which is why the host clock is only ever measured here and repaired
where a console can answer. This one never asks: on the single host type
that registers a provider, the gate above begins with Assert-Elevation and
refuses the cycle when it fails, so reaching this line is proof that
Administrator is already held. No provider is registered for the hosts
where the same work would need a sudo credential.

Runs before any guest starts, so an install that restarts a service or
touches the firewall can never land mid-provisioning. Costs one service
lookup on a host that already has the exporter; a host that does not gets
one bounded install attempt, and a failed attempt buys a quiet interval so
a host that cannot install does not spend part of every cycle
rediscovering it.

Two belts, because this is telemetry and telemetry may not end a cycle.
The try means not even a module that failed to import -- which would make
the command itself unresolvable -- can raise here. Discarding the value
means this step can never contribute to what the enclosing function
returns; everything a person is meant to read is on the warning and
information streams instead.

<a id="4213a0b3-00f1"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Bootstrap-stage failure -- no cycle folder yet, so the helper
builds a minimal payload from these scalars. The infra record above
already wrote the canonical class (network_timeout when a DNS/TCP
probe failed, else bootstrap_sync) + severity 'hard'; pass the same
so extensions route on failureClass instead of free-text grep.
Network sub-case (a DNS/TCP probe failed) is the transient, retryable
kind -> network_timeout; otherwise a divergence / auth / dirty-tree
git failure -> bootstrap_sync (operator). Write the schema-v2 record
before the notification so its EventData picks up the real class.

<a id="4213a0b3-00f2"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

When this host is in a pool that carries repositories
(runtime/pool.manifest.json, written by the outer loop's
Sync-YurunaPoolIntent), the pool's framework/project repo PAIR overrides this
host's repositories.frameworkUrl / repositories.projectUrl for THIS cycle, so
the project refresh + framework clone below use the pool's repos. GH_TOKEN is
deliberately NOT overridden -- it stays host-local (never travels in pool
intent). Unpooled hosts (no manifest / no repositories) are untouched.
Cleared every cycle: a stale value would make an unpooled cycle probe (and
possibly fail on) an assignment that no longer applies.

<a id="4213a0b3-00f3"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

A pool can hand this host a projectUrl its credential cannot read. Without
this probe that surfaces only when the clone below fails, mid-cycle, as a
generic bootstrap error -- and the person who MADE the assignment is not
the person watching this host. Probe first, classify precisely, and
publish the result so the pool-control board can name the blocked hosts.

Runs only for a POOL-ASSIGNED url: a host's own projectUrl is already
preflighted inside Update-ProjectClone, and duplicating that here would
double every unpooled host's cycle-start network cost for nothing.

<a id="4213a0b3-00f4"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

The -Force re-import above replaces Test.Status's module instance, which
discards the in-memory status document built at cycle start (status.json on
disk is untouched). Rebuild it from that file so the rest of the cycle has a
live document to mutate. A per-guest cycle would recreate it a few regions
down at Initialize-StatusDocument, but a cycle whose top-level is an
orchestration sequence skips that block entirely and would otherwise run
every status write against no document until the orchestrator installs its
own -- dropping infra-failure records and failing outright on the Get-Image
timestamp. Cheap and idempotent: the same preserve-and-rewrite pass as the
cycle-start call, reading back what it just wrote.

<a id="4213a0b3-00f5"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Build per-cycle execution plan from project/test/test.runner.yml.
Each plan entry is a (top-level workload, guest, sequence chain) tuple;
multiple top-levels can share a guest, so we dedupe to GuestList for
the parts of the cycle that operate per unique VM (folder check,
Get-Image, the cleanup -> create -> start -> verify per-guest loop).
Falls back to the legacy guestSequence list when the cycle config is
missing -- useful before the project repo clone bootstrap lands and
for operators who haven't migrated yet.

<a id="4213a0b3-00f6"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

PlannerFatal (currently: duplicate project sequence files with the
same name under different test/ folders) means the plan is
ambiguous -- silently falling back to guestSequence would let the
cycle run against an arbitrary winner. Print the error prominently
and short-circuit GuestList to empty so the foreach loop below
runs zero iterations. Cycle still flows through "Finalize cycle"
naturally so $OverallPassed=false bumps ConsecutiveFailures and
fires notifications on the same threshold as any other failure.

<a id="4213a0b3-00f7"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

A test.runner.yml entry can be an orchestration sequence (no resource:/
baseline; steps are InvokeTestSequence). It contributes no per-guest plan
entries, so it owns the whole cycle via Invoke-OrchestrationSequence
(Test.Orchestrator) -- Reset/Initialize/Start-Log, one dashboard row per
inner sequence, Complete/seal -- exactly as a standalone `Debug-TestSequence
<orch>` run does. The runner delegates to it below instead of the per-guest
VM lifecycle, and forces GuestList empty so the empty-plan fallback to the
legacy guestSequence does NOT bring up a phantom guest.

<a id="4213a0b3-00f8"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Assign the helper's result DIRECTLY -- do NOT wrap the call in @(). The unary
comma inside New-CycleGitCommitList already emits the whole list as one
pipeline item (so even a one-element list stays an array). Wrapping that single
array item in @() nests it one level deeper, yielding gitCommits = [[{...}]]
instead of [{...}] -- the array-double-wrap trap class. That malformed shape is
rejected by the status schema's gitCommits reader and by the pool-aggregator service,
which then cannot parse the host's status.json at all.
An orchestration cycle skips this whole block: Invoke-OrchestrationSequence
(delegated at "Finalize cycle" below) does its own Reset/Initialize-Status
Document + Start-LogFile so it owns the status doc + transcript. Running the
runner's Initialize here too would create an empty guest cycle that the
orchestrator then clobbers. $CycleStartUtc/$LogFile stay empty; the guest loop
(empty GuestList) and the failure-notification tail tolerate that.

<a id="4213a0b3-00f9"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

CycleNumber is read AFTER Initialize-StatusDocument so it sees the
incremented value (1, 2, 3, ...). Drives the 6-digit prefix in the
cycleFolder name; Start-LogFile also publishes the folder URL onto
the status doc via Set-CycleFolderUrl so the dashboard can build
per-guest tile links from it.
CycleNumber (also returned by the helper) is not read downstream in the
cycle body -- it is consumed inside Start-CycleLogFile to name the cycle
folder -- so only LogFile is captured here.

<a id="4213a0b3-00fa"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Re-assert the host driver into the GLOBAL session before the guest loop.
The &-invoked child scripts run just above (status-service restart, the
Remove-TestVMFiles VM sweep) execute nested in this module's session
state, where a -Force import without -Global pulls the host driver out of
the global table (the legacy-eviction regression class). Host-contract
calls made from THIS module's scope (New-VM/Start-VM) still resolve from
the module copy, but a call made from a FOREIGN module mid-sequence
(Invoke-Sequence's Restart-VMConsole repaint at sequence start) needs the
GLOBAL copy. Re-importing here is idempotent and cheap, and restores the
global contract for the sequence engine.

<a id="4213a0b3-00fb"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

EventData: in-cycle alert -- the cycle folder is
established, so Get-FailureEventData reads schema-v2
last_failure.json (failureClass/severity/suggested
Recoveries from the verb registry) and augments with
cycle/host context. Built here so it can be remediated
below before Send-CycleFailureNotification ships it --
the body's JSON trailer and the -EventData payload carry
the same hashtable; extensions that declare -EventData
route on it, legacy ones still see it in the body.

<a id="4213a0b3-00fc"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Close the self-heal observability loop: route the failure
through the remediation dispatcher so it computes a recovery
recommendation, emits the remediation_recommended NDJSON event
(internally, via Send-CycleEventSafely), persists the durable
last_remediation.json beside the failure (archived into the
cycle folder and replicated to the pool), and logs the next
step. Advisory only -- the dispatcher records the decision but
never acts. Pass the in-memory payload so a cycle-boundary wipe
of last_failure.json can't route this on a stale file. Auto-
applying a recommendation is a separate, default-off feature
that needs a per-cycle attempt cap and a class allow-list
(and enough human review) before it can act.

<a id="4213a0b3-00fd"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Invoke-Sequence's per-step gate throws "YurunaCycleRestart: ..." when
/control/start-cycle requests an abort mid-cycle. This is the
operator clicking "Save and start cycle" while a cycle is actively
executing steps: Remove-TestVMFiles has already torn down the VMs,
the flag has been touched, and the cycle needs to unwind cleanly.
Detected by message prefix (cross-module typed exceptions would
need a shared assembly; the prefix is unique enough). Treated as a
NORMAL cycle ending, not an UNHANDLED ERROR:
  - No ConsecutiveCrashes increment -- this is not a code crash.
  - No 60-line origin + stack dump banner -- the flag was visible to
    the operator who set it, no post-mortem needed.
  - Cycle is finalized as 'fail' so status.json reflects the abort
    rather than a phantom pass; teardown proceeds normally; the
    inter-cycle delay loop's existing flag-check then consumes
    control.cycle-restart on its first tick and exits inner, after
    which outer respawns with a clean slate.

<a id="4213a0b3-00fe"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

yuruna_retry-style auto-retry backoff: capped exponential with jitter.
Applied on top of the existing inter-cycle delay so a transient failure
(subiquity restore_apt_config exit 100, github.com 5xx during tofu init,
...) cools the retry off long enough for the upstream blip to pass
without saturating MaxConsecutiveCrashes. Same policy as
automation/yuruna-retry.sh: base doubles each consecutive crash,
capped at MaxDelaySeconds. Skipped when Get-YurunaRetryBackoff is
unavailable (early-bootstrap path before Yuruna.Retry imports).

<a id="4213a0b3-00ff"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Inter-cycle delay LIVES IN THE INNER (not the outer) so the operator
sees the countdown in the same console as the cycle's own output.
Outer is intentionally dumb: it spawns us, waits, and either
respawns immediately (success) or enters its failure-pause (non-
zero exit). Putting the delay here means an "Start-TestRunner is
idle for 30s between cycles" period is observable on the runner
host -- with the delay in the outer, Windows hosts in particular go
dark between cycles, since the outer's Write-Output can be swallowed
by conhost while the inner pwsh is gone.

The countdown is sliced into 1-second waits so Ctrl+C / shutdown /
cycle-pause flag can break out without sitting through a long
Start-Sleep. Write-Progress shows a percentage bar; Write-Output
logs only the start and the end of the wait, so a non-progress-rendering
log collector records no ticks in between.
$CycleDelaySeconds is set inside the cycle's try block once config is
merged; an early throw before that point would leave it null.
Fall back to the script param so the inter-cycle wait is still
respected on the rare crash-before-config path.

<a id="4213a0b3-0100"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-RunnerInnerCycle

Cycle-pause counterpart to the "Cycle-pause back-channel" gate above: a
pause armed via the status UI DURING the cycleDelaySeconds wait is honored
here -- after the wait runs to completion, before we exit the inner, so the
outer respawns the next cycle only once resumed. This is what makes the
UI's "Pause after cycle" button take effect right after the
inter-cycle delay. Gated on $effectiveDelay so it only fires when a wait
actually ran; with no inter-cycle delay the pre-delay gate above is the
sole cycle boundary. Mirrors that gate's wait loop -- keep the heartbeat-
refresh / resume / shutdown handling in sync.

<a id="4213a0b3-0101"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-GuestProvisionIteration

One guest's full lifecycle: cleanup -> New-VM -> Start-VM -> Start-GuestOS ->
New-VM.Resource -> screenshots -> workload -> stop. Lifted out of the cycle's
guest foreach so it is unit-testable. The caller foreach dispatches on
$IterState.Control: 'break' ends the guest sweep, 'continue' skips to the next
guest, 'proceed' falls through. Mutable cycle state carries back two ways -- the
four failure fields through $IterState, and the reloadable config through the
shared bag $cfg (mutated in place by the per-step Sync; the caller re-reads the
mirrors it needs from $cfg after the call). This helper re-reads only the knobs
it acts on: $StopOnFailure (the stop guards) and the VM start timeout.
Status Write-Output flows to the caller's stream exactly as when inline (the
helper is invoked as a statement, not captured).

<a id="4213a0b3-0102"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-GuestProvisionIteration

failure_screenshot_<VM>.png and failure_ocr_<VM>.txt still live
at the YURUNA_LOG_DIR root (shared across cycles, keyed only by
VM name) so without this drop, a later cycle that fails before
any sequence runs (e.g. New-VM aborts on a host-side precondition
like missing openssl) would have Copy-FailureArtifactsToStatusLog
copy the previous cycle's screenshot forward, misleading the
operator. Done unconditionally at the top of each guest iteration
so any artifact that lands in the per-cycle folder belongs to
this cycle. The screens_<VM>/ ring buffer lives INSIDE the cycle
folder (Get-CycleScreenDir) so it can't leak forward -- no cleanup
needed for it here.

<a id="4213a0b3-0103"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-GuestProvisionIteration

On hosts with only a few hardware threads, guests still running
from earlier sequences compete with this guest's OS install: vCPU
totals above the host's thread count plus guest RAM above physical
can deschedule an installer's vCPUs for seconds at a time, so the
autoinstall console appears frozen until the step timeout gives up
on it. Stop the cycle's other test guests first -- the guest sweep
runs one full lifecycle at a time, so guests before this one are
already past their sequences. Scoped to $VMNames (this cycle's
guests only) so infra VMs -- e.g. the caching-proxy service, which every
step asserts reachable -- are never touched. Force, because a
guest sitting in an installer ignores ACPI shutdown.
No continue/break in this loop: the enclosing helper's control-flow
invariant (see Test.RunnerInnerLoop.Tests.ps1) reserves loop escapes
for $IterState.Control signaling, so the skip logic nests instead.

<a id="4213a0b3-0104"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-GuestProvisionIteration

Forward the cache URL detected at runner startup so every guest
uses the same address. Without this, each guest's New-VM.ps1
probes independently and races with transient listeners (stale
DHCP leases, torn-down sibling VMs), baking a dead IP into the
cidata seed -- seen on UTM where apt then fails with "No route
to host" at install. This is the same URL Test-CachingProxyService.ps1
probes; install VMs reach it directly: Default-Switch guests
via Hyper-V's NAT-to-LAN, UTM guests via the vmnet-shared
gateway forwarder. No cache detected -> pass "" so guests skip
their probe: one detection event, one outcome.

<a id="4213a0b3-0105"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-GuestProvisionIteration

Planner-cascaded username: a workload that overrides
`variables.username` propagates that value back to the start
sequence (and therefore to the cloud-init account this New-VM
invocation provisions). Empty effectiveUsername falls through
to the per-host New-VM.ps1 default, preserving today's
behavior when no plan has been resolved (legacy guestSequence
path).

variables.hostname cascades the same way and becomes the guest's
cloud-init local-hostname, which is the name the guest DHCP-registers
under. Empty leaves the guest named after the VM. When it is set, the
UTM dhcpd_leases lookup must key on the pinned name: blocks under the
VM name are then predecessors' and resolve to dead addresses. The host
driver reads the pinned name back out of the bundle's seed ISO, so it
does not have to be threaded down from here.

<a id="4213a0b3-0106"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-GuestProvisionIteration

Resolve the guest's host-side IP so the operator can ssh /
vmconnect / VNC straight from the cycle log. Polls briefly --
KVP integration services on Hyper-V and utmctl/dhcpd_leases on
UTM typically need a few seconds after start to publish an
address. "(pending)" means no host-side answer within the
budget; the actual address shows up in later runner output
(New-VM.Resource / extension scripts) once the guest is fully up.

Where the host is not the DHCP server for the guest network, address
discovery has no in-band source to ask and falls back to reading a
host-side cache that holds the guest only while it happens to be
talking to us. Warming that cache first is what makes the lookup below
answer on the first attempt instead of the fifth.
(memory: feedback_hyperv_external_vswitch_arp_discovery.md)
A contract verb, so every driver answers: each decides for itself
whether a sweep is the right move and bounds its own cost.

<a id="4213a0b3-0107"></a>

## test/modules/Test.RunnerInnerLoop.psm1: Invoke-GuestProvisionIteration

Serialization guard: guests run one at a time, so confirm this VM is
actually gone before the next guest cold-starts -- otherwise a teardown
that silently stalled (e.g. utmctl unresponsive under host memory
pressure) leaves it running and the next guest doubles the load.
Remove-VM's own return can't answer this: its status Write-Output lines
fold into the [bool] cast, so probe Get-VMState directly. A VM still
'running' after one retry blocks the next guest; anything else (absent /
stopped / can't-tell) proceeds.

<a id="4213a0b3-0108"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Forward-env helper

Every Invoke-RunnerOuterCycle return also updates the module's last-result slot,
so Invoke-TestCycleRunner.ps1 can read the typed outcome without capturing the
success stream. The inner is launched through `Process.Start` with inherited
console streams, and `WaitForExit` tracks its exit independently of stdout EOF.

The earlier call-operator launch could hang when its caller captured the success
stream: PowerShell supplied an anonymous stdout pipe, and the inner's status
service inherited the write end through `Start-Process -RedirectStandard*`.
On Windows the service could keep that pipe open after the inner logged "about
to exit with code 0", preventing "outer runner back in control" and the next
cycle. The POSIX detach replaced those descriptors. The current explicit process
wait avoids that EOF dependency.

<a id="4213a0b3-0109"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

1b. Pool intent sync (best-effort, IN-PROCESS, DEFAULT-OFF). Pull the
    pool intent over the LAN and reconcile desiredState BEFORE spawning
    the inner, so a pulled paused/drain gates THIS cycle. A no-op (single
    try-wrapped call that short-circuits) when pool sync is unconfigured
    -- a no-pool host is unaffected. The pull is wall-clock-bounded +
    credential-prompt-proof inside Sync-YurunaPoolIntent, so this can't
    hang the (bare-pwsh-INTERACTIVE) outer loop; any error is non-fatal.
Per-pool config.testCycle override (default-off, empty for a no-pool host),
captured at the cycle boundary so the watchdog (step-timeout) below can let
a pool tighten the step timeout fleet-wide without editing each host's
test.config.yml. This value is per-PROCESS: the failure pause lives in
Invoke-RunnerOuterLoop, in the parent, and cannot read it.

<a id="4213a0b3-010a"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

No clock repair here. Guests take their clock from the host's
virtual RTC at power-on, so a drifted host is worth knowing about
-- but every platform's fix is a privileged call (Administrator,
or a sudo credential nobody is present to type), and an unattended
loop that stops to ask is a hang. Assert-HostConditionSet inside
the inner measures the skew once per cycle and warns; the repair
is offered where a console can answer for it (test/Test-Config.ps1,
host/*/Enable-TestAutomation.ps1).

<a id="4213a0b3-010b"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

2. Spawn the inner. YURUNA_RUNNER_RELAUNCH=1 (set just before the
   spawn, cleared in the finally that follows it) tells the inner
   that we (the outer) own the pidfile + Ctrl+C handler; inner
   skips its own copies of those. It is scoped tightly to the spawn:
   left set in $env: after the inner returns it would suppress the
   inner's single-instance guard for any LATER direct invocation in
   the same shell session, silently disabling concurrency protection.
   Sync-ForwardEnv re-asserts the launch-time snapshot of YURUNA_*
   vars (cache IP, runtime/log dirs, log level, OCR combine) so the
   inner sees them even if some module in this outer process
   clobbered $env: mid-run.

<a id="4213a0b3-010c"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

Deliberately AFTER the last_failure.json wipe. The failure pause classifies
from that file, so a check placed before the wipe would leave the PREVIOUS
cycle's record in place -- and if its class were a transient one, a host with
auto-remediation on would cut the storage pause short and re-enter the same
wall every few minutes instead of holding for the hour.

Running a full cycle only to discover at the end that its results cannot be
archived wastes the cycle; this refuses before the spawn, on a projection
from what recent cycles actually cost.

<a id="4213a0b3-010d"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

break-active.json: written by the `break` sequence action
when a cooperative breakpoint parks the cycle, removed on
resume. If the operator restarts only Start-TestRunner.ps1
while a break is parked, the file survives and the first
new-cycle step's Gate #1 thinks a break is still active --
hanging the cycle on a non-existent marker. Status-service
startup also sweeps this file but the runner can start
without the status service; clean here so both startup paths
agree. Not in a preflight cycle: a refresh archives a reclaimed
inner's marker itself and leaves a surviving inner's alone.

<a id="4213a0b3-010e"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

Same lifetime, different contract: YURUNA_NONINTERACTIVE tells the
child there is nobody at the console to answer a prompt. The spawn
uses `Process.Start` without standard-stream redirection, so the inner
inherits this terminal -- any prompt it raises blocks the whole host
until the watchdog kills it,
with the dashboard still green. Elevation helpers (Initialize-Sudo-
Cache) read this and decline to prompt; the inner widens it to git
and Console.In at its own startup. Cleared in the finally for the
same reason as the relaunch flag: a value left in $env: would make a
later INTERACTIVE run in this shell silently refuse to prompt.

<a id="4213a0b3-010f"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

Fire the backlog-draining archiver in its OWN detached process so a
slow/absent NAS can NEVER delay the next cycle. The drain self-dedupes
(single-instance lock file), fail-fasts on an unreachable share, copies
every not-yet-archived cycle atomically, and is a no-op unless the three
pool paths are configured. Spawn failure is non-fatal. Detach idiom mirrors
Start-StatusService.ps1 (empty stdin sink on Windows so the child can't pin
conhost; nohup + own process group on macOS/Linux).

MOVE mode is deliberately excluded here: it deletes local folders, so it has
to run synchronously (below) where its verdict can still fail the cycle, and
a detached copy running beside it would race it for the same folders.

<a id="4213a0b3-0110"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

Wait on the forwarder PROCESS, not on its lock file. The lock is created
well into the child's own startup -- after module imports, the vault token,
the proxy-IP read and the cycle-folder scan -- and three gated paths exit
without ever taking it. A wait-for-release would therefore observe "released"
instantly while the child was still booting, and the mover would delete the
cycle folder out from under the read it exists to protect. Process exit is
the only signal that means every read is done.

Timing out is survivable, not silent: the archived folder carries its own
cycle.events.ndjson, so the events are never lost -- only their arrival in
Loki is delayed until the aggregator's pull re-reaches the file through the
host's mount fallback.

<a id="4213a0b3-0111"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

On the ONE host the operator configured the pool.alert transport, deliver the
aggregator's ADVISORY pool-degraded alerts: read the latched yuruna_pool_alert_
active gauge over HTTP, enqueue rising edges on the poolStorage NAS spool, deliver
via the notification extension, move to delivered/. Self-elects -- a clean no-op
everywhere the transport is not configured. Fully bounded (HTTP -TimeoutSec on the
gauge fetch AND the Resend POST, plus a per-cycle message cap) and never throws,
so it is safe on the bare-pwsh-INTERACTIVE outer loop (the cycle-end hook
prompt-safe + subprocess-bounded contract). IN-PROCESS so the dispatcher's delivery
ledger (the confirmation channel) is readable; no detached spawn needed.

<a id="4213a0b3-0112"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

Watchdog-kill detection: when the inner exits non-zero AND
the last step heartbeat is older than the threshold, the
cause was almost certainly the watchdog (the exit code is
whatever Stop-Process -Force happened to deliver; the
application-level failure path can't run after a SIGKILL/
TerminateProcess). Tag the situation so the operator doesn't
waste time hunting an application-level failure that never
happened.

<a id="4213a0b3-0113"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterCycle

A SIGKILL leaves no last_failure.json (the inner's application
failure path cannot run), so the auto-remediation pause-skip
below has nothing to classify and the cycle escalates straight
to the full human-wait pause. Synthesize a minimal schema-v2
record -- only when the inner left none -- with the already-
wired 'wait_timeout' class so the ledger-budgeted auto-retry can
end the pause early. Atomic write so a reader never sees a
partial record; the durable budget is keyed by failure fingerprint
and repair, so a runner restart does not reset a deterministic hang's
attempt count.

<a id="4213a0b3-0114"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-OuterCycleDispatch

Wrap the script path in literal double quotes before it reaches
-ArgumentList. Start-Process joins the array elements with spaces WITHOUT
quoting, so a path like "C:\Users\Yuruna Test\..." gets re-split by
CreateProcess and the child pwsh sees -File C:\Users\Yuruna and exits 64
with: The argument 'C:\Users\Yuruna' is not recognized as the name of a
script file. The outer reads that as a failed cycle, so a host whose path
contains a space never completes one. Same pre-quoting as the detached
drain / push spawns above and Start-StatusService.ps1.

<a id="4213a0b3-0115"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-OuterCycleDispatch

-NonInteractive: this child shares the operator's terminal (-NoNewWindow),
and a pwsh that loses its script context there falls into the console input
loop, whose first act is to ask the terminal for the cursor position. On a
terminal another process is also reading, that query never gets its answer
and PowerShell answers a failed console read with Environment.FailFast --
the process dies outright, mid-cycle. A cycle child has no business
prompting for anything, so the input loop is refused rather than survived.
Every supported operator option forwards into the per-cycle child, not
just -Cycle: an option left out here -- a custom config path,
-NoStatusService, -NoConfigGate, a non-default cycle delay or log level --
silently reverts to Invoke-TestCycleRunner.ps1's own default on every
cycle. ContainsKey guards each one so a caller (a unit test, or an older
State shape) that omits a key keeps that script's own default instead of
binding $null/0/empty explicitly.

<a id="4213a0b3-0116"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-OuterCycleDispatch

A child that died young, non-zero, without ever reporting an outcome did not
run a cycle -- it aborted on the way in. Scoring that as a cycle FAIL is a
lie in the direction that costs the most: it points an operator at the tests
and the dashboard for a fault that is upstream of both. The observed shape is
a console that broke under it (a second process on the same terminal, a
closed pty), which kills the child in seconds and produces exactly this
signature: no outcome file, non-zero exit, no time to have done anything.

Threshold, not exit code alone: a cycle that ran for minutes and then exited
non-zero DID run, and its failure is real and must keep its verdict. Only the
implausibly short ones are reclassified, and they are reported loudly as
their own thing rather than folded into either verdict.

<a id="4213a0b3-0117"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterLoop

Transient, non-fault outcomes: hold, then re-enter. The hold is sliced so
a Ctrl+C during it is seen within a few seconds instead of at the end.
'cycle-aborted' joins these: the cycle never ran, so there is no verdict
to print and nothing for the failure machinery to act on. Holding and
re-entering is right for the same reason it is right for a failed spawn --
the condition is upstream of the tests and usually momentary.
'storage-full' is deliberately NOT in this list. These outcomes take a short
hold and retry, which is right for a momentary condition upstream of the
tests; a full share is not momentary -- retrying every 30 seconds would burn
the day re-discovering that nobody has deleted anything yet. It falls through
to the failure branch below and takes the full pause, which ends early only
on a config edit or a new commit: the two things that plausibly change it.

<a id="4213a0b3-0118"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterLoop

3b. Failure -- pause until either a new upstream commit
    lands on the framework repo OR a new commit lands on
    repositories.projectUrl OR the local test.config.yml
    is edited OR the status-UI requests a restart OR the
    cap elapses, polled every FailureCommitPollSeconds.
    The wait loop sleeps in 5-second slices so Ctrl+C is
    responsive (Start-Sleep can't be interrupted by our
    event handler in long sweeps).

<a id="4213a0b3-0119"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterLoop

Trigger 4: status-service /control/start-cycle from
the UI. The endpoint sees this outer's runner.pid as
alive and skips spawning a replacement; without this
poll, that path would leave the UI's "Start cycle"
button silent until the backoff cap. Consume the
flag here so the next inner spawn doesn't re-fire on
it (Debug-TestSequence / inner's boot sweep also consume,
but the closer the consume to the wake the smaller
the window for stale-flag re-entry).

<a id="4213a0b3-011a"></a>

## test/modules/Test.RunnerOuterLoop.psm1: Invoke-RunnerOuterLoop

Trigger 5: gated auto-remediation (default off). For a failure class the
remediation dispatcher maps to a clearly-safe retry there is no point
waiting the full human-commit pause, so end it early and let the next
spawn retry. The attempt budget lives in the recovery ledger, keyed by
the failure's fingerprint, and not in this process: a runner restart
must not hand a deterministic transient a fresh set of retries, and a
passing cycle is what resets it. Everything the dispatcher does not
classify as clearly-safe keeps the full pause.
Local test.config.yml only. The per-pool testCycle override is
resolved in Invoke-RunnerOuterCycle, which runs in a SEPARATE process
on the shipped path, so no variable of its can be read here -- naming
one binds $null over the parameter default and the lookup inside
throws on every poll tick. Carrying the override across that boundary
needs the outcome file, not a variable.

<a id="4213a0b3-011b"></a>

## test/modules/Test.RunnerState.psm1: Adjacency map of valid transitions

Adjacency map of valid transitions. Last writer in the same
transition stays; a fault-from-anywhere fallback comes from the
boot-recovery synthetic transitions below.

The healthy pool-hold loop enters each iteration at 'cycle-start'
(set before the intent pull) and, on a pulled desiredState=paused,
moves to 'paused', then re-enters 'cycle-start' on the next 30s poll.
Both edges are legitimate, so they are in the map -- otherwise every
hold iteration logged two "not in the canonical adjacency map"
warnings, flooding the outer log for the duration of the hold.

<a id="4213a0b3-011c"></a>

## test/modules/Test.RunnerWatchdog.psm1: Start-Watchdog

Wait for the inner to publish inner.pid + the first heartbeat.
180 s upper bound: a loaded host can take well past a minute to
spawn pwsh and import the runner modules, and a premature
give-up here runs the whole cycle unguarded, while a longer
wait costs nothing (the job just idles). If the file still
never appears, log and exit without killing anything --
preferable to picking a PID blindly. The outer wipes both files
before spawning the inner so a stale copy from the previous
cycle can't short-circuit this wait.

<a id="4213a0b3-011d"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence's body and Wait-ForText / Invoke-TapOn call

Invoke-Sequence's body and Wait-ForText / Invoke-TapOn call
contract functions (Get-VMScreenshot, Restart-VMConsole) that live in
Yuruna.Host. When this module loads in a process with no other path
to Yuruna.Host, calling Initialize-YurunaHost here guarantees the
contract is resolvable from every sequence-engine call site. The host driver
is force-imported globally on every call; the Get-Module check skips only
the shared Test.VMUtility import when that helper module is already loaded.

<a id="4213a0b3-011e"></a>

## test/modules/Test.SequenceEngine.psm1: Load global defaults from test.config.yml

Ring-buffer depth for raw pre-OCR screen captures kept per VM (Wait-ForText).
On guest success the buffer dir is deleted; on failure the whole sequence is
preserved so the failure-screenshot link can point at the run-up to the bug.

Measured in FRAMES but it has to be CHOSEN as a duration: what a reader needs
is the window between the keystrokes that caused a failure and the frames that
survive to be looked at. A poll pass is a screenshot plus an OCR pass plus a
sidecar write on top of the pollSeconds sleep -- about 8 s of wall-clock per
frame in practice -- so 20 frames is roughly two and a half minutes of console
history, comfortably more than a multi-prompt credential exchange and the
verdict that follows it have been measured to occupy together.
A handful of frames spans well under a minute and evicts the keystrokes that
explain the failure before the failure is even detected.

The cost is disk, never memory: the ring holds file PATHS, while each frame on
disk is a PNG plus its OCR sidecar (order 100 KB together). A guest that
passes has the whole directory deleted; a guest that FAILS keeps its frames
twice -- here and in the copy taken alongside the failure log -- and cycle-log
rotation moves those folders into a history bucket rather than deleting them.
So every extra frame is paid for twice, indefinitely, and only by hosts that
fail.

<a id="4213a0b3-011f"></a>

## test/modules/Test.SequenceEngine.psm1: Progress wrapper

Under `vmCommunication` with its siblings, not at the file root: the
template overlay is the schema and it DROPS every key the template does
not define, so a root-level key would be deleted from the operator's file
on the next reconciliation and the setting would silently revert to the
built-in default on the following cycle.
Tested with `$null -ne` rather than truthiness because 0 is a value an
operator can mean; the consumer clamps it into range instead of reading
it as "unset".

<a id="4213a0b3-0120"></a>

## test/modules/Test.SequenceEngine.psm1: Action: type / typeAndEnter

Button-focus navigation via Tab keystrokes is brittle: initial focus depends
on splash animation state, async-loaded widgets, and installer redesigns,
so the "correct" Tab count drifts. tapOn sidesteps focus
entirely -- it OCRs the VM screen, locates the button's bounding box, and
synthesizes a mouse click at that box's center.

Coordinate contract: the captured image and the click target share the
same pixel space. On Hyper-V we use PrintWindow on the vmconnect client
area so image (x,y) == vmconnect client (x,y), and ClientToScreen maps
it to a SetCursorPos + mouse_event sequence.

<a id="4213a0b3-0121"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-TapOn

-Global: a nested -Force without -Global evicts Test.YurunaDir from
the parent script's session state, breaking later top-level calls.
Pure eviction recovery: Test.YurunaDir is stateless (Initialize-YurunaLogDir is
env-backed; $env:YURUNA_LOG_DIR survives re-imports), so re-parse the psm1 only
when its command is actually unresolvable -- i.e. when a nested -Force evicted it
-- not on every hot-path pass. Gate on Get-Command, NOT Get-Module: Get-Module
stays truthy after an eviction moves the module into another scope, so it would
skip the very re-assert this exists to perform. (Stateful modules re-imported
nearby -- OcrEngine/Log/Ssh -- are deliberately left unconditional: their -Force
reload also resets $script: registrations/caches, a side effect gating would drop.)

<a id="4213a0b3-0122"></a>

## test/modules/Test.SequenceEngine.psm1: Action: tapOn -- OCR-located mouse click

Persist this frame's OCR output as raw_${stamp}.txt next to the
raw_${stamp}.png it was extracted from. The text file is what the
matcher actually saw -- invaluable for diagnosing "should have matched"
regressions, since the ring-buffer .png alone leaves the reader to
re-OCR the image to figure out why the pattern didn't fire.

AllowEmptyCollection: a [Parameter(Mandatory)] typed-collection param
rejects empty input with the misleading "Cannot bind argument ...
because it is an empty string" error. The empty case happens when
Test-CombinedOcrMatch returns no EngineResults (no providers ran on
this frame); skipping the write is correct -- an empty sidecar would
misrepresent "no engine ran" as "engines ran and saw nothing."

AllowEmptyString: PowerShell's Mandatory binder enumerates a typed
List[string] and validates each element against the implicit non-
empty-string check, so a list containing the trailing '' separators
the callers add between engine sections fails with the same
"empty string" message. AllowEmptyString lifts that per-element
check; AllowEmptyCollection lifts the whole-list one.

<a id="4213a0b3-0123"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Match the positive pattern only against console lines the guest
printed after this step began, ignoring everything the previous step
left on the surface. Set it on a step whose pattern is short enough
that unrelated prose already on screen can satisfy it -- a class the
tolerant matcher cannot avoid, because the same tolerance that lets a
prompt survive dropped and confused characters also lets its letters
be found in order inside a sentence about something else.

Where the previous wait handed one on, the baseline is the frame THAT
wait matched, so a prompt printed in answer to what the step before
typed is new and matchable however long the poll gap was. Without one
-- the first gated step of a sequence, or one whose predecessor failed
-- it falls back to this wait's own first frame and costs a poll: that
frame records what was already there and only later frames can match.

Anti-patterns are deliberately NOT gated by this. Their job is to
notice that the screen is in a state the sought text can never arrive
from, and that state is routinely already on screen when the step
starts -- so they keep reading the whole frame.

<a id="4213a0b3-0124"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Anti-patterns: if ANY of these fuzzy-matches on screen OCR,
abort the wait immediately and return $false. Canonical use
case is subiquity's "install_fail.crash" / "An error occurred.
Press enter to start a shell" output -- at that point the
positive pattern (e.g. "Not listed?" from the GDM login screen)
is never going to appear, so polling until $TimeoutSeconds
wastes up to an hour before the runner gets a misleading
"pattern not found" failure. On match this function also sets
the shared cross-module WaitForTextMatchedFailurePattern signal so
the caller's failure-label builder can surface *which* anti-
pattern fired, producing a banner like
  waitForAndEnter: "Not listed?" -- matched failurePattern "install_fail.crash"
instead of the opaque timeout message.

<a id="4213a0b3-0125"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Anti-patterns that are only meaningful for the first
$EarlyFailureSeconds of the wait, then stop being evaluated.

The canonical use is a shell REJECTING the command line it was just
handed ("command not found", "No such file or directory"). That
verdict is delivered within a second of Enter and means nothing ever
started, so the positive pattern can never arrive and the whole
timeout would be spent proving it. The same strings are also ordinary
output from a script that IS running and healthy -- a package tool
probing for an optional binary prints them constantly -- so as
permanent anti-patterns they would abort good runs. The window is
what separates the two readings: inside it the only thing that has
had time to speak is the shell, outside it the answer is whatever the
payload is printing. That is why this cannot simply be folded into
$FailurePattern, whose entries are (correctly) evaluated for the
whole wait.

<a id="4213a0b3-0126"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Which of the two match paths below this wait will take, because only one of
them measures the console's shape. A tail-confined (freshMatch) wait reads
the same frames but runs neither the flood check nor the content-static
tracker, so the two slots above keep the values set here for the whole wait
-- and 0 / empty are the SAME values a wait that did measure a moving,
non-repeating console leaves behind. Published without this flag the pair
invites the one reading it cannot support: that something looked at the
screen and found it healthy. Recorded here rather than at the failure
returns so it is scoped to this wait exactly like the slots it qualifies.

<a id="4213a0b3-0127"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Wall-clock deadline -- NOT an iteration counter. Adding $PollSeconds per
loop pass would assume every iteration finishes in $PollSeconds of
wall-clock. In practice each iteration does a screenshot + tesseract OCR
+ sidecar write before the Start-Sleep -Seconds $PollSeconds at the
bottom -- on a busy Hyper-V host that adds 5-25 s on top of the sleep, so
a configured timeoutSeconds: 1800 would take 1-3 hours of wall-clock to
expire (and multiplied by retry maxAttempts could exceed half a day
before giving up). timeoutSeconds sets the base wall-clock budget; an
OCR self-heal can extend its deadline by at most min(timeoutSeconds, 120)
seconds in total so a recovering feed has time to deliver a fresh frame.

<a id="4213a0b3-0128"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Import required modules. Screenshot capture is via the Yuruna.Host
contract (Get-VMScreenshot) -- assumed already loaded by the caller's
Initialize-YurunaHost. OcrEngine stays in test/modules/ as a
cross-host helper. -Global is load-bearing: the poll loop below calls
Test-CombinedOcrMatch (Test.OcrMatch module), which resolves
Get-EnabledOcrProvider / Invoke-OcrProvider through the global session
state. A nested -Force WITHOUT -Global evicts Test.OcrEngine from
global (the module-eviction regression class,
feedback_module_force_import_evicts_global.md), so the very next
Test-CombinedOcrMatch call crashes with "Get-EnabledOcrProvider is not
recognized".

<a id="4213a0b3-0129"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Per-VM ring buffer of raw pre-OCR captures. Persists across multiple
Wait-ForText calls within a guest run so the failure path can surface
the run-up to the bug. Cleared at end-of-guest on success by the
runner; preserved on failure and copied alongside the failure log.
-Global on the -Force re-imports: a nested -Force without -Global
evicts the modules from the parent script's session state, so a
later top-level call to Get-CycleScreenDir (Invoke-GuestProvisionIteration
success branch, seen on macOS in-process runners) fails with
"term not recognized".
Pure eviction recovery: Test.YurunaDir is stateless (Initialize-YurunaLogDir is
env-backed; $env:YURUNA_LOG_DIR survives re-imports), so re-parse the psm1 only
when its command is actually unresolvable -- i.e. when a nested -Force evicted it
-- not on every hot-path pass. Gate on Get-Command, NOT Get-Module: Get-Module
stays truthy after an eviction moves the module into another scope, so it would
skip the very re-assert this exists to perform. (Stateful modules re-imported
nearby -- OcrEngine/Log/Ssh -- are deliberately left unconditional: their -Force
reload also resets $script: registrations/caches, a side effect gating would drop.)

<a id="4213a0b3-012a"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Per-line signatures of the console as it stood on this wait's first
readable frame, plus the window applied on top of them. $FreshMatch
narrows the lines a pattern is tested against by POSITION on the screen;
$SinceStepStart narrows them by whether the guest printed them during this
step. Asked for together they compose -- the window applies to whatever
survives the baseline -- so each can only remove lines from what is
matched, never add any. $null (not an empty array) means "not recorded
yet": a screen that read as empty is a legitimate baseline and must not be
re-taken on the next poll.

<a id="4213a0b3-012b"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Degradation-trend early action: the two self-heals above are reactive at a fixed
threshold. Once the feed has proven flaky (a console restart fired), drop
the freeze threshold so the next stall is caught sooner -- acting on the
trend rather than re-waiting the full window. And grant the deadline a
bounded grace per self-heal so a feed that IS recovering isn't killed
mid-recovery by the original deadline (the false ocr_timeout); the cap
keeps a dead feed bounded. Each proactive action emits a `degradation`
event so a degraded-but-passing wait is queryable, not silent.

<a id="4213a0b3-012c"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

OCR is fed the raw capture as-is -- no preprocessing. Do not
reintroduce a vertical-line / grayscale / invert / contrast-
stretch / 2x-scale pipeline, nor a diff-against-the-previous-
frame stage that suppresses unchanged pixels: both corrupt edge
cases (anti-aliased serifs collapsing, fresh text suppressed
when the surrounding pixels also changed). Tesseract / WinRT OCR
/ macOS Vision all handle native-resolution color screenshots
fine.

<a id="4213a0b3-012d"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Flooded-console detection, and a THIRD case distinct from
both branches around it. The no-text branch below sees a
feed with nothing on it; the byte-hash freeze detector
further down sees a feed that stopped changing. A console
scrolling one repeating log line is neither: every frame
differs, so the feed looks perfectly healthy, and every
frame is full of text, so AnyText is true -- while the
pattern being sought has already scrolled out of the
visible surface and is never coming back into it. Left
unnamed this spends the entire timeout and is recorded as
an ordinary pattern-never-printed, which sends the reader
to the guest script that was in fact never reached.

Recorded, NOT acted on: the wait still runs its full
budget. A flood can stop, and aborting early on a
heuristic would trade a slow correct answer for a fast
wrong one. What changes is that the failure names itself.

<a id="4213a0b3-012e"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

Anti-pattern (early-fail) check. Runs AFTER the positive-match
check so a positive match wins ties when both appear in one
frame. Uses $lastOcrText (the freshest OCR output) so the
signature isn't masked by an OCR glitch on the current poll.
The early set joins the permanent one only while the window is
open, so a match inside it reports through the same signal, the
same screenshot capture and the same failure label as any other
anti-pattern -- the window governs WHEN a pattern is consulted,
never what happens once it fires.

<a id="4213a0b3-012f"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

The early set is matched without Test-OCRMatch's segment strategy.
Its members are short, ordinary phrases, and that strategy asks
only whether each of their words turns up somewhere on the screen
-- which a healthy step's own output supplies by accident as soon
as it prints a few KB of URLs or paths. A permanent anti-pattern
is chosen by a step author against the one script that step runs
and keeps the full matcher; these are matched against every guest
in the fleet, so they are held to evidence that sits on one line.

<a id="4213a0b3-0130"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

How long the console content sat unchanged, at its longest. Separates a
guest that was working the whole time from one parked on an unreadable
screen, which the flood detail alone cannot do: Get-ConsoleFloodVerdict
counts repeats WITHIN one frame, so a frozen wall of already-scrolled
text reads as a flood even though nothing is moving.

Only the accumulating match path feeds this. Under a tail-confined
match $maxConsoleStaticSecs is still its initializer, which is what the
measured flag set at entry exists to declare -- the value written here
is an observation only when that flag is true.

<a id="4213a0b3-0131"></a>

## test/modules/Test.SequenceEngine.psm1: Wait-ForText

An empty near-miss list covers three unrelated screens: no window was
in force, the window covered the whole frame, or the text was nowhere
on it. Read alone it is taken for the third. Recording what the screen
DID hold that came closest separates them, and on a frame too short
for a window to hide anything -- a console sitting at a login prompt
-- it is the only evidence there is. Deliberately not gated on
$FreshMatch: a wait with no window that timed out wants the same
answer, and pays for it once, here, not in the poll loop.

<a id="4213a0b3-0132"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-SequenceByName

Planner-cascaded variable overrides. When present, each key in
this map REPLACES the same-named entry under the sequence
file's `variables:` block before step expansion (top-of-chain
wins for the whole chain -- see Test.SequencePlanner). Empty
map = a direct invocation without planner overrides, keeping the
sequence-local variables. Debug-TestSequence forwards its planner's
effectiveVariables through Invoke-TestSequenceChain.
Use IDictionary (not [hashtable]) so an [ordered]@{} from the
planner keeps its insertion order through parameter binding.
A [hashtable] cast would coerce OrderedDictionary -> Hashtable
and lose the order, which then has the override loop below
process e.g. `currentPassword: ${ext:...(${username})}` BEFORE
`username: yauser1`. The `${username}` placeholder fails to
resolve and the literal string ends up as a vault key.

<a id="4213a0b3-0133"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-SequenceByName

Informational lines go through Write-Information, NOT Write-Output.
Write-Output emits to the pipeline, and combined with `return (...)`
below it would fold these strings into the caller's `$ok` variable --
turning the boolean into @("Running...", "Sequence file...", $true/$false).
The caller's `$ok -eq $false` still catches an honest $false inside
that array, but a returned $null (e.g. from an unhandled crash path)
would look identical to success. Keep the pipeline clean so the
return is strictly [bool].

<a id="4213a0b3-0134"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Planner-cascaded variable overrides; see Invoke-SequenceByName.
Null/empty = use the sequence file's own `variables:` block
verbatim. Debug-TestSequence's chain runner forwards planner overrides.
Use IDictionary (not [hashtable]) so an [ordered]@{} from the
planner keeps its insertion order through parameter binding.
A [hashtable] cast would coerce OrderedDictionary -> Hashtable
and lose the order, which then has the override loop below
process e.g. `currentPassword: ${ext:...(${username})}` BEFORE
`username: yauser1`. The `${username}` placeholder fails to
resolve and the literal string ends up as a vault key.

<a id="4213a0b3-0135"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Initialize logDir early so the catch block can write
diagnostics; the runtime dir behind the pause-flag paths resolves below. Invoke-Sequence
runs inside a child module scope when a test-start extension script
imports it, so the parent runner's global Import-Module doesn't
propagate here -- each helper has to be re-imported on this path.
-Global on the -Force re-imports: without it, the nested reload
evicts these modules from the parent script's session state and
breaks subsequent top-level calls (see Get-CycleScreenDir crash).

<a id="4213a0b3-0136"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Pure eviction recovery: Test.YurunaDir is stateless (Initialize-YurunaLogDir is
env-backed; $env:YURUNA_LOG_DIR survives re-imports), so re-parse the psm1 only
when its command is actually unresolvable -- i.e. when a nested -Force evicted it
-- not on every hot-path pass. Gate on Get-Command, NOT Get-Module: Get-Module
stays truthy after an eviction moves the module into another scope, so it would
skip the very re-assert this exists to perform. (Stateful modules re-imported
nearby -- OcrEngine/Log/Ssh -- are deliberately left unconditional: their -Force
reload also resets $script: registrations/caches, a side effect gating would drop.)

<a id="4213a0b3-0137"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Build variables table: built-ins first, then YAML-defined entries
evaluated EAGERLY in file order (full contract:
docs/test-sequences.md#variable-substitution-rules -- the Markdown
is the contract). ${ext:...} in a value runs once at definition
time, so pinning a generated value across steps is an explicit,
file-visible operation. Planner overrides (-EffectiveVariables)
REPLACE same-named YAML entries; ${hostname} is seeded from
-VMName and overwritten by the sequence's variables: block or the
cascade when declared.

<a id="4213a0b3-0138"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Auto-derive ${hostLabel}: the host name a guest's own console prints,
which is not ${hostname}. ${hostname} defaults to the VM name, and a VM
name carries dots -- test-guest.ubuntu.server.26-01 -- while agetty and a
shell prompt both print only the first label, "test-guest". The full name
appears on the console in exactly one place, the /etc/issue banner, so a
pattern built from ${hostname} matches only while that banner is on
screen and stops matching the moment it scrolls, even though the prompt
it is waiting for is still sitting there. A wait like that cannot fail
fast: it spends its entire budget and is recovered only by a retry that
redraws the banner.

Derived after the override merge so it follows whatever hostname is
actually in force, and only when unset, so a sequence or a cascade can
still name it outright.

<a id="4213a0b3-0139"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Cycle-restart back-channel: the status service's /control/start-cycle
endpoint sets this flag while it kills in-progress VMs. The inter-
cycle delay loop in Invoke-TestRunnerInnerLoop already breaks on it, but
if the request lands while a cycle is actively executing steps the
delay loop never sees it -- the cycle limps through screenshot
failures of deleted VMs and the operator's "restart now" never
arrives. Gating here too makes the abort fire from inside an active
cycle: the throw escapes through retry / sequence / runner and is
recognized by the inner's cycle-catch by the message prefix.

<a id="4213a0b3-013a"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Shared pause-wait block. Used both at sequence start (Label='[sequence
start]') and at the top of each step (Label='[stepNum/Count]').
Dynamic scoping resolves $stepPauseFlagFile and $writeCurrentAction
from the caller's scope at invoke time, so the scriptblock doesn't
need its own parameters for those.

This gate holds the RUNNER, not the guest: the VM is created and started
before the sequence begins, so it keeps running -- and printing -- for as
long as the hold lasts. Anything the guest prints once and does not reprint
(a boot-time confirmation prompt) can therefore expire while parked here,
and the step that was going to read it resumes against a screen that no
longer carries it. Both ends of the hold are published to the event stream
so a failure that follows one can be read as such instead of as a guest
that never printed; see docs/control-routes.md, "Pause and resume".

<a id="4213a0b3-013b"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Cycle-restart gate. Throws a control-flow marker so the inner
runner's cycle-catch (see Invoke-RunnerInnerCycle) can short-
circuit emergency-cleanup chatter and skip the ConsecutiveCrashes
increment for this expected abort. The flag is intentionally NOT
cleared here: the post-cycle inter-cycle delay loop will consume it
on its next tick, which keeps the existing "wake delay early" path
working unchanged. If the inner is already past the delay (i.e.
actively running this sequence), the throw propagates up through
any enclosing retry / step / sequence frames straight to the cycle
try/catch.

The marker is carried BOTH as an Exception.Data tag and as the
'YurunaCycleRestart:' message prefix. Consumers prefer the structured
tag, which survives a rewrap that a downstream `throw "wrapped: $_"`
would strip from the message; the prefix stays as the fallback so any
reader still matching on the message routes this abort correctly.

<a id="4213a0b3-013c"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Lab-health gate: hold here while a lab service this host HAD been
reaching has stopped answering, and resume when it returns. A service
that was never reachable is deliberately not a hold -- see
Test.LabHealth -- so a host with no stash still fails fast in the
caller's own preflight rather than parking on its first cycle.

Get-Command-guarded: an entry point whose module set omits Test.LabHealth
runs ungated, which is the behavior every caller had before the gate and
is a better failure mode than a step that cannot start.

<a id="4213a0b3-013d"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Gate #1: sequence-level pause + cycle-restart check, before any per-
sequence work. Pause is checked first so an operator-initiated pause
that overlaps a restart click still resolves predictably (pause
wins until released, then the restart flag is observed). The lab-health
hold sits between them: an operator who has parked the cycle is present
and outranks a machine-initiated hold, and re-probing a lab nobody is
watching achieves nothing.
Cleared here rather than with the other per-sequence cause slots further
down: those run AFTER this gate, and the hold this gate is about to record
is the one most worth reporting -- it ends with the guest already booted and
a step about to read a screen that moved on without the runner.

<a id="4213a0b3-013e"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

takeScreenshot debug PNGs land under test/status/captures/sequences/
(gitignored runtime data, lives with the rest of the harness state
so cleaning a host is one rm -rf status/* away). Sequence name is
prefixed onto each filename in Save-DebugScreenshot, so a single
flat folder keeps captures organized without a per-sequence subdir.
Anchor on $PSScriptRoot (this module lives at <TestRoot>/modules/);
$SequencePath is unreliable as a harness-state anchor because project-tree
sequences live under <RepoRoot>/project/.../test/. The chain runner uses
each entry's real path with a local StartStep/StopStep window.

<a id="4213a0b3-013f"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Wrapped as a script-block so the `retry` action case (below) can call
it on its inner `steps:` array, reusing the full per-step
infrastructure: pause checks, currentAction sidecar, progress ticks,
variable expansion, the action switch, PASS/FAIL logging. The block
resolves $vars, $writeCurrentAction, $waitWhilePaused,
$waitWhileLabHealthy, $HostType,
$VMName, $GuestKey, $logDir, $screenshotDir, $ShowSensitive, and the
$script:Default* defaults from the enclosing function scope via
PowerShell's dynamic-scoping read semantics; the param $Steps shadows
the outer $steps within the block. On step failure the block captures
context into the shared failure store ($script:Fail) and returns $false. The OUTER call
site below is what writes last_failure.json + failure screenshot +
post-failure pause, so a transient failure inside a retry attempt
never pollutes last_failure.json -- only an exhausted-retry failure
(or a non-retry failure) does, after the outer call finally returns.

<a id="4213a0b3-0140"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Refresh runner.stepHeartbeat from the runspace so the outer
watchdog can detect a single step that exceeds testCycle.stepTimeoutSeconds.
We do NOT update this inside the action's own poll
loop -- the threadpool-driven runner.heartbeat already
provides proof-of-life for the process. Refreshing only at
step boundaries means the watchdog kicks in if any single
step (waitForText with its own deadline, ssh exec, retry
block) hangs longer than the configured budget.

<a id="4213a0b3-0141"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Current-step visibility is intentionally driven by Write-Progress
(via Write-ProgressTick below), NOT by a Write-Information here.
A Write-Information at step-start would go through the Yuruna.Log
proxy and leave a permanent line in both the terminal and the log
transcript -- then the end-of-step completion line (with elapsed
time) would appear below rather than replacing it. Write-Progress
renders out-of-band (floating bar) and auto-dismisses on
-Completed, so the scroll-permanent log gets exactly one entry
per step (the completion).

<a id="4213a0b3-0142"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Per-step registry dispatch. Test.SequenceAction lets a verb
register a Handler scriptblock; the Context hashtable is the
canonical state surface (no closures over the parent function's
locals). Every built-in verb -- including `retry` -- registers
a Handler.
A YAML typo (e.g. "tapButton" instead of "tapOn") or a third-
party verb that registered a FailureLabel without a Handler
surfaces here as a hard fail so it never silently passes.

<a id="4213a0b3-0143"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

A verb's registration states how it classifies ITS OWN failure, so it
belongs only on a row that actually failed. Stamped on a passing row
it leaves `ok` as the single field that separates a real failure from
a static registration, and every grep, Loki selector and dashboard
filter for a class then matches once per executed step of that verb --
all of them passes. Nothing is lost by omitting it: actionVerb is on
the row, and Get-SequenceAction maps it back to the same registration
for a consumer that wants to know what the verb WOULD have classed a
failure as.

The verbDefault* names say the other half: these are the registry's
values for the verb, not a reading of what went wrong here, while
step_failure publishes a real classification under failureClass /
severity / suggestedRecoveries -- one that a matched failure pattern
or an unreachable guest can move off the registration entirely. One
key over both would make a join across the two rows compare a
measurement against a constant and call them the same field.

<a id="4213a0b3-0144"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Avoid the dual unwrap trap: PowerShell flattens single-element
arrays AND empty arrays out of an if-statement's pipeline
output, so `[string[]]$x = if (...) { @(...) }` yields a scalar
on a 1-element value and $null on an empty value. The two-step
form below initializes to an empty string[] up front, then
overwrites only when there are entries to materialize; either
outcome serializes as a JSON array and clears the schema
validator's typed-array check.

<a id="4213a0b3-0145"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Emit one structured row per step execution. stepName is the
RAW (pre-expansion) YAML `description:` -- variables like
${vmName} are intentionally NOT expanded here so cross-cycle
joins on stepName remain stable even though vmName changes when
saveDiskSnapshot renames the VM and carries a host-id segment in a pool.
Falls back to step.action when no
description is set. A retry emits its enclosing interval and final
outcome as well as the children; readers count only top-level rows
when summing work and final failures.

<a id="4213a0b3-0146"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Build a human-readable failed-step label (e.g. 'waitForText: "login prompt"').
Canonical builder: Test.SequenceAction\Get-SequenceActionFailureLabel.
Each verb's FailureLabel scriptblock lives next to its capability
requirements in Test.SequenceHandler.psm1 -- search for
Register-SequenceAction. The OUTER call site reads $script:Fail.Last-
Failure* below to write last_failure.json + the failure screen-
shot. Capturing here (and only returning $false) keeps transient
retry-attempt failures from leaving a stale last_failure.json
behind.

<a id="4213a0b3-0147"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

If a wait-signal verb short-circuited on a failurePattern,
annotate the step label so the runner's ERROR banner and the
per-run failure JSON both say *why* the step died instead of
the generic "pattern not found within Ns". The set of verbs
that populate this signal is declared per-verb via the
UsesWaitSignals registry flag (Register-SequenceAction), so a
new wait verb opts in at its registration rather than editing
this engine site. For other actions the signal is $null and
the label is unchanged.

<a id="4213a0b3-0148"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Inner-verb capture for retry-exhausted failures. The per-step failure
branch in $invokeStepBlock overwrites $script:Fail.LastFailedAction with
the OUTER step's action name (= 'retry') whenever a Handler returns
$false; that collapses the deepest inner verb's classification
into 'retry_exhausted'. The retry Handler captures the inner verb
into these slots BEFORE returning so the v2 emitter below can
surface both classes -- 'retry_exhausted' for the outer step,
plus the inner class an autonomous remediator needs to pick the
right recovery (an OCR timeout asks for a different remediation
than an SSH down).

<a id="4213a0b3-0149"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Built after the capture above, not before it: the record names the
screen artifacts this failure left behind and only claims one that is
already on disk and newer than the failing step, so a record built
first would have to describe a frame that does not exist yet.
New-SequenceFailureRecord reads the $script:Fail slots and returns
both the last_failure.json ordered dict and the matching step_failure
NDJSON record so the file and the event stream can never drift. See
docs/failure-schema.md.

<a id="4213a0b3-014a"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

YurunaCycleRestart is a control-flow marker from the cycle-restart
gate ($checkCycleRestart), not an actual sequence failure. The gate
comment at Gate #2 promises it "bubbles up to the cycle-level try/
catch in Invoke-TestRunnerInnerLoop" -- re-throw before the generic
handler turns it into a Write-Warning + return $false, which would
leave control.cycle-restart unconsumed and the flag re-fires on every
subsequent sequence's [sequence start] gate. Prefer the structured
Exception.Data tag (survives a rewrap that would strip the message
prefix); fall back to the message prefix so an untagged marker from an
older throw path still re-throws instead of being counted as a crash.

<a id="4213a0b3-014b"></a>

## test/modules/Test.SequenceEngine.psm1: Invoke-Sequence

Preserve diagnostics for the crash, in the SAME schema-v2 shape
the normal failure path emits above. Without this, a
throw from any verb Handler (or from infrastructure between
steps) silently downgrades last_failure.json from v2 to a v0
crash payload, stripping failureClass/severity/suggested
Recoveries -- the exact fields a downstream remediator routes
on. When $script:Fail.LastFailedAction was already captured by the
per-step failure branch we resolve its registry entry; otherwise we
fall back to the canonical 'unknown' classification (the same
fallback the per-step paths above use when a verb is unresolved)
so the record stays schema-v2 AND passes the failureClass/severity
enum validation in Test.EventSchema. The crash stays distinguishable
via the "engine crash: ..." action label, the crashError field, and
the .context.crash block -- a separate enum value carries no routing
weight, since the remediation dispatcher already maps 'unknown' to
pause-and-inspect.

<a id="4213a0b3-014c"></a>

## test/modules/Test.SequenceEngine.psm1: Recursive step executor

Registered in per-host singular-noun modules:
  Test.HostIO.HyperV.psm1   host.windows.hyper-v
  Test.HostIO.Utm.psm1      host.macos.utm
  Test.HostIO.Kvm.psm1      host.ubuntu.kvm
Each module owns only its Register-HostIOProvider calls; the
function bodies (Send-KeyHyperV / Send-KeyVNC / Send-KeyUTM /
Send-KeyKvm / Send-TextHyperV / Send-TextVNC / Send-TextUTM /
Send-TextKvm / Send-ClickHyperV / Send-ClickUtm) live in
Test.Transport.psm1. The startup capability matrix reads
Get-HostIOProviderMatrix so the operator sees which actions are
wired on the current host before the cycle starts. See docs/host-io.md.

<a id="4213a0b3-014d"></a>

## test/modules/Test.SequenceEngine.psm1: Host I/O provider registrations

Failure-label scriptblock convention: $Context carries Step (parsed YAML
step), Vars (variable scope), and ExpandVariable (live reference to
Expand-Variable; we pass it in so the registry module does NOT have to
import Invoke-Sequence). Each block reads $Context and returns the
label string. Capability requirements (HostIORequirement + OcrRequired)
ride in the same registry entries; Test.Capability reads them from there.

See ../../docs/test-sequences.md#handler-contract for the built-in verb
catalog's -Global wiring and how it coordinates through the shared
failure-state store. -- Test.SequenceEngine.psm1

<a id="4213a0b3-014e"></a>

## test/modules/Test.SequenceFailureState.psm1: Initialize-SequenceFailureStateStore

Populated at any wait that timed out having read some text: per engine and
per sought pattern, the line on the final frame that came closest and how
close. The near-miss slot above is empty for three unrelated screens, so on
its own it cannot say whether anything resembling the pattern was there;
this can, and on a frame shorter than the tail window -- where the window
is incapable of hiding anything -- it is the only screen evidence in the
record. Three states: entries, an empty array from a scan that compared the
frame and found nothing like the pattern, and $null from no scan at all --
a wait that ends on a failure pattern returns the moment it matches, and a
failure outside a wait has no frame. Only the first two say anything about
the screen, so the third must not arrive wearing the second's shape.

<a id="4213a0b3-014f"></a>

## test/modules/Test.SequenceFailureState.psm1: New-SequenceFailureRecord

Both console fields describe a screen something looked at. When the wait
confined its match to the console tail, nothing did: the flood check and the
content-static tracker never ran, so 0 / '' are initializers rather than
readings -- and they are exactly the values a measured healthy console
produces. $null keeps both keys present while saying the wait did not look,
so no consumer can read "the console was moving" out of a measurement that
never happened. A store with no flag at all is treated as measured, so a
record built from one keeps the shape it already had.

<a id="4213a0b3-0150"></a>

## test/modules/Test.SequenceFailureState.psm1: New-SequenceFailureRecord

Wait-ForText short-circuit on a hard-block pattern reclassifies the step.
The recoveries move with the class: the verb registry's hint describes
its DEFAULT failure (a completion marker that never arrived, which is
worth retrying), and a matched failure pattern is the opposite case --
the guest script announced its own failure, so a retry only re-runs a
command already known to fail. Leaving the registry's retry hint in
place here would advertise a retry for exactly the failure that cannot
benefit from one.

<a id="4213a0b3-0151"></a>

## test/modules/Test.SequenceFailureState.psm1: New-SequenceFailureRecord

The session dropped while the command was running, so the registry's
script_error is describing a script whose outcome nobody observed.
network_timeout is both the honest name and the one an in-place warm
resume acts on -- re-running the sequence from its last-good step on
the same live guest is exactly the right answer to a path that broke
under it, and is unreachable while the record says script_error.
Ordered after the address check on purpose: an unresolved address is
the more specific fault, and the two cannot both be true anyway --
the ssh driver returns before dialing when it has no address.

<a id="4213a0b3-0152"></a>

## test/modules/Test.SequenceFailureState.psm1: New-SequenceFailureRecord

Ordered last of the guest-side corrections, and that ordering is what
makes it safe: this signal is read out of output the guest sent, so
reaching it means the session held and the wrapper spoke. The three
above describe the ways that does NOT happen -- no address, a dropped
link, a run nobody could account for -- and each is the more specific
fault where both could look true. What is left is a guest that ran the
wrapper and was served nothing, so no script executed and the registry's
script_error names a thing that does not exist.

<a id="4213a0b3-0153"></a>

## test/modules/Test.SequenceFailureState.psm1: New-SequenceFailureRecord

repro: a copy-paste command that re-runs the failing sequence (and its
baseline chain) to reproduce the failure deterministically. The command
deliberately OMITS -StartStep: stepNumber is file-local (1-based within
this sequence file), but Debug-TestSequence's -StartStep is chain-GLOBAL, so a
naive -StartStep would mis-target a leaf that still has an unbuilt
baseline. The file-local failing step is exposed as resumeFromStep
(advisory; valid as -StartStep on the warm / no-baseline path). Contract
in docs/failure-schema.md.
Strip characters that would break out of the double-quoted repro arguments
('"', backtick, '$') or split the command line (CR/LF). The repro is
surfaced for copy-paste and for an autonomous remediator to run, so a
hostile or malformed VM/guest name must not become an execution hazard.
Identifiers are normally quote-free, so this only ever changes pathological
names; the data fields (sequenceName, vmName, guestKey) keep the real value.

<a id="4213a0b3-0154"></a>

## test/modules/Test.SequenceFailureState.psm1: New-SequenceFailureRecord

Cycle-dir-relative, naming where the artifacts actually land. The flat
root-level form these carried was keyed only by VM name, so every cycle
that failed on the same guest rewrote the same two files: a pointer read
later could resolve to a DIFFERENT cycle's screenshot and give no sign
that it had, which is worse than a path that resolves to nothing.

Claimed only when the source artifact was written after the failing step
began. Both sources are sticky per-VM files at the log root that only the
verbs which read a screen ever rewrite, so a failure in a verb that reads
none inherits whatever an earlier step left behind -- and a pointer to
that reads as this failure's screen, sending the reader after a fault
that belongs to a different step. The boundary is the step's START, not
the failure instant: every artifact for a failure is written before the
record describing it, so the instant would reject all of them. The
2-second slack absorbs filesystem timestamp granularity (FAT/exFAT round
mtime to 2s), the only skew that can under-report a genuinely fresh
write; a stale artifact is a whole step older at minimum, so the slack
cannot reach one. With no step boundary recorded, both are claimed as
before: nothing is known about their age, and an absent judgment is not
evidence of staleness.

<a id="4213a0b3-0155"></a>

## test/modules/Test.SequenceFailureState.psm1: New-InfraFailureRecord

What the host itself held at the moment it refused. A provisioning
failure is a statement about the machine rather than about the guest, and
the machine's memory position is recoverable from nothing else the cycle
keeps -- those numbers exist only in the instant of the call. Carried only
when a driver actually measured; ABSENT otherwise, on the same discipline
the screen-evidence pointers follow, because a zeroed block would be read
as a machine measured and found empty. The file nests the reading and the
event carries it flat, like every other nested value on this stream.

<a id="4213a0b3-0156"></a>

## test/modules/Test.SequenceHandler.psm1: The wrapper prints the sentinel for two different events, and only it can tell

The wrapper prints the sentinel for two different events, and only it can tell
them apart: a script that RAN and exited non-zero, and a payload that was never
served so nothing ran at all. It already says which in the parenthetical it
appends. Matching only the sentinel discards that, and the second event then
arrives as the verb registry's script_error -- a script to debug that never
existed, and a class the transient allow-lists exclude, so the failure most
likely to clear on its own is the one nothing retries.

These are the never-ran reasons that are SAFE to retry. Two are deliberately
absent. "(exit N)" is the script's own non-zero status -- it ran, and
script_error is correct. "(integrity mismatch -- refusing to run)" also never
ran, but it is a refusal, not a shortage: the fetched bytes did not match the
host's digest, and a retry is the one response that must not be advertised for
it. The strings are mirrored from automation/fetch-and-execute.sh and pinned
against it by a drift guard, the same coupling the sentinel itself uses.

<a id="4213a0b3-0157"></a>

## test/modules/Test.SequenceHandler.psm1: The shell's own refusal of the command line it was just handed

The shell's own refusal of the command line it was just handed. Unlike the
sentinel above -- which the wrapper prints, and which therefore proves the
wrapper RAN -- these come from bash before anything of ours executes: the
interpreter named on the line does not exist, so no script, no wrapper and no
sentinel will ever appear, and the completion marker is unreachable from the
first second onward.

The way a console-typed command reaches that state is the keystroke
transport: the line is delivered one key event per character into a guest
whose input layer can drop and reorder them under load, and a command word
that loses four characters is a command word that does not resolve. Nothing
upstream can see that happen, and nothing downstream can distinguish it from
a payload that is merely slow, which is why the shell's answer is worth
reading directly.

These are matched ONLY inside Wait-ForText's early window (see
$script:ShellRejectionWindowSeconds). A healthy script can probe missing
binaries or deliberately test invalid shell input, so these strings alone
do not establish command-delivery failure outside that window.

<a id="4213a0b3-0158"></a>

## test/modules/Test.SequenceHandler.psm1: Resolve-WaitForTextStepParam

Confine the positive match to lines that were NOT already on screen
when the wait began. A prompt whose wording is a subsequence of text
standing above it -- PAM's "New password:" against the banner saying
the password must be changed -- matches that banner on the first
poll, and the verb then answers a prompt the guest has not printed:
the password lands on a tty PAM has not yet switched to no-echo,
echoes in the clear, and the retype can no longer match. Only text
the step itself provoked can carry that verdict. failurePatterns are
deliberately NOT narrowed this way -- a crash screen is evidence
whenever it is visible, including when it was visible on arrival.

<a id="4213a0b3-0159"></a>

## test/modules/Test.SequenceHandler.psm1: Verb registrations

Shared tail of the type-then-Enter input verbs (inputTextAndEnter, waitForAndEnter,
passwdPrompt, fetchAndExecute): send the already-expanded $Text; on a Send-Text
failure bail BEFORE draining (no Enter is sent); otherwise drain $DelaySeconds with
progress ticks + an 800ms settle, then press Enter. Returns the Enter result as
[bool] (or $false when Send-Text failed). Callers keep their own "Typing ..." debug
line -- the message text and the sensitive-masking rule differ per verb -- and decide
whether to return the result or continue (fetchAndExecute continues to wait for a
completion marker). $ShellEscape is OFF for passwdPrompt so the password types
literally, ON for the command/text verbs, matching each verb's Send-Text call.
Send-Text / Send-Key are qualified to Invoke-Sequence's dispatcher (the same names
also exist on the per-host I/O modules imported here). Write-Progress-only ticks
emit nothing to the output stream, so the single [bool] return is uncontaminated.

<a id="4213a0b3-015a"></a>

## test/modules/Test.SequenceHandler.psm1: Invoke-BlindAnswer

A screen this step names is one the answer must never be typed at. Both
halves of the blind contract are satisfied by an interactive menu just as
well as by the scrolled-away prompt they were written for: a menu waiting
on a keystroke is perfectly static, and the keystroke navigates it, so the
console moves and reads as consumption. Only the screen itself separates
the two. Declining costs nothing but the recovery -- the step still spends
the rest of its budget on the wait it asked for -- so a pattern here is
safe to be wrong about in a way a failurePattern is not. Matched with
-NoSegmentMatch so an anti-pattern cannot fire on its own words scattered
across an unrelated screen.

<a id="4213a0b3-015b"></a>

## test/modules/Test.SequenceHandler.psm1: Verb registrations

Optional wall-clock bound so an UNATTENDED cycle does not wedge here
forever: step.timeoutSeconds, else a global YURUNA_BREAK_MAX_SECONDS,
bounds the wait. With neither set the wait is effectively unbounded --
the interactive default when an operator is present. On timeout the
break auto-resumes IN PLACE (resumedVia='timeout'); the continue-button
snapshot-restore path below is intentionally skipped for a timeout.
Parse the optional timeout defensively. A bare [int] cast throws on a
non-numeric value (e.g. an operator typo like '5m' in the free-text
YURUNA_BREAK_MAX_SECONDS, or a bad step.timeoutSeconds the schema does not
constrain for break). This handler's dispatch wrapper has a finally but no
catch, so an escaping throw would bypass the break's soft/return-$false
envelope and abort the cycle -- the opposite of the unattended-wedge guard
intended here. Default to 0 (unbounded interactive wait) when unparseable.

<a id="4213a0b3-015c"></a>

## test/modules/Test.SequenceHandler.psm1: Verb registrations

The registered class is the DEFAULT -- what this verb failed as when no
failPattern matched. That is the completion marker never arriving, i.e. a
wait_timeout; the fetched script hanging on a stalled package mirror is the
common cause. Registering 'pattern_matched_failure' here asserted the
opposite: that the wrapper printed its failure tag. Nothing re-checked it,
so a plain timeout was reported as a script-reported failure, routed to
pause_and_inspect ("auto-retry would just re-trigger it") and excluded from
warm resume -- turning a transient upstream stall into a dead cycle needing
an operator. Build-SequenceFailureRecord still reclassifies to
pattern_matched_failure when a pattern actually matched, so that case keeps
its own label and its no-retry routing.

<a id="4213a0b3-015d"></a>

## test/modules/Test.SequenceHandler.psm1: Verb registrations

This IS the fetchAndExecute action, so its fetch-and-execute
contract (automation/fetch-and-execute.sh) always applies: the
wrapper prints "NONZERO SCRIPT EXIT:" on a non-zero child exit.
Derive the fast-fail from the ACTION, never from the literal
waitPattern text -- keying it off the waitPattern (e.g. matching
"FETCHED AND EXECUTED:") silently disabled this seconds-fast crash
detection the moment anyone decorated or reworded the human-facing
completion marker, leaving a crashed fetch to burn the full timeout.
The marker deliberately avoids the words "fetch"/"execute"
(Test-OCRMatch is fuzzy and would otherwise match the echoed
'fetch-and-execute.sh ...' command line on the first poll and fail
a healthy run in ~4 s); "NONZERO" cannot collide with a command or
normal script output. A step can still override via failurePatterns.

<a id="4213a0b3-015e"></a>

## test/modules/Test.SequenceHandler.psm1: Verb registrations

The window is the ONLY thing keeping a marker printed by an EARLIER
fetchAndExecute from satisfying this one: freshMatch here is a tail
restriction and nothing else -- it does not first require the pattern
to clear -- and sequences reuse one generic completion marker for
every step. So the window cannot simply be opened up: past the point
where the previous step's marker is still inside it, a step that never
ran reports success, which is worse than the failure widening it
would prevent.

It cannot stay at the waitForText default either. Anything the guest
emits after the marker -- a console repaint, a completion listing, a
late daemon line -- pushes it out and fails a run that SUCCEEDED, and
the replay that follows re-runs work that already landed. A modest
default absorbs an extra repaint; a sequence that clears the screen
before this step has nothing stale to confuse and can safely raise
freshMatchTailLines as far as its own output needs. The near-miss
report at the wait's timeout names that knob and the value to use.

<a id="4213a0b3-015f"></a>

## test/modules/Test.SequenceHandler.psm1: Verb registrations

Optional OCR-based fast-fail: when `installerFailurePatterns` is
set, periodically screen-OCR the guest while waiting for SSH and
short-circuit if any pattern matches. Targets subiquity's
"install_fail.crash" / "Press enter to start a shell" output --
without this, a crashed install only surfaces after the full
timeoutSeconds (~40 min on the Ubuntu Server sequences) because
sshd never comes up to satisfy Wait-SshReady. Pairs with the
yuruna_retry exp-backoff auto-retry in Invoke-TestRunnerInnerLoop so
a transient installer flake is recovered on the next cycle.

<a id="4213a0b3-0160"></a>

## test/modules/Test.SequenceHandler.psm1: Verb registrations

Test.OcrEngine + Test.YurunaDir + Test.Log live alongside this
module; Import-Module -Force is cheap once warm. -Global on all
three is load-bearing: a nested -Force WITHOUT -Global evicts the
module from the parent (global) session. Test-CombinedOcrMatch
(Test.OcrMatch module, called below) resolves Get-EnabledOcrProvider
/ Invoke-OcrProvider through global, so evicting Test.OcrEngine here
crashes the OCR scan (the module-eviction regression class,
feedback_module_force_import_evicts_global.md).

<a id="4213a0b3-0161"></a>

## test/modules/Test.SequenceHandler.psm1: Verb registrations

Detached by default. The payload runs under a supervisor on the guest
and outlives the session, so a renumber costs a re-attach instead of
the step -- and, unlike a re-run, that is sound for a payload that
seeds records and then asserts counts over them, which is most of what
this verb carries. `detach: false` opts a step out.

The token is derived rather than random, and that is load-bearing
twice: a reconnect within the step attaches to the same run, and a
warm resume that re-enters this step on a guest that is still up
attaches to the work already in flight rather than starting it again.

<a id="4213a0b3-0162"></a>

## test/modules/Test.SequenceHandler.psm1: retry / recoverFromSnapshot

Preserve what the failed attempt had on screen, before the next
attempt's waits recycle the frame ring and overwrite the
per-VM failure screenshot. An attempt that later succeeds
takes the whole cycle to a pass, and every path that gathers
evidence is a cycle-failure path -- so without a copy taken
here, a recovered failure is unreconstructable no matter how
often it recurs. Gated on hard severity: soft classes are the
ones the retry exists to absorb, and copying for those would
bury the real captures under routine ones.

<a id="4213a0b3-0163"></a>

## test/modules/Test.SequenceHandler.psm1: retry / recoverFromSnapshot

ARM64 Hyper-V can wedge while booting either the live installer
or the installed guest, with virtual processors spending almost
all of their time outside the guest. A console reconnect cannot
change that VM state; a cold power cycle can. Keep recovery
opt-in, platform-specific, and limited to a login wait or a
separately confirmed stall before installer confirmation.
In particular, never restart on an installer failurePattern,
a console flood, or a password-prompt failure.

<a id="4213a0b3-0164"></a>

## test/modules/Test.SequenceHandler.psm1: retry / recoverFromSnapshot

Back off before the next attempt. Re-running instantly
burns all attempts in milliseconds and gives a transient
fault (network blip, a service still coming up) no time to
clear. Get-PollDelay is jittered + exponentially capped,
so it also breaks lock-step when many guests retry at
once. Refresh the heartbeat first so the watchdog stays
aligned across the wait (mirrors the per-attempt refresh
above).

<a id="4213a0b3-0165"></a>

## test/modules/Test.SequencePlanner.psm1: Pull in Resolve-SequencePath and Read-SequenceFile from the engine module

Pull in Resolve-SequencePath and Read-SequenceFile from the engine module
so prereqs resolve the same way Invoke-Sequence does.

-Global is required: -Force without -Global yanks the engine module out of
the global session (see the module-force-evict trap in repo memory). The
runner imports Invoke-Sequence at startup; if any later -Force import here
evicts it, every caller that built a function reference to e.g.
Invoke-SequenceByName / Read-SequenceFile loses visibility.

<a id="4213a0b3-0166"></a>

## test/modules/Test.SequenceResolve.psm1: A snippet is a named, reusable list of steps spliced into a sequence wherever

A snippet is a named, reusable list of steps spliced into a sequence wherever
a `{ snippet: <name> }` step appears (including inside retry.steps), so common
preambles like the cold-agetty login prime live in one place instead of being
copied across every workload sequence. Libraries are `_snippets.yml` files (a
map of name -> step-array) living beside the sequences: framework
`test/sequences/_snippets.yml` and project `project/<...>/test/_snippets.yml`.
Project entries override framework ones of the same name (mirrors
Resolve-SequencePath's project-wins layering);
two PROJECT libraries defining the same name is a fatal ambiguity. Expansion
runs inside Read-SequenceFile so every consumer (executor, planner, perf, step
windows) sees the already-spliced steps with no per-call-site wiring.

<a id="4213a0b3-0167"></a>

## test/modules/Test.SequenceRunner.psm1: Resolve-TestSequencePlan

When the top-level sequence declares `requiresSnapshot: { id: <X> }`,
the chain ends in a saveDiskSnapshot that renames `test-<guestKey>`
-> <X>. Two paths:

  WARM: persisted VM <X> exists AND already has snapshot <X> on disk.
        Skip every prereq sequence and run only the top-level against
        <X>. The top-level's first loadDiskSnapshot reverts the disk.

  COLD: snapshot not present. Walk the full chain. The build VM is
        created with the test-<guestKey> name (so Remove-TestVMFiles
        can sweep a failed cold build); saveDiskSnapshot renames it
        to <X> mid-chain, and subsequent entries operate on <X>. The
        per-entry loop below detects the rename and updates $VMName.

<a id="4213a0b3-0168"></a>

## test/modules/Test.SequenceVariable.psm1: Variable substitution for sequence step text: ${var} placeholders and

Variable substitution for sequence step text: ${var} placeholders and
${ext:area.Method(args)} extension expressions. See
../../docs/test-sequences.md#variable-substitution-rules for the rules and
why this is kept outside the engine. -- Test.SequenceVariable.psm1
Private-use Unicode codepoint used as the placeholder for `$` after the
$$ -> sentinel pre-pass and before the sentinel -> $ post-pass. The
Unicode private-use area (U+E000-U+F8FF) is reserved for application-
specific use and effectively never appears in legitimate input, so it
is safe to round-trip through the regex pass without colliding with
something a user actually typed.

<a id="4213a0b3-0169"></a>

## test/modules/Test.SequenceVariable.psm1: ${ext:area.Method(arg1, arg2, ...)} -- inline expression form

${ext:area.Method(arg1, arg2, ...)} -- inline expression form. ArgList
may include nested ${var} placeholders, which are expanded BEFORE the
extension is invoked. Each call is dispatched fresh -- there is no
caching, so ${ext:authentication.NewRandomPassword()} returns a new
value every time it is evaluated. Side-effecting calls
(e.g. Set-Password) still belong in the dedicated `callExtension`
action; ${ext:...} is for value-producing reads. Parameter is named
ArgList (not Args) because $Args is a PowerShell automatic variable.

<a id="4213a0b3-016a"></a>

## test/modules/Test.ServiceCensus.psm1: The service census: what this host last knew about each managed service,

The service census: what this host last knew about each managed service,
which lifecycle operation an operator last asked for, and who may start or
stop a service right now.

Four things live here and nowhere else, all under the private state root
($HOME/.yuruna/host-refresh, never inside a served tree):

  * service-census.record -- one checksummed, generation-numbered record
    (Test.CriticalRecord) holding per-service evidence and the newest
    explicit start/stop intent. Written only under service-census.lock.
  * service-census.lock -- the short merge lock (rank CensusMerge). Never
    held while waiting for a longer lock, so it cannot deadlock a service
    operation.
  * service-operation.<key>.lock -- one per logical service (rank
    ServiceKey). Start and Stop scripts, the reboot sweep and the refresh
    worker all take it, in ordinal key order, before touching a service.
  * the capability table -- which uses of census evidence a platform has
    earned, as a pure declaration.

This module deliberately names no command that can raise an Apple Event,
query hypervisor state through the control channel, or start or stop a
guest: the beacon runs its tick every few seconds on a host whose control
channel may be the thing that is wedged, and one blocked call there would
stall the beacon's own announcements. Addresses come only from the
platform's passive resolver (Get-VMPassiveAddressContext,
Get-VMPassiveAddress, Get-PortMapTarget), resolved by name at call time,
and from files. A static scan of this file pins the rule.

Timestamps are authoritative as ...UnixMs numbers. Nothing here parses an
ISO string back for a decision: ConvertFrom-Json turns those into local
DateTime values, and a comparison of those drifts with the host's time zone
(feedback_datetime-compare-is-timezone-sensitive.md).

<a id="4213a0b3-016b"></a>

## test/modules/Test.SingleFlightLock.psm1: A held-open, never-unlinked, cross-process exclusive lock

A held-open, never-unlinked, cross-process exclusive lock. The handle IS
the mutex: a second Enter for the same path fails for as long as this
handle stays open, in this process or any other, and process death
releases it automatically through OS handle cleanup -- there is no PID
file to go stale and no unlink to race a concurrent stale-drainer against.

This is the same OpenOrCreate + FileShare.None shape the host-address
beacon already relies on for hostaddress.beacon.lock. .NET implements
FileShare.None with flock(LOCK_EX) on Unix, and any other open of the file
(even a read-only one) takes LOCK_SH, so it conflicts with the holder
across genuinely separate processes as a single-flight lock requires. An
environment switch (DOTNET_SYSTEM_IO_DISABLEFILELOCKING) turns that
locking off silently, so every acquisition verifies exclusion itself
before reporting the lock as held.

It is NOT copied from the caching-proxy lock (Test.CachingProxyServiceLock
.psm1): that lock closes its exclusive stream immediately after writing
the PID, publishes identity in a separate sidecar file, and drains a
suspected-stale holder by deleting files -- none of which is a lifetime OS
lock, and its 21600-second forced-age drain would let a live worker's lock
be stolen out from under it. This module holds one exclusive OS handle for
the caller's entire operation and never age-drains at all: only a caller
who can themselves acquire the lock (proving no one else holds it) may
clear stale metadata, via Clear-YurunaSingleFlightLock.

Ranks order nested acquisitions: the lifetime host-operation lock, then
service-key locks in ordinal path order, then at most one short lock
(admission, census merge, runner gate). A request that would wait for a
longer-lived lock while holding a shorter one is refused without touching
the disk, which is what keeps two processes from each holding the lock the
other waits for.

<a id="4213a0b3-016c"></a>

## test/modules/Test.SingleInstance.psm1: Stop-StaleRunner

The TREE, not the PID. A runner spawns its cycle process, that spawns the
inner, and every one of them inherits the terminal (they are started
-NoNewWindow). Killing only the runner leaves those children alive, holding
the console the NEW runner is about to write to -- and two processes on one
terminal is not a cosmetic problem: each side's cursor-position query
(ESC[6n) gets its reply consumed by the other, so the report text leaks into
the output as stray ";1R" and the side that asked fails the read. PowerShell
answers a failed console read with Environment.FailFast, which kills the
process outright. The orphaned inner also keeps driving VMs with nothing
supervising it.

TERM before KILL, and children before the parent: a parent killed first
re-parents its children to init and loses the group that would have reached
them. The grace period is what lets the old runner put the terminal back the
way it found it; the KILL sweep afterwards is for whatever ignored TERM.

<a id="4213a0b3-016d"></a>

## test/modules/Test.SingleInstance.psm1: Write-RunnerPidFile

Atomic-write contract for the pidfile + StartTime sidecar pair:
the reader must never see a pidfile without its sidecar, or it
falls back to cmdline regex on a stale identity and may
misattribute. Sequence:

  1. Compute startIso and write to a per-PID `.tmp` next to
     RunnerStartFile so a concurrent runner's tmp can't collide.
  2. CreateNew + FileShare.None on the pidfile -- this is the
     compare-and-set that decides the race.
  3. On win: Move-Item .tmp -> RunnerStartFile (atomic rename
     on same-volume NTFS / ext4 / APFS).
  4. On loss: delete the orphan .tmp and return $false; the
     caller treats this the same as Get-RunnerInstanceState
     returning 'OtherRunner'.

The only remaining unprotected window is between (2) and (3) --
~one rename syscall.

<a id="4213a0b3-016e"></a>

## test/modules/Test.Ssh.psm1: Addresses that ssh has actually authenticated to, per VM

Addresses that ssh has actually authenticated to, per VM. Global-anchored for
the same reason as the user overrides: the harness -Force re-imports this
module mid-cycle, and a memo wiped at that moment is a memo that is empty
exactly when a renumber is in progress.

This is the last word in address discovery, not the first. Every other source
is a report about the guest -- the agent's, the lease database's, the kernel
neighbor table's -- and each can decline. A proven address is different in
kind: ssh completed a key exchange with the guest there. That does not make it
current (the guest may have moved since), which is why it is consulted only
when every discovery rung has declined, where today the harness dials the bare
VM name and fails inside getaddrinfo.

<a id="4213a0b3-016f"></a>

## test/modules/Test.Ssh.psm1: Get-GuestAddress

Fallback path for standalone Test.Ssh use (no Yuruna.Host loaded),
so SSH-client users (Wait-SshReady / Invoke-GuestSsh) work even when
callers forget to call Initialize-YurunaHost first.

Deliberately only the CHEAP lookups, and therefore weaker than the
driver's Get-VMIp: a bridged UTM guest is invisible to both of them
(no agent, and the shared-NAT lease file cannot hold its lease) and
is found only by matching the bundle MAC in the host ARP table --
which needs an ICMP sweep, and is host-driver work this module has
no business duplicating. A caller that must resolve a bridged guest
has to have the driver in scope; without it the VM name is returned
and ssh's own resolution is the last route left.

<a id="4213a0b3-0170"></a>

## test/modules/Test.Ssh.psm1: Get-SshReadinessFailureCause

An address that never answered ANYTHING is a different fault from a live
address whose path broke, and the two send a reader to different machines.
A lease table can hold several addresses for one guest -- a rebuilt guest
takes a new one and the old rows stay until they expire -- so an address
can be discovered, unexpired, and belong to a machine that no longer
exists. This does not prove the discovery was stale rather than the path
broken; it says only that nothing ever replied on what was handed over,
which is the point at which the address's provenance is worth reading
before the network is.

<a id="4213a0b3-0171"></a>

## test/modules/Test.Ssh.psm1: Wait-SshReady

Failure path. Classify WHY before dumping diagnostics, so the dumps and
the operator guidance target the actual cause.
The whole dump is Verbose: readiness failure is soft (callers fall back to
the console rung and the cycle still passes), and the same multi-line block
repeats for every diagnostic capture on a guest whose sshd is unreachable.
The structured ssh_handshake_failed event below is the durable signal;
raise the log level when actually debugging a handshake.
Choose which probe's words the cause is read from instead of taking
whatever landed last: the final probe is frequently the one killed at the
deadline, and it then carries no verdict about the target at all.

<a id="4213a0b3-0172"></a>

## test/modules/Test.Ssh.psm1: Wait-SshReady

Surface the failure as a structured NDJSON event so an autonomous
remediator routes on `event=ssh_handshake_failed` without having to
regex-parse the Write-Warning stream. `cause` is the granular
discriminator (ip_not_discovered vs auth_denied vs connection_refused
...) whose remediations differ; `ipDiscovered` says whether the wait
ever saw a real address and `ipAnswered` whether anything replied at it.
lastError carries the final probe output;
attempts / timeout pin down whether the gate was time- or attempt-bounded.
An account the guest itself has expired is a credential fault, not a
transport one, and the two send a reader to different machines. Filing it
under the transport class buries the one line in the probe output that
names the repair behind advice to wait and try again, which cannot rotate
a password. Every other cause here is a wait that ran out of budget while
the caller falls back to the console rung, so those stay soft.

<a id="4213a0b3-0173"></a>

## test/modules/Test.Ssh.psm1: Invoke-GuestSsh

Get-GuestAddress answers with the VM name when nothing discovered an
address. That sentinel is truthy and shaped like a hostname, so on its own
it reaches ssh as a target and fails inside getaddrinfo -- a resolver error
naming nothing about the real fault, and one no guest-side change can fix.
Discovery misses are typically sub-second, so re-resolve on a bounded loop
rather than spending the step on a stale cache.

The Test-IpAddress clause carries the whole predicate: -VMName is
documented as accepting an address, and for such a caller the sentinel
comparison is true on a perfectly good address. Testing the shape as well
is what keeps that case out of the wait.

<a id="4213a0b3-0174"></a>

## test/modules/Test.Ssh.psm1: Invoke-GuestSsh

Detached mode changes what an attempt costs. A re-run gets the full
TimeoutSeconds because it starts the work over; an attach does not, because
the work has been running the whole time and the step's budget has been
draining with it. Giving each attach a fresh full budget would let a step
declared at 1800s occupy an hour and a half across three reconnects. So the
deadline is computed once here and every attach is bounded by what is left
of it, while the number of reconnects is bounded only by that deadline --
at a change every ten minutes, a fixed small retry count is the thing that
would run out first.

<a id="4213a0b3-0175"></a>

## test/modules/Test.Ssh.psm1: Invoke-GuestSsh

Let the guest reap what the dead session left behind before
dialing again. sshd only tears the old session down when its own
keepalive gives up, and until it does, the command from the
previous attempt is still running -- re-running now would put two
copies against the same apt/dpkg locks and turn a recoverable
blip into a new failure. The wait matches the guest-side
ClientAlive bound seeded in host/vmconfig/ubuntu.server.base.user-data,
plus margin. A guest from an image predating that seed reaps on
the kernel's TCP timeout instead, far outside any wait worth
spending here, which is the case -TransportRetryCount 0 exists for.

<a id="4213a0b3-0176"></a>

## test/modules/Test.Ssh.psm1: Invoke-GuestSsh

Process exit does not imply pipe EOF, and process-tree cleanup can
block inside the runtime. The shared helper bounds both independently.
ServerAliveInterval/CountMax are the only thing that ends a session
whose peer stopped answering: without application-level keepalives a
half-open connection holds the step until its own timeout, which on a
long provisioning step is most of an hour of a green-looking runner.
The 15s x 4 bound gives a full minute of silence before giving up, far
longer than any hiccup this is not meant to react to, and sshd answers
a keepalive regardless of what the remote command is doing -- so a
busy guest is never mistaken for an absent one. TCPKeepAlive stays on
as the second, kernel-level path to the same verdict.

<a id="4213a0b3-0177"></a>

## test/modules/Test.Ssh.psm1: Invoke-GuestSsh

No exit marker. The supervisor announces itself before it streams
anything, so a start or attach line with no exit line means the session
ended while the run was still live -- which is a lost transport by
construction, whatever ssh did or did not say about it. That inference
is available only here, and it is worth more than the wording: with
LogLevel=ERROR the client's own explanation is frequently absent, and
relying on it meant a step whose payload was mid-wait was reported as
the guest script failing.

Only the supervisor's own stream is classified when the marker is
missing too. Payload bytes arrive on stdout by the supervisor's
contract, so merging them in buries a one-line ssh message under
kilobytes of provisioning output -- and the empty-output rule that
catches a silent 255 can then never fire at all.

<a id="4213a0b3-0178"></a>

## test/modules/Test.Ssh.psm1: Resolve-GuestDiagnosticAddress

The portable rung, and the one that works on every host: ask the driver to
warm the host's neighbor cache, then re-run the ordinary lookup. Every
driver's address discovery includes a MAC-keyed read of that cache, so
warming it is exactly what turns a silent lookup into an answering one --
and both halves are contract verbs, so this needs no per-host branch.

This used to gate on a UTM-only function, which made the whole resolver a
no-op on the other two hosts: they returned '' unconditionally and the
second-chance probe built on top of this could never recover anything.

<a id="4213a0b3-0179"></a>

## test/modules/Test.Ssh.psm1: Wait-YurunaServiceVmDaemon

An empty answer is not a discovery that the guest has no address. The
wait keeps probing the last address it held -- including the one the
caller seeded from the hypervisor -- so forgetting it here would put
"no guest address discovered yet, so nothing has been probed" on screen
while a probe runs against a known address every poll. That is the same
unmeasured claim this wrapper exists to remove, merely inverted. It
would also make the line flip text on every poll whenever discovery is
intermittent, which is what floods a log. Only a NEW address replaces
the one in hand.

<a id="4213a0b3-017a"></a>

## test/modules/Test.Start-GuestOS.psm1: Generic dispatcher that runs a caller-supplied list of sequence names

Generic dispatcher that runs a caller-supplied list of sequence names
via Invoke-SequenceByName -- one entry point regardless of the guest
OS, in place of per-OS Test-Start.guest.*.ps1 extension scripts. The
cycle planner derives the list from project/test/test.runner.yml
and the per-sequence baseline fields.

Naming convention (by design):
    Module filename = "Test.<exported-cmdlet>.psm1"
This file exports exactly one cmdlet, `Start-GuestOS`, so the filename
is `Test.Start-GuestOS.psm1`. The hyphen makes the basename look like
a cmdlet -- that is the FEATURE: `grep -l Test.Start-GuestOS` finds
the single source file that defines the dashboard tile of the same
name, and the operator clicking through from the status UI lands on
the right file. If you're adding a sibling dispatcher (e.g.
Start-GuestRepair), follow the same shape: one exported cmdlet,
filename = "Test.<cmdlet>".

<a id="4213a0b3-017b"></a>

## test/modules/Test.Start-GuestOS.psm1: Start-GuestOS

Planner-cascaded variable overrides (Test.SequencePlanner ->
Invoke-Sequence). Forwarded to each Invoke-SequenceByName call
so the workload's `variables.username` override reaches the
baseline `start.*.yml` despite the baseline declaring its own
default value.
IDictionary (not [hashtable]) preserves the planner's
[ordered]@{} insertion order through parameter binding so
`${username}` resolves before `${currentPassword}` in the
downstream Invoke-Sequence expansion loop.

<a id="4213a0b3-017c"></a>

## test/modules/Test.Status.psm1: Reset-StatusDocumentForCycleStart

Prior status.json is unparseable -- preserve the corrupt
copy under a timestamped name so an operator (or remediator)
can diff it against the fresh doc instead of finding only
a silent counter reset. Stamp is millisecond-precision to
tolerate same-second rotations (write-write race against
the status service). Emit an NDJSON event into the current
cycle's ndjson so dashboards / autonomous remediators see
the gap explicitly instead of inferring it from a missing
history entry.

<a id="4213a0b3-017d"></a>

## test/modules/Test.Status.psm1: New-CycleHistoryEntry

Per-sequence rollup, parallel to guestSummary. The dashboard's Recent
Cycles table renders one button per sequence (the test.runner.yml
entries this cycle ran), each linking to that sequence's results
folder. Built from the cycle's ordered sequences[] joined to the
per-guest status + folder URL already gathered in $guestSummary. The
status rank mirrors the dashboard's aggregateStatus
(fail > running > pass > skipped > pending) so a sequence row's badge
matches the Latest Cycle sequence card. A 1:1 sequence links straight
to its guest's per-VM folder; a sequence that fans out to >1 guest
links to the cycle folder so every guest subfolder stays reachable.

<a id="4213a0b3-017e"></a>

## test/modules/Test.Status.psm1: New-CycleHistoryEntry

History entries carry their OWN gitCommits snapshot so a row
written months ago still links to the right framework + project
commits even if the runner has since picked up a new repo URL or
added/removed a project clone. The dashboard renders these as
comma-separated linked SHAs (framework first, project second).
cycleFolderUrl is snapshotted too so the history-row cycle-id
link survives even after the live $Doc rolls to the next cycle.
totalDurationSeconds is the cycle's wall-clock seconds; the dashboard
already derives this from startedAt/finishedAt on the fly, so the
field is additive -- its purpose is to let programmatic trend
analysis (jq / Python) read a number directly without re-parsing
ISO timestamps.

<a id="4213a0b3-017f"></a>

## test/modules/Test.Status.psm1: Write-StatusJson

Per-writer unique temp name: the runner and the status-service
process both flush status.json, so a shared fixed "$File.tmp"
lets one process's Move-Item rename the other's half-written temp.
A PID+GUID suffix keeps each writer's temp private; the rename to
the final path stays atomic. Suffix ends in .tmp so existing
*.tmp cleanup/ignore rules still match.
Atomic temp-write + rename via the shared primitive: guarantees no BOM
(Set-Content -Encoding utf8 emits one on PS5.1, and a leading BOM breaks
fetch().json() in the browser) and keeps the per-PID temp-name concurrency
safety in one place. -Compress:$false preserves the pretty-printed on-disk
shape; -Depth 10 matches the document nesting.

<a id="4213a0b3-0180"></a>

## test/modules/Test.Status.psm1: A Debug-TestSequence run either OWNS status.json (standalone, or the outermost

A Debug-TestSequence run either OWNS status.json (standalone, or the outermost
orchestration) or runs NESTED inside another run's process tree -- a
host-action step that re-enters Debug-TestSequence.ps1 in a child pwsh (e.g.
Set-Resource.ps1 fanning out per-stage guest builds). Exactly ONE process --
the outermost -- owns the top-level document (guests[]/sequences[]/history +
Reset/Initialize/Complete-Run). A nested run NEVER resets the doc: it attaches
a node into the `nested` map (nodeId -> node) and updates ONLY its own node.

Ownership is partitioned by JSON key: the owner authors everything EXCEPT
`nested`; a nested run authors ONLY `nested[<its id>]`. Both sides write the
whole file, so both run their read-modify-write under a shared status-file
lock (Enter/Exit-StatusLock) -- the owner re-reads `nested` before its flush
(Write-StatusJson, gated on $script:PreserveNested), and a nested writer
re-reads the whole doc before touching its node. Neither can lose the other's
section. The single "am I nested?" signal is the inherited
$env:YURUNA_CYCLE_CONTEXT handle; its absence == standalone owner.

<a id="4213a0b3-0181"></a>

## test/modules/Test.Status.psm1: Get-CycleContext

cycleStartUtc is published as text and comes back as a [DateTime]:
the JSON reader promotes anything ISO-8601-shaped. Casting that
object to [string] renders it in the process's current culture, so
the correlation key a nested run stamps on its events and status
nodes stops matching the one the owner wrote -- the two describe the
same instant in two different notations, and every join on them
silently returns nothing. Re-normalize at the single point the
coercion happens, so callers keep receiving the string they published.

<a id="4213a0b3-0182"></a>

## test/modules/Test.Tesseract.psm1: Invoke-TesseractOcr

--psm 6 is load-bearing: every neighboring page-segmentation mode
silently drops text on terminal screenshots. Full mode-by-mode
rationale: docs/ocr.md#why-tesseract-runs-at---psm-6

Capture stdout and stderr in a single pass. 2>&1 merges tesseract's
stderr (surfaced as ErrorRecord objects) into the success stream, so a
failure is diagnosable from THIS run's stderr -- re-running tesseract to
fetch stderr could diverge (the image may have changed or been deleted
between runs) and doubles the process spawn. $LASTEXITCODE survives the
variable assignment (no pipeline) and is snapshotted immediately.

$PSNativeCommandUseErrorActionPreference is pinned $false in this scope so
a non-zero tesseract exit reaches the explicit branch below instead of
throwing a bare NativeCommandExitException that bypasses the diagnostic
message (the preference defaults $false, but a caller or profile can enable
it under EAP=Stop; see feedback_winget_self_upgrade_kills_running_pwsh for
the guard class).

<a id="4213a0b3-0183"></a>

## test/modules/Test.Transport.psm1: Send-TextVNC

Empirically, UTM's QEMU VNC does NOT auto-shift from the keysym
alone (e.g. `asterisk` arrives as `8`, `bar` arrives as `\`), so we
must press LShift ourselves. 20ms down / 10ms up has tested clean
for the supported guests and is matched against Send-TextHyperV's
batched-scancode shift settle. If a future guest regresses, the
cycle log's "VNC text send: failed" warning is the trigger -- a
larger window (e.g. 80/40) is the conservative escape hatch.
Hoisted out of the try so the finally can always name $shiftSym.

<a id="4213a0b3-0184"></a>

## test/modules/Test.Transport.psm1: Send-TextVNC

Let go of whatever was still down. Reached when the loop is torn
down between a key's press and its release -- a mid-send transport
error, or an operator Ctrl-C (PowerShell runs finally on pipeline
stop too). Doing nothing here is what turns a one-character glitch
into a console that auto-repeats that character until the VM is
rebuilt. Best effort: if the socket is what broke, these writes
throw as well, and swallowing that keeps the original failure --
already reported above -- as the one the caller sees.

<a id="4213a0b3-0185"></a>

## test/modules/Test.Transport.psm1: UTM keystroke transport: AppleScript chords + JXA/CGEvent text

VNC (Connect-VNC + Send-TextVNC, the path UTM uses) does not work here.
Empirically, libvirt-managed QEMU on Ubuntu 24.04 accepts our TCP connect
and emits its 'RFB 003.008' greeting, then drops the connection
immediately after we write the client version -- before any auth or
security-types handshake. UTM's QEMU does not. Rather than chase the
libvirt-vs-standalone-QEMU handshake difference, KVM bypasses VNC entirely.
Text normally uses one bounded system-Python child and one libvirt connection;
a missing interpreter or Python binding permits the `virsh send-key` fallback.
A failed or interrupted libvirt send is never replayed. Both paths avoid the
VNC listen-address, port-discovery, and RFB-version moving parts.

The fallback `virsh send-key <domain> [keycode...]` accepts Linux input event
names (KEY_A, KEY_LEFTSHIFT, KEY_ENTER, ...) and sends them as one chord
(all pressed simultaneously, then released). Both text paths send one chord
per character; shifted characters become a 2-key chord. The preferred libvirt
path uses numeric PS2-Char / PS2-Named values; the fallback text and named-key
paths use KVM-Char / KVM-Named. These maps live in Test.KeyCodeRegistry.

<a id="4213a0b3-0186"></a>

## test/modules/Test.Transport.psm1: Send-KeyKvm

Chord map first (KVM-Chord), then the named map (KVM-Named). Anything in
neither passes through verbatim so a sequence can write KEY_LEFTMETA,
KEY_F2, etc. directly.

`virsh send-key` presses every positional keycode simultaneously and
releases them together, so a chord is just a multi-element argument
list -- it must be SPLATTED, not stringified, or the two names collapse
into one unrecognized argument.

<a id="4213a0b3-0187"></a>

## test/modules/Test.Transport.psm1: Send-TextHyperV

Post-batch settle: linear in char count up to a ceiling. The
PS/2 controller drains asynchronously, so without a wait the
next action (Enter, screenshot) can sample a half-typed field.
Formula: min($DefaultSettleMs, $CharDelayMs * $charCount).
$DefaultSettleMs (200 ms default) is the empirical ceiling that
covered every login-prompt drain measured on this hardware;
tune via test.config.yml's vmCommunication.settleMs for guests
that need more (slow agetty) or less (KVM/SeaBIOS, where the
buffer is faster).

<a id="4213a0b3-0188"></a>

## test/modules/Test.Transport.psm1: Send-TextUTM

Opt-in shell-side decoding. When set AND Text contains chars
that need Shift after the keypad remap (uppercase letters and
shifted punctuation other than '*' / '+'), rewrites Text as
a two-stage eval wrapper so the bash prompt on the guest
decodes the shifted chars from \xNN escapes. Default off: at
login/password prompts there is no shell to decode the wrapper,
so callers in those contexts (Send-Text via passwdPrompt) must
NOT pass this switch.

<a id="4213a0b3-0189"></a>

## test/modules/Test.VMUtility.psm1: Test.YurunaDir.psm1 owns $env:YURUNA_RUNTIME_DIR + Initialize-YurunaRuntimeDir;

Test.YurunaDir.psm1 owns $env:YURUNA_RUNTIME_DIR + Initialize-YurunaRuntimeDir;
import here so Get-PortMapStatePath can resolve the state file even when
a caller hasn't bootstrapped the full runner path. -Global so a caller
that already imported Test.YurunaDir into its own session keeps seeing
Initialize-YurunaRuntimeDir afterwards -- a -Force re-import without
-Global evicts the caller's binding into Test.VMUtility's private scope,
which is exactly what broke Start-StatusService.ps1 at "Initialize-
YurunaRuntimeDir is not recognized".

<a id="4213a0b3-018a"></a>

## test/modules/Test.VMUtility.psm1: Releasing a lease is an optimization and can always miss; the BOUND is what

Releasing a lease is an optimization and can always miss; the BOUND is what
decides whether a long lease is survivable. The bound says a guest asks for a
new address only when its identity is new -- so the way to test it is to
rebuild the same identity and see whether the same address comes back.

Observed, not configured, deliberately. A pin that is present and a pin the
server honors look identical from the guest's own files, and only one of them
bounds anything. This measures the outcome, which is the half that cannot be
faked by a correct-looking setting.

<a id="4213a0b3-018b"></a>

## test/modules/Test.VMUtility.psm1: Remove-GuestVMQuietly

Read the address BEFORE the release: a guest that has just handed its
lease back no longer has one to report, so asking afterwards would
measure nothing on exactly the guests that behaved correctly.

Keyed on the name the VM carries at TEARDOWN, which is the closest
identity available here and not quite the one the MAC is derived from
(that is the cloud-init hostname the sequence declares, which this
layer never sees). The approximation is safe in the direction that
matters: a guest built and promoted the same way each cycle ends at
the same name, so like is compared with like. Where a hostname is
shared across tiers of a chain, several names map onto one address and
each simply reads as bounded -- extra rows, no false alarm. Callers
that DO know the lifelong identity should pass it as -Identity.

<a id="4213a0b3-018c"></a>

## test/modules/Test.VMUtility.psm1: Update-StashServiceMarkerAddress

A candidate address has to be PROVEN before it is advertised. For the
first seconds of a freshly built VM's life the guest has not completed
DHCP, and macOS files every lease under the name the guest sends and
never prunes -- so the lease file still holds blocks filed under this
VM's name by the incarnations it replaced. Get-VMIp then hands back a
dead predecessor's address that is syntactically perfect, on-link, and
indistinguishable from a good answer. Taking the first non-empty reply
spends the whole poll budget on its first tick and publishes the
previous incarnation, which the dashboard's deep-link then points at
for the rest of the cycle.

/healthz answering is what separates the two, so the poll keeps going
until a candidate proves it is a stash service. The real address shows
up within seconds of its lease being issued.

<a id="4213a0b3-018d"></a>

## test/modules/Test.VMUtility.psm1: Update-StashServiceMarkerAddress

Only 'offsegment' refuses. 'unknown' (no route resolved, no mask
available) proves nothing and must not withdraw a working service, and
a lab whose stash genuinely lives on another routed subnet keeps its
pool registration through the daemon's own announce.

Resolved BEFORE anything is said about publishing an unconfirmed
address, because on an off-segment host nothing is published at all --
announcing that an address is being advertised unconfirmed, and then
withholding it two lines later, describes an outcome that never happens.

<a id="4213a0b3-018e"></a>

## test/modules/Test.VMUtility.psm1: Update-StashServiceMarkerAddress

Said once per time the host ENTERS this state, not once per refresh.
A stash on a hypervisor-private network is in this branch on every
refresh for the life of the VM -- on the per-cycle path that is a
warning every cycle, forever, about a condition that has not changed
and that the operator can do nothing about mid-run. Repeating it is
how a real warning becomes something people filter out.

The marker is where the memory lives, because the marker is already
this function's state file and nothing else survives between runs.
poolWithheld records the verdict; the entry into it is news, the
steady state after it is not.

<a id="4213a0b3-018f"></a>

## test/modules/Test.VMUtility.psm1: Update-StashServiceMarkerAddress

Said HERE, where the address really is about to be published, and only
about a publication that really happens -- the off-segment branch above
returns without publishing anything, so an unconfirmed notice there
would describe an outcome that never occurs.

Once per address, not once per refresh: publishing an address this host
could not confirm is worth flagging, and the per-cycle refresh re-runs
the same unconfirmed publish of the same address for as long as the
daemon takes to build. The address already being on the marker means
this was said when it was first published and nothing has changed since.

<a id="4213a0b3-0190"></a>

## test/modules/Test.VMUtility.psm1: Wait-YurunaServiceVmEndpoint

Not bound yet. Extend ONLY on evidence the guest is still
working: cloud-init `running` or `not started` permits an extension,
up to the configured hard deadline. `done` stops extending the deadline
but keeps waiting within the remaining budget for the daemon to bind;
other statuses do not extend it.
cloud-init ERROR is terminal, so stop rather than serve out
the budget. Nothing re-runs cloud-init on this boot: every
remaining poll asks a question already answered, and the
operator watches a progress bar for up to 45 more minutes
before being told what the guest knew at minute two. 'done'
deliberately keeps waiting -- the daemon can still be binding
its port in the seconds after cloud-init finishes.

<a id="4213a0b3-0191"></a>

## test/modules/Test.WarmResume.psm1: A checkpoint names the step that FAILED, and resuming there replays it against

A checkpoint names the step that FAILED, and resuming there replays it against
a guest that step may already have half-changed: an install that unpacked
before its network call died, a seed script that wrote some rows. The step is
eligible for resume because its FAILURE was transient, which says nothing
about how much of its work landed first. Replaying onto that residue is a
different run from the one the sequence describes.

loadDiskSnapshot is the one action that makes the guest's state known again,
so it is the only honest place to restart: rewind to the most recent one at or
before the checkpoint and every step after it runs against the state it was
written for. The cost is redoing the steps in between, which is the trade warm
resume already makes against a full cold rebuild.

No boundary at or before the checkpoint means there is nothing to restore to.
The checkpoint is used as-is only when the failed step merely observes.
A step that changes state, an unclassified step, or an unavailable safety
check declines warm resume instead of replaying onto the failed attempt's residue.

<a id="4213a0b3-0192"></a>

## test/modules/Test.WarmResume.psm1: Replaying the failed step in place puts a second run on top of whatever the

Replaying the failed step in place puts a second run on top of whatever the
first one left: a fetched script installed packages and initialized tool
state, typed text sits half-entered on a command line, a snapshot was saved.
Tools that are deliberately not idempotent (tofu refusing an already
initialized working directory is the canonical one) then fail on the residue
rather than on whatever stopped the original attempt, and THAT failure is
the one reported.

Which verbs can be replayed harmlessly is a fact about each verb, so each one
declares it where it registers (Register-SequenceAction -ReplaySafety) and
this module only reads it. A list kept here would name the verbs known when it
was written; a verb added later would default to "replay is fine". An
undeclared, unregistered or unreadable verb is 'unclassified' and counts as
unsafe: for a guard, "I could not tell" falls on the same side as "unsafe".

<a id="4213a0b3-0193"></a>

## test/modules/Test.YurunaDir.psm1: Get-YurunaHostId

Atomic first-write, shared with Get-PerfHostUuid on this same host.uuid: two
processes hitting first-use at once would each generate a DIFFERENT id, so a
plain overwrite would leave the host with two identities. The create itself is
the lock -- FileMode.CreateNew is O_CREAT|O_EXCL on POSIX and CREATE_NEW on
Windows, so exactly one caller can bring the path into existence and everyone
else adopts what that caller wrote. A temp-then-rename cannot hold this line on
POSIX: [System.IO.File]::Move tests for the destination and then renames, so
racers that pass the test together all rename successfully, the last one lands
on disk, and every earlier one walks away with an id that was never persisted.
A genuine persist failure is fatal to the caller (return $null, per the OUTPUTS
contract) rather than an unpersisted id the next call would silently
re-generate as a different one.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Back to [Yuruna](../README.md)
