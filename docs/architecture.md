# Yuruna Architecture

Cross-cutting concepts referenced by every README. Other docs link here
rather than repeat.

## Three capabilities

1. **Reproducible host/guest VM setups** — provision development
   workspaces as VMs on macOS UTM, Windows Hyper-V, or Ubuntu
   KVM/libvirt. See [Hosts](../host/README.md) and
   [Guests](../guest/README.md).
2. **Kubernetes deployment** — three-phase model targeting localhost,
   AWS, or Azure with the same project layout (GCP is planned, not yet
   available). See
   [Kubernetes Deployment](kubernetes.md).
3. **Test harness** — continuous VM creation + validation across hosts
   and guests, with status server, notifications, and extensible
   sequences. See [Test harness](test-harness.md).

## Three-phase deployment model

```
┌───────────┐    ┌────────────┐    ┌───────────┐
│ Resources │ => │ Components │ => │ Workloads │
│(OpenTofu) │    │  (Docker)  │    │  (Helm)   │
└───────────┘    └────────────┘    └───────────┘
```

Each phase reads its YAML from `config/<cloud>/` and passes outputs to the
next:

| Phase | File | Purpose |
|-------|------|---------|
| Resources  | `resources.yml`  | Provision clusters, registries, IPs |
| Components | `components.yml` | Build and push Docker images |
| Workloads  | `workloads.yml`  | Deploy Helm charts |

## CLI entry points

Run any of these from a project folder under `project/` (after
`./Add-AutomationToPath.ps1`):

```
Set-Resource.ps1  [project_root] [config_subfolder] [options]
Set-Component.ps1 [project_root] [config_subfolder] [options]
Set-Workload.ps1  [project_root] [config_subfolder] [options]
Invoke-Clear.ps1  [project_root] [config_subfolder]
Test-Configuration.ps1
Test-Requirement.ps1
Test-Runtime.ps1
```

- `Set-Resource.ps1` — `tofu apply` in the configured work folder.
- `Set-Component.ps1` — build and push images to the registry.
- `Set-Workload.ps1` — `helm install` in the configured work folder.
- `Invoke-Clear.ps1` — `tofu destroy` in the configured work folder; see
  [cleanup](cleanup.md).
- `Test-Configuration.ps1` — validate configuration files.
- `Test-Requirement.ps1` — check required tools and versions.

`config_subfolder` selects the cloud: `localhost`, `aws`, or `azure`
(`gcp` is planned, not yet available). Cloud variants require
a one-time auth step (`az login`, `aws configure`, `gcloud auth …`) — see
[Yuruna Authentication](authentication.md). Which streams reach the
console is set by `-logLevel`: [Yuruna Log Levels](loglevels.md).

## Project layout

```
yuruna/
├── automation/         # Set-*, Test-*, Invoke-*, Get-* scripts and Yuruna.*.psm1 modules
├── global/resources/   # OpenTofu templates per cloud
├── install/            # Per-host installer entry points (curl|bash, irm|iex)
├── project/            # Project under verification (cloned from test.config.yml's repositories.projectUrl each cycle)
├── docs/               # User-facing documentation
├── host/               # Per-hypervisor VM provisioning (macos.utm, windows.hyper-v, ubuntu.kvm)
├── guest/              # Workload scripts run inside a running guest
└── test/               # Continuous test harness
```

- A `.yuruna` folder is created under `project_root` for temporary files.

## Reusable conventions

### `YurunaCacheContent` cache-buster

One-liners (`irm …$nc | iex`, `fetch-and-execute.sh`) read
`YurunaCacheContent`. Unset → cacheable URL. Set to a unique string
(typically a datetime) → fresh fetch. Full setup, persistence (`setx`,
shell profiles), and the companion Squid VM:
[Caching](caching.md).

### Cost warning

Cloud resources incur charges. Always [cleanup](cleanup.md) what
you stop using.

### Windows line endings

Before cloning on Windows:
`git config --global core.autocrlf input`

### Per-phase `*.stderr.log` catalog

Each automation phase writes a full stdout+stderr capture of its tool
calls into `.yuruna/<env>/...` with a `=== <cmd> (exit=N) ===` header,
plus a `*.rc` sidecar holding the LAST observed exit code:

| File | Producer | Captures |
|------|----------|----------|
| `tofu.stderr.log`    | Yuruna.Resource.psm1 (`Set-Resource`)           | `tofu init / plan / apply` |
| `helm.stderr.log`    | Yuruna.Workload.psm1                            | Chart install + ad-hoc `helm:` deployments |
| `kubectl.stderr.log` | Yuruna.Workload.psm1                            | `kubectl:` deployments |
| `shell.stderr.log`   | Yuruna.Workload.psm1                            | `shell:` deployments |
| `docker.stderr.log`  | Yuruna.Component.psm1                           | Build / tag / push pipeline |

