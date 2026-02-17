# Yuruna - Kubernetes Deployment

**Deploy containerized applications to Kubernetes across multiple clouds with a single workflow.**

Yuruna automates the complexity of provisioning infrastructure, building containers, and deploying to Kubernetes. Write your configuration once, then deploy to localhost, Azure, AWS, or Google Cloud by changing a single parameter.

## How It Works

Yuruna uses a **three-phase deployment model**:

```text
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Resources  │ ──▶ │ Components  │ ──▶ │  Workloads  │
│ (Terraform) │     │  (Docker)   │     │   (Helm)    │
└─────────────┘     └─────────────┘     └─────────────┘
```

1. **Resources** - Provision cloud infrastructure (Kubernetes clusters, container registries, databases) using Terraform
2. **Components** - Build Docker images and push them to your container registry
3. **Workloads** - Deploy applications to Kubernetes using Helm charts

Each phase reads from YAML configuration files and passes outputs to the next phase.

## Quick Start (Localhost)

Deploy a sample .NET website to Docker Desktop Kubernetes in minutes. No cloud account required.

### Prerequisites

Install the following tools:

- [PowerShell 7+](https://github.com/powershell/powershell) - Run `Install-Module -Name powershell-yaml` after installing
- [Git](https://git-scm.com/downloads)
- [Docker Desktop](https://docs.docker.com/desktop/) with [Kubernetes enabled](https://docs.docker.com/get-started/orchestration/)
- [Helm](https://helm.sh/docs/intro/install/)
- [Terraform](https://developer.hashicorp.com/terraform/install)
- [mkcert](https://github.com/FiloSottile/mkcert) - Run `mkcert -install` after installing

See [full requirements](requirements.md) for detailed setup instructions.

### Deploy the Example Website

```powershell
# Clone the repository
git clone https://github.com/alissonsol/yuruna.git
cd yuruna

# Add automation folder to your path (or run from automation folder)
$env:PATH += ";$PWD/automation"

# Phase 1: Create local resources (registry, Kubernetes context)
Set-Resource.ps1 website localhost

# Phase 2: Build and push the Docker image
Set-Component.ps1 website localhost

# Phase 3: Deploy to Kubernetes
Set-Workload.ps1 website localhost
```

Once complete, visit the URL shown in the output to see your deployed website.

## Cloud Deployment

To deploy to a cloud provider instead of localhost, authenticate with your cloud CLI, then replace `localhost` with your target cloud.

### Azure

```powershell
# Authenticate (once per session)
az login --use-device-code
az account set --subscription <your-subscription-id>  # if you have multiple subscriptions

# Deploy to Azure
Set-Resource.ps1 website azure
Set-Component.ps1 website azure
Set-Workload.ps1 website azure
```

### AWS

```powershell
# Authenticate (configure once)
aws configure  # Enter your Access Key ID, Secret Access Key, region, and output format

# Deploy to AWS
Set-Resource.ps1 website aws
Set-Component.ps1 website aws
Set-Workload.ps1 website aws
```

### Google Cloud

```powershell
# Authenticate (once per session)
gcloud auth application-default login

# Deploy to GCP
Set-Resource.ps1 website gcp
Set-Component.ps1 website gcp
Set-Workload.ps1 website gcp
```

See [authentication docs](authenticate.md) for detailed setup instructions including service accounts and API enablement.

## Configuration

Each project has three YAML configuration files in the `config/<cloud>/` folder:

| File | Purpose |
|------|---------|
| `resources.yml` | Infrastructure to create (clusters, registries, IPs) |
| `components.yml` | Docker images to build and push |
| `workloads.yml` | Applications to deploy via Helm |

See the [website example](../examples/website/) for a complete reference and the [syntax documentation](syntax.md) for configuration details.

## Project Structure

```text
yuruna/
├── automation/          # PowerShell scripts (Set-Resource.ps1, Set-Component.ps1, etc.)
├── global/resources/    # Terraform templates for each cloud provider
├── examples/            # Example projects (website, template)
└── docs/                # Documentation
```

## Documentation

- [Requirements](requirements.md) - Full tool installation guide
- [Authentication](authenticate.md) - Cloud provider setup
- [Syntax](syntax.md) - Configuration file reference
- [FAQ](faq.md) - Troubleshooting common issues
- [Cleanup](cleanup.md) - Removing deployed resources
- [Examples](../examples/README.md) - Sample projects

## Important Notes

- **Cost warning**: Cloud resources incur charges. Always [clean up](cleanup.md) resources you're not using.
- **Windows users**: Set `git config --global core.autocrlf input` before cloning to avoid line-ending issues with Linux containers.
- Scripts and examples are provided "as is" without guarantees. See [license](../license.md).

## Contributing

Check the [contributing guidelines](contributing.md) and the list of [open tasks](todo.md).

Thanks to all [contributors](contributors.md)!

## Resources

- [Yuruna YouTube channel](https://www.youtube.com/channel/UCl36lZ2MwZ0f6_QAUOmGNDw) - Video tutorials
- [Latest version](https://github.com/alissonsol/yuruna)
- [References](references.md) - Additional reading

---

Copyright (c) 2019-2026 by Alisson Sol et al.
