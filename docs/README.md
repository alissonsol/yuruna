# Yuruna documentation

What each document under `docs/` covers, so you can jump straight to the
right one. Start with [Yuruna Architecture](architecture.md) for the
cross-cutting model every other doc builds on, or with
[Operator runbook](operator.md) if you are bringing up a test machine.

## Start here

- **[architecture.md](architecture.md)** — the three capabilities and the
  three-phase Resources → Components → Workloads model, plus the CLI entry
  points. Cross-cutting concepts referenced by every README; other docs link
  here rather than repeat.
- **[install.md](install.md)** — load-bearing rationale for the three bootstrap
  installers (Windows Hyper-V, Ubuntu KVM, macOS UTM): what each step does and
  why it is ordered that way. The installers stop at packages and the clone;
  [`install/setup.ps1`](../install/README.md#guided-setup) takes a machine from
  there to a working standalone host or lab, and
  [`test/Disable-TestAutomation.ps1`](operator.md#putting-the-machine-back)
  puts it back.
- **[operator.md](operator.md)** — bring-up runbook for a single test
  machine: OS baseline to a passing cycle, the test user, and the
  caching-proxy-service / stash-service VMs. Its [preflight
  dependencies](operator.md#b2-preflight-dependencies) section is the tool
  list — every tool to install before running Yuruna, the cloud accounts and
  CLIs, and the environment the instructions were tested against.
- **[lab-operator.md](lab-operator.md)** — bring-up runbook for a lab:
  shared NAS storage, caching-proxy service, stash and pool-control services,
  each additional machine enrolled via the dashboard's lab token, and a
  two-pool split running a different test set on each.
- **[definition.md](definition.md)** — the glossary. Generic and
  Yuruna-specific terms in one place, so the framework, guest scripts, and docs
  stay consistent.
- **[opportunities.md](opportunities.md)** — prioritized work the project would
  welcome help on, ranked by return on investment, with a roadmap.

## Deploying applications

- **[kubernetes.md](kubernetes.md)** — the user-facing quick start: deploy a
  containerized app to localhost, Azure, or AWS with one workflow, and clean up
  the cloud resources afterwards.
- **[authentication.md](authentication.md)** — how to authenticate to Docker
  Desktop, AWS, Azure, and Google Cloud, how the [component-push pipeline logs
  into the target container
  registry](authentication.md#component-registry-login) before pushing images,
  plus the test-harness vault threat model.
- **[cleanup is in kubernetes.md](kubernetes.md#cleaning-up-cloud-resources)** —
  destroying cloud resources automatically or by hand, per cloud.

## Test harness

- **[test-harness.md](test-harness.md)** — how `test/` is put together: entry
  points, modules, and how the pieces fit.
- **[test-runner.md](test-runner.md)** — the daily-driver loop that pulls the
  repo, re-reads config, refreshes images, and runs cycles forever.
- **[test-sequences.md](test-sequences.md)** — authoritative reference for every
  action available in a sequence file, plus the per-host contract functions.
- **[test-config.md](test-config.md)** — every key in the per-host
  `test/test.config.yml`, which is bootstrapped from a template and stays local.
- **[handler-schema.md](handler-schema.md)** — the contract for the verb-handler
  registry that drives the YAML sequence engine.
- **[test-perf.md](test-perf.md)** — the append-only structured log of every step
  execution, for cross-host and cross-cycle performance analytics.
- **[runner-outer-loop.md](runner-outer-loop.md)** — the eternal cycle loop that
  makes the runner resilient, the five things it does every pass, and the
  runner's explicit six-state lifecycle machine.
- **[watchdog.md](watchdog.md)** — the heartbeat protocol and the out-of-process
  watchdog that lets the runner survive guest, network, and host-OS failures.
- **[capability-matrix.md](capability-matrix.md)** — the per-cycle banner naming
  what the harness can actually do on the current host (OCR engines, host I/O,
  and more).
- **[extensions-api.md](extensions-api.md)** — the five classes of swappable
  behavior under `test/extension/` and the contract each area implements.
- **[ocr.md](ocr.md)** — how the guest framebuffer is polled for text, and the
  three pluggable matching providers behind `waitForText` and friends.
- **[loglevels.md](loglevels.md)** — the single resolved log level, how it gates
  PowerShell streams, and how it propagates across every child process.

## Failures and self-healing

- **[failure-schema.md](failure-schema.md)** — the `last_failure.json` record and
  the matching `step_failure` event, both produced from one builder so they
  cannot drift, plus the
  [remediation dispatcher](failure-schema.md#remediation-dispatcher) that routes
  a `failureClass` token to a recovery recommendation.
- **[host-condition-registry.md](host-condition-registry.md)** — the three-method
  contract each host platform implements to apply and verify host settings.
- **[system-diagnostic.md](system-diagnostic.md)** — the read-only diagnostic
  dump collected during incident triage.
- **[workarounds.md](workarounds.md)** — frequently asked questions plus
  workarounds learned during development, starting with connectivity, and
  [per-guest-OS troubleshooting](workarounds.md#guest-troubleshooting) for
  Amazon Linux, Ubuntu Server, and Windows 11.
- **[memory.md](memory.md)** — load-bearing rationale that used to live inline in
  the code, kept here so long explanations do not drift out of date.

## Hosts and guests

- **[host-hyperv.md](host-hyperv.md)** — Windows Hyper-V host notes: cleaning up
  old VM files, screen-capture and OCR without a monitor, and related traps.
- **[host-macos.md](host-macos.md)** — macOS UTM host notes, including Homebrew
  and PATH issues. Intentionally brief.
- **[host-io.md](host-io.md)** — the dispatcher every GUI-driving step goes
  through for keystrokes, text input, and mouse clicks.
- **[guest-image-setup.md](guest-image-setup.md)** — the shared image lifecycle
  every `host/<HOST>/guest.<GUEST>/` folder follows; per-host READMEs document
  only the deltas.
- **[guest-workloads.md](guest-workloads.md)** — optional software workloads
  installed into a guest via `fetch-and-execute.sh`.
- **[vmconfig.md](vmconfig.md)** — rationale behind every non-trivial line in the
  per-guest `vmconfig/` artifacts, so the seed files themselves stay short, plus
  the shared base + per-host overlay rendering pipeline that produces them, and
  the [caching-proxy-service seed](vmconfig.md#caching-proxy-service-seed-topics)
  that builds the cache VM.

## Caching, network, and storage

- **[caching.md](caching.md)** — the two composable caching layers: the
  `YurunaCacheContent` cache-buster and the Squid cache VM — plus the
  [operator reference](caching.md#caching-proxy-service--test-harness-operator-reference):
  exposing the cache to remote clients, pointing a host at a remote
  cache, and preflighting.
- **[network.md](network.md)** — rationale for network-related workarounds in the
  guest scripts and the host harness.
- **[pool-storage.md](pool-storage.md)** — the optional NAS-backed durable tier,
  and why host-local storage is treated as ephemeral.

## Pools and services

- **[pool-admin.md](pool-admin.md)** — the pool administrator's guide: group
  hosts into a pool and assign them test sets through the admin commands, and
  the [Pool control service](pool-admin.md#pool-control-service) — the operator
  UI and API that drives the pool-intent git store, which runners only ever
  pull read-only.
- **[control-routes.md](control-routes.md)** — the state-changing `/control/*`
  routes on a host's status service and the proof required to call them.
- **[stash-guide.md](stash-guide.md)** — the shared drop box for files and
  snippets: put content in over `scp` or the browser, then manage it in the web
  UI.

## Design

- **[design/00-index.md](design/00-index.md)** — entry point to the generated
  design diagrams: what each shows, how they relate, and the source each was
  derived from. From there: [Level-1
  components](design/01-context-and-components.md), the [Level-2
  breakdown](design/02-component-breakdown.md), [data
  flows](design/03-data-flows.md), [lifecycle
  state](design/04-lifecycle-state.md), the [configuration data
  model](design/05-data-model.md), and the [deployment
  topology](design/06-deployment.md).
- **[design/naming.md](design/naming.md)** — the naming rules: components are
  "<name> service", durations carry `Seconds`/`Ms`, booleans are bare
  adjectives, acronyms are words in camelCase — plus the foreign contracts
  (Kubernetes, .NET, squid) that are deliberately exempt.

## Further reading

External documentation for the tools Yuruna uses, grouped by topic.

### AWS

- [Getting started with Amazon ECR using the AWS CLI](https://docs.aws.amazon.com/AmazonECR/latest/userguide/getting-started-cli.html)

### Azure

- [Azure Container Registry documentation](https://learn.microsoft.com/en-us/azure/container-registry/)
- [Create an ingress controller with a static public IP address in Azure Kubernetes Service (AKS)](https://learn.microsoft.com/en-us/azure/aks/ingress-static-ip)
- [Use a static public IP address and DNS label with the Azure Kubernetes Service (AKS) load balancer](https://learn.microsoft.com/en-us/azure/aks/static-ip)
- [AKS with multiple nginx ingress controllers, Application Gateway and Key Vault certificates](https://web.archive.org/web/2023/https://blog.hjgraca.com/aks-with-multiple-nginx-ingress-controllers-application-gateway-and-key-vault-certificates)

### GCP

- [Configuring cluster access for kubectl](https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl)
- [Using Container Registry with Google Cloud](https://cloud.google.com/container-registry/docs/using-with-google-cloud-platform)
- Container Registry Guides: [Authentication methods](https://cloud.google.com/container-registry/docs/advanced-authentication)
- Container Registry Guides: [Configuring access control](https://cloud.google.com/container-registry/docs/access-control)
- [Reserving a static external IP address](https://cloud.google.com/compute/docs/ip-addresses/reserve-static-external-ip-address#gcloud)
- [Setting up HTTP(S) Load Balancing with Ingress](https://cloud.google.com/kubernetes-engine/docs/tutorials/http-balancer)
  - Notice that this doesn't apply when using [Ingress with NGINX controller on Google Kubernetes Engine](https://cloud.google.com/community/tutorials/nginx-ingress-gke)
  - [Configuring domain names with static IP addresses](https://cloud.google.com/kubernetes-engine/docs/tutorials/configuring-domain-name-static-ip)

### Kubernetes

- [OpenTofu Documentation](https://opentofu.org/docs/)
- [Declarative Management of Kubernetes Objects Using Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)

### Ingress

- [ingress-nginx](https://github.com/kubernetes/ingress-nginx/tree/master/charts/ingress-nginx) at GitHub
- [Redirect to www with an nginx ingress](https://www.informaticsmatters.com/blog/2020/06/03/redirecting-to-www.html)
- [How To Set Up an Nginx Ingress on DigitalOcean Kubernetes Using Helm](https://www.digitalocean.com/community/tutorials/how-to-set-up-an-nginx-ingress-on-digitalocean-kubernetes-using-helm)

### Certificates

- [cert-manager](https://cert-manager.io/docs/installation/) documentation
- NGINX Ingress Controller [TLS termination](https://kubernetes.github.io/ingress-nginx/examples/tls-termination/)

### PowerShell

- PSScriptAnalyzer [code](https://github.com/PowerShell/PSScriptAnalyzer)
  - If not yet installed: `Install-Module -Name PSScriptAnalyzer`
  - `Invoke-ScriptAnalyzer -Path . -Recurse` (auto-picks up the repo-root
    `PSScriptAnalyzerSettings.psd1`)
  - `Invoke-ScriptAnalyzer -Path . -Recurse | Select-Object -Property Line, Column, ScriptPath, RuleName, Message`
  - BOM-only spot check: `Invoke-ScriptAnalyzer -Path . -Recurse | Where-Object RuleName -eq 'PSUseBOMForUnicodeEncodedFile'`
- [Quickstart: Configure Terraform using Azure PowerShell](https://learn.microsoft.com/en-us/azure/developer/terraform/get-started-powershell) (applicable to OpenTofu)

### Ubuntu

- How to Install Kubernetes (k8s) on [Ubuntu](https://ubuntu.com/kubernetes/install)
- Google Cloud SDK [Installing a Snap package](https://cloud.google.com/sdk/docs/downloads-snap)
- NGINX Ingress Controller [Bare-metal considerations](https://kubernetes.github.io/ingress-nginx/deploy/baremetal/)
- [Allow non-root process to bind to port 80 and 443?](https://superuser.com/questions/710253/allow-non-root-process-to-bind-to-port-80-and-443/892391#892391)

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.31

Back to [Yuruna](../README.md)
