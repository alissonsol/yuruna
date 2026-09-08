<a id="42d43217-0001"></a>

# Yuruna documentation

What each document under `docs/` covers. Start with
[Yuruna Architecture](architecture.md) for the cross-cutting model every
other doc builds on, or [Operator runbook](operator.md) if you are bringing
up a test machine.

<a id="42d43217-0002"></a>

## Start here

Portuguese (Brazil): [documentação em português](pt-BR/index.md) -- a
machine-produced first draft of the operator subset, pending native review.
English remains the source of truth.

- **[architecture.md](architecture.md)** -- the three capabilities and the
  three-phase Resources -> Components -> Workloads model, plus the CLI entry
  points. Cross-cutting concepts every other README links to rather than
  repeats.
- **[install.md](install.md)** -- load-bearing rationale for the three bootstrap
  installers (Windows Hyper-V, Ubuntu KVM, macOS UTM): what each step does and
  why it is ordered that way. The installers stop at packages and the clone;
  [`install/setup.ps1`](../install/README.md#guided-setup) takes a machine from
  there to a working standalone host or lab, and
  [`test/lab/Disable-TestAutomation.ps1`](operator.md#putting-the-machine-back)
  puts it back.
- **[operator.md](operator.md)** -- bring-up runbook for a single test
  machine: OS baseline to a passing cycle, the test user, and the
  caching-proxy-service / stash-service VMs. Its [preflight
  dependencies](operator.md#b2-preflight-dependencies) section lists every
  tool to install before running Yuruna, the cloud accounts and CLIs, and the
  environment the instructions were tested against.
- **[lab-operator.md](lab-operator.md)** -- bring-up runbook for a lab:
  shared NAS storage, caching-proxy-service, stash and pool-control services,
  each additional machine enrolled via the dashboard's Lab token, and a
  two-pool split running a different test-set on each.
- **[lab-new-machine.md](lab-new-machine.md)** -- adding one machine to an
  existing lab, step by step: creating the account the harness runs as (and
  what a domain password policy does to it), signing in, the GitHub
  credential, the configuration sync and its Lab-token prompt, and which
  warnings a first `Test-Config.ps1` is expected to print.
- **[definition.md](definition.md)** -- the glossary: generic and
  Yuruna-specific terms in one place, so the framework, guest scripts, and docs
  stay consistent.
- **[opportunities.md](opportunities.md)** -- work the project would welcome
  help on, ranked by return on investment, with a roadmap.

<a id="42d43217-0003"></a>

## Deploying applications

- **[kubernetes.md](kubernetes.md)** -- the user-facing quick start: deploy a
  containerized app to localhost, Azure, or AWS with one workflow, and clean up
  the cloud resources afterwards.
- **[authentication.md](authentication.md)** -- how to authenticate to Docker
  Desktop, AWS, Azure, and Google Cloud, how the [component-push pipeline logs
  into the target container
  registry](authentication.md#component-registry-login) before pushing images,
  plus the test-harness vault threat model.
- **[cleanup is in kubernetes.md](kubernetes.md#cleaning-up-cloud-resources)** --
  destroying cloud resources automatically or by hand, per cloud.

<a id="42d43217-0004"></a>

## Test harness

- **[test-harness.md](test-harness.md)** -- how `test/` is put together: entry
  points and modules, including the
  [host-condition registry](test-harness.md#host-condition-registry) --
  the three-method contract each host platform implements to apply and
  verify host settings, how a drifted
  [host clock](test-harness.md#the-host-clock) is reported, and the
  [capability matrix and cycle-plan
  gate](test-harness.md#capability-matrix-and-cycle-plan-gate) -- the per-cycle
  banner naming what the harness can actually do on the current host (OCR
  engines, host I/O, and more), and the gate that refuses a cycle needing a
  backend this host has not wired.
- **[test-sequences.md](test-sequences.md)** -- authoritative reference for every
  action available in a sequence file, the [handler
  contract](test-sequences.md#handler-contract) for the verb registry that
  drives the YAML sequence engine, plus the per-host contract functions.
- **[test-config.md](test-config.md)** -- every key in the per-host
  `test/test.config.yml`, which is bootstrapped from a template and stays local.
- **[test-perf.md](test-perf.md)** -- the append-only structured log of every step
  execution, for cross-host and cross-cycle performance analytics.
- **[runner-outer-loop.md](runner-outer-loop.md)** -- the daily-driver runner,
  end to end. What to do [once per machine](runner-outer-loop.md#prepare-the-host)
  before leaving it unattended -- test account, host settings, the first
  interactive run -- and the two
  [startup gates](runner-outer-loop.md#startup-gates) that refuse a degraded
  loop. Then the eternal cycle loop that makes the runner resilient, the five
  things it does every pass, the [heartbeat protocol and out-of-process
  watchdog](runner-outer-loop.md#watchdog-and-heartbeat-protocol) that lets it
  survive guest, network, and host-OS failures, and the runner's six-state
  lifecycle machine.
- **[extensions-api.md](extensions-api.md)** -- the eight classes of swappable
  behavior under `test/extension/` and the contract each area implements.
- **[ocr.md](ocr.md)** -- how the guest framebuffer is polled for text, and the
  three pluggable matching providers behind `waitForText` and friends.
- **[loglevels.md](loglevels.md)** -- the single resolved log level, how it gates
  PowerShell streams, and how it propagates across every child process.
- **[accessibility.md](accessibility.md)** -- the WCAG 2.2 AA target, the
  surfaces in and out of scope, an operator keyboard reference, and the two
  gates that hold the line.

<a id="42d43217-0005"></a>

## Failures and self-healing

- **[failure-schema.md](failure-schema.md)** -- the `last_failure.json` record and
  the matching `step_failure` event, both produced from one builder so they
  cannot drift, plus the
  [remediation dispatcher](failure-schema.md#remediation-dispatcher) that routes
  a `failureClass` token to a recovery recommendation.
- **[system-diagnostic.md](system-diagnostic.md)** -- the read-only diagnostic
  dump collected during incident triage.
- **[workarounds.md](workarounds.md)** -- frequently asked questions plus
  workarounds from development, starting with connectivity, and
  [per-guest-OS troubleshooting](workarounds.md#guest-troubleshooting) for
  Amazon Linux, Ubuntu Server, and Windows 11.
- **[memory.md](memory.md)** -- load-bearing rationale that used to live inline in
  the code, kept here so long explanations do not drift out of date.

<a id="42d43217-0006"></a>

## Hosts and guests

- **[host-hyperv.md](host-hyperv.md)** -- Windows Hyper-V host notes: cleaning up
  old VM files, screen-capture and OCR without a monitor, and related traps.
- **[host-macos.md](host-macos.md)** -- macOS UTM host notes, including Homebrew
  and PATH issues. Intentionally brief.
- **[host-io.md](host-io.md)** -- the dispatcher every GUI-driving step goes
  through for keystrokes, text input, and mouse clicks.
- **[guest-image-setup.md](guest-image-setup.md)** -- the shared image lifecycle
  every `host/<HOST>/guest.<GUEST>/` folder follows; per-host READMEs document
  only the deltas. Continues past first boot into the scripts that run *inside*
  the guest: the per-guest update script and the optional
  [software workloads](guest-image-setup.md#guest-workloads) installed via
  `fetch-and-execute.sh`.
- **[vmconfig.md](vmconfig.md)** -- rationale behind every non-trivial line in the
  per-guest `vmconfig/` artifacts, so the seed files themselves stay short, plus
  the shared base + per-host overlay rendering pipeline that produces them, and
  the [caching-proxy-service seed](vmconfig.md#caching-proxy-service-seed-topics)
  that builds the cache VM.

<a id="42d43217-0007"></a>

## Caching, network, and storage

- **[caching.md](caching.md)** -- the two composable caching layers: the
  `YurunaCacheContent` cache-buster and the Squid cache VM -- plus the
  [operator reference](caching.md#caching-proxy-service--test-harness-operator-reference):
  exposing the cache to remote clients, pointing a host at a remote
  cache, and preflighting.
- **[cache-health-dashboard.md](cache-health-dashboard.md)** -- the cache VM's two
  Grafana dashboards: the zot registry-path manifest latency canary, upstream pull
  budget, and slow-request forensics, plus the Squid web-path throughput, hit
  ratios, connectivity, and offline mode. Both dashboards' tooltips link here.
- **[network.md](network.md)** -- rationale for network-related workarounds in the
  guest scripts and the host harness.
- **[pool-storage.md](pool-storage.md)** -- the optional NAS-backed durable tier,
  and why host-local storage is treated as ephemeral.

<a id="42d43217-0008"></a>

## Pools and services

- **[pool-admin.md](pool-admin.md)** -- the pool administrator's guide: group
  hosts into a pool and assign them test-sets through the admin commands, and
  the [Pool-control service](pool-admin.md#pool-control-service) -- the operator
  UI and API that drives the pool-intent git store, which runners only ever
  pull read-only.
- **[pool-dashboard.md](pool-dashboard.md)** -- the Yuruna hosts Grafana dashboard,
  panel by panel: what each tile and table means, how the Host ID menus and `/go/`
  links behave, and the metrics behind them. The panels' (i) tooltips link here.
- **[download-agent.md](download-agent.md)** -- the pool-wide image downloader:
  one machine fetches a guest image and every host reads it from the pool
  share, kept fresh on a timer and managed from the service's own board.
- **[control-routes.md](control-routes.md)** -- the state-changing `/control/*`
  routes on a host's status service and the proof required to call them.
- **[stash-guide.md](stash-guide.md)** -- the shared drop box for files and
  snippets: put content in over `scp` or the browser, then manage it in the web
  UI.

<a id="42d43217-0009"></a>

## Design

- **[design/00-index.md](design/00-index.md)** -- entry point to the generated
  design diagrams: what each shows, how they relate, and the source each was
  derived from. From there: [context and
  components](design/01-context-and-components.md), the [component
  breakdown](design/02-component-breakdown.md), [data
  flows](design/03-data-flows.md), [lifecycle
  state](design/04-lifecycle-state.md), the [configuration data
  model](design/05-data-model.md), and the [deployment
  topology](design/06-deployment.md).
- **[design/naming.md](design/naming.md)** -- the naming rules: components are
  "`<name>` service", durations carry `Seconds`/`Ms`, booleans are bare
  adjectives, acronyms are words in camelCase -- plus the foreign contracts
  (Kubernetes, .NET, squid) that are deliberately exempt.

<a id="42d43217-000a"></a>

## Further reading

External documentation for the tools Yuruna uses, grouped by topic.

<a id="42d43217-000b"></a>

### AWS

- [Getting started with Amazon ECR using the AWS CLI](https://docs.aws.amazon.com/AmazonECR/latest/userguide/getting-started-cli.html)

<a id="42d43217-000c"></a>

### Azure

- [Azure Container Registry documentation](https://learn.microsoft.com/en-us/azure/container-registry/)
- [Create an ingress controller with a static public IP address in Azure Kubernetes Service (AKS)](https://learn.microsoft.com/en-us/azure/aks/ingress-static-ip)
- [Use a static public IP address and DNS label with the Azure Kubernetes Service (AKS) load balancer](https://learn.microsoft.com/en-us/azure/aks/static-ip)
- [AKS with multiple nginx ingress controllers, Application Gateway and Key Vault certificates](https://web.archive.org/web/2023/https://blog.hjgraca.com/aks-with-multiple-nginx-ingress-controllers-application-gateway-and-key-vault-certificates)

<a id="42d43217-000d"></a>

### GCP

- [Configuring cluster access for kubectl](https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl)
- [Using Container Registry with Google Cloud](https://cloud.google.com/container-registry/docs/using-with-google-cloud-platform)
- Container Registry Guides: [Authentication methods](https://cloud.google.com/container-registry/docs/advanced-authentication)
- Container Registry Guides: [Configuring access control](https://cloud.google.com/container-registry/docs/access-control)
- [Reserving a static external IP address](https://cloud.google.com/compute/docs/ip-addresses/reserve-static-external-ip-address#gcloud)
- [Setting up HTTP(S) Load Balancing with Ingress](https://cloud.google.com/kubernetes-engine/docs/tutorials/http-balancer)
  - Notice that this doesn't apply when using [Ingress with NGINX controller on Google Kubernetes Engine](https://cloud.google.com/community/tutorials/nginx-ingress-gke)
  - [Configuring domain names with static IP addresses](https://cloud.google.com/kubernetes-engine/docs/tutorials/configuring-domain-name-static-ip)

<a id="42d43217-000e"></a>

### Kubernetes

- [OpenTofu Documentation](https://opentofu.org/docs/)
- [Declarative Management of Kubernetes Objects Using Kustomize](https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/)

<a id="42d43217-000f"></a>

### Ingress

- [ingress-nginx](https://github.com/kubernetes/ingress-nginx/tree/master/charts/ingress-nginx) at GitHub
- [Redirect to www with an nginx ingress](https://www.informaticsmatters.com/blog/2020/06/03/redirecting-to-www.html)
- [How To Set Up an Nginx Ingress on DigitalOcean Kubernetes Using Helm](https://www.digitalocean.com/community/tutorials/how-to-set-up-an-nginx-ingress-on-digitalocean-kubernetes-using-helm)

<a id="42d43217-0010"></a>

### Certificates

- [cert-manager](https://cert-manager.io/docs/installation/) documentation
- NGINX Ingress Controller [TLS termination](https://kubernetes.github.io/ingress-nginx/examples/tls-termination/)

<a id="42d43217-0011"></a>

### PowerShell

- PSScriptAnalyzer [code](https://github.com/PowerShell/PSScriptAnalyzer)
  - If not yet installed: `Install-Module -Name PSScriptAnalyzer`
  - `Invoke-ScriptAnalyzer -Path . -Recurse` (auto-picks up the repo-root
    `PSScriptAnalyzerSettings.psd1`)
  - `Invoke-ScriptAnalyzer -Path . -Recurse | Select-Object -Property Line, Column, ScriptPath, RuleName, Message`
  - BOM-only spot check: `Invoke-ScriptAnalyzer -Path . -Recurse | Where-Object RuleName -eq 'PSUseBOMForUnicodeEncodedFile'`
- [Quickstart: Configure Terraform using Azure PowerShell](https://learn.microsoft.com/en-us/azure/developer/terraform/get-started-powershell) (applicable to OpenTofu)

<a id="42d43217-0012"></a>

### Ubuntu

- How to Install Kubernetes (k8s) on [Ubuntu](https://ubuntu.com/kubernetes/install)
- Google Cloud SDK [Installing a Snap package](https://cloud.google.com/sdk/docs/downloads-snap)
- NGINX Ingress Controller [Bare-metal considerations](https://kubernetes.github.io/ingress-nginx/deploy/baremetal/)
- [Allow non-root process to bind to port 80 and 443?](https://superuser.com/questions/710253/allow-non-root-process-to-bind-to-port-80-and-443/892391#892391)

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.08

Back to [Yuruna](../README.md)
