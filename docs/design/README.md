# Yuruna design diagrams

This overview connects the source-derived component, runtime, lifecycle, data, deployment, and globalization views.

Start with the [canonical architecture](../architecture.md) for the capabilities,
deployment model, and shared implementation contracts. These pages map those
concepts to the current `yuruna` and `yuruna-project` source without restating
the architecture.

| Document | Question answered | Primary source anchors |
| --- | --- | --- |
| [01 Context and components](01-context-and-components.md) | Where are the seven system boundaries? | [install/setup.ps1](../../install/setup.ps1), [automation/](../../automation/), [Start-TestRunner.ps1](../../test/Start-TestRunner.ps1), [host/](../../host/), [guest/](../../guest/). |
| [02 Component breakdown](02-component-breakdown.md) | Which scripts, modules, and directories implement each boundary? | [automation/](../../automation/), [test/modules/](../../test/modules/), [test/extension/](../../test/extension/), [host contract](../../host/Yuruna.Host.Contract.psm1), [tools/](../../tools/). |
| [03 Data flows](03-data-flows.md) | What crosses each boundary, and where is data stored? | [phase modules](../../automation/), [Test.SequenceRunner](../../test/modules/Test.SequenceRunner.psm1), [Test.PoolStorage](../../test/modules/Test.PoolStorage.psm1), [download-agent](../../test/extension/download-agent-service/), [stash](../../test/extension/stash-service/). |
| [04 Lifecycle state](04-lifecycle-state.md) | How do cycles succeed, fail, pause, and restart? | [Test.RunnerState](../../test/modules/Test.RunnerState.psm1), [Test.RunnerOuterLoop](../../test/modules/Test.RunnerOuterLoop.psm1), [Test.RunnerInnerLoop](../../test/modules/Test.RunnerInnerLoop.psm1), [Test.RunnerWatchdog](../../test/modules/Test.RunnerWatchdog.psm1). |
| [05 Configuration data model](05-data-model.md) | Which fields and references do the engines consume? | [project configurations](https://github.com/alissonsol/yuruna-project/tree/main/example/website/config), [template](https://github.com/alissonsol/yuruna-project/tree/main/template), [validation](../../automation/Yuruna.Validation.psm1), [authentication](../../test/extension/authentication/), [schemas](../../test/schemas/). |
| [06 Deployment topology](06-deployment.md) | Which machines host the code and exchange network traffic? | [host providers](../../host/), [service launchers](../../test/service/), [extension daemons](../../test/extension/), [service guest setup](../../guest/ubuntu.server.26/). |
| [07 Globalization](07-globalization.md) | How do client and server select and render a locale? | [locale manifest](../../globalization/locale-manifest.json), [Test.Locale](../../test/modules/Test.Locale.psm1), [Go SDK](../../test/extension/extension-sdk/i18n/), [browser kernel](../../globalization/kernel/yuruna.i18n.js). |

Every diagram's adjacent prose cites its more specific implementation sources.
The project links refer to matching files in the sibling
`yuruna-project` checkout; the framework links are relative so they also
work in a local clone.

## Reading the views together

The L1 diagram fixes seven responsibility boundaries. L2 expands those same
boundaries in the same order. The data flows follow messages and files across
them; the state views describe control flow over time. The data model names
the configuration records read in those flows, and deployment maps the same
participants to hosts and service VMs. Globalization applies across these
components, rather than adding a deployment phase.

Two boundaries need particular care. Runtime
`test/status/extension/authentication/` belongs to the harness, not the
project deployment schema. The pool share and stash share also have separate
settings and writers: pool images, host records, intent, and telemetry are
distinct from stash artifacts and the stash VM's local index/buffer.

The source currently provides resource templates for localhost, AWS, and
Azure. GCP registry authentication exists, but GCP deployment templates and
example configurations do not. `template/` is itself a project root;
`example/<project>/` and book/test definitions add other project shapes.

The [test-cycle flow](03-data-flows.md#b-test-cycle) places prompt recognition
before input and separates console/OCR work from SSH actions. The [pool telemetry flow](03-data-flows.md#g-pool-telemetry-and-dashboards)
separates event ingestion from metrics and SMB archiving. The
[lifecycle](04-lifecycle-state.md) also distinguishes manual host refresh,
its runner preflight/barrier, and the currently unqualified automatic trigger.

The deployment views distinguish the host's 8080 status endpoint from its
8443 mutual-TLS configuration endpoint, expand the caching-proxy VM processes,
and separate local and cloud deployment targets. The globalization views
distinguish runtime locale availability from entry provenance and connect the public catalog compiler,
embedded service assets, HTTP negotiation, and browser rendering.

## Grouping and notation

| View | Grouping decision |
| --- | --- |
| L1 | Seven empty subgraphs represent the seven components; implementations appear in L2. |
| L2 | At most seven siblings per view. Related validators, provider implementations, shared modules, and extension families are named aggregates with membership listed in prose. |
| Sequences | At most seven participants. Phase-owned tool calls and related remote targets are grouped; the cache, stash, download-agent, and pool-telemetry paths have separate diagrams. |
| Pool storage | One share boundary plus six children; per-host cycle/service directories share a host box. A separate six-box view distinguishes stash share data from VM-local state. |
| Lifecycle | Six persisted runner states and a separate seven-state summary of inner VM work. Watchdog and exit conditions are transitions or prose, not invented enum values. |
| Data model | Seven deployment entities and five test/credential entities. Phase entries share their list names; globals and dynamic map keys are explained in prose. |
| Deployment | Separate bounded views for test endpoints, pool services/storage, cache VM internals, guest configuration, and local/cloud targets. Co-located endpoints and file reads are identified explicitly. |
| Globalization | Seven catalog components, six locale-selection nodes, five request/render participants, with PowerShell and Go adapters sharing an explicitly named contract. |

Only `flowchart`, `sequenceDiagram`, `stateDiagram-v2`, and `erDiagram`
are used. Node IDs are stable artifact-derived slugs; labels are short.
State diagrams use underscore aliases for Mermaid parser compatibility while
preserving source state names in the displayed labels.
Empty subgraphs count as one box; a populated subgraph and its children all
count toward the diagram's seven-box limit. Sequence participants and ER
entities count once, regardless of messages or fields. Long source memberships
belong in prose rather than additional diagram boxes.
Declaration order follows the component list, phase order, or runtime
exchange. Solid arrows have the meaning described beside each diagram;
dashed flowchart edges mark optional behavior with an `%% optional` comment.
ER dashed relationships mean non-identifying data references.

## Regeneration contract

Read implementation files and configuration examples before changing a diagram.
Confirm source paths and runtime fields, then update affected views together.
Prior diagrams are not evidence for what the code does. Keep stable IDs,
declaration order, LF line endings, and fixed prose for unchanged behavior;
do not insert generation timestamps, random identifiers, live hostnames, or
secret values. Re-running against unchanged source should leave no diff.

Validate every Mermaid block by parsing and rendering it, check the seven-box
bounds and local/project source links, and preserve inbound section links.
The overview target is `docs/design/README.md`, including
[the documentation index](../README.md) and
[the yuruna.link design redirect](https://yuruna.link/design).

Use the documented [GitHub Mermaid fences](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/creating-diagrams)
and the stable diagram types listed above. Local rendering validates Mermaid
syntax and layout without requiring a commit or publication. Source citations
use current public paths rather than transient line numbers. The diagrams
cover the published framework and its companion project repository.

[Naming conventions](naming.md) remains the companion reference for component,
configuration, and page names.

---

[Architecture](../architecture.md) | [Design overview](README.md)
