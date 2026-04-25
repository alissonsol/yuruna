# Kubernetes Deployment

Deploy containerized applications to Kubernetes across localhost, Azure,
AWS, and GCP with a single workflow. Write the configuration once; switch
target clouds by changing a parameter.

See [../CODE.md](../CODE.md) for the three-phase model
(Resources→Components→Workloads), the CLI entry points, and the project
layout. This doc is the user-facing quick start for Kubernetes itself.

Prerequisites are in [requirements.md](requirements.md).

## Quick Start (Localhost)

Deploy the sample `.NET` website to Docker Desktop Kubernetes. No cloud
account required.

```powershell
git clone https://github.com/alissonsol/yuruna.git
cd yuruna
./Add-AutomationToPath.ps1
```

Create the HTTPS dev certificate (the Ubuntu `ubuntu.desktop.k8s.sh`
and `ubuntu.server.k8s.sh` workloads do this automatically on those
guests):

```powershell
$pfxDir = Join-Path $HOME ".aspnet/https"
if (!(Test-Path $pfxDir)) { New-Item -ItemType Directory -Path $pfxDir -Force | Out-Null }
openssl req -x509 -newkey rsa:4096 -keyout "$pfxDir/aspnetapp.key" -out "$pfxDir/aspnetapp.crt" -days 365 -nodes -subj '/CN=localhost' 2>$null
openssl pkcs12 -export -out "$pfxDir/aspnetapp.pfx" -inkey "$pfxDir/aspnetapp.key" -in "$pfxDir/aspnetapp.crt" -password pass:password
Remove-Item "$pfxDir/aspnetapp.key", "$pfxDir/aspnetapp.crt" -Force
```

Deploy:

```powershell
cd projects/examples
Set-Resource.ps1  website localhost -debug_mode $true -verbose_mode $true
Test-Runtime.ps1
Set-Component.ps1 website localhost -debug_mode $true -verbose_mode $true
Set-Workload.ps1  website localhost -debug_mode $true -verbose_mode $true
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

Details, service accounts, and API enablement: [authenticate.md](authenticate.md).

## Documentation

- [Requirements](requirements.md) · [Authentication](authenticate.md) ·
  [Syntax](syntax.md) · [FAQ](faq.md) · [Cleanup](cleanup.md)
- [Website example](../projects/examples/website/) · [Contributing](contributing.md) ·
  [Contributors](contributors.md) · [References](references.md)
- [Yuruna YouTube channel](https://www.youtube.com/channel/UCl36lZ2MwZ0f6_QAUOmGNDw)
