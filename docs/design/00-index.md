# Yuruna design overview

This page is the deterministic entry point for the current-source design diagrams and the grouping decisions that keep each view readable.

[Yuruna Architecture](../architecture.md) | [Design index](00-index.md)

The canonical design narrative remains in [Yuruna Architecture](../architecture.md).
These pages only map that design to current scripts, modules, data files, runtime
exchanges, and deployed processes.

## Diagram set

| Document | Question answered | Primary source paths |
|---|---|---|
| [Context and components](01-context-and-components.md) | What are the seven system blocks and their dependencies? | `install/`, `automation/`, `test/`, `host/`, `guest/`, `global/`, `tools/`, and `yuruna-project/{template,example,book,test}` |
| [Component breakdown](02-component-breakdown.md) | Which current artifacts sit inside each block? | The same roots, expanded to their entry scripts, modules, provider folders, guest payloads, and project folders |
| [Data flows](03-data-flows.md) | What moves during deployment, a test cycle, framework and dependency fetches, download-agent transfers, stash transfers, and storage writes? | `automation/Yuruna.{Resource,Component,Workload}.psm1`, `host/modules/Yuruna.{DownloadAgent,Image,UbuntuImage}.psm1`, `test/modules/`, `host/vmconfig/`, `guest/ubuntu.server.*/`, and `test/extension/` |
| [Lifecycle state](04-lifecycle-state.md) | Which runner states persist, and which guest stages execute inside a cycle? | `test/modules/Test.RunnerState.psm1`, `Test.RunnerOuterLoop.psm1`, `Test.RunnerWatchdog.psm1`, and `Test.RunnerInnerLoop.psm1` |
| [Configuration data model](05-data-model.md) | Which project and authentication records are read by the engine and harness? | `yuruna-project/template/`, `automation/Yuruna.Validation.psm1`, `automation/Yuruna.*.psm1`, and `test/{schemas,extension/authentication}` |
| [Deployment topology](06-deployment.md) | Where do the processes run, and which network or storage links join them? | `test/service/`, `test/extension/`, `host/vmconfig/`, provider `New-VM.ps1` files, and guest setup scripts |

## Source-boundary decisions

The current tree changes four durable anchors from the prompt in ways the diagrams
make explicit:

- The runner entry point is `test/Start-TestRunner.ps1`; the current child layers are
  `test/modules/Invoke-TestCycleRunner.ps1` and
  `test/modules/Invoke-TestRunnerInnerLoop.ps1`. There is no current
  `test/Invoke-TestRunner.ps1`.
- Localhost, AWS, and Azure project configurations exist. GCP deployment remains
  planned in `docs/architecture.md`, and there is no `global/resources/gcp/`, so
  these diagrams do not draw a GCP deployment target.
- `yuruna-project/template/` is itself a project root, while examples live below
  `yuruna-project/example/<project>/`.
- Stash data is stored on the independently configured stash share. It is not a
  child of the `yuruna-pool` share.

## Rule-of-seven decisions

The level-1 view uses exactly seven stable blocks, in prompt order: Provisioning,
Deploy Engine, Test Harness, Providers, Project Data, Shared Modules, and External
Systems. The level-2 page expands each block separately and never gives a parent
more than seven children.

Larger source sets are folded into named aggregates:

- Platform installers combine the three host-specific installer entry points.
- Service builders combine the caching-proxy, stash, pool-control, and
  download-agent VM builders across all host providers.
- Runner roles group process control, sequence execution, host I/O, status, OCR,
  diagnostics, notification, and remediation modules by runtime responsibility.
- Guest payloads combine the five current `guest/` families; their host-specific
  builders stay under the three provider folders.
- Project roots combine `template/` with the two deploy examples; the test-only
  `example/nested.host/` fixture stays under Test Content.
- External endpoints are grouped by protocol role rather than by every vendor URL.
- Deployment uses seven machine/tier subgraphs; every subgraph also has seven or
  fewer process boxes.
- Runner state and guest lifecycle are separate diagrams: the persisted runner
  view has six states, and the guest view has seven operational stages.
- Pool and stash storage are separate diagrams because they are independently
  configured shares. Pool Storage has seven boxes (its root and six direct
  areas); Stash Storage has four (share root, host root, host key, and dated
  files).

## Deterministic rendering rules

All diagrams use GitHub Mermaid types allowed by the prompt. Node identifiers follow
stable kebab-case artifact names, declarations follow phase or directory order, and
labels contain at most four words. The one grammar-required exception is
`stateDiagram-v2`: Mermaid reserves the ASCII hyphen while parsing transitions, so
multiword state IDs use deterministic snake_case while their visible labels retain
the source enum's spelling. Optional flowchart links are dashed and preceded by an
`%% optional` comment; dotted ER links retain Mermaid's non-identifying association
meaning. No planned-only box is included. Source paths, rather than the previous
contents of `docs/design/`, are the authority for every regeneration.
