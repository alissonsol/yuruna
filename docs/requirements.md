# `yuruna` requirements

Some examples assume that you have a registered domain and know how to create/edit DNS records in your registrar.

Ahead of installing certificates in the localhost, it is recommended to run `mkcert -install` once to create the local certificate authority. Depending on the operating system, that may demand elevation.

## Required tools

- You obviously need [Git](https://git-scm.com/downloads)
  - `git config --global user.name "Your Name"`
  - `git config --global user.email "Your@email.address"`
  - `git config --global core.autocrlf input`
- Using a Hyper-V machine in Windows? Enable [nested virtualization](https://docs.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization)
- Installed [Docker Desktop](https://docs.docker.com/desktop/)
  - Enable [Kubernetes](https://docs.docker.com/get-started/orchestration/)
- Installed [PowerShell Core](https://github.com/powershell/powershell), the cross-platform automation and configuration tool/framework, version 7+.
  - For Windows: learn about [execution policies](https://go.microsoft.com/fwlink/?LinkID=135170)
    - From PowerShell as Administrator, run `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned`
  - While in the Administrator PowerShell window, install the module "powershell-yaml"
    - Execute: `Install-Module -Name powershell-yaml`
- Installed [Helm](https://helm.sh/docs/intro/install/) in the path.
  - Download: [`https://github.com/helm/helm/releases`](https://github.com/helm/helm/releases)
- Installed [Terraform](https://www.terraform.io/downloads.html) in the path.
- Installed [mkcert](https://github.com/FiloSottile/mkcert) in the path.
  - Run `mkcert -install`
- Installed [wget](https://www.gnu.org/software/wget/) in the path.
  - Binaries for Windows at [webfolderio.github.io](https://webfolderio.github.io/wget-windows/)

## Cloud tools

- AWS
  - Created [AWS Account](https://aws.amazon.com/free)
  - Installed [AWS CLI](https://aws.amazon.com/cli/)
- Azure
  - Created [Azure Account](https://azure.microsoft.com/free)
  - Installed [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli)
- Google Cloud SDK
  - Created [Google Cloud Account](https://console.cloud.google.com/freetrial)
  - Install the [Google Cloud SDK CLI](https://cloud.google.com/sdk/docs/install)
- DNS provider and instructions to create A record
  - Instructions for [Amazon Route 53](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resource-record-sets-creating.html)
  - Instructions for [Azure DNS](https://docs.microsoft.com/en-us/azure/dns/dns-getstarted-portal)
  - Instructions for [Google Domains](https://support.google.com/domains/answer/9211383)

## Recommended tools

- Installed version of [Visual Studio Code](https://code.visualstudio.com/)
  - Installed [Docker](https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-docker) extension.
  - Installed extension for [Kubernetes](https://marketplace.visualstudio.com/items?itemName=ms-kubernetes-tools.vscode-kubernetes-tools).
- Installed [Graphviz](https://graphviz.org/download/) in the path.
- Installed [K9S](https://k9scli.io/topics/install/) in the path.

## Development environment

- Instructions developed and tested with
  - Operating systems
    - Windows 10 Professional.
      - `ver`
        - `Microsoft Windows [Version 10.0.19044.1387]`
  - Required tools
    - Check with the implemented command `yuruna requirements`
      - It will show for each tool what was the version in the test environment and version locally found.
      - Follow links above to install or update tools.

See some additional guidance on how machines were setup for the [macOS](./requirements-mac-os.md) and [Ubuntu](./requirements-ubuntu.md) tests (no guarantees!).

Back to main [readme](../README.md)
