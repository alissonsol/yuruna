# Yuruna Hacks

Notes and workarounds learned during development.

**Log data from inside a VM** — copy/paste often works; when it doesn't,
<https://privatebin.at> handles >512 KB (like pastebin).

**Files marked `assume-unchanged`** — scripts set some files so local
edits don't surface to git. Revert with
`git update-index --really-refresh`.

**Docker registry names** — clouds need a unique name +
[FQDN](https://en.wikipedia.org/wiki/Fully_qualified_domain_name).
Changing the name may require edits to `config/deployment.yml`.

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

Back to [[Yuruna](../README.md)]
