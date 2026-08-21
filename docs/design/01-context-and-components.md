# Context and Components

> One sentence: the seven level-1 blocks Yuruna is built from, where each one lives on disk, and which calls actually cross the boundaries between them.

See [Design overview](00-index.md) - [Component breakdown](02-component-breakdown.md) -
[Yuruna Architecture](../architecture.md).

## Where the blocks come from

The blocks below are not an invented taxonomy. They are the tracked top-level
directories of the two repositories, read with `git ls-tree --name-only HEAD`.

`yuruna` tracks nine directories: `automation/`, `dev-only/`, `docs/`, `global/`,
`guest/`, `host/`, `install/`, `test/`, `tools/`. `yuruna-project` tracks four:
`book/`, `example/`, `template/`, `test/`.

Three exclusions and two merges turn that listing into seven blocks:

- **`docs/` and `dev-only/` are excluded.** They are documentation and maintainer
  trees. No runtime path reads them, and this file lives inside one of them.
- **`project/` is excluded.** It exists in a working tree but is gitignored at
  `.gitignore:376`, because `Update-ProjectClone`
  (`test/modules/Test.HostGit.psm1:785`) deletes and re-clones it at the start of
  every cycle so the previous cycle's output cannot leak forward.
- **Root files are excluded** (`README.md`, `VERSION`, `PSScriptAnalyzerSettings.psd1`,
  and so on). They are repository furniture, not system parts.
- **`global/` and the whole `yuruna-project` repository merge into one block.**
  A resource template is resolved project-first and global-second by the same two
  lines of the same function, so the two roots are one namespace rather than two
  components (see the boundary notes below).
- **`install/` and `tools/` merge into one block.** For one reason:
  `tools/Update-YurunaReleasePins.ps1` regenerates and signs the manifest the
  installers are verified against, which makes the two roots one release path. The
  rest of `tools/` is repository gates that run against every other block (see the
  boundary notes below).

One block, External Services, owns no directory at all. It is declared last for
that reason; every other block is declared in repository directory order.

## The seven blocks

```mermaid
flowchart TD
  subgraph deploy-engine["Deploy Engine"]
    automation["automation/"]
  end
  subgraph project-data["Project & Global Data"]
    project-trees["global/ + project repo"]
  end
  subgraph guest-workloads["Guest Workloads"]
    guest-scripts["guest/"]
  end
  subgraph host-provisioning["Host Provisioning"]
    host-drivers["host/"]
  end
  subgraph installers["Installers"]
    install-tools["install/ + tools/"]
  end
  subgraph test-harness["Test Harness"]
    test-tree["test/"]
  end
  subgraph external-services["External Services"]
    external-endpoints["clouds, registries, upstreams"]
  end

  install-tools -->|"installs host prerequisites"| host-drivers
  install-tools -->|"runs setup steps"| test-tree
  install-tools -->|"checks version floors"| automation
  test-tree -->|"loads host driver"| host-drivers
  test-tree -->|"re-clones project repo"| project-trees
  test-tree -->|"types fetch command"| automation
  test-tree -->|"names guest script"| guest-scripts
  test-tree -->|"git pull, email"| external-endpoints
  host-drivers -->|"imports shared modules"| automation
  host-drivers -->|"imports harness modules"| test-tree
  host-drivers -->|"cloud-init runs script"| guest-scripts
  host-drivers -->|"downloads base images"| external-endpoints
  automation -->|"fetches, verifies, runs"| guest-scripts
  automation -->|"runs per-host script"| host-drivers
  automation -->|"emits retry telemetry"| test-tree
  automation -->|"reads config, templates"| project-trees
  project-trees -->|"invokes phase scripts"| automation
  automation -->|"tofu, docker, helm"| external-endpoints
  guest-scripts -->|"package upstreams"| external-endpoints
```

Seven boxes, one per block, nothing folded into an aggregate. Each edge names a
call, and all but the last name the file it lives in:

- `install-tools -> host-drivers`: `install/ubuntu.kvm.sh:937` installs
  `host/ubuntu.kvm/yuruna-bridge-pin.sudoers` (resolved at `:923`, invoked at
  `:945`),
  and `:1146` points the operator at
  `host/ubuntu.kvm/Enable-TestAutomation.ps1`.
