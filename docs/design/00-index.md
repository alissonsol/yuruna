# Yuruna design diagrams

> One sentence: the entry point to Yuruna's generated design diagrams — what
> each shows, how they relate, and where each was derived from.

This set is **generated from source** and meant to be regenerated as the code
evolves. The canonical prose architecture — the three capabilities and the
three-phase model — is [Yuruna Architecture](../architecture.md); these diagrams
visualize it rather than restate it.

## The documents

| # | Document | Diagram type | Shows |
|---|----------|--------------|-------|
| 1 | [Context and components](01-context-and-components.md) | flowchart | The 7 top-level building blocks and the edges between them. |
| 2 | [Component breakdown](02-component-breakdown.md) | flowchart ×7 | Each block opened into ≤7 real scripts, modules or directories. |
| 3 | [Data flows](03-data-flows.md) | sequenceDiagram ×6 | Deploy, test cycle, guest fetch, failure alert, image acquisition, shared storage. |
| 4 | [Lifecycle state](04-lifecycle-state.md) | stateDiagram-v2 ×2 | Outer 6-state runner machine + per-guest step lifecycle. |
| 5 | [Data model](05-data-model.md) | erDiagram ×4 | Project deploy YAML, cycle plan + sequences, harness runtime, pool intent. |
| 6 | [Deployment topology](06-deployment.md) | flowchart (subgraphs) | The 7 network nodes and their links. |
| — | [Naming conventions](naming.md) | prose | The rules every component, config key, duration, boolean and page name follows, and the foreign contracts exempt from them. |

## How they relate

- Doc 1 names the blocks; doc 2 opens each one; doc 6 places those same blocks
  on a network.
- Doc 3 shows what moves **between** blocks at runtime; doc 4 shows the
  **states** the test harness passes through while doc 3's test cycle runs.
- Doc 5 is the **data** that docs 1–3 read and write (project YAML, sequences,
  `test.config.yml`, vaults, pool intent).

## Source provenance

