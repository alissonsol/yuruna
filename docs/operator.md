# Yuruna operator guide

Bring-up runbook for a single Yuruna test machine: OS baseline to a
passing test cycle, plus the two service VMs a standalone machine
benefits from (caching-proxy, stash).

[Section A: Quickstart](#section-a-quickstart) is the complete command
sequence — run it top to bottom, or let
[A.0](#a0-shortcut-the-standalone-setup-script) run its middle
(A.3–A.7). [Section B: Deep dive](#section-b-deep-dive) explains each
step; read it when a step needs judgment or fails.

For a lab — several machines sharing one caching-proxy service,
NAS-backed storage, and pool-control service — complete A.1–A.2 on
each machine, then continue with the
[Lab operator guide](lab-operator.md).

---

## Section A: Quickstart

Start from a freshly installed Windows 11 Pro/Enterprise/Education (or
Windows Server), macOS 26+, or Ubuntu 26+ host: 32 GB RAM, 512 GB free
disk, 16+ physical cores, virtualization enabled in firmware, OS
activated and updated, network access to github.com
([B.1](#b1-operating-system-baseline-assumed)–[B.2](#b2-preflight-dependencies)).
"Elevated" means an Administrator PowerShell on Windows, `sudo` on
macOS / Ubuntu.

### A.0 Shortcut: the standalone setup script

**Do [A.1](#a1-install-the-framework) and [A.2](#a2-create-the-test-user)
first** — `setup.ps1` installs nothing, clones nothing, and does not
create the test user. Then, signed in as the test account, from the
framework folder:

```
pwsh install/setup.ps1
```

It asks what it cannot infer (standalone or lab, host settings, where
storage lives), then runs
[A.3](#a3-enable-test-automation)–[A.7](#a7-start-the-stash-service) in
order, ending on the `Test-Config` gate. On Windows it relaunches
itself elevated once. It runs no cycles —
[A.8](#a8-run-one-test-cycle)–[A.9](#a9-run-continuous-cycles) are
still yours. Re-running is safe, **except that every run rebuilds the
service VMs** (~15 minutes for the caching-proxy). Parameters,
`-WhatIf`, unattended runs, exact coverage, and failure behavior:
[B.0](#b0-the-guided-setup-script).

The steps below are the by-hand path — read them when a step needs
judgment, fails under `setup.ps1`, or you are repairing a host.

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
one-liner in that session — the clone is per-user, and the second run
is quick.

> **Lab?** Switch to the [Lab operator guide](lab-operator.md) now —
> it picks up after this step.

### A.3 Enable test automation

Elevated ([B.5](#b5-enable-test-automation)):

```
pwsh test/Enable-TestAutomation.ps1
```

On Windows, sign out and back in if it reports display-scaling
changes.

*Run for you by [A.0](#a0-shortcut-the-standalone-setup-script),
unless this machine only hosts services.*

### A.4 Configure and validate

Edit `test/test.config.yml` — at minimum `repositories.projectUrl`
(and `GH_TOKEN` if private) and `guestSequence` — then validate
([B.6](#b6-configure-and-validate)):

```
pwsh test/Test-Config.ps1
```

Fix every FAIL before moving on.

*[A.0](#a0-shortcut-the-standalone-setup-script) creates the file and
runs this validation, but the edits are still yours — it never touches
`guestSequence` or `GH_TOKEN`.*

### A.5 Create pool and stash storage

**Storage on this machine (no NAS)** — elevated, one idempotent
command creates the folders, accounts, shares, mounts, and config
([B.7](#b7-local-shares-for-pool-and-stash-storage)):

```
pwsh test/New-LocalLabStorage.ps1
```

It asks only where storage should live (suggesting a per-OS default),
writes `networkStorage.*` and both vault entries, and calls `New-Lab`
for you. Add `-EnableReplication` to archive finished cycles to the
pool share. A later lab on the same machine needs only
`pwsh test/New-Lab.ps1 -Name <lab-name>` — it reuses the folders and
accounts already here.

*[A.0](#a0-shortcut-the-standalone-setup-script) runs this when you
answer `local`. `nas` only mounts what `networkStorage.*` already
names; `none` skips shared storage and, with it, the stash service.*

**Storage on a NAS or a separate file server** — this machine cannot
create accounts there. Create the folders and the lab vault here, then
grant the share permissions on the device itself:

```
pwsh test/New-Lab.ps1 -Name <lab-name> -Root <storage-root>
```

`<lab-name>` is lowercase (letters, digits, hyphens); `<storage-root>`
is e.g. `D:\work` or `/srv/yuruna`. Share the two folders it created —
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

Then fill `networkStorage.*` in `test.config.yml` and store both share
passwords in the host vault
([Setting the SMB passwords in the vault](test-config.md#setting-the-smb-passwords-in-the-vault)).

### A.6 Start the caching-proxy service

Elevated on Windows, unelevated on macOS
([B.8](#b8-start-the-caching-proxy-service--dashboards)):

```
pwsh test/Start-CachingProxyServiceVM.ps1
```

Set `vmStart.cachingProxyIp` in `test.config.yml` to the proxy VM's
IP, then re-run `pwsh test/Test-Config.ps1`.

*[A.0](#a0-shortcut-the-standalone-setup-script) does all of that,
including writing the IP.*

### A.7 Start the stash service

Elevated on Windows ([B.9](#b9-start-the-stash-service)):

```
pwsh test/Start-StashServiceVM.ps1
```

*Run for you by [A.0](#a0-shortcut-the-standalone-setup-script),
unless storage was skipped.*

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
before the caching-proxy-service VM build). Every step below names its
script and links the reference doc that owns the details.

### B.0 The guided setup script

Reference for [A.0](#a0-shortcut-the-standalone-setup-script).
`install/setup.ps1` runs *after* the OS bootstrapper
(`install/windows.hyper-v.ps1`, `install/macos.utm.sh`,
`install/ubuntu.kvm.sh`) has put the dependencies and the clone in
place. Its preflight fails the run if `powershell-yaml` is missing and
tells you to run the bootstrapper. It needs pwsh 7.

**What it covers, step by step:**

| Quickstart step | Does `setup.ps1` do it? |
| --------------- | ----------------------- |
| [A.1](#a1-install-the-framework) install the framework | No — bootstrapper, by hand, first |
| [A.2](#a2-create-the-test-user) create the test user | No — `New-LocalTestUser.ps1`, by hand, first |
| [A.3](#a3-enable-test-automation) enable test automation | Yes — runs `Enable-TestAutomation -SkipPoolStorage`, unless `runTests: false` |
| [A.4](#a4-configure-and-validate) configure and validate | Partly — creates or refreshes `test/test.config.yml` from the template and ends on the `Test-Config` gate; the edits in between are still yours |
| [A.5](#a5-create-pool-and-stash-storage) pool and stash storage | Yes for `kind: local` — runs `New-LocalLabStorage`. For `kind: nas` it only **mounts** what `networkStorage.*` already names |
| [A.6](#a6-start-the-caching-proxy-service) caching-proxy service | Yes — stops and removes any existing one first, builds the VM, waits up to 15 minutes for the pool-aggregator service, then writes `vmStart.cachingProxyIp` |
| [A.7](#a7-start-the-stash-service) stash service | Yes — same stop-then-build — unless storage was skipped |
| [A.8](#a8-run-one-test-cycle) one test cycle | No |
| [A.9](#a9-run-continuous-cycles) continuous cycles | No — the closing message points you at `pwsh test/Invoke-TestRunner.ps1` |

It also creates the image, VM, log and runtime folders. `setup.ps1`
*itself* edits exactly two keys in `test.config.yml`, by
comment-preserving line replacement: `projectUrl` (when you supply one)
and `vmStart.cachingProxyIp`. The scripts it runs write more —
answering `local` runs `New-LocalLabStorage.ps1`, which writes the six
`networkStorage.*` keys and both vault entries
([A.5](#a5-create-pool-and-stash-storage)). Nothing touches
`guestSequence` or `GH_TOKEN`.

#### Re-running, and the service-VM exception

Every step runs in a child `pwsh`, and a step that can tell it is
already done — config file present, pool storage mounted,
`cachingProxyIp` matching — is skipped, so re-running is safe.

**The service VMs are the exception: every run rebuilds them.** Each
start is preceded by its own `Stop-…ServiceVM.ps1`. That is what lets
a re-run *apply* a change — left alone, a healthy proxy is adopted in
seconds and keeps the configuration you re-ran to replace — and what
keeps a start from failing over a registered VM whose files are gone.
Budget roughly 15 minutes for the proxy. A run only removes a service
it will rebuild, so a standalone re-run leaves a former lab's
pool-control service running.

#### What ends a run

Five failures end the run: preflight, the config file, the
caching-proxy service, the aggregator wait, and an unmountable NAS
when `storage.onFailure` is `stop` (the default; interactively it
offers local shares instead).

Anything else that fails is warned about, recorded in the closing
Failed list, and the run continues. **A non-empty Failed list exits
non-zero** — including a failed `Test-Config` gate — so the exit code
never calls a broken host ready. Fix what the list names and re-run.

#### Parameters

The script declares `-AnswerFile`, `-logLevel` and `-LogPath`;
`-WhatIf` and `-Confirm` come from `SupportsShouldProcess`.

`-WhatIf` previews the ordered task list: nothing changes, no
elevation is needed, and the answers file is not written (the
questions are still asked).

`-logLevel` is the [shared cascade](loglevels.md) and reaches every
script the run starts, so re-run with `-logLevel Debug` when a step
failed inside a child script. The run log is always written in full;
the level only decides what also reaches the terminal. `-LogPath`
continues an existing run log (used by the Windows elevated
relaunch).

#### Unattended runs: the answer file

A run without `-AnswerFile` saves what you answered to
`install/setup.answers.standalone.yml`. Feed that back to repeat the
run without prompts:

```
pwsh install/setup.ps1 -AnswerFile install/setup.answers.standalone.yml
```

An unattended `storage.kind: local` run must include
`storage.localRoot` — the storage script would otherwise prompt for
it, so the run stops and names the key rather than blocking.

The standalone keys it reads (anything else in the file is ignored):

```yaml
setup:
  type: standalone       # standalone | lab
  runTests: true         # false = this machine only hosts services
  projectUrl: ''         # '' keeps whatever test.config.yml has;
                         # omit the key for the script's built-in default
storage:
  kind: local            # local | nas | none ('none' is standalone-only)
  localRoot: '/srv'      # kind: local -- required unattended (see above)
  networkPath: '//ypool-nas/work/yuruna.pool'   # kind: nas only; required
  networkUser: 'yuruna-pool'                    # kind: nas only
  onFailure: stop        # stop | local -- if a NAS mount fails
```

`storage.localRoot` is where the local shares are created — e.g.
`/srv` on Ubuntu, `/Users/Shared/yuruna` on macOS, `D:\Shares\yuruna`
on Windows.

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
proceeding on an under-spec'd host. Some examples also assume a
registered domain whose DNS you control. Before installing
certificates on localhost, run `mkcert -install` once (may require
elevation).

#### Required tools

The host installer ([B.3](#b3-install-the-framework)) puts most of
these in place; install them by hand when running without the
installer, or to repair a partial install. Run
`Test-Requirement.ps1` to compare present tools against the versions
used in testing
([`automation/Yuruna.Requirement.yml`](../automation/Yuruna.Requirement.yml)).

- Install [PowerShell Core](https://github.com/powershell/powershell) 7.6.4+ — the floor in [`Yuruna.Requirement.yml`](../automation/Yuruna.Requirement.yml); anything older fails `Test-Requirement.ps1`.
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

Scripts may work with older versions, but tests used the pinned ones.

### B.3 Install the framework

Commands: [A.1](#a1-install-the-framework); the one-liners are owned
by [install/README.md](../install/README.md), also at
<https://yuruna.link/install>. The installer installs dependencies,
clones the framework, and seeds `test/test.config.yml` when absent.
First-time Hyper-V enablement triggers RESTART REQUIRED — reboot
before continuing. Alternatively `git clone` and run the matching
`install/<host>.{ps1,sh}` yourself; signature-checked installs and
release pinning: [install/README.md](../install/README.md).

### B.4 Create the Yuruna test user

```
pwsh test/New-LocalTestUser.ps1 -Admin
```

Elevated (Administrator / sudo). Creates a dedicated local OS account
(default `yurunatest`) that owns test operation, so the harness never
runs under your personal profile. `-Admin` makes it a local
administrator — required, because later steps elevate. The password is
asked interactively (twice) and is immediately usable; add
`-ForcePasswordChange` for a one-shot initial credential instead. The
account is also registered under the default Yuruna authentication
extension. Cross-platform; details in `test/New-LocalTestUser.ps1`
comment-based help.

Sign in as this user for everything that follows, so the config,
vault, and runtime state belong to the test account. The clone is
per-user — that is why A.2 repeats the install one-liner in the
test-user session; the heavyweight work is already done, so that run
only clones and seeds the config.

### B.5 Enable test automation

```
pwsh test/Enable-TestAutomation.ps1
```

Explicit opt-in that turns this machine into a test host: display
sleep, screen saver, screen lock, display scaling (Windows), TCC
grants (macOS). Elevated (Administrator / sudo); idempotent; supports
`-WhatIf`. On Windows, sign out and back in if it reports display-scaling
changes — OCR needs 100% scaling. Details:
`host/<platform>/Enable-TestAutomation.ps1`. To undo it, see
[Putting the machine back](#putting-the-machine-back).

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
commands: [A.5](#a5-create-pool-and-stash-storage). It suggests a
storage root of `/srv/yuruna` (Ubuntu), `/Users/Shared/yuruna`
(macOS), or `<drive>\Shares\yuruna` (Windows, first non-system drive).
It calls `New-Lab` for the folders, the lab vault, and the intent
repository, then does what `New-Lab` deliberately leaves alone:

- **One local account per tier** — `yuruna-pool` and `yuruna-stash`,
  each scoped to its own share and nothing else: not an administrator,
  no interactive shell, hidden from the macOS login window, and on
  Ubuntu no OS password at all (the SMB credential lives in Samba's
  own passdb).
- **An SMB server** — started on Windows, File Sharing enabled on
  macOS, `samba` + `cifs-utils` installed on Ubuntu.
- **One share per tier**, granting only that tier's account, so a
  leaked pool credential cannot reach the stash share.
- **The vault** — each password stored under a non-empty `vaultKey`,
  which keeps `Get-Password` off the auto-generate path (a random
  password the share never had).
- **The mount and the config** — both shares mounted, the six
  `networkStorage.*` keys written; `-EnableReplication` also sets
  `pool.networkReplicate`.

The shares are local but consumed **as if remote**: each tier gets a
hosts-file alias (`ypool-nas`, `ystash-nas`) resolving to loopback,
and the mount runs over SMB through that name via the same
`Connect-YurunaPoolStorage` the unattended cycle uses. A
single-machine lab therefore exercises the same replication, gating,
and mount code as one with a NAS; moving to real hardware later only
changes what the alias resolves to. On Windows the two names are also
registered as NTLM loopback exemptions (`BackConnectionHostNames`) and
`EnableLinkedConnections` is set — without them the machine refuses
its own SMB connection or shows the mapped drives only to elevated
processes; both apply at the next restart or sign-in.

**More labs on the same machine.** Run `New-Lab` on its own; the share
accounts are **machine-wide**, so it **reuses** what is already
present rather than minting a second set:

- `-Root` may be omitted — the storage root is read back from an
  existing lab's vault, so a typo cannot land a second lab's folders
  elsewhere.
- Credentials already in the host vault are **reused**, not
  regenerated: a fresh password would leave the OS account, the SMB
  server, and the lab's other machines holding the old one, and every
  mount driven from the new vault would fail. `-Force` (which rewrites
  the lab vault file) still reuses rather than rotates — rotation must
  also reach the OS account and the share, so it stays a deliberate,
  separate act.

The storage folders keep the operator as owner; the share account is
added alongside (inherited ACE on Windows/macOS, group + setgid on
Linux). That lets `New-Lab` create the next lab's intent repository in
the pool folder, and avoids git's "dubious ownership" refusal that
chowning to the share account would trigger.

**It is for local storage only.** A NAS or separate file server owns
its own accounts — create them **on that device**. Use
`test/New-Lab.ps1` for the folders and lab vault, share them there,
then fill `networkStorage.*` and store the share passwords in the host
vault
([Setting the SMB passwords in the vault](test-config.md#setting-the-smb-passwords-in-the-vault)).
The lab vault holds the generated values for copying between machines;
the host vault is what the harness reads. Set
`pool.networkReplicate: true` to archive cycles to the share.

### B.8 Start the caching-proxy service + dashboards

```
pwsh test/Start-CachingProxyServiceVM.ps1
```

Builds the `yuruna-caching-proxy-service` VM and exposes ports 80 (CA cert),
3128/3129 (Squid), 3000 (Grafana), 9302 (metrics). Elevated on Windows;
unelevated on macOS. Set `vmStart.cachingProxyIp` in
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
`Start-StatusService.ps1` step.

---

## Putting the machine back

```
pwsh test/Disable-TestAutomation.ps1
```

The reverse of [B.5](#b5-enable-test-automation). It forwards whatever
you pass to `host/<platform>/Disable-TestAutomation.ps1`, which takes
`-StopServices` and `-WhatIf`. On Windows it requires an
already-elevated PowerShell (it does **not** self-elevate); macOS and
Ubuntu prime `sudo` once.

Its closing report distinguishes three things:

- **Restored.** Host settings are put back from
  `status/runtime/host.pre-automation.json`, the snapshot
  `Enable-TestAutomation` wrote before changing anything: display
  sleep, screen lock, inactivity timeout, and display/text scaling on
  Windows; `pmset`, screensaver/screen-lock, hot corners, auto-logout
  and network time on macOS; the GNOME power/session/screensaver keys,
  `timedatectl set-ntp`, and the `libvirtd`/`virtlogd` enabled state
  on Ubuntu. A knob that was *unset* before automation is removed
  where it can be, not written back as a zero. **No capture, no
  restore** — an uncaptured knob is listed under "Left as it is"
  instead. The capture file is kept so the command can be re-run;
  delete it yourself when done.
- **Removed outright.** Only what is provably the framework's own, by
  name: on Windows the status-port firewall rule and the rule
  `Yuruna: Allow ICMPv4 Echo Request`; on Ubuntu the `ufw` allow rule
  for the status port, plus `libvirt` / `kvm` group membership and the
  `libvirt-qemu` ACL on `$HOME` — those last two only when the capture
  proves `Enable-TestAutomation` added them. macOS removes nothing.
- **Only reported.** The closing `NOT reversed (deliberately)` list
  names what it will not touch, most with the command to do it
  yourself: packages and PSGallery modules, the credential vault
  (never removed automatically), everything under `~/yuruna`, and the
  `networkStorage.*` configuration with its credential and mounts.
  Windows adds Hyper-V, `vmms` and W32Time (the bootstrapper enabled
  those); macOS the TCC grants and UTM Dock assignment; Ubuntu the
  libvirt default network, guests defined here, and the pool-storage
  sudoers drop-in.

The service VMs stay up unless you pass `-StopServices` — restoring
host settings and tearing down services are different intentions.
`-WhatIf` restores nothing and still prints both lists.

It refuses to run while a test runner owns this host's runtime
directory, naming the live PID — restoring screen lock under a running
cycle would blank capture mid-run. Stop the runner first.

---

## VM administrator accounts

Each service VM is seeded with its own administrator, and each password
lives under its own vault key:

| VM | Administrator |
| -- | ------------- |
| `yuruna-caching-proxy-service` | `caching-proxy-service-admin` |
| `yuruna-pool-control-service` | `pool-control-service-admin` |
| `yuruna-stash-service` | `stash-admin` |
| `yuruna-download-agent-service` | `download-agent-service-admin` |

(`yuruna-pool-control-service` appears when a lab builds that VM —
[lab-operator.md](lab-operator.md).) One shared account would mean one
vault entry: building any VM would overwrite the password the others
were provisioned with, and their console logins would silently stop
working.

The download-agent service's board gates its mutating actions with the
rotating 6-character **Lab token** from the Yuruna hosts dashboard —
checked with the pool aggregator, never stored in the vault; nothing
to mint or rotate by hand
([download-agent.md](download-agent.md#unlocking-the-actions)). A
stale `download-agent-service-passcode` entry from an earlier build
can be deleted; nothing reads it.

A VM whose seed named a different administrator keeps it until rebuilt
— the names above apply from each VM's next build.
`Move-CachingProxyService.ps1` talks to two cache VMs at once, so pass
`-OldUser` when the source VM's account differs from the default.
Remove a superseded vault entry only after every VM provisioned with
it has been rebuilt.

`users.yml.template` declares all four. An existing `users.yml` is not
re-bootstrapped — new template entries are merged in one by one, and
only while they carry no operator meaning (no vault key, no corporate
mapping) — so a `strict: true` host picks up a new service's
administrator without hand-editing. See
[test-config.md](test-config.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.05

Back to [Yuruna](../README.md)
