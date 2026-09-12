# Yuruna design overview

These source-derived diagrams connect Yuruna's component boundaries, runtime flows, state, data, deployment, and globalization.

Start with [Architecture](../architecture.md) for the canonical capability and
phase definitions. These pages add navigable implementation views rather than
copying that prose. They describe the checked-in framework and project examples,
not the health or configuration of a particular running lab.

## Reading the views

| Document | Question answered | Primary source anchors |
| --- | --- | --- |
| [01 Context and components](01-context-and-components.md) | Where are the system boundaries? | [install/setup.ps1](../../install/setup.ps1), [automation](../../automation), [test/Start-TestRunner.ps1](../../test/Start-TestRunner.ps1), [host](../../host), [guest](../../guest). |
| [02 Component breakdown](02-component-breakdown.md) | Which artifacts implement each boundary? | [Yuruna.Host.Contract.psm1](../../host/Yuruna.Host.Contract.psm1), [Test.Prelude.psm1](../../test/modules/Test.Prelude.psm1), [test/extension](../../test/extension), [global/resources](../../global/resources), [project examples](https://github.com/alissonsol/yuruna-project/tree/main/example). |
| [03 Data flows](03-data-flows.md) | What moves between callers, tools, services and storage? | [Yuruna.Resource.psm1](../../automation/Yuruna.Resource.psm1), [Yuruna.Component.psm1](../../automation/Yuruna.Component.psm1), [Yuruna.Workload.psm1](../../automation/Yuruna.Workload.psm1), [Test.PoolStorage.psm1](../../test/modules/Test.PoolStorage.psm1), [service extensions](../../test/extension). |
| [04 Lifecycle state](04-lifecycle-state.md) | What happens on success, failure, timeout or restart? | [Test.RunnerState.psm1](../../test/modules/Test.RunnerState.psm1), [Test.RunnerOuterLoop.psm1](../../test/modules/Test.RunnerOuterLoop.psm1), [Test.RunnerInnerLoop.psm1](../../test/modules/Test.RunnerInnerLoop.psm1), [Test.RunnerWatchdog.psm1](../../test/modules/Test.RunnerWatchdog.psm1). |
| [05 Data model](05-data-model.md) | Which configuration fields and relationships drive execution? | [project template](https://github.com/alissonsol/yuruna-project/tree/main/template), [website config](https://github.com/alissonsol/yuruna-project/tree/main/example/website/config), [Yuruna.Validation.psm1](../../automation/Yuruna.Validation.psm1), [authentication extension](../../test/extension/authentication). |
| [06 Deployment](06-deployment.md) | Where do processes run and which network paths connect them? | [service launchers](../../test/service), [caching-proxy seed](../../host/vmconfig/caching-proxy-service.base.user-data), [pool aggregator](../../test/extension/pool-aggregator-service/main.go), [service metadata](../../test/extension). |
| [07 Globalization](07-globalization.md) | How are locale, catalogs and localized responses selected? | [globalization](../../globalization), [Test.Locale.psm1](../../test/modules/Test.Locale.psm1), [Test.Message.psm1](../../test/modules/Test.Message.psm1), [status service](../../test/service/Start-StatusService.ps1), [extension SDK](../../test/extension/extension-sdk), [tools](../../tools). |

Follow component names from 01 into 02, then use 03 for message/data movement
and 04 for lifecycle decisions. The records in 05 are inputs to those flows.
The same services appear in 06 as deployed processes rather than logical
components. Page and API interactions in 03/06 use the locale behavior in 07;
localization does not rename protocol keys or runner state tokens.

## Grouping and notation

| View | Seven-box grouping decision |
| --- | --- |
| Context | Seven top-level subgraphs, each containing one representative artifact. |
| Breakdown | One diagram per context boundary, with at most seven children; modules, guest adapters and extensions are named source-family aggregates. |
| Flows | Separate sequence diagrams bound the participants for deployment, testing and service access; pool storage uses a hierarchy to separate storage ownership. |
| Lifecycle | Runner state and guest lifecycle are separate views, so process outcomes are not confused with VM power states. |
| Data model | Related configuration views are separated rather than combining every directory, record and secret into one ER diagram. |
| Deployment | Seven top-level network groups; individual extension VMs and storage shares are expanded inside their group. Host and caching-proxy process views are separate. |
| Globalization | Catalog production, HTTP negotiation and localized consumers use separate small diagrams. |

A box or participant maps to a cited artifact or an explicitly named aggregate
of artifacts. Flowchart IDs use stable kebab-case names derived from source
paths; labels remain short. State diagrams use underscore aliases because the
Mermaid state grammar rejects hyphens in identifiers; their visible labels keep
the exact source state names. Sequence messages and prose carry the details
omitted from those labels. Arrows are defined per view: dependencies in component
diagrams, actual exchanges in sequence diagrams, allowed execution transitions
in state diagrams, and network/data direction in deployment diagrams. Dashed
edges with Mermaid comments identify optional or planned paths where drawn.

The documents use fenced `mermaid` blocks and the standard `flowchart`,
`sequenceDiagram`, `stateDiagram-v2`, and `erDiagram` types. This follows
[GitHub's diagram support](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/creating-diagrams);
there is no dependency on an experimental component/deployment diagram type,
external icon pack, custom theme, or embedded script.

## Source and regeneration boundaries

Treat source implementations, schemas, templates and checked-in tests as the
authority when regenerating. Architecture prose supplies the canonical
vocabulary, not evidence that an optional or planned feature is implemented.
The diagrams omit GCP deployment because the tree has no GCP resource templates.
The template layout is `template/{config,resources,components,workloads}`;
it does not add a project-name directory under `template`. Project links use
the public project repository so they remain navigable on GitHub.

Keep phase/directory ordering, stable artifact IDs, explicit source citations,
and LF newlines. Do not insert generation timestamps, machine-specific lab
addresses, live pool counts or screenshots into these pages. Those values are
runtime evidence and would create diffs unrelated to the source. Preserve the
inbound architecture anchors for
[three-phase deployment](03-data-flows.md#a-three-phase-deployment) and
[tool sidecars](03-data-flows.md#the-stderrlog--rc-sidecar-contract).
Verify Mermaid parsing/rendering, parent/participant counts, short labels and
links after regeneration.

Use `docs/design/README.md` for links to this overview, including the
[design shortcut](https://yuruna.link/design); individual topic links can still
target their numbered document. [Naming conventions](naming.md) remains a
separate maintained reference rather than another generated diagram.

---

Back to [Architecture](../architecture.md) · [Design overview](README.md)
