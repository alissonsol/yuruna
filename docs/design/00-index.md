# Yuruna design diagrams

> One sentence: the entry point to Yuruna's generated design diagrams -- what
> each shows, how they relate, and where each was derived from.

See [Context and components](01-context-and-components.md) - [Naming conventions](naming.md) -
[Yuruna Architecture](../architecture.md).

This set is **generated from source** and meant to be regenerated as the code
evolves. The canonical prose architecture -- the three capabilities and the
three-phase model -- is [Yuruna Architecture](../architecture.md); these diagrams
visualize it rather than restate it. Nothing here repeats that page: when a
diagram needs a concept from it, it links instead of explaining. Twenty-two
diagrams across six documents, each one derived by reading the code rather than
the prose, so a diagram disagreeing with `architecture.md` is a signal that one
of them has drifted.

## The documents

| # | Document | Diagram type(s) | Shows |
|---|----------|-----------------|-------|
| 1 | [Context and components](01-context-and-components.md) | flowchart x1 (7 boxes) | The seven top-level building blocks and the thirteen edges between them, plus the edges that are easy to misread and the one that is absent on purpose. |
| 2 | [Component breakdown](02-component-breakdown.md) | flowchart x7 (7, 7, 5, 7, 6, 7, 7 boxes) | Each block from doc 1 opened into at most seven real scripts, modules or directories, each diagram followed by a table mapping every box to its paths. |
| 3 | [Data flows](03-data-flows.md) | sequenceDiagram x6 (7, 7, 7, 7, 6, 7 participants) | Three-phase deployment, one test cycle, the guest repo/proxy/stash fetch, failure->taxonomy->alert, agent-first image acquisition, and what lives on the shared storage. |
| 4 | [Lifecycle state](04-lifecycle-state.md) | stateDiagram-v2 x3 (6, 7, 6 states) | The outer runner's six-state machine and all twelve valid transitions, the per-guest step lifecycle inside `in-cycle`, and the warm-resume retry nested inside `Start-GuestWorkload`. |
| 5 | [Configuration data model](05-data-model.md) | erDiagram x4 (7 entities each) | Project deploy YAML, the project's cycle plan and sequences, harness runtime data, and pool intent -- each with a relationships table marking every edge *engine* or *convention*. |
| 6 | [Deployment topology](06-deployment.md) | flowchart x1 (7 subgraphs, 15 boxes) | The seven network nodes, what runs on each, the exact script that brings it up, and the gate behind each of the eighteen dashed edges. |
| -- | [Naming conventions](naming.md) | prose (no diagram) | The rules every component, config key, duration, boolean, acronym, verb and page name follows, and the foreign contracts deliberately exempt from them. |

## How they relate

- **Doc 1 names the blocks; doc 2 opens each one; doc 6 places those same blocks
  on a network.** Doc 1's `subgraph`s are placeholders by construction -- one node
  each -- so that doc 2 owns every expansion and the two can never disagree about
  how many children a block has.
- **Doc 3 shows what moves *between* blocks at runtime; doc 4 shows the *states*
  the harness passes through while doc 3's flow B runs.** Where flow B draws one
  `New-VM` message, doc 4 draws the six-step machine that message sits inside.
- **Doc 5 is the *data* docs 1-3 read and write.** Its four erDiagrams are the
  static shape of the project YAML the engine parses, the cycle plan the harness
  resolves, the runtime config and vaults, and the pool intent store. Anything
  that is *generated* state rather than authored configuration -- work folders,
  `resources.output.yml`'s on-disk tree, the download pool layout -- is drawn in
  doc 3 instead, because it lives in no repository.
- **Doc 6 is the only place ports, protocols and process co-residency appear.**
  Docs 1-3 deliberately name no port, so a topology change touches one document.
- **Doc 2 and doc 6 disagree about `test/` on purpose.** By directory, the Go
  daemons under `test/extension/*/server/` belong to the Test Harness block; by
  deployment they run inside their own service VMs. Doc 2 draws the directory,
  doc 6 draws the machine.