- `install-tools -> test-tree`: `install/setup.ps1:3356` runs
  `test/lab/Set-LabToken.ps1`; the same script drives `test/service/*` and
  `test/pool/*`.
- `install-tools -> automation`: each bootstrapper checks the tools it manages
  against the floors in `automation/Yuruna.Requirement.yml` before it finishes --
  `install/ubuntu.kvm.sh:1175`, `install/macos.utm.sh:1120`,
  `install/windows.hyper-v.ps1:1511` -- and parses the `REQUIREMENT-ISSUE:` lines
  `Test-Requirement.ps1 -WarnOnly` prints.
- `test-tree -> host-drivers`: `test/modules/Test.HostBootstrap.psm1:79` resolves
  `host/<type>/modules/Yuruna.Host.psm1` and imports it, throwing when it is absent.
- `test-tree -> project-trees`: `Update-ProjectClone`
  (`test/modules/Test.HostGit.psm1:785`) re-clones the project repository;
  `test/Test-Config.ps1:711-757` classifies the resulting slot before a cycle
  starts; and `test/service/Start-StatusService.ps1:2793-2803` serves the tree to
  guests as `/yuruna-project-archive.tar.gz`.
- `test-tree -> automation`: `test/sequences/start.guest.ubuntu.server.24.yml:99`
  types `/usr/local/lib/yuruna/fetch-and-execute.sh` into the guest console; that
  binary is `automation/fetch-and-execute.sh`, seeded into the guest.
- `test-tree -> guest-scripts`: the sequences name the `guest/**` path they hand
  to `fetch-and-execute.sh` (`test/sequences/workload.guest.ubuntu.server.24.yml:42`),
  and Pester modules read the same scripts as fixtures
  (`test/modules/Test.ExtensionService.Tests.ps1:335`).
- `test-tree -> external-endpoints`: `Invoke-GitPull`
  (`test/modules/Test.HostGit.psm1:349`) and the Resend call at
  `test/extension/notification/default.psm1:91`.
- `host-drivers -> automation`: `host/ubuntu.kvm/modules/Yuruna.Host.psm1:94`
  imports `automation/Yuruna.Common.psm1`; 21 of the 25 per-guest builders call
  `New-CloudInitUserData` (`host/windows.hyper-v/guest.stash-service/New-VM.ps1:213`).
  The four that do not are all three `guest.windows.11` builders -- Windows has no
  cloud-init, and each reads a builder-local `vmconfig/autounattend.xml` instead --
  and `host/macos.utm/guest.macos.26/New-VM.ps1`.
- `host-drivers -> test-tree`: every driver's load tail imports
  `test/modules/Test.Ssh.psm1` and `Test.CachingProxyService.psm1` `-Global`
  (`host/ubuntu.kvm/modules/Yuruna.Host.psm1:95-96`), and the per-host operator
  scripts pull `Test.HostAutomationState`, `Test.HostCondition`,
  `Test.StatusFirewall`, `Test.HostIdentity` and `Test.ConfigServiceSync`.
- `host-drivers -> external-endpoints`: `host/modules/Yuruna.Image.psm1` pulls
  cloud images from `cloud-images.ubuntu.com` and GPG-verifies them against the
  pinned keyring in `host/modules/keys/`; `host/modules/Yuruna.UbuntuImage.psm1`
  resolves live-server ISOs from `cdimage.ubuntu.com` / `releases.ubuntu.com`.
- `host-drivers -> guest-scripts`: the seed at
  `host/vmconfig/stash-service.base.user-data:186` runs
  `guest/ubuntu.server.26/ubuntu.server.26.stash-service.sh` by absolute path.
- `automation -> guest-scripts`: `automation/fetch-and-execute.sh` fetches a
  `guest/**` path and gates it on the host-supplied SHA-256 before any byte
  reaches bash. The harness envelope always sets `EXEC_REQUIRE_SHA256=1`, so a
  missing digest fails closed there; a hand-run with neither a digest nor that
  variable warns and runs the bytes unverified
  (`automation/fetch-and-execute.sh:275-284`).
