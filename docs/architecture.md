<a id="42e568c8-0001"></a>

# Yuruna Architecture

Cross-cutting concepts every other doc links to rather than repeats.

<a id="42e568c8-0002"></a>

## Three capabilities

1. **Reproducible host/guest VM setups** -- provision development
   workspaces as VMs on macOS UTM, Windows Hyper-V, or Ubuntu
   KVM/libvirt. See [Hosts](../host/README.md) and
   [Guests](../guest/README.md).
2. **Kubernetes deployment** -- three-phase model targeting localhost,
   AWS, or Azure with the same project layout (GCP is planned, not yet
   available). See
   [Kubernetes Deployment](kubernetes.md).
3. **Test harness** -- continuous VM creation + validation across hosts
   and guests, with status service, notifications, and extensible
   sequences. See [Test harness](test-harness.md).

<a id="42e568c8-0003"></a>

## Three-phase deployment model

```
+-----------+    +------------+    +-----------+
| Resources | => | Components | => | Workloads |
|(OpenTofu) |    |  (Docker)  |    |  (Helm)   |
+-----------+    +------------+    +-----------+
```

Each phase reads its YAML from `config/<cloud>/` and passes outputs to the
next:

| Phase | File | Purpose |
|-------|------|---------|
| Resources  | `resources.yml`  | Provision clusters, registries, IPs |
| Components | `components.yml` | Build and push Docker images |
| Workloads  | `workloads.yml`  | Deploy Helm charts |

<a id="42e568c8-0004"></a>

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

