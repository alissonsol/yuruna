# Yuruna design diagrams

> One sentence: the entry point to Yuruna's generated design diagrams —
> what each shows, how they relate, and where each was derived from.

This set is **generated from source** and meant to be regenerated as the
code evolves. The canonical prose architecture — the three capabilities and
the three-phase model — is [Yuruna Architecture](../architecture.md); these
diagrams visualize it rather than restate it.

## The documents

| # | Document | Diagram type | Shows |
|---|----------|--------------|-------|
| 1 | [Components](01-components.md) | flowchart ×8 | The 7 top-level building blocks and their edges, then ≤7 real children inside each. |
| 2 | [Data flows](02-data-flows.md) | sequenceDiagram ×5 | Deploy, test cycle, guest fetch, failure alert, image acquisition. |
| 3 | [Lifecycle state](03-lifecycle-state.md) | stateDiagram-v2 ×2 | Outer 6-state machine + per-guest step lifecycle. |
| 4 | [Data model](04-data-model.md) | erDiagram ×2 | Project deploy YAML + test-harness runtime data. |
| 5 | [Deployment topology](05-deployment.md) | flowchart (subgraphs) | The 7 network nodes and their links. |
| — | [Naming conventions](naming.md) | prose | The rules every component, config key, duration, boolean and page name follows, and the foreign contracts exempt from them. |

## How they relate

- Doc 1 names the blocks and opens each one; doc 5 places those blocks on a
  network.
- Doc 2 shows what moves **between** blocks at runtime; doc 3 shows the
  **states** the test harness passes through while doc 2's "test cycle" runs.
- Doc 4 is the **data** that docs 1–2 read and write (project YAML + vaults +
  `test.config.yml`).

## Source provenance

