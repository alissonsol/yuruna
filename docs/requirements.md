# Yuruna Requirements

Some examples assume that you have a registered domain and know how to create/edit DNS records in your registrar.

Before installing certificates on localhost, run `mkcert -install` once to create the local certificate authority. This may require elevated privileges.

## Required tools

Install each of the tools linked below. After installing PowerShell, run `Test-Requirements.ps1` to check which tools are installed and whether their versions meet the ones used in testing.

- Install [PowerShell Core](https://github.com/powershell/powershell), the cross-platform automation and configuration tool/framework, version 7.5+.
  - For Windows: learn about [execution policies](https://go.microsoft.com/fwlink/?LinkID=135170)
    - From PowerShell as Administrator, run `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned`
  - While in the Administrator PowerShell window, install the module "powershell-yaml"
    - Execute: `Install-Module -Name powershell-yaml`
- Install [Git](https://git-scm.com/downloads)
  - `git config --global user.name "Your Name"`
  - `git config --global user.email "Your@email.address"`
  - `git config --global core.autocrlf input`
- Using a Hyper-V machine in Windows? Enable [nested virtualization](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization)
- Using UTM on macOS? Nested virtualization (required for Docker Desktop inside the VM) needs macOS 15 Sequoia+, Apple M3+ chip, UTM v4.6+, and the Apple Virtualization backend (not QEMU). See [UTM setup details](../host/macos.utm/guest.ubuntu.desktop/read.more.md).
- Install [Docker Desktop](https://docs.docker.com/desktop/)
  - Enable [Kubernetes](https://docs.docker.com/get-started/orchestration/)
  - Install [Docker buildx](https://github.com/docker/buildx) in the path.
- Install [Helm](https://helm.sh/docs/intro/install/) in the path.
  - Download: [`https://github.com/helm/helm/releases`](https://github.com/helm/helm/releases)
- Install [OpenTofu](https://opentofu.org/docs/intro/install/) in the path.
- Install [wget](https://www.gnu.org/software/wget/) in the path.
  - Binaries for Windows at [eternallybored.org](https://eternallybored.org/misc/wget/)
- Install [mkcert](https://github.com/FiloSottile/mkcert) in the path.
  - Run `mkcert -install`

## Cloud tools

- AWS
  - Create an [AWS Account](https://aws.amazon.com/free)
  - Install the [AWS CLI](https://aws.amazon.com/cli/)
- Azure
  - Create an [Azure Account](https://azure.microsoft.com/free)
  - Install the [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- Google Cloud SDK
  - Create a [Google Cloud Account](https://console.cloud.google.com/freetrial)
  - Install the [Google Cloud SDK CLI](https://cloud.google.com/sdk/docs/install)
- DNS provider and instructions to create A record
  - Instructions for [Amazon Route 53](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resource-record-sets-creating.html)
  - Instructions for [Azure DNS](https://learn.microsoft.com/en-us/azure/dns/dns-getstarted-portal)
  - Instructions for [Google Cloud DNS](https://cloud.google.com/dns/docs/records)

## Recommended tools

- Install the latest version of [Visual Studio Code](https://code.visualstudio.com/)
  - Install the [Docker](https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-docker) extension.
  - Install the [Kubernetes](https://marketplace.visualstudio.com/items?itemName=ms-kubernetes-tools.vscode-kubernetes-tools) extension.
- Install [Graphviz](https://graphviz.org/download/) in the path.
- Install [K9S](https://k9scli.io/topics/install/) in the path.

## Development environment

- Instructions developed and tested with
  - Operating systems
    - Windows 11 Professional (`ver` → `Microsoft Windows [Version 10.0.26220.7872]`).
  - Required tools — run `Test-Requirements.ps1` to compare the version in the test environment against the one locally installed; follow links above to install or update. Scripts may work with older versions, but tests were performed with the indicated versions.

Back to [[Yuruna](../README.md)]
