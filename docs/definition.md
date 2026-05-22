# Yuruna definitions

This file collects definitions of generic and yuruna-specific terms
that used to live as long inline comments in the codebase. Centralising
them in one place keeps definitions consistent across the framework,
the guest scripts, and the docs.

Source files reference an entry with a single line of the form:

```
# --- See https://yuruna.link/definition#<topic-slug>
```

The fragment resolves to a `### Defining <topic>` heading in this file.
Slugs follow the standard GitHub Markdown rule: lowercase the heading
text, strip everything that isn't `[a-z0-9_ -]`, then replace spaces
with hyphens. So `### Defining the two-source scheme` becomes
`#defining-the-two-source-scheme`.

This file is the sibling of [Yuruna memory](memory.md) (for historical /
incident rationale) and of [vmconfig topic reference](vmconfig.md)
(for `user-data` topic rationale). The same `# --- See` convention is
used in all three.

**Out of scope for this file:**

- PowerShell comment-based help (`<# .SYNOPSIS ... #>` blocks). Those
  are load-bearing for `Get-Help` and must stay attached to the
  function or script they document. Where a script's `.SYNOPSIS` is
  also the canonical definition of a yuruna concept (e.g. "resource",
  "component", "workload"), link to the script here instead of moving
  the help block.

Adding a new entry:

1. Pick the source comment block (must be a true inline comment, not a
   `.SYNOPSIS` docstring).
2. Add a `### Defining <topic>` heading here with the migrated content.
3. Replace the source comment with a single
   `# --- See https://yuruna.link/definition#<slug>` line (or
   `// --- See …` for Go, etc.).
4. The yuruna.link `definition` key already redirects to this file on
   GitHub — no `yuruna.link.json` edit needed for individual topics.

---

## Fetch-and-execution contract

### Defining fetch-and-execute base URL resolution

`fetch-and-execute.sh` is the guest-side fetch helper. It resolves the
base URL for `curl`-style fetches in this priority order:

1. **`$EXEC_BASE_URL`** — explicit override, used verbatim. Highest
   priority so a per-call override always wins over auto-discovery.
2. **`/etc/yuruna/host.env`** — written by `New-VM.ps1` at provision
   time. Holds `YURUNA_HOST_IP` / `YURUNA_HOST_PORT` for the dev
   iteration loop. We probe `/livecheck` with a short timeout; on
   success the host status server takes precedence over GitHub. On
   failure we fall through silently — no `/etc/yuruna/host.env` (CI,
   fresh demo) or a stopped server lands transparently on GitHub.
3. **`https://raw.githubusercontent.com/...`** — final fallback.

Cache-busting via environment variables (priority order):

1. **`$EXEC_QUERY_PARAMS`** — explicit override, used verbatim (include
   `?`).
2. **`YurunaCacheContent`** — systemwide cache-buster. Leave unset so
   caching proxies (e.g. the optional squid VM) serve stored copies;
   set it to force a fresh fetch:
   `export YurunaCacheContent="$(date +%Y%m%d%H%M%S)"`.

Both unset/empty → empty suffix, URL stays cacheable.

**`--no-proxy` on `/etc/yuruna/host.env` probes.** The host status
server lives on a Hyper-V Default Switch / VZ shared NAT IP. If
anything (subiquity leakage, `/etc/wgetrc`, the harness itself on the
host) left `http_proxy` pointing at the squid-cache, the probe rewrites
to that proxy — which is meant for external mirrors and cannot route
to the host's internal IP. `--no-proxy` keeps the probe direct.

