# Get-SystemDiagnostic — design and per-section rationale

[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1)
is a read-only diagnostic dump invoked from the host (and pulled
through the status server during incident triage) when a Yuruna cycle
wedges or returns an empty cluster. It enumerates host facts, Docker
state, Kubernetes state, install-time evidence (Linux only), and a
"problems detected" summary aggregating signals that typically
indicate trouble.

The script's help block (`.SYNOPSIS` / `.DESCRIPTION` / per-parameter
help) lists what each section reports. This document covers the
**why** — the incident classes each section was added to catch, and
the patterns the script uses to stay bounded when the underlying
daemons are wedged.

> Side-effect-free: nothing is started, stopped, or modified.
> Implementation contracts live at
> [`yuruna.link/definition#defining-get-systemdiagnostic`](https://yuruna.link/definition#defining-get-systemdiagnostic).
> Per-incident triggers live at
> [`yuruna.link/memory#system-diagnostics`](https://yuruna.link/memory#system-diagnostics).

## Wedged-daemon protection

A wedged daemon (dockerd stuck in a syscall, kubectl blocked on an
unreachable apiserver, gcloud importing a broken bundled-python)
can consume the entire outer SSH / console wall budget if invoked
in-process. Three patterns keep `Get-SystemDiagnostic` bounded.

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

### Per-tool request timeouts

Tool-level flags cap per-call waits **before** the wrapper budget
fires:

- `kubectl --request-timeout=5s` — caps every apiserver roundtrip;
  without it a stale kubeconfig pointing at a torn-down VIP blocks
  for the full client default (~30 s) per probe and starves later
  sections of their wall budget.
- `docker --version` (local, no daemon roundtrip) instead of
  `docker version -f json` from `Yuruna.Requirement.yml` — the
  JSON form hangs ~30 s when dockerd is unreachable.
- `docker info` invocations wrapped in `Invoke-WithDeadline -TimeoutSeconds 5`.
- `gcloud -v 2>$null` (NOT `2>&1`) so a broken bundled-python install
  produces "(not installed)" rather than dumping a Python traceback
  into the table.
- `kubectl version --client --request-timeout=5s` — `--client`
  suppresses the apiserver roundtrip but kubectl still resolves
  kubeconfig; `--request-timeout` caps the fallback for unreachable
  clusters with broken contexts.

### Probe via proxy when egress is locked

When cloud-init has installed an HTTP egress lock + proxy env vars
(`https_proxy`, `http_proxy`), direct TCP/443 to public IPs is
typically REJECTed by the same egress firewall. Connectivity probes
detect the env-configured proxy and report end-to-end round-trip via
HTTP CONNECT (single TCP to proxy + tunnel-setup reply from the
upstream target). The reply timing approximates
`client → proxy + proxy → target` without doing a full TLS
handshake, which would skew the number with crypto cost.

The CONNECT matrix proves the tunnel path at most. Package managers
fetch their `http://` origins through the proxy's GET/cache path
(`http_proxy`), which wedges independently of CONNECT: a cache
revalidation can stall after response headers, where no connect or
read-gap timeout fires and the client hangs mid-body (the
stalled-transfer trap class). The diagnostic therefore also fetches a
small body END TO END per mirror origin, with revalidation forced
(`Cache-Control: no-cache`) so the probe exercises the proxy's
upstream fetch instead of a cache hit. A healthy CONNECT column plus
failures on this probe isolates the wedge to the GET/cache path.

## Section-by-section rationale

### 1. HOST — software-probe resilience

Probes follow [`automation/Yuruna.Requirement.yml`](../automation/Yuruna.Requirement.yml)
plus tools that show up in the codebase (>10 mentions) but aren't in
the YAML: `git`, `python3`, `node`/`npm`, `containerd`, `curl`,
`tesseract`, `qemu-img`. Each entry is resilient to the tool being
absent OR present-but-broken (e.g. Windows App Execution Alias for
`python3` that resolves via `Get-Command` but refuses to execute) —
a failure renders as `"(not installed)"` rather than aborting the
whole HOST section.

### 11. HOST DETAIL — runner process tree

On a stuck cycle, the process tree is the most actionable artifact
in the dump: it shows the runner pwsh's descendants (`ssh.exe`,
`virsh`, `vmconnect`, ...) so the operator can tell whether the
inner is wedged on a specific child versus spinning on its own
logic.

- Reads the inner pwsh pid from
  `$env:YURUNA_RUNTIME_DIR/inner.pid`, falling back to `runner.pid`
  (outer's pid) if the inner isn't currently running.
- Walks descendants iteratively with a visited set so a process
  recycling its parent's pid can't loop the walker.
- When invoked outside a runner cycle, `$env:YURUNA_RUNTIME_DIR` is
  derived from the script location (the status server publishes its
  own copy of the env var to its child pwsh).

#### `ps -ww` is mandatory on macOS / Linux

`/bin/ps` defaults to truncating the cmd column to the terminal
width on BSD-style invocations, and `-axo args=` inherits that
truncation. Without `-ww` the long `pwsh -File ... -EncodedCommand
...` lines that identify the wedged child get cut. Tab-separated
columns then avoid having to count spaces in the cmd field. ETIME
(wall-clock since process start, in `[[dd-]hh:]mm:ss`) is left as
the raw string for human readability.

Related: the `bsd_ps_args_truncation` trap class.

### 11b. INSTALL & EARLY-BOOT TIMELINE (Linux)

Captures evidence the runtime-state sections cannot: what the
autoinstall actually shipped, how subiquity/curtin progressed,
whether cloud-init / systemd-networkd hit retries, and what the
install boot's journal looked like.

**Motivating case:** the `subiquity/Network/_send_update: CHANGE
eth0` loop on `host/windows.hyper-v/` — the discriminating signal
(RAs vs. apt mirror retries vs. `hv_netvsc` VF flap) only exists in
`/var/log/installer/subiquity-server-debug.log` and the previous
boot's journal, neither of which section 11 collects.

### 13. GAP HEURISTICS

Cross-section sanity checks. Each one catches a documented
silent-failure mode where one phase wrote its artifacts but a
downstream phase produced nothing — the kind of incident where
every section above looks fine in isolation but the cluster ended
up empty.

Runs AFTER YURUNA PROJECT so it shares the same `projectRoot`
resolution; also re-queries `helm` / `kubectl` read-only so a stale
variable from the KUBE section doesn't mislead.

#### Heuristic 1: tofu state without helm releases

If `Set-Resource` (tofu) wrote state, the project intends to deploy
something; if the matching workloads phase didn't produce a single
helm release across **all** namespaces, the wrapper script most
likely exited 0 without invoking `Set-Workload` (or `Set-Workload`
silently short-circuited).

#### Heuristic 2: declared namespaces missing from cluster

`globalVariables.namespace` is the canonical Helm / kubectl target.
If it's declared in any `resources.output.yml` but `kubectl get ns`
doesn't list it, the workloads phase never ran `kubectl create
namespace` (or it ran but errored). Same class of silent failure
as heuristic 1, but works even on projects that don't use helm.

A cheap regex matches the two-space-indented `namespace:` key under
`globalVariables:` rather than pulling in `powershell-yaml` for one
field.

#### Heuristic 3: cluster Ready but no user-namespace pods

Same shape as 1+2 but doesn't need any project context, so it
catches a deploy-nothing-at-all failure even when
`resources.output.yml` and `tofu.tfstate` are both missing. A fresh
kubeadm cluster only ships `kube-system` + `kube-flannel` +
`kube-public` + `kube-node-lease`; anything outside that set is
"user content" that should appear once `Set-Workload` /
`Set-Component` land.

#### Heuristic 4: local registry image not referenced by any pod

If `Set-Component` pushed an image to the `localhost:5000` registry
and nothing in the cluster is pulling it, either the workloads
phase didn't run (covered by 1/3) or it ran but the chart's image
ref doesn't match what was pushed (e.g. `registryLocation` rendered
empty — the "InvalidImageName" failure mode the chart template's
`required` guardrail was added to catch). Either way, surfacing the
mismatch helps narrow the diagnosis fast.

Pod image refs against `localhost:5000` take the form
`localhost:5000/<repo>:<tag>` or sometimes
`<host>:5000/<repo>:<tag>` if the chart was rendered with a
non-localhost `registryLocation`. The orphan check matches on the
`/<repo>:` substring so both shapes resolve.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.22

Back to [Yuruna](../README.md)
