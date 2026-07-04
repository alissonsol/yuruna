# Level-2 component breakdown

> One sentence: each Level-1 component expanded into at most seven real
> child scripts/modules/directories.

See [Design overview](00-index.md) · [Level-1 components](01-context-and-components.md) · [Yuruna Architecture](../architecture.md).

## Deploy Engine — `automation/`

```mermaid
flowchart TD
    set-resource[Set-Resource.ps1<br/>Yuruna.Resource]
    set-component[Set-Component.ps1<br/>Yuruna.Component + Registry]
    set-workload[Set-Workload.ps1<br/>Yuruna.Workload]
    validation[Test-Runtime / Test-Requirement<br/>Test-Configuration]
    config-parse[Import.Yaml + VariableExpansion<br/>Invoke-DynamicExpression]
    cross-cutting[Retry / Result / Log<br/>cross-cutting psm1]
    diagnostic[Get-SystemDiagnostic.ps1<br/>post-phase verify]

    config-parse --> set-resource --> set-component --> set-workload
    validation --> config-parse
    cross-cutting -.-> set-resource
    cross-cutting -.-> set-component
    cross-cutting -.-> set-workload
    set-workload --> diagnostic
```

## Host Provisioning — `host/`

```mermaid
flowchart TD
    windows-hyperv[windows.hyper-v<br/>provider]
    ubuntu-kvm[ubuntu.kvm<br/>provider]
    macos-utm[macos.utm<br/>provider]
    host-contract[Yuruna.Host.Contract.psm1<br/>New/Start/Stop/Remove-VM]
    host-modules[modules/<br/>Provision, Download, Image, UbuntuImage, Cleanup]
    vmconfig[vmconfig/<br/>shared cloud-init user-data]
    infra-guests[guest.caching-proxy<br/>guest.stash-service]

    host-contract --> windows-hyperv
    host-contract --> ubuntu-kvm
    host-contract --> macos-utm
    host-modules -.-> host-contract
    vmconfig -.-> host-contract
    infra-guests -.-> host-contract
```

`infra-guests` (`guest.caching-proxy`, `guest.stash-service`) is a logical
aggregate: these directories live nested under each provider
(`windows.hyper-v/`, `ubuntu.kvm/`, `macos.utm/`), not at the `host/` root
(see the [≤7 rule](00-index.md#the-7-rule-grouping-decisions)).

## Guest Workloads — `guest/`

```mermaid
flowchart TD
    amazon-linux[amazon.linux.2023]
    ubuntu-24[ubuntu.server.24]
    ubuntu-26[ubuntu.server.26]
    windows-11[windows.11]
    macos-26[macos.26]

    amazon-linux -.- ubuntu-24 -.- ubuntu-26 -.- windows-11 -.- macos-26
```

Each holds the in-guest workload scripts fetched and run via
`automation/fetch-and-execute.sh` once the guest is booted.

## Test Harness — `test/`

```mermaid
flowchart TD
    runner[Invoke-TestRunner.ps1<br/>outer/inner loop, watchdog, state]
    sequences[sequences/ gui+ssh<br/>Invoke-Sequence + OCR]
    status[status/<br/>HTTP UI + runtime state]
    extensions[extension/<br/>auth, notify, parser, pool, stash]
    pool[pool/<br/>multi-host pool admin]
    cache-stash[caching proxy + stash<br/>Start/Stop scripts]
    schemas[schemas/<br/>YAML validation schemas]

    runner --> sequences
    runner --> status
    runner --> extensions
    runner --> cache-stash
    pool -.-> runner
    schemas -.-> sequences
```

## Installers — `install/`

```mermaid
flowchart TD
    win-install[windows.hyper-v.ps1]
    kvm-install[ubuntu.kvm.sh]
    utm-install[macos.utm.sh]
    integrity[keys/ + install.sha256<br/>install.sha256.sig]

    integrity -.->|verify| win-install
    integrity -.->|verify| kvm-install
    integrity -.->|verify| utm-install
```

## Project & Global Data — `yuruna-project/`, `global/`

```mermaid
flowchart TD
    examples[yuruna-project/example<br/>website, text-to-sql]
    template[yuruna-project/template<br/>placeholder scaffold]
    cloud-config[config/&lt;cloud&gt;<br/>resources/components/workloads.yml]
    components-dir[components/&lt;project&gt;<br/>Dockerfiles + build context]
    workloads-dir[workloads/&lt;project&gt;<br/>Helm charts]
    global-resources[global/resources<br/>OpenTofu templates per cloud]
    vault[vault<br/>users.yml, transports.yml]

    examples --> cloud-config
    template --> cloud-config
    cloud-config --> components-dir
    cloud-config --> workloads-dir
    global-resources -.-> cloud-config
    vault -.-> cloud-config
```

## External Services

```mermaid
flowchart TD
    clouds[Cloud providers<br/>AWS / Azure / GCP]
    registries[Registries<br/>ECR / ACR / zot / localhost]
    clusters[Kubernetes<br/>EKS / AKS / GKE / docker-desktop]
    github[GitHub<br/>framework + project repos]
    mirrors[Upstream mirrors<br/>apt / dnf, images]
    ocr[OCR engines<br/>Tesseract / WinRT]

    clouds -.- registries -.- clusters
    github -.- mirrors -.- ocr
```

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.03
