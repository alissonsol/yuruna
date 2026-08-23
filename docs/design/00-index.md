# Yuruna design diagrams

> One sentence: the entry point to the six diagram documents -- what each one shows, what it was read from, and which box stands for how many files.

See [Context and components](01-context-and-components.md) -
[Component breakdown](02-component-breakdown.md) - [Data flows](03-data-flows.md) -
[Lifecycle state](04-lifecycle-state.md) -
[Configuration data model](05-data-model.md) -
[Deployment topology](06-deployment.md) - [Naming conventions](naming.md) -
[Yuruna Architecture](../architecture.md).

The canonical prose design lives in [Yuruna Architecture](../architecture.md) and is
**not repeated here**. These documents are derived by reading the source: they show
what the code does rather than restate what that page says, and where one of them
needs a concept from it, it links. A diagram that disagrees with
`../architecture.md` means one of the two has drifted.

Thirty-four diagrams across six documents. Every one obeys the same acceptance rule:
no diagram holds more than seven top-level boxes or subgraphs, and no single parent
subgraph's child set holds more than seven children. Where reality holds more,
siblings are folded into a named aggregate and the fold is spelled out in the prose
under the diagram. The grouping-decisions section at the end of this page collects
every one of those folds in one place, so a box can be turned back into files without
opening all six documents.

## The documents

| Document | What it shows | Diagram types, with counts |
|---|---|---|
| [Context and components](01-context-and-components.md) | The seven level-1 blocks, the directory roots behind each one, the nineteen calls that cross between them, the two merges that hold the count at seven, and the four places where a block boundary does not follow a directory line. | `flowchart` x1 -- 7 subgraphs, exactly one node each, 19 cross-block edges |
| [Component breakdown](02-component-breakdown.md) | Each block opened one level down into at most seven children, with the exact member list and tracked-file count under every box. | `flowchart` x7 -- 7, 7, 6, 7, 6, 7, 7 boxes, in block declaration order |
| [Data flows](03-data-flows.md) | The three-phase deployment and its sidecar contract, one test cycle over one guest, the guest fetch path, failure to taxonomy to alert, agent-first image acquisition, what the two shares hold, and the per-cycle pool round trip. | `sequenceDiagram` x6 -- 7 participants each; `flowchart` x1 -- 7 boxes |
| [Lifecycle state](04-lifecycle-state.md) | The outer runner's state enum, the per-guest step lifecycle inside one cycle, the hold on a lab service that stopped answering, and the warm-resume retry loop. | `stateDiagram-v2` x4 -- 6, 7, 7, 6 states |
| [Configuration data model](05-data-model.md) | Every YAML and JSON document the deploy engine and the harness parse, as fourteen views across five areas, each with a relationships table and a fields table naming the reading module. | `erDiagram` x14 -- 7 entities in twelve of them, 3 in the requirement view, 6 in the cycle-plan view |
| [Deployment topology](06-deployment.md) | Where every process runs once a lab is deployed, the port on each link, the gate behind every conditional link, the four addresses the repository deliberately does not pin, and what a standalone host keeps with the pool tier off. | `flowchart` x1 -- 7 subgraphs over 28 leaf nodes, 36 labeled edges, 19 of them dashed |
| [Naming conventions](naming.md) | The rules a component, config key, duration, boolean, acronym, PowerShell verb, VM name, host id and page name follows, and the foreign contracts deliberately exempt. | prose, no diagram |

## How they relate

**Context and components gives you the parts.** Seven blocks, derived from the
tracked top-level directories of the two repositories rather than invented, drawn one
node per block so nothing in it can disagree with the component breakdown about how
many children a block has. It answers *what are the pieces, and what calls what*.
Read it first, and read it again whenever an arrow somewhere else looks like a
dependency you did not expect -- its edge table names the call site for all nineteen.

**Component breakdown turns a box into paths.** One section per block, in the same
order, each block expanded into at most seven children with the exact member list and
count under every aggregate. It answers *which file does this*. Read it second, and
read it any time a box in another document is a name you cannot place on disk.

**Data flows shows what moves at runtime.** Seven exchanges, six of them message
sequences and one a storage layout, chosen by frequency rather than by interest. It
answers *what happens when I run this*. Read it when tracing an artifact -- a
planfile, a screenshot, a failure record, a guest image, a cycle folder -- from the
process that writes it to the one that reads it.

**Lifecycle state shows what a long-lived thing is doing right now.** Four machines:
the runner's own enum, the per-guest step sequence inside one cycle, the hold on a lab
service that went away, and the warm-resume loop nested inside the workload step. It
answers *why is it in this state, and what gets it out*. Read it for a wedged cycle, a
pause that will not end, or a guest that keeps being skipped; the transition tables
carry the trigger, the bound and the config key for every edge.

**Configuration data model is the data underneath all of it.** Fourteen
entity-relationship views over the project deploy YAML, the cycle plan and sequence
files, the host configuration and runtime state, the pool intent store, and the
credential and extension configuration. It answers *what key goes where, and what
happens if it is missing*. Read it when authoring or debugging a config file; every
edge carries the parser reason for its cardinality and every field names its reader.