- **Reading order.** 1 -> 2 for structure, 3 -> 4 for behavior, 5 for the data,
  6 for where it all runs. `naming.md` is orthogonal: it explains why the
  identifiers in every other document are spelled the way they are.

## Source provenance

Each row lists the real primary sources the document was derived from. Every
path below exists in the working tree at the last review date; paths without a
repository prefix are relative to **yuruna**.

| Document | Primary sources |
|----------|-----------------|
| 1 | `automation/` -- `fetch-and-execute.sh`, `Yuruna.{HostRedirect,CloudInitTemplate,GuestSeed,HostSetup}.psm1`; `global/config/gcp/`, `global/resources/`; `guest/`, `guest/ubuntu.server.{24,26}/ubuntu.server.{24,26}.k8s.sh`; `host/Yuruna.Host.Contract.psm1`, `host/modules/Yuruna.DownloadAgent.psm1`, `host/ubuntu.kvm/{Enable-TestAutomation.ps1,guest.ubuntu.server.26/New-VM.ps1}`; `install/{setup.ps1,windows.hyper-v.ps1,ubuntu.kvm.sh,macos.utm.sh}`; `tools/`; `test/Debug-TestSequence.ps1`, `test/lab/Enable-TestAutomation.ps1`, `test/modules/{Test.HostBootstrap,Test.HostGit,Test.SequencePlanner,Test.Orchestrator}.psm1`, `test/modules/Test.AuEntry.Tests.ps1`, `test/extension/notification/default.psm1`; `.gitignore`; `yuruna-project/example/website/` including `test/workload.guest.ubuntu.server.26.k8s.website.yml` and `test/ubuntu.server.26/ubuntu.server.26.workload.k8s.website.sh` |
| 2 | `automation/` -- `Set-{Resource,Component,Workload}.ps1`, `yuruna.ps1`, `Yuruna.{DeploymentKind,Common,Log}.psm1`; `host/Yuruna.Host.Contract.psm1`, `host/modules/`, `host/vmconfig/`, `host/{windows.hyper-v,ubuntu.kvm,macos.utm}/`, `host/ubuntu.kvm/modules/Yuruna.GuestRail.psm1`; `guest/`; `install/`, `install/install.sha256`, `install/keys/`; `tools/`; `test/`, `test/{modules,sequences,schemas,extension,pool,lab,service,check}/`; `global/`; `yuruna-project/{example,template}/`, `yuruna-project/book/test/`, `yuruna-project/test/test.runner.yml` |
| 3 | `automation/Set-{Resource,Component,Workload}.ps1`, `automation/Yuruna.{Resource,Component,Component.Registry,CredentialProvider,Workload,DeploymentKind,Retry,Result,VariableExpansion,GitHubSource}.psm1`, `automation/Invoke-DynamicExpression.psm1`, `automation/Get-SystemDiagnostic.ps1`, `automation/{fetch-and-execute,yuruna-host-locate}.sh`; `test/Start-TestRunner.ps1`, `test/service/Start-StatusService.ps1`, `test/modules/{Invoke-TestCycleRunner,Invoke-TestRunnerInnerLoop,Invoke-PoolStorageDrain}.ps1`, `test/modules/Test.{RunnerOuterLoop,RunnerInnerLoop,RunnerWatchdog,SequenceEngine,SequenceAction,SequenceHandler,SequenceFailureState,SequencePlanner,FailureTaxonomy,EventSchema,Status,Log,OcrEngine,OcrMatch,Diagnostic,Remediation,Notify,PoolStorage,PoolNotifier,PoolAdmin,HostIdentity,GuestQuarantine,HostContract}.psm1`; `host/Yuruna.Host.Contract.psm1`, `host/modules/Yuruna.{DownloadAgent,UbuntuImage,Image,HostDownload}.psm1`, `host/vmconfig/{ubuntu.server,caching-proxy-service,stash-service}.base.user-data`; `test/extension/stash-service/default.psm1` and `.../server/internal/{config/config.go,store/store.go,httpsrv/handlers.go}`, `test/extension/download-agent-service/server/internal/{config/config.go,imagestore/store.go,imagestore/lease.go,state/state.go}`, `test/extension/pool-control-service/server/internal/state/state.go`, `test/extension/pool-aggregator-service/main.go`, `test/extension/notification/default.psm1`; `yuruna-project/example/website/test/ubuntu.server.26/ubuntu.server.26.workload.k8s.website.sh` |
| 4 | `test/modules/Test.{RunnerState,RunnerOuterLoop,RunnerInnerLoop,RunnerWatchdog,WarmResume,EventSchema,Diagnostic}.psm1`, `test/modules/{Invoke-TestCycleRunner,Invoke-TestRunnerInnerLoop}.ps1`, `test/Start-TestRunner.ps1`; [runner-outer-loop.md](../runner-outer-loop.md#runner-state-machine) |
| 5 | `yuruna-project/{example,template}/`, `yuruna-project/book/test/`, `yuruna-project/test/test.runner.yml`; `automation/Yuruna.{Resource,Component,Workload,Validation,DeploymentKind,VariableExpansion}.psm1`, `automation/Import.Yaml.psm1`; `test/test.config.yml.template`, `test/Test-Config.ps1`, `test/schemas/`, `test/lab/New-Lab.ps1`, `test/pool/examples/`; `test/modules/Test.{SequenceResolve,SequencePlanner,RunnerInnerLoop,HostDetection,PoolPlanner,Capability,ExtensionService,EventSchema,FailureTaxonomy,Perf}.psm1` |
| 6 | `test/Start-TestRunner.ps1`, `test/service/Start-StatusService.ps1`, `test/service/Start-{ConfigService,CachingProxyServiceVM,StashServiceVM,PoolControlServiceVM,DownloadAgentServiceVM}.ps1`, `test/service/Move-CachingProxyService.ps1`, `test/test.config.yml.template`; `test/modules/Test.{PoolStorage,PoolSync,PoolPush,PoolNotifier,ExtensionService,VMUtility}.psm1`, `test/modules/{Invoke-PoolPushForwarder,Invoke-PoolStorageDrain}.ps1`, `test/pool/Sync-PoolDashboardOnProxy.ps1`; `test/extension/pool-aggregator-service/{main.go,pool-aggregator-service.config.yml}`, `test/extension/{stash-service,pool-control-service,download-agent-service}/*.config.yml`; `host/vmconfig/caching-proxy-service.base.user-data`, `host/modules/Yuruna.DownloadAgent.psm1`; `guest/ubuntu.server.26/ubuntu.server.26.{stash,pool-control,download-agent}-service.sh`; `automation/Set-Resource.ps1`, `install/setup.ps1` |
| -- | `naming.md` is authored, not derived. Its two machine-checkable claims point at `host/Yuruna.Host.Contract.psm1` (the exempt `VM` verbs) and `test/modules/Test.ConfigNaming.psm1` (the retired-key table both `test/Test-Config.ps1` and `tools/Update-TestConfigNaming.ps1` read). |

## The ≤7 rule — grouping decisions

Every diagram, and every parent's child set inside one, shows **at most seven
boxes**. Where reality exceeds seven, siblings are grouped under a named
aggregate and the fold is stated with its real count. Doc 6 is the one apparent
exception and is not one: it has fifteen boxes but seven `subgraph` network
nodes, the largest holding four children.

**Doc 1 -- the seven blocks**

- `tools/` (7 entries) is folded into **Installers** rather than drawn as an
  eighth block, because the signed integrity artifacts under `install/` are its
  output; its remaining entries are development gates, not shipped artifacts.
- `global/` is folded into **Project & Global Data** rather than into the Deploy
  Engine, because `global/resources/<template>` is the fallback a project's own
  `resources/` folder resolves to -- one data plane with two roots.
- The harness-maintained clone at `<RepoRoot>/project/` is folded into **Project
  & Global Data** rather than drawn as its own node, even though it is in
  neither repository and the harness re-creates it every cycle.
- The four infra-service guests and the Go daemons under
  `test/extension/*/server/` stay inside the **Test Harness** block rather than
  becoming their own top-level node; doc 6 places them on the network instead.
- **External Services** is one block covering seven distinct third parties --
  clouds, registries, clusters, GitHub, upstream mirrors, OCR engines and the
  Resend email API -- so the edges that leave the machine are visible without an
  eighth block; doc 2 opens it into its seven children.
- Each of the seven blocks is a `subgraph` wrapping exactly one placeholder node,
  so the diagram reads as seven top-level components and doc 2 owns every
  expansion.

**Doc 2 -- the seven breakdowns**

- **Deploy Engine**: the 44 files in `automation/` fold to 7 boxes drawing 6 of
  the 15 `.ps1`, 13 of the 22 `.psm1` and all 6 `.sh`; the remaining 9 `.ps1` and
  9 `.psm1` are enumerated in prose.
- **Deploy Engine**: the six `automation/*.sh` files collapse into one
  guest-runtime box labelled `fetch-and-execute.sh + 5 guest shell libs` and are
  named individually in the grounding table.
- **Project & Global Data**: the three sequence roots in `yuruna-project` -- each
  project's `test/`, the repo-level `test/test.runner.yml`, and `book/test/`'s
  narrated sequences -- share one box; doc 5 gives them separate entities.
- **Guest Workloads**: no fold -- all five family directories are drawn. The 24
  scripts inside them become a count on their family box (5 / 6 / 9 / 3 / 1), and
  the three infra bring-ups stay annotated inside `ubuntu.server.26` rather than
  becoming a sixth box, since no such directory exists.
- **Host Provisioning**: the 25 `guest.<key>/` folders (8 `windows.hyper-v` + 8
  `ubuntu.kvm` + 9 `macos.utm`) collapse into a count on their provider node,
  because they nest one level below `host/`.
- **Host Provisioning**: the four infra guests are drawn as one logical aggregate
  box on dotted edges -- they exist as siblings inside each provider, 12
  directories in all, not at the `host/` root.
- **Host Provisioning**: the six `host/modules/*.psm1` collapse to one **modules**
  box, and the `README.md` / `read.more.md` files throughout `host/` are omitted.
- **Installers**: `install/` (the three bootstrappers, `setup.ps1`, `README.md`,
  the two signature artifacts and `keys/`) plus `tools/`'s 7 entries fold to 6
  boxes -- the two signature files and the three `keys/` entries become one
  integrity box, while `Invoke-Lint.ps1`, `Sync-ExtensionSdk.ps1`,
  `Update-TestConfigNaming.ps1`, `Test-RegionAnchors.ps1` and
  `githooks/pre-commit` stay in prose as development gates.
- **Test Harness**: 50 tracked non-test `.ps1`, 94 `.psm1` under `test/modules/`
  and 175 tracked Pester files fold to 7 boxes; the admin box is the widest fold,
  standing for `test/service/` (14), `test/pool/` (13), `test/lab/` (9) and
  `test/check/` (2).
- **Test Harness**: the 175 tracked Pester suites are counted, never drawn -- they mirror
  the modules beside them.
- **External Services**: no fold -- seven external dependencies, seven boxes.

**Doc 3 -- the six flows**

- Every diagram declares only the participants that actually exchange messages,
  so none exceeds seven: five sit exactly at seven and the image-acquisition flow
  at six.
- **Flow B**: the OCR stack is a self-message on the InnerRunner rather than an
  eighth participant, because `Test.OcrEngine.psm1` genuinely runs inside the
  inner process -- Tesseract in-process, WinRT via a PS 5.1 worker, macOS Vision
  via a cached `swiftc` binary.
- **Flow B**: one `Host contract` box stands for the whole 38-verb
  `host/Yuruna.Host.Contract.psm1` surface and the three per-provider drivers
  behind it.
- **Flow E**: the download-agent's three-rung discovery ladder (operator pin,
  local VM, pool aggregator) is one aggregator arrow plus prose rather than three
  participants.
