# Kubernetes Deployment

Deploy containerized applications to Kubernetes across localhost, Azure,
and AWS with a single workflow (GCP is planned, not yet available). Write
the configuration once; switch target clouds by changing a parameter.

See [Yuruna Architecture](architecture.md) for the three-phase model
(Resources→Components→Workloads), the CLI entry points, and the project
layout. This doc is the user-facing quick start for Kubernetes itself.

Prerequisites are in [Yuruna Requirements](requirements.md).

## Quick Start (Localhost)

Deploy the sample `.NET` website to Docker Desktop Kubernetes. No cloud
account required.

```
git clone https://github.com/alissonsol/yuruna.git
cd yuruna
./Add-AutomationToPath.ps1
```

Create the HTTPS dev certificate (the `ubuntu.server.24.k8s.sh` workload
does this automatically on that guest):

```
$pfxDir = Join-Path $HOME ".aspnet/https"
if (!(Test-Path $pfxDir)) { New-Item -ItemType Directory -Path $pfxDir -Force | Out-Null }
openssl req -x509 -newkey rsa:4096 -keyout "$pfxDir/aspnetapp.key" -out "$pfxDir/aspnetapp.crt" -days 365 -nodes -subj '/CN=localhost' 2>$null
openssl pkcs12 -export -out "$pfxDir/aspnetapp.pfx" -inkey "$pfxDir/aspnetapp.key" -in "$pfxDir/aspnetapp.crt" -password pass:password
Remove-Item "$pfxDir/aspnetapp.key", "$pfxDir/aspnetapp.crt" -Force
```

Deploy:

```
cd project/example
Set-Resource.ps1  website localhost -logLevel Debug
Test-Runtime.ps1
Set-Component.ps1 website localhost -logLevel Debug
Set-Workload.ps1  website localhost -logLevel Debug
```

The output of `Set-Workload.ps1` prints the URL.

## Cloud Deployment

Authenticate once, then swap `localhost` for your cloud:

```
# Azure
az login --use-device-code
az account set --subscription <your-subscription-id>
Set-Resource.ps1 website azure; Set-Component.ps1 website azure; Set-Workload.ps1 website azure

# AWS
aws configure
Set-Resource.ps1 website aws;   Set-Component.ps1 website aws;   Set-Workload.ps1 website aws

# GCP (planned, not yet available)
gcloud auth application-default login
Set-Resource.ps1 website gcp;   Set-Component.ps1 website gcp;   Set-Workload.ps1 website gcp
```

Details, service accounts, and API enablement: [Yuruna Authentication ...](authentication.md).

## Guest-side prerequisites

Workload that installs SSH, Git, Docker, Kubernetes, PowerShell, Helm,
OpenTofu, mkcert, Graphviz, and cloud CLIs (Azure, AWS, GCP) on a running
guest VM. Full tool list: [Yuruna Requirements](requirements.md). Guest
workload pattern: [Yuruna Architecture](architecture.md).

| Guest | Command |
|---|---|
| **Ubuntu Server 24.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.k8s.sh` |
| **Ubuntu Server 26.04** | `/usr/local/lib/yuruna/fetch-and-execute.sh guest/ubuntu.server.26/ubuntu.server.26.k8s.sh` |
| **Windows 11** | `irm "…/guest/windows.11/windows.11.k8s.ps1$nc" \| iex` (see [Windows 11 ...](../guest/windows.11/README.md)) |

**Ubuntu — optional after:** change hostname with
`sudo hostnamectl set-hostname <name>`; a terminal restart may be
needed for new group permissions.

### Verify

```
docker images
docker ps -a
kubectl get nodes
kubectl get pods -A
kubectl config current-context
```

## Test-sequence notes

### Why the website readiness check waits on Deployment availability, not Endpoints

The website workload's GUI test waits on **Deployment availability**,
not on Endpoints addresses:

```
kubectl wait --for=condition=available deployment/website -n website --timeout=240s
```

The old check looked at `endpoints/website-service`, which was wrong on
two counts:

1. **Wrong name.** The helm chart's Service is `website`, not
   `website-service` — that name is on the standalone manifest in
   `components/frontend/website/` used for ad-hoc `kubectl apply`, not
   in-cluster.
2. **Wrong signal.** It reported `NotFound` instantly when the
   Deployment was 0/1 ready, masking the real fault (a pod Evicted by
   ephemeral-storage pressure, its replacement stuck on the
   disk-pressure taint).

`--for=condition=available` blocks on the actual
`Deployment.status.conditions` readiness signal, so the test waits the
full 240 s and the diagnostic captures a useful pod state.

### Reclaim build-cache disk before deploy

The dotnet SDK build leaves ~1.3 GiB in `docker buildx prune` territory
and another ~0.5 GiB of dangling intermediate images. On a 14 GiB node
disk that was enough to trip kubelet's 85% ephemeral-storage watermark,
get the workload + nginx-ingress pods Evicted, and leave their
replacements stuck on the disk-pressure taint. The workload scripts
prune both caches before the cluster deploys; failure there is
non-fatal — only the side effect matters.

## See also

- [Yuruna Syntax](syntax.md) — CLI reference for the three phases
- [Yuruna Frequently Asked Questions](faq.md), [Yuruna Workarounds](workarounds.md), [Yuruna Resources Clean Up](cleanup.md)
- [Yuruna Website example](../project/example/website/), [Yuruna References](references.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.10

Back to [Yuruna](../README.md)