**Deployment topology puts the processes on machines.** Nodes, listeners, ports, and
the gate behind every optional link. It answers *what talks to what over the network*,
and *what does this lab still do with the pool tier turned off*. Read it when a link
is refused, when deciding what a standalone host needs, or when a port has to be
opened on something outside the lab.

**Naming conventions is the rule set the other six spell names by.** It answers *what
is this thing called, and why is that one spelled differently*. Read it before adding
a config key, a service, a PowerShell function or a page, and read the exempt table
before "fixing" a name that belongs to somebody else's schema.

Two shortcuts are worth knowing. A box in the data-flow, lifecycle or deployment
documents that you cannot place is almost always an aggregate from the component
breakdown, so start there. A field name with no obvious writer is in the data model's
fields tables, which name the module that writes each one.

## Source provenance

Each document was derived by reading code, not by reading its siblings. Paths are
repo-relative to `yuruna` except where prefixed `yuruna-project/`.

| Document | Derived from |
|---|---|
| [Context and components](01-context-and-components.md) | `git ls-tree -r --name-only HEAD` in both repositories with `.gitignore`, `.gitattributes`, `KEEP-PRIVATE.txt` and `VERSION`; the cross-boundary call sites in `automation/yuruna.ps1`, `automation/Yuruna.Resource.psm1`, `automation/Yuruna.Validation.psm1`, `automation/Yuruna.HostRedirect.psm1`, `automation/Yuruna.Retry.psm1`, `automation/Yuruna.CredentialProvider.psm1`, `automation/Yuruna.Requirement.yml` and `automation/fetch-and-execute.sh`; `global/resources/`; `guest/ubuntu.server.26/ubuntu.server.26.k8s.sh`; `host/Yuruna.Host.Contract.psm1`, `host/modules/Yuruna.Image.psm1`, `host/modules/Yuruna.UbuntuImage.psm1`, the three `host/<platform>/modules/Yuruna.Host.psm1` drivers and `host/vmconfig/*.base.user-data`; `install/ubuntu.kvm.sh`, `install/macos.utm.sh`, `install/windows.hyper-v.ps1`, `install/setup.ps1`; `tools/Update-YurunaReleasePins.ps1`, `tools/Test-AsciiNoBom.ps1`, `tools/Test-RegionAnchors.ps1`, `tools/Invoke-GoTest.ps1`, `tools/Invoke-TestSuite.ps1`; `test/modules/Test.HostBootstrap.psm1`, `test/modules/Test.HostGit.psm1`, `test/modules/Test.Log.psm1`, `test/sequences/`, `test/service/Start-McpServer.ps1`, `test/service/Start-StatusService.ps1`, `test/extension/notification/default.psm1`; `yuruna-project/example/website/config/` and `yuruna-project/example/website/test/ubuntu.server.24/ubuntu.server.24.workload.k8s.website.sh`. |
| [Component breakdown](02-component-breakdown.md) | The tracked file listing of every block root -- `automation/`, `global/`, `guest/`, `host/`, `install/`, `tools/`, `test/` and `yuruna-project/` -- read against the code that groups them: `automation/yuruna.ps1`, `automation/Set-Resource.ps1`, `automation/Yuruna.CloudInitTemplate.psm1`, `automation/Yuruna.CredentialProvider.psm1`, `automation/Yuruna.Requirement.psm1` with `automation/Yuruna.Requirement.yml`, `automation/fetch-and-execute.sh`; `global/resources/aws/registry/registry.tf`, `global/resources/azure/registry/registry.tf`, `global/resources/localhost/registry/`; `host/Yuruna.Host.Contract.psm1`, `host/modules/`, `host/vmconfig/`, `host/ubuntu.kvm/guest.ubuntu.server.26/New-VM.ps1`; `install/setup.ps1`, `install/keys/README.md`; `tools/Invoke-TestSuite.ps1`, `tools/_InvokeOneSuite.ps1`, `tools/Invoke-GoTest.ps1`, `tools/Invoke-A11yCheck.ps1`, `tools/Update-YurunaReleasePins.ps1`; `test/Test-Config.ps1`, `test/modules/Test.Extension.psm1`, `test/modules/Test.SequenceHandler.psm1`, `test/sequences/actions.yml`, `test/schemas/extension-config.schema.yml`, `test/service/Start-McpServer.ps1`, `test/extension/extension-sdk/`; `.gitattributes`, `KEEP-PRIVATE.txt`, `yuruna-project/KEEP-PRIVATE.txt`, `yuruna-project/test/test.runner.yml`. |
| [Data flows](03-data-flows.md) | `automation/Set-Resource.ps1`, `automation/Set-Component.ps1`, `automation/Set-Workload.ps1` and the `automation/Yuruna.{Resource,Component,Workload,Clear,Retry,Result,DeploymentKind,Validation}.psm1` modules behind them; `automation/Get-SystemDiagnostic.ps1`; `automation/fetch-and-execute.sh` with `automation/yuruna-host-locate.sh` and `automation/yuruna-retry.sh`; `test/Start-TestRunner.ps1`, `test/modules/Invoke-TestCycleRunner.ps1`, `test/modules/Invoke-TestRunnerInnerLoop.ps1`, `test/modules/Invoke-PoolStorageDrain.ps1`, `test/modules/Invoke-PoolPushForwarder.ps1` and the `test/modules/Test.{RunnerOuterLoop,RunnerInnerLoop,RunnerWatchdog,SequenceEngine,SequenceHandler,SequenceFailureState,FailureTaxonomy,GuestQuarantine,Remediation,Notify,PoolStorage,PoolSync,PoolPush,HostIdentity,Log,Prelude,CachingProxyService}.psm1` modules; `test/service/Start-StatusService.ps1`; `test/lab/New-Lab.ps1`; `test/test.config.yml.template`; `test/sequences/`; `test/pool/`; `test/extension/notification/default.psm1`, `test/extension/stash-service/default.psm1` and the Go packages `test/extension/{stash-service,download-agent-service,pool-control-service}/server/internal/`; `host/Yuruna.Host.Contract.psm1`, `host/modules/Yuruna.DownloadAgent.psm1`, `host/modules/Yuruna.HostDownload.psm1`, `host/ubuntu.kvm/guest.amazon.linux.2023/Get-Image.ps1`, `host/vmconfig/caching-proxy-service.base.user-data`, `host/vmconfig/ubuntu.server.base.user-data`; `guest/amazon.linux.2023/amazon.linux.2023.update.sh`, `guest/ubuntu.server.26/ubuntu.server.26.k8s.sh`, `guest/ubuntu.server.26/ubuntu.server.26.pool-control-service.sh`; `yuruna-project/example/website/test/ubuntu.server.24/ubuntu.server.24.workload.k8s.website.sh`. |
| [Lifecycle state](04-lifecycle-state.md) | `test/modules/Test.RunnerState.psm1` for the enum, the adjacency map and the boot-recovery synthetics; `test/modules/Test.RunnerOuterLoop.psm1` for every product `Set-RunnerState` call site and the failure pause; `test/modules/Test.RunnerWatchdog.psm1`, `test/modules/Test.RunnerHeartbeat.psm1`, `test/modules/Test.RunnerInnerLoop.psm1`, `test/modules/Invoke-TestRunnerInnerLoop.ps1`, `test/modules/Invoke-TestCycleRunner.ps1` and `test/Start-TestRunner.ps1` for the two processes and their bounds; `test/modules/Test.WarmResume.psm1` and `test/modules/Test.Start-GuestWorkload.psm1` for the resume loop; `test/modules/Test.LabHealth.psm1` with its call sites in `test/modules/Test.SequenceEngine.psm1` and `test/modules/Test.Orchestrator.psm1`; `test/modules/Test.SequenceResolve.psm1`, `test/modules/Test.SequenceHandler.psm1`, `test/modules/Test.GuestQuarantine.psm1`, `test/modules/Test.PoolSync.psm1`, `test/modules/Test.Backoff.psm1`, `test/modules/Test.Remediation.psm1`, `test/modules/Test.FailureTaxonomy.psm1`, `test/modules/Test.Status.psm1` and the atomic writer `test/modules/Test.StateFile.psm1`; bounds and defaults from `test/test.config.yml.template`. |
| [Configuration data model](05-data-model.md) | The deploy parsers `automation/Yuruna.Resource.psm1`, `automation/Yuruna.Component.psm1`, `automation/Yuruna.Workload.psm1`, `automation/Yuruna.Validation.psm1`, `automation/Yuruna.DeploymentKind.psm1`, `automation/Yuruna.VariableExpansion.psm1`, `automation/Yuruna.Result.psm1` and `automation/Import.Yaml.psm1`, with `automation/yuruna.ps1`; the version floors `automation/Yuruna.Requirement.yml` and their reader `automation/Yuruna.Requirement.psm1`; `global/resources/` and the project trees `yuruna-project/template/config/localhost/`, `yuruna-project/example/website/config/`, `yuruna-project/example/text-to-sql/config/localhost/` with `yuruna-project/test/test.runner.yml`; `test/test.config.yml.template` and `test/status/status.json.template`; the readers and writers `test/modules/Test.{Config,ConfigNaming,ConfigSync,ConfigValidator,SequencePlanner,RunnerState,RunnerInnerLoop,Log,Perf,Capability,PoolSync,PoolStorage,PoolAdmin,HostIdentity,HostDetection,StateFile,SequenceFailureState,GuestQuarantine,LabHealth,Extension,ExtensionService,YurunaDir}.psm1`, `test/modules/Invoke-TestRunnerInnerLoop.ps1` and `test/Test-Config.ps1`; the thirteen JSON Schemas under `test/schemas/`; `test/sequences/`; `test/pool/Test-PoolIntent.ps1` and `test/pool/Set-PoolTestSetDefinition.ps1`; `test/extension/authentication/default.psm1` with `test/extension/authentication/users.yml.template` and each area's `<area>.config.yml`. |
| [Deployment topology](06-deployment.md) | `host/Yuruna.Host.Contract.psm1`, `host/modules/Yuruna.HostDownload.psm1`, `host/modules/Yuruna.DownloadAgent.psm1`, `host/modules/Yuruna.HostProvision.psm1` and the three `host/<platform>/modules/Yuruna.Host.psm1` drivers; the cloud-init seeds `host/vmconfig/{caching-proxy-service,stash-service,download-agent-service,pool-control-service,ubuntu.server}.base.user-data`; `automation/Yuruna.Common.psm1`, `automation/Yuruna.Workload.psm1`, `automation/fetch-and-execute.sh`; the service scripts `test/service/Start-StatusService.ps1`, `Start-ConfigService.ps1`, `Start-CachingProxyServiceVM.ps1`, `Start-StashServiceVM.ps1`, `Start-PoolControlServiceVM.ps1`, `Start-DownloadAgentServiceVM.ps1`, `Move-CachingProxyService.ps1` and `Start-McpServer.ps1`; `test/modules/Test.VMUtility.psm1`, `test/modules/Test.PoolSync.psm1`, `test/modules/Test.PoolPush.psm1`, `test/modules/Test.PoolStorage.psm1`; the Go daemons and manifests under `test/extension/{caching-proxy-parser-service,caching-proxy-service,pool-aggregator-service,pool-control-service,stash-service,download-agent-service,extension-sdk}/`; `test/test.config.yml.template` and `test/lab/Set-LabToken.ps1`; `guest/ubuntu.server.26/ubuntu.server.26.k8s.sh`, `guest/ubuntu.server.24/ubuntu.server.24.k8s.sh`, `guest/ubuntu.server.26/ubuntu.server.26.download-agent-service.sh`, `guest/ubuntu.server.26/ubuntu.server.26.pool-control-service.sh`, `guest/amazon.linux.2023/amazon.linux.2023.update.sh`; `install/setup.ps1`; `global/resources/localhost/registry/localhost-registry-check.sh`, `global/resources/azure/registry/registry.tf`, `global/resources/aws/registry/registry.tf`. |
| [Naming conventions](naming.md) | `host/Yuruna.Host.Contract.psm1` for the exempt verb list, `test/modules/Test.ConfigNaming.psm1` for the retired-key table, and the component, config-key, duration, boolean, host-id and page spellings as they stand across `automation/`, `host/`, `test/` and `guest/`. |

