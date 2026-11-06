<a id="423ef7f5-0001"></a>

# Get-SystemDiagnostic -- design and per-section rationale

[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1)
is a read-only diagnostic dump invoked from the host (and pulled
through the status service during incident triage) when a Yuruna cycle
wedges or returns an empty cluster. It enumerates host facts, Docker
state, Kubernetes state, install-time evidence (Linux only), and a
"problems detected" summary aggregating signals that typically
indicate trouble.

Besides incident triage, the runner runs it at the start of every
cycle, orchestrated cycles included, and keeps the dump as
`host.diagnostic.txt` (with its problem sidecar
`host.diagnostic.txt.json`) at the root of the cycle folder; the perf
log's `hostInfoHash` is computed from that file. A standalone
`Debug-TestSequence` run takes no cycle-start dump; when its guest chain
fails, it still takes the failure-time one, `host.diagnostics.txt` in the
guest's folder.

The script's help block (`.SYNOPSIS` / `.DESCRIPTION` / per-parameter
help) lists what each section reports. This document covers the
**why** -- the incident classes each section catches, and the patterns
the script uses to stay bounded when the underlying daemons are wedged.

> Side-effect-free: nothing is started, stopped, or modified.
> Implementation contracts live at
> [`yuruna.link/42fa6f45-0013`](https://yuruna.link/42fa6f45-0013).
> Per-incident triggers live at
> [`yuruna.link/42d69dfa-0029`](https://yuruna.link/42d69dfa-0029).

<a id="423ef7f5-0002"></a>

## Wedged-daemon protection

A wedged daemon (dockerd stuck in a syscall, kubectl blocked on an
unreachable apiserver, gcloud importing a broken bundled-python)
can consume the entire outer SSH / console wall budget if invoked
in-process. Three patterns keep `Get-SystemDiagnostic` bounded.

<a id="423ef7f5-0003"></a>

### Invoke-WithDeadline

Runs a scriptblock in a background job with `Wait-Job -Timeout`. On
timeout, returns `@{ TimedOut = $true; Output = $null; ExitCode = -1 }`.

- Captured variables must flow through `-ArgumentList`, NOT the
  scriptblock closure: `Start-Job` runs the block in a fresh
  runspace, so `$using:` / lexical scope are not honored.
- Child-process exit code only flows back if the scriptblock emits
  it explicitly (parent-scope `$LASTEXITCODE` is unrelated to the
  job's runspace); callers that care must include `$LASTEXITCODE`
  in their block's final pipeline and recover it from `$Output`.

<a id="423ef7f5-0004"></a>

### Per-tool request timeouts

Tool-level flags cap per-call waits **before** the wrapper budget
fires:

- `kubectl --request-timeout=5s` -- caps every apiserver round trip;
  without it a stale kubeconfig pointing at a torn-down VIP blocks
  for the full client default (~30 s) per probe and starves later
  sections of their wall budget.
- `docker --version` (local, no daemon round trip) instead of
  `docker version -f json` from `Yuruna.Requirement.yml` -- the
  JSON form hangs ~30 s when dockerd is unreachable.
- `docker info` invocations wrapped in `Invoke-WithDeadline -TimeoutSeconds 5`.
- `gcloud -v 2>$null` (NOT `2>&1`) so a broken bundled-python install
  produces "(not installed)" rather than dumping a Python traceback
  into the table.
- `kubectl version --client --request-timeout=5s` -- `--client`
  suppresses the apiserver round trip but kubectl still resolves
  kubeconfig; `--request-timeout` caps the fallback for unreachable
  clusters with broken contexts.

<a id="423ef7f5-0005"></a>

### Probe via proxy when egress is locked

When cloud-init has installed an HTTP egress lock + proxy env vars
(`https_proxy`, `http_proxy`), direct TCP/443 to public IPs is
typically REJECTed by the same egress firewall. Connectivity probes
detect the env-configured proxy and report end-to-end round-trip via
HTTP CONNECT (single TCP to proxy + tunnel-setup reply from the
upstream target). The reply timing approximates
`client -> proxy + proxy -> target` without a full TLS handshake,
which would skew the number with crypto cost.

The CONNECT matrix proves the tunnel path at most. Package managers
fetch their `http://` origins through the proxy's GET/cache path
(`http_proxy`), which wedges independently of CONNECT: a cache
revalidation can stall after response headers, where no connect or
read-gap timeout fires and the client hangs mid-body (the
stalled-transfer trap class). The diagnostic therefore also fetches a
small body END TO END per mirror origin with revalidation forced
(`Cache-Control: no-cache`), so the probe exercises the proxy's
upstream fetch instead of a cache hit. A healthy CONNECT column plus
failures on this probe isolates the wedge to the GET/cache path.

The object it fetches is the suite `InRelease` for the guest's own
`VERSION_CODENAME` -- the exact URL apt blocks on -- not a `dists/`
directory index. An index is small and rarely revalidated, so a cache
answers it in single-digit milliseconds while the `InRelease` beside it
stalls; probing the index reports the path healthy during the outage
this probe exists to catch. Guests with no codename (non-Ubuntu) fall
back to the index and the output says so.

Two things are reported that a plain pass/fail would hide. Squid's
`X-Cache` header is printed when present: a HIT means the upstream was
never contacted, so the timing is not evidence about origin health.
And a fetch that succeeds but takes longer than 5 s is flagged `SLOW`
and raises a problem -- apt blocks on these fetches, so an origin
answering in tens of seconds exhausts a step's timeout exactly as an
unreachable one does.

<a id="423ef7f5-0006"></a>

### Container-registry route

The OCI counterpart of the package-mirror probe above, and for the same reason:
image pulls leave through a different door than apt does, and a cache can be
healthy on one while unusable on the other.

This earns its own probe because the obvious check is blind here.
`GET /v2/` is answered out of the registry's own process and comes back in
single-digit milliseconds no matter how badly the pull-through behind it is
stalled; a MANIFEST request is what re-runs the upstream sync, so it is the only
request shaped like the pull it stands in for. A tag, not a digest -- digests are
immutable and answered locally, so they stay fast through an outage. The
`Accept:` header is spelled out because a registry answers a manifest
request that states no preference with whatever it considers the default, which
for a multi-arch tag is not the index a pull resolves.

Both probes are sent with `-NoProxy`: the runtime pulls straight at the cache, so
a probe routed through the proxy would time a path no pull takes -- and the proxy
refuses CONNECT to this port anyway, which would read as a dead cache.

The cap is deliberately below the patience a container runtime shows. This
capture runs inside a per-command SSH budget during an incident, so it answers
"did the cache answer promptly" and leaves the magnitude of a stall to the
cache's own canary, which has no such constraint. Anything past ~3 s is already
evidence the upstream leg is being walked, since a warm cache answers in well
under a second.

For the manifest reading itself the diagnostic prefers the cache's own published
`/cache-health` page over measuring directly -- and not to save a few seconds. A
manifest request walks the upstream sync, which spends one pull from a
per-egress-IP budget the whole lab shares and exhausts routinely. This capture
runs several times per cycle per machine, so measuring directly every time would
make the diagnostic a meaningful consumer of the very resource whose exhaustion
it exists to detect. The cache probes itself on a cadence that budgets for it and
publishes the result; reading that costs nothing. The reading's timestamp is
printed alongside, because a reading minutes old is still evidence but not
a live one. See the [zot manifest canary
exporter](vmconfig.md#zot-manifest-canary-exporter) for the publishing side.

<a id="423ef7f5-0007"></a>

## Section-by-section rationale

<a id="423ef7f5-0008"></a>

### 1. HOST — software-probe resilience

Probes follow [`automation/Yuruna.Requirement.yml`](../automation/Yuruna.Requirement.yml)
plus tools common in the codebase (>10 mentions) but absent from the
YAML: `git`, `python3`, `node`/`npm`, `containerd`, `curl`,
`tesseract`, `qemu-img`. Each entry is resilient to the tool being
absent OR present-but-broken (e.g. Windows App Execution Alias for
`python3` that resolves via `Get-Command` but refuses to execute) --
a failure renders as `"(not installed)"` rather than aborting the
whole HOST section.

<a id="423ef7f5-0009"></a>

### 11. HOST DETAIL — runner process tree

On a stuck cycle, the process tree is the most actionable artifact
in the dump: it shows the runner pwsh's descendants (`ssh.exe`,
`virsh`, `vmconnect`, ...) so the operator can tell whether the
inner is wedged on a specific child versus spinning on its own
logic.

- Reads the inner pwsh pid from
  `$env:YURUNA_RUNTIME_DIR/inner.pid`, falling back to `runner.pid`
  (outer's pid) if the inner isn't running.
- Walks descendants iteratively with a visited set so a process
  recycling its parent's pid can't loop the walker.
- When invoked outside a runner cycle, `$env:YURUNA_RUNTIME_DIR` is
  derived from the script location (the status service publishes its
  own copy of the env var to its child pwsh).

<a id="423ef7f5-000a"></a>

#### `ps -ww` is mandatory on macOS / Linux

`/bin/ps` defaults to truncating the cmd column to the terminal
width on BSD-style invocations, and `-axo args=` inherits that
truncation. Without `-ww` the long `pwsh -File ... -EncodedCommand
...` lines that identify the wedged child get cut. Tab-separated
columns then avoid counting spaces in the cmd field. ETIME
(wall-clock since process start, in `[[dd-]hh:]mm:ss`) is left as
the raw string for human readability.

Related: the `bsd_ps_args_truncation` trap class.

<a id="423ef7f5-0013"></a>

#### Process subtree walk (breadth-first, bounded)

`Get-ProcessDescendantPid` walks a process subtree breadth-first -- the
root, then every descendant, in discovery order. The process a Linux
package manager is blocked on is generally not the one whose name matched:
`apt-get` forks `sh -c`, which forks the tool that actually owns the
blocking read, so a capture that stops at direct children names the shell
and never the leaf holding the file descriptor -- and that leaf is the
whole point of the capture. The walk is bounded two ways so a fork-storm
cannot turn one section into an unbounded `ps` walk: `MaxPids` caps the
total processes visited, and only pids reached through the walk's own
queue are visited, so a cycle in a doctored ppid chain still terminates.

<a id="423ef7f5-000b"></a>

### 11b. INSTALL & EARLY-BOOT TIMELINE (Linux)

Captures evidence the runtime-state sections cannot: what the
autoinstall shipped, how subiquity/curtin progressed,
whether cloud-init / systemd-networkd hit retries, and what the
install boot's journal looked like.

On a pre-login installer failure, the failure-capture path attempts the guest
diagnostic before teardown and writes its availability manifest beside the
screen evidence. These files require a reachable guest SSH or console shell;
the live installer may offer neither. In that case the OCR stage and host-side
network evidence are the available observations, and the manifest records why
guest logs could not be collected.

**Motivating case:** the `subiquity/Network/_send_update: CHANGE
eth0` loop on `host/windows.hyper-v/` -- the discriminating signal
(RAs vs. apt mirror retries vs. `hv_netvsc` VF flap) only exists in
`/var/log/installer/subiquity-server-debug.log` and the previous
boot's journal, neither of which section 11 collects.

Beside systemd-networkd's journal, the section prints the current boot's
NetworkManager `dhcp4` lines, which carry the leases of a bridge
NetworkManager built:
`journalctl -b 0 -u NetworkManager --grep dhcp4 -n 100 --no-pager`. The
DHCP4 lines under NETWORK show only the lease held now, its length and its
expiry; these show what became of each lease during the boot: granted,
extended at a renewal, or replaced after it ran out. That is the record a
host that takes a new address at every lease expiry needs, and the
address-stability report's lease-expiry advice
([network.md](network.md#4220a755-0026)) points to it.

<a id="423ef7f5-000c"></a>

### 11c. LIBVIRT GUEST NETWORKS

Where libvirt runs the guest network, the host **is** the DHCP server
its guests talk to, and nothing else in this capture describes that
service: the interface, route and socket dumps cover the host's own
addressing. Without this section a guest that came up with no lease is
a failure whose server side was never recorded -- it is destroyed at
cleanup minutes later, and the lease table and dnsmasq window are the
only surviving copies of what the server saw.

Collects, per host: the domains, each running domain's NIC MAC and
bridge (unresolvable once the domain is undefined), each network's
bridge, forward mode and DHCP range, its lease table, and the last 30
minutes of dnsmasq transactions.

Read-only by construction -- a section that could define, start or
destroy a network could cause the outage it was run to explain. It
retries through the non-interactive sudo prefix when `virsh` cannot
reach `qemu:///system`, because an account outside the `libvirt` group
must not be reported as a host without libvirt: that is the wrong
answer AND the one that stops the reader from looking.

Per-guest evidence with a window pinned to one boot lands separately,
beside the failure diagnostics; see
[Reading the DHCP server a libvirt host runs](https://yuruna.link/4220a755-000e).

<a id="423ef7f5-000d"></a>

### Journal windows exclude this harness's own polling

Both journal windows -- the error list in RECENT SYSTEM EVENTS and the
`journalctl -xe` tail in HOST DETAIL -- are finite, and the harness
writes to the journal on a timer whenever a cycle is running: an
apparmor profile reload per console frame captured, a libvirt
guest-agent error per guest address lookup on an image that ships no
agent, a compile record per child `pwsh`, an IPC-listener record per
`pwsh` teardown. Unfiltered, a 100-line tail of a busy host is entirely
that bookkeeping and every line a reader came for aged out of it
minutes earlier; the same lines counted as errors report a permanent
problem no operator can act on.

So the `-xe` window reads four times what it prints, drops those
classes, prints the last 100 of what survives, and states how many
lines of each class it removed. The error section prints every line it
was given -- suppression is never for hiding what the journal said --
but counts only the entries the harness did not write when deciding
whether to raise a problem.

apparmor is matched on `STATUS` only. A profile load is bookkeeping; a
`DENIED` line is a fault, and is exactly what a reader of this section
is looking for.

<a id="423ef7f5-0015"></a>

### Failed units with their own reason

The error list names a failed unit only through systemd's own
`Failed to start` line. The reason is usually what the unit's process
printed, and the journal keeps a service's stdout and stderr at info
priority, below the error list's cut. A guest whose sshd had lost its
host keys showed six `Failed to start ssh.service` errors per boot and
never `sshd: no hostkeys available -- exiting.`, so the guest's own
evidence did not explain why every SSH path to it was closed.

RECENT SYSTEM EVENTS therefore prints `systemctl --failed` and, for
each failed unit, the newest 10 journal lines of the current boot at
every priority -- what `systemctl status` shows, without its pager or
terminal width. At most 8 units are read, so a guest with many failures
cannot crowd the rest of the capture out of a console-sized budget.
Nothing here raises a problem: the list is evidence for whichever
failure asked for the capture.

<a id="423ef7f5-000e"></a>

### 13. GAP HEURISTICS

Cross-section sanity checks. Each catches a silent-failure mode
where one phase wrote its artifacts but a downstream phase produced
nothing -- the kind of incident where every section above looks fine
in isolation but the cluster ended up empty.

Runs AFTER YURUNA PROJECT so it shares the same `projectRoot`
resolution; also re-queries `helm` / `kubectl` read-only so a stale
variable from the KUBE section doesn't mislead.

<a id="423ef7f5-000f"></a>

#### Heuristic 1: tofu state without helm releases

If `Set-Resource` (tofu) wrote state, the project intends to deploy
something; if the matching workloads phase didn't produce a single
helm release across **all** namespaces, the wrapper script most
likely exited 0 without invoking `Set-Workload` (or `Set-Workload`
silently short-circuited).

<a id="423ef7f5-0010"></a>

#### Heuristic 2: declared namespaces missing from cluster

`globalVariables.namespace` is the canonical Helm / kubectl target.
If it's declared in any `resources.output.yml` but `kubectl get ns`
doesn't list it, the workloads phase never ran `kubectl create
namespace` (or it ran but errored). Same class of silent failure
as heuristic 1, but works even on projects that don't use helm.

A cheap regex matches the two-space-indented `namespace:` key under
`globalVariables:` rather than pulling in `powershell-yaml` for one
field.

<a id="423ef7f5-0011"></a>

#### Heuristic 3: cluster Ready but no user-namespace pods

Same shape as 1+2 but needs no project context, so it
catches a deploy-nothing-at-all failure even when
`resources.output.yml` and `tofu.tfstate` are both missing. A fresh
kubeadm cluster only ships `kube-system` + `kube-flannel` +
`kube-public` + `kube-node-lease`; anything outside that set is
"user content" that should appear once `Set-Workload` /
`Set-Component` land.

<a id="423ef7f5-0012"></a>

#### Heuristic 4: local registry image not referenced by any pod

If `Set-Component` pushed an image to the `localhost:5000` registry
and nothing in the cluster is pulling it, either the workloads
phase didn't run (covered by 1/3) or it ran but the chart's image
ref doesn't match what was pushed (e.g. `registryLocation` rendered
empty -- the "InvalidImageName" failure mode the chart template's
`required` guardrail catches). Either way, surfacing the mismatch
narrows the diagnosis.

Pod image refs against `localhost:5000` take the form
`localhost:5000/<repo>:<tag>` or sometimes
`<host>:5000/<repo>:<tag>` if the chart was rendered with a
non-localhost `registryLocation`. The orphan check matches on the
`/<repo>:` substring so both shapes resolve.

<a id="423ef7f5-0016"></a>

## Crash evidence on a Linux host

A KVM host whose operating system froze is diagnosed after it restarts, from
what the test runner's account can read. That account usually has no
passwordless sudo, so every privileged probe in this report runs unelevated
there. These parts of the report keep the evidence a freeze leaves within that
account's reach, and say plainly when it is out of reach.

<a id="423ef7f5-0017"></a>

### System journal access

On Linux, RECENT SYSTEM EVENTS starts by asking `journalctl --system` for one
entry. journalctl exits non-zero when it can open no system journal file, an
answer that holds whatever groups a distribution grants access to. Without
access, journalctl answers every query from the account's own user journal and
reports no error: the journal sections come back short or empty, and
`journalctl --list-boots` shows a single boot. The report then names the
account, journalctl's reason and the fix, membership in `systemd-journal`,
which takes effect only in a new login session. When the group database
already lists the membership, the report says this process started before it
instead.

[`host/ubuntu.kvm/Enable-TestAutomation.ps1`](../host/ubuntu.kvm/Enable-TestAutomation.ps1)
adds the runner account to `systemd-journal`.
[`Disable-TestAutomation.ps1`](../host/ubuntu.kvm/Disable-TestAutomation.ps1)
removes that membership only when the pre-automation capture shows the account
was not a member before; a capture with no record of the group leaves it as it
is.

<a id="423ef7f5-0018"></a>

### Kernel log when dmesg is restricted

`kernel.dmesg_restrict` closes the kernel ring buffer to an unprivileged
account. The system journal keeps the same kernel records and opens them to its
readers, so when dmesg is refused the ring-buffer tail and the OOM and
hardware-error scans read the current boot's kernel journal instead:
`journalctl -k -b 0`, its newest 5000 entries, with `-q` so that journalctl's own
notices are never scanned as kernel records. The report says which source
answered, and a problem found in the journal keeps the class it has when dmesg
answers (`LINUX.oom-events`, `LINUX.hardware-errors`).

Whichever source answers, the hardware-error scan counts these error reports: an
`I/O error`, a `Hardware Error` (the `[Hardware Error]` prefix of a logged
machine check or of an APEI or boot-error record, or a SCSI sense key), and an
EDAC memory controller's count of corrected (`CE`) or uncorrected (`UE`)
errors. The banners every boot prints, such as `EDAC MC: Ver: 3.0.0` and
`MCE: In-kernel MCE decoding enabled.`, and an `edac` inside a device name or
UUID raise nothing.

<a id="423ef7f5-0019"></a>

### Machine identity and microcode

On Linux the BIOS section prints the DMI fields the kernel publishes
world-readable under `/sys/class/dmi/id` (system, board and BIOS vendor, name
and version, BIOS date and release) in a fixed order, rendered as the Windows
BIOS rows are, followed by the CPU microcode revision from `/proc/cpuinfo`, with
every distinct revision listed when the CPUs disagree. These tie a freeze on one
host to the same board or firmware build on another. Serial numbers and UUIDs
identify a single machine and are never read.

<a id="423ef7f5-001a"></a>

### Lockup and crash-evidence settings

HOST DETAIL lists the settings that decide what a frozen or hung kernel leaves
behind: `kernel.watchdog`, `kernel.nmi_watchdog`, `kernel.softlockup_panic`,
`kernel.hardlockup_panic`, `kernel.panic`, `kernel.panic_on_oops`,
`kernel.hung_task_timeout_secs`, `kernel.hung_task_panic` and `kernel.printk`,
the pstore backend, each hardware watchdog device with its timeout, systemd's
`RuntimeWatchdogUSec`, journald's `Storage=` (the last valid assignment in the
files `systemd-analyze cat-config systemd/journald.conf` prints), and whether
`/var/log/journal` exists. The journal of the boot that froze survives the
restart only when `Storage=` is `persistent`, or `auto` (the default) with that
directory present; `volatile` and `none` keep nothing on disk even where the
directory exists. Every value is world-readable, so the view does not depend on
sudo, and a setting this kernel does not have reads `(not reported)`, as does
`Storage=` when systemd-analyze does not answer. `RuntimeWatchdogUSec` is asked
with a 5-second cap, because PID 1 answers it and may not on a host in trouble.

<a id="423ef7f5-001b"></a>

### Deep diagnostics mode

A host switched into deep diagnostics mode records what was applied in
`/var/lib/yuruna/deep-diagnostics/state.json`. HOST DETAIL prints when the mode
was enabled, then the schema, who enabled it, the host type, the netconsole
target where a freeze's last kernel lines went, and each component's status and
reason, every field named by its path in the document and shown as its JSON
value. Fields the report does not know are left out. A file that is not a
regular file of at most 64 KiB, is not JSON, or does not hold a JSON object is
reported, and nothing in it is shown.

<a id="423ef7f5-0014"></a>

## Guest evidence across CPU restarts and stalls

The Linux snapshot and execution recorder enumerate threads before sorting by
CPU usage. This avoids procps suppressing worker threads when `ps -eLo` is
combined with its own `--sort`. Each selected runnable, blocked, or CPU-heavy
thread includes its raw task accounting, scheduler statistics, wait channel,
and accessible stack. Memory pressure, VM counters, and cgroup memory events
help distinguish CPU stalls from reclaim or OOM failures.

Ubuntu Server 26 sequences on native ARM64 Hyper-V capture two clock samples
before the one-to-two CPU restart and after the existing SSH readiness or
console-login step. The ten-second SSH budget uses an already proven address
and allows for authentication, the one-second interval between samples, and
transport cleanup. Both samples precede optional boot metadata; a timeout
retains any completed samples and remains advisory. Samples include boot ID,
UTC, BOOTTIME uptime, monotonic time when Python is available, tick rate, online
CPUs, and raw per-CPU `/proc/stat`.
Clock-only captures retain timestamped uptime, CPU accounting, interrupts,
and softirqs before optional Python clock reads. Readable kernel files are
read directly so privilege setup cannot consume that early evidence budget.
Host samples bracket the processor change with UTC, performance-counter ticks,
and bounded Hyper-V processor and VM context. Analysis flags impossible
accounting, counter decreases, incomplete samples, and clock discontinuities.
Counters from different boot IDs are never subtracted; Linux iowait decreases
are permitted. Timestamped process samples collect `/proc/interrupts` and
`/proc/softirqs` immediately after `/proc/stat`, before larger memory and stack
reads can consume the collection budget. Retained samples allow per-CPU
interrupt and softirq progress to be compared within the same boot. Warnings
record evidence and do not change the workload result or authorize a restart.

Provenance is collected from the guest itself: owned Git HEAD or validated
archive `.yuruna-revision`, fixed helper and Dockerfile hashes, installed helper
hashes, and separate downloaded/executed payload hashes. Missing, invalid,
unsafe, or oversized sources have explicit states. No remote URLs or source
contents are included. Stable boot metadata and provenance are collected once
per execution and retained outside the rolling process samples.

The execution recorder also retains bounded TCP socket tables, socket usage,
and TCP counters alongside addresses, routes, neighbor state, and interface
counters before uploading evidence. These passive readings can retain a
connection attempt or retransmissions that later connectivity probes miss.
The existing sample deadline, byte cap, and ring size still bound collection.

A separate kernel collector starts with the execution recorder and uploads
through the host's existing HTTP diagnostic endpoint without SSH. It keeps
four 32 KiB samples, reads up to 256 journal lines per sample, polls every five
seconds, and posts only changed evidence plus the cached process ring.
An unchanged-data heartbeat is uploaded every
60 seconds, and failed uploads are retried. Kernel collection
has a two-second deadline and HTTP a six-second deadline, each with a
one-second kill grace. Both recorders stop with their owner or after two hours;
credentials are redacted before retention. Disable only the kernel stream with
`EXEC_KERNEL_RECORDER=0`; the existing execution-recorder controls still apply.
No guest uploader can run through a complete kernel stall, so the last upload
and the host-side observations remain essential.

The first observed RCU stall, missed RCU timer wakeup, or watchdog lockup is
also retained outside the rotating kernel ring in `kernel.first-stall.txt`.
Its first redacted sample and one following sample preserve the initial report
and stacks that finish printing after that first read. Each sample keeps the
same 32 KiB cap and two-second collection deadline; the additional upload
section is capped at 68,000 bytes. The existing
`execution.system.diagnostic.<step>.txt` artifact includes this under
`--- first observed kernel stall ---`, with the step and sequence identities,
`kernelFirstStallAdvisoryOnly=true`, and explicit sample exit codes and
truncation flags. `kernelFirstStallUtc` and `kernelFirstStallFollowupUtc` are
capture times; the journal lines retain their kernel monotonic timestamps.
These timestamps do not prove when the triggering defect began. A report or
stack exceeding the collection bounds can still be incomplete. Each sample is
the newest 256 kernel records of the boot, so a first stall frozen from the
recorder's first sample can be a report from before the step. The host reads
this section with the parser it applies to the Hyper-V serial console and keeps
the reading as `kernelStall` in the step's recorder evidence and as
`guestKernelFault.recorder` in a [failure record](failure-schema.md#42820e91-0006),
marked `mayPredateStep` when it came from that first sample.
This evidence does not change the all-processor livelock predicate or permit
automatic reset.

New Ubuntu and Amazon Linux seeds keep the journal across boots with 32 MiB
disk and 8 MiB runtime caps, a 256 MiB free-space reserve, and 30-second sync.
They do not forward kernel output onto the OCR console. With
`testCycle.stopOnFailure: true`, the runner writes a durable
`runtime/diagnostic-preserve.json` before failure capture, and pauses before
recovery, refresh, or another VM dispatch. Runner shutdown preserves the hold.
Remove this marker from the configured runtime directory or explicitly set
`stopOnFailure: false` to release it. Once guest access returns, inspect the
prior kernel boot with `sudo journalctl -k -b -1`; the newest unsynced journal
entries may be lost on a hard power-off.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.11.05

Back to [Yuruna](../README.md)
