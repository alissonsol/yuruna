# Yuruna definitions

This file collects definitions of generic and yuruna-specific terms
in one place to keep definitions consistent across the framework,
the guest scripts, and the docs.

Source files reference an entry with a single line of the form:

```
# --- REGION: https://yuruna.link/definition#<topic-slug>
```

The fragment resolves to a `### Defining <topic>` heading in this file.
Slugs follow the standard GitHub Markdown rule: lowercase the heading
text, strip everything that isn't `[a-z0-9_ -]`, then replace spaces
with hyphens. So `### Defining the two-source scheme` becomes
`#defining-the-two-source-scheme`.

This file is the sibling of [Yuruna memory](memory.md) (for historical /
incident rationale) and of [vmconfig topic reference](vmconfig.md)
(for `user-data` topic rationale). The same `# --- REGION:` convention is
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
   `# --- REGION: https://yuruna.link/definition#<slug>` line (or
   `// --- REGION: …` for Go, etc.).
4. The yuruna.link `definition` key already redirects to this file on
   GitHub — no `yuruna.link.json` edit needed for individual topics.

---

## Fetch-and-execution contract

### Defining fetch-and-execute base URL resolution

`fetch-and-execute.sh` is the guest-side fetch helper. It resolves the
base URL for `curl`-style fetches in this priority order:

1. **`$EXEC_BASE_URL`** — explicit override, used verbatim. Highest
   priority so a per-call override always wins over auto-discovery.
   Classified by scheme: an `http://` override is treated as a host
   status server (`--no-proxy`, eligible for the perf-checkpoint POST);
   anything else is treated as remote and gets neither.
2. **`/etc/yuruna/host.env`** — written by `New-VM.ps1` at provision
   time. Holds `YURUNA_HOST_IP` / `YURUNA_HOST_PORT` for the dev
   iteration loop. We probe `/livecheck` with a short timeout; on
   success the host status server takes precedence over GitHub. On
   failure we fall through — no `/etc/yuruna/host.env` (CI,
   fresh demo) or a stopped server lands on the GitHub fallback below.
3. **GitHub, same repository, pinned commit** — the final fallback.

**The fallback is not a fixed public URL.** It is built from a repo slug
and an exact commit supplied by the host: `EXEC_FALLBACK_REPO` /
`EXEC_FALLBACK_REF`, typed into the guest console alongside `EXEC_SHA256`
(see the integrity gate), or `YURUNA_GITHUB_REPO` / `YURUNA_GITHUB_REF`
baked into `host.env` at New-VM time. The typed pair wins, because it
names the commit the host is serving *now* rather than whenever this VM
was provisioned.

Two properties make this the only sound fallback, and both come straight
from the integrity gate — the host digests *its* copy of the file, and the
guest refuses bytes that don't match that digest:

- **Same repository.** A fallback aimed anywhere else — a public mirror of
  a private repo being the obvious case — serves bytes the digest was never
  taken from. The guest then refuses to run them, and the run dies with an
  `INTEGRITY MISMATCH` whose real meaning is *wrong repository*.
- **Pinned commit, never a branch.** `main` moves on every push; the digest
  does not.

With no repo+ref available, there is **no** fallback: the fetch fails with
`NO FETCH SOURCE` rather than guessing at another repository.

**Private repositories.** When `repositories.GH_TOKEN` is configured, the
guest receives it on the cloud-init seed (never over the console, which the
host screenshots and OCRs into the published run log, and never over HTTP).
With a token present the fetch goes through the GitHub Contents API, which
serves a file body verbatim under the raw media type whether the repo is
public or private; without one it uses `raw.githubusercontent.com`, which
can only ever read a public repo. Both are pinned to the same commit, so
either shape satisfies the digest. The token is passed to `wget` through a
`0600` wgetrc (`--config`), never `--header`, so it never appears in the
process list — where any `ps` snapshot in a diagnostic dump would carry it
into the published log.

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
host) left `http_proxy` pointing at the caching-proxy, the probe rewrites
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
pointing at the caching-proxy, the probe rewrites to that proxy — which
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

- The host's IP changed since this VM was provisioned — a DHCP lease
  renewed across a host reboot, or Wi-Fi roamed to another subnet. The
  address in `host.env` is baked at New-VM time and never re-resolved,
  so a reused VM outlives it.
- Host status server crashed.
- Host firewall change.
- Default Switch / VZ shared NAT gateway changed.

The cycle can still complete via the GitHub fallback, but only if the
commit the host is serving is actually *on* the remote: the fallback
fetches a pinned commit, so a commit that exists only in the host's
working tree (uncommitted, or committed but unpushed) cannot be fetched,
and the integrity gate refuses whatever else it finds. Either way the dev
iteration loop is broken until the host is reachable again.
`fetch-and-execute.sh` warns loudly on stderr.

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
`source=github`, the proxy is left on so caching-proxy can serve cached
external fetches.

On fetch failure, the script prints the distinct
`NONZERO SCRIPT EXIT:` marker so the GUI harness's
`FailurePattern` detection fires. This marker closes the OCR wait at
the same cadence as success, while surfacing the actual failure
category (couldn't fetch the script); a success marker here would lie
to the harness about completion status.

**Inner-script failure.** Under `set -euo pipefail`, the first
non-zero command aborts the script; the failing command's output is
printed above the failure block. The end-tag block (see "end tags"
below) emits the same `NONZERO SCRIPT EXIT:` marker on this path
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
- On failure: `NONZERO SCRIPT EXIT:`

The markers must differ by `$rc`: a single `FETCHED AND EXECUTED:`
marker printed regardless of exit code lets the harness's wait-for-text
match on completion and report PASS even when the inner script exits
non-zero — the failure only surfaces one or two steps later, usually
as a confusing downstream symptom (e.g. `test-localhost.sh` can't
reach a website that was never deployed).

The success marker keeps its exact shape so existing
`waitPattern: "FETCHED AND EXECUTED:"` sequences still match. The
engine's `fetchAndExecute` action passes
`"NONZERO SCRIPT EXIT:"` as a `FailurePattern` to
`Wait-ForText`, so failure is detected at the same OCR-poll cadence
as success. The SSH harness uses the exit code (unchanged).

The failure marker deliberately avoids the words "fetch" and "execute".
`Test-OCRMatch` is fuzzy, so a failure marker containing those words
fuzzy-matches the echoed `fetch-and-execute.sh …` command line on the
first OCR poll — aborting a healthy run in seconds, before any script
output appears. The rare token `NONZERO` cannot collide with a command
or with normal `dnf`/`git`/PowerShell output. Keep the wrapper marker
(`automation/fetch-and-execute.sh`) and the handler's auto-derived
`FailurePattern` (`Test.SequenceHandler.psm1`) in sync.

Source: [`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh).

### Defining fetch-and-execute checkpoints

A fetched script can mark phase boundaries so the perf graph shows
*where* the time inside a `fetchAndExecute` step went, not just how
long the whole step took. The convention is a single output line that
**starts with four equals signs**:

```bash
echo "==== Installing base packages ===="
# ... work ...
echo -e "\e[1;36m==== Configuring services ====\e[0m"   # color is fine
```

The checkpoint name is the text after the leading `====`, up to a
trailing `====` or the end of the line, trimmed. Any line of output that
does not begin with the four-equals marker is ignored, so checkpoints
cost nothing to scripts that don't use them. The marker test is
ANSI-tolerant: a colorized line (e.g. `echo -e "\e[1;36m==== … ===="`)
has its leading color escapes peeled off before the column-0 test, and
any escapes left inside the captured name are stripped out, so the
phase name shows clean. The `====` must still be the first *visible*
characters on the line — only ANSI color codes may precede it.

**How they are collected.** `fetch-and-execute.sh` runs the fetched
script with the bash xtrace profiler enabled to a dedicated descriptor
(`BASH_XTRACEFD`), so a full timestamped command trace becomes a
guest-local artifact without polluting the visible console. Each
checkpoint line is read off the script's live stdout and stamped with
bash's high-resolution `EPOCHREALTIME` clock — the same clock the
profiler's `PS4` uses — then turned into an offset in milliseconds from
the script's start. Profiling needs `EPOCHREALTIME` (bash ≥ 5); set
`EXEC_PROFILE=0` to opt out, or `EXEC_KEEP_PROFILE=1` to keep the raw
trace file for debugging.

**How they reach the host.** When the script was fetched from the host
(not the GitHub fallback), the wrapper POSTs the collected checkpoints to
`control/perf-checkpoints` on the status service **before** printing the
completion marker, so the data is on disk while the host's step window is
still open. The POST is best-effort: a failed or skipped POST never
changes the exit code or the end-tag markers above. The status service
host-stamps the arrival time and writes one sidecar JSON under
`status/perf/checkpoints/`.

**How they are attached.** `control/perf-aggregates` joins each sidecar
to the `fetchAndExecute` step whose `[startedAtUtc, endedAtUtc]` window
contains the sidecar's host-stamped arrival time. Both sides of that
comparison are host-clock, so guest/host clock skew cannot break the
match. `perf.html` then subdivides that step's bar segment into one
sub-segment per phase — the slice before the first checkpoint is the
fetch/preamble `(setup)`, and the slice after the last checkpoint runs to
the step's end. Steps without checkpoints render unchanged.

Source: [`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh),
[`test/Start-StatusService.ps1`](../test/Start-StatusService.ps1),
[`test/status/yuruna.common.js`](../test/status/yuruna.common.js).

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
3. Fall back to `YURUNA_FRAMEWORK_URL` / `YURUNA_PROJECT_URL` in
   `host.env` when step 2 returned nothing. That endpoint lives *on* the
   host, so a guest cut off from the host gets nothing from it — which is
   exactly the moment it most needs a URL to clone from. The same two URLs
   are baked into the seed at New-VM time for that case.
4. **Framework**: prefer the host's `/yuruna-archive.tar.gz` (committed
   working tree, no `.git/`), fall back to `git clone $FRAMEWORK_URL`
   with retries.
