# Yuruna Workarounds

Notes and workarounds learned during development.

**Log data from inside a VM** — copy/paste often works; when it doesn't,
<https://privatebin.at> handles >512 KB (like pastebin).

**Files marked `assume-unchanged`** — scripts set some files so local
edits don't surface to git. Revert with
`git update-index --really-refresh`.

**Docker registry names** — clouds need a unique name +
[FQDN](https://en.wikipedia.org/wiki/Fully_qualified_domain_name).
Changing the name may require edits to `config/<cloud>/components.yml`.

**Kubernetes context collisions** — keep multiple-cloud contexts
side-by-side with `kubectl config rename-context old-name new-name`.

**cert-manager debugging** —
[cert-manager FAQ](https://cert-manager.io/docs/faq/acme/); inspect
`certificaterequests` under Custom Resources. Wildcard certs need DNS01
(not HTTP01) — see
[challenge types](https://letsencrypt.org/docs/challenge-types/).

**Debugging from inside a minimal container** — most images ship
without `ping`:

```
apt-get update && apt-get install -y iputils-ping
```

Building outside the container with `dotnet restore` may need
[`nuget`](https://learn.microsoft.com/en-us/nuget/install-nuget-client-tools)
in PATH; sometimes `nuget restore <name>.proj` must run before
`dotnet restore <name>.proj`. Ingress debugging:
[kubernetes/ingress-nginx examples](https://github.com/kubernetes/ingress-nginx/tree/master/docs/examples/grpc).

**Docker Desktop recovery** — "Reset to factory defaults" under
Troubleshoot is the quickest fix. Afterwards remove `~/.kube` and
re-enable Kubernetes (loses some configuration).

For `docker-credential-desktop executable file not found in $PATH`:
in `~/.docker/config.json` rename `credsStore` → `credStore` (or remove
the entry, or install `osxkeychain`/`wincred`).

**Azure drops static IP when deleting its ingress** — confirmed
[here](https://stackoverflow.com/questions/66435282/how-to-make-azure-not-delete-public-ip-when-deleting-service-ingress-controlle).
The workaround has side-effects; prefer `clear` + rebuild of
resources/components/workloads.

**`Invoke-Expression: Cannot bind argument to parameter 'Command' because it is an empty string`**
— usually a shell expression that returned nothing; append `$true`.

**Edit a live service** — `kubectl edit svc <name> -n <ns>` (also
configMaps, pods, etc.); once you reach the desired state, encode it
as `kubectl patch` statements.

**Debugging localhost** — resetting Docker's Kubernetes cluster and
re-connecting contexts often helps. `automation/context-copy.ps1
-sourceContext <src> -destinationContext <dst>`; context names live in
`resources.output.yml`. See
[docker/for-mac#4903](https://github.com/docker/for-mac/issues/4903).

**PodSecurityPolicy** — `kubectl get psp -A` /
`kubectl delete psp <name>`.

**Ubuntu latest-point-release picker is a string sort, not a version
sort** — `Resolve-UbuntuServerStableImage` in
[`host/modules/Yuruna.UbuntuImage.psm1`](../host/modules/Yuruna.UbuntuImage.psm1)
(consumed by every per-guest `Get-Image.ps1` across Hyper-V, UTM and
KVM — noble + resolute) resolves the "latest stable" ISO by
regex-matching `ubuntu-[\d.]+-live-server-<arch>.iso` on the release
directory listing and then
`Sort-Object Value -Descending | Select-Object -First 1`. That is a
lexicographic sort on the filename, not a `[version]` comparison.
Today it works because Ubuntu LTS has historically capped at ~5 point
releases (`24.04.1` … `24.04.5`), so single-digit components sort
correctly. The sort would silently mis-rank if Ubuntu ever shipped a
`.10`+ point release: `ubuntu-24.04.10-...` sorts BEFORE `ubuntu-24.04.2-...`
(because `'1' < '2'`), so the picker would pin `24.04.9` and skip the
newer `.10`. Symptom in that scenario: `Selected stable ISO:
ubuntu-<NN>.04.9-live-server-<arch>.iso` even though releases.ubuntu.com
already serves `.10`. Fix when it bites: replace the string sort in
`Resolve-UbuntuServerStableImage` with a `[version]`-keyed sort, e.g.
`Sort-Object @{ Expression = { [version]([regex]::Match($_.Value, 'ubuntu-([\d.]+)-').Groups[1].Value) } } -Descending`,
or grab the version from `releases.ubuntu.com/<codename>/SHA256SUMS`
ordering. One edit in the shared module covers every per-guest caller.

## A detached grandchild pins the caller's pipe on Windows

Spawning a child pwsh with any std stream redirected (including
`& pwsh ... *> $null`)
turns handle inheritance ON for that child. `Invoke-StatusServiceBounce` in
[`test/modules/Test.HostConfigSync.psm1`](../test/modules/Test.HostConfigSync.psm1)
runs `Start-StatusService.ps1 -Restart` in a child pwsh, and the status
server it starts is a grandchild that outlives the bounce by design. With
inheritance on, that server inherits the write end of the caller's stdout
pipe and holds it open for its whole lifetime: the read never reaches EOF,
so the bounce blocks on the SERVER, not on the child that exited seconds
ago. The same redirection also swallows every progress line, so the symptom
is a silent, unbounded hang. Redirecting the child's own streams to files
does NOT close the hole — an inheritable pipe further up the ancestry (any
caller that captures our output) is passed down all the same.

The fix is to spawn with neither `-Redirect*` nor `-NoNewWindow`, which makes
PowerShell use `ShellExecute`; that passes no inheritable handles at all, so
nothing downstream can pin a pipe anywhere in the chain. The child writes its
own transcript with `Tee-Object` and the caller tails that file while it
waits. `-NonInteractive` goes on the child so a prompt fails fast instead of
blocking against a hidden window nobody can answer. Waiting must use
`Process.WaitForExit(ms)` on the child alone — `Start-Process -Wait` waits on
the whole descendant tree, which includes the status server, and reintroduces
the unbounded wait from the other direction.

Unix has no `ShellExecute`, but its detached server is `nohup`'d onto
`/dev/null` + `server.err` and cannot pin the caller's streams, so
redirecting the child's own streams to files there is safe and gives the same
live tail.

## Nested non-global import evicts a caller's view of a module

PowerShell keeps **one active version per module** in a session. When a
module is re-imported *without* `-Global` from inside another module, that
nested copy takes over the active-version slot and the original caller's
view of the exported functions disappears. The next call fails with
`The term '<Function>' is not recognized`.

The trap fires in both directions:

- **Caller loses its view.** `Initialize-YurunaHost` (from
  `test/modules/Test.HostContract.psm1`) cascades into
  `host/<host type>/modules/Yuruna.Host.psm1`, which nested-imports
  `test/modules/Test.CachingProxy.psm1` **without** `-Global`. Any script
  that imported `Test.CachingProxy` for itself loses
  `Read-CachingProxyState`, `Save-CachingProxyState`,
  `Invoke-CachingProxyProbe`, and `Get-CachingProxyStatePath` the moment
  `Initialize-YurunaHost` runs.
- **Foreign modules lose theirs.** A script `&`-invoked from a module
  context (the inner cycle runner calling `Remove-TestVMFiles.ps1`, or the
  status service calling into the host contract) that does a `-Force`
  import *without* `-Global` pulls the module out of the global table for
  every unrelated module, so a later contract call from `Invoke-Sequence`
  fails to resolve. This is the *legacy-eviction regression class*.

**The rule:** re-import with `-Global -Force` immediately **after** every
`Initialize-YurunaHost` call and before touching the affected exports, and
always pass `-Global` when a script that may be invoked from a module
context imports a shared module.

Sites that depend on this ordering: `test/Start-CachingProxy.ps1`,
`test/Stop-CachingProxy.ps1`, `test/Repair-CachingProxyForwarder.ps1`,
`test/Test-CachingProxy.ps1`, `test/Start-StatusService.ps1`,
`test/Remove-TestVMFiles.ps1`, `test/Set-PoolAuthToken.ps1`.

Symptoms when the re-import is missing are silent rather than loud,
because the surrounding `try` usually swallows the resolution error:

- `Start-StatusService.ps1` leaves `runtime/caching-proxy.txt` at whatever
  the previous run wrote, so the status-page banner reports "not detected"
  while the runner's own banner — running in `Yuruna.Host`'s session, where
  `Read-CachingProxyState` *is* visible — correctly reports "detected".
- `Start-CachingProxy.ps1` skips persisting the discovered cache IP, so
  guest provisioners and the status server's fast path re-run full
  discovery on every cycle.

Durable capture: `feedback_module_force_import_evicts_global`.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.21

Back to [Yuruna](../README.md)
