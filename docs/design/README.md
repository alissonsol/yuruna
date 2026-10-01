# Yuruna design diagrams

These source-derived views connect Yuruna's components, runtime exchanges, state, data, deployment, and localization.

Start with the [canonical architecture](../architecture.md) for the capabilities
and deployment model. The pages here map those concepts to the current
`yuruna` source and companion `yuruna-project` data. Each page cites the paths
used for its diagrams.

| View | What it shows | Primary source paths |
| --- | --- | --- |
| [01 Context and components](01-context-and-components.md) | Seven responsibility boundaries and their dependencies. | [install/setup.ps1](../../install/setup.ps1), [automation/](../../automation/), [Start-TestRunner.ps1](../../test/Start-TestRunner.ps1), [host/](../../host/), [guest/](../../guest/). |
| [02 Component breakdown](02-component-breakdown.md) | The scripts, modules, and directories inside each boundary. | [automation/](../../automation/), [test/modules/](../../test/modules/), [test/extension/](../../test/extension/), [host contract](../../host/Yuruna.Host.Contract.psm1), [tools/](../../tools/). |
| [03 Data flows](03-data-flows.md) | Phase execution, VM test cycles, service fetches, and pool storage. | [phase modules](../../automation/), [runner modules](../../test/modules/), [pool coordination](../../test/pool/), [extension services](../../test/extension/). |
| [04 Lifecycle state](04-lifecycle-state.md) | Runner and VM cycle transitions, including failure recovery. | [Test.RunnerOuterLoop](../../test/modules/Test.RunnerOuterLoop.psm1), [Test.RunnerInnerLoop](../../test/modules/Test.RunnerInnerLoop.psm1), [Test.RunnerWatchdog](../../test/modules/Test.RunnerWatchdog.psm1), [Test.RunnerState](../../test/modules/Test.RunnerState.psm1). |
| [05 Configuration data model](05-data-model.md) | Project configuration and test/credential records consumed by the engines. | [project configurations](https://github.com/alissonsol/yuruna-project/tree/main/example/website/config), [project template](https://github.com/alissonsol/yuruna-project/tree/main/template), [validation](../../automation/Yuruna.Validation.psm1), [authentication](../../test/extension/authentication/), [schemas](../../test/schemas/). |
| [06 Deployment topology](06-deployment.md) | Hosts, guests, services, shares, and network links. | [host providers](../../host/), [service launchers](../../test/service/), [extension daemons](../../test/extension/), [guest setup](../../guest/ubuntu.server.26/). |
| [07 Globalization](07-globalization.md) | Catalog production, locale selection, and client/server rendering. | [locale manifest](../../globalization/locale-manifest.json), [Test.Locale](../../test/modules/Test.Locale.psm1), [Go i18n SDK](../../test/extension/extension-sdk/i18n/), [browser kernel](../../globalization/kernel/yuruna.i18n.js). |

## Reading the views

The first view establishes component ownership. The second expands each
boundary. Data flows then show exchanges between those components, while
lifecycle diagrams show transitions within the runner. The data model names
the records read during those flows. Deployment places processes and storage
on network nodes. Globalization cuts across the same components.

The diagrams group related implementations so that each diagram and each
parent's immediate children contain at most seven boxes. L1 uses seven
subgraph placeholders; L2 gives each boundary its own diagram. Runtime,
storage, state, data-model, deployment, and localization concerns use separate
views when a single picture would exceed the limit. Aggregate membership and
source paths are listed beside the diagrams. A box can represent a code family
without implying a separate process.

## Regeneration

Derive every update from the current source, then keep stable artifact-based
node IDs, declaration order, short labels, and source links. Do not introduce
timestamps or live machine identifiers. Re-running against unchanged source
should leave these files byte-identical. Validate Mermaid rendering, local
links, and the seven-box limit together because changes in one view can affect
the others.

[Naming conventions](naming.md) is the companion reference for component and
configuration names. The [documentation index](../README.md) and
[yuruna.link design entry](https://yuruna.link/design) both lead here.

---

[Architecture](../architecture.md) | [Design overview](README.md)