- **Flow F**: the detached `Invoke-PoolStorageDrain.ps1` and the in-process
  `Invoke-PoolNotifierCycle` fold into a single `Runner host` participant -- two
  writers on the same machine -- so both shares stay visible as separate boxes.
- **Flow F**: the on-share tree is a fenced code block rather than more
  participants, keeping the seven boxes at five writers plus two shares.

**Doc 4 -- the three machines**

- **Outer runner**: no fold at all -- the six boxes are exactly
  `$script:StateEnum` and the twelve edges are exactly `$script:ValidTransition`,
  so the diagram *is* the constant rather than a summary of it.
- **Outer runner**: the watchdog is not a state. It is the mechanism that forces
  `in-cycle -> fault`, so its arm / bound / kill / disarm / attribute / restart
  stages are a table under the diagram instead of a seventh and eighth box.
- **Outer runner**: the eight `Invoke-OuterCycleDispatch` outcomes (completed,
  pull-error, drain, paused, storage-full, spawn-failed, cycle-aborted, shutdown)
  are a table rather than states, because four of them return without any
  transition and leave the machine where the child left it.
- **Per-guest lifecycle**: teardown is the exit *transition* rather than an
  eighth state, so a `Cleanup` failure is a second edge out of the machine rather
  than an edge into the failure-capture box.
