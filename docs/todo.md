# Yuruna TODO List

## Global

### P0

- Get to at most one "framework incident" every 24 hours
  - MAJOR BLOCK: Keyboard locked during Ubuntu boot (spice issue?)
  - 2nd: Not detecting the ${username}@${vmName} pattern: is there a better way to do the OCR?
  - 3rd: Spurious messages coming at random times (like the "hv_balloon" messages)
  - 4th: Still getting sporadic errors when sending chars to the macOS.
    - Amazon Linux command: `dnf list installed | grep desktop`
    - Is received as: `dnf list installed \ grep desktop`
- Investigate framework for "mobile"
- Windows sequence for startup and minimal workload test
- Get error logs from inside VM to outside in cross-host and cross-guest manner
- Externalize "credentials": should come through method that can start just reading local file, but later gets credentials from "service"
- Flags so that now all notifications get email (reduce noise)
- Less dependency on remote for "fetch-and-execute": can do a "git clone" early on and then use content locally (better to ensure "consistency")
- Functionality to find and activate window with a certain title (maily in Ubuntu)
  - Background: during a test run, a popup came to offer an update and took away focus from the Terminal window. Ensure focus is back there before commands are sent.

### P1

- Cache machine instructions
- Machine and test pools
- Need something like: loop: _number(001-003)
- Bug in  Remove-OrphanedVMFiles.ps1 in macOS
- How to "pack and move" to another machine
- Before "cloud-based" scripts execute, validate session
- Validation: repeated resource names and other duplications like context names

### P2

- Time zone still wrong in Ubuntu and
- Check if tofu requires variable and not provide it if not needed (avoids warnings).
- Documentation
  - How to start new project from the "template".
  - How to use a single PowerShell script for the several commands in a repeated block until someday implementing loop: _number(001-003)
- Finish testing and publish the resources for AWS and GCP
  - More resource templates in general
- Why renaming UTM in the macOS leaves files unbound and removable?

### P3+

- For resources created using tofu `local-exec`: destroy when doing `tofu destroy`
- Create Visual Studio Code extension to start projects, run commands, etc.
  - Visual Studio Code: [Your First Extension](https://code.visualstudio.com/api/get-started/your-first-extension)
- Graph from YML: Python [graphviz 0.15](https://pypi.org/project/graphviz/)
- Decide on copying all code during component setup (`automation/yuruna-components.psm1`)
- Generic registry login approach (`automation/yuruna-components.psm1`)

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

## VDE

- Create scripts to configure host and guest settings for Windows 11 (`vde/guest.windows.11/README.md`)
- Document Hyper-V Amazon Linux nested virtualization setup (`vde/host.windows.hyper-v/guest.amazon.linux/read.more.md`)

Back to [[Yuruna](../README.md)]