| Document | Primary sources |
|----------|-----------------|
| 1 | Repo layout: `automation/ global/ guest/ host/ install/ test/ tools/`, `yuruna-project/{book,example,template,test}` |
| 2 | `automation/Yuruna.*.psm1`, `automation/yuruna.ps1`, `host/Yuruna.Host.Contract.psm1`, `host/modules/`, `host/vmconfig/`, `guest/*/`, `install/setup.ps1`, `install/keys/`, `tools/`, `test/modules/`, `test/sequences/`, `test/schemas/`, `test/extension/`, `global/resources/`, `yuruna-project/{example,template,book}` |
| 3 | `automation/Set-*.ps1`, `automation/Yuruna.{Component,Workload,DeploymentKind,GitHubSource}.psm1`, `automation/fetch-and-execute.sh`, `test/modules/{Test.RunnerOuterLoop,Test.RunnerInnerLoop,Test.SequenceEngine,Test.SequenceHandler,Test.Notify,Test.PoolStorage,Test.HostIdentity}.psm1`, `host/modules/Yuruna.DownloadAgent.psm1`, `host/*/guest.*/Get-Image.ps1`, `host/vmconfig/*.base.user-data`, `test/extension/*/server/internal/` |
| 4 | `test/modules/{Test.RunnerState,Test.RunnerOuterLoop,Test.RunnerInnerLoop,Test.RunnerWatchdog}.psm1`, `test/Invoke-TestCycleRunner.ps1`; [runner-outer-loop.md](../runner-outer-loop.md#runner-state-machine) |
| 5 | `yuruna-project/.../config/<cloud>/*.yml`, `yuruna-project/test/test.runner.yml`, `automation/Yuruna.{Resource,Component,Workload,Validation,DeploymentKind,VariableExpansion}.psm1`, `automation/Import.Yaml.psm1`, `test/test.config.yml.template`, `test/schemas/`, `test/Test-Config.ps1`, `test/New-Lab.ps1`, `test/pool/examples/`, `test/modules/{Test.Capability,Test.ExtensionService,Test.SequencePlanner,Test.PoolPlanner}.psm1` |
| 6 | `test/Invoke-TestRunner.ps1`, `test/Start-{StatusService,ConfigService}.ps1`, `test/Start-{CachingProxyServiceVM,StashServiceVM,PoolControlServiceVM,DownloadAgentServiceVM}.ps1`, `test/Sync-PoolDashboardOnProxy.ps1`, `test/Move-CachingProxyService.ps1`, `host/vmconfig/*.base.user-data`, `test/extension/{pool-aggregator-service,pool-control-service,stash-service,download-agent-service}`, `test/modules/{Test.PoolSync,Test.PoolStorage,Test.ExtensionService,Test.VMUtility}.psm1` |

## The ≤7 rule — grouping decisions

Every diagram (and every parent's child set) shows **at most seven boxes**. Where
reality exceeds seven, siblings are grouped under a named aggregate:

- **Doc 1 / seven blocks**: `tools/` (release-pin signer, SDK mirror, linter,
  config migrator, git hooks) is folded into **Installers** — the integrity
  artifacts under `install/` are its output — rather than shown as an 8th block,
  and `global/` joins `yuruna-project` as one data plane with two roots.
- **Doc 2 / Deploy Engine**: `automation/` holds 13 top-level `.ps1` files and 22
  `.psm1` modules. Seven boxes cover the phase path, its validators, its parser
  and its cross-cutting modules; the standalone utilities (`Invoke-Clear`,
  `Get-SystemDiagnostic`, `Set-HostAlias`, `Test-YurunaHost`,
  `Check-DependencyVersion`, `context-copy`) and the five host-provisioning
  helpers that merely live there stay in prose.
- **Doc 2 / Host**: the six `host/modules/*.psm1` collapse to one **modules**
  box; the four infra guests (`guest.caching-proxy-service`,
  `guest.download-agent-service`, `guest.pool-control-service`,
  `guest.stash-service`) share one box and live nested under each provider rather
  than at the `host/` root.
- **Doc 2 / Test Harness**: `test/` holds 46 top-level `.ps1` scripts, 91 `.psm1`
  modules and 163 Pester files. Seven boxes cover the three runner processes (the
  outer loop and its per-cycle child share one), the module layer, `sequences/` +
  `schemas/` together, the status service, the extensions and the admin CLIs; the
  11 pool admin CLIs and the 8 extension areas are enumerated in prose.
- **Doc 2 / Installers**: six boxes — the three bootstrappers, the guided
  `setup.ps1`, the signed integrity artifacts and the release-pin signer.
  `Invoke-Lint.ps1`, `Sync-ExtensionSdk.ps1`, `Update-TestConfigNaming.ps1` and
  `githooks/pre-commit` are development gates rather than shipped artifacts and
  stay in prose.
- **Doc 2 / Project data**: the three sequence roots in the project repo (each
  project's `test/`, the repo-level `test/test.runner.yml`, and `book/test/`)
  share one box; doc 5 gives them their own entities.
- **Doc 3**: each sequence diagram carries only the participants that exchange
  messages — seven or fewer in every flow. The download-agent discovery ladder's
  three rungs are one aggregator arrow plus prose rather than three participants,
  and the shared-storage flow draws the four writers plus the two shares, with
  the on-share tree in a code block rather than as more participants.
- **Doc 4 / per-guest lifecycle**: teardown is drawn as the exit *transition*
  rather than an eighth state, so its failure path is the `Cleanup` edge out of
  the machine rather than into `diagnose`.
- **Doc 5**: the data model is split into **four** erDiagrams (project deploy,
  cycle plan + sequences, harness runtime, pool intent) so none exceeds seven
  entities. The Download pool's on-share layout (pointer files,
  content-addressed generations, sidecars, lease) is drawn in doc 3 instead,
  because none of it lives in a repo, and the extension `service:` manifest stays
  in prose because it is a declaration rather than runtime state.
- **Doc 6**: ~20 deployed processes are grouped into seven `subgraph` network
  nodes, each with at most four children. The caching-proxy-service VM box
  aggregates squid, zot, Apache, Grafana, the log parser, the
  pool-aggregator-service, Loki, Prometheus and the squid exporter — the
  aggregator is drawn inside that box because that is where it runs — and the
  Pool Tier holds the pool-control-service VM and the NAS.

## What is deliberately not drawn

- **Anything planned.** GCP/GKE appear only as a named gap: `global/config/gcp`
  holds a credential stub with no matching templates under `global/resources/`.
- **Test files.** The 163 Pester suites under `test/modules/` are counted, never
  drawn — they mirror the modules beside them.
- **The extension SDK mirrors.** `test/extension/extension-sdk/` is one box in
  doc 2's extension count; its byte-identical copies under three services'
  `server/internal/yex/` are generated, so drawing them would draw the same three
  packages four times.

Anything config-gated is drawn with dashed edges under a `%% planned` note. In
doc 6 that is deliberately **per edge**: the pool, stash, ingest, replicate and
download-agent paths each have their own switch, and no single flag turns the
tier on.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.07