- **Per-guest lifecycle**: the six step-failure branches share one
  `Copy-FailureArtifacts` box rather than six, since all six run the identical
  five-statement failure block and differ only in `FailedStep`.
- **Warm resume**: the five literal `Get-WarmResumeDecision` refusal reasons
  collapse into one `attempts exhausted` state and are enumerated in the
  transition table, because each is a distinct string on one return path rather
  than a distinct place the loop can sit. The sixth exit -- a rewind that finds no
  restore point in front of a step that ran guest work -- stays a drawn edge,
  because it leaves from a different box.

**Doc 5 -- the four data views**

- The model is split into **four** erDiagrams -- project deploy, cycle plan and
  sequences, harness runtime, pool intent -- so none exceeds seven entities; each
  lands on exactly seven.
- **Cycle plan**: the 17 framework sequence files under `test/sequences/` plus
  every project's own sequence files are one `SEQUENCE` entity, and the two
  snippet libraries (framework `test/sequences/_snippets.yml` and a project's
  own `_snippets.yml`) are one `SNIPPET_LIB`, because they are the same shape and
  a project name overrides a framework name of the same key.
- **Harness runtime**: three real siblings are folded into notes rather than
  drawn -- the per-guest driver folder `host/<short-host>/<guestKey>/` every
  `guestKey` must resolve to, the rest of `test/status/runtime/`, and the
  `service:` block an extension area's config may declare.
