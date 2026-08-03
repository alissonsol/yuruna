# Yuruna Workarounds and FAQ

Notes, frequently asked questions, and workarounds learned during
development, followed by per-guest-OS troubleshooting. Host-side issues
live in the host docs: [Windows Hyper-V](host-hyperv.md) ·
[macOS UTM](host-macos.md).

## Connectivity

**Connection to <http://localhost> fails** — on Windows, stop HTTP and
related processes. Find what's holding port 80 with
`netstat -nao | find ":80"`, then `net stop http`. When that is blocked by
[HTTP services can't be stopped when the Microsoft Web Deployment Service is installed](https://learn.microsoft.com/en-us/troubleshoot/iis/http-service-fail-stopped),
also `net stop msdepsvc`, reboot, and retry. If `BranchCache` keeps needing
a stop, disable it via
[`Disable-BC`](https://learn.microsoft.com/en-us/powershell/module/branchcache/disable-bc).
Browser [HSTS](https://en.wikipedia.org/wiki/HTTP_Strict_Transport_Security)
can also be the cause: remove localhost (or your dev site) from the
[preloaded HSTS list](https://www.chromium.org/hsts/) — open
`chrome://net-internals/#hsts` (`edge://net-internals/#hsts` in Edge) →
under "Delete domain security policies" type the site → Delete.

**A container is reachable via port forward but not via the ingress on
localhost** — confirm the required ports aren't held by other processes
before deploying. Docker Desktop itself often holds them
([docker/for-mac#4903](https://github.com/docker/for-mac/issues/4903)); quit
and restart Docker, since the Restart menu item is not enough. See also
**Debugging localhost** below.

**An example fails when executed twice, or after another example** — run,
clear, and if port 80 is still busy quit Docker and start again. Check the
exposed ports with `kubectl get svc --all-namespaces`.

**The local registry doesn't work on macOS** — confirm port 5000 isn't in
use ([SO](https://stackoverflow.com/questions/69818376/localhost5000-unavailable-in-macos-v12-monterey)):
`lsof -nP -iTCP -sTCP:LISTEN | grep 5000`.

**Applications inside the container can't connect to the outside** — verify
`kube-proxy` can reach the host IP. Find the host IP (`ipconfig`/`ifconfig`),
exec into `kube-proxy`, install `ping` if needed (see **Debugging from inside
a minimal container** below), and ping outward.

## General

**What is the answer to the ultimate question of life, the universe, and
everything?** — `42`. That's why every example uses
easily-found-and-replaced prefixes starting with `yrn42`.

**Moving a development machine** — cloud resources and components created on
one machine can be picked up on another. Import the cluster context and
`resources.output.yml`; the import command is in the resource template's
`cluster.tf`. See also
[merging Kubernetes configurations](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/).

**`Error: can't find external program "pwsh"`** — check for PowerShell 7.0+
via `$PSVersionTable`. Setup: <https://aka.ms/powershell>. Versions used in
testing are listed in [Preflight
dependencies](operator.md#b2-preflight-dependencies).

## Development notes

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

```bash
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

**Ubuntu latest-point-release picker sorts on the parsed version, not
the filename string** — `Resolve-UbuntuServerStableImage` in
[`host/modules/Yuruna.UbuntuImage.psm1`](../host/modules/Yuruna.UbuntuImage.psm1)
(consumed by every per-guest `Get-Image.ps1` across Hyper-V, UTM and
KVM — noble + resolute) resolves the "latest stable" ISO by
regex-matching `ubuntu-[\d.]+-live-server-<arch>\.iso` on the release
directory listing and then sorting the matches on the `[version]`
parsed out of each filename, descending, taking the first.
The `[version]` key is load-bearing: a plain
`Sort-Object Value -Descending` is lexicographic, so once Ubuntu ships
a `.10`+ point release `ubuntu-24.04.10-...` sorts BEFORE
`ubuntu-24.04.2-...` (because `'1' < '2'`) and the picker would pin
`24.04.9` while releases.ubuntu.com already serves `.10` — symptom:
`Selected stable ISO: ubuntu-<NN>.04.9-live-server-<arch>.iso`.
Keep the version-keyed sort (and its unparseable-value fallback) if
this resolver is ever rewritten; one edit in the shared module affects
every per-guest caller.

## A detached grandchild pins the caller's pipe on Windows

Spawning a child pwsh with any std stream redirected (including
`& pwsh ... *> $null`)
turns handle inheritance ON for that child. `Invoke-StatusServiceBounce` in
[`test/modules/Test.ConfigServiceSync.psm1`](../test/modules/Test.ConfigServiceSync.psm1)
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
the whole descendant tree, which includes the status service, and reintroduces
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
  `test/modules/Test.CachingProxyService.psm1` **without** `-Global`. Any script
  that imported `Test.CachingProxyService` for itself loses
  `Read-CachingProxyServiceState`, `Save-CachingProxyServiceState`,
  `Invoke-CachingProxyServiceProbe`, and `Get-CachingProxyServiceStatePath` the moment
  `Initialize-YurunaHost` runs.
- **Foreign modules lose theirs.** A script `&`-invoked from a module
  context (the inner cycle runner calling `Remove-TestVMFiles.ps1`, or the
  status service calling into the host contract) that does a `-Force`
  import *without* `-Global` pulls the module out of the global table for
  every unrelated module, so a later contract call from `Test.SequenceEngine`
  fails to resolve. This is the *legacy-eviction regression class*.

**The rule:** re-import with `-Global -Force` immediately **after** every
`Initialize-YurunaHost` call and before touching the affected exports, and
always pass `-Global` when a script that may be invoked from a module
context imports a shared module.

Sites that depend on this ordering: `test/Start-CachingProxyServiceVM.ps1`,
`test/Stop-CachingProxyServiceVM.ps1`, `test/Repair-CachingProxyServiceForwarder.ps1`,
`test/Test-CachingProxyService.ps1`, `test/Start-StatusService.ps1`,
`test/Remove-TestVMFiles.ps1`, `test/Set-LabToken.ps1`.

Symptoms when the re-import is missing are silent rather than loud,
because the surrounding `try` usually swallows the resolution error:

- `Start-StatusService.ps1` leaves `runtime/caching-proxy-service.txt` at whatever
  the previous run wrote, so the status-page banner reports "not detected"
  while the runner's own banner — running in `Yuruna.Host`'s session, where
  `Read-CachingProxyServiceState` *is* visible — correctly reports "detected".
- `Start-CachingProxyServiceVM.ps1` skips persisting the discovered cache IP, so
  guest provisioners and the status service's fast path re-run full
  discovery on every cycle.

Durable capture: `feedback_module_force_import_evicts_global`.

## `utmctl start` exits 0 without starting the VM

On a freshly-imported bundle, `utmctl start` can return 0 at the RPC layer
while UTM is still finalizing bundle ingestion — the start request is
silently dropped and the VM stays `stopped`. The exit code alone is
therefore not evidence the VM is running, and a caller that trusts it
advertises a service that does not exist and then blames whatever runs
next (cloud-init, a daemon build, a NAS mount) for a guest that never
booted.

The fix is to verify the transition rather than the exit code: the host
contract's `Start-VM` (`Start-UtmVM`) retries and parses `utmctl status`,
and every service bring-up follows it with `Wait-VMRunning` before doing
anything downstream. Do not hand-roll `open` + `utmctl start`; that path
also skips the custom-QEMU-args dialog watchdog, without which UTM blocks
on a modal and the bring-up cannot run unattended at all.

## Guest troubleshooting

Per-guest-OS notes, for problems that surface inside a provisioned guest
rather than on the host.

### Amazon Linux 2023

**"Display Output Is Not Active"** — confirm a GUI is installed. Amazon
Linux's first boot (especially on macOS UTM) has only an attached
terminal; switch to that window to log in.

### Ubuntu Server

Shared troubleshooting for the Ubuntu Server guests (24.04, 26.04, …).
Substitute your release (`24`, `26`, …) for `<release>` in the paths
below — e.g. the 24.04 fetch-and-execute paths use
`guest/ubuntu.server.24/…` (`ubuntu.server.24.update.sh`).

**Boot issues** — check `/var/log/installer/installer-journal.txt` for
hints. If the text-mode installer appears stuck, `Ctrl+Alt+F2` (or `F3`)
to switch to a TTY, then check `/var/log/installer` or
`/var/log/cloud-init.log` for `Error` or `Failed to load` — these usually
point at the offending config line.

**Console login not accepting the password** — `Ctrl+Alt+F3` for an
alternate TTY, then run
`/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.<release>/ubuntu.server.<release>.update.sh`
two or three times until no updates or cleanup remain, and
`sudo reboot now`.

**Time zone incorrect** — auto-detected at install via IP geolocation
(cloud-init). To set manually:

```bash
timedatectl list-timezones | grep <region>
sudo timedatectl set-timezone America/Los_Angeles
timedatectl                       # verify
```

### Windows 11

**winget not available** — after a fresh install, update **App
Installer** in Microsoft Store and restart the terminal. Alternatively:

```powershell
Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe
```

**Scripts blocked by execution policy** —

```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

**Docker Desktop requires restart** — if `docker` commands fail after
install: restart the computer, launch Docker Desktop, wait for the
systray icon to stop animating.

**Kubernetes not available in Docker Desktop** — Docker Desktop →
**Settings** → **Kubernetes** → check **Enable Kubernetes** → **Apply &
restart**.

**Time zone incorrect** — **Settings** → **Time & Language** → **Date &
time**. Enable **Set time zone automatically** or pick one manually.

**Windows activation** — the VM is installed with a generic key
(unactivated). Activate:

```powershell
slmgr /ipk XXXXX-XXXXX-XXXXX-XXXXX-XXXXX
slmgr /ato
```

Product keys: [Windows 11 ...](../host/windows.hyper-v/guest.windows.11/vmconfig/README.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.03

Back to [Yuruna](../README.md)