## The <= 7 rule -- grouping decisions

This is the map from a box back to its files. The real count is what the source
holds; the fold is what the diagram had to do about it. Counts are tracked files,
`git ls-tree -r --name-only HEAD <path> | wc -l`, unless the row says otherwise.

### Doc 1 -- Context and components

The one diagram has seven subgraphs with exactly one node each, so no parent's child
set exceeds one. The folding happened one level up, when thirteen tracked directory
roots across the two repositories were reduced to seven blocks by three exclusion
classes -- documentation and maintainer trees, repository root furniture, untracked
working-tree state -- and the two merges below.

| Box | Stands for | Real count |
|---|---|---|
| `global-project` ("global/ + project repo") | `global/` and the whole `yuruna-project` repository, merged because resource-template resolution is one project-first, global-second lookup inside a single function in `automation/Yuruna.Resource.psm1` | 2 roots -- `global/` 51 tracked, `yuruna-project` 108 inside the block, 116 counting its 8 root files |
| `install-tools` ("install/ + tools/") | `install/` and `tools/`, merged because `tools/Update-YurunaReleasePins.ps1` writes and signs the `install/` manifest the bootstrappers verify themselves against | 2 roots -- `install/` 10, `tools/` 14 |
| `external-endpoints` ("clouds, registries, upstreams") | cloud control planes, container registries, the OpenTofu provider registry, GitHub, OS image publishers, package upstreams, the transactional mail API | 7 systems, 0 files |
| each block subgraph | one node standing for the whole block; the real children are drawn in the component breakdown | `automation/` 44, `global/` 51 plus project 108, `guest/` 30, `host/` 150, `install/` 10 plus `tools/` 14, `test/` 646, External Services 0 |
| the excluded roots | `docs/` 45 and `dev-only/` 63; 13 `yuruna` root files and 8 `yuruna-project` root files; the untracked `project/` clone, `test/status/<subdir>/`, `test/test.config.yml` and `install/setup.answers.*.yml` | 945 of `yuruna`'s 1066 tracked files sit inside blocks; `yuruna-project` contributes 108 of its 116 |

