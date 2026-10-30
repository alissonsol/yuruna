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

Deployment values are serialized as YAML for Helm and as `terraform.tfvars.json`
for OpenTofu. The resource writer removes its obsolete `terraform.tfvars` file;
quotes, backslashes, newlines, and Unicode survive serialization. Workload helpers
restore the caller's working directory even when a tool or log write throws.

Deployment secrets are published to the environment and expanded into tool command
strings, so every phase logs through one redaction rule: `Protect-YurunaSecretText`
in `automation/Yuruna.Retry.psm1` replaces the value of every environment variable
whose name contains password, passwd, passphrase, secret, token, credential, api key,
private key or access key with `<redacted>`. It covers the retry log headers and
captured output, the retry events, the console lines and the result manifest of the
workload and component phases. Values shorter than four characters and the literals
true, false, null, none, yes and no are left alone. The standalone system diagnostic
applies the same name rule to the tool logs it prints.

The test coordinator and workers select the highest installed Pester 6.x version.
A host without a 6.x copy is rejected before running suites; the baseline
records the Pester version of the full run that produced it. UTF-8 directory
scans include nested text files and reject an empty requested text root.

Host-process shutdown verifies the captured process identity and confirms exit
before deleting the service marker. A permission failure, reused PID, uncertain
liveness, or marker-deletion failure leaves the stop unconfirmed.

Prometheus retention updates use the sibling `prometheus.yml.yuruna.lock` through
validation, installation, reload, and rollback. Every writer must honor this
advisory lock. A failed reload restores only the candidate still owned by that
transaction; a detected foreign edit and the backup are preserved for diagnosis.
POSIX rename cannot provide a compare-and-swap against writers that ignore the
lock. Failure to delete a backup after an acknowledged reload does not undo the
successful update.


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
`== <cmd> (exit=N) ==` header, and a `*.rc` sidecar holding the last
observed exit code -- so a post-mortem never depends on the transcript
surviving the run. `Get-SystemDiagnostic.ps1` is the consumer: it cross-checks
each `*.rc` against in-cluster state to flag a silent success-without-effect
(`helm.rc=0` but no helm releases).