Source: [`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh).

### Defining fetch-and-execute host environment variables

When `/etc/yuruna/host.env` defines `YURUNA_HOST_IP` and
`YURUNA_HOST_PORT`, `fetch-and-execute.sh` probes
`http://${YURUNA_HOST_IP}:${YURUNA_HOST_PORT}/livecheck` and, on success,
serves files from the host status server. Two probe details are
load-bearing:

**`--no-proxy`.** The host status server lives on a Hyper-V Default
Switch / VZ shared NAT IP. If anything (subiquity leakage,
`/etc/wgetrc`, the harness itself on the host) left `http_proxy`
pointing at the squid-cache, the probe rewrites to that proxy — which
is meant for external mirrors and cannot route to the host's internal
IP — and times out. We then silently fall through to GitHub even
though the host server is right there. `NO_PROXY` won't save us: this
is a private 172.x address that any custom `NO_PROXY` list might
omit.

**GET (not `--spider`).** `wget --spider` issues HEAD, and the host's
`HttpListener`-backed status server RSTs HEAD on endpoints that
declare `Content-Length` and write a body (HTTP.sys closes the
connection rather than truncating the body). The `/livecheck` body is
87 bytes — discarding to `/dev/null` is cheap. The server-side fix
shipped alongside this change; the client probe stays GET-based
defensively so future HEAD-RST regressions in any handler don't
silently push every guest back to GitHub.

Source: [`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh).

### Defining fetch-and-execute host-unreachable warning

When `/etc/yuruna/host.env` exists and names a host but `/livecheck`
doesn't answer in 2 s, that's an UNEXPECTED failure: this guest was
provisioned to talk to that host, so silently falling through to
GitHub would hide the real problem. Common causes:

- Host Wi-Fi roamed to a different SSID / subnet.
- Host status server crashed.
- Host firewall change.
- Default Switch / VZ shared NAT gateway changed.

The cycle will still complete via GitHub, but the dev iteration loop
is broken until the host is reachable again. `fetch-and-execute.sh`
warns loudly on stderr — stdout is captured by
`$(resolve_base_url)` and must stay clean.

Source: [`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh).

### Defining fetch-and-execute failure modes

`fetch-and-execute.sh` separates fetch from execute so the operator
can tell two distinct failure categories apart immediately.

**Fetch failure** (network, 404, empty file). The script fetches
first and runs `/bin/bash -c "$script_content"` second; this surfaces
network problems distinctly from inner-script errors. When
`source=host` the URL is a local-only IP (Hyper-V Default Switch / VZ
shared NAT) — `--no-proxy` is added to wget for the same reason
`resolve_base_url` does (see "host environment variables" above). For
`source=github`, the proxy is left on so squid-cache can serve cached
external fetches.

On fetch failure, the script prints the distinct
`FETCH AND EXECUTE FAILED:` marker so the GUI harness's
`FailurePattern` detection fires. Previously this branch printed the
legacy success marker (with the rationale "so the harness doesn't
hang") — but that lied to the harness about completion status. The
new marker closes the OCR wait at the same cadence as success, while
surfacing the actual failure category (couldn't fetch the script).

**Inner-script failure.** Under `set -euo pipefail`, the first
non-zero command aborts the script; the failing command's output is
printed above the failure block. The end-tag block (see "end tags"
below) emits the same `FETCH AND EXECUTE FAILED:` marker on this path
too — so the harness can't confuse an inner-script failure with a
pass.

Source: [`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh).

### Defining fetch-and-execute end tags

`fetch-and-execute.sh` emits two markers that bound the visible
output the host-side OCR harness reads.

**Pre-fetch `clear`.** Resets the visible screen so the harness's
"wait for prompt" doesn't match a stale prompt left from the previous
command. After `clear`, the next prompt the harness sees belongs to
this script's output, not the predecessor's.

**Post-execute end tag.** Distinct on success vs failure so the GUI
keystroke harness can tell them apart via OCR:

- On success: `FETCHED AND EXECUTED:`
- On failure: `FETCH AND EXECUTE FAILED:`

Previously a single `FETCHED AND EXECUTED:` marker was printed
regardless of `$rc`, so the harness's wait-for-text matched on
completion and reported PASS even when the inner script exited
non-zero — the failure only surfaced one or two steps later, usually
as a confusing downstream symptom (e.g. `test-localhost.sh` can't
reach a website that was never deployed).

The success marker keeps its exact shape so existing
`waitPattern: "FETCHED AND EXECUTED:"` sequences still match. The
engine's `fetchAndExecute` action passes
`"FETCH AND EXECUTE FAILED:"` as a `FailurePattern` to
`Wait-ForText`, so failure is detected at the same OCR-poll cadence
as success. The SSH harness uses the exit code (unchanged).

Source: [`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh).

### Defining the two-source scheme for framework and project URLs

Guest scripts that need to clone the yuruna framework and/or the
project repo (e.g. `ubuntu.server.24.update.sh`, `amazon.linux.2023.update.sh`,
`ubuntu.server.24.workload.k8s.website.sh`) follow a uniform two-source
scheme so framework + project URLs are NOT duplicated across guest
scripts:

1. Read host coordinates from `/etc/yuruna/host.env`
   (cloud-init-populated).
2. Pull `repositories.frameworkUrl` / `repositories.projectUrl` from
   the host status server's `/control/test-config` endpoint.
3. **Framework**: prefer the host's `/yuruna-archive.tar.gz` (committed
   working tree, no `.git/`), fall back to `git clone $FRAMEWORK_URL`
   with retries.
4. **Project**: `git clone $PROJECT_URL` into
   `$REAL_HOME/yuruna/project`. Skipped silently when
   `repositories.projectUrl` is empty (in-tree `project/` stop-gap path
   used by older configs).

**`--no-proxy` on host probes.** The host server lives on a private
NAT IP that any inherited `http_proxy` (e.g. squid-cache) cannot route
to.

Sources (every guest script that needs framework/project repos
re-implements this same scheme):

- [`guest/ubuntu.server.24/ubuntu.server.24.update.sh`](../guest/ubuntu.server.24/ubuntu.server.24.update.sh)
- [`guest/amazon.linux.2023/amazon.linux.2023.update.sh`](../guest/amazon.linux.2023/amazon.linux.2023.update.sh)
- Per-workload guest scripts in the yuruna-project tree (e.g.
  `project/example/website/...`) repeat the same shape.

---

## Host-side networking and registry contracts

### Defining the Windows host-proxy registry keys

Yuruna's Hyper-V host-proxy helpers (migrated from
`test/modules/Test.HostProxy.psm1`) read and write the following
registry values:

**WinINet (`HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`):**

| Value | Type | Notes |
|---|---|---|
| `ProxyEnable` | DWORD | `0` / `1` |
| `ProxyServer` | REG_SZ | `host:port` |
| `ProxyOverride` | REG_SZ | `;`-separated bypass list (`<local>` bypasses plain hostnames) |

**Environment (`HKCU\Environment`):**

| Value | Type | Notes |
|---|---|---|
| `HTTP_PROXY` / `HTTPS_PROXY` | REG_SZ | `http://host:port/` |
| `NO_PROXY` | REG_SZ | `,`-separated bypass list |

**Yuruna-managed markers:**

- `YurunaProxyManaged` (DWORD) under the WinINet key.
- `YURUNA_PROXY_MANAGED` (REG_SZ) under `HKCU\Environment`.

The markers flag "this state was set by yuruna" so a re-promotion
across a missing backup file doesn't capture our own value as if it
were the user's original.

Source:
[`host/windows.hyper-v/modules/Yuruna.Host.psm1`](../host/windows.hyper-v/modules/Yuruna.Host.psm1).

---

## Guest-side container runtime contracts

### Defining containerd hosts.toml cache mirror

The guest's `ubuntu.server.24.k8s.sh` reconfigures containerd to:

1. **Enable the CRI plugin** (disabled by default in the
   `containerd.io` package).
2. **Use `SystemdCgroup`** (k8s requirement).
3. **Route `/v2/` pulls through the `yuruna-caching-proxy`'s zot.**
   Without (3), containerd — the runtime
   `kubeadm` / `kubelet` / `k3s` actually use — bypasses zot entirely;
   only `docker pull` via dockerd benefits from the `daemon.json`
   `registry-mirrors` set above.

`config_path = "/etc/containerd/certs.d"` is the modern containerd
v1.7+ mechanism: drop a `hosts.toml` per upstream registry to rewrite
the pull host. We register `docker.io` and `registry.k8s.io` (the
`kubeadm` pre-pull set lives on `registry.k8s.io`). zot's sync
extension is configured (squid-cache `user-data`) to mirror both
upstreams plus `quay.io` / `ghcr.io` / `gcr.io`, so any future
workload pulling from those will also flow through cache on the first
hit.

Source:
[`guest/ubuntu.server.24/ubuntu.server.24.k8s.sh`](../guest/ubuntu.server.24/ubuntu.server.24.k8s.sh).

---

## System diagnostics

### Defining Get-SystemDiagnostic

`automation/Get-SystemDiagnostic.ps1` produces a read-only diagnostics
dump grouped into 13 sections. The script's SYNOPSIS lists each
section and what it reports; this entry covers HOW each section is
implemented and the contracts of its helpers. Memory.md carries the
incident-driven design rationale for specific checks (see
[memory.md "System diagnostics" group](memory.md#system-diagnostics)).

**Helpers**

- **`$script:Problems`** — collected problem signals; printed at the
  end so the operator gets a punch list without re-reading the full
  dump. Anything that adds an entry has been flagged by a script
  reader as out-of-band.
- **`Write-Section` / `Write-Sub` / `Write-Block`** — output helpers.
  `Write-Section` emits a banner; `Write-Sub` a sub-header;
  `Write-Block` streams a raw command's stdout so multi-line output
  (kubectl, docker ps) keeps its alignment. Output stays on the
  success stream so a `>` redirect by the operator captures the whole
  report.
- **`Invoke-DiagnosticSection`** — wraps a section so a thrown
  exception does NOT abort the whole dump. The catch logs the failing
  section by name, records a Problems entry for the summary, emits
  the inner exception's `PositionMessage` (file:line:col so the line
  is jumpable from the console), and falls through to the next
  section. Rationale in
  [Yuruna memory](memory.md#why-get-systemdiagnostic-wraps-each-section-in-invoke-diagnosticsection).
- **`Invoke-Tool`** — runs a native command and streams stdout +
  stderr. Returns nothing (output streams to the parent). Logs a
  problem on non-zero exit so the summary catches missing / broken
  tools without aborting the whole dump. The parameter is named
  `ToolArgs` (not `$Args`) because `$Args` is a PowerShell automatic
  variable.
- **`Format-ByteCount`** — converts a byte count to a human-readable
  string (B / KB / MB / GB / TB / PB). PowerShell ships no built-in
  helper; this is small enough to inline.
- **`-OutFile` transcript wrapper** — when `-OutFile` is set, captures
  via `Start-Transcript` so the file mirrors the console verbatim;
  `Stop-Transcript` runs in a `finally` block. We can't simply use
  `Tee-Object` on the whole script because `PSScriptInfo` + `param()`
  resist inline pipelining.
- **`logLevel` cascade** — see `Invoke-Clear.ps1` for the shared
  rationale (each level shows itself plus all higher-priority
  streams).

**Section internals**

**1. HOST** — platform-conditional. Windows uses
`Win32_OperatingSystem` for OS/version/uptime. macOS/Linux use
`uname -a` + `uptime` (plus `sw_vers` on macOS, `/etc/os-release` on
Linux).

**2. CPU** — Windows: `Win32_Processor`. macOS: `sysctl` +
`top -l 1`. Linux: parses `/proc/cpuinfo` and `/proc/loadavg`. The
"model name" line may be missing on ARM cores / qemu-KVM generic CPU
/ container-stripped cpuinfos; the script falls back to
`(unknown -- no "model name" line in /proc/cpuinfo)` rather than
blowing up on `-f` format. `$cores` is defaulted to 0 so the
`loadavg` branch has a sane denominator. `@(...)` wraps the
processor-line count so `.Count` is always an int. Failure-mode
rationale in
[Yuruna memory](memory.md#why-the-cpu-section-guards-against-proccpuinfo-automationnull).

**3. MEMORY** — Linux iterates `/proc/meminfo` with a literal
`foreach` rather than `$mi -match '...'` because the latter is filter
semantics and `$Matches` after an array match is unreliable for
capture extraction. Flags ≥ 90 % used.

**4. DISK** — Windows: `Win32_LogicalDisk DriveType=3`. macOS/Linux:
`df -h` for human-readable view, then re-runs `df -Pl` for portable
parseable output. Any filesystem at ≥ 90 % is flagged.

**5. GPU** — prefers `nvidia-smi`; falls back per-platform
(`Win32_VideoController`, `system_profiler SPDisplaysDataType`,
`lspci -nnk`).

**6. NETWORK** — interfaces, default route, and a DNS sanity probe
(`one.one.one.one` — a name that should always resolve from a
healthy host).

**7. TOP PROCESSES** — `Get-Process` sorted by CPU and by working
set.

**8. RECENT EVENTS** — Windows: `Get-WinEvent System Level=Error`
(last hour). Linux: `journalctl -p err -n 20 --since '1 hour ago'`.
macOS: `dmesg | tail -n 30` (`log show --last 1h` is slow; dmesg
covers the most useful signal).

**9. DOCKER** — `docker info` short-circuits with a single problem
when the daemon is unreachable. The image listing parses the
human-readable `--format` Size column (`359MB` etc.) into bytes so
it can sort largest-first; without this, the legacy table call
dumped every layer unfiltered, which on a busy build host drowns
the rest of the report. A `/v2/_catalog` probe of
`http://localhost:5000` checks the yuruna local registry: if
reachable, list repositories; catalog-empty is a problem because it
means no images have been pushed (or the registry's storage was
reset). 3-second timeout so the probe can't hang on a wedged
registry container. `/v2/_catalog` has no auth in the default
yuruna registry config.

**10. KUBE** — `kubectl version --output=json` (since `--short` is
deprecated). Surfaces nodes, namespaces, pods, services,
deployments, daemonsets, statefulsets, jobs/cronjobs, ingresses,
PV/PVCs, configmap/secret counts. Warning events use
`--sort-by .lastTimestamp` (ascending) and tail the last 100. Helm
releases are listed and any release not in `deployed` / `superseded`
states is flagged; `superseded` is what a prior revision moves to
after a successful upgrade. Empty namespaces (no Pods AND no
Deployments, excluding the k8s built-ins `default`, `kube-system`,
`kube-public`, `kube-node-lease`, `kube-flannel`) are flagged.
`kubectl port-forward` runs as a host process — `Win32_Process` on
Windows, `/bin/ps` on Unix — because it's not a cluster resource.
Failure-mode rationale for helm + empty-namespace flagging in
[Yuruna memory](memory.md#why-get-systemdiagnostic-flags-helm-releases-not-in-deployedsuperseded-states).

**11. LINUX HOST DETAIL** — Linux-only deep dive. Networking
blueprint (netplan, `/etc/resolv.conf`, `/etc/hosts`, resolvectl /
systemd-resolve); runtime networking state (`ip route`,
`ss -tulpn`, `ping`); firewall (`iptables -S` + `nft list ruleset`,
capped at 200 lines each); kernel signals (`dmesg -T` last 100
lines + full-ring OOM and hardware-error scan); virtualization
kernel modules (`lsmod` filtered to KVM / virtio / Hyper-V / VMware
/ VirtualBox / Xen prefixes); `journalctl -xe` last 100 lines with
PowerShell `ScriptBlock_Compile_Detail` entries redacted (see
[Yuruna memory](memory.md#why-the-journalctl-sample-redacts-get-systemdiagnostics-own-script-echo));
container runtime journals for docker / containerd / kubelet (last
100 warning+ since 6 h ago); CNI plugin presence under
`/opt/cni/bin/` and config under `/etc/cni/net.d/`. Each sub-section
degrades gracefully when its tool/file is absent. Tool quirks:
- `ss -p` needs `CAP_NET_ADMIN` / root to attach process info;
  without it `ss` still lists sockets, just with empty users.
- `ping -W 2` caps each probe at 2 s so a black-hole route can't
  hang the whole dump (max ~6 s total).
- `nft list ruleset` needs `CAP_NET_ADMIN` — as an unprivileged
  user it returns empty/error; `ss -tuln` is used instead (no `-p`
  so no root needed to read other users' `/proc` entries).
- `dmesg -T` pretty-prints kernel timestamps. On Ubuntu 24.04
  `/proc/sys/kernel/dmesg_restrict=1` by default so unprivileged
  callers get EPERM; the failure is treated as informational.

**12. YURUNA PROJECT** — surfaces two artifacts that pinpoint
deploy-time issues otherwise visible only as opaque kubelet errors
hours later:

- **(a) `resources.output.yml`** — the bridge between
  `yuruna resources` (writes it) and `yuruna components` /
  `yuruna workloads` (read it). The parser is line-by-line WITHOUT
  the `powershell-yaml` module so the diagnostic still works on a
  fresh box. Two heuristics flag known failure modes:
  1. A top-level key whose value is empty AND no indented non-blank
     line follows is a "block present but empty" — exactly what
     produces empty `registryLocation` lookups in Helm.
  2. A nested `value:` field with nothing after the colon means
     `tofu output` captured the field but its value was empty/null.
- **(b) Errors / failures / warnings under `.yuruna/`** — grep
  across every `.yuruna/` working folder. Two filters keep the dump
  signal-only:
  - **Skip patterns**: `.terraform/providers/` paths, binary /
    archive extensions (`.exe`, `.dll`, `.so`, `.zip`, `.iso`,
    `.qcow2`, `.vhd*`, image files, `.pdf`, etc.), and files over
    5 MB.
  - **Identifier denylist**: PowerShell preference variables
    (`ErrorAction*`), helm/k8s threshold knobs (`failureThreshold*`),
    log-level constants (`WarningLevel*`). Denylist mechanism is in
    [Yuruna memory](memory.md#why-the-yuruna-grep-filters-trigger-word-identifiers-via-a-denylist).
- **(c) Recent cycle footprint** — top-100 most recently modified
  files under any `.yuruna/`, with mtime + size. See
  [Yuruna memory](memory.md#why-the-diagnostic-shows-recent-yuruna-file-mtime-as-cycle-footprint)
  for the design rationale.

Path is resolved from `$PSScriptRoot` (the `automation/` folder) so
the section works regardless of where the operator launched pwsh.

**13. SUMMARY** — list of problems detected. Intentionally OUTSIDE
`Invoke-DiagnosticSection` — see
[Yuruna memory](memory.md#why-summary-is-outside-invoke-diagnosticsection).
`Stop-Transcript` failures in the cleanup `finally` are swallowed
(best-effort tee for the operator; we don't want a transient
transcript error to drown the dump in red text).

Source:
[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1).

---

## VM provisioning policies

### Defining the VM core-count policy

Every `New-VM.ps1` script in this repo assigns vCPUs to its guest using
the same uniform policy:

```
vmCores = max(4, floor(hostCores / 2))
```

`hostCores` is the host's physical-core count, detected per platform:

| Platform        | Detection                                                  |
|-----------------|------------------------------------------------------------|
| Windows Hyper-V | `Win32_Processor.NumberOfCores`, summed across all sockets |
| macOS UTM       | `sysctl -n hw.physicalcpu`                                 |
| Ubuntu KVM      | `nproc --all` (installed processors)                       |

**Rationale.** Floor-half-of-host is generous enough for the guest
workloads typical of yuruna tests (k8s cluster bring-up, image pulls,
helm renders, .NET / Java builds) without starving the host of cycles
for the runner, status server, and VM management itself. The 4-core
floor is the practical minimum for `kubeadm` + `containerd` + `dockerd`
plus a small workload: below 4 the guest churns at startup and cycles
flake intermittently (kubelet self-heal loops, helm install timeouts).

**Failure mode.** If the host has fewer than 4 cores total, `New-VM.ps1`
exits with a non-zero error code rather than silently provisioning an
under-sized guest that will time out later in the cycle. The operator
must either run on a larger host or edit the specific guest's
`New-VM.ps1` to override the policy.

**Uniform across all guests.** Every guest follows this policy —
including the squid-cache VM (historically 4 vCPU regardless of host).
On larger hosts the extra vCPUs cost nothing because caching is I/O-
and memory-bound, not CPU-bound; the policy keeps every guest's sizing
predictable instead of carrying per-guest exceptions.

**Override on macOS 26 guest only.** The macOS 26 guest's `-CpuCount`
parameter exists because the IPSW restorer's minimum varies by macOS
version. Passing `-CpuCount <n>` overrides the policy, but `<n>` must
still be ≥ 4 or `New-VM.ps1` exits with the same error.

Source files (each implements the policy in line):

- `host/macos.utm/guest.<amazon.linux.2023|ubuntu.server.24|windows.11|squid-cache|macos.26>/New-VM.ps1`
- `host/windows.hyper-v/guest.<amazon.linux.2023|ubuntu.server.24|windows.11|squid-cache>/New-VM.ps1`
- `host/ubuntu.kvm/guest.<amazon.linux.2023|ubuntu.server.24|windows.11|squid-cache>/New-VM.ps1`

---

## Status pages (UI)

### Defining the status-page browser baseline

The Yuruna status pages (`test/status/index.html`,
`test/status/test.config.html`, and any future page mounted under
`test/status/`) are written so they render correctly on Safari iOS
9.x as well as current browsers. iOS 9.0–9.2 ship an ES5-only
JavaScript parser and a partial CSS implementation; supporting them
rules out:

- **JavaScript:** ES2015+ syntax (arrow functions, template literals,
  `async`/`await`, destructuring, optional chaining, nullish
  coalescing, default params, spread/rest, `for-of` with `const`).
  Wrap each page's code in an IIFE to keep helpers off the global
  object.
- **CSS:** the `inset` shorthand (iOS 14.5+), flex `gap` (iOS 14.5+),
  grid `gap` (iOS 10.3+), CSS Grid (iOS 10.3+), and CSS custom
  properties / variables (iOS 9.3+). Use margins, explicit
  `top/right/bottom/left`, and flex-wrap instead.
- **DOM API:** `KeyboardEvent.key` landed in iOS 10.3 — read `.key`,
  fall through to `.keyCode` (`27 == Escape`) and `.which`. Use the
  bracket form `['catch'](...)` on promises because iOS 9.0–9.2
  strict-mode parsers still treat `catch` as reserved in member
  position.

`fetch` is shimmed inside
[`test/status/yuruna.common.js`](../test/status/yuruna.common.js) for
browsers that lack it; native fetch on every other browser is left
untouched.

### Defining the status-page cache policy

Every `.html` response from `Start-StatusServer.ps1` carries
`Cache-Control: public, max-age=60, must-revalidate`, and each HTML
file includes a matching `<meta http-equiv="Cache-Control">` tag.
Operators often browse the status page through a shared squid-cache
(`Test-CachingProxy -SetHostProxy`, corp proxy, etc.); without a
cache window the dashboard re-fetched on every navigation/poll, but
the prior `no-store` header was leaking stale content through some
intermediary clients. `max-age=60 + must-revalidate` bounds staleness
at 60 s — on next access after that, the client must revalidate (the
server returns 200 with the current body; ETag / If-Modified-Since
matching is not issued). The meta tag is the belt to that brace,
covering intermediaries that forward HTTP headers but not every
client path.

Other extensions (`.json`, `.txt`, `.css`, `.js`, `.sh`, `.ps1`,
`.psm1`, `.yml`, `.yaml`, `.md`) are served `no-store` so polled
data lands fresh.

### Defining the status-page HostInfo aggregator

`Yuruna.getHostInfo()` (in
[`test/status/yuruna.common.js`](../test/status/yuruna.common.js))
returns a Promise that resolves to a single object aggregating every
piece of host-level data the status pages need. Three sources are
fetched in parallel; the result is cached for the lifetime of the
page so additional consumers do not re-fetch.

| Field         | Source                    | Notes |
|---------------|---------------------------|-------|
| `repoName`    | `status.json.repoUrl`     | Trailing path segment, `.git` stripped, first letter upper-cased. |
| `version`     | `/yuruna-repo/VERSION`    | First line only. |
| `hostname`    | `status.json.hostname`    | Falls back to `window.location.hostname`. |
| `host`        | `status.json.host`        | `host.` prefix stripped. |
| `ipAddresses` | `/track/ipaddresses.txt`  | Raw text, trailing whitespace stripped. |

Each field is `null` (or `''` for hostname) when its source is
unavailable; the renderer is expected to no-op rather than throw.

`Yuruna.populateHeader(cta)` consumes HostInfo to fill
`#header-title`, `#header-version`, and `#header-machine` in one
pass. Callers that need to refresh the machine identity from live
polled data (e.g. the dashboard's `renderStatus`) call
`Yuruna.renderHeaderMachine(el, name, host, cta)` directly with the
freshly polled fields.

### Defining the status-page header anatomy

Every status page renders the same header shape:

```html
<header class="page-header">
  <h1><span id="header-title">Yuruna</span><span id="header-version"></span></h1>
  <span id="header-machine"></span>
</header>
```

| Element            | Populated by                           | Content                              |
|--------------------|----------------------------------------|--------------------------------------|
| `#header-title`    | `Yuruna.populateHeader`                | Capitalised repo name (`Yuruna`, `Yurunadev`, …). Hard-coded `Yuruna` is the no-JS fallback. |
| `#header-version`  | `Yuruna.populateHeader`                | `v<VERSION>` from the project root.  |
| `#header-machine`  | `Yuruna.populateHeader` then per page  | Hostname stack (`name` / `(host-type)`) plus a right-edge CTA link. |

Pages pass a `cta` object (`{ href, label, title? }`) so the CTA
varies per page (`Edit config` on the dashboard, `← Dashboard` on the
config editor). The CTA class is `.header-cta` in
[`yuruna.common.css`](../test/status/yuruna.common.css) so its
footprint is identical across pages — navigating between them does
not shift the header items.

### Defining the status-page hostinfo dump

Clicking the hostname in any status page's header navigates to
[`hostinfo.html`](../test/status/hostinfo.html), which renders a
fresh run of
[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1)
for the host the page is being served from (not any guest).

Round trip:

1. The page's bootstrap fires a `GET /control/host-diagnostic` (single
   round trip, no separate trigger).
2. `Start-StatusServer.ps1` invokes the script via a child `pwsh`
   (`pwsh -NoProfile -ExecutionPolicy Bypass -WorkingDirectory
   <repoRoot> -File <script>`), captures both stdout and stderr
   through `Out-String`, writes the result to
   `[System.IO.Path]::GetTempPath()/yuruna-hostinfo.txt` (overwriting
   any previous run), and returns the captured text as
   `text/plain; no-store`.
3. The page renders the text inside a `<pre>` with
   `white-space: pre-wrap` so the diagnostic's column-aligned tables
   keep their layout while still wrapping on narrow viewports.

**Why a child `pwsh`.** The status server is itself running in pwsh,
but invoking the diagnostic in the same process would interleave the
script's transcript writes with the server's own logging and could
mutate global preference variables
(`InformationPreference`/`WarningPreference`/etc.) the script sets
for its `-logLevel` handling. A child process keeps the script's
side-effects isolated.

**Why a fixed temp filename.** The file is overwritten on every
request — operators get one canonical "most recent host diagnostic"
they can grep from the shell (`cat /tmp/yuruna-hostinfo.txt` or
`type %TEMP%\yuruna-hostinfo.txt`) without timestamped clutter. The
file is not web-accessible by path (the temp directory is outside
`$statusDir` / `$trackDir`); the only way to read it through the
server is via the same `/control/host-diagnostic` request, which
regenerates it.

**Why synchronous.** The diagnostic typically completes in a few
seconds; making the request asynchronous (trigger + poll) would
double the moving parts for no real benefit at Yuruna's
single-operator scale. The endpoint blocks the server's request loop
for the duration of the run, which is acceptable because the polling
dashboard re-tries on the next 30 s tick.

**Why the hostname is the click target.** It is the same string the
operator reads at the top right of every page, so the affordance
"click my host to see its diagnostic" needs no extra label. The link
is styled (`a.hm-name`) so it is indistinguishable from the prior
text span at rest and underlines only on hover.

### Defining the status-page caching-proxy banner

`$env:YURUNA_RUNTIME_DIR/caching-proxy.txt` is rewritten at the start
of every test cycle by `Start-StatusServer.ps1` (run with `-Restart`
from `Invoke-TestRunner.ps1` on each cycle; its
`Test-CachingProxyAvailable` probe re-runs then). The file contains
trusted server-generated HTML — possibly an `<a href>` to the
`cachemgr` URL — and the dashboard renders it inside the "Latest
Cycle" section title via `innerHTML`. The dashboard re-fetches the
file on every `loadStatus()` poll so a page left open sees the new
cycle's cache state within one poll interval, even across cycles.

---

## Canonical yuruna concepts

The following terms are defined canonically inside PowerShell
comment-based help (`.SYNOPSIS` / `.DESCRIPTION`) because `Get-Help`
relies on them. Pointers, not duplicates:

- **Resource** — see
  [`automation/Set-Resource.ps1`](../automation/Set-Resource.ps1) help
  block. Resources are deployed with OpenTofu and produce
  `resources.output.yml` consumed by components.
- **Component** — see
  [`automation/Set-Component.ps1`](../automation/Set-Component.ps1).
  Container images that are built and pushed to a registry.
- **Workload** — see
  [`automation/Set-Workload.ps1`](../automation/Set-Workload.ps1).
  Helm-driven deployments of one or more components.
- **The three operations (`resources`, `components`, `workloads`)** —
  see [`automation/yuruna.ps1`](../automation/yuruna.ps1). Sequenced
  by the umbrella CLI.
- **Forwarder** (host-side squid TCP forwarder) — see
  [`host/macos.utm/Start-CachingProxyForwarder.ps1`](../host/macos.utm/Start-CachingProxyForwarder.ps1).

For deeper architectural context see [Yuruna Architecture](architecture.md) (framework
architecture) and [Test harness — architecture](test-harness.md) (test-harness
architecture).

---

Back to [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
