# Yuruna operator guide

Bring-up runbook for a single Yuruna test machine: operating-system
baseline to a passing test cycle, plus the two service VMs a standalone
machine benefits from (caching-proxy service, stash service).

[Section A: Quickstart](#section-a-quickstart) is the complete command
sequence — run it top to bottom. [Section B: Deep dive](#section-b-deep-dive)
explains each step: what the command does, why the order matters, and
where the details live. Every quickstart step links its deep-dive
counterpart; read that when a step needs judgment or fails.

This guide assumes you operate **one machine**. To bring up a lab —
several machines sharing one caching-proxy service, NAS-backed storage, and
pool-control service — complete A.1–A.2 here on each machine, then continue
with the [Lab operator guide](lab-operator.md).

---

## Section A: Quickstart

Start from a freshly installed Windows 11 Pro/Enterprise/Education (or
Windows Server), macOS 26+, or Ubuntu 26+ host: 32 GB RAM, 512 GB free
disk, 16+ physical cores, virtualization enabled in firmware, OS
activated and updated, network access to github.com
([B.1](#b1-operating-system-baseline-assumed)–[B.2](#b2-preflight-dependencies)).
"Elevated" means an Administrator PowerShell on Windows, `sudo` on
macOS / Ubuntu.

### A.1 Install the framework

Paste the one-liner for the host OS ([B.3](#b3-install-the-framework)).

Windows (PowerShell, self-elevates):

```
irm "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/windows.hyper-v.ps1?nocache=$(Get-Date -Format yyyyMMddHHmmss)" | iex
```

macOS (Terminal):

```
/bin/bash -c "$(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/macos.utm.sh?nocache=$(date +%Y%m%d%H%M%S)")"
```

Ubuntu (Terminal):

```
bash <(curl -fsSL "https://raw.githubusercontent.com/alissonsol/yuruna/refs/heads/main/install/ubuntu.kvm.sh?nocache=$(date +%Y%m%d%H%M%S)")
```

**Reboot if the installer says RESTART REQUIRED.** The framework lands
in `~/git/yuruna` (`%USERPROFILE%\git\yuruna` on Windows); run every
command below from that folder.

### A.2 Create the test user

Elevated ([B.4](#b4-create-the-yuruna-test-user)):

```
pwsh test/New-LocalTestUser.ps1 -Admin
```

**Sign in as the new account (default `yurunatest`) for everything
that follows**, and repeat the [A.1](#a1-install-the-framework)
one-liner once in that session: the clone is per-user, so this gives
the test account its own `~/git/yuruna`, config, and vault. The
second run is quick — dependencies are already in place.

> **Single machine or lab?** From here on this guide is the
> single-machine path. For a lab, switch to the
> [Lab operator guide](lab-operator.md) now — it picks up exactly
> after this step.

### A.3 Enable test automation

Elevated ([B.5](#b5-enable-test-automation)):

```
pwsh test/Enable-TestAutomation.ps1
```

On Windows, sign out and back in if it reports display-scaling
changes.

### A.4 Configure and validate

Edit `test/test.config.yml` — at minimum `repositories.projectUrl`
(and `GH_TOKEN` if private) and `guestSequence` — then validate
([B.6](#b6-configure-and-validate)):

```
pwsh test/Test-Config.ps1
```

Fix every FAIL before moving on.

### A.5 Create pool and stash storage

**Storage on this machine (no NAS)** — elevated, one idempotent command
creates the folders, the two storage accounts, the SMB shares, the
mounts, and the config
([B.7](#b7-local-shares-for-pool-and-stash-storage)):

```
pwsh test/New-LocalLabStorage.ps1
```

It asks only where storage should live, suggesting `/srv/yuruna`
(Ubuntu), `/Users/Shared/yuruna` (macOS), or `<drive>\Shares\yuruna`
(Windows, first non-system drive), and finishes with
`networkStorage.*` and both vault entries already written — so the
paragraph below about filling them in does not apply. It calls
`New-Lab` for you, so the lab exists too. Add `-EnableReplication` to
archive finished cycles to the pool share.

Adding **another lab** to that machine later needs only `New-Lab`,
with no `-Root`: it reuses the folders, the storage root, and the share
accounts that are already here.

```
pwsh test/New-Lab.ps1 -Name <lab-name>
```

**Storage on a NAS or a separate file server** — this machine cannot
create accounts there, so create the folders and the lab vault here
and grant the share permissions on the device itself:

```
pwsh test/New-Lab.ps1 -Name <lab-name> -Root <storage-root>
```

`<lab-name>` is lowercase (letters, digits, hyphens — the pool-id
charset); `<storage-root>` is e.g. `D:\work` on Windows or
`/srv/yuruna` on macOS / Ubuntu. Share the two folders it created —
one dedicated account per share, using the passwords `New-Lab` just
generated into the lab vault:

```powershell
# Elevated, Windows example
New-LocalUser yuruna-pool  -Password (Read-Host -AsSecureString 'yuruna-pool password')
New-LocalUser yuruna-stash -Password (Read-Host -AsSecureString 'yuruna-stash password')
New-SmbShare -Name yuruna.pool  -Path D:\work\yuruna.pool  -FullAccess yuruna-pool
New-SmbShare -Name yuruna.stash -Path D:\work\yuruna.stash -FullAccess yuruna-stash
icacls D:\work\yuruna.pool  /grant 'yuruna-pool:(OI)(CI)M'
icacls D:\work\yuruna.stash /grant 'yuruna-stash:(OI)(CI)M'
```

Then fill `networkStorage.*` in `test.config.yml` and store both
share passwords in the host vault — steps in
[Setting the SMB passwords in the vault](test-config.md#setting-the-smb-passwords-in-the-vault).

### A.6 Start the caching-proxy service

Elevated on Windows, `sudo -E` on macOS
([B.8](#b8-start-the-caching-proxy-service--dashboards)):

```
pwsh test/Start-CachingProxyServiceVM.ps1
```

Set `vmStart.cachingProxyIp` in `test.config.yml` to the proxy VM's
IP so cycles find it, then re-run `pwsh test/Test-Config.ps1` to
validate the A.5–A.6 config edits.

### A.7 Start the stash service

Elevated on Windows ([B.9](#b9-start-the-stash-service)):

```
pwsh test/Start-StashServiceVM.ps1
```

### A.8 Run one test cycle

Debug here until green ([B.10](#b10-run-one-test-cycle)):

```
pwsh test/Invoke-TestProject.ps1
```

### A.9 Run continuous cycles

([B.11](#b11-run-continuous-cycles)):

```
pwsh test/Invoke-TestRunner.ps1
```

Watch progress on the status dashboard it starts at
`http://<host>:8080/`.

---

## Section B: Deep dive

The quickstart order is deliberate: each step validates the one before
it, and cheap checks run before expensive ones (config validation
before the caching-proxy-service VM build). Every step below names the script
it runs and links the reference doc that owns the details.

### B.1 Operating-system baseline (assumed)

A freshly installed Windows 11 Pro/Enterprise/Education (or Windows
Server), macOS 26+, or Ubuntu 26+ host. Tested baseline: 32 GB RAM,
512 GB free disk, 16+ physical cores. The tool stack the framework
expects is listed in [B.2](#b2-preflight-dependencies).

### B.2 Preflight dependencies

Before running the installer, confirm:

- **License / activation** — Windows must be activated and a
  Hyper-V-capable edition (Pro or above; Home has no Hyper-V).
- **OS updates applied** — pending updates can force a reboot mid-install.
- **Virtualization enabled in firmware** — Intel VT-x / AMD-V
  (Ubuntu: `grep -E 'vmx|svm' /proc/cpuinfo` must match).
- **Network access to github.com** — the installer clones the framework.

The installer re-checks the hardware baselines and prompts before
proceeding on an under-spec'd host.

Some examples additionally assume a registered domain whose DNS records
you can create and edit at your registrar. Before installing certificates
on localhost, run `mkcert -install` once to create the local certificate
authority; this may require elevated privileges.

#### Required tools

The host installer ([B.3](#b3-install-the-framework)) puts most of these
in place. Install them by hand when running without the installer, or to
repair a partial install. After installing PowerShell, run
`Test-Requirement.ps1` to check which tools are present and whether their
versions meet the ones used in testing — the pinned versions live in
[`automation/Yuruna.Requirement.yml`](../automation/Yuruna.Requirement.yml).

- Install [PowerShell Core](https://github.com/powershell/powershell) 7.0+.
  On Windows, from an Administrator PowerShell:
  - `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned` (see [execution policies](https://go.microsoft.com/fwlink/?LinkID=135170))
  - `Install-Module -Name powershell-yaml`
- Install [Git](https://git-scm.com/downloads)
  - `git config --global user.name "Your Name"`
  - `git config --global user.email "Your@email.address"`
  - `git config --global core.autocrlf input`
- Using a Hyper-V machine in Windows? Enable [nested virtualization](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization)
- Using UTM on macOS? Nested virtualization (required for Docker Desktop
  inside the VM) needs macOS 15 Sequoia+, Apple M3+ chip, UTM v4.6+, and
  the Apple Virtualization backend (not QEMU).
- Install [Docker Desktop](https://docs.docker.com/desktop/)
  - Enable [Kubernetes](https://docs.docker.com/get-started/orchestration/)
  - Install [Docker buildx](https://github.com/docker/buildx) in the path.
- Install [Helm](https://helm.sh/docs/intro/install/) in the path.
  - Download: [`https://github.com/helm/helm/releases`](https://github.com/helm/helm/releases)
- Install [OpenTofu](https://opentofu.org/docs/intro/install/) in the path.
- Install [wget](https://www.gnu.org/software/wget/) in the path.
  - Binaries for Windows at [eternallybored.org](https://eternallybored.org/misc/wget/)
- Install [mkcert](https://github.com/FiloSottile/mkcert) in the path.
  - Run `mkcert -install`

#### Cloud tools

Needed only for the examples that deploy to a cloud; a local-only host
can skip this list.

- AWS
  - Create an [AWS Account](https://aws.amazon.com/free)
  - Install the [AWS CLI](https://aws.amazon.com/cli/)
- Azure
  - Create an [Azure Account](https://azure.microsoft.com/en-us/free/)
  - Install the [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
- Google Cloud SDK
  - Create a [Google Cloud Account](https://console.cloud.google.com/freetrial)
  - Install the [Google Cloud SDK CLI](https://cloud.google.com/sdk/docs/install)
- DNS provider and instructions to create an A record
  - Instructions for [Amazon Route 53](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resource-record-sets-creating.html)
  - Instructions for [Azure DNS](https://learn.microsoft.com/en-us/azure/dns/dns-getstarted-portal)
  - Instructions for [Google Cloud DNS](https://cloud.google.com/dns/docs/records)

#### Recommended tools

- Install the latest version of [Visual Studio Code](https://code.visualstudio.com/)
  - Install the [Docker](https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-docker) extension.
  - Install the [Kubernetes](https://marketplace.visualstudio.com/items?itemName=ms-kubernetes-tools.vscode-kubernetes-tools) extension.
- Install [Graphviz](https://graphviz.org/download/) in the path.
- Install [K9S](https://k9scli.io/topics/install/) in the path.

Scripts may work with older versions of any of the above, but tests were
performed with the pinned ones. `Test-Requirement.ps1` compares the
version in the test environment against the one locally installed; follow
the links above to install or update.

### B.3 Install the framework

Commands: [A.1](#a1-install-the-framework); the one-liners are owned
by [install/README.md](../install/README.md), also linked at
<https://yuruna.link/install>. The installer installs dependencies,
clones the framework, and seeds `test/test.config.yml` from its
template when the file is absent. First-time Hyper-V enablement is
what triggers RESTART REQUIRED — reboot before continuing.

Alternatively `git clone` the repo and run the matching
`install/<host>.{ps1,sh}` yourself; for a signature-checked install or
to pin a release (disable auto-update), see
[install/README.md](../install/README.md).

### B.4 Create the Yuruna test user

```
pwsh test/New-LocalTestUser.ps1 -Admin
```

Elevated (Administrator / sudo). Creates a dedicated local OS account
(default name `yurunatest`) that owns test operation, so the harness
never runs under your personal profile. `-Admin` makes it a local
machine administrator — required, because the steps that follow
elevate. The password is asked for interactively on the elevated side
(twice, confirmed) and is immediately usable, so an unattended host
can log in without a first-login rotation standing in the way; add
`-ForcePasswordChange` if you want a one-shot initial credential
instead. The same account name is registered under the default Yuruna
authentication extension. Cross-platform (Windows / macOS / Ubuntu);
details are owned by `test/New-LocalTestUser.ps1` comment-based help.

Sign in as this user for everything that follows, so the per-host
config, vault, and runtime state it creates belong to the test
account. The framework clone is also per-user, which is why A.2 ends
by repeating the install one-liner in the test-user session — the
heavyweight work (dependencies, Hyper-V enablement) is already done,
so that run only clones and seeds the config.

### B.5 Enable test automation

```
pwsh test/Enable-TestAutomation.ps1
```

Explicit opt-in that turns this machine into a test host: display
sleep, screen saver, screen lock, display scaling (Windows), TCC
grants (macOS). Elevated (Administrator / sudo); idempotent; supports
`-WhatIf`. On Windows, sign out and back in if it reports display-scaling
changes — OCR needs 100% scaling. Details are owned by
`host/<platform>/Enable-TestAutomation.ps1`.

### B.6 Configure and validate

Edit `test/test.config.yml` (created from
`test/test.config.yml.template`; parameter reference:
[test-config.md](test-config.md)). Minimum for a first run:
`repositories.projectUrl` (and `GH_TOKEN` if private), `guestSequence`.
Then validate:

```
pwsh test/Test-Config.ps1
```

Checks the config and the `test/extension/*` configs, probes GitHub and
Resend reachability, and fires a smoke-test notification (`-SkipSend`
to validate only). Fix every FAIL before moving on — this takes seconds
and the next step takes many minutes.

### B.7 Local shares for pool and stash storage

Durable storage ([pool-storage.md](pool-storage.md),
[stash-guide.md](stash-guide.md)) is backed by two SMB3 shares. On a
single machine both live here, and **`test/New-LocalLabStorage.ps1`
sets up the whole tier in one idempotent, `-WhatIf`-able command**;
commands: [A.5](#a5-create-pool-and-stash-storage). It calls `New-Lab`
for the folders, the lab vault, and the intent repository, then does
what `New-Lab` deliberately leaves alone:

- **One local account per tier** — `yuruna-pool` and `yuruna-stash`,
  each scoped to its own share and to nothing else on the machine: not
  an administrator, no interactive shell, hidden from the macOS login
  window, and on Ubuntu the OS password stays locked (the SMB
  credential lives in Samba's own passdb, so the account cannot be
  logged into at all).
- **An SMB server** — started on Windows, File Sharing enabled on
  macOS, `samba` + `cifs-utils` installed and configured on Ubuntu.
- **One share per tier**, granting only that tier's account, so a
  leaked pool credential cannot reach the stash share.
- **The vault** — each password mapped to a non-empty `vaultKey` and
  stored, which is what keeps `Get-Password` off the auto-generate path
  where a random password the share never had would be minted.
- **The mount and the config** — both shares mounted, and the six
  `networkStorage.*` keys written. `-EnableReplication` also sets
  `pool.networkReplicate`.

The shares are local but are consumed **as if they were remote**: each
tier gets a hosts-file alias (`ypool-nas`, `ystash-nas`) resolving to
the loopback address, and the mount runs over SMB through that name
via the same `Connect-YurunaPoolStorage` the unattended cycle uses. A
single-machine lab therefore exercises the same replication, gating,
and mount code as a lab with a NAS, and repointing it at real hardware
later changes what the alias resolves to and nothing else. On Windows
the two names are also registered as NTLM loopback exemptions
(`BackConnectionHostNames`) and `EnableLinkedConnections` is set —
without the first the machine refuses its own SMB connection, without
the second the mapped drives exist only for elevated processes; both
apply at the next restart or sign-in.

**More labs on the same machine.** Run `New-Lab` on its own; the
storage step does not need repeating. The share accounts are
**machine-wide** — one `yuruna-pool` OS account serves every lab whose
storage lives here — so `New-Lab` **reuses** what is already present
rather than minting a second set:

- `-Root` may be omitted. The storage root is read back from the lab
  vault of a lab already on this machine, so a second lab cannot land
  its folders somewhere else through a typo.
- Each credential already in the host vault is **reused**, not
  regenerated. A fresh random password would be written into the new
  lab vault while the OS account, the SMB server, and the lab's other
  machines all still held the old one, and every mount driven from that
  vault would fail against a share that never had it. `New-Lab` reports
  which credentials it reused. The lookup is read-only, and `-Force`
  (which rewrites the lab vault file) still reuses rather than rotates
  — rotating a share password has to reach the OS account and the share
  too, so it stays a deliberate, separate act.

The storage folders keep the operator as their owner; the share account
is added alongside (an inherited ACE on Windows and macOS, group
ownership plus setgid on Linux). That is what lets `New-Lab` create the
next lab's intent repository inside the pool folder — and it avoids
git's "detected dubious ownership" refusal, which chowning the folder
to the share account would trigger on every intent repository already
in it.

**It is for local storage only.** For a NAS or a separate file server,
the accounts and permissions have to be created **on that device** —
nothing here can reach them. Use `test/New-Lab.ps1` for the folders and
the lab vault, share them there, then fill `networkStorage.*` in
`test.config.yml` and store the share passwords in the host vault. The
lab vault holds the generated values so they can be copied between
machines; the host vault is what the harness reads
([Setting the SMB passwords in the vault](test-config.md#setting-the-smb-passwords-in-the-vault)).
Set `pool.networkReplicate: true` if this host should archive cycles to
the share — see [test-config.md](test-config.md).

### B.8 Start the caching-proxy service + dashboards

```
pwsh test/Start-CachingProxyServiceVM.ps1
```

Builds the `yuruna-caching-proxy-service` VM and exposes ports 80 (CA cert),
3128/3129 (Squid), 3000 (Grafana), 9302 (metrics). Elevated on Windows;
macOS needs `sudo -E`. Set `vmStart.cachingProxyIp` in
`test.config.yml` to the proxy's IP so cycles find it. The cache VM
survives framework reinstalls. Details: [caching.md](caching.md#caching-proxy-service--test-harness-operator-reference).

### B.9 Start the stash service

```
pwsh test/Start-StashServiceVM.ps1
```

Brings up the `yuruna-stash-service` VM — the shared drop box for files
and snippets (web UI + scp). Elevated on Windows. It mounts the
`yuruna.stash` share from
[B.7](#b7-local-shares-for-pool-and-stash-storage), so set that up
first. No login; trusted networks only. User guide:
[stash-guide.md](stash-guide.md).

### B.10 Run one test cycle

```
pwsh test/Invoke-TestProject.ps1
```

One-shot cycle: wipes `project/`, re-clones `repositories.projectUrl`,
runs a single cycle exactly as the runner would, and exits. Debug here
until green — one cycle with no loop around it is the cheapest place.

### B.11 Run continuous cycles

```
pwsh test/Invoke-TestRunner.ps1
```

The resilient outer loop: pulls the framework, runs a cycle in a fresh
inner process, repeats; on failure it pauses until new commits land or
a timeout passes ([test-runner.md](test-runner.md)). It auto-starts the
status dashboard at `http://<host>:8080/` — no separate
`Start-StatusService.ps1` step needed.

---

## VM administrator accounts

Each service VM is seeded with its own administrator, and each password
lives under its own vault key:

| VM | Administrator |
| -- | ------------- |
| `yuruna-caching-proxy-service` | `caching-proxy-service-admin` |
| `yuruna-pool-control-service` | `pool-control-service-admin` |
| `yuruna-stash-service` | `stash-admin` |

(`yuruna-pool-control-service` appears when a lab builds the pool-control-service VM —
[lab-operator.md](lab-operator.md).) One account for all three would
mean one vault entry: building any VM would overwrite the password the
other two were provisioned with, and their console logins would stop
working with no visible cause.

A VM whose seed named a different administrator keeps that account and
that vault entry until it is rebuilt — the names above apply from the
next build of each VM. `Move-CachingProxyService.ps1` talks to two cache VMs at
once, so pass `-OldUser` when the source VM's account differs from the
`caching-proxy-service-admin` default. Remove a superseded vault entry only after
every VM provisioned with it has been rebuilt.

`users.yml.template` declares all three. An existing
`status/extension/authentication/users.yml` is not re-bootstrapped from
the template (that happens only when the file is absent), so hosts running
`strict: true` need the three entries added by hand — see
[test-config.md](test-config.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.29

Back to [Yuruna](../README.md)