- `automation -> project-trees`: `automation/Yuruna.Resource.psm1:105` falls back
  to `global/resources/<template>`; the phase scripts read
  `<project_root>/config/<sub>/*.yml`.
- `project-trees -> automation`: the project's own guest script calls the phase
  entry points, e.g.
  `yuruna-project/example/website/test/ubuntu.server.24/ubuntu.server.24.workload.k8s.website.sh:263`.
- `automation -> host-drivers`: `Invoke-YurunaHostScript`
  (`automation/Yuruna.HostRedirect.psm1:250`) resolves and runs the current
  platform's `host/<host type>/<script>.ps1`; `test/lab/Enable-TestAutomation.ps1`
  is the host-neutral entry point that goes through it.
- `automation -> test-tree`: `automation/Yuruna.HostRedirect.psm1:127` loads
  `test/modules/Test.HostDetection.psm1` on demand, and
  `automation/Yuruna.Retry.psm1:144` calls `Send-CycleEventSafely`
  (`test/modules/Test.Log.psm1`) to emit `retry_attempt` / `retry_exhausted` --
  a `Get-Command`-guarded call, so it is a no-op outside a cycle.
- `automation -> external-endpoints`: `tofu init`
  (`automation/Yuruna.Retry.psm1:319`), `plan` and `apply`
  (`automation/Yuruna.Resource.psm1:253`, `:257`) and `destroy`
  (`automation/Yuruna.Clear.psm1:84`); `helm upgrade --install --atomic` and
  `kubectl config use-context` from `automation/Yuruna.Workload.psm1`; docker
  build and push through `Invoke-ComponentCommand`; and the five registry logins
  registered in `automation/Yuruna.CredentialProvider.psm1`.
- `guest-scripts -> external-endpoints`: every family's update script installs
  from upstream package repositories -- `*.update.sh` on the four Linux and macOS
  families, `guest/windows.11/windows.11.update.ps1` on Windows, which has no `.sh`
  at all -- as do the workload scripts (`guest/ubuntu.server.26/ubuntu.server.26.k8s.sh`
  reaches `download.docker.com` and `pkgs.k8s.io`).

## What each block is

