# Yuruna Hacks

Some notes and hacks learned during the development process.

## Getting log data from inside a VM

Copy and paste often works directly. When it doesn't, and a GUI is available, use <https://privatebin.at>. It works like <https://pastebin.com> but allows data beyond 512KB.

## Files not changed

Scripts set some files to `assume-unchanged` so that locally-modified values aren't picked up by git. Revert with `git update-index --really-refresh`.

## Note about Docker registry names

Cloud providers commonly demand a unique registry name and corresponding [FQDN](https://en.wikipedia.org/wiki/Fully_qualified_domain_name). Changing the registry name may require changes in `config/deployment.yml`.

## Hack to workaround Kubernetes context collision

Keep contexts pointing to clusters in different clouds simultaneously with [`kubectl config rename-context`](https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#-em-rename-context-em-).

```shell
kubectl config rename-context old-name new-name
```

## Troubleshooting the automated certificate issuing process

- Check the [cert-manager.io FAQ](https://cert-manager.io/docs/faq/acme/)
  - Under the cluster `Custom Resources`, check the `certificaterequests`
  - Per [Syncing Secrets Across Namespaces](https://cert-manager.io/docs/faq/kubed/): "Wildcard certificates are not supported with HTTP01 validation and require DNS01". See the [Challenge Types](https://letsencrypt.org/docs/challenge-types/) docs.

## Hack to debug issues from container

The containers have minimal software — even `ping` must be installed.

```shell
apt-get update
apt-get install -y iputils-ping
```

To build a project outside the container you may need `dotnet restore`, `dotnet build`, then `dotnet run`. The restore step may need [`nuget`](https://learn.microsoft.com/en-us/nuget/install-nuget-client-tools) in the path. The real reason this is in "hacks": at times you first have to run `nuget restore [name].proj` before `dotnet restore [name].proj`.

See also [kubernetes/ingress-nginx](https://github.com/kubernetes/ingress-nginx/tree/master/docs/examples/grpc) for debugging.

## Docker and Kubernetes issues

`Reset to factory defaults` in Docker is usually the quickest fix. It is under the "Troubleshoot" menu (icon looks like a bug, but acts like a help button).

Afterward, remove `~/.kube` and enable Kubernetes again (this loses at least some configuration and possibly data).

For the error:

```shell
docker-credential-desktop executable file not found in $PATH
```

In `~/.docker/config.json`, change `credsStore` to `credStore` — this switches from the desktop credential store to file-based credential storage. Alternatively remove the `credsStore` entry to store credentials in the config file, or install a suitable credential helper (osxkeychain, wincred).

## Azure deletes static IP when deleting an ingress using it

Unexpected Azure behavior, confirmed [here](https://stackoverflow.com/questions/66435282/how-to-make-azure-not-delete-public-ip-when-deleting-service-ingress-controlle). The workaround has side-effects; better to `clear` and rebuild everything (`resources`, `components`, `workloads`).

## Invoke-Expression: Cannot bind argument to parameter 'Command' because it is an empty string.

Usually a `shell` expression that doesn't return anything. Add `$true` to the end of the expression.

## Debug service

Iterate with `kubectl edit svc [service-name] -n [namespace-name]` (also works for configMaps, pods, etc.). Then build the sequence of `kubectl patch` statements to reach the right state.

## Debugging localhost issues

After deploying resources and components, resetting the Docker Kubernetes cluster and reconnecting contexts often helps. Use `automation/context-copy.ps1` — the context names that may need to be reconnected are listed in `resources.output.yml`; deleting those ahead of time avoids issues. Then run `automation/context-copy.ps1 -sourceContext <source> -destinationContext <dest>`.

GitHub issue documenting need to restart Docker: <https://github.com/docker/for-mac/issues/4903>

## PodSecurityPolicy

- Check with `kubectl get psp -A`
- Delete with `kubectl delete psp [name]`

Back to [[Yuruna](../README.md)]
