# Yuruna Website Example

A simple .NET C# website container deployed to Kubernetes.

## Deploy

Before deploying, search for `TO-SET` in `config/<cloud>/*.yml` and fill
the required values (see [Cloud](#cloud) below). Read the Connectivity
section of [FAQ](../../../docs/faq.md) first.

From the `automation/` folder (in `pwsh`):

```shell
Set-Resource.ps1  website localhost
Set-Component.ps1 website localhost
Set-Workload.ps1  website localhost
```

See [../../../CODE.md](../../../CODE.md) for the three-phase model and CLI
entry points.

## What this project contains

- **Resources** — a Kubernetes cluster, a container registry, a public
  IP. OpenTofu outputs `${env:registryName}.registryLocation`,
  `${context.name}.clusterIp`, `${context.name}.frontendIp`,
  `${context.name}.hostname`.
- **Components** — a .NET C# website Docker image and the NGINX Ingress
  Controller ([Helm chart](https://kubernetes.github.io/ingress-nginx/deploy/#using-helm)).
- **Workloads** — frontend/website and NGINX ingress routing traffic to
  the website.

## Validation

- Open the endpoint printed after publishing workloads.
- `kubectl get services --all-namespaces`
- `kubectl get events --all-namespaces`

## Cloud

Before `Set-Workload.ps1`, confirm the `yrn42website-domain` DNS entry
(e.g. `www.yrn42.com`) points to the `frontendIp` that `Set-Resource.ps1`
output. Alternatives:

- `curl -v http://{frontendIp} -H 'Host: {yrn42website-domain}'`
- A temporary entry in `/etc/hosts`.

### Azure

- Pick a globally unique registry name — ping `yourname.azurecr.io` to
  confirm it is free — then replace `localhost` with `azure`.
- If `EXTERNAL-IP` on `nginx-ingress` never appears and events mention
  `Error syncing load balancer: failed to ensure load balancer:
  ensurePublicIPExists …`, verify `azure-dns-label-name` in the Helm
  deployment matches the `frontendIp` label (the cluster name).
- Re-running `workloads` may drop the IP; lock the resource as
  described in [this issue](https://stackoverflow.com/questions/66435282/how-to-make-azure-not-delete-public-ip-when-deleting-service-ingress-controlle).

Back to [[Yuruna](../../../README.md)] or [[Examples](../README.md)].
