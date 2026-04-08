# Yuruna TODO List

## Global

### P0, P1

- Need something like: loop: _number(001-003)
- How to "pack and move" to another machine
- Before "cloud-based" scripts execute, validate session
- Validation: repeated resource names and other duplications like context names

### P1

- Better PowerShell scripts (likely eternal goal!).
  - Consider check behavior like that of the [GitHub actions](https://docs.github.com/en/actions/reference/workflow-syntax-for-github-actions), appending to each command: `if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit $LASTEXITCODE }`
- Check if tofu requires variable and not provide it if not needed (avoids warnings).
- Documentation
  - How to start new project from the "template".
  - How to use a single PowerShell script for the several commands in a repeated block until someday implementing loop: _number(001-003)
- Finish testing and publish the resources for AWS and GCP
  - More resource templates in general

### P2

- For resources created using tofu `local-exec`: destroy when doing `tofu destroy`
- Create Visual Studio Code extension to start projects, run commands, etc.
  - Visual Studio Code: [Your First Extension](https://code.visualstudio.com/api/get-started/your-first-extension)
- Graph from YML: Python [graphviz 0.15](https://pypi.org/project/graphviz/)
- Decide on copying all code during component setup (`automation/yuruna-components.psm1`)
- Generic registry login approach (`automation/yuruna-components.psm1`)

### P3+

- Confirm use only of [Approved Verbs for PowerShell Commands](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands?view=powershell-7.1)
- Non-repro or hard to repro issues
  - Cert-manager: workloads in Azure — transient connection errors to charts.jetstack.io
  - NGINX: workloads in Azure: 2nd time+: Error: cannot re-use a name that is still in use

## AWS

- Fix issue with Windows (/bin/sh) when executing `tofu apply` [Works for macOS]
  - <https://github.com/terraform-aws-modules/terraform-aws-eks/issues/757>
- OpenTofu
  - Create+output registry
  - Standard names
- import-clusters: get created registry credentials
- Cluster IP?
  - <https://docs.aws.amazon.com/vpc/latest/userguide/vpc-ip-addressing.html#vpc-public-ipv4-addresses>
  - public_subnet_map_public_ip_on_launch

## Azure

- Global improvements

## GCP

- Global improvements
- Fix the cluster.min_master_version: creating with v1.19+ failed
  - Consequence: hack to deploy the ingress, since today it depends on v1.19+ syntax
- IP load balancer not working.

## VDE

- Create scripts to configure host and guest settings for Windows 11 (`vde/guest.windows.11/README.md`)
- Document Hyper-V Amazon Linux nested virtualization setup (`vde/host.windows.hyper-v/guest.amazon.linux/read.more.md`)

Back to [[Yuruna](../README.md)]
