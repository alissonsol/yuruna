# Yuruna design diagrams

> One sentence: the entry point to Yuruna's generated design diagrams —
> what each shows, how they relate, and where each was derived from.

This set is **generated from source** and meant to be regenerated as the
code evolves; see the prompt that produced it. For the canonical prose
architecture (the three capabilities and the three-phase model) read
[Yuruna Architecture](../architecture.md) — these diagrams visualize it,
they do not restate it.

## The documents

| # | Document | Diagram type | Shows |
|---|----------|--------------|-------|
| 1 | [Level-1 components](01-context-and-components.md) | flowchart | The 7 top-level building blocks and their edges. |
| 2 | [Level-2 breakdown](02-component-breakdown.md) | flowchart ×7 | ≤7 real children inside each Level-1 block. |
| 3 | [Data flows](03-data-flows.md) | sequenceDiagram ×4 | Deploy, test cycle, fetch, failure-alert. |
| 4 | [Lifecycle state](04-lifecycle-state.md) | stateDiagram-v2 ×2 | Outer 6-state machine + per-guest step lifecycle. |
| 5 | [Data model](05-data-model.md) | erDiagram ×2 | Project deploy YAML + test-harness runtime data. |
| 6 | [Deployment topology](06-deployment.md) | flowchart (subgraphs) | The 7 network nodes and their links. |

## Component specifications

Prose design specs for individual components also live here (not diagrams,
not regenerated — hand-maintained):

| Document | Covers |
|----------|--------|
| [Stash Service](stash-service.md) | The `scp`/`sftp` file-receiving daemon: storage layout, metadata, IDs. |
| [Stash Service UI](stash-service-ui.md) | The browser UI + JSON API on top of the daemon. |

For end-user instructions (not design), see the
[Stash guide](../stash-guide.md).

## How they relate

- Doc 1 names the blocks; doc 2 opens each block; doc 6 places those blocks
  on a network.
- Doc 3 shows what moves **between** blocks at runtime; doc 4 shows the
  **states** the test harness passes through while doc 3's "test cycle" runs.
- Doc 5 is the **data** that docs 1–3 read and write (project YAML + vault +
  `test.config.yml`).

## Source provenance

| Document | Primary sources |
|----------|-----------------|
| 1 | Repo layout: `automation/ host/ guest/ install/ test/ global/`, `yuruna-project/` |
| 2 | `automation/Yuruna.*.psm1`, `host/modules/`, `host/Yuruna.Host.Contract.psm1`, `test/modules/`, `install/`, `global/resources/`, `yuruna-project/{example,template}` |
| 3 | `automation/Set-*.ps1`, `automation/fetch-and-execute.sh`, `test/modules/{Test.RunnerOuterLoop,Test.RunnerInnerLoop,Invoke-Sequence}.psm1` |
| 4 | `test/modules/Test.RunnerState.psm1`, `Test.RunnerInnerLoop.psm1`; [runner-state.md](../runner-state.md) |
| 5 | `yuruna-project/.../config/<cloud>/*.yml`, `test/test.config.yml`, `test/extension/{authentication,notification}` |
| 6 | `test/Invoke-TestRunner.ps1`, `test/Start-{StatusService,CachingProxy,StashServer}.ps1`, `test/pool/`, `test/extension/pool-aggregator` |

## The ≤7 rule — grouping decisions

Every diagram (and every parent's child set) shows **at most seven boxes**.
Where reality exceeds seven, siblings are grouped under a named aggregate:

- **Doc 1**: `tools/` (release-pin updater + git hooks) is folded into
  **Deploy Engine** rather than shown as an 8th block.
- **Doc 2 / Host**: the five `host/modules/*.psm1` collapse to one
  **modules** box; the two infra guests (`guest.caching-proxy`,
  `guest.stash-service`) share one box.
- **Doc 5**: the data model is split into **two** erDiagrams (project deploy
  vs. harness runtime) so neither exceeds seven entities.
- **Doc 6**: ~12 deployed processes are grouped into seven `subgraph`
  network nodes.

Anything planned/optional is drawn with dashed edges and a `%% planned`
note (e.g. the pool tier in doc 6).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.26
