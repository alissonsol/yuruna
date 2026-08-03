# Yuruna design diagrams

> One sentence: the entry point to Yuruna's generated design diagrams —
> what each shows, how they relate, and where each was derived from.

This set is **generated from source** and meant to be regenerated as the
code evolves. For the canonical prose
architecture (the three capabilities and the three-phase model) read
[Yuruna Architecture](../architecture.md) — these diagrams visualize it,
they do not restate it.

## The documents

| # | Document | Diagram type | Shows |
|---|----------|--------------|-------|
| 1 | [Level-1 components](01-context-and-components.md) | flowchart | The 7 top-level building blocks and their edges. |
| 2 | [Level-2 breakdown](02-component-breakdown.md) | flowchart ×7 | ≤7 real children inside each Level-1 block. |
| 3 | [Data flows](03-data-flows.md) | sequenceDiagram ×4 | Deploy, test cycle, guest fetch, failure alert. |
| 4 | [Lifecycle state](04-lifecycle-state.md) | stateDiagram-v2 ×2 | Outer 6-state machine + per-guest step lifecycle. |
| 5 | [Data model](05-data-model.md) | erDiagram ×2 | Project deploy YAML + test-harness runtime data. |
| 6 | [Deployment topology](06-deployment.md) | flowchart (subgraphs) | The 7 network nodes and their links. |
| — | [Naming conventions](naming.md) | prose | The rules every component, config key, duration, boolean and page name follows, and the foreign contracts exempt from them. |

## How they relate

- Doc 1 names the blocks; doc 2 opens each block; doc 6 places those blocks
  on a network.
- Doc 3 shows what moves **between** blocks at runtime; doc 4 shows the
  **states** the test harness passes through while doc 3's "test cycle" runs.
- Doc 5 is the **data** that docs 1–3 read and write (project YAML + vaults +
  `test.config.yml`).

## Source provenance

| Document | Primary sources |
|----------|-----------------|
| 1 | Repo layout: `automation/ host/ guest/ install/ test/ global/ tools/`, `yuruna-project/` |
| 2 | `automation/Yuruna.*.psm1`, `automation/yuruna.ps1`, `host/modules/`, `host/Yuruna.Host.Contract.psm1`, `host/vmconfig/`, `test/modules/`, `test/schemas/`, `install/`, `tools/`, `global/resources/`, `yuruna-project/{example,template}` |
| 3 | `automation/Set-*.ps1`, `automation/Yuruna.{Component,Workload,DeploymentKind}.psm1`, `automation/fetch-and-execute.sh`, `test/modules/{Test.RunnerOuterLoop,Test.RunnerInnerLoop,Invoke-Sequence,Test.SequenceHandler,Test.Notify}.psm1` |
| 4 | `test/modules/{Test.RunnerState,Test.RunnerOuterLoop,Test.RunnerInnerLoop,Test.RunnerWatchdog}.psm1`, `test/Invoke-TestCycleRunner.ps1`; [runner-outer-loop.md](../runner-outer-loop.md#runner-state-machine) |
| 5 | `yuruna-project/.../config/<cloud>/*.yml`, `automation/Yuruna.{Resource,Component,Workload,Validation,DeploymentKind,VariableExpansion}.psm1`, `automation/Import.Yaml.psm1`, `test/test.config.yml.template`, `test/schemas/`, `test/New-Lab.ps1` |
| 6 | `test/Invoke-TestRunner.ps1`, `test/Start-{StatusService,ConfigService}.ps1`, `test/Start-{CachingProxyServiceVM,StashServiceVM,PoolControlServiceVM}.ps1`, `host/vmconfig/{caching-proxy-service,stash-service,pool-control-service}.base.user-data`, `test/extension/{pool-aggregator-service,pool-control-service,stash-service}`, `test/modules/{Test.PoolSync,Test.PoolStorage,Test.VMUtility}.psm1` |

## The ≤7 rule — grouping decisions

Every diagram (and every parent's child set) shows **at most seven boxes**.
Where reality exceeds seven, siblings are grouped under a named aggregate:

- **Doc 1**: `tools/` (release-pin signer, linter, git hooks) is folded into
  **Installers** — the integrity artifacts under `install/` are its output —
  rather than shown as an 8th block.
- **Doc 2 / Deploy Engine**: `automation/` holds 13 top-level `.ps1` files.
  Seven boxes cover the phase path, its validators, its parser and its
  cross-cutting modules; the standalone utilities (`Invoke-Clear`,
  `Get-SystemDiagnostic`, `Set-HostAlias`, `Test-YurunaHost`,
  `Check-DependencyVersion`, `context-copy`) and the five host-provisioning
  helpers that merely live there are listed in prose instead.
- **Doc 2 / Host**: the five `host/modules/*.psm1` collapse to one **modules**
  box; the three infra guests (`guest.caching-proxy-service`, `guest.pool-control-service`,
  `guest.stash-service`) share one box.
- **Doc 2 / Test Harness**: the three runner processes collapse to two boxes
  (the outer loop and its per-cycle child share one), and `sequences/` +
  `schemas/` share one. The 81 modules under `test/modules/` are a single box.
- **Doc 4 / per-guest lifecycle**: teardown is drawn as the exit *transition*
  rather than an eighth state, so its failure path is the `Cleanup` edge into
  `diagnose`.
- **Doc 5**: the data model is split into **two** erDiagrams (project deploy
  vs. harness runtime) so neither exceeds seven entities.
- **Doc 6**: ~18 deployed processes are grouped into seven `subgraph` network
  nodes; the caching-proxy-service VM box aggregates squid, zot, Apache, Grafana, the
  log parser, the pool-aggregator-service and Loki, and the Pool Tier holds the
  pool-control-service VM and the NAS.

Anything config-gated is drawn with dashed edges under a `%% planned` note.
In doc 6 that is deliberately **per edge**: the pool, stash, ingest and
replicate paths each have their own switch, and no single flag turns the tier
on.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.03