### Doc 2 -- Component breakdown

Forty-seven boxes over seven diagrams. Forty of them stand for files: thirty-seven
are aggregates, and three -- `guest-readme`, `host-contract` and `guided-setup` --
are single files and are marked as such. The other seven are the External Services
boxes, which own nothing on disk, so nothing in that block folds. The 212 Pester suites -- 211 under `test/modules/` and
`host/modules/Yuruna.Image.Tests.ps1` -- never get a box of their own and are counted
inside the directory that holds them.

| Block | Box | Real count | Members |
|---|---|---|---|
| Deploy Engine, 44 | `phase-entrypoints` | 5 | `yuruna.ps1`, `Set-Resource.ps1`, `Set-Component.ps1`, `Set-Workload.ps1`, `Invoke-Clear.ps1` |
| | `phase-modules` | 4 | `Yuruna.Resource.psm1`, `Yuruna.Component.psm1`, `Yuruna.Workload.psm1`, `Yuruna.Clear.psm1` |
| | `shared-contract` | 10 | `Import.Yaml.psm1`, `Invoke-DynamicExpression.psm1`, `Yuruna.Common.psm1`, `Yuruna.DeploymentKind.psm1`, `Yuruna.Log.psm1`, `Yuruna.LogLevel.psm1`, `Yuruna.Result.psm1`, `Yuruna.Retry.psm1`, `Yuruna.Validation.psm1`, `Yuruna.VariableExpansion.psm1` |
| | `registry-credentials` | 2 | `Yuruna.Component.Registry.psm1`, `Yuruna.CredentialProvider.psm1` |
| | `host-seed-modules` | 5 | `Yuruna.CloudInitTemplate.psm1`, `Yuruna.GitHubSource.psm1`, `Yuruna.GuestSeed.psm1`, `Yuruna.HostRedirect.psm1`, `Yuruna.HostSetup.psm1` |
| | `requirement-diagnostic` | 7 | `Check-DependencyVersion.ps1`, `Get-SystemDiagnostic.ps1`, `Test-Configuration.ps1`, `Test-Requirement.ps1`, `Test-Runtime.ps1`, `Yuruna.Requirement.psm1`, `Yuruna.Requirement.yml` |
| | `guest-side-runtime` | 11 | `context-copy.ps1`, `fetch-and-execute.sh`, `Set-HostAlias.ps1`, `Test-YurunaHost.ps1`, `windows-guest-bootstrap.ps1`, `yuruna-host-locate.ps1`, `yuruna-host-locate.sh`, `yuruna-network.sh`, `yuruna-retry.sh`, `yuruna-run.sh`, `yuruna-versions.sh` -- 5 + 4 + 10 + 2 + 5 + 7 + 11 = 44, the whole flat directory |
| Project & Global Data, 51 + 108 | `global-resources` | 48 | 10 OpenTofu template directories under 3 provider roots: `global/resources/aws/` 11, `global/resources/azure/` 27, `global/resources/localhost/` 10 |
| | `global-placeholders` | 3 | `global/components/placeholder`, `global/workloads/placeholder`, `global/config/gcp/gcp-access-key.json` -- 48 + 3 = 51, all of `global/` |
| | `project-template` | 7 | `yuruna-project/template/` -- `README.md`, three `config/localhost/*.yml`, and the `components/`, `resources/`, `workloads/` scaffold files |
| | `example-website` | 52 | `yuruna-project/example/website/` -- `README.md` 1, `config/` 9 across `aws`, `azure`, `localhost`, `components/` 30, `workloads/` 5, `resources/` 1, `test/` 6 |
| | `example-text-to-sql` | 41 | `yuruna-project/example/text-to-sql/` -- `README.md` 1, `config/` 3, `components/` 26, `workloads/` 5, `resources/` 1, `db/` 1, `test/` 4 |
| | `example-nested-host` | 3 | `yuruna-project/example/README.md`, `example/nested.host/README.md`, `example/nested.host/test/nested.host.yml` |
| | `book-and-runner-plan` | 5 | four `yuruna-project/book/test/*.yml` chapter sequences plus `yuruna-project/test/test.runner.yml` -- 7 + 52 + 41 + 3 + 5 = 108 |
| Guest Workloads, 30 | `amazon-linux-2023` | 6 | `guest/amazon.linux.2023/` -- `README.md` plus `code`, `n8n`, `openclaw`, `postgresql`, `update` scripts |
| | `macos-26` | 2 | `guest/macos.26/README.md`, `macos.26.update.sh` |
| | `ubuntu-server-24` | 7 | `guest/ubuntu.server.24/` -- `README.md` plus `code`, `k8s`, `n8n`, `openclaw`, `postgresql`, `update` |
| | `ubuntu-server-26` | 10 | `guest/ubuntu.server.26/` -- the same six plus `download-agent-service`, `pool-control-service`, `stash-service` builders |
| | `windows-11` | 4 | `guest/windows.11/README.md`, `windows.11.code.ps1`, `windows.11.k8s.ps1`, `windows.11.update.ps1` |
| | `guest-readme` | 1 | `guest/README.md`. A single file, not an aggregate -- 6 + 2 + 7 + 10 + 4 + 1 = 30, six boxes, no fold needed |
| Host Provisioning, 150 | `host-contract` | 1 | `host/Yuruna.Host.Contract.psm1`. A single file, not an aggregate; it declares 38 verb names in 11 comment-labeled groups |
| | `macos-utm` | 46 | `host/macos.utm/` -- 1 driver module, 9 root files, 36 files across 9 `guest.*` builder directories |
| | `ubuntu-kvm` | 30 | `host/ubuntu.kvm/` -- 2 modules, 6 root files, 22 files across 8 `guest.*` directories |
| | `windows-hyper-v` | 32 | `host/windows.hyper-v/` -- 1 driver module, 6 root files, 25 files across 8 `guest.*` directories |
| | `host-modules` | 8 | `Yuruna.DownloadAgent.psm1`, `Yuruna.HostDownload.psm1`, `Yuruna.HostProvision.psm1`, `Yuruna.Image.psm1`, `Yuruna.Image.Tests.ps1`, `Yuruna.UbuntuImage.psm1`, `Yuruna.VMCleanup.psm1`, `keys/ubuntu-image-signing-keys.asc` |
| | `host-vmconfig` | 31 | 6 `*.base.user-data`, 6 `*.meta-data`, 18 `*.overlay.yml` (three per family), `guest-dhcp.network-config`; no script of any kind |
| | `host-docs` | 2 | `host/README.md`, `host/read.more.md` -- 1 + 46 + 30 + 32 + 8 + 31 + 2 = 150 |
| Installers, 10 + 14 | `platform-bootstrappers` | 3 | `install/macos.utm.sh`, `install/ubuntu.kvm.sh`, `install/windows.hyper-v.ps1` |
| | `guided-setup` | 1 | `install/setup.ps1`. A single file, not an aggregate; its untracked answer file is not in the count of 10 |
| | `release-manifest` | 6 | `install/install.sha256`, `install/install.sha256.sig`, `install/keys/yuruna-release-signing.pub.pem`, `install/keys/yuruna-release-signing.pub.xml`, `install/keys/README.md`, `install/README.md` |
| | `repo-gates` | 6 | `tools/Invoke-Lint.ps1`, `tools/Invoke-ShellCheck.ps1`, `tools/Test-AsciiNoBom.ps1`, `tools/Test-RegionAnchors.ps1`, `tools/Invoke-Es5Check.ps1`, `tools/Invoke-A11yCheck.ps1` |
| | `suite-runners` | 4 | `tools/Invoke-TestSuite.ps1`, `tools/_InvokeOneSuite.ps1`, `tools/Invoke-GoTest.ps1`, `tools/Invoke-JsTest.ps1` |
| | `maintenance-tools` | 4 | `tools/Export-GeneratedPages.ps1`, `tools/Update-TestConfigNaming.ps1`, `tools/Update-YurunaReleasePins.ps1`, `tools/githooks/pre-commit` -- 3 + 1 + 6 + 6 + 4 + 4 = 24 |
| Test Harness, 646 | `runner-entrypoints` | 11 | every file at the `test/` root: `Debug-TestSequence.ps1`, `Invoke-TestProject.ps1`, `New-LocalTestUser.ps1`, `README.md`, `read.more.md`, `Remove-TestVMFiles.ps1`, `Start-TestRunner.ps1`, `Test-CachingProxyService.ps1`, `Test-Config.ps1`, `test-localhost.sh`, `test.config.yml.template` |
| | `runner-modules` | 315 | `test/modules/` -- 97 `.psm1`, 211 `*.Tests.ps1`, 5 loose `.ps1` (`Invoke-TestCycleRunner`, `Invoke-TestRunnerInnerLoop`, `Invoke-HostAddressBeacon`, `Invoke-PoolPushForwarder`, `Invoke-PoolStorageDrain`), `README.md`, `suite-baseline.json`; all 97 module names are listed in that section |
| | `extension-areas` | 231 | `test/extension/` -- 9 area directories plus `ui-pages.test.js`: `authentication` 4, `caching-proxy-parser-service` 11, `caching-proxy-service` 15, `download-agent-service` 47, `extension-sdk` 13, `notification` 4, `pool-aggregator-service` 27, `pool-control-service` 54, `stash-service` 55 |
| | `sequence-schema-data` | 32 | a fold of two directories: `test/sequences/` 19 (`actions.yml`, `_snippets.yml`, 7 `start.guest.*`, 10 `workload.guest.*`) and `test/schemas/` 13 |
| | `service-scripts` | 16 | `test/service/` -- 7 `Start-*`, 6 `Stop-*`, `Move-CachingProxyService.ps1`, `Repair-CachingProxyServiceForwarder.ps1`, `README.md` |
| | `pool-lab-cli` | 28 | a fold of two directories: `test/pool/` 16 (13 `.ps1`, `README.md`, 2 examples) and `test/lab/` 12 (10 `.ps1`, `README.md`, `yuruna-churn.sudoers`) |
| | `status-ui-check` | 13 | a fold of two directories: `test/status/` 10 tracked root files and `test/check/` 3 -- 11 + 315 + 231 + 32 + 16 + 28 + 13 = 646; ten children folded to seven by the three two-directory boxes above |
| External Services, 0 | all seven boxes | 0 files each | `cloud-control-planes`, `opentofu-provider-registry`, `container-registries`, `github`, `os-image-publishers`, `package-upstreams`, `resend-email-api`. This block owns nothing on disk, so each box is a system and its citation is the in-repo call site |

