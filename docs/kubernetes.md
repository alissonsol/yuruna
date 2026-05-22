# Kubernetes Deployment

Deploy containerized applications to Kubernetes across localhost, Azure,
AWS, and GCP with a single workflow. Write the configuration once; switch
target clouds by changing a parameter.

See [Yuruna Architecture](architecture.md) for the three-phase model
(Resources→Components→Workloads), the CLI entry points, and the project
layout. This doc is the user-facing quick start for Kubernetes itself.

Prerequisites are in [Yuruna Requirements](requirements.md).

## Quick Start (Localhost)

Deploy the sample `.NET` website to Docker Desktop Kubernetes. No cloud
account required.

```powershell
git clone https://github.com/alissonsol/yuruna.git
cd yuruna
./Add-AutomationToPath.ps1
```

Create the HTTPS dev certificate (the `ubuntu.server.24.k8s.sh` workload
does this automatically on that guest):

```powershell
$pfxDir = Join-Path $HOME ".aspnet/https"
if (!(Test-Path $pfxDir)) { New-Item -ItemType Directory -Path $pfxDir -Force | Out-Null }
openssl req -x509 -newkey rsa:4096 -keyout "$pfxDir/aspnetapp.key" -out "$pfxDir/aspnetapp.crt" -days 365 -nodes -subj '/CN=localhost' 2>$null
openssl pkcs12 -export -out "$pfxDir/aspnetapp.pfx" -inkey "$pfxDir/aspnetapp.key" -in "$pfxDir/aspnetapp.crt" -password pass:password
Remove-Item "$pfxDir/aspnetapp.key", "$pfxDir/aspnetapp.crt" -Force
```

Deploy:

```powershell
cd project/example
Set-Resource.ps1  website localhost -logLevel Debug
Test-Runtime.ps1
Set-Component.ps1 website localhost -logLevel Debug
Set-Workload.ps1  website localhost -logLevel Debug
```

The output of `Set-Workload.ps1` prints the URL.

## Cloud Deployment

Authenticate once, then swap `localhost` for your cloud:

```powershell
# Azure
az login --use-device-code
az account set --subscription <your-subscription-id>
Set-Resource.ps1 website azure; Set-Component.ps1 website azure; Set-Workload.ps1 website azure

# AWS
aws configure
Set-Resource.ps1 website aws;   Set-Component.ps1 website aws;   Set-Workload.ps1 website aws

# GCP
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
| **Ubuntu Server 24.04** | `/automation/fetch-and-execute.sh guest/ubuntu.server.24/ubuntu.server.24.k8s.sh` |
| **Ubuntu Server 26.04** | `/automation/fetch-and-execute.sh guest/ubuntu.server.26/ubuntu.server.26.k8s.sh` |
| **Windows 11** | `irm "…/guest/windows.11/windows.11.k8s.ps1$nc" \| iex` (see [Windows 11 ...](../guest/windows.11/README.md)) |

**Ubuntu — optional after:** change hostname with
`sudo hostnamectl set-hostname <name>`; a terminal restart may be
needed for new group permissions.

### Verify

```bash
docker images
docker ps -a
kubectl get nodes
kubectl get pods -A
kubectl config current-context
```

## See also

- [Yuruna Syntax](syntax.md) — CLI reference for the three phases
- [Yuruna Frequently Asked Questions](faq.md), [Yuruna Workarounds](workarounds.md), [Yuruna Resources Clean Up](cleanup.md)
- [Yuruna Website example](../project/example/website/), [Yuruna References](references.md)

Back to [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