Per-phase paths, the producer of each pair, and how the diagnostic reads them:
[the sidecar contract](design/03-data-flows.md#the-stderrlog--rc-sidecar-contract).

<a id="42e568c8-000b"></a>

### Atomic resource work-folder staging

`Set-Resource` (Yuruna.Resource.psm1) never edits a live resource work folder
in place. It copies the template to `<workFolder>.new`, carries the existing
`.terraform`, lock file, plan file and `*.tfstate*` files into that staging
directory, then moves the live folder to `<workFolder>.old` and moves `.new`
into place. It writes `.workfolder.complete` only after the swap. At the start
of the next run, it restores `.old` if a process kill left the live path absent.

Three properties are load-bearing:

- **Rollback on a failed swap** -- if the `.new -> live` move throws, `.old`
  goes back to live.
- **`-ErrorAction Stop` on every copy** -- a permission blip, AV lock or
  `templateFolder` typo must abort the resource loudly rather than silently
  produce an empty work folder, which is the entry to the tofu silent-cascade
  trap. See
  [why the phase fails fast on empty tofu outputs](memory.md#why-set-resource-fails-fast-on-empty-tofu-outputs).
- **SIGKILL recovery ahead of every other staging step** -- the rollback is a
  PowerShell `catch`, so it only fires when `Move-Item` throws. A process kill
  between the two moves leaves only `<workFolder>.old`; without the guard the
  next `tofu apply` runs against a folder with no provider state and usually
  destroys live cloud resources. `yuruna clear` makes the same recovery before
  its destroy, so a clear after such a kill destroys from the state in `.old`
  instead of finding no folder and leaving the resources running.

A folder that was initialized before -- a second run after a pass, or a run
after a failure -- is initialized again: `tofu init` is idempotent, the plan is
read-only, and the apply changes only what differs from the carried-over
state. Refusing it and advising a clear first would destroy the resources it
found.

`runId` in `globalVariables` is the configuration's identity: the examples draw
it at random, and the resource names carry it, so one drawn again at every run
would make a second run create a second set of resources beside the first. Once a run
has recorded it in `resources.output.yml`, later runs keep that value instead
of expanding the expression again; deleting the recorded file after a clear
starts a configuration with a new one.

<a id="42e568c8-000c"></a>

### Shared transient-failure retry policy

The shared backoff policy covers the retried calls across the three phases.
The transient-failure classifier gates only the calls described below.
Both live in Yuruna.Retry.psm1 and are
mirrored on the guest side by
[automation/yuruna-retry.sh](../automation/yuruna-retry.sh) -- see
[Defining yuruna retry lib](network.md#defining-yuruna-retry-lib).

**Defaults:** 5 attempts, 10s initial delay, `*= 2` backoff, +/-25%
jitter, 300s cap. That window reaches past github.com's typical 5xx blip,
so a transient provider download does not fail the cycle. `tofu init` takes
6 attempts unless `YURUNA_RETRY_MAX_ATTEMPTS` sets the count: it is the call
that must reach the provider registry, and an attempt that cannot reach it
fails within seconds on OpenTofu's own client timeout, so five attempts span
only about four minutes. Six span about seven, which outlasts a registry that
stays unreachable through the caching proxy for five minutes.

**The classifier** decides whether a failed `tofu plan`, saved-planfile
`apply`, `tofu output`, chart install (`helm upgrade --install --atomic`),
component image build, or supported helm/kubectl fetch warrants another attempt. `tofu init` uses the same backoff but retries any non-zero exit;
it has no classifier predicate. For classifier-gated calls, a deterministic
config, plan, auth, or NotFound error does *not* match, so those calls fail
fast instead of spending the whole backoff budget. The classifier matches:

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
manifest and chart fetches gated here (helm, `kubectl -f <URL>`) hit upstream
CDNs and registries -- GitHub
release assets in particular return transient bare 500s that clear on
retry. A genuinely deterministic 500 burns the backoff budget and then
fails, like any other code in the list, so including it costs at most one
backoff cycle.

**Per-phase gating:** `tofu init` retries every non-zero exit under the shared
backoff. `tofu plan`, saved-planfile `apply`, and `tofu output` retry only
classifier matches. The refreshing-apply fallback is not retried because it
recomputes the plan. `helm repo update`, `helm install <repo>/<chart>` and
`kubectl -f <URL>` retry classifier matches, as does the chart install, which
`--atomic` has rolled back before the next attempt; `shell` deployments do not
retry. A component's image build retries classifier matches when its
`buildRetry` allows more than one attempt; the default is one, and the matched
text is the end of the failed attempt's output, where docker prints the error
that stopped the build. Why the resource phase is shaped that way:
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

<a id="42e568c8-000f"></a>

### Deploy tool call bounds

Every tool call the three phases and `yuruna clear` make that can wait on a
service -- `tofu`, `helm`, a `kubectl`, `helm` or `shell` deployment, the Azure
CLI subscription lookup and the image probe of the
[deploy phase ledger](#42e568c8-0010) -- runs under a deadline
(`Invoke-YurunaToolWithDeadline`, and `Invoke-WithYurunaRetry -TimeoutSeconds`
for a retried call, in Yuruna.Retry.psm1). The `kubectl config` calls that read
and switch kubeconfig contexts stay unbounded: they never contact a cluster. At the deadline the
process tree the call started is killed, the call reports exit code 124, its
log section ends with a line saying it was stopped, and the phase ends with the
`tool_timeout` failure class, which the host routes as `wait_timeout`, the class
a hang the step watchdog kills has. The component phase's commands run under
the same kind of bound already (`commandTimeoutSeconds`).

The call still runs in the phase's own process, so its output, its environment
changes and a project's PowerShell `shell` deployments behave as before; only
external processes can be stopped. A stopped call's outcome is unknown -- the
tool may have acted before it was killed -- so it is a failure even when the
killed tool exits 0. A stopped `tofu init` is retried like any other failed
init; the classifier never matches the stopped line, so a classifier-gated call
is not retried after a stop.

Built-in bounds, in seconds: `tofu init` 600, `plan` 3600, `apply` 3600,
`output` 300, `destroy` 3600; `helm lint` 300, `status` 300, `rollback` 600,
`uninstall` 600, `upgrade --install` 1800; a `kubectl`, `helm` or `shell`
deployment 1800; `az account show` 120; the image probe 60. Each is well past
the call's normal duration. A project replaces them with
`commandTimeoutSeconds`, an integer from 1 through 3600 on a resource or
deployment entry, or in the file's `globalVariables`, which bounds every call
made for that entry, as it does for a component.

<a id="42e568c8-0010"></a>

### Deploy phase ledger

The three phases run as three processes (`Set-Resource`, `Set-Component`,
`Set-Workload`), so a deployment script run again after its workloads phase
failed would provision and rebuild everything before it reached the phase that
failed. `.yuruna/<config>/deploy-ledger.json`
([Yuruna.DeployLedger.psm1](../automation/Yuruna.DeployLedger.psm1)) records
each phase's outcome, and a phase that passed is skipped, with a passing result
that has `skipped` set, only when all of these hold:

- A later phase failed after it passed. A run with no failure behind it runs
  every phase as before, and a first run has no ledger.
- The SHA-256 of its inputs is the one it passed with. The resources phase
  hashes `resources.yml` and the project and framework template folders; the
  components phase hashes `components.yml`, `resources.output.yml` and the
  project's `components` folder. A phase that writes into its own inputs
  changes their hash, and runs again.
- Its outputs are still in place: the same `resources.output.yml`, and each
  resource's completed work folder with its state; for components, every image
  the pass pushed still answers by digest in its registry (`docker manifest
  inspect`, with the image read from the `docker push` output). A push through
  another tool records no image, and that phase always runs.
- It has not been skipped already since it passed. A retry that skipped phases
  and failed again forgets them, so an output no check can see costs one retry,
  never a loop.

The workloads phase always runs, and its pass deletes the ledger. Deleting the
file runs every phase again. The ledger only saves work: one that cannot be
read is ignored, a failure to write it leaves every phase to run, and inputs
over 20,000 files or 512 MB are not hashed, so that phase always runs.

<a id="42e568c8-000d"></a>

## Service VM memory budget

Each service guest (cache, stash, download agent, and the rest of the
always-on pool) is sized in its own per-host `New-VM.ps1` builder and
nowhere else. Every hypervisor pins that size rather than letting the guest
grow into it -- the UTM guests carry no balloon driver, Hyper-V builds them
with `DynamicMemoryEnabled $false`, and virt-install is given a flat
`--memory`. A configured size is therefore a commitment from the moment the
VM runs, not a ceiling, and the sum of the service guests' sizes is knowable
before the first one is built.

A hypervisor's own resident set runs larger than the guest memory it was
configured with -- the device model, the framebuffer, and the accelerator's
page tables are host-side costs on top of the guest's own RAM. Measured
across a three-guest service set, 20.0 GB of configured guest memory held
24.7 GB resident, and a single 12 GB guest held 15.2 GB; both land about a
quarter over the configured size, which is the origin of the ~1.24 overhead
factor used when budgeting host capacity for the service fleet.

What has to be left over once the service guests are resident is memory for
the host operating system, the hypervisor's own process, and the harness
driving the run. A calibration run that left 7.3 GB free still had to hold
about 1.9 GB of that in its memory compressor to stay up, which counts as
already under reclaim pressure rather than comfortable -- so the reserve is
rounded up from that measured point rather than down. The reserve is a fixed
8 GB rather than a fraction of installed memory: what a host needs for
itself is roughly constant regardless of its size, so a fraction would let a
large machine skate under the floor a small one is held to, and would grow
tighter, not looser, as machines get bigger.

<a id="42e568c8-000e"></a>

## License

Scripts and examples are provided "as is". See [Yuruna License](../LICENSE.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.10.30

Back to [Yuruna](../README.md)
