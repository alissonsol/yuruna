# Context and components

This view maps the current implementation to seven responsibility boundaries expanded in the component breakdown.

The [canonical architecture](../architecture.md) defines the capabilities and
deployment model. These boundaries group code responsibilities; they do not
represent seven processes or seven repository directories.

```mermaid
flowchart LR
    subgraph install["Provisioning"]
    end
    subgraph automation["Deploy engine"]
    end
    subgraph test["Test harness"]
    end
    subgraph host["Providers"]
    end
    subgraph yuruna-project["Project data"]
    end
    subgraph yuruna-common-psm1["Shared modules"]
    end
    subgraph global-resources["External services"]
    end
    install -->|prepares| test
    install -->|configures| host
    install -->|checks requirements| automation
    test -->|drives| host
    host -->|imports harness modules| test
    yuruna-project -->|configuration and sources| automation
    yuruna-project -->|guest scripts invoke| automation
    yuruna-project -->|test definitions| test
    install -->|imports| yuruna-common-psm1
    automation -->|imports| yuruna-common-psm1
    test -->|imports| yuruna-common-psm1
    host -->|imports| yuruna-common-psm1
    automation -->|deploys and publishes| global-resources
    test -->|fetches and notifies| global-resources
    host -->|downloads images| global-resources
```

Each empty subgraph is a placeholder expanded by the identically titled section
in [Component breakdown](02-component-breakdown.md). The seven boxes cover these
current sources:

| Boundary | Source and scope |
| --- | --- |
| Provisioning | OS bootstrappers in [install/](../../install/), [setup.ps1](../../install/setup.ps1), [Yuruna.HostSetup](../../automation/Yuruna.HostSetup.psm1), host commands in [test/lab/](../../test/lab/), pool administration in [test/pool/](../../test/pool/), and service VM launchers in [test/service/](../../test/service/). |
| Deploy engine | [Set-Resource](../../automation/Set-Resource.ps1), [Set-Component](../../automation/Set-Component.ps1), [Set-Workload](../../automation/Set-Workload.ps1), their phase modules, validators, and [Invoke-Clear](../../automation/Invoke-Clear.ps1). |
| Test harness | [Start-TestRunner](../../test/Start-TestRunner.ps1), supervision and sequence modules in [test/modules/](../../test/modules/), [diagnostic preservation](../../test/modules/Test.DiagnosticPreservation.psm1), [test/sequences/](../../test/sequences/), [test/status/](../../test/status/), pool runtime modules, and [test/extension/](../../test/extension/). |
| Providers | The shared [host contract](../../host/Yuruna.Host.Contract.psm1), platform drivers in [host/](../../host/), shared [host/modules/](../../host/modules/), and OS scripts in [guest/](../../guest/). |
| Project data | The companion repository's [layout](https://github.com/alissonsol/yuruna-project/blob/main/README.md), [template](https://github.com/alissonsol/yuruna-project/blob/main/template/README.md), [examples](https://github.com/alissonsol/yuruna-project/blob/main/example/README.md), and [test/test.runner.yml](https://github.com/alissonsol/yuruna-project/blob/main/test/test.runner.yml). |
| Shared modules | Cross-cutting [automation/](../../automation/) libraries and guest shell helpers, reusable [global/](../../global/) assets, [globalization/](../../globalization/), and [tools/](../../tools/). |
| External services | Implemented integration points in [global/resources/](../../global/resources/), [Yuruna.CredentialProvider](../../automation/Yuruna.CredentialProvider.psm1), [Yuruna.GitHubSource](../../automation/Yuruna.GitHubSource.psm1), [Yuruna.HostDownload](../../host/modules/Yuruna.HostDownload.psm1), and [notification/](../../test/extension/notification/). |

The deploy engine and shared modules occupy the same automation directory.
Provisioning owns service launch commands; the harness owns their implementations.
The host implementations are [Windows Hyper-V](../../host/windows.hyper-v/),
[Ubuntu KVM](../../host/ubuntu.kvm/), and [macOS UTM](../../host/macos.utm/).
They select scripts for [Amazon Linux 2023](../../guest/amazon.linux.2023/),
[Ubuntu Server 24](../../guest/ubuntu.server.24/),
[Ubuntu Server 26](../../guest/ubuntu.server.26/),
[Windows 11](../../guest/windows.11/), and [macOS 26](../../guest/macos.26/).
Host drivers execute on the hypervisor host and import harness modules for
configuration, logging, SSH, and sequences; guest scripts execute in the VM and
source the automation shell helpers. GUI fetch execution crosses that boundary:
the harness [prepares and types the command](../../test/modules/Test.SequenceHandler.psm1),
while the guest [validates the envelope](../../automation/yuruna-fetch-context.sh)
before invoking the downloaded script. Project guest scripts, rather than
framework guest scripts, invoke the deploy engine inside a test guest. The
bootstrappers check tool version floors through
[Test-Requirement](../../automation/Test-Requirement.ps1).
The runner obtains project data from `repositories.projectUrl`, including
pool repository assignments, through
[Test.RunnerInnerLoop](../../test/modules/Test.RunnerInnerLoop.psm1); its runtime
project checkout is input to the harness and deploy engine.

Related module and extension families remain named aggregates to keep this view
at seven boxes. Host refresh is implemented by
[Invoke-HostRefresh](../../test/lab/Invoke-HostRefresh.ps1) and
[Test.HostRefresh](../../test/modules/Test.HostRefresh.psm1) within the provisioning
and harness boundaries. Its admission and recovery behavior is shown in
[Lifecycle](04-lifecycle-state.md). Service placement and network connections are
shown in [Deployment](06-deployment.md).

The resource directories implement localhost, AWS, and Azure; there is no
GCP resource directory or companion config/gcp deployment. Google Artifact
Registry authentication exists in the credential-provider module, and
[global/config/gcp/](../../global/config/gcp/) holds only a placeholder key file
for it. It does not
establish a GCP infrastructure deployment path, so no active GCP edge is drawn.

---

[Architecture](../architecture.md) | [Design overview](README.md)