- `Set-Resource.ps1` -- `tofu apply` in the configured work folder.
- `Set-Component.ps1` -- build and push images to the registry.
- `Set-Workload.ps1` -- `helm install` in the configured work folder.
- `Invoke-Clear.ps1` -- `tofu destroy` in the configured work folder; see
  [cleanup](kubernetes.md#cleaning-up-cloud-resources).
- `Test-Configuration.ps1` -- validate configuration files.
- `Test-Requirement.ps1` -- check required tools and versions.

`config_subfolder` selects the cloud: `localhost`, `aws`, or `azure`
(`gcp` is planned). Cloud variants require a one-time auth step
(`az login`, `aws configure`, `gcloud auth ...`) -- see
[Yuruna Authentication](authentication.md). Which streams reach the
console is set by `-logLevel`: [Yuruna Log Levels](loglevels.md).

<a id="42e568c8-0005"></a>

## Project layout

```
yuruna/
+-- automation/         # Set-*, Test-*, Invoke-*, Get-* scripts and Yuruna.*.psm1 modules
+-- global/resources/   # OpenTofu templates per cloud
+-- install/            # Per-host installer entry points (curl|bash, irm|iex)
+-- project/            # Project under verification (cloned from test.config.yml's repositories.projectUrl each cycle)
+-- docs/               # User-facing documentation
+-- host/               # Per-hypervisor VM provisioning (macos.utm, windows.hyper-v, ubuntu.kvm)
+-- guest/              # Workload scripts run inside a running guest
+-- test/               # Continuous test harness
```

- A `.yuruna` folder is created under `project_root` for temporary files.

Directories are not system blocks, and several of these do
not line up with one -- `automation/` is a shared library root rather than only
the deploy engine, and `project/` is re-cloned every cycle rather than tracked.
[Context and components](design/01-context-and-components.md) draws the blocks
and names every place the boundaries diverge.

<a id="42e568c8-0006"></a>

## Reusable conventions

<a id="42e568c8-0007"></a>

### `YurunaCacheContent` cache-buster

One-liners (`irm ...$nc | iex`, `fetch-and-execute.sh`) read
`YurunaCacheContent`. Unset -> cacheable URL. Set to a unique string
(typically a datetime) -> fresh fetch. Full setup, persistence (`setx`,
shell profiles), and the companion Squid VM:
[Caching](caching.md).

<a id="42e568c8-0008"></a>

### Cost warning

Cloud resources incur charges. Always [clean up](kubernetes.md#cleaning-up-cloud-resources) what
you stop using.

<a id="42e568c8-0009"></a>

### Windows line endings

Before cloning on Windows:
`git config --global core.autocrlf input`

<a id="42e568c8-000a"></a>

### Per-phase `*.stderr.log` catalog

Every phase captures its tool calls to a stable pair of paths under
`.yuruna/<cloud>/...` -- a `*.stderr.log` holding full stdout+stderr with a
`=== <cmd> (exit=N) ===` header, and a `*.rc` sidecar holding the last
observed exit code -- so a post-mortem never depends on the transcript
surviving the run. `Get-SystemDiagnostic.ps1` is the consumer: it cross-checks
each `*.rc` against in-cluster state to flag a silent success-without-effect
(`helm.rc=0` but no helm releases).

Per-phase paths, the producer of each pair, and how the diagnostic reads them:
[the sidecar contract](design/03-data-flows.md#the-stderrlog--rc-sidecar-contract).

<a id="42e568c8-000b"></a>

### Atomic resource work-folder staging

`Set-Resource` (Yuruna.Resource.psm1) never edits a live resource work folder
in place. The template refresh is staged into a sibling directory, swapped in
with two `Move-Item` calls, and marked complete last, so no cycle can observe
a half-applied template. The swap order, the carried-over tofu state, the
`.workfolder.complete` marker and the SIGKILL-recovery guard are spelled out
in [Data flows -- three-phase deployment](design/03-data-flows.md#a-three-phase-deployment).

Three properties are load-bearing:

- **Rollback on a failed swap** -- if the `.new -> live` move throws, `.old`
  goes back to live.
- **`-ErrorAction Stop` on every copy** -- a permission blip, AV lock or
  `templateFolder` typo must abort the resource loudly rather than silently
  produce an empty work folder, which is the entry to the tofu silent-cascade
  trap. See
  [why the phase fails fast on empty tofu outputs](memory.md#why-set-resource-fails-fast-on-empty-tofu-outputs)
  and `feedback_tofu_null_resource_provisioner_silent_cascade.md`.
- **SIGKILL recovery ahead of every other staging step** -- the rollback is a
  PowerShell `catch`, so it only fires when `Move-Item` throws. A process kill
  between the two moves leaves only `<workFolder>.old`; without the guard the
  next `tofu apply` runs against a folder with no provider state and usually
  destroys live cloud resources.

<a id="42e568c8-000c"></a>

### Shared transient-failure retry policy

One classifier and one backoff policy cover every network-touching tool
call across the three phases. Both live in Yuruna.Retry.psm1 and are
mirrored on the guest side by
[automation/yuruna-retry.sh](../automation/yuruna-retry.sh) -- see
[Defining yuruna retry lib](network.md#defining-yuruna-retry-lib).

**Defaults:** 5 attempts, 10s initial delay, `*= 2` backoff, +/-25%
jitter, 300s cap. That window reaches past github.com's typical 5xx blip,
so a transient provider download does not fail the cycle.

**The classifier** is the single source of truth for "is this failure
worth retrying?" across `tofu init/plan/apply/output` and helm/kubectl
fetches. A deterministic config, plan, auth, or NotFound error does
*not* match, so callers gating on it fail fast instead of spending the
whole backoff budget on an error that will never clear. It matches:

- **Network blips** -- `failed to fetch`, `i/o timeout`, `no such host`,
  `server misbehaving`, connection refused/reset, `client.timeout`,
  `TLS handshake`, `temporary failure`, `EOF`, HTTP 429/500/502/503/504,
  `too many requests`.
- **Backend locks** -- tofu remote-state contention (`Error acquiring
  the state lock`, DynamoDB `ConditionalCheckFailedException`).

A refused connection needs two spellings, not one. Go prints the errno form
(`connect: connection refused`); kubectl catches the same errno and reformats
it around the URL's host -- `The connection to the server <host> was refused -
did you specify the right host or port?` -- sharing no contiguous substring
with the first. A classifier carrying only the Go wording fails fast on
`kubectl -f <URL>`, which is one of the call sites gated below.

A bare `500` sits alongside the gateway 5xx codes because the read-only
manifest and chart fetches gated here (helm, `kubectl -f <URL>`, tofu
provider/registry GETs) hit upstream CDNs and registries -- GitHub
release assets in particular return transient bare 500s that clear on
retry. A genuinely deterministic 500 burns the backoff budget and then
fails, like any other code in the list, so including it costs at most one
backoff cycle.

**Per-phase gating:** matching the classifier is necessary but not sufficient
-- each call site also declares whether re-running it is *safe*. `tofu init`,
`tofu plan` and a saved-planfile `apply` are; the refreshing-apply fallback is
not, because it recomputes the plan. `helm repo update`,
`helm install <repo>/<chart>` and `kubectl -f <URL>` are retried; `chart` and
`shell` deployments never are. Which call site sits behind which gate:
[Data flows](design/03-data-flows.md#a-three-phase-deployment). Why the
resource phase is shaped that way:
[the saved planfile](memory.md#why-set-resource-uses-a-saved-planfile-for-apply),
[the init retry](memory.md#why-tofu-init-retries-before-failing) and
[the pre-seeded plugin cache](memory.md#why-set-resource-pre-seeds-tf_plugin_cache_dir)
that keeps a retried `init` off the network entirely.

Representative helm/kubectl symptoms:

```
Error: INSTALLATION FAILED: failed to fetch https://...
error: unable to read URL "https://github.com/...", server
 reported 502 Bad Gateway, status code=502
```

Multiple hosts sharing one Squid egress IP can fail inside a
sub-second window -- that is a shared upstream event, not per-host
configuration.

<a id="42e568c8-000d"></a>

## License

Scripts and examples are provided "as is". See [Yuruna License](../LICENSE.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.08

Back to [Yuruna](../README.md)