5. **Project**: `git clone $PROJECT_URL` into
   `$REAL_HOME/yuruna/project`. Skipped silently when
   `repositories.projectUrl` is empty (in-tree `project/` stop-gap path
   used by older configs).

**Private repositories: `repositories.GH_TOKEN`.** git does **not** read
`GH_TOKEN` — that name is a `gh(1)` convention, not a git one. A bare
`git clone https://github.com/owner/private-repo` therefore prompts for a
username, which hangs an unattended guest (or fails outright under
`GIT_TERMINAL_PROMPT=0`). What makes the clone work is `GIT_ASKPASS`: the
seed installs a shim at `/usr/local/lib/yuruna/git-askpass.sh` (Windows:
`C:\ProgramData\yuruna\git-askpass.cmd`) that answers git's credential
prompts from `$GH_TOKEN`, and exports `GH_TOKEN` + `GIT_ASKPASS` +
`GIT_TERMINAL_PROMPT=0` into the guest's shell environment. Every
`clone` / `fetch` / `pull` then authenticates with no change at any call
site. The token stays in the environment — it never reaches `~/.gitconfig`
or a remote URL, so it cannot leak through `git remote -v` or the process
list. Leave `GH_TOKEN` empty for public repositories and none of this is
installed.

**Scope it read-only.** The guests only ever pull, but the token is copied
onto every test VM and is served on `/control/test-config`, so it should be
the least-privileged credential that works: a fine-grained token, scoped to
the `frameworkUrl` and `projectUrl` repositories only, with **Contents:
Read-only** — which covers both the `git clone` and the Contents API fetch
above. A classic PAT's smallest useful scope (`repo`) is read-write across
every repository the account can see, which is a far larger blast radius
than this job needs. See
[CONTRIBUTING](../CONTRIBUTING.md#repositoriesgh_token--reading-a-private-frameworkproject-repo)
for the exact settings, and note that one fine-grained token can only cover
repositories under a single owner.

**`--no-proxy` on host probes.** The host server lives on a private
NAT IP that any inherited `http_proxy` (e.g. caching-proxy) cannot route
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

Yuruna's Hyper-V host-proxy helpers read and write the following
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

### Defining the tofu external hook shell choice

The tofu resources under `global/resources/localhost/` run their
host-side checks through `data "external"` blocks whose `program` is
`["bash", "<hook>.sh"]` — POSIX bash plus the tool each check actually
needs (`kubectl`, `docker inspect`, `python3` + PyYAML). A
`null_resource` + `provisioner "local-exec" { interpreter = pwsh }`
is deliberately avoided: spawning pwsh from a tofu provisioner is a
recurring failure point under pwsh 7.6.x / .NET 10 (observed on
7.6.1) — the child pwsh crashes at process startup with a
`FileLoadException` on `System.Collections.Specialized` carrying a
truncated `PublicKeyToken`, before any script line runs. The trap
class is captured in the memory file
`feedback_pwsh_provisioner_assemblyname_flake.md`; the
`global/resources/azure/aks-cluster` hooks share the same rationale.

**Plan-time execution.** `Set-Resource`'s planfile-pinned apply means
a `data "external"` program runs at plan time only: its result is
captured once into the plan, and the apply pass never re-invokes it.

**Stdin query protocol.** tofu serializes the block's `query` map as
a single JSON object on the program's stdin — and it sends a JSON
object even when `query` is unset, so a hook that takes no arguments
must still drain stdin. The program answers with exactly one JSON
object of string values on stdout; diagnostics go to stderr, and a
non-zero exit fails the plan with them.

The localhost hooks:

- [`context-copy.sh`](../global/resources/localhost/context-copy/context-copy.sh)
  (wired by
  [`context-copy.tf`](../global/resources/localhost/context-copy/context-copy.tf))
  copies a kube context bundle — cluster + user + context — from the
  query's `sourceContext` under `destinationContext` inside
  `~/.kube/config`, renaming the entries with python3/PyYAML.
- [`localhost-registry-check.sh`](../global/resources/localhost/registry/localhost-registry-check.sh)
  (wired by
  [`localhost-registry.tf`](../global/resources/localhost/registry/localhost-registry.tf))
  only **verifies** the local docker `registry` container is up
  (`docker inspect -f '{{.State.Running}}'`) and bubbles a meaningful
  error otherwise. Starting the container — with retry and rate-limit
  diagnostics — is the job of the workload bash script (e.g.
  `ubuntu.server.24.workload.k8s.website.sh`), which runs BEFORE
  `Set-Resource`.

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
extension is configured (caching-proxy `user-data`) to mirror both
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

**11c. GUEST PROVISIONING (Linux)** — Linux-only side-channel
collector for the `pwsh_retry`-wrapped actions in guest update
scripts (see
[`Defining yuruna retry lib`](network.md#defining-yuruna-retry-lib)).
Lists `/var/log/yuruna/`, then cats every `*.log` under it with
size-tagged headers. Any log containing the
`_yuruna_retry` exhaustion string `all N attempts exhausted` is
flagged as a problem so the SUMMARY catches it (the wrapped
action retried until the cycle aborted). Adds the last 80 lines
of `journalctl -u systemd-resolved --since '15 min ago'` so a
DNS-side explanation is visible without re-shelling into the
guest, and a current `Get-PSRepository` /
`Get-PackageProvider -ListAvailable` / module snapshot so the
operator can compare against the pre-flight state captured in
the log at install time. Rationale in
[Yuruna memory](memory.md#why-ubuntu--al2023-guest-update-scripts-wrap-install-module-powershell-yaml-with-pwsh_retry).

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
including the caching-proxy VM.
On larger hosts the extra vCPUs cost nothing because caching is I/O-
and memory-bound, not CPU-bound; the policy keeps every guest's sizing
predictable instead of carrying per-guest exceptions.

**Override on macOS 26 guest only.** The macOS 26 guest's `-CpuCount`
parameter exists because the IPSW restorer's minimum varies by macOS
version. Passing `-CpuCount <n>` overrides the policy, but `<n>` must
still be ≥ 4 or `New-VM.ps1` exits with the same error.

Source files (each implements the policy in line):

- `host/macos.utm/guest.<amazon.linux.2023|ubuntu.server.24|ubuntu.server.26|windows.11|caching-proxy|stash-service|macos.26>/New-VM.ps1`
- `host/windows.hyper-v/guest.<amazon.linux.2023|ubuntu.server.24|ubuntu.server.26|windows.11|caching-proxy|stash-service>/New-VM.ps1`
- `host/ubuntu.kvm/guest.<amazon.linux.2023|ubuntu.server.24|ubuntu.server.26|windows.11|caching-proxy|stash-service>/New-VM.ps1`

### Defining the VM memory policy

Unlike the core count, memory is **not** derived from the host: each
`New-VM.ps1` writes a fixed value for its guest. The default is **12 GB**;
the exceptions are deliberate.

| Guest               | Hyper-V | macOS UTM        | Ubuntu KVM |
|---------------------|---------|------------------|------------|
| `amazon.linux.2023` | 12 GB   | 12 GB            | 4 GB       |
| `ubuntu.server.24`  | 12 GB   | 12 GB            | 8 GB       |
| `ubuntu.server.26`  | 12 GB   | 12 GB            | 8 GB       |
| `windows.11`        | 12 GB   | 12 GB            | 8 GB       |
| `caching-proxy`     | 12 GB   | 12 GB            | 12 GB      |
| `stash-service`     | 8 GB    | 8 GB             | 8 GB       |
| `macos.26`          | —       | 8 GB (`-MemoryMb`) | —        |

**Rationale.** 12 GB carries the heaviest guest workload the cycles run: a
single-node `kubeadm` cluster (control plane + containerd + pulled images,
~3–4 GB) alongside a `dotnet-sdk` build/run. It is a ceiling, not a
reservation the guest is expected to fill.

**Hyper-V reserves the full amount.** `Set-VM` sets Startup = Minimum =
Maximum, i.e. dynamic memory is off, so a guest holds its whole allocation
for the life of the VM. That is why a leftover guest from a previous cycle
starves the next one with `0x800705AA` (insufficient system resources)
until it is torn down — the runner's cleanup paths exist for exactly that.

**KVM guests are sized down** to the minimum that carries the workload
rather than matching the Hyper-V / UTM allocation, because every extra GB
per VM subtracts from how many guests a KVM host can run concurrently in a
busy pool.

**The caching-proxy 12 GB is load-bearing**, not a default that happens to
match: squid's `cache_mem` is tuned to 7 GB (58 % of the VM) with 2 GB left
for the zot registry cache, and swap is masked, so an OOM is unrecoverable.
Tune VM RAM, `cache_mem`, and zot together — see
[caching-proxy.md](caching-proxy.md).

**Changing it.** Edit the guest's `New-VM.ps1`; the value is expressed
differently per host — Hyper-V takes `-MemoryStartupBytes` /
`-MemoryMinimumBytes` / `-MemoryMaximumBytes`, which must move **together**
(a Startup above Maximum is rejected); macOS UTM substitutes
`__MEMORY_SIZE__` (MB) into the `config.plist` template; KVM passes
`--memory` (MB) to `virt-install`. A change affects **newly created** VMs
only — an existing guest keeps its allocation until it is recreated, or is
resized in place per [host/read.more.md](../host/read.more.md).

Host sizing assumes this: the 32 GB host minimum in
[install.md](install.md) is what lets a cycle hold a guest plus the cache
VM without the host itself swapping.

---

## Status pages (UI)

### Defining the status-page browser baseline

The Yuruna status pages (`test/status/index.html`,
`test/status/test.config.html`, and any future page mounted under
`test/status/`) are written so they render correctly on **Safari iOS
9.3 / Safari 9.1** as well as current browsers. That is the real hard
floor: every color token is a CSS custom property (`var(--…)`), and
custom properties first ship in iOS 9.3 / Safari 9.1 — below that the
palette is undefined and the pages do not render. The JavaScript is
still authored to the stricter ES5-only bar (the pages predate a hard
9.3 decision and the defensive style costs nothing), so the code
avoids:

- **JavaScript:** ES2015+ syntax (arrow functions, template literals,
  `async`/`await`, destructuring, optional chaining, nullish
  coalescing, default params, spread/rest, `for-of` with `const`).
  Wrap each page's code in an IIFE to keep helpers off the global
  object.
- **CSS:** the `inset` shorthand (iOS 14.5+), flex `gap` (iOS 14.5+),
  grid `gap` (iOS 10.3+), and CSS Grid (iOS 10.3+). Use margins,
  explicit `top/right/bottom/left`, and flex-wrap instead. CSS custom
  properties (iOS 9.3+) ARE used and define the baseline above.
  `env()` / `max()` safe-area insets (iOS 11.2+) are a progressive
  enhancement: every rule that uses them declares a plain-value
  `padding` fallback first, so iOS 9.3–11.1 keeps its gutter and only
  loses the notch inset.
- **DOM API:** `KeyboardEvent.key` landed in iOS 10.3 — read `.key`,
  fall through to `.keyCode` (`27 == Escape`) and `.which`. Use the
  bracket form `['catch'](...)` on promises because older iOS
  strict-mode parsers still treat `catch` as reserved in member
  position.

`fetch` is shimmed inside
[`test/status/yuruna.common.js`](../test/status/yuruna.common.js) for
browsers that lack it; native fetch on every other browser is left
untouched.

### Defining the status-page mobile and dark-mode hardening

Every status page reads its color tokens from CSS custom properties
declared in `:root` of [`test/status/yuruna.common.css`](../test/status/yuruna.common.css);
a `@media (prefers-color-scheme: dark)` block flips the palette so the
same rules work on both themes (operators triaging incidents at 03:00
get a low-glare surface without a per-page rewrite).

Touch targets reach the iOS HIG / Material Design floor: every
`.header-cta`, `.meta-btn`, and bare `<button>` inherits
`min-height: 2.75rem` and `min-width: 2.75rem` (44 px / 48 dp) from
the `.yuruna-touchable` rule so a phone-sized finger can hit them.

`@media (max-width: 600px)` collapses the page header to a vertical
stack and trims side padding so the dashboard reads on a 375 px
portrait phone without horizontal scrolling.

### Defining the status-page visibility-aware polling

Status pages that refresh on a `setInterval` / countdown would burn
cellular battery when a phone tab is left in the background. The
`Yuruna.startVisibilityAwarePolling` helper exported by
[`test/status/yuruna.common.js`](../test/status/yuruna.common.js)
returns a controller; the page calls `.tick()` from its 1-second
loop, the controller checks `document.hidden` first, and when the
tab is invisible the fetch is suppressed and the countdown freezes
(rendered as `...`). On `visibilitychange` back to visible the
countdown resets to 0 so the operator sees a fresh reload
immediately.

### Defining the status-page cache policy

Every `.html` response from `Start-StatusService.ps1` carries
`Cache-Control: public, max-age=60, must-revalidate`, and each HTML
file includes a matching `<meta http-equiv="Cache-Control">` tag.
Operators often browse the status page through a shared caching-proxy
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
| `ipAddresses` | `/runtime/ipaddresses.txt`  | Raw text, trailing whitespace stripped. |

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

```
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
2. `Start-StatusService.ps1` invokes the script via a child `pwsh`
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
dashboard re-tries on the next 60 s tick.

**Why the hostname is the click target.** It is the same string the
operator reads at the top right of every page, so the affordance
"click my host to see its diagnostic" needs no extra label. The link
is styled (`a.hm-name`) so it is indistinguishable from the prior
text span at rest and underlines only on hover.

### Defining the status-page caching-proxy banner

`$env:YURUNA_RUNTIME_DIR/caching-proxy.txt` is rewritten at the start
of every test cycle by `Start-StatusService.ps1` (run with `-Restart`
from `Invoke-TestRunner.ps1` on each cycle; its
`Test-CachingProxyAvailable` probe re-runs then). The file contains
trusted server-generated HTML — possibly an `<a href>` to the
`cachemgr` URL — and the dashboard extracts its href and applies it to the "Latest
Cycle" Dashboards link via `setAttribute` (not `innerHTML`, so the
fetched markup is never injected). The dashboard re-fetches the
file on every `loadStatus()` poll so a page left open sees the new
cycle's cache state within one poll interval, even across cycles.

### Defining the status-page banner

Every status page (`index.html`, `test.config.html`, `hostinfo.html`)
renders the same `#banner` strip just below the header. The visual
contract is identical across pages so an operator switching between
the dashboard, the config editor, and the host-diagnostic dump sees
the same color + dot + text for the same runner state.

**State precedence and colors** (highest priority first):

| State     | Background | When fired                                    |
|-----------|------------|-----------------------------------------------|
| `stopped` | `#374151`  | `control/runner-status` reports `running:false` — the runner process is dead. Always wins, so a page left open after a stop doesn't look "live". |
| `paused`  | `#ca8a04`  | Pause-state text is non-null (see below); amber pulse on the dot is suppressed (would clash with the meaning). |
| `fail`    | `#dc2626`  | `data.overallStatus === 'fail'`               |
| `pass`    | `#16a34a`  | `data.overallStatus === 'pass'`               |
| `running` | `#2563eb`  | `data.overallStatus === 'running'`. The dot pulses (`@keyframes pulse`) so a hung tab is visually distinct from a fresh load. |
| `idle`    | `#6b7280`  | No data and runner not stopped (e.g. fresh host). |

**Pause-state text decision.** Three pause signals interact:

- `data.stepPaused` (server flag) — operator clicked "Pause after step".
- `data.cyclePaused` — operator clicked "Pause after cycle".
- `current-action.json.line` — written by `Invoke-Sequence`; the substring `Paused (waiting for resume)` means the runner has actually reached the step boundary (vs. just having the flag armed mid-step).

```
stepPaused && line says "Paused (waiting for resume)"  -> "Test paused"
stepPaused                                             -> "Test will pause (after current step)"
cyclePaused && status !== 'running'                    -> "Test paused"
cyclePaused                                            -> "Test will pause (after current cycle)"
otherwise                                              -> null (use the status-based text)
```

Step pause wins over cycle pause because the step boundary is
always reached first. The banner is amber whenever any of the
pause text fires; the per-guest action pill stays its normal color
until the runner is actually waiting for resume (so the operator
can tell "armed but still working" from "stopped at the boundary").

**Polling cadence.** All three pages poll the same triple:
`runtime/status.json` + `runtime/current-action.json` +
`control/runner-status`. The dashboard (`index.html`) shows a
visible countdown badge; `test.config.html` and `hostinfo.html` poll
silently. The interval is **60 seconds** across all pages —
matched to the `Cache-Control: max-age=60` window so each poll
crosses the cache boundary cleanly. Faster polling would either
hit a cache hit (no fresher data) or fight the cache for the same
ETag-less file; slower polling would let a finished cycle stale on
the editor pages longer than the cache window.

**User-account row** (`hostinfo.html` only). The right-aligned
`User account: <name>` text shows the OS account the
`Start-StatusService.ps1` pwsh process is running as — surfaced via
`GET /control/runtime-env` → `serverUserAccount`
(`[Environment]::UserName`, cross-platform). Useful when sudo /
Run-As elevation is in play or on a host with multiple operator
accounts. Rendered as plain `<span>` text on a transparent
background so it blends into the banner color regardless of state;
not present on `index.html` (dashboard real estate is denser) or on
`test.config.html` (the editor is operator-facing so the account is
implicit). Fetched once per page load — the value is stable for the
server process's lifetime.

**Page-specific extras.** Beyond the shared banner contract, only
`index.html` carries Pause buttons (`Pause after step`, `Pause after
cycle`), a Continue button when a break action is parked
(`runtime/break-active.json`), and the visible refresh countdown.
Those are dashboard concerns; the other pages keep the banner
display-only.

### Defining the status-page dashboard

[`test/status/index.html`](../test/status/index.html). The operator's
landing page; one yuruna.link reference at the top of the file points
here. Subsystems covered separately:
[banner state](#defining-the-status-page-banner),
[header anatomy](#defining-the-status-page-header-anatomy),
[HostInfo aggregator](#defining-the-status-page-hostinfo-aggregator),
[cache policy](#defining-the-status-page-cache-policy),
[browser baseline](#defining-the-status-page-browser-baseline),
[caching-proxy banner](#defining-the-status-page-caching-proxy-banner).

Page-specific behavior:

- **60 s poll with visible countdown.** `setInterval` ticks every
  second and decrements a `#countdown` badge; reaching zero re-fires
  `loadStatus()` which sequences three soft fetches —
  `runtime/status.json`, `runtime/current-action.json`, and
  `control/runner-status` — before re-rendering. 404s are tolerated
  (`null` propagates and the renderer falls through to "no data" /
  "stopped" branches).
- **Pause buttons.** Two `.meta-btn`s (`step` and `cycle`) toggle the
  banner's amber state. The button stays enabled while EITHER the
  cycle is running OR a pause is armed, so the operator can flip
  between modes mid-flight. "Armed" → label switches to "Continue"
  and the button gets the `paused-active` amber class; clicking POSTs
  to `/control/<kind>-resume`, then forces a `loadStatus()` so the
  banner flips without waiting for the next poll.
- **Break-step Continue.** When a guest is parked at a `break` action
  the runner writes `runtime/break-active.json`; the renderer emits an
  inline Continue button on that guest's action pill. Server-side
  Continue restores the snapshot, starts the VM, and removes the
  break-active sidecar — making the button vanish on the next poll.
- **VM-prep collapse.** `New-VM`, `Start-VM`, and `New-VM.Resource`
  render as a single combined pill labeled "New VM". Status
  precedence inside the triplet is `fail > running > pass > skipped >
  pending`, so a single failure inside the trio surfaces even if the
  other two passed. The combined pill carries the earliest-start /
  latest-finish timestamps so the duration reading stays meaningful.
- **Sequence cards (Latest Cycle).** When `status.json` carries
  `sequences[]`, the "Test sequences" section renders one card per
  entry, in runner-list order, nesting the guest(s) that sequence
  drives. The card header shows the sequence name plus ONE aggregate
  status badge (`fail > running > pass > skipped > pending` over its
  guests). The nested guest blocks deliberately omit their own status
  badge — for the common one-guest sequence it would just repeat the
  card's badge — but keep the guest-name link to the results folder.
  The flat fallback list (no `sequences[]`: legacy `guestSequence`
  path, or the brief pre-`Initialize-StatusDocument` window) renders
  each guest as a standalone card WITH its badge, since there it is the
  only status indicator.
- **Log file URL resolution.** Two layouts are supported: new
  (per-cycle folder via `cycleFolderUrl`, HTML log lives inside with
  the same base name) and legacy flat
  (`log/<cycleId>.<host>.<sha>.html`). The renderer picks
  `cycleFolderUrl` when present and falls through to the flat form
  otherwise — keeps historical browsing working across the cycleFolder
  rename.
- **Commit links.** History rows may carry either the new
  `gitCommits: [{sha, repoUrl}, ...]` shape or the legacy
  `gitCommit` + top-level `repoUrl`. The `<a href>` is gated on
  `https?://` scheme AND alphanumeric SHA so a hostile `repoUrl`
  cannot inject markup. `gitCommits[0]` is the framework SHA (used
  to build the per-cycle log URL); subsequent entries are project
  repos and additional layers.
- **Recent Cycles sequence buttons.** The "Sequences" column renders
  one badge per entry in the row's `sequenceSummary`
  (`[{ name, status, folderUrl }]`), each wrapped in an `<a href>` to
  that sequence's results folder — the driven guest's per-VM folder
  for a 1:1 sequence, or the cycle folder when a sequence fans out to
  more than one guest. `status` is the worst of the sequence's guests
  (`fail > running > pass > skipped > pending`), matching the Latest
  Cycle sequence-card badge. Rows recorded before `sequenceSummary`
  existed — and the legacy `guestSequence` path, which has no
  sequences — carry only `guestSummary`, so the renderer falls back to
  one badge per guest there: `guestSummary[k]` can be a bare string
  ("pass"/"fail" — very old rows) or `{ status, failureArtifacts }`,
  and when `failureArtifacts` is set that pill links to the per-guest
  cycle folder. In that fallback the pill is still *labeled* with the
  sequence name(s) that drive its guest in the CURRENT cycle plan
  (`status.json.sequences[]`, joined with " + " when a guest serves
  more than one), so the column reads as sequences even for old rows;
  a guest the current plan no longer references degrades to its bare
  guest key.
- **`#cycle-timestamp`, `#cycle-started`, `#cycle-commit`,
  `#cycle-images-refresh`.** The four "Latest Cycle" meta-cards
  (`#cycle-timestamp` holds the UTC cycle identifier shown under the
  "Cycle ID (UTC)" label). The
  static `#sec-cycle-title` label sits to the LEFT in the section
  header; the dashboards link sits in the right-aligned
  `#banner-dash-row` instead.
- **Per-page dashboards label.** Right-aligned `#banner-dash-row`
  inside `#banner`, transparent background. Parses
  `runtime/caching-proxy.txt` for a `<a href="...">` — if present,
  renders a **`Dashboards`** anchor to that URL (the Grafana
  dashboards browse page filtered by the `yuruna` tag, served from
  the same host as the caching proxy); otherwise renders text **`No
  dashboard server`**. `&amp;` in the file is unescaped to `&` before
  `setAttribute('href', ...)` so the browser hits the actual URL on
  click.

### Defining the status-page config editor

[`test/status/test.config.html`](../test/status/test.config.html).
Live edit of `test/test.config.yml`. GET `/control/test-config` parses
the YAML on disk and returns JSON; the page renders it as an
expandable tree. Save POSTs the in-memory JSON back; server converts
to YAML and atomically replaces the file. Subsystems covered:
[banner state](#defining-the-status-page-banner),
[header anatomy](#defining-the-status-page-header-anatomy),
[cache policy](#defining-the-status-page-cache-policy),
[browser baseline](#defining-the-status-page-browser-baseline).

Page-specific behavior:

- **Type-aware leaf inputs.** Booleans render as toggle switches with
  a True/False side label; numbers use `<input type=number>` (empty
  value coerced to `0` so an in-progress edit doesn't poison the
  saved JSON with `NaN`); strings get a free-form `<input type=text>`
  EXCEPT for enum keys (`keystrokeMechanism`, `logLevel`) which use
  the custom dropdown, and for `guestSequence` array entries which
  use a host-aware dropdown filtered by `/control/guest-folders`.
- **Custom `.ydd` dropdown.** Replaces the native `<select>` element
  because Firefox-on-Wayland fails to paint the native popup on some
  Linux sessions. Capture-phase document mousedown listener closes
  the open menu when the user clicks outside; the per-item click
  handler uses `mousedown` (not `click`) so the pick fires BEFORE
  the wrap blurs and our blur handler closes the menu underneath
  the click. Keyboard navigation (arrow keys, Enter, Escape, Space)
  driven via a `keyOf(e)` shim that falls through to `e.keyCode`
  because iOS 9 lacks `e.key`.
- **`guestSequence` array editor.** Already-selected guest folders
  filter out of the add-item dropdown so each guest appears at most
  once. A stale value (folder no longer present under the current
  host) renders as a disabled option flagged with
  "(not under host folder)" so the operator can see what's being
  replaced rather than the value silently dropping.
- **`vmStart.cachingProxyIP` probe driver.** Live verdict mark next
  to the input: green ✓ (probe succeeded), red ✗ (probe failed),
  amber ⏳ (probe in flight), gray ✗ (empty / invalid format / not
  yet probed). The driver triggers a fetch ONLY on field blur, not
  per-keystroke — a valid-looking prefix like `192.168.7.4` en route
  to `192.168.7.46` would lock the field on the partial value. While
  the probe is in flight the input is disabled and re-focused
  afterwards. Out-of-order responses are dropped via a `latestId`
  counter so a stale response from probe-N-1 can't overwrite the
  fresh mark from probe-N.
- **Env-var mirror.** Beneath the editable `vmStart.cachingProxyIP`
  row, a read-only mirror shows whatever
  `$env:YURUNA_CACHING_PROXY_IP` the status server inherited at
  startup. At cycle start the persisted value is probed first and
  wins when its `:3128` answers; the env var is the fallback probed
  only when the config value is absent or unreachable (see
  `Resolve-CachingProxyEndpoint`). Surfacing both side-by-side makes
  it obvious which one the next run will actually use.
- **Save and start cycle.** Destructive: orange button at the far
  left of the footer (hard to click by accident). Confirms with
  `window.confirm()` only when a runner is currently alive — starting
  from a stopped state is non-destructive so no prompt fires. POSTs
  to `/control/test-config` first (atomic file replace) and then to
  `/control/start-cycle` (clears pause flags, runs
  `Remove-TestVMFiles.ps1`, and either signals the inner runner to
  break its delay OR spawns a fresh runner if none). 6-second dwell
  on the final "Cycle restarted / Runner started" message before
  navigating to the status page so the operator can read it before
  the dashboard takes over.

### Defining the status-page perf chart

[`test/status/perf.html`](../test/status/perf.html). Per-sequence
**icicle / flame graph**: one horizontal icicle per cycle (latest 10,
newest first), time on the x-axis (shared scale across the shown
cycles, so a slower cycle's bar reads as wider) and step-hierarchy
depth on the y-axis. Subsystems covered:
[banner state](#defining-the-status-page-banner),
[header anatomy](#defining-the-status-page-header-anatomy),
[cache policy](#defining-the-status-page-cache-policy),
[browser baseline](#defining-the-status-page-browser-baseline).

Page-specific behavior:

- **Aggregation.** Server endpoint `/control/perf-aggregates` (GET =
  cached, POST = recompute) scans `test/status/perf/cycles/*.jsonl`.
  Each cycle bucket holds the full step list — `{ordinal, occurrence,
  name, kind, durationMs, outcome, parentOrdinal, parentAction,
  startedMs, endedMs}` — plus the per-cycle totals (`durationMs`,
  `stepCount`, `failCount`). `startedMs` / `endedMs` are
  epoch-millisecond INTEGERS, not ISO strings, so the browser never
  has to parse a .NET `'o'`-format (7-digit fractional) timestamp.
  fetchAndExecute steps additionally keep the ISO `startedAtUtc` /
  `endedAtUtc` window the checkpoint-sidecar join matches against.
  Cache lives in the detached server's memory; endpoint edits in
  `Start-StatusService.ps1` require a server restart to take effect.
- **Hierarchy by time containment.** The page builds each cycle's step
  tree from the `[startedMs, endedMs]` windows: a step whose window
  sits inside another's becomes its child, one level deeper. A `retry`
  parent therefore renders as a single bar with its child steps nested
  INSIDE it — not as a separate bar stacked on top of the children.
  (Stacking double-counted the nested time: the retry bar re-added its
  children's durations, inflating the cycle total.) The wall-clock
  duration shown per cycle is the span `max(end) − min(start)`, not the
  sum of every step's duration.
- **fetchAndExecute checkpoints** become a further nested level: each
  guest-pushed phase marker is a child segment under its step, so the
  per-phase breakdown is preserved inside the icicle.
- **Cycle data link.** Each row's timestamp links to that cycle's
  results folder. perf.html fetches `runtime/status.json` alongside the
  aggregates and joins `cycleId` → `cycleFolderUrl` (lifecycle suffix
  stripped, as the history rows do). A miss (cycle older than
  `history[]`, or status.json unavailable) drops only the link, not the
  chart.
- **Most-recent-10 display.** The page shows the latest `MAX_CYCLES`
  (10) cycles per sequence, newest first, regardless of how many the
  server returns. The server still scans up to
  `testCycle.recentDisplayCount` (default 30, from
  `test/test.config.yml` — the same cap that bounds
  `status.json.history[]`); files are sorted name-descending (ISO-8601
  filename prefixes make lexical order chronological) and clipped to
  that N before the scan.
- **Stable per-step palette.** `stepColor(name)` djb2-hashes the step
  name to a 16-color palette. Idempotent across page loads, so the same
  step always gets the same color across cycles — a regression in step
  X surfaces as "the magenta bar got wider" rather than as a position
  shift. Collisions are possible past 16 distinct step names, but
  adjacent cells rarely share a color by chance.
- **Cell labels + tooltips.** A cell wide enough gets an in-cell label
  (dark glyphs with a white halo via `paint-order: stroke`, legible on
  any palette color AND on touch devices, which never get the hover
  `<title>`). The `<title>` carries the full name / kind / duration /
  outcome / enclosing action.
- **Failed steps.** Same fill color as the success case (so the
  color-identity invariant survives) with a red 1.5 px stroke; the
  row's duration label turns red and gets a ✕.
- **Fallback for missing step timing.** A cycle whose steps lack usable
  `startedMs` / `endedMs` is drawn as ONE gray bar and increments
  `staleCycleCount`; after the pass, `staleCycleCount > 0` inserts an
  amber `.stale-banner` explaining that the detached status-service
  process predates the icicle endpoint change and how to restart it.
- **Recalculate button.** Right-aligned in the banner area. POSTs to
  `/control/perf-aggregates`; server invalidates the cache and
  recomputes. Page re-renders with the fresh payload.

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

## Cycle-folder sidecar inventory

Each cycle leaves a small set of well-known sidecar files alongside the
captured artifacts. Their lifecycle is documented here so an autonomous
remediator can reason about cycle state without re-deriving the layout
by directory-walking. All paths are relative to the cycle folder
(`<repo>/test/status/log/<cycleBaseName>/`) unless otherwise noted;
runtime-only files live under `<runtimeDir>/` (typically
`<repo>/test/status/runtime/`).

### Defining the cycle-folder sidecar inventory

| Sidecar | Path | Producer | Removed | Purpose |
| --- | --- | --- | --- | --- |
| `.incomplete` | cycle folder | `Start-LogFile` in [Test.Log.psm1](../test/modules/Test.Log.psm1) | `Stop-LogFile` after manifest write | Marker file (JSON: cycleId, pid, startedAtUtc, hostname) that lets a boot-time recovery sweep detect crashed cycles in O(1). Paired with the R-2 folder-name `.incomplete` suffix: marker FILE carries forensic detail; folder NAME signals state at a glance. Presence means "this cycle did not reach a clean end." |
| `manifest.json` | cycle folder | `Write-CycleManifest` in [Test.Log.psm1](../test/modules/Test.Log.psm1) at cycle close | overwritten on next cycle close (same folder is single-use) | Enumerates every artifact in the cycle folder with kind + sha256 + size + mtime so downstream consumers (CI, remediator, dashboard) don't have to walk the directory. |
| `cycle.events.ndjson` | cycle folder | `Write-CycleNdjsonEvent` in [Test.Log.psm1](../test/modules/Test.Log.psm1) — every emit site routes through the `Send-CycleEventSafely` wrapper | append-only for the life of the cycle | JSON-Lines event stream stamped with `cycleId` + `cycleFolder` so multi-host pool consumers can join events without parsing folder names. |
| `cycle.events.gaps` | cycle folder | `Write-CycleNdjsonEvent` failure sentinel | append-only | One line per failed NDJSON append (open-handle race, disk full). Surfaces stream gaps to a remediator that would otherwise consume truncated truth. |
| `last_failure.json` | `<runtimeDir>` (NOT the cycle folder) | the failure-emit blocks in [Invoke-Sequence.psm1](../test/modules/Invoke-Sequence.psm1) | overwritten on the next cycle's first sequence start, and pre-wiped by [Invoke-TestRunner.ps1](../test/Invoke-TestRunner.ps1) before each spawn | Schema-v2 record (failureClass, severity, suggestedRecoveries, action, vmName, guestKey, hostType) that an out-of-process remediator consumes to choose a recovery handler. |
| `current-action.json` | `<runtimeDir>` | retry-with-backoff write loop in [Invoke-Sequence.psm1](../test/modules/Invoke-Sequence.psm1) | every action transition rewrites it; cleared at cycle end | In-flight action breadcrumb the dashboard reads to display "running step N of M: <verb> <description>". |
| `break-active.json` | `<runtimeDir>` | retry-with-backoff write loop in [Test.SequenceHandler.psm1](../test/modules/Test.SequenceHandler.psm1) `break` handler | break handler removes on resume; pre-wiped by [Invoke-TestRunner.ps1](../test/Invoke-TestRunner.ps1) before each spawn | Marks a cooperative breakpoint as parked so the status UI can render a Resume button. |
| `runner.pid` + `runner.start` | `<runtimeDir>` | `Write-RunnerPidFile` in [Test.SingleInstance.psm1](../test/modules/Test.SingleInstance.psm1) | rewritten by every outer launch; an atomic temp→rename keeps the pair consistent | Outer's pidfile + StartTime sidecar so a re-launched outer can classify the prior occupant as Self / Stale / OtherRunner without misreading via cmdline regex. |
| `inner.pid` | `<runtimeDir>` | atomic write at top of [Invoke-TestInnerRunner.ps1](../test/modules/Invoke-TestInnerRunner.ps1) | pre-wiped by outer before each spawn | Inner's PID — read by the outer's watchdog. Temp-file + Move-Item makes the write atomic so a crash mid-write can't leave a truncated digit. |
| `runner.heartbeat` | `<runtimeDir>` | C# `Yuruna.HeartbeatWriter` timer in [Invoke-TestInnerRunner.ps1](../test/modules/Invoke-TestInnerRunner.ps1) | overwritten every 30 s | Process-level proof of life. Stays fresh even when the runspace is wedged inside a long SSH/OCR call. |
| `runner.stepHeartbeat` | `<runtimeDir>` | runspace-side touch at the top of every step in [Invoke-Sequence.psm1](../test/modules/Invoke-Sequence.psm1); outer pre-wipes + force-touches before each spawn | overwritten per step | Runspace-level proof of life. Mtime older than `testCycle.stepTimeoutMinutes` means the inner is wedged inside a step → outer watchdog kills it. |
| `.test.config.snapshot.json` | `<runtimeDir>` | `Publish-TestConfigSnapshot` in [Test.Config.psm1](../test/modules/Test.Config.psm1), auto-fired by every `Read-TestConfig` parse | overwritten on next parse | Cross-process parsed-config snapshot (envelope: sourcePath, sourceMtime, sourceHash, publishedAt, publisherPid, config). `Read-TestConfigOrSnapshot` validates the envelope's mtime+hash against the live YAML and uses the snapshot when both still match, avoiding a redundant YAML parse in the inner. |
| `.caching-proxy.env.json` | `<runtimeDir>` | atomic temp→rename in [test/Start-CachingProxy.ps1](../test/Start-CachingProxy.ps1) | wiped by `Remove-TestVMFiles.ps1` | Cleared `*_proxy` env-var snapshot so a re-invocation of Start-CachingProxy can restore them without operator re-typing. |
| `caching-proxy.state.yml` | `<runtimeDir>` | `Save-CachingProxyState` in [Test.CachingProxy.psm1](../test/modules/Test.CachingProxy.psm1) (temp-file + Move-Item + `.backup` rotation) | merged on next save | Cache-VM password + IP. Has a `.backup` sibling rotated on each successful write; `Read-CachingProxyState` falls back to the backup when the main is corrupt and rotates the bad copy to `.corrupt.<UTC>` for forensics. |

Conventions:

- Every JSON sidecar is UTF-8 without BOM; YAML follows the same.
- Atomic writes go through `Write-YurunaStateFile` / `Write-YurunaStateFileJson`
  in [Test.StateFile.psm1](../test/modules/Test.StateFile.psm1) -- the
  shared temp-file + rename primitive. New sidecar writers should use
  it rather than re-implementing the pattern. The canonical example
  is `Save-CachingProxyState` (which predates the helper and adds
  `.backup` rotation on top of the same shape).
- Sidecars in `<runtimeDir>` are PROCESS-SCOPED and pre-wiped by the
  outer runner at each new cycle spawn. Sidecars in the cycle folder
  are CYCLE-SCOPED and persist with the cycle artifacts.
- A boot-recovery sweep runs ONCE per outer startup via
  `Invoke-YurunaBootRecovery` in [Test.Recovery.psm1](../test/modules/Test.Recovery.psm1).
  It archives orphan `.incomplete` markers (renamed to
  `.aborted.<UTC>.json` so a future sweep is a no-op), deletes stale
  pidfiles whose process is provably dead, and renames a stale
  `break-active.json` to `break-active.<UTC>.json.aborted`. A clean
  boot is silent; a non-trivial sweep emits a single
  `boot_recovery_completed` NDJSON event with the archived /
  cleared counts.

## Cycle folder lifecycle

A cycle's on-disk folder transitions through three named states.
Discovery + boot recovery use the folder name to classify a cycle
in O(1) without opening any file inside it:

| On-disk folder name | Cycle state | Written by |
| --- | --- | --- |
| `<base>.incomplete/`        | In progress, OR crashed (marker file inside) | `Start-LogFile` |
| `<base>/`                   | Cleanly closed                              | `Stop-LogFile` rename |
| `<base>.aborted.<UTC>/`     | Boot-recovered crash; folder + content preserved as forensics | R-5 boot sweep |

Where `<base>` is the canonical `NNNNNN.YYYY-MM-DD.HH-mm-ss.HOSTID`
shape from `Format-CycleFolderBaseName` — the 4th segment is the opaque
per-host `hostId` (not the hostname), so the cycle-folder name (and the
pool dashboard's `cycleFolderUrl` deep-link derived from it) discloses no
hostnames.

### Defining the cycle folder identity

Every NDJSON event records `cycleFolder` as the bare `<base>` (no
suffix), called the cycle's **identity**. A streaming consumer
joining events across the rename boundary sees a stable identifier
even as the on-disk folder transitions through the three states
above. Consumers that need to FIND on-disk artifacts try the bare
`<base>/` first, then `<base>.incomplete/`, then any
`<base>.aborted.<UTC>/` archive.

`Get-CycleFolderIdentity` in [Test.Log.psm1](../test/modules/Test.Log.psm1)
is the one-liner that strips any of the three suffixes from a path
or leaf and returns the identity.

### Defining the clean-close rename

At a successful `Stop-LogFile` the sequence is:

1. Emit `cycle_end` NDJSON event into `<base>.incomplete/cycle.events.ndjson`.
2. Close the HTML log inside `<base>.incomplete/`.
3. Write `<base>.incomplete/manifest.json`.
4. Delete the `.incomplete` marker file inside the folder.
5. `Move-Item <base>.incomplete/ -> <base>/` (atomic single rename
   on same-volume NTFS / ext4 / APFS).
6. `Set-CycleFolderUrl -RelativeUrl log/<base>/` so the dashboard's
   next poll of status.json sees the post-rename URL.

A crash between steps 1-4 leaves the folder as `<base>.incomplete/`
WITH the marker file — boot recovery handles it. A crash AT step 5
(folder rename failed) leaves `<base>.incomplete/` WITHOUT the
marker file — boot recovery handles that too (the folder suffix
alone is the orphan signal).

### Defining the boot-recovery folder rename

`Resolve-OrphanIncompleteCycle` (Test.Recovery.psm1) handles both
recovery signals:

1. **Marker file inside `<base>.incomplete/`** (the common case)
   — read marker payload, augment with `recoveredAtUtc` +
   `recoveredByPid`, rename folder to `<base>.aborted.<UTC>/`,
   write augmented payload to `<base>.aborted.<UTC>/.aborted.<UTC>.json`,
   delete the original marker file.

2. **Folder with `.incomplete` suffix but NO marker inside**
   (rename-failure during Stop-LogFile) — rename folder to
   `<base>.aborted.<UTC>/`. No marker payload to archive.

Both end with the folder name carrying the `.aborted.<UTC>` suffix
so a second boot sweep on the same host is an idempotent no-op.

## Cycle-event NDJSON schema

`cycle.events.ndjson` is the cycle-scoped append-only event stream
that drives every off-host consumer: the status dashboard, the
remediation dispatcher, multi-host pool joins. Each line is a JSON
object validated at the emit site by [Test.EventSchema.psm1](../test/modules/Test.EventSchema.psm1)
before it reaches disk.

### Defining the cycle.events.ndjson record shape

Every record carries an envelope plus event-specific payload fields.
The envelope is enforced by the schema; payload fields are accepted
as-is so a new event type can introduce fields without amending the
schema in lockstep.

**Required envelope fields:**

| Field       | Type   | Source                                           |
| ---         | ---    | ---                                              |
| `timestamp` | string | ISO-8601 UTC; emitter sets at write time.        |
| `event`     | string | Free-form event name (`step_end`, `cycle_start`, etc.). |

**Auto-stamped correlation fields** (set by Write-CycleNdjsonEvent if missing):

| Field         | Type   | Set when                                         |
| ---           | ---    | ---                                              |
| `cycleFolder` | string | Leaf name of `$global:__YurunaCycleFolder` -- always present mid-cycle. |
| `cycleId`     | string | `$global:__YurunaCycleId`, the ISO timestamp the outer assigned at cycle start. |
| `runId`       | string | `$global:__YurunaRunId`, a per-runner-process GUID generated once at module load. |

A multi-host pool consumer joins on `(runId, cycleId)` to identify a
specific cycle on a specific host without parsing the leaf-name format
or relying on hostname collisions across the pool.

**Typed payload fields** (validated when present; absent is fine):

`stepNumber`, `totalSteps`, `cycleNumber`, `pid` are `int`. `ok` is
`bool`. `durationMs` is `int-or-null`. `suggestedRecoveries` is an
array. `failureClass` and `severity` are matched against the canonical
enums in [Test.SequenceAction.psm1](../test/modules/Test.SequenceAction.psm1):

* **failureClass**: ocr_timeout, network_timeout, credential_expired,
  host_io_blocked, pattern_matched_failure, retry_exhausted,
  snapshot_restore_failed, script_error, wait_timeout,
  extension_error, instrumentation_failure, unknown.
* **severity**: hard, soft, unknown.

`actionVerb`, `action`, `description`, `sequencePath`, `vmName`,
`guestKey`, `hostType`, `error`, `reason`, `hostname`, `handler`,
`snapshotId` are typed as strings.

### Defining the cycle.events.ndjson event-name catalog

Every event name emitted into `cycle.events.ndjson` today. Order
follows the lifecycle: cycle boundary → per-step → failure / recovery
→ infrastructure-class. An off-host consumer joins on `(runId,
cycleId)` (R-8) and routes on `event` plus the validated typed
fields above.

| Event name | Producer | Trigger |
| --- | --- | --- |
| `cycle_start` | [Start-LogFile](../test/modules/Test.Log.psm1) | New cycle begins; carries `cycleId`, `cycleNumber`, `cycleFolder`, `hostname`. |
| `cycle_end` | [Stop-LogFile](../test/modules/Test.Log.psm1) | Cycle closes; carries `outcome` (pass/fail/aborted/unknown) and `reason`. |
| `step_end` | [Invoke-Sequence](../test/modules/Invoke-Sequence.psm1) | Each step finishes; carries `stepNumber`, `actionVerb`, `ok`, `durationMs`, `failureClass`/`severity`/`suggestedRecoveries` from the verb's static registration. |
| `step_failure` | [Invoke-Sequence](../test/modules/Invoke-Sequence.psm1) | Normal-path or engine-crash failure; mirrors `step_end` plus `lastSucceededStepNumber`, `innerActionVerb`, `failureScreenshotPath`, `failureOcrPath`. |
| `runner_state_transition` | [Test.RunnerState](../test/modules/Test.RunnerState.psm1) | Every state transition + synthetic boot-recovery fault pair; carries `fromState`, `toState`, optional `reason` / `synthetic`. |
| `remediation_recommended` | [Test.Remediation](../test/modules/Test.Remediation.psm1) | `Invoke-Remediation` dispatched a handler; carries `recommendation` enum, `handledBy`, `autoApply`. |
| `boot_recovery_completed` | [Test.Recovery](../test/modules/Test.Recovery.psm1) | Boot sweep found at least one stale class to clean; carries `archivedCycleCount`, `clearedPidFileCount`, `archivedBreakActive`, `warningCount`. Silent on clean boot. |
| `cycle_log_rotated` | [Invoke-CycleLogRotation](../test/modules/Test.Log.psm1) | Cycle-folder count crossed `CYCLE_HISTORY_LIMIT`; carries `historyFolder`, `moved`, `kept`. |
| `snapshot_missing` | [loadDiskSnapshot / recoverFromSnapshot](../test/modules/Test.SequenceHandler.psm1) | `Test-VMDiskSnapshot` returned $false; carries `vmName`, `snapshotId`, `handler`. |
| `snapshot_manifest_missing` | snapshot handlers | Manifest sidecar (R-6) absent — legacy snapshot; warn-only. |
| `snapshot_manifest_mismatch` | snapshot handlers | Manifest present but `vmName`/`snapshotId`/`hostType` disagree — hard refuse. Carries `violations[]`. |
| `ssh_handshake_failed` | [Test.Ssh.Wait-SshReady](../test/modules/Test.Ssh.psm1) | All probes exhausted; carries `target`, `user`, `privateKey`, `attempts`, `lastError`. |
| `ocr_provider_unavailable` | [Test.OcrEngine](../test/modules/Test.OcrEngine.psm1) | A requested OCR provider isn't available on this platform; carries `provider`. |
| `ocr_provider_failed` | [Test.OcrEngine](../test/modules/Test.OcrEngine.psm1) | Provider call threw mid-OCR; carries `provider`, `imagePath`, `error`. |
| `vnc_reconnect_failed` | [Test.VncProvider.Repair-VncConnection](../test/modules/Test.VncProvider.psm1) | VNC re-handshake threw; carries `vmName`, `hostType`, `error`. |
| `perf_context_unavailable` | [Invoke-Sequence](../test/modules/Invoke-Sequence.psm1) | perf-context setup failed; carries `reason` (`sequence_read_failed`/`setup_failed`), `path`. |
| `last_failure_write_failed` | [Invoke-Sequence](../test/modules/Invoke-Sequence.psm1) | last_failure.json write failed; carries `path`, `error`. |
| `sidecar_write_failed` | [Invoke-Sequence](../test/modules/Invoke-Sequence.psm1), [Test.SequenceHandler](../test/modules/Test.SequenceHandler.psm1) | An action's sidecar write (current-action.json / break-active.json) exhausted retries; carries `file`, `path`, `attempts`, `error`. |
| `status_doc_corrupt` | [Test.Status](../test/modules/Test.Status.psm1) | status.json parse failed at cycle start; original moved to `.corrupt.<UTC>.json`. |
| `guest_diagnostic` | [Test.SequenceHandler.saveSystemDiagnostic](../test/modules/Test.SequenceHandler.psm1) | Capture-outcome breadcrumb; carries `success`, `mechanism`, `attempted[]`, `exitCode`, `bytes`, `skipped`. |
| `schema_violation` | [Send-CycleEventSafely](../test/modules/Test.Log.psm1) | An emit-site record failed the schema check; carries `badEvent` + `violations[]`. The bad event is preserved on the line that follows. |
| `ndjson_write_gap` | [Write-CycleNdjsonEvent](../test/modules/Test.Log.psm1) | The NDJSON append itself failed; gap-sentinel written to `cycle.events.gaps` carrying `droppedEvent`, `droppedAction`, `writeError`. |

The catalog is current as of 2026-05-29. New events MUST be added
here in the same commit that introduces them (CONTRIBUTING gate)
so a streaming consumer doesn't have to discover new event names
in production.

### Defining the schema-violation contract

When a record fails validation, Send-CycleEventSafely:

1. Logs a `Write-Warning` naming the bad fields + event type.
2. Emits a synthetic `schema_violation` event **before** the original
   record, carrying the violation list + the offending event's `event`
   name (the payload itself is NOT duplicated because the original
   record follows on the next line).
3. Writes the original record as-is. The original is NEVER rejected
   -- a cycle does not fail because its telemetry was malformed; a
   consumer that reads truncated telemetry would have a worse signal
   than one that reads the violation report alongside the bad record.

`Get-CycleEventSchemaDescriptor` exposes the live schema for
dashboards / CI / introspection tooling that wants to know the
required + typed contract without re-deriving it.

## Snapshot manifest sidecars

[Test.SnapshotManifest.psm1](../test/modules/Test.SnapshotManifest.psm1)
co-locates Yuruna-owned metadata next to every hypervisor-level
snapshot so a restore can refuse a snapshot it doesn't recognize.

### Defining the snapshot manifest

`saveDiskSnapshot` writes a JSON manifest at
`<runtimeDir>/snapshots/<vmName>__<snapshotId>.manifest.json`
immediately after the hypervisor confirms the save. Payload:

| Field            | Source                                                  |
| ---              | ---                                                     |
| `vmName`         | The VM the snapshot was taken on.                       |
| `snapshotId`     | Hypervisor-level id (Hyper-V checkpoint name, virsh snapshot name, UTM bundle name). |
| `hostType`       | Platform (host.windows.hyper-v, host.macos.utm, host.ubuntu.kvm). |
| `hostName`       | `[System.Net.Dns]::GetHostName()` for multi-host pools. |
| `takenAtUtc`     | ISO-8601 timestamp.                                     |
| `writerPid`      | PID that took the snapshot.                             |
| `cycleId`        | The cycle that took it (joined with NDJSON events).     |
| `runId`          | The runner spawn that took it.                          |
| `manifestVersion`| Schema version (1).                                     |

### Defining the snapshot restore contract

`loadDiskSnapshot` and `recoverFromSnapshot` call
`Test-SnapshotManifestMatch` between the existing-snapshot check
(M-5) and the actual `Restore-VMDiskSnapshot` call. Three outcomes:

* **`ok`** — manifest present + every field matches the requested
  `(VMName, SnapshotId, HostType)`. Restore proceeds.
* **`missing`** — no manifest. Warn-only: emit a
  `snapshot_manifest_missing` NDJSON event, proceed (legacy
  snapshots taken before R-6 don't have manifests).
* **`mismatch`** — manifest present but at least one field differs.
  HARD REFUSE: emit a `snapshot_manifest_mismatch` NDJSON event
  carrying the violation list, return `$false` from the handler.

The handler emits `failureClass=snapshot_restore_failed,
severity=hard` on a mismatch so the remediation dispatcher (R-4)
routes the operator straight to the snapshot subsystem.

## Image-integrity gateway

[Yuruna.Image.psm1](../host/modules/Yuruna.Image.psm1) generalises
the warn-only SHA-256 verification policy that H-8 wired into the
Ubuntu live-server ISOs.

### Defining Save-ImageWithChecksum

`Save-ImageWithChecksum -SourceUrl <url> -DestPath <path>
[-ExpectedSha256 <hex>] [-ChecksumUrl <url>]
[-ChecksumTargetFileName <name>] [-ChecksumPattern <regex>]
[-OnMismatch <policy>]`

Behavior:

1. Routes the download through `Save-CachedHttpUri` when available
   (squid bump + per-process custom CA trust) and falls back to a
   direct `Invoke-WebRequest`.
2. Computes SHA-256 of the downloaded file.
3. Compares against `-ExpectedSha256` directly OR by parsing a
   publisher checksum file at `-ChecksumUrl` (default pattern
   matches the conventional `<sha256>  <filename>` layout used by
   the cloud-images mirrors).

Policy via `-OnMismatch`:

* **`WarnAndContinue`** *(default)* — emit a visual banner
  `Write-Warning`, keep the file. Matches the H-8 user policy.
* **`WarnAndDelete`** — emit banner + delete the file.
* **`Throw`** — emit banner + throw an exception.

A missing checksum (no `-ExpectedSha256`, no `-ChecksumUrl`, or the
checksum file doesn't list the target filename) is silent-pass:
the publisher chose not to publish, so it isn't Yuruna's call to
block. Same shape as `Test-UbuntuServerImageChecksum` in
[Yuruna.UbuntuImage.psm1](../host/modules/Yuruna.UbuntuImage.psm1)
which keeps the codename resolver on top of this gateway.

## Log rotation

[Test.LogRotation.psm1](../test/modules/Test.LogRotation.psm1) is
the general-purpose byte-bounded rotation primitive for the
`Add-Content`-style append-only files outside the per-cycle log
folder (which has its own rotation via H-9's
`Invoke-CycleLogRotation`).

### Defining the log-rotation policy

* `LOG_BYTE_LIMIT = 1 MB` — threshold for rotation
* `LOG_FILE_KEEP = 10` — number of `.1 .. .10` archives retained

Both are code constants by design (matches `FailurePauseMaxSeconds` /
`CycleHistoryLimit` patterns); an operator greps + tunes without a
config-schema migration.

`Invoke-LogRotation -Path <file>` is throttled per-path via
`Test-LogRotationDue` (60 s window) so a tight write loop doesn't
pay a `Get-Item` on every emit. When the size threshold is crossed:

```
events.log         -> events.log.1
events.log.1       -> events.log.2
...
events.log.9       -> events.log.10
events.log.10      -> (dropped)
```

Currently wired into `Write-VaultEvent` in the authentication
extension. Other future `Add-Content` paths adopt the helper with
one `Invoke-LogRotation -Path $logPath -Confirm:$false` call before
each append.

## Runner state machine

[Test.RunnerState.psm1](../test/modules/Test.RunnerState.psm1) gives
the outer runner's lifecycle an explicit observable shape so a
watchdog / dashboard / autonomous loop doesn't have to reconstruct
"what is the runner doing right now" from heartbeat mtimes, pidfile
presence, and cycle-folder existence. Each transition is atomically
written to `<runtimeDir>/runner.state.json` AND emitted as a
schema-validated `runner_state_transition` NDJSON event.

### Defining the runner-state enum

| State          | Meaning                                                            |
| ---            | ---                                                                |
| `idle`         | Runner alive and ready for the next cycle.                         |
| `cycle-start`  | A new cycle is starting; pre-spawn work in flight.                 |
| `in-cycle`     | Inner runner is executing steps.                                   |
| `cycle-end`    | Inner exited 0; outer is in post-cycle cleanup.                    |
| `fault`        | Inner exited non-zero or crashed before exit.                      |
| `paused`       | Failure-pause loop waiting for new commit / cap elapsed.           |

### Defining the valid transitions

```
idle        -> cycle-start, fault   (fault only from boot recovery)
cycle-start -> in-cycle, fault, paused
in-cycle    -> cycle-end, fault
cycle-end   -> idle
fault       -> paused, idle
paused      -> idle, cycle-start
```

The `cycle-start <-> paused` pair is the healthy pool-hold loop
(`desiredState=paused` gates a started cycle; each ~30s re-poll
re-enters `cycle-start`).

`Test-RunnerStateTransition` is the predicate. An out-of-band write
(e.g. an extension that ships its own state pump) that goes through
`Set-RunnerState` with a pair outside the adjacency map is logged as
`Write-Warning` but recorded anyway -- the validator's purpose is
to surface drift, never to lose telemetry. The schema validator
(R-7) ALSO enforces that `fromState` and `toState` values are in
the canonical enum.

### Defining the boot-time fault synthesis

`Initialize-RunnerState` reads the prior `runner.state.json` at outer
startup. If the prior `current` is not `idle` AND the prior `runId`
differs from the new outer's, the previous runner crashed mid-
lifecycle. The startup emits TWO synthetic transitions on the NDJSON
stream:

1. `<prior-state> -> fault`  (the crash boundary)
2. `fault -> idle`           (the boot recovery resolution)

A downstream consumer that follows the stream therefore sees the
crash as a discrete event pair rather than a silent gap. Pairs with
R-5's filesystem-level boot recovery: filesystem artifacts get
archived; the state machine narrates the semantic recovery.

### Defining the runner.state.json shape

```
{
  "current":   "<state>",
  "since":     "<ISO-8601 UTC>",
  "runId":     "<GUID>",
  "writerPid": <int>,
  "lastCycleId":     "<ISO-8601 UTC>",
  "lastCycleNumber": <int>,
  "history": [
    { "from": "<state>", "to": "<state>", "at": "<UTC>", "reason": "<text>" },
    ...
  ]
}
```

`history` is capped at the last 20 transitions; the canonical
history is the cycle.events.ndjson stream.

## Cycle remediation dispatcher

[Test.Remediation.psm1](../test/modules/Test.Remediation.psm1) routes a
recorded failure to a recovery handler based on its `failureClass`.
The FailureClass enum has been the routing key on the wire since
schema v2 of `last_failure.json`; the dispatcher closes the loop by
giving the routing key something to dispatch *to*.

### Defining the remediation dispatcher contract

`Invoke-Remediation` reads `last_failure.json` (or accepts an inline
hashtable) and returns a recommendation:

```
@{
  FailureClass   = '<one of the FailureClass enum>'
  Severity       = '<hard|soft|unknown>'
  Recommendation = '<one of the recommendation enum>'
  Actions        = [string[]]   # ordered ops the caller should run
  Rationale      = '<short human-readable>'
  HandledBy      = '<handler identifier>'
  AutoApply      = $false       # advisory by design (today)
  Source         = '<path or "(inline)">'
}
```

The **Recommendation enum** is a small finite set so a streaming
consumer can pivot without free-text matching:

`retry_immediately`, `retry_with_backoff`, `restart_from_snapshot`,
`reconnect`, `pause_and_inspect`, `operator_intervention_required`,
`escalate`.

Built-in handlers cover every value in the FailureClass enum so
`last_failure.json` is never observed without a routing target. The
handlers are **advisory** today: they return what to do, not what was
done. A future iteration can flip individual handlers to active mode
(calling Repair-VncConnection / Wait-SshReady / Restore-VMDiskSnapshot
directly) when the autonomous loop's blast radius is bounded.

`Register-RecoveryHandler` lets external modules override or extend a
class -- last-writer-wins, so loading a project-specific
Test.Remediation.<area>.psm1 can replace the default for any class.
The registry appears in `Get-YurunaRegistryDirectory` alongside
SequenceAction / HostIO / OcrProvider / Remediation.

Every dispatch emits a `remediation_recommended` NDJSON event
(failureClass, severity, recommendation, handledBy, autoApply, vmName,
guestKey, hostType, actionVerb, source) so a stream consumer follows
the dispatcher's decision without reading the recommendation object
back from memory.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.17

Back to [Yuruna](../README.md)
