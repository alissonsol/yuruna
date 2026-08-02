# Yuruna lab operator guide

Bring-up runbook for a Yuruna lab: several physically local machines
sharing one caching-proxy service, NAS-backed pool and stash storage, and a
pool-control service, grouped into pools and assigned test sets.

[Section A: Quickstart](#section-a-quickstart) is the complete command
sequence — shared services first, then machine by machine.
[Section B: Deep dive](#section-b-deep-dive) explains each step in
depth; every quickstart step links its deep-dive counterpart. The
guide ends with a worked
[two-pool split](#two-pools-running-two-different-test-sets) running a
different test set on each group of hosts.

Prerequisite: every lab machine has completed the
[operator guide](operator.md) through A.2 — OS baseline, preflight,
framework install, and the Yuruna test user (signed in as that user).
The shared services below are built once, on the most powerful
machine; every other machine only points at them.

> **Shortcut for the beacon.** [install/setup.ps1](../install/setup.ps1) runs the
> shared-services half of this quickstart as one guided command — host settings
> ([A.1](#a1-enable-test-automation-every-machine)), storage
> ([A.2](#a2-create-lab-storage)), the caching-proxy
> ([A.3](#a3-start-the-caching-proxy-service-one-per-lab)), stash
> ([A.4](#a4-start-the-stash-service)) and pool-control
> ([A.5](#a5-start-the-pool-control-service)) services, this host's own
> enrolment, the `test.config.yml` work and validation gate from
> ([A.6](#a6-bring-up-the-first-machine)), and — if you ask for it — the
> `default` pool. Two of those are conditional: host settings are skipped if you
> answer that the machine only hosts services, and the stash service is skipped
> unless storage is configured. Each of the three service VMs is stopped and
> removed before its replacement is built, so re-running the command rebuilds the
> beacon's services rather than adopting whatever survived the last run — budget
> roughly 15 minutes for the proxy. It asks only what it cannot infer:
>
> ```
> pwsh install/setup.ps1                              # choose "Lab"
> pwsh install/setup.ps1 -WhatIf                      # print the ordered task list, change nothing
> pwsh install/setup.ps1 -AnswerFile lab-answers.yml  # unattended
> ```
>
> An interactive run writes what you answered to
> `install/setup.answers.lab.yml` — feed that back with `-AnswerFile` to build the
> next beacon the same way. The lab keys are `lab.name` and
> `lab.createDefaultPool` on top of the standalone set
> ([operator.md A.0](operator.md#a0-shortcut-the-standalone-setup-script) lists
> them all); an unattended `storage.kind: local` run also needs
> `storage.localRoot`, or it stops and names the key rather than hanging on the
> storage script's own prompt.
>
> It orchestrates exactly the scripts below, so the two paths stay
> interchangeable: read on to understand what it does, or to do any step by hand.
> It configures **only the machine it runs on** — nothing in it reaches a second
> machine, so joining machines still run `Set-LabToken.ps1` and the sync
> themselves ([A.7](#a7-enroll-each-additional-machine)). Four things it
> deliberately leaves to you: it installs and clones nothing (run the OS
> bootstrapper first); on a NAS it mounts what `networkStorage.*` already names
> instead of creating it ([A.2](#a2-create-lab-storage)); it does not turn on the
> auto-enrolment sweep ([B.5](#b5-start-the-pool-control-service)); and it runs no
> cycles, so [A.6](#a6-bring-up-the-first-machine) still ends with you.
> To put a machine back afterwards, see
> [test/Disable-TestAutomation.ps1](../test/Disable-TestAutomation.ps1)
> ([B.1](#b1-enable-test-automation-every-machine)).

---

## Section A: Quickstart

"Elevated" means an Administrator PowerShell on Windows and `sudo` on
Ubuntu. Run commands from the `yuruna` folder.
`install/setup.ps1` is the one exception on Windows: start it from any
PowerShell and it relaunches itself elevated once, up front, because the
host settings, the firewall rules and every Hyper-V VM operation below
need it (`-WhatIf` changes nothing, so it does not elevate for a
preview). On macOS and Ubuntu it stays unelevated like everything else
here, and the per-host scripts ask for what they need.

**On macOS, do not put `sudo` in front of these scripts.** They are
built to run unelevated and to request `sudo` for the individual
operations that need it. Running a whole script as root breaks it in
two ways: root has no GUI login session, so registering the VM bundle
with UTM, `utmctl`, and the dialog watchdog all fail — and every file
the run writes (the VM bundle, the disk image, the harness SSH key,
the vault) lands root-owned, where UTM, running as you, cannot open
it. If you have already done this, recover with
`sudo chown -R "$USER" ~/yuruna` and re-run unelevated; the scripts
are idempotent.

### A.1 Enable test automation (every machine)

Elevated, on each lab machine
([B.1](#b1-enable-test-automation-every-machine)):

```
pwsh test/Enable-TestAutomation.ps1
```

On Windows, sign out and back in if it reports display-scaling
changes.

**Guided path** — on the beacon, `install/setup.ps1` runs this step for
you as `Enable-TestAutomation -SkipPoolStorage`, so it does not duplicate
[A.2](#a2-create-lab-storage); answer that the machine only hosts
services and it skips host settings altogether and says so in its
closing report. Every other lab machine runs the command above by hand.

### A.2 Create lab storage

Run where the storage lives — on a machine that mounts the NAS path,
or on the shared-services machine if there is no NAS
([B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas)).

**Storage on this machine (no NAS)** — one command does all of it
(folders, accounts, shares, mounts, config). Elevated on Windows;
on macOS and Ubuntu run it **without** `sudo` — it asks for your
password once and elevates the steps that need it:

```
pwsh test/New-LocalLabStorage.ps1
```

It asks only where storage should live, suggesting `/srv/yuruna`
(Ubuntu), `/Users/Shared/yuruna` (macOS), or `<drive>\Shares\yuruna`
(Windows, first non-system drive). It calls `New-Lab` for you, so the
lab is created too. Skip to the last paragraph of this step afterwards
— it writes `networkStorage.*` and the vault entries on this machine
itself.

To add **another lab** to that machine later, `New-Lab` on its own is
enough — it finds the folders, the storage root, and the share
accounts already here and reuses them, so `-Root` is not needed and no
second set of passwords is minted:

```
pwsh test/New-Lab.ps1 -Name <lab-name>
```

**Storage on a NAS or a separate file server** — create the folders
and the lab vault here, then create the accounts and grant the share
permissions **on that device**, with its own administration tool:

```
pwsh test/New-Lab.ps1 -Name <lab-name> -Root <storage-root>
```

`<lab-name>` is lowercase (letters, digits, hyphens — the pool-id
charset); `<storage-root>` is e.g. `D:\work` on Windows or `/srv` on
Linux. Share the two folders it created — one dedicated account per
share, using the passwords `New-Lab` just generated into the lab
vault:

```powershell
# On the machine hosting the shares (elevated, Windows example)
New-LocalUser yuruna-pool  -Password (Read-Host -AsSecureString 'yuruna-pool password')
New-LocalUser yuruna-stash -Password (Read-Host -AsSecureString 'yuruna-stash password')
New-SmbShare -Name yuruna.pool  -Path D:\work\yuruna.pool  -FullAccess yuruna-pool
New-SmbShare -Name yuruna.stash -Path D:\work\yuruna.stash -FullAccess yuruna-stash
icacls D:\work\yuruna.pool  /grant 'yuruna-pool:(OI)(CI)M'
icacls D:\work\yuruna.stash /grant 'yuruna-stash:(OI)(CI)M'
```

Then, on each machine you configure by hand — the shared-services
machine now ([A.4](#a4-start-the-stash-service)–[A.5](#a5-start-the-pool-control-service)
require it) and the first cycle machine in
[A.6](#a6-bring-up-the-first-machine) — fill `networkStorage.*` in
`test/test.config.yml` and store both share passwords in the host
vault ([Setting the SMB passwords in the vault](test-config.md#setting-the-smb-passwords-in-the-vault)).
Machines enrolled in [A.7](#a7-enroll-each-additional-machine)
receive the config and credentials through the sync.

**Guided path** — `install/setup.ps1` does this whole step on the beacon
when you answer that storage lives on this machine: it runs
`New-LocalLabStorage.ps1`, exactly as above. For a NAS it only **mounts**
the share, using the `networkStorage.*` values already in
`test/test.config.yml` — it creates nothing *on the NAS*: no folders, no
accounts, no shares, no vault entries. (Locally it does create the mount
point, and on Ubuntu it installs the pool-storage sudoers drop-in first,
because the mount itself runs `sudo -n` and fails without it.) So on a
NAS, do the commands above first and run it afterwards. An empty
`networkStorage.*` section fails the step naming the `networkPath`,
`networkUser` and `localPath` it expected. A failed mount — for that
reason or any other — asks whether to stop and fix the NAS or fall back
to local shares on this machine; under `-AnswerFile` there is nobody to
ask, so `storage.onFailure` decides, and its default `stop` ends the
run. A lab may not decline shared storage: the stash
service and the pool intent store both need it.

### A.3 Start the caching-proxy service (one per lab)

On the shared-services machine; elevated on Windows, unelevated on
macOS ([B.3](#b3-start-the-caching-proxy-service--dashboards)):

```
pwsh test/Start-CachingProxyServiceVM.ps1
```

Note the proxy VM's IP the script prints when it finishes — every
machine's `vmStart.cachingProxyIp`
([A.6](#a6-bring-up-the-first-machine)) points at it.

The Grafana "Yuruna hosts" dashboard's "Lab token" stat tile shows
the 6-character code later steps redeem to enroll hosts. It rotates
about once a minute — read the current value each time you run
`Set-LabToken.ps1` rather than writing it down.

**Guided path** — `install/setup.ps1` starts this VM, waits up to 15
minutes for the pool aggregator behind it to answer, and writes the
proxy's IP into **this** machine's `vmStart.cachingProxyIp` for you.
Every other machine gets that value by hand
([A.6](#a6-bring-up-the-first-machine)) or through the sync
([A.7](#a7-enroll-each-additional-machine)).

### A.4 Start the stash service

Elevated on Windows, unelevated on macOS; needs the A.2 configuration
on this machine ([B.4](#b4-start-the-stash-service)):

```
pwsh test/Start-StashServiceVM.ps1
```

**Guided path** — `install/setup.ps1` starts it, but only once storage is
configured; if [A.2](#a2-create-lab-storage) did not complete it lists
the stash service as skipped rather than starting a VM that exits 1
without it.

### A.5 Start the pool control service

Elevated on Windows, unelevated on macOS
([B.5](#b5-start-the-pool-control-service)):

```
pwsh test/Start-PoolControlServiceVM.ps1
pwsh test/Set-LabToken.ps1 -LabToken <code>
```

`<code>` is the current "Lab token" tile value
([A.3](#a3-start-the-caching-proxy-service-one-per-lab)); `Set-LabToken.ps1`
enrolls this host in the lab.

**Guided path** — `install/setup.ps1` does both lines. It reads the
rotating token itself from the pool-aggregator service's open metrics
endpoint on the proxy (`<proxy-ip>:9400/metrics`) — no tile to copy
— and runs `Set-LabToken.ps1 <code> -CachingProxyService <proxy-ip>
-BounceStatusService -NonInteractive`, printing a copy-pasteable command
if it could not read a token. It can also create the `default` pool and
validate the intent store, which this guide otherwise leaves to
[pool-admin.md](pool-admin.md). It does not turn on auto-enrolment
([B.5](#b5-start-the-pool-control-service)).

### A.6 Bring up the first machine

On the machine that will run cycles first: edit
`test/test.config.yml` — at minimum `repositories.projectUrl` (and
`GH_TOKEN` if private) and `guestSequence`, plus the
`networkStorage.*` values and share passwords from
[A.2](#a2-create-lab-storage) and the `vmStart.cachingProxyIp` from
[A.3](#a3-start-the-caching-proxy-service-one-per-lab) — then enroll,
validate, and run ([B.6](#b6-configure-the-first-machine)):

```
pwsh test/Set-LabToken.ps1 -LabToken <code>
pwsh test/Test-Config.ps1
pwsh test/Invoke-TestProject.ps1
pwsh test/Invoke-TestRunner.ps1
```

Skip `Set-LabToken.ps1` if this is the shared-services machine —
[A.5](#a5-start-the-pool-control-service) already enrolled it. Fix
every `Test-Config` FAIL; debug `Invoke-TestProject` until green; then
leave the runner cycling — it serves the status dashboard at
`http://<host>:8080/`.

**Guided path** — on the beacon, `install/setup.ps1` has already created
`test/test.config.yml` from the template, set `repositories.projectUrl`
if you gave it one, set `vmStart.cachingProxyIp`, and run this same
`Test-Config` gate. Those are the two keys it edits *directly*; the
enrolment in [A.5](#a5-start-the-pool-control-service) also seeds
`pool.enabled` and `pool.intentGitUrl` through `Set-LabToken.ps1`, and
answering `local` to the storage question writes the six
`networkStorage.*` keys through `New-LocalLabStorage.ps1`. `guestSequence`
and `GH_TOKEN` are never touched. It
it runs no cycles, so `Invoke-TestProject.ps1` and `Invoke-TestRunner.ps1`
above are the commands left to do.

### A.7 Enroll each additional machine

On each remaining machine ([B.7](#b7-each-additional-machine)):

```
pwsh test/Set-LabToken.ps1 -LabToken <code>
pwsh test/Sync-HostConfiguration.ps1 -ReferenceHost <ip-or-name>
pwsh test/Invoke-TestProject.ps1
```

The sync copies the reference host's config converted for this host
and finishes by running `Test-Config.ps1`. Once `Invoke-TestProject` is
green, open the pool-control service UI at `http://<pool-control-service-vm-ip>/`
(also linked as "Pool-control service" in the Grafana "Yuruna hosts"
dashboard's Extension hosts table), add the host to a pool, assign a
test set, then:

```
pwsh test/Invoke-TestRunner.ps1
```

**Guided path** — none. `install/setup.ps1` sets up the beacon and only
the beacon; it never touches a second machine, so every command in this
step is by hand. It also leaves the auto-enrolment sweep off
([B.5](#b5-start-the-pool-control-service)): a machine enrolled here
belongs to no pool until you put it in one.

---

## Section B: Deep dive

### B.1 Enable test automation (every machine)

```
pwsh test/Enable-TestAutomation.ps1
```

Run on each lab machine. Explicit opt-in that turns it into a test
host: display sleep, screen saver, screen lock, display scaling
(Windows), TCC grants (macOS). Administrator on Windows; on macOS and
Ubuntu run it unelevated — it self-elevates the steps that need root,
and running the whole script under `sudo` installs its PowerShell
modules into root's profile instead of yours. Idempotent; supports
`-WhatIf`. On Windows, sign out and back in if it
reports display-scaling changes — OCR needs 100% scaling. Details are
owned by `host/<platform>/Enable-TestAutomation.ps1`.

**Putting a machine back** — `pwsh test/Disable-TestAutomation.ps1` is
the inverse, and it restores from the record `Enable-TestAutomation`
wrote *before* it changed anything (`status/runtime/host.pre-automation.json`).
A knob that record does not cover is left alone and reported rather than
guessed at, so with no capture at all it changes very little — on macOS,
nothing — and names everything it left. It removes outright only
what is provably Yuruna's by name (the status-port firewall rule and the
ICMPv4 echo rule on Windows, the ufw status-port rule on Ubuntu; macOS
removes nothing). Administrator on Windows — it refuses rather than
self-elevating; unelevated on macOS and Ubuntu, which prime `sudo` once.
It supports `-WhatIf`. `-StopServices` also stops the caching-proxy,
stash and pool-control VMs: on the shared-services machine that takes the
whole lab down with it, which is why it is off by default. The run ends
listing what it deliberately did not reverse — packages and PSGallery
modules, everything under `~/yuruna`, the `networkStorage.*`
configuration with its mounts, the credential vault (never removed
automatically) — most with the command to do it yourself, and it keeps
the capture file so it can be re-run. Full breakdown:
[operator.md](operator.md#putting-the-machine-back).

Two things matter more on a lab machine than on a standalone one. It
**refuses to run while a test runner owns the runtime directory**, naming
the live PID — which is the normal state of a cycling lab host, so stop
the runner first. And it knows nothing about lab **enrolment**: the
`pool.enabled` / `pool.intentGitUrl` keys and the lab auth token that
[A.5](#a5-start-the-pool-control-service) wrote stay exactly where they
are. To take a host out of a pool, use the pool admin commands
([pool-admin.md](pool-admin.md)); to drop it from the dashboard, see
`test/Remove-PoolHost.ps1`.

### B.2 Lab storage: pool and stash shares (ideally on a NAS)

Durable network tiers ([pool-storage.md](pool-storage.md),
[stash-guide.md](stash-guide.md)) are backed by two SMB3 shares —
`yuruna.pool` and `yuruna.stash` — on a NAS if you have one, otherwise
on the machine hosting the shared services. `test/New-Lab.ps1` creates
the folders, the lab vault, and the seeded pool-intent repository in
one idempotent step, run where the storage lives; commands:
[A.2](#a2-create-lab-storage).

It generates one credential per share account into the lab vault —
plain YAML protected by filesystem permissions, so it stays **copyable
to the other lab machines** (DPAPI-bound files would not decrypt off
the machine that wrote them; see `test/schemas/lab.vault.schema.yml`).
Sharing the folders is left to the operator — one dedicated account per
share, as in the A.2 example. (NAS / Ubuntu / macOS: any Samba/SMB
server with the same two share names and accounts.) Then, on each
machine, fill `networkStorage.*` in `test.config.yml`, put the share
passwords in the vault, and set `pool.networkReplicate: true` on hosts
that should archive cycles to the NAS — see
[test-config.md](test-config.md).

**When the storage lives on the machine you are standing at,
`test/New-LocalLabStorage.ps1` does the whole step instead.** It calls
`New-Lab` for the folders, the lab vault, and the intent repository,
then does what `New-Lab` deliberately leaves alone: creates one local
storage account per tier (not an administrator, no interactive shell,
and on Ubuntu no OS password at all), stands up the SMB server
(starting it on Windows, enabling File Sharing on macOS, installing
Samba + cifs-utils on Ubuntu), publishes one share per tier scoped to
its own account, stores both passwords under a mapped `vaultKey`,
mounts the shares, and writes the six `networkStorage.*` keys. It is
idempotent, supports `-WhatIf`, and adds `-EnableReplication` for
`pool.networkReplicate`.

The shares are local but are consumed **as if they were remote**: each
tier gets a hosts-file alias (`ypool-nas`, `ystash-nas`) pointing at
the loopback address, and the mount goes over SMB through that name,
using the same code path the unattended cycle uses. So a one-machine
lab exercises the same replication and gating code as a lab with a
NAS, and moving to real hardware later is a change of what the alias
resolves to and nothing else.

That alias is **host-local on purpose**, and the service VMs do not
use it. The stash, pool-control and caching-proxy VMs mount these same
shares from inside a guest, where `127.0.0.1` is the guest's own
loopback and the mount fails with `cifs_mount ... -111`. So the VM
seeds do not inherit the host's answer: each build bakes the address
*this host* is reachable at *from the network that VM is attached to* —
its LAN address for a bridged VM, the hypervisor's gateway for a
NAT'd one. Nothing to configure, but two consequences worth knowing:
the address is fixed when the VM is **built**, so a host that changes
address (or moves between Wi-Fi and Ethernet) needs the service VMs
rebuilt; and on Windows and Ubuntu hosts, inbound TCP 445 must be
reachable from the VM's network for a bridged guest to mount at all. On Windows it also registers the two
names as NTLM loopback exemptions (`BackConnectionHostNames`) and sets
`EnableLinkedConnections`, without which the machine refuses its own
SMB connection and the mapped drives are invisible outside the
elevated session; both apply at the next restart or sign-in.

**Adding more labs to that machine** takes only `New-Lab` — the
storage step is not repeated. The share accounts are machine-wide (one
`yuruna-pool` OS account serves every lab whose storage lives here), so
`New-Lab` reuses what is already present: `-Root` may be omitted (the
root is read back from a lab already on this machine), and a credential
already in the host vault is reused rather than regenerated. Minting a
second password would leave the new lab vault disagreeing with the OS
account, the SMB server, and every other machine in the lab, and each
mount driven from it would fail against a share that never had that
password. `New-Lab` reports which credentials it reused; the lookup is
read-only and `-Force` still reuses rather than rotates. See
[operator.md](operator.md#b7-local-shares-for-pool-and-stash-storage).

**It is for local storage only.** A NAS or a separate file server owns
its own accounts and its own access control, and nothing on this
machine can create them — do that on the device, then point
`networkStorage.*` at it as above. The script says so and asks for
confirmation before it changes anything.

### B.3 Start the caching-proxy service + dashboards

```
pwsh test/Start-CachingProxyServiceVM.ps1
```

One proxy serves the whole lab. Builds the `yuruna-caching-proxy-service` VM
and exposes ports 80 (CA cert), 3128/3129 (Squid), 3000 (Grafana),
9302 (metrics). Elevated on Windows; unelevated on macOS. On every
lab machine, set `vmStart.cachingProxyIp` in `test.config.yml` to this
proxy's IP so cycles find it. The build mints and stores a random
`lab-auth-token` in this host's vault when none exists, so the proxy
never comes up with an empty token; once the dashboards are up, the
"Yuruna hosts" Grafana dashboard shows the current 6-character lab
connection token in its "Lab token" stat tile (rotating about once a
minute) — later steps redeem that code to enroll hosts. The cache VM survives framework
reinstalls. Details: [caching.md](caching.md#caching-proxy-service--test-harness-operator-reference), including
exposing the cache to remote clients and pointing a host at a remote
cache.

### B.4 Start the stash service

```
pwsh test/Start-StashServiceVM.ps1
```

Brings up the `yuruna-stash-service` VM — the lab-wide drop box for
files and snippets (web UI + scp). Elevated on Windows, unelevated on
macOS. It mounts the `yuruna.stash` share
from [B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas), so
set that up first. No login; trusted networks only. User guide:
[stash-guide.md](stash-guide.md).

On a macOS host with a **Wi-Fi** default route this VM is built on UTM
Shared NAT rather than bridged — vmnet cannot bridge a Wi-Fi uplink,
so a bridged VM would never get a DHCP lease. It is then invisible to
the LAN on its own address, and the script forwards a host port
instead: peers reach it at `<host-lan-ip>:2222` (remapped, because the
Mac's own sshd owns 22) rather than `<vm-ip>:22`. Plugging into
Ethernet — including a USB Ethernet adapter, which vmnet bridges
fine — switches it back to bridged on the next rebuild; the script
warns when the VM's mode no longer matches the host's uplink.

### B.5 Start the pool control service

```
pwsh test/Start-PoolControlServiceVM.ps1
```

Brings up the `yuruna-pool-control-service` VM — operator UI + API for LAN pool
intent: create pools, add hosts, assign test sets. Elevated on
Windows, unelevated on macOS. On a macOS host with a Wi-Fi default
route this VM is built on UTM Shared NAT for the reason given in
[B.4](#b4-start-the-stash-service), and the script forwards a host port
to it — peers open `http://<host-lan-ip>:8081/` rather than the VM's
own address. (8081, not 80: on a shared-services machine the
caching-proxy already owns host `:80` for its CA-cert endpoint.)
Cloud-init builds the daemon inside the guest (no host `go`
toolchain needed) and persists its audit log + status under
`poolStorageNetworkPath` — set up the shares
([B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas)) first.
The VM serves the UI on port 80 (`http://<pool-control-service-vm-ip>/`),
also linked as "Pool-control service" in the Grafana "Yuruna hosts"
dashboard's Extension hosts table.
Enroll this host with `test/Set-LabToken.ps1 -LabToken <code>` —
`<code>` is the current 6-character code on the dashboard's "Lab
token" tile ([B.3](#b3-start-the-caching-proxy-service--dashboards)); the
script fetches the shared `lab-auth-token` into the host vault.
`install/setup.ps1` starts this VM and does that enrolment for the
beacon, reading the token off the proxy itself, and can create the
`default` pool — but it leaves **auto-enrolment off**, and prints the two
steps it did not take: an `autoEnrollment` block naming a target pool in
the intent store's `pools.yml`, and running the pool-control daemon with
`--auto-enrol`. Until both are done, a host enrolled in
[B.7](#b7-each-additional-machine) joins no pool on its own.
Add `-HostSideProof` to build + run it directly on this host instead (UI
at `http://<host>:8090/`, needs `go` + `pwsh` on PATH). Details:
[the Pool control service section](pool-admin.md#pool-control-service) of
the pool admin guide.

Each service VM has its own administrator account and vault key — see
[VM administrator accounts](operator.md#vm-administrator-accounts).

### B.6 Configure the first machine

On the machine that will run cycles first (any of them):

1. **Enroll in the lab** — `pwsh test/Set-LabToken.ps1 -LabToken
   <code>` (current "Lab token" tile value); already done for the
   shared-services machine in
   [B.5](#b5-start-the-pool-control-service). Without the token the
   host still cycles standalone but never reports to the lab
   dashboards.
2. **Configure and validate** — edit `test/test.config.yml` and run
   `pwsh test/Test-Config.ps1`
   ([operator guide B.6](operator.md#b6-configure-and-validate));
   include the `networkStorage.*` values and share passwords from
   [B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas) and
   the `vmStart.cachingProxyIp` from
   [B.3](#b3-start-the-caching-proxy-service--dashboards).
3. **One local cycle** — `pwsh test/Invoke-TestProject.ps1` until green; one
   cycle with no loop around it is the cheapest place to debug.
4. **Continuous cycles** — `pwsh test/Invoke-TestRunner.ps1`; it
   auto-starts the status dashboard at `http://<host>:8080/`
   ([test-runner.md](test-runner.md)).

### B.7 Each additional machine

1. **OS baseline, preflight, install, test user** — operator guide
   through [A.2](operator.md#a2-create-the-test-user); reboot if the
   installer asks.
2. **Enable test automation** — `pwsh test/Enable-TestAutomation.ps1`
   ([B.1](#b1-enable-test-automation-every-machine)).
3. **Enroll in the lab, then sync configuration from an existing
   host:**

   ```
   pwsh test/Set-LabToken.ps1 -LabToken <code>
   pwsh test/Sync-HostConfiguration.ps1 -ReferenceHost <ip-or-name>
   ```

   `<code>` is the 6-character code on the dashboard's "Lab token"
   tile; `Set-LabToken.ps1` redeems it at the aggregator and stores
   the shared `lab-auth-token` in this host's vault. The sync then
   copies the reference host's `test.config.yml` converted for this
   host (share paths, mount points, host aliases — cross-host-type is
   the point), authenticating with this host's own stored token, and
   **finishes by running Test-Config.ps1** — so this step ends with a
   validated config. If the aggregator is unreachable, skip
   `Set-LabToken.ps1` and pass the raw token to
   `Sync-HostConfiguration.ps1` instead:
   `-SharedToken '<raw-token>' -PersistSharedToken` — the raw
   `lab-auth-token` is in the shared-services host's vault.
   No local caching-proxy service is needed: the synced
   `vmStart.cachingProxyIp` points at the shared one.

   Before overwriting anything, the sync compares the fetched config
   against **this** host's `test.config.yml.template` and stops to ask if
   the reference host is behind it — listing the retired key names it
   still uses, the current keys it lacks (which would land here silently
   defaulted), and the keys it carries that the schema has dropped. The
   fix is at the source: run `pwsh tools/Update-TestConfigNaming.ps1` and
   `pwsh test/Test-Config.ps1` on the reference host, then sync again.
   `-AllowStaleReference` accepts the drift and proceeds; under
   `-NonInteractive` a stale reference fails the run unless that switch
   is passed, so an unattended sync cannot quietly propagate a
   half-migrated config across the lab.
4. **(Recommended) one local cycle** — `pwsh test/Invoke-TestProject.ps1` to
   prove the host green standalone before the pool drives it.
5. **Join a pool and take assignments** — open the pool-control service UI at
   `http://<pool-control-service-vm-ip>/` (linked as "Pool-control service" in the
   Grafana "Yuruna hosts" dashboard's Extension hosts table), add
   this host to a pool, and assign a test set. CLI equivalent:
   `test/Add-HostToPool.ps1` + `test/Set-PoolTestSet.ps1`
   ([pool-admin.md](pool-admin.md)). Then start
   `pwsh test/Invoke-TestRunner.ps1`.

---

## Troubleshooting bring-up

Symptoms specific to this runbook. Storage-mount problems in general
are in [pool-storage.md](pool-storage.md#operating--troubleshooting).

**`New-LocalLabStorage.ps1` stops at `[5/8]` with an exit-131 error
naming .NET or `libhostfxr` (macOS).** The step re-launches itself
under `sudo` to write `/etc/hosts`, and a Homebrew PowerShell cannot
start without the `DOTNET_ROOT` its wrapper sets. Record the runtime
location once, machine-wide, then re-run — the script is idempotent
and picks up where it stopped:

```
echo "$(brew --prefix dotnet)/libexec" | sudo tee /etc/dotnet/install_location_$(uname -m)
```

Steps 1–4 (folders, vault, accounts, shares) had already run; steps
6–8 (vault keys, `test.config.yml`, mounts) had not, which is why the
accounts exist but nothing is configured. Current installs write this
file for you — this applies to hosts installed before that.

**Both SMB mounts fail at `[8/8]` with an authentication error, and
the password is definitely right (macOS).** macOS keeps a separate
credential per authentication authority and `smbd` accepts only the
SMB-NT one, which `sysadminctl` does not create. Current versions
enable it as part of step 3 and prove it at step 4. To repair an
account created earlier, per account:

```
sudo pwpolicy -u yuruna-pool -sethashtypes SMB-NT on
sudo sysadminctl -resetPasswordFor yuruna-pool -newPassword '<the lab-vault password>'
```

Enabling the hash type only affects passwords set *afterwards*, so the
re-set is required, not optional. The password is in
`test/status/extension/authentication/lab.<lab-name>.vault.yml`.

**A service VM script reports success but the VM is not running, or
blames cloud-init / the daemon build / the NAS for a VM that never
booted.** Fixed: all three scripts now assert the VM actually reached
`running` before anything downstream, and fail naming the state they
observed. If you see the old behavior, the scripts predate this.

**The pool-control VM never mounts the pool share —
`cifs_mount failed w/return code = -111`.** The guest reached an
address that refused the connection, which is what happens when the
share's server name resolves to something host-local. Distinguish it
from `mount error(13)`, which is a rejected credential (see the SMB-NT
item above). Current builds bake a guest-reachable address into the
seed; a VM built before that needs rebuilding, not reconfiguring.
Confirm from inside the guest:

```
getent hosts ypool-nas          # what the guest resolves, if anything
grep cifs /etc/fstab            # the ip= option should name the host
```

**Bundle or artifacts are root-owned and UTM will not open the VM
(macOS).** Something was run with `sudo`. See the note at the top of
[Section A](#section-a-quickstart): `sudo chown -R "$USER" ~/yuruna`,
then re-run unelevated.

---

## Two pools running two different test sets

A worked example of the common scale-out shape: one lab, two groups of
hosts, each group running a different body of tests. Names here are
placeholders — substitute your own.

Assume four hosts registered and green standalone (each has passed the
one-local-cycle check of [B.7](#b7-each-additional-machine)), the pool
NAS from [B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas),
and the pool-control-service VM from
[B.5](#b5-start-the-pool-control-service). `<intent-url>` below is the
writable pool-intent git URL; every command that mutates intent takes
it.

### 1. Define the two test-sets

A test-set is a named framework/project repo **pair**: a pooled
member overrides its own `repositories.frameworkUrl` /
`repositories.projectUrl` with it for the cycle and runs the assigned
project's own `test.runner.yml` plan. "Two different bodies of tests"
therefore means two project repos — two projects, or two branches or
forks of one. `GH_TOKEN` is never stored in pool intent; it stays
host-local.

Register both pairs in the intent store's test-set library (it backs
the pool-control service "Test sets" page; `Set-PoolTestSet.ps1` in step 4
also accepts the URLs directly):

```powershell
pwsh test/Set-PoolTestSetDefinition.ps1 -Name testset1 -FrameworkUrl <framework-url> -ProjectUrl <project-a-url> -IntentGitUrl <intent-url>
pwsh test/Set-PoolTestSetDefinition.ps1 -Name testset2 -FrameworkUrl <framework-url> -ProjectUrl <project-b-url> -IntentGitUrl <intent-url>
```

### 2. Create both pools

```powershell
pwsh test/New-Pool.ps1 -PoolId poola -DisplayName 'Pool A' -IntentGitUrl <intent-url>
pwsh test/New-Pool.ps1 -PoolId poolb -DisplayName 'Pool B' -IntentGitUrl <intent-url>
```

`-PoolId` is permanent — `New-Pool.ps1` mints a stable `poolGuid` for
it (the dashboard's "Pool ID"), so renaming later means a new pool
and forks the telemetry history.

### 3. Split the hosts between them

A host belongs to **at most one pool**, which is what makes the split
meaningful. Each `-HostId` is that host's `runtime/host.uuid`:

```powershell
pwsh test/Add-HostToPool.ps1 -PoolId poola -HostId <host-1-uuid> -IntentGitUrl <intent-url>
pwsh test/Add-HostToPool.ps1 -PoolId poola -HostId <host-2-uuid> -IntentGitUrl <intent-url>
pwsh test/Add-HostToPool.ps1 -PoolId poolb -HostId <host-3-uuid> -IntentGitUrl <intent-url>
pwsh test/Add-HostToPool.ps1 -PoolId poolb -HostId <host-4-uuid> -IntentGitUrl <intent-url>
```

### 4. Assign one test-set to each pool

```powershell
pwsh test/Set-PoolTestSet.ps1 -PoolId poola -Name testset1 -FrameworkUrl <framework-url> -ProjectUrl <project-a-url> -IntentGitUrl <intent-url>
pwsh test/Set-PoolTestSet.ps1 -PoolId poolb -Name testset2 -FrameworkUrl <framework-url> -ProjectUrl <project-b-url> -IntentGitUrl <intent-url>
```

A pool holds exactly one `testSet`; assigning replaces the previous
one. Members do not split the work: from its next cycle, every poola
member clones `<project-a-url>` and runs that project's full
`test.runner.yml` plan, reporting under the pool.

### 5. Verify before the next cycle

```powershell
pwsh test/Test-PoolIntent.ps1 -IntentGitUrl <intent-url>          # schema-validates the intent files
pwsh test/Get-PoolStatus.ps1  -PoolId poola -IntentGitUrl <intent-url>
pwsh test/Get-PoolStatus.ps1  -PoolId poolb -IntentGitUrl <intent-url>
```

`Test-PoolIntent.ps1` validates `pools.yml` (and
`guests.compatibility.yml` when present) against the schemas and
enforces that a host belongs to at most one pool; `Get-PoolStatus.ps1`
shows members, `desiredState`, and the assigned test-set. Neither
probes the repo URLs — a typo there first surfaces when a member's
next cycle tries to clone. Nothing is deployed: each runner pulls
intent at cycle start, so the assignment takes effect on the next
cycle with no restart.

### 6. Operate the two pools independently

`desiredState` is per pool, so one can be paused while the other keeps
cycling:

```powershell
pwsh test/Set-PoolDesiredState.ps1 -PoolId poolb -State paused -IntentGitUrl <intent-url>
pwsh test/Set-PoolDesiredState.ps1 -PoolId poolb -State run    -IntentGitUrl <intent-url>
```

To move a host from Pool A to Pool B, drain it first, let its current
cycle finish, then remove and re-add:

```powershell
pwsh test/Set-PoolDesiredState.ps1  -PoolId poola -State drain  -IntentGitUrl <intent-url>
pwsh test/Remove-HostFromPool.ps1   -PoolId poola -HostId <host-2-uuid> -IntentGitUrl <intent-url>
pwsh test/Add-HostToPool.ps1        -PoolId poolb -HostId <host-2-uuid> -IntentGitUrl <intent-url>
pwsh test/Set-PoolDesiredState.ps1  -PoolId poola -State run    -IntentGitUrl <intent-url>
```

Draining stops the runner process on every Pool A member, so restart
`Invoke-TestRunner.ps1` on the hosts that stayed — and on the moved
host once it is in Pool B. Full command reference and limitations:
[pool-admin.md](pool-admin.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.02

Back to [Yuruna](../README.md)