### Doc 3 -- Data flows

Each diagram carries only actors that exchange a message, so the folds here name
processes and file sets rather than directories.

| Diagram | Box | Real count | Members |
|---|---|---|---|
| A. Three-phase deployment | `tool` | 4 | `tofu`, `docker`, `kubectl`, `helm`; only `tofu` is named in the engine, the rest come from config command strings |
| | `files` | 14 | `terraform.tfvars`, `tofu.planfile`, `tofu.stderr.log`, `tofu.rc`, `.workfolder.complete`, `resources.output.yml`, `docker.stderr.log`, `docker.rc`, `values.yaml`, `helm.stderr.log`, `helm.rc`, `<toolName>.stderr.log`, `<toolName>.rc`, `<phase>.<yyyy-MM-dd-HH-mm-ss>.yml` |
| B. One test cycle | `outer runner processes` | 2 | `test/Start-TestRunner.ps1` (resident) and `test/modules/Invoke-TestCycleRunner.ps1` (one fresh `pwsh` per cycle) |
| | `Invoke-Sequence` | 4 | `test/modules/Test.SequenceEngine.psm1`, `Test.SequenceHandler.psm1`, `Test.OcrMatch.psm1`, `Test.OcrEngine.psm1` |
| | `status.json and NDJSON` | 3 | `runtime/status.json`, the per-cycle `cycle.events.ndjson`, and the cycle folder that holds it |
| | `Yuruna.Host driver` | 1 of 3 | whichever of `host/windows.hyper-v/`, `host/ubuntu.kvm/`, `host/macos.utm/` `modules/Yuruna.Host.psm1` was loaded; all three export the same 38 contract verbs |
| | the watchdog | 1, excluded | `Start-Watchdog` exchanges no message with any participant -- only runtime-dir files and a signal -- so it is described in prose instead of drawn |
| C. Guest fetch | `origin` | 2 named legs plus a class | `https://api.github.com/repos/...` and `https://raw.githubusercontent.com/...`, plus the distribution and vendor archives squid reaches on a MISS; enumerated as members of External Services in docs 1 and 2 |
| D. Failure, taxonomy, alert | `cycle folder files` | 4 | `last_failure.json`, `last_remediation.json`, `notification.delivery.json`, `cycle.events.ndjson` |
| E. Image acquisition | `pool share images tree` | 5 named entries | `images/`, `images/.agent-lease.json`, `images/<hostType>/<imageKey>/current.<arch>.<variant>.json`, `.../.staging/`, `.../manual/<arch>.<variant>/`, each a row in the share table in section F |
| F. Pool share layout | `service-state` | 2 | `download-agent-service/` and `pool-control-service/` at the pool root, each holding `audit.jsonl` and `status.json` |
| | `hosts` | 4 rows | `hosts/info.<hostId>.yml`, `hosts/<hostId>/`, `hosts/<hostId>/test-cycles/<cycle>/`, `hosts/<hostId>/services/caching-proxy-service/` |
| | `images` | 5 rows | `images/`, `images/.agent-lease.json`, `images/<hostType>/<imageKey>/current.<arch>.<variant>.json`, `images/<hostType>/<imageKey>/.staging/`, `images/<hostType>/<imageKey>/manual/<arch>.<variant>/` |
| | `stash-host-tree` | 3 rows | `<hostId>/hostkey/stash_host_ed25519`, `<hostId>/files/<YYYY>/<MM>/<DD>/`, the `.yuruna.meta.json` sidecar beside each artifact -- the section's table resolves all 15 rows of both shares |
| G. Per-cycle pool round trip | `runtime state files` | 3 | `runtime/pool.state.json`, `runtime/pool.manifest.json`, `runtime/poolstorage.state.json` |