| Component | Root | Responsibility |
|---|---|---|
| Deploy Engine | `automation/` | 44 files: 22 `.psm1` (20 of them `Yuruna.*`), 15 `.ps1`, 6 guest shell scripts, and `Yuruna.Requirement.yml`. Three phase entry points -- `Set-Resource.ps1`, `Set-Component.ps1`, `Set-Workload.ps1` -- drive OpenTofu, Docker and helm/kubectl. `Get-YurunaGuestScriptBase64` (`automation/Yuruna.CloudInitTemplate.psm1:199`) encodes five of the six for a seed -- `fetch-and-execute.sh`, `yuruna-retry.sh`, `yuruna-network.sh`, `yuruna-host-locate.sh`, `yuruna-versions.sh` -- but only the two general-purpose guest seeds carry all five placeholders (`host/vmconfig/ubuntu.server.base.user-data`, `amazon.linux.2023.base.user-data`); the four service seeds take `yuruna-host-locate.sh` alone. The sixth script, `yuruna-run.sh`, is never seeded: it is streamed in over SSH, so the supervisor always matches this harness rather than the oldest snapshot. |
| Project & Global Data | `global/`, `yuruna-project/` | 51 files under `global/`, including 10 OpenTofu templates across 3 clouds (`aws`, `azure`, `localhost`); `global/components/` and `global/workloads/` hold only `placeholder`. 116 tracked files in `yuruna-project`: `template/` (scaffold, `localhost` only), `example/website` (the only project with `aws`, `azure` and `localhost`), `example/text-to-sql`, `example/nested.host` (sequences, no deploy tree), and `book/`. |
| Guest Workloads | `guest/` | 30 files, 24 of them scripts, in 5 families: `amazon.linux.2023`, `macos.26`, `ubuntu.server.24`, `ubuntu.server.26`, `windows.11`. Workload names are `update`, `code`, `k8s`, `n8n`, `openclaw`, `postgresql`, plus the three `ubuntu.server.26`-only service builders (`stash-service`, `download-agent-service`, `pool-control-service`). |
| Host Provisioning | `host/` | 150 files. Three `modules/Yuruna.Host.psm1` drivers -- `windows.hyper-v`, `ubuntu.kvm`, `macos.utm` -- all implementing the 38 verbs declared in `Yuruna.Host.Contract.psm1`. 25 `guest.*` builder directories, 6 shared modules under `host/modules/`, and 31 cloud-init seed files under `vmconfig/`. |
| Installers | `install/`, `tools/` | 10 tracked files in `install/`: three bootstrappers (`windows.hyper-v.ps1`, `ubuntu.kvm.sh`, `macos.utm.sh`), the guided `setup.ps1`, the `install.sha256` manifest with its detached signature and two public-key encodings, and two READMEs (`install/README.md` carries the verified download path). 11 files in `tools/`: four source gates (`Test-AsciiNoBom.ps1`, `Test-RegionAnchors.ps1`, `Invoke-Lint.ps1`, `Invoke-ShellCheck.ps1`), the suite runners (`Invoke-TestSuite.ps1` with its per-suite child shim `_InvokeOneSuite.ps1`, `Invoke-GoTest.ps1`, `Invoke-JsTest.ps1`), the operator-run `Update-TestConfigNaming.ps1` migration, `Update-YurunaReleasePins.ps1`, and `githooks/pre-commit`. |
| Test Harness | `test/` | 633 tracked files: 96 `.psm1` under `test/modules/`, 19 files in `test/sequences/`, 13 JSON Schemas in `test/schemas/`, 15 scripts in `test/service/`, 13 pool-admin scripts in `test/pool/`, and 8 contract-bearing areas plus the shared Go SDK under `test/extension/`. |
| External Services | (no directory) | Cloud control planes reached through OpenTofu providers, and the cluster API through helm/kubectl; container registries behind the five credential providers (`azurecr`, `ecr`, `gar`, `dockerhub`, `docker-generic`); the OpenTofu provider registry `tofu init` reads; GitHub, via the Contents API (`automation/fetch-and-execute.sh:168`, the token route) or `raw.githubusercontent.com` (`:170`, public only) and via `git pull` (`test/modules/Test.HostGit.psm1:349`); upstream package repositories and OS image publishers; and Resend for e-mail. |

## Edges that are easy to misread

- **No cycle path in `test/` calls a phase entry point.** The deploy engine is
  driven from inside the guest, by a script the *project* ships: the harness types
  `fetch-and-execute.sh guest/.../update.sh`, the guest later runs the project's own
  workload script, and that script calls
  `pwsh ../../automation/Set-Resource.ps1 website localhost`
  (`yuruna-project/example/website/test/ubuntu.server.24/ubuntu.server.24.workload.k8s.website.sh:263`).
  The one caller on the harness side is out of band and never runs in a cycle:
  `test/service/Start-McpServer.ps1` is an operator-launched stdio MCP server that
  exposes ten `automation/` entry points -- the three phase scripts and
  `Invoke-Clear.ps1` among them (`test/service/Start-McpServer.ps1:164-185`) --
  each shelled out as a child `pwsh` (`:133`). A project sequence can also reach a
  phase script in-cycle without any of this: `Invoke-OrchestratorHostAction`
  (`test/modules/Test.Orchestrator.psm1:70`) runs whatever host script a
  sequence's `host:` block names, and in a live project that script can be
  `Set-Resource.ps1`.
- **The arrow from Project & Global Data into the Deploy Engine is not backwards.**
  Data repositories usually do not call code, but this one ships the shell script
  that invokes all three phases (same citation as above). That is why the block is
  a source of an edge and not only a target.
- **`automation/` is not a leaf library.** It is imported by `host/` and `test/`, as
  expected, but it also reaches back: `automation/Yuruna.HostRedirect.psm1:127`
  loads `test/modules/Test.HostDetection.psm1` on demand. The dependency between
  the Deploy Engine and the Test Harness runs in both directions.
