# Yuruna design diagrams

<a id="425aae9a-0001"></a>

These source-derived views connect Yuruna's components, runtime exchanges, runner states, configuration, deployment, and localization.

Start with the [canonical architecture](../architecture.md) for the capabilities
and deployment model. These pages map its concepts to the current `yuruna`
implementation and companion `yuruna-project` records. Each diagram's prose
cites the scripts, modules, templates, or configuration that establish it.
Companion source links use the public repository paths and are checked against
the sibling local checkout during regeneration.

| View | What it shows | Primary source paths |
| --- | --- | --- |
| [01 Context and components](01-context-and-components.md) | Seven responsibility boundaries and their dependencies. | [install/setup.ps1](../../install/setup.ps1), [automation/](../../automation/), [Start-TestRunner.ps1](../../test/Start-TestRunner.ps1), [host/](../../host/), [guest/](../../guest/). |
| [02 Component breakdown](02-component-breakdown.md) | The scripts, modules, and directories inside each boundary. | [automation/](../../automation/), [test/modules/](../../test/modules/), [test/extension/](../../test/extension/), [host contract](../../host/Yuruna.Host.Contract.psm1), [tools/](../../tools/). |
| [03 Data flows](03-data-flows.md) | Phase execution, VM test cycles, cache/stash fetches, pool storage, and intent synchronization. | [phase modules](../../automation/), [runner modules](../../test/modules/), [pool coordination](../../test/pool/), [extension services](../../test/extension/). |
| [04 Lifecycle state](04-lifecycle-state.md) | Runner and VM transitions, diagnostic holds, watchdog recovery, and host refresh. | [Test.RunnerOuterLoop](../../test/modules/Test.RunnerOuterLoop.psm1), [Test.RunnerInnerLoop](../../test/modules/Test.RunnerInnerLoop.psm1), [Test.RunnerWatchdog](../../test/modules/Test.RunnerWatchdog.psm1), [Test.RunnerState](../../test/modules/Test.RunnerState.psm1), [Test.DiagnosticPreservation](../../test/modules/Test.DiagnosticPreservation.psm1). |
| [05 Configuration data model](05-data-model.md) | Configuration scopes, phase list entries, output references, and separate test identities. | [project configurations](https://github.com/alissonsol/yuruna-project/tree/main/example/website/config), [project template](https://github.com/alissonsol/yuruna-project/tree/main/template), [validation](../../automation/Yuruna.Validation.psm1), [variable expansion](../../automation/Yuruna.VariableExpansion.psm1), [authentication](../../test/extension/authentication/), [schemas](../../test/schemas/). |
| [06 Deployment topology](06-deployment.md) | Hosts, guests, services, shares, and network links. | [host providers](../../host/), [service launchers](../../test/service/), [extension daemons](../../test/extension/), [guest setup](../../guest/ubuntu.server.26/). |
| [07 Globalization](07-globalization.md) | Catalog production, request locale selection, browser rendering, and example service diagnostics. | [locale manifest](../../globalization/locale-manifest.json), [Test.Locale](../../test/modules/Test.Locale.psm1), [Go i18n SDK](../../test/extension/extension-sdk/i18n/), [browser kernel](../../globalization/kernel/yuruna.i18n.js), [example request localization](https://github.com/alissonsol/yuruna-project/blob/main/example/text-to-sql/components/frontend/text-to-sql-ui/Program.cs). |

<a id="425aae9a-0002"></a>

## Reading the views

The first view establishes component ownership. The second expands each
boundary. Data flows then show exchanges between those components, while
lifecycle diagrams show transitions within the runner. The data model names
the records read during those flows. Deployment places processes and storage
on network nodes. Globalization cuts across the same components.

The diagrams group related implementations so that each diagram and each
parent's immediate children contain at most seven boxes. Flowchart counts
include subgraph frames; sequence counts refer to participants, and ER counts
refer to entities. L1 uses seven subgraph placeholders, and L2 gives each
boundary its own expansion. Related modules, extensions, guest families,
registries, and upstreams remain named aggregates with membership cited in prose.
State counts include composite states and start/end symbols where present.

Runtime flows and lifecycle transitions use separate diagrams when needed.
The configuration views split filesystem scopes, phase records, and test
identities. Deployment separates runner endpoints, service VMs and storage,
cache processes, guest configuration, and the localhost, AWS, and Azure targets.
Localization separates catalog delivery, resolver precedence, the status
request, and the example's diagnostic resources.
A box may represent a role or code family; it does not always imply a separate
machine or process. Optional paths use dashed edges with Mermaid comments or
explicit `opt`/`alt` branches in sequence diagrams.

<a id="425aae9a-0003"></a>

## Regeneration

Read the current code and companion data before rewriting a view. Prior diagrams
provide a navigation reference; the executable readers, writers, and providers
establish the current behavior. Keep artifact-based kebab-case IDs, directory
or phase order, labels of at most four words, and stable source citations.
Avoid timestamps and live machine identifiers so unchanged source can produce
byte-identical documents and source changes can produce small diffs.
State diagrams use stable underscore aliases because Mermaid's state-transition
grammar rejects hyphens in identifiers; labels retain the actual code names.

Use only ordinary flowcharts, sequence diagrams, state diagrams, and ER diagrams
inside Mermaid fences. Parse and render every block, count boxes and parent
children, and check local links plus public companion paths against the checkouts.
Check incoming fragment links when replacing headings. GitHub's rendering
contract is documented in [Creating diagrams](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/creating-diagrams).

[Naming conventions](naming.md) is the companion reference for component and
configuration names. The [documentation index](../README.md) and
[yuruna.link design entry](https://yuruna.link/design) both lead here.

---

[Architecture](../architecture.md) | [Design overview](README.md)