### Doc 4 -- Lifecycle state

Two of the four machines are at the cap of seven states -- the per-guest step
lifecycle and the lab-service hold. Most folds here sit on edges rather than in
boxes: a state machine's boxes are its enum, so what has to be aggregated is the
trigger set on a transition. The one box fold is the lab-service hold's `ok`.

| Diagram | Fold | Real count | Members |
|---|---|---|---|
| Outer runner | none | 6 | `$script:StateEnum` has exactly six members: `idle`, `cycle-start`, `in-cycle`, `cycle-end`, `fault`, `paused` |
| | the `paused --> idle` edge | 6 | the failure-pause break-out triggers: new framework commit, new project commit, local `test.config.yml` mtime change, `runtime/control.cycle-restart`, gated auto-remediation, cap elapsed or shutdown requested |
| Per-guest step lifecycle | states, at the cap | 7 | six literal `-StepName` values (`New-VM`, `Start-VM`, `Start-GuestOS`, `New-VM.Resource`, `Screenshots`, `Start-GuestWorkload`) plus the `Cleanup` stage name -- no aggregate needed |
| | the `[*] --> New-VM` edge, entry gates | 3 | the quarantine gate skip, a requested shutdown, membership in `$FailedGuests` |
| | the same edge, preparation | 4 | create the per-guest data folder and record its URL, delete stale `failure_screenshot_<VM>.png` and `failure_ocr_<VM>.txt`, force-stop other cycle VMs on a host with four or fewer processors, `Remove-GuestVMQuietly -SkipStop` |
| | every `fail` edge | 5 | `Set-StepStatus fail`, `Set-GuestStatus fail`, the four `$IterState` fields, `Write-CycleInfraFailure` where the class is infra, `Copy-FailureArtifactsToStatusLog`, all before the stop-on-failure branch |
| Lab-service hold | the `ok` box | 3 verdicts | `ok` and `unknown` are drawn as one box because the hold returns its idle result for any verdict that is not `down`; `down` is its own state |
| Warm-resume retry loop | none | 6 | `Start-GuestWorkload`, `Read-WarmResumeCheckpoint`, `Get-WarmResumeDecision`, `Get-WarmResumeRewindStep`, `Test-WarmResumeReplayIsSafe`, the `ResumeFromStep` re-invocation |
| | the `decision --> [*]` edge | 5 | the decline reasons in evaluation order: `disabled`, `class-not-eligible`, `no-resume-step`, `no-sequence-name`, `sequence-not-in-workload` |
| | eligible classes, named not drawn | 6 | `network_timeout`, `wait_timeout`, `instrumentation_failure`, `host_io_blocked`, `ip_not_discovered`, `payload_unavailable` |