- **Pool intent**: the 13 admin CLIs under `test/pool/` that author these files
  are not entities (doc 2 draws them), and the per-host runtime projections
  `runtime/pool.state.json` and `runtime/pool.manifest.json` are cycle state and
  belong to doc 4.

**Doc 6 -- the seven network nodes**

- Roughly twenty deployed processes group into seven `subgraph` network nodes,
  fifteen boxes in all, with the largest subgraph -- the runner host -- at four
  children.
- The caching-proxy VM's fifteen long-lived listeners and eight timers fold into
  one box, because drawing them alone would exceed the seven-child budget.
- The stash VM's two listeners (`:22` SCP sink and `:80` UI) fold into one box
  because they are one process, and the fold is named in both the box label and
  the node table.
- The runner host's three detached per-cycle sidecars and its long-lived
  host-address beacon fold into the runner box rather than becoming peers of the
  status and config services.
- The three infra-service VMs' presence-beacon and CIFS edges stay per-service
  rather than becoming an aggregate node: the CIFS edges each carry a different
  gate, and the three identical beacons share one gate-table row while staying
  three edges on the diagram.
- The NAS is a single box covering both the pool share and the separate stash
  share; what the pool share holds is enumerated in prose instead of splitting
  the box.

## What is deliberately not drawn