- **Service VMs build themselves; the harness only smoke-tests the same script.**
  In production a service guest runs its build script from cloud-init by absolute
  path (`host/vmconfig/stash-service.base.user-data:186`), not through
  `fetch-and-execute.sh` and not from a cycle. Three sequences do drive those same
  scripts through `fetch-and-execute.sh` --
  `test/sequences/workload.guest.ubuntu.server.26.stash-service.yml:50`,
  `...stash-service.ssh.yml:38` and `...download-agent-service.yml:52` -- but each
  says in its own header that it is a standalone smoke test of the daemon build,
  wired into no test-set and run by hand. `pool-control-service` has no sequence
  at all. Both paths reaching the same script is why those scripts are
  idempotent.
- **The installers stop short of provisioning.** `install/ubuntu.kvm.sh:1146`
  prints the `Enable-TestAutomation.ps1` command rather than running it -- the
  heredoc around it says "NOT run automatically" in as many words -- so the arrow
  into Host Provisioning is a handoff, not an invocation. The version-floor check
  in the same installers is the opposite case: it really does call into the Deploy
  Engine and read the answer back.

## Where the block boundaries do not match the directories

- **`automation/` is a shared library root, not just the Deploy Engine.** 30 files
  under `test/` name an `automation/Yuruna.*.psm1` path
  (`git grep -lE 'automation/Yuruna\.[A-Za-z0-9.]+\.psm1' -- test/`), 15 of them
  outside the Pester suites -- for example
  `test/Test-Config.ps1:124` (`Yuruna.Common.psm1`) and
  `test/modules/Test.CachingProxyService.psm1:1302` (`Yuruna.Retry.psm1`). Several
  modules in the directory (`Yuruna.CloudInitTemplate`, `Yuruna.GuestSeed`,
  `Yuruna.GitHubSource`, `Yuruna.HostRedirect`, `Yuruna.HostSetup`, `Yuruna.Log`)
  are never on a deploy path at all.
- **`global/` and a separate repository are one block.**
  `automation/Yuruna.Resource.psm1:105` resolves `<project_root>/resources/<t>`
  first and `<yuruna_root>/global/resources/<t>` second, with the same fallback
  duplicated in the validator at `automation/Yuruna.Validation.psm1:140`. The two
  roots are one template namespace with project-first precedence. The fallback is
  resources-only: `global/components/` and `global/workloads/` contain nothing but
  a `placeholder` file and no code path consults them.
- **`project/` is a directory but not a block.** It is gitignored
  (`.gitignore:376`) and re-created every cycle by `Update-ProjectClone`
  (`test/modules/Test.HostGit.psm1:785`), which deletes the tree before cloning.
  Its contents belong to Project & Global Data; its lifecycle belongs to the Test
  Harness.
- **`host/vmconfig/` is data, not code.** All 31 files are cloud-init seeds: 6
  `*.base.user-data`, 6 `*.meta-data`, 18 `*.overlay.yml`, and one shared
  `guest-dhcp.network-config`. There is no script in the directory. The merge logic
  that turns a base plus an overlay into a seed lives in the Deploy Engine, at
  `automation/Yuruna.CloudInitTemplate.psm1`.
- **`test/extension/` is mostly Go, not PowerShell.** Seven `go.mod` modules live
  there -- `caching-proxy-parser-service`, `caching-proxy-service`,
  `download-agent-service/server`, `extension-sdk`, `pool-aggregator-service`,
  `pool-control-service/server`, `stash-service/server` -- and the daemons they
  build run inside VMs, not in the runner process. Three of them sit at their area
  root rather than under a `server/` subdirectory -- `caching-proxy-service`,
  `caching-proxy-parser-service` and `pool-aggregator-service` -- because the VM
  that builds them has no framework checkout and cloud-init fetches their sources
  file by file: from an area-root module `../extension-sdk` is the real SDK both in
  the enlistment and beside the build directory on the guest, so nothing has to be
  staged. The `.psm1` files beside them are metadata stubs and host-side
  clients.
- **`tools/` ships no installer.** The two roots are one block for one reason only,
  `tools/Update-YurunaReleasePins.ps1` regenerates `install/install.sha256` and
  signs it, making the two roots one release path. The rest is source and suite
  gates that run against every other block, plus one operator-run migration
  (`Update-TestConfigNaming.ps1`, which rewrites a `test.config.yml` away from
  retired key names using the table in `test/modules/Test.ConfigNaming.psm1`) and
  the per-suite child shim `_InvokeOneSuite.ps1`, which is never a gate on its
  own.