`Get-SystemDiagnostic.ps1` cross-checks `*.rc` against in-cluster
state to flag a silent success-without-effect (e.g. `helm.rc=0` but
no helm releases). The scan uses `-Force` so recursion descends into
the dot-prefixed `.yuruna/` working folders; without `-Force`,
helm/kubectl stderr files are hidden on Linux and a real failure
shows as "no `*.stderr.log` — no phase has produced output" even when
a 60-char-truncated excerpt of the error sits in the earlier "Errors,
failures and warnings" section.

### Atomic resource work-folder staging

`Set-Resource` (Yuruna.Resource.psm1) never edits a live resource work
folder in place. The template refresh is staged into a sibling
directory and swapped atomically:

1. Stage the template plus any carry-over tofu state (`.terraform/`,
   `.terraform.lock.hcl`, `tofu.planfile`) into `<workFolder>.new`.
2. `live -> <name>.old`
3. `.new -> live`
4. `.old -> trash`

A failure of step 3 rolls `.old` back to live, so a cycle never
observes a half-applied template. A `.workfolder.complete` marker is
written immediately after the swap so a downstream consumer can verify
the staging finished. Every copy runs with `-ErrorAction Stop`: a
permission blip, AV lock, or `templateFolder` typo aborts the resource
loudly instead of silently producing an empty work folder.

This guards against the tofu silent-cascade trap — `tofu output -json`
returning `{}`, which yields an empty `resources.output.yml` and then
malformed helm image references. See
`feedback_tofu_null_resource_provisioner_silent_cascade.md`.

**SIGKILL recovery.** The rollback above is a PowerShell `catch`, so it
only runs when `Move-Item` itself throws. A process kill (watchdog
SIGTERM/SIGKILL, host shutdown, BSOD) landing between the two moves
leaves only `<workFolder>.old` on disk and the `catch` never runs.
Without an explicit guard the staging branch would then see
`Test-Path $workFolderRoot == $false`, skip the `.terraform/` and
`tofu.planfile` carry-over, and the next `tofu apply` would run against
a freshly created folder with no provider state — usually destroying
actual cloud resources. `Set-Resource` detects that signature (no live
folder, `.old` present) and restores before any other staging step
runs.

### Shared transient-failure retry policy

One classifier and one backoff policy cover every network-touching tool
call across the three phases. Both live in Yuruna.Retry.psm1 and are
mirrored on the guest side by
[automation/yuruna-retry.sh](../automation/yuruna-retry.sh) — see
[Defining yuruna retry lib](network.md#defining-yuruna-retry-lib).

**Defaults:** 5 attempts, 10s initial delay, `*= 2` backoff, ±25%
jitter, 300s cap. This widens the retry window past github.com's
typical 5xx blip so a transient provider download no longer fails the
cycle.

**The classifier** is the single source of truth for "is this failure
worth retrying?" across `tofu init/plan/apply/output` and helm/kubectl
fetches. A deterministic config, plan, auth, or NotFound error does
*not* match, so callers gating on it fail fast instead of spending the
whole backoff budget on an error that will never clear. It matches:

- **Network blips** — `failed to fetch`, `i/o timeout`, `no such host`,
  connection refused/reset, `client.timeout`, `TLS handshake`,
  `temporary failure`, `EOF`, HTTP 429/500/502/503/504, `too many
  requests`.
- **Backend locks** — tofu remote-state contention (`Error acquiring
  the state lock`, DynamoDB `ConditionalCheckFailedException`).

A bare `500` sits alongside the gateway 5xx codes because the read-only
manifest and chart fetches gated here (helm, `kubectl -f <URL>`, tofu
provider/registry GETs) hit upstream CDNs and registries — GitHub
release assets in particular return transient bare 500s that clear on
retry. A genuinely deterministic 500 just burns the backoff budget and
then fails, the same as any other code in the list, so including it
costs at most one backoff cycle.

**Per-phase gating:**

| Phase | Retried | Never retried |
|-------|---------|---------------|
| `tofu init` | Provider/registry download failures. `TF_PLUGIN_CACHE_DIR` makes every later attempt and every later cycle read the already-fetched plugin from disk instead of redownloading. | — |
| `tofu plan` / saved-planfile `apply` | Both are safe to re-run: plan is read-only, and a saved-planfile apply re-applies the same plan. | The refreshing-apply fallback (no planfile on disk) recomputes the plan, so a retry after a partial apply is not safely idempotent and must fail loudly. |
| helm / kubectl | `helm repo update`, `helm install <repo>/<chart>`, and `kubectl -f <URL>` cross the network and stutter on shared-egress rate limits or proxy blips. | Chart not found, schema violation, auth, `NotFound`/`Invalid` for kubectl — and every `shell:` deployment step. |

Representative helm/kubectl symptoms:

```
Error: INSTALLATION FAILED: failed to fetch https://...
error: unable to read URL "https://github.com/...", server
 reported 502 Bad Gateway, status code=502
```

Multiple hosts sharing one squid egress IP can fail inside a
sub-second window — that is a shared upstream event, not per-host
configuration.

## License

Scripts and examples are provided "as is". See [Yuruna License](../LICENSE.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.22

Back to [Yuruna](../README.md)