### Doc 5 -- Configuration data model

Twelve of the fourteen views sit at exactly seven entities, so the folds here move a
detail into a fields table rather than dropping it.

| View | Fold | Real count | Members |
|---|---|---|---|
| Workloads phase | the merged deployment variable bag is not drawn -- it is memory, not a document | 4 layers | `resources.output.yml`, `workloads.globalVariables`, `workload.variables`, `deployment.variables` |
| Host configuration | `service_keys` | 4 | `configService`, `downloadAgentService`, `notification`, `statusService` |
| | `vm_and_guest_keys` | 5 | `guestSequence`, `logLevel`, `vmCommunication`, `vmImage`, `vmStart`; with the four keys drawn verbatim that is the template's 13 top-level keys in 6 boxes |
| Runtime state | `PoolSyncState` | 2 | `runtime/pool.state.json`, `runtime/pool.manifest.json` |
| | `CycleGateState` | 3 | `runtime/runner.gating.json`, `runtime/runner.quarantine.json`, `runtime/lab-health.json` |
| Per-cycle results | `GuestArtifacts` | 2 per guest | the data folder `<vmName>/` and the screen ring `screens_<vmName>/`, both created lazily |
| | `ArtifactEntry` folded into `CycleManifest` | 5 fields | `path`, `kind`, `sizeBytes`, `sha256`, `modifiedUtc`, listed in that view's fields table |
| Pool intent | `rules[]` folded into `guests_compatibility_yml` | 3 fields | `guestKey`, `hypervisors[]`, `notes` -- one rule shape, spelled out in the fields table |
| Extension configuration | `ServiceManifest` | 5 of 8 | nine directories under `test/extension/`, eight carrying a config (`extension-sdk` carries none), five of those declaring a `service` block: `caching-proxy-service`, `download-agent-service`, `pool-aggregator-service`, `pool-control-service`, `stash-service` |

