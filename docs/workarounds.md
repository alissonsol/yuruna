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

```shell
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

**Ubuntu `Get-Image.ps1` latest-point-release picker is a string sort, not
a version sort** — every `host/<host>/guest.ubuntu.server.<NN>/Get-Image.ps1`
(noble + resolute × hyper-v, utm, kvm; six scripts total) resolves the
"latest stable" ISO by regex-matching `ubuntu-[\d.]+-live-server-<arch>.iso`
on the release directory listing and then
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
`Resolve-StableIso` with a `[version]`-keyed sort, e.g.
`Sort-Object @{ Expression = { [version]([regex]::Match($_.Value, 'ubuntu-([\d.]+)-').Groups[1].Value) } } -Descending`,
or grab the version from `releases.ubuntu.com/<codename>/SHA256SUMS`
ordering. Same fix needs to land in all six scripts.

Back to [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
