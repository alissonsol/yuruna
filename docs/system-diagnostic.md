<a id="423ef7f5-0001"></a>

# Get-SystemDiagnostic -- design and per-section rationale

[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1)
is a read-only diagnostic dump invoked from the host (and pulled
through the status service during incident triage) when a Yuruna cycle
wedges or returns an empty cluster. It enumerates host facts, Docker
state, Kubernetes state, install-time evidence (Linux only), and a
"problems detected" summary aggregating signals that typically
indicate trouble.

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

**Motivating case:** the `subiquity/Network/_send_update: CHANGE
eth0` loop on `host/windows.hyper-v/` -- the discriminating signal
(RAs vs. apt mirror retries vs. `hv_netvsc` VF flap) only exists in
`/var/log/installer/subiquity-server-debug.log` and the previous
boot's journal, neither of which section 11 collects.

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

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.24

Back to [Yuruna](../README.md)