### Doc 6 -- Deployment topology

Seven subgraphs over 28 leaf nodes; the largest child sets are the hypervisor host and
the caching-proxy VM, each at exactly seven.

| Fold | Real count | Members |
|---|---|---|
| ten node classes drawn as seven subgraphs | 10 | operator workstation, hypervisor host, caching-proxy VM, stash VM, pool-control VM, download-agent VM, pool-aggregator service, test guests, storage tier, target cluster plus registry. Two folds bring it to seven: the three single-purpose service VMs become one `Extension Service VMs` subgraph, and `pool-aggregator-service` is drawn inside the caching-proxy VM because its manifest declares `hostedIn: caching-proxy-service` instead of a `vmName` |
| `Extension Service VMs` | 3 | `yuruna-stash-service`, `yuruna-pool-control-service`, `yuruna-download-agent-service`, each still its own child so no link is lost |
| `Proxy management daemons` | 2 | `caching-proxy-parser-service` on `9302`, `caching-proxy-service` on `0.0.0.0:9310` |
| `Loopback telemetry` | 5 processes, 6 listeners | Prometheus `127.0.0.1:9090`, prometheus-node-exporter `:9100`, Loki `:3100` HTTP with `:9096` gRPC, promtail `:9080`, squid-exporter `:9301`; none has a LAN link of its own |
| `squid` | 5 listeners | `3128` plain, `3129` ssl-bump, `3138` and `3139` the `require-proxy-header` twins, `3130` the TLS `cache_peer` port that exists only during a cache handover |
| `Add-PortMap forwarders` | 3 mechanisms, 6 ports | `netsh portproxy v4tov4` on windows.hyper-v, socket-activated `systemd-socket-proxyd` units on ubuntu.kvm, per-port `pwsh` `TcpListener` forwarders on macos.utm; the LAN set is `80`, `3000`, `9302`, `9400` plus the client-facing squid HTTP and HTTPS ports |
| `Disposable guest VM` | 5 guest keys | `guest.amazon.linux.2023`, `guest.ubuntu.server.24`, `guest.ubuntu.server.26`, `guest.windows.11` on all three drivers and `guest.macos.26` on macos.utm only -- 5 of the 9 distinct `guest.*` keys, built by 25 builder directories (9 macos.utm, 8 ubuntu.kvm, 8 windows.hyper-v) |
| `Browser` | 5 UIs plus Grafana | `test/status/index.html`, `test/extension/caching-proxy-service/` with its `landing.go` / `ui.go` page, and the `server/internal/httpsrv/web/` roots under `pool-control-service`, `stash-service` and `download-agent-service`; plus Grafana on `:3000` |
| `test/pool and test/lab` | 23 scripts | 13 `.ps1` under `test/pool/`, 10 under `test/lab/` |
| storage tier, 3 children | 2 shares plus 1 repository | the `yuruna.pool` and `yuruna.stash` SMB3 shares, plus `pool-intent.git`, which lives on the pool share and is drawn separately because two transports reach it |

Each document also states what it deliberately leaves undrawn and why -- the paths
outside the block set in [Context and components](01-context-and-components.md), the
excluded suites in [Component breakdown](02-component-breakdown.md), and the
dispatch tables, counter pairs and one-shot sequences in
[Lifecycle state](04-lifecycle-state.md).