- **Anything planned.** GCP/GKE appear only as a named gap: `global/config/gcp`
  holds a credential stub with no matching templates under `global/resources/`.
  Two `%% planned` comments in doc 5 mark the other two: a `gcp` `CLOUD_CONFIG`
  parses but has no templates, and `HOST_REGISTRATION.supportedGuests` /
  `.capacity` are declared but null until populated.
- **Test files.** The 175 tracked Pester suites under `test/modules/` are counted, never
  drawn -- they mirror the modules beside them, so drawing them would double every
  node in doc 2's Test Harness diagram.
- **Generated mirrors.** `test/extension/extension-sdk/` is one box in doc 2's
  extension count; its copies under three services' `server/internal/yex/` are
  generated, so drawing them would show the same three packages four times.
- **Documentation.** Every `README.md` and `read.more.md` across `host/`,
  `guest/` and `install/` is omitted -- documentation, not mechanism. The two
  tracked top-level roots that are not system components, `docs/` and
  `dev-only/`, are named in doc 1's intro so their absence is visible rather
  than accidental.
- **Shared-library import edges.** `automation/` is a library root as well as the
  Deploy Engine: `Yuruna.CloudInitTemplate.psm1` is imported by 21
  `host/*/guest.*/New-VM.ps1` scripts, `Yuruna.GuestSeed.psm1` by 9 of them,
  `Yuruna.HostSetup.psm1` by all six host operator scripts, and
  `Yuruna.Common.psm1` by 13 non-test files under `test/`. Drawing those would
  read as "Host Provisioning depends on the Deploy Engine", which is not what is
  happening, so they are prose with per-module importer counts instead.
- **One edge that does not exist.** Host Provisioning reads no project YAML: a
  grep for `resources.yml` / `components.yml` / `workloads.yml` /
  `yuruna-project` across `host/` returns one comment and no code. Its inputs
  come from `test/test.config.yml`, `host/vmconfig/` and the download-agent
  service.
- **Phase-to-phase edges inside the Deploy Engine.** The three `Set-*.ps1`
  scripts never invoke one another; their only coupling is the generated
  `config/<cloud>/resources.output.yml`, which is doc 2's and doc 3's concern.
- **Registries drawn as counts.** The 21 sequence verbs, the 21 failure classes
  and the 3 severities are cited by count and source, never drawn -- they are
  lookup tables, not message exchanges or states.
- **Counters, latches and sleeps that ride alongside a machine.** The
  consecutive-crash counter, the `YurunaCycleRestart` mid-cycle abort, the
  notification gating latch and the host-network loss streak are all named in
  doc 4's prose; none of them changes the shape of a state machine.
- **Ports, protocols and process co-residency outside doc 6.** Docs 1-5 name no
  port on purpose, so a topology change touches exactly one document. Doc 6 in
  turn draws none of the six loopback-only listeners on the caching-proxy VM
  (Loki 3100 and its 9096 gRPC port, promtail 9080, Prometheus 9090, the node
  exporter 9100 and the squid exporter 9301) -- they reach nothing across the
  network, so it names them in prose instead. It also omits the operator's
  browser edges to the stash UI and Grafana, and three of the four identical
  bootstrap edges into a deploying host's status service.
- **Utilities with no caller on a drawn path.** `automation/yuruna.ps1`,
  `Invoke-Clear.ps1`, `Get-SystemDiagnostic.ps1`, `Set-HostAlias.ps1`,
  `Test-YurunaHost.ps1`, `Check-DependencyVersion.ps1`, `context-copy.ps1`,
  `windows-guest-bootstrap.ps1` and `yuruna-host-locate.ps1` are enumerated in
  doc 2's prose rather than drawn, because no deploy-path or cycle-path caller
  reaches them.

Config-gated relationships are drawn as **dashed** edges. Doc 1 has none --
nothing among the seven blocks is planned or gated -- and doc 6 makes the gating
deliberately **per edge**: each of its eighteen dashed edges carries an inline
`%% gate:` comment naming its own flag, and the gate table has a row for every
distinct gate -- sixteen rows, because the three identical presence beacons share
one. The pool, stash, ingest, replicate and download-agent paths each have their
own switch and no single flag turns the tier on.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.19