| Document | Primary sources |
|----------|-----------------|
| 1 | Repo layout: `automation/ host/ guest/ install/ test/ global/ tools/`, `yuruna-project/`; `automation/Yuruna.*.psm1`, `automation/yuruna.ps1`, `host/modules/`, `host/Yuruna.Host.Contract.psm1`, `host/vmconfig/`, `test/modules/`, `test/schemas/`, `test/extension/`, `install/setup.ps1`, `tools/`, `global/resources/`, `yuruna-project/{example,template}` |
| 2 | `automation/Set-*.ps1`, `automation/Yuruna.{Component,Workload,DeploymentKind,GitHubSource}.psm1`, `automation/fetch-and-execute.sh`, `test/modules/{Test.RunnerOuterLoop,Test.RunnerInnerLoop,Test.SequenceEngine,Test.SequenceHandler,Test.Notify}.psm1`, `host/modules/Yuruna.DownloadAgent.psm1`, `host/*/guest.*/Get-Image.ps1` |
| 3 | `test/modules/{Test.RunnerState,Test.RunnerOuterLoop,Test.RunnerInnerLoop,Test.RunnerWatchdog}.psm1`, `test/Invoke-TestCycleRunner.ps1`; [runner-outer-loop.md](../runner-outer-loop.md#runner-state-machine) |
| 4 | `yuruna-project/.../config/<cloud>/*.yml`, `automation/Yuruna.{Resource,Component,Workload,Validation,DeploymentKind,VariableExpansion}.psm1`, `automation/Import.Yaml.psm1`, `test/test.config.yml.template`, `test/schemas/`, `test/Test-Config.ps1`, `test/New-Lab.ps1`, `test/modules/{Test.Capability,Test.ExtensionService}.psm1` |
| 5 | `test/Invoke-TestRunner.ps1`, `test/Start-{StatusService,ConfigService}.ps1`, `test/Start-{CachingProxyServiceVM,StashServiceVM,PoolControlServiceVM,DownloadAgentServiceVM}.ps1`, `test/Sync-PoolDashboardOnProxy.ps1`, `host/vmconfig/*.base.user-data`, `test/extension/{pool-aggregator-service,pool-control-service,stash-service,download-agent-service}`, `test/modules/{Test.PoolSync,Test.PoolStorage,Test.ExtensionService,Test.VMUtility}.psm1` |

## The ≤7 rule — grouping decisions

Every diagram (and every parent's child set) shows **at most seven boxes**.
Where reality exceeds seven, siblings are grouped under a named aggregate:

- **Doc 1 / seven blocks**: `tools/` (release-pin signer, SDK mirror, linter,
  config migrator, git hooks) is folded into **Installers** — the integrity
  artifacts under `install/` are its output — rather than shown as an 8th block.
- **Doc 1 / Deploy Engine**: `automation/` holds 13 top-level `.ps1` files and
  22 `.psm1` modules. Seven boxes cover the phase path, its validators, its
  parser and its cross-cutting modules; the standalone utilities
  (`Invoke-Clear`, `Get-SystemDiagnostic`, `Set-HostAlias`, `Test-YurunaHost`,
  `Check-DependencyVersion`, `context-copy`) and the five host-provisioning
  helpers that merely live there stay in prose.
- **Doc 1 / Host**: the six `host/modules/*.psm1` collapse to one **modules**
  box; the four infra guests (`guest.caching-proxy-service`,
  `guest.download-agent-service`, `guest.pool-control-service`,
  `guest.stash-service`) share one box and live nested under each provider
  rather than at the `host/` root.
- **Doc 1 / Test Harness**: `test/` holds 44 top-level `.ps1` scripts, 90
  `.psm1` modules and 148 Pester files. Seven boxes cover the three runner
  processes (the outer loop and its per-cycle child share one), the module
  layer, `sequences/` + `schemas/` together, the status service, the extensions
  and the admin CLIs; the 11 pool admin CLIs and the 8 extension areas are
  enumerated in prose.
- **Doc 1 / Installers**: six boxes — the three bootstrappers, the guided
  `setup.ps1`, the signed integrity artifacts and the release-pin signer.
  `Invoke-Lint.ps1`, `Sync-ExtensionSdk.ps1`, `Update-TestConfigNaming.ps1` and
  `githooks/pre-commit` are development gates rather than shipped artifacts and
  stay in prose.
- **Doc 2**: each sequence diagram carries only the participants that exchange
  messages — six or fewer in every flow. The download-agent discovery ladder's
  three rungs are one aggregator arrow plus prose rather than three
  participants.
- **Doc 3 / per-guest lifecycle**: teardown is drawn as the exit *transition*
  rather than an eighth state, so its failure path is the `Cleanup` edge out of
  the machine rather than into `diagnose`.
- **Doc 4**: the data model is split into **two** erDiagrams (project deploy
  vs. harness runtime) so neither exceeds seven entities. The Download pool's
  on-share layout (pointer files, content-addressed generations, sidecars,
  lease) stays in prose because none of it lives in a repo, and the extension
  `service:` manifest stays in prose because it is a declaration rather than
  runtime state.
- **Doc 5**: ~20 deployed processes are grouped into seven `subgraph` network
  nodes, each with at most four children. The caching-proxy-service VM box
  aggregates squid, zot, Apache, Grafana, the log parser, the
  pool-aggregator-service, Loki and Prometheus — the aggregator is drawn inside
  that box because that is where it runs — and the Pool Tier holds the
  pool-control-service VM and the NAS.

## What is deliberately not drawn

- **Anything planned.** GCP/GKE appear only as a named gap: `global/config/gcp`
  holds a credential stub with no matching templates under `global/resources/`.
- **Test files.** The 148 Pester suites under `test/modules/` are counted, never
  drawn — they mirror the modules beside them.
- **The extension SDK mirrors.** `test/extension/extension-sdk/` is one box in
  doc 1's extension count; its byte-identical copies under three services'
  `server/internal/yex/` are generated, so drawing them would draw the same
  three packages four times.

Anything config-gated is drawn with dashed edges under a `%% planned` note.
In doc 5 that is deliberately **per edge**: the pool, stash, ingest, replicate
and download-agent paths each have their own switch, and no single flag turns
the tier on.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.04
