# Yuruna Contributor Opportunities

Prioritised work the project would welcome help on. New contributors:
pick something at a priority level that matches the time you have, and
read [Contributing](../CONTRIBUTING.md) for the workflow.

## Global

### P0

- Get to at most one "framework incident" every 24 hours
  - Remaining blocking: timing issues with login
  - Step [6/13] passwdPrompt: "Current password' | 'urrent password:" - Current password: (sequence: start.guest.amazon.linux.2023)
- Generic registry login approach in `automation/Yuruna.Component.psm1`
  (today only `*.azurecr.io` is handled via `az acr login`; needs
  ECR / GAR / Docker Hub / generic-docker-login coverage)
- SSH support across hosts
- Windows sequence for startup and minimal workload test

### P1

- Need something like: loop: _number(001-003)
- Before "cloud-based" scripts execute, validate session
- Validation: repeated resource names and other duplications like context names

### P2

- Time zone still wrong in Ubuntu
- Check if tofu requires variable and not provide it if not needed (avoids warnings).
- Documentation
  - How to start new project from the "template".
  - How to use a single PowerShell script for the several commands in a repeated block until someday implementing loop: _number(001-003)
- Finish testing and publish the resources for AWS and GCP
  - More resource templates in general

### P3+

- Mobile framework integration (Maestro, etc.)
- For resources created using tofu `local-exec`: destroy when doing `tofu destroy`
- Create Visual Studio Code extension to start projects, run commands, etc.
  - Visual Studio Code: [Your First Extension](https://code.visualstudio.com/api/get-started/your-first-extension)
- Graph from YML: Python [graphviz 0.15](https://pypi.org/project/graphviz/)
- Decide on copying all code during component setup (`automation/Yuruna.Component.psm1`)

## AWS

- Fix issue with Windows (/bin/sh) when executing `tofu apply` [Works for macOS]
  - <https://github.com/terraform-aws-modules/terraform-aws-eks/issues/757>
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

## Host / guest

- Document Hyper-V Amazon Linux nested virtualization setup (`host/windows.hyper-v/guest.amazon.linux.2023/read.more.md`)

Back to [Yuruna](../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
