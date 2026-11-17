<a id="425aae9a-0001"></a>

# Yuruna design diagrams

These source-derived views connect Yuruna's components, runtime exchanges, runner states, configuration, deployment, and localization.

Start with the [canonical architecture](../architecture.md) for the capabilities
and deployment model. These pages map its concepts to the current `yuruna`
implementation and companion `yuruna-project` records. Each diagram's prose
cites the scripts, modules, templates, or configuration that establish it.
Companion source links use the public repository paths and are checked against
the sibling local checkout during regeneration.

| View | What it shows | Primary source paths |
| --- | --- | --- |
| [01 Context and components](01-context-and-components.md) | Seven responsibility boundaries and their dependencies. | [install/](../../install/), [automation/](../../automation/), [Start-TestRunner.ps1](../../test/Start-TestRunner.ps1), [host/](../../host/), [guest/](../../guest/). |
| [02 Component breakdown](02-component-breakdown.md) | The scripts, modules, and directories inside each boundary. | [automation/](../../automation/), [test/modules/](../../test/modules/), [test/extension/](../../test/extension/), [source selection](../../test/modules/Test.SourceSelection.psm1), [host contract](../../host/Yuruna.Host.Contract.psm1), [tools/](../../tools/). |
| [03 Data flows](03-data-flows.md) | Phase execution and its retry ledger, VM test cycles, advisory restart accounting, startup cold restarts, events queued between cycles, GUI transport recovery, source selection through the Git mirror, guest archive verification, pool telemetry through the Loki outbox, cache/stash fetches, GitHub release-asset caching, pool and stash share layouts, and configuration synchronization. | [phase modules](../../automation/), [runner modules](../../test/modules/), [SSH readiness](../../test/modules/Test.Ssh.psm1), [restart evidence](../../test/modules/Test.Diagnostic.psm1), [source selection](../../test/modules/Test.SourceSelection.psm1), [Git mirror](../../test/extension/caching-proxy-service/), [guest fetch](../../automation/fetch-and-execute.sh), [guest retry library](../../automation/yuruna-retry.sh), [pool administration](../../test/pool/), [extension services](../../test/extension/), [service seeds](../../host/vmconfig/). |
| [04 Lifecycle state](04-lifecycle-state.md) | Runner and VM transitions, supervisor re-entry and framework rescue, runner session and exit records, host and OCR admission, failure evidence and installer causes, host-restart evidence, diagnostic holds, watchdog and cycle-ceiling recovery, startup login and uncommitted-password retries, livelock and display-stall early ends, UTM install power-off and bounded serial capture stop, and host refresh. | [Test.RunnerOuterLoop](../../test/modules/Test.RunnerOuterLoop.psm1), [Test.RunnerInnerLoop](../../test/modules/Test.RunnerInnerLoop.psm1), [Test.RunnerWatchdog](../../test/modules/Test.RunnerWatchdog.psm1), [Test.RunnerState](../../test/modules/Test.RunnerState.psm1), [Test.DiagnosticPreservation](../../test/modules/Test.DiagnosticPreservation.psm1), [Test.SequenceHandler](../../test/modules/Test.SequenceHandler.psm1), [Test.SequenceEngine](../../test/modules/Test.SequenceEngine.psm1), [Test.SingleInstance](../../test/modules/Test.SingleInstance.psm1). |
| [05 Configuration data model](05-data-model.md) | Configuration scopes, phase list entries, output references, project selection, and separate test identities. | [project configurations](https://github.com/alissonsol/yuruna-project/tree/main/example/website/config), [project template](https://github.com/alissonsol/yuruna-project/tree/main/template), [validation](../../automation/Yuruna.Validation.psm1), [variable expansion](../../automation/Yuruna.VariableExpansion.psm1), [sequence resolution](../../test/modules/Test.SequenceResolve.psm1), [authentication](../../test/extension/authentication/), [schemas](../../test/schemas/), [test configuration template](../../test/test.config.yml.template). |
| [06 Deployment topology](06-deployment.md) | Hosts, guests, services, shares, network links, Git mirror source routing, CA enrollment, service credentials, pool status codes, host memory readings, and the deep diagnostics netconsole. | [host providers](../../host/), [service launchers](../../test/service/), [extension daemons](../../test/extension/), [caching proxy and Git mirror](../../test/extension/caching-proxy-service/), [CA trust recovery](../../test/modules/Test.CachingProxyService.psm1), [guest setup](../../guest/ubuntu.server.26/). |
| [07 Globalization](07-globalization.md) | Catalog production, request locale selection, browser rendering, response caching, and example service diagnostics. | [locale manifest](../../globalization/locale-manifest.json), [Test.Locale](../../test/modules/Test.Locale.psm1), [Go i18n SDK](../../test/extension/extension-sdk/i18n/), [browser kernel](../../globalization/kernel/yuruna.i18n.js), [example request localization](https://github.com/alissonsol/yuruna-project/blob/main/example/text-to-sql/components/frontend/text-to-sql-ui/Program.cs). |

<a id="425aae9a-0002"></a>

## Reading the views

The first view establishes component ownership. The second expands each
boundary. Data flows then show exchanges between those components, while
lifecycle diagrams show transitions within the runner. The data model names
the records read during those flows. Deployment places processes and storage
on network nodes. Globalization cuts across the same components.
One mechanism can appear in several views: GitHub release downloads reach
External services from Provisioning and Providers in the first view, their
caching has its own data flow, and the learner that files them is a process
in the deployment's caching-proxy VM; the runner's exit record is lifecycle
prose, a probe in the pool telemetry flow, and the `lastExit` of the
runner-status route in the deployment's runner endpoints view.

The diagrams group related implementations so that each diagram and each
parent's immediate children contain at most seven boxes. Flowchart counts
include subgraph frames; sequence counts refer to participants, and ER counts
refer to entities. L1 uses seven subgraph placeholders, and L2 gives each
boundary its own expansion. Related modules, extensions, guest families,
registries, and upstreams remain named aggregates with membership cited in prose.
Tool and package sources join the External services box: the bootstrappers
reach it through one Provisioning edge, and guest tool downloads share the
Providers' image-download edge. The Git mirror and the release-asset learner
run on the caching-proxy VM, inside existing boundaries, so neither adds a box
or an external edge.
State counts include composite states and start/end symbols where present.

Runtime flows and lifecycle transitions use separate diagrams when needed.
The pool share tree reaches seven boxes, so the separately configured stash
share has its own layout diagram. GitHub release-asset caching has its own
flow: one guest participant stands for the updaters that call the retry
library, the proxy participant groups Squid with its Store ID helper and
redirect log, and one CDN participant groups both release-asset hosts. The
guest cycle and pool telemetry flows stay at seven participants, so the
aggregator's runner-status probe is an edge pair between existing
participants, and installer failure uploads, runner session and exit records,
and the serial reader stop appear in their prose. Guest shell helpers form one
shared-module box, while validation and requirement modules stay with the
deploy engine that alone imports them.
The configuration views split filesystem scopes, phase records, and test
identities. Deployment separates runner endpoints, service VMs and storage,
cache processes, Git mirror source routing, service credentials, the deep
diagnostics netconsole, and the localhost, AWS, and Azure targets. Its
source-routing view aggregates the download-agent, pool-control, and stash VMs,
whose seeds share one fetch order, and its credential view aggregates the same
three VMs, which share one mutual-TLS channel to the config service; the stash
fetches `/v1/nas/stash`, and the other two fetch `/v1/nas/pool`. Its pool view
draws the host-address
lookup from the workload guest box, which also stands for the service VMs that
make the same query.
The pool view keeps the aggregator's host status codes, including a runner
lost mid-cycle, in prose beside its existing poll edge, and the cache-process
view lists the release-asset learner in its Squid, Zot, and self-tests family.
The startup cold retry has its own lifecycle diagram, separate from the runner's;
it includes the admitted password tail only while password entry is uncommitted.
Advisory restart accounting has its own sequence so its bounded SSH wait and
evidence event remain distinct from a workload verdict without adding a
participant to the guest cycle.
Runner session and exit records, the display-stall early end, declared
`startVm` failure patterns, installer failure causes, and the bounded UTM
serial-capture stop ride existing lifecycle states and edges.
Localization separates catalog delivery, resolver precedence, status requests,
Go page responses, and the example's diagnostic resources.
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
[yuruna.link design entry](https://yuruna.link/425aae9a) both lead here.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.11.16

[Architecture](../architecture.md) | [Design overview](README.md)
