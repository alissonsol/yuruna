<a id="42383647-0001"></a>

# Yuruna lab operator guide

Bring-up runbook for a Yuruna lab: several machines sharing one
caching-proxy-service, NAS-backed pool and stash storage, and a
pool-control service, grouped into pools and assigned test-sets.

[Section A: Quickstart](#section-a-quickstart) is the complete command
sequence -- shared services first, then machine by machine.
[Section B: Deep dive](#section-b-deep-dive) explains each step. The
guide ends with a worked
[two-pool split](#two-pools-running-two-different-test-sets).

Prerequisite: every lab machine has completed the
[operator guide](operator.md) through A.2 (signed in as the test
user). The shared services are built once, on the most powerful
machine; every other machine points at them.

> **Shortcut for the beacon.** [install/setup.ps1](../install/setup.ps1)
> runs the shared-services half of this quickstart --
> [A.1](#a1-enable-test-automation-every-machine)-[A.6](#a6-bring-up-the-first-machine)
> -- as one guided command:
>
> ```
> pwsh install/setup.ps1    # choose "Lab"
> ```
>
> It runs exactly the scripts below, so the two paths stay
> interchangeable. It configures **only the machine it runs on** --
> joining machines still run `Set-LabToken.ps1` and the sync themselves
> ([A.7](#a7-enroll-each-additional-machine)). Re-running adopts healthy
> service VMs; `-Rebuild` replaces them (~15 minutes for the proxy).
> Coverage, `-WhatIf`, and unattended runs:
> [B.0](#b0-the-guided-setup-script-on-a-beacon).

---

<a id="42383647-0002"></a>

## Section A: Quickstart

"Elevated" means an Administrator PowerShell on Windows. Run commands
from the `yuruna` folder. The one Windows
exception is `install/setup.ps1`: start it from any PowerShell and it
relaunches itself elevated once, up front.

**On macOS and Ubuntu, do not put `sudo` in front of these scripts.**
They run unelevated and request `sudo` for the operations that need it.
Running one as root leaves files root-owned. On macOS, root also has
no GUI session, so UTM registration, `utmctl`, and the dialog watchdog
fail; UTM, running as you, cannot open the root-owned files.
Recover with `sudo chown -R "$USER" ~/yuruna` and re-run unelevated;
the scripts are idempotent.

<a id="42383647-0003"></a>

### A.1 Enable test automation (every machine)

On each lab machine: elevated on Windows; without `sudo` on macOS and Ubuntu
([B.1](#b1-enable-test-automation-every-machine)):

```
pwsh test/lab/Enable-TestAutomation.ps1
```

On Windows, sign out and back in if it reports display-scaling
changes.

**Guided path** -- on the beacon, `install/setup.ps1` runs this step
(skipped if the machine only hosts services). Every other lab machine
runs the command above by hand.

<a id="42383647-0004"></a>

### A.2 Create lab storage

Run where the storage lives -- on a machine that mounts the NAS path,
or on the shared-services machine if there is no NAS
([B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas)).

**Storage on this machine (no NAS)** -- one command does all of it
(folders, accounts, shares, mounts, config). Elevated on Windows; on
macOS and Ubuntu run it **without** `sudo`:

```
pwsh test/lab/New-LocalLabStorage.ps1
```

It asks only where storage should live (suggesting a per-OS default),
calls `New-Lab`, and writes `networkStorage.*` and the vault entries --
then skip to the last paragraph of this step.
A later lab on the same machine needs only
`pwsh test/lab/New-Lab.ps1 -Name <lab-name>` -- it reuses the folders and
accounts already here.

**Storage on a NAS or a separate file server** -- create the folders
and the lab vault here, then create the accounts and grant the share
permissions **on that device**:

```
pwsh test/lab/New-Lab.ps1 -Name <lab-name> -Root <storage-root>
```

`<lab-name>` is lowercase (letters, digits, hyphens); `<storage-root>`
is e.g. `D:\work` or `/srv`. Share the two folders it created -- one
dedicated account per share, using the passwords `New-Lab` just
generated into the lab vault:

```powershell
# On the machine hosting the shares (elevated, Windows example)
New-LocalUser yuruna-pool  -Password (Read-Host -AsSecureString 'yuruna-pool password')
New-LocalUser yuruna-stash -Password (Read-Host -AsSecureString 'yuruna-stash password')
New-SmbShare -Name yuruna.pool  -Path D:\work\yuruna.pool  -FullAccess yuruna-pool
New-SmbShare -Name yuruna.stash -Path D:\work\yuruna.stash -FullAccess yuruna-stash
icacls D:\work\yuruna.pool  /grant 'yuruna-pool:(OI)(CI)M'
icacls D:\work\yuruna.stash /grant 'yuruna-stash:(OI)(CI)M'
```

Then, on each machine you configure by hand -- the shared-services
machine now and the first cycle machine in
[A.6](#a6-bring-up-the-first-machine) -- fill `networkStorage.*` in
`test/test.config.yml` and store both share passwords in the host
vault ([Setting the SMB passwords in the vault](test-config.md#setting-the-smb-passwords-in-the-vault)).
Machines enrolled in [A.7](#a7-enroll-each-additional-machine)
receive both through the sync.

**Guided path** -- `install/setup.ps1` runs `New-LocalLabStorage.ps1`
on the beacon when you answer that storage lives here. For a NAS it
only **mounts** what `networkStorage.*` already names -- it creates
nothing on the NAS, so do the commands above first. A failed mount
asks whether to stop or fall back to local shares; unattended,
`storage.onFailure` decides (default `stop`). A lab cannot decline
shared storage: the stash service and the pool intent store both need
it.

<a id="42383647-0005"></a>

### A.3 Start the caching-proxy service (one per lab)

On the shared-services machine; elevated on Windows, unelevated on
macOS ([B.3](#b3-start-the-caching-proxy-service--dashboards)):

```
pwsh test/service/Start-CachingProxyServiceVM.ps1
```

Note the proxy VM's IP the script prints -- every machine's
`vmStart.cachingProxyIp` ([A.6](#a6-bring-up-the-first-machine))
points at it.

The Grafana "Yuruna hosts" dashboard's "Lab token" tile shows the
6-character code later steps redeem to enroll hosts. It rotates about
once a minute -- read it fresh each time you run `Set-LabToken.ps1`.

**Guided path** -- `install/setup.ps1` starts this VM, waits for the
pool aggregator, and writes **this** machine's
`vmStart.cachingProxyIp`. Every other machine gets the value by hand
or through the sync.

<a id="42383647-0006"></a>

### A.4 Start the stash service

Elevated on Windows, unelevated on macOS; needs the A.2 configuration
on this machine ([B.4](#b4-start-the-stash-service)):

```
pwsh test/service/Start-StashServiceVM.ps1
```

**Guided path** -- `install/setup.ps1` starts it once storage is
configured; otherwise it lists the stash service as skipped.

<a id="42383647-0007"></a>

### A.5 Start the pool-control service

Elevated on Windows, unelevated on macOS
([B.5](#b5-start-the-pool-control-service)):

```
pwsh test/service/Start-PoolControlServiceVM.ps1
pwsh test/lab/Set-LabToken.ps1 -LabToken <code>
```

`<code>` is the current "Lab token" tile value
([A.3](#a3-start-the-caching-proxy-service-one-per-lab)); `Set-LabToken.ps1`
enrolls this host in the lab.

**Guided path** -- `install/setup.ps1` does both lines, reading the
rotating token from the aggregator's metrics endpoint -- no tile to
copy -- and printing a copy-pasteable command if it could not. It
also ensures the `default` pool exists and validates the intent store;
[pool-admin.md](pool-admin.md) covers manual administration. It does not turn on
auto-enrollment ([B.5](#b5-start-the-pool-control-service)).

<a id="42383647-0008"></a>

### A.6 Bring up the first machine

On the machine that will run cycles first: edit
`test/test.config.yml` -- at minimum `repositories.projectUrl` (and
`GH_TOKEN` if private) and `guestSequence`, plus the
`networkStorage.*` values and share passwords from
[A.2](#a2-create-lab-storage) and the `vmStart.cachingProxyIp` from
[A.3](#a3-start-the-caching-proxy-service-one-per-lab) -- then enroll,
validate, and run ([B.6](#b6-configure-the-first-machine)):

```
pwsh test/lab/Set-LabToken.ps1 -LabToken <code>
pwsh test/Test-Config.ps1
pwsh test/Invoke-TestProject.ps1
pwsh test/Start-TestRunner.ps1
```

Skip `Set-LabToken.ps1` if this is the shared-services machine --
[A.5](#a5-start-the-pool-control-service) already enrolled it. Fix
every `Test-Config` FAIL; debug `Invoke-TestProject` until green; then
leave the runner cycling -- it serves the status dashboard at
`http://<host>:8080/`.

**Guided path** -- on the beacon, `install/setup.ps1` has already
created `test/test.config.yml`, set `repositories.projectUrl` (if
given) and `vmStart.cachingProxyIp`, and run this `Test-Config` gate;
the [A.5](#a5-start-the-pool-control-service) enrollment also seeds
`pool.enabled` and `pool.intentGitUrl`. `guestSequence` and `GH_TOKEN`
are never touched. It runs no cycles -- `Invoke-TestProject.ps1` and
`Start-TestRunner.ps1` are left to you.

<a id="42383647-0009"></a>

### A.7 Enroll each additional machine

> **First time, or a machine that still needs its test account?**
> [Adding a machine to a lab](lab-new-machine.md) walks this same
> sequence in full -- creating the account, signing into it, the GitHub
> credential, and the first `Test-Config.ps1` report.

On each remaining machine ([B.7](#b7-each-additional-machine)):

```
pwsh test/lab/Set-LabToken.ps1 -LabToken <code>
pwsh test/lab/Sync-HostConfiguration.ps1 -ReferenceHost <ip-or-name>
pwsh test/Invoke-TestProject.ps1
```

The sync copies the reference host's config converted for this host
and finishes by running `Test-Config.ps1`.

If the machine was previously a **standalone host**, run
`pwsh test/pool/Convert-ToPoolWorker.ps1 -ReferenceHost <ip-or-name>` in
place of the sync. It does the same sync and then retires the local
services the lab now provides -- which otherwise keep winning the
lookup and quietly serve this host's cycles
([B.7](#b7-each-additional-machine)).

Once `Invoke-TestProject`
is green, open the pool-control service UI at
`http://<pool-control-service-vm-ip>/`, add the host to a pool, assign
a test-set, then:

```
pwsh test/Start-TestRunner.ps1
```

**Guided path** -- none: `install/setup.ps1` never touches a second
machine. Auto-enrollment stays off
([B.5](#b5-start-the-pool-control-service)), so a machine enrolled
here belongs to no pool until you put it in one.

---

<a id="42383647-000a"></a>

## Section B: Deep dive

<a id="42383647-000b"></a>

### B.0 The guided setup script on a beacon

Reference for the shortcut at the top of this guide. In lab mode
`install/setup.ps1` covers, on the beacon only: host settings
([A.1](#a1-enable-test-automation-every-machine)), storage
([A.2](#a2-create-lab-storage)), the caching-proxy
([A.3](#a3-start-the-caching-proxy-service-one-per-lab)), stash
([A.4](#a4-start-the-stash-service)) and pool-control
([A.5](#a5-start-the-pool-control-service)) services, this host's own
enrollment -- reading the rotating token from the pool-aggregator's open
metrics endpoint on the proxy (`<proxy-ip>:9400/metrics`) -- and the
`test.config.yml` work and validation gate from
[A.6](#a6-bring-up-the-first-machine), and ensures the `default` pool
exists. Host settings are skipped if the machine only hosts
services; the stash service is skipped unless storage is configured.

**It deliberately leaves to you:** installing and cloning (run the OS
bootstrapper first); creating anything on a NAS -- it only mounts what
`networkStorage.*` already names, creating the local mount point (and
on Ubuntu the pool-storage sudoers drop-in first, since the mount runs
`sudo -n`), and an empty `networkStorage.*` fails the step naming the
keys it expected; the auto-enrollment sweep
([B.5](#b5-start-the-pool-control-service)); and the cycles, so
[A.6](#a6-bring-up-the-first-machine) still ends with you.

Bring-up adopts a healthy service VM and replaces an unhealthy,
half-removed, or missing one. `-Rebuild` replaces every service VM in the
run; budget roughly 15 minutes for the proxy.

An interactive run writes the answers it *resolved* to
`install/setup.answers.lab.yml`; feed that back with `-AnswerFile` to
build the next beacon the same way. The only lab key is `lab.name` on
top of the standalone set. The `default` pool is not a choice: every
run creates it in the intent store when none is there, leaving an
existing one untouched.

An unattended `storage.kind: local` run also needs
`storage.localRoot`, and is refused in its first second without it --
`New-LocalLabStorage.ps1` runs as a child with its stdin closed, so it
cannot be asked. An interactive run does not ask either: it takes the
platform's convention and records that in the run log. On a beacon,
storage failing ends the run, because the pool intent store and the
stash service both live on it.

Parameters, re-run semantics, and what makes a run fail are shared
with the standalone path:
[operator.md B.0](operator.md#b0-the-guided-setup-script). To put a
machine back, see
[test/lab/Disable-TestAutomation.ps1](../test/lab/Disable-TestAutomation.ps1)
([B.1](#b1-enable-test-automation-every-machine)).

<a id="42383647-000c"></a>

### B.1 Enable test automation (every machine)

```
pwsh test/lab/Enable-TestAutomation.ps1
```

Run on each lab machine. Explicit opt-in that turns it into a test
host: display sleep, screen saver, screen lock, display scaling
(Windows), TCC grants (macOS). Administrator on Windows; unelevated on
macOS and Ubuntu -- under `sudo` its PowerShell modules land in root's
profile. Idempotent; supports `-WhatIf`. On Windows, sign out and back
in if it reports display-scaling changes -- OCR needs 100% scaling.
Details: `host/<platform>/Enable-TestAutomation.ps1`.

**Putting a machine back** -- `pwsh test/lab/Disable-TestAutomation.ps1` is
the inverse; full breakdown:
[operator.md](operator.md#putting-the-machine-back). On a lab machine,
`-StopServices` also stops the caching-proxy, stash and pool-control
VMs -- on the shared-services machine that takes the whole lab down,
which is why it is off by default.

Two lab-specific notes: it **refuses to run while a test runner owns
the runtime directory** -- the normal state of a cycling lab host, so
stop the runner first -- and it knows nothing about **enrollment**: the
`pool.*` keys and the internal authentication key stay where they are. To leave a pool,
use the pool admin commands ([pool-admin.md](pool-admin.md)); to drop
a host from the dashboard, `test/pool/Remove-PoolHost.ps1`.

<a id="42383647-000d"></a>

### B.2 Lab storage: pool and stash shares (ideally on a NAS)

Durable network tiers ([pool-storage.md](pool-storage.md),
[stash-guide.md](stash-guide.md)) are backed by two SMB3 shares --
`yuruna.pool` and `yuruna.stash` -- on a NAS if you have one, otherwise
on the machine hosting the shared services. `test/lab/New-Lab.ps1` creates
the folders, the lab vault, and the seeded pool-intent repository in
one idempotent step, run where the storage lives; commands:
[A.2](#a2-create-lab-storage).

It generates one credential per share account into the lab vault --
plain YAML protected by filesystem permissions, so it stays **copyable
to the other lab machines** (DPAPI-bound files would not decrypt
elsewhere; see `test/schemas/lab.vault.schema.yml`). Sharing the
folders is yours to do -- one dedicated account per share, as in the
A.2 example; any Samba/SMB server with the same share names and
accounts works. Then, on each machine, fill `networkStorage.*`, put
the share passwords in the vault, and set `networkStorage.moveLogsToPoolStorage:
true` on hosts that should archive cycles
([test-config.md](test-config.md)).

**When the storage lives on the machine you are standing at,
`test/lab/New-LocalLabStorage.ps1` does the whole step instead** -- the
accounts, SMB server, shares, vault entries, mounts, and the six
`networkStorage.*` keys, on top of the `New-Lab` call. Idempotent,
`-WhatIf`-able, `-MoveLogs` for `networkStorage.moveLogsToPoolStorage`.
Details:
[operator.md B.7](operator.md#b7-local-shares-for-pool-and-stash-storage).

The shares are consumed through hosts-file aliases (`ypool-nas`,
`ystash-nas`) resolving to loopback, so a one-machine lab exercises
the same mount and replication code as one with a NAS
([operator.md B.7](operator.md#b7-local-shares-for-pool-and-stash-storage)).

A **standalone** machine gets one more alias, `yuruna-dash`, pointing at
the caching-proxy-service VM rather than at loopback: it makes the Yuruna hosts
dashboard `http://yuruna-dash:3000/d/yuruna-pool/yuruna-hosts`, a URL
worth bookmarking because it survives the cache VM being rebuilt onto a
new DHCP lease. `setup.ps1` rewrites it every run from the same address
it writes into `vmStart.cachingProxyIp`. A lab gets no such alias -- its
proxy is shared, and every other machine reaches it through that config
key instead.

The alias is **host-local on purpose** -- the service VMs do not use
it. Inside a guest `127.0.0.1` is the guest's own loopback (the mount
fails with `cifs_mount ... -111`), so each VM build bakes the address
this host is reachable at from that VM's network: the LAN address for
a bridged VM, the hypervisor's gateway for a NAT'd one. Two
consequences: the address is fixed at **build** time, so a host that
changes address (or moves between Wi-Fi and Ethernet) needs the
service VMs rebuilt; and inbound TCP 445 must be reachable from the
VM's network for a bridged guest to mount.

**Adding more labs to that machine** takes only `New-Lab`: the share
accounts are machine-wide, so it reuses the root and the credentials
already present rather than minting a second set -- see
[operator.md B.7](operator.md#b7-local-shares-for-pool-and-stash-storage).

**It is for local storage only.** A NAS owns its own accounts -- create
them on the device, then point `networkStorage.*` at it as above.

<a id="42383647-000e"></a>

### B.3 Start the caching-proxy service + dashboards

```
pwsh test/service/Start-CachingProxyServiceVM.ps1
```

One proxy serves the whole lab. Builds the
`yuruna-caching-proxy-service` VM and exposes ports 80 (CA cert),
3128/3129 (Squid), 3000 (Grafana), 9302 (metrics). Elevated on
Windows; unelevated on macOS. On every lab machine, set
`vmStart.cachingProxyIp` to this proxy's IP. The build mints an
internal authentication key into this host's vault when none exists, and the
"Yuruna hosts" Grafana dashboard shows the rotating 6-character "Lab
token" later steps redeem to enroll hosts. The cache VM survives
framework reinstalls. Details:
[caching.md](caching.md#caching-proxy-service--test-harness-operator-reference).

<a id="42383647-000f"></a>

### B.4 Start the stash service

```
pwsh test/service/Start-StashServiceVM.ps1
```

Brings up the `yuruna-stash-service` VM -- the lab-wide drop box for
files and snippets (web UI + scp). Elevated on Windows, unelevated on
macOS. It mounts the `yuruna.stash` share
from [B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas), so
set that up first. No login; trusted networks only. User guide:
[stash-guide.md](stash-guide.md).

On a macOS host with a **Wi-Fi** default route this VM is built on UTM
Shared NAT rather than bridged -- vmnet cannot bridge a Wi-Fi uplink,
so a bridged VM would never get a DHCP lease. It is then invisible to
the LAN on its own address, and the script forwards a host port
instead: peers reach it at `<host-lan-ip>:2222` (remapped, because the
Mac's own sshd owns 22) rather than `<vm-ip>:22`. Plugging into
Ethernet -- including a USB Ethernet adapter, which vmnet bridges
fine -- switches it back to bridged on the next rebuild; the script
warns when the VM's mode no longer matches the host's uplink.

<a id="42383647-0010"></a>

### B.5 Start the pool-control service

```
pwsh test/service/Start-PoolControlServiceVM.ps1
```

Brings up the `yuruna-pool-control-service` VM -- operator UI + API for
pool intent: create pools, add hosts, assign test-sets. Elevated on
Windows, unelevated on macOS. On a Wi-Fi macOS host it is built on UTM
Shared NAT ([B.4](#b4-start-the-stash-service)) and forwarded -- peers
open `http://<host-lan-ip>:8081/` (the per-service forwards never
move: caching-proxy `:80`, stash `:2222`, pool-control `:8081`,
download-agent `:8082`). Cloud-init builds the daemon inside the guest
(no host `go` needed) and persists its audit log + status under
`poolStorageNetworkPath` -- set up the shares
([B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas))
first. The UI is on port 80 (`http://<pool-control-service-vm-ip>/`),
also linked in the Grafana "Yuruna hosts" dashboard's Extension hosts
table. Enroll this host with `test/lab/Set-LabToken.ps1 -LabToken <code>`
(the "Lab token" tile value); the script fetches the shared
internal authentication key into the host vault. `install/setup.ps1` does this
for the beacon -- but **auto-enrollment stays off** until an
`autoEnrollment` block names a target pool in the intent store's
`pools.yml` *and* the daemon runs with `--auto-enroll`; until then, an
enrolled host joins no pool on its own. Add `-HostSideProof` to run it
directly on this host (UI at `http://<host>:8090/`, needs `go` +
`pwsh`). Details:
[Pool-control service](pool-admin.md#pool-control-service).

Each service VM has its own administrator account and vault key -- see
[VM administrator accounts](operator.md#vm-administrator-accounts).

<a id="42383647-0011"></a>

### B.6 Configure the first machine

On the machine that will run cycles first (any of them):

1. **Enroll in the lab** -- `pwsh test/lab/Set-LabToken.ps1 -LabToken
   <code>` (current "Lab token" tile value); already done for the
   shared-services machine in
   [B.5](#b5-start-the-pool-control-service). Without the token the
   host still cycles standalone but never reports to the lab
   dashboards.
2. **Configure and validate** -- edit `test/test.config.yml` and run
   `pwsh test/Test-Config.ps1`
   ([operator guide B.6](operator.md#b6-configure-and-validate));
   include the `networkStorage.*` values and share passwords from
   [B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas) and
   the `vmStart.cachingProxyIp` from
   [B.3](#b3-start-the-caching-proxy-service--dashboards).
3. **One local cycle** -- `pwsh test/Invoke-TestProject.ps1` until green; one
   cycle with no loop around it is the cheapest place to debug.
4. **Continuous cycles** -- `pwsh test/Start-TestRunner.ps1`; it
   auto-starts the status dashboard at `http://<host>:8080/`
   ([runner-outer-loop.md](runner-outer-loop.md)).

<a id="42383647-0012"></a>

### B.7 Each additional machine

Step by step, with the human parts (test account, sign-in, GitHub
credential, reading the first validation report):
[Adding a machine to a lab](lab-new-machine.md).

1. **OS baseline, preflight, install, test user** -- operator guide
   through [A.2](operator.md#a2-create-the-test-user); reboot if the
   installer asks.
2. **Enable test automation** -- `pwsh test/lab/Enable-TestAutomation.ps1`
   ([B.1](#b1-enable-test-automation-every-machine)).
3. **Enroll in the lab, then sync configuration from an existing
   host:**

   ```
   pwsh test/lab/Set-LabToken.ps1 -LabToken <code>
   pwsh test/lab/Sync-HostConfiguration.ps1 -ReferenceHost <ip-or-name>
   ```

   `Set-LabToken.ps1` redeems the "Lab token" tile code at the
   aggregator and stores the internal authentication key in this
   host's vault. The sync then copies the reference host's
   `test.config.yml` converted for this host (share paths, mount
   points, host aliases) and **finishes by running Test-Config.ps1**.
   If the aggregator is unreachable, skip `Set-LabToken.ps1` and pass
   the raw key (from the shared-services host's vault) to the sync:
   `-InternalAuthKey '<raw-key>' -PersistInternalAuthKey`. No local
   caching-proxy-service is needed -- the synced `vmStart.cachingProxyIp`
   points at the shared one.

   Before overwriting anything, the sync compares the fetched config
   against this host's `test.config.yml.template` and stops to ask if
   the reference host is behind it -- listing retired keys it still
   uses, current keys it lacks, and keys the schema has dropped. Fix
   at the source (`pwsh tools/Update-TestConfigNaming.ps1` +
   `Test-Config.ps1` there), then sync again. `-AllowStaleReference`
   accepts the drift; under `-NonInteractive` a stale reference fails
   the run without it, so an unattended sync cannot propagate a
   half-migrated config.
   **A machine that was a standalone host needs the conversion, not
   the sync.** `Sync-HostConfiguration.ps1` replaces the
   configuration; it does not retire what the old configuration
   pointed at, and a leftover local service VM *wins*. Extension
   areas resolve as operator pin -> **a VM on this host** -> the pool's
   record, so a machine that keeps its own stash service goes on using
   it and never consults the lab's -- and its cycles pass while doing
   so. Stopping the VM is not enough either: the per-cycle sweep
   restarts every registered-but-stopped service VM. Use:

   ```
   pwsh test/lab/Set-LabToken.ps1 -LabToken <code>
   pwsh test/pool/Convert-ToPoolWorker.ps1 -ReferenceHost <ip-or-name>
   ```

   It runs the sync above, then retires every local service VM
   (caching-proxy, stash, pool-control, download-agent) through each
   service's own `Stop-*ServiceVM.ps1` -- which also clears the
   extension marker and refreshes `host.registration.json`, so the
   host drops off the dashboard's Extension hosts row within one
   aggregator poll -- drops the hosts-file aliases those services
   owned, and verifies the end state. `-KeepCachingProxy` keeps a warm
   local Squid on a slow link. Add `-WhatIf` to preview; that needs no
   elevation.

   The internal authentication key is **required** for the conversion.
   Without it the vault entries this machine minted for the shares it
   used to serve itself would survive, and the lab's storage has never
   seen those passwords -- the mount fails later with a credential
   error nobody connects back to this step.

   Storage is reported, never deleted:
   `pwsh test/lab/Clear-LocalLabStorage.ps1` withdraws the SMB shares, the
   `yuruna-pool` / `yuruna-stash` accounts, and the loopback
   exemptions, then prints the sizes under the storage root and the
   exact command to reclaim them. Start with `-ReportOnly`.
4. **(Recommended) one local cycle** -- `pwsh test/Invoke-TestProject.ps1` to
   prove the host green standalone before the pool drives it.
5. **Join a pool and take assignments** -- open the pool-control service UI at
   `http://<pool-control-service-vm-ip>/` (linked as "Pool-control service" in the
   Grafana "Yuruna hosts" dashboard's Extension hosts table), add
   this host to a pool, and assign a test-set. CLI equivalent:
   `test/pool/Add-HostToPool.ps1` + `test/pool/Set-PoolTestSet.ps1`
   ([pool-admin.md](pool-admin.md)). Then start
   `pwsh test/Start-TestRunner.ps1`.

---

<a id="42383647-0013"></a>

## Troubleshooting bring-up

Symptoms specific to this runbook. Storage-mount problems in general
are in [pool-storage.md](pool-storage.md#operating--troubleshooting).

**`New-LocalLabStorage.ps1` stops at `[5/8]` with an exit-131 error
naming .NET or `libhostfxr` (macOS).** The step re-launches itself
under `sudo` to write `/etc/hosts`, and a Homebrew PowerShell cannot
start without the `DOTNET_ROOT` its wrapper sets. Record the runtime
location once, then re-run -- the script picks up where it stopped:

```
echo "$(brew --prefix dotnet)/libexec" | sudo tee /etc/dotnet/install_location_$(uname -m)
```

Current installs write this file for you; only older hosts need it.

**Both SMB mounts fail at `[8/8]` with an authentication error, and
the password is right (macOS).** `smbd` accepts only the SMB-NT
credential, which `sysadminctl` does not create; current versions
enable and prove it. To repair an account created earlier, per
account:

```
sudo pwpolicy -u yuruna-pool -sethashtypes SMB-NT on
sudo sysadminctl -resetPasswordFor yuruna-pool -newPassword '<the lab-vault password>'
```

The hash type only affects passwords set *afterward*, so the re-set
is required. The password is in
`test/status/extension/authentication/lab.<lab-name>.vault.yml`.

**A service VM script reports success but the VM is not running, or
blames cloud-init / the daemon build / the NAS for a VM that never
booted.** All three scripts assert the VM reached `running` before
anything downstream and fail naming the state they observed, so this
symptom means the scripts are out of date.

**The pool-control VM never mounts the pool share --
`cifs_mount failed w/return code = -111`.** The share's server name
resolved to something host-local (`mount error(13)` is a rejected
credential instead -- see above). Current builds bake a guest-reachable
address into the seed; an older VM needs rebuilding. Confirm from
inside the guest:

```
getent hosts ypool-nas          # what the guest resolves, if anything
grep cifs /etc/fstab            # the ip= option should name the host
```

**Bundle or artifacts are root-owned and UTM will not open the VM
(macOS).** Something was run with `sudo`. See the note at the top of
[Section A](#section-a-quickstart): `sudo chown -R "$USER" ~/yuruna`,
then re-run unelevated.

---

<a id="42383647-0014"></a>

## Two pools running two different test-sets

A worked example: one lab, two groups of hosts, each running a
different body of tests. Names are placeholders.

Assume four hosts registered and green standalone
([B.7](#b7-each-additional-machine)), the pool NAS
([B.2](#b2-lab-storage-pool-and-stash-shares-ideally-on-a-nas)), and
the pool-control-service VM
([B.5](#b5-start-the-pool-control-service)). `<intent-url>` is the
writable pool-intent git URL; every command that mutates intent takes
it.

<a id="42383647-0015"></a>

### 1. Define the two test-sets

A test-set is a named framework/project repo **pair**: a pooled
member overrides its `repositories.*` URLs with it for the cycle and
runs the assigned project's `test.runner.yml` plan. Two bodies of
tests therefore mean two project repos -- or two branches or forks of
one. `GH_TOKEN` is never stored in pool intent; it stays host-local.

Register both pairs in the intent store's test-set library:

```powershell
pwsh test/pool/Set-PoolTestSetDefinition.ps1 -Name testset1 -FrameworkUrl <framework-url> -ProjectUrl <project-a-url> -IntentGitUrl <intent-url>
pwsh test/pool/Set-PoolTestSetDefinition.ps1 -Name testset2 -FrameworkUrl <framework-url> -ProjectUrl <project-b-url> -IntentGitUrl <intent-url>
```

<a id="42383647-0016"></a>

### 2. Create both pools

```powershell
pwsh test/pool/New-Pool.ps1 -PoolId poola -DisplayName 'Pool A' -IntentGitUrl <intent-url>
pwsh test/pool/New-Pool.ps1 -PoolId poolb -DisplayName 'Pool B' -IntentGitUrl <intent-url>
```

`-PoolId` is permanent -- `New-Pool.ps1` mints a stable `poolGuid` for
it (the dashboard's "Pool ID"), so renaming later means a new pool
and forks the telemetry history.

<a id="42383647-0017"></a>

### 3. Split the hosts between them

A host belongs to **at most one pool**, which is what makes the split
meaningful. Each `-HostId` is that host's `runtime/host.uuid`:

```powershell
pwsh test/pool/Add-HostToPool.ps1 -PoolId poola -HostId <host-1-uuid> -IntentGitUrl <intent-url>
pwsh test/pool/Add-HostToPool.ps1 -PoolId poola -HostId <host-2-uuid> -IntentGitUrl <intent-url>
pwsh test/pool/Add-HostToPool.ps1 -PoolId poolb -HostId <host-3-uuid> -IntentGitUrl <intent-url>
pwsh test/pool/Add-HostToPool.ps1 -PoolId poolb -HostId <host-4-uuid> -IntentGitUrl <intent-url>
```

<a id="42383647-0018"></a>

### 4. Assign one test-set to each pool

```powershell
pwsh test/pool/Set-PoolTestSet.ps1 -PoolId poola -Name testset1 -FrameworkUrl <framework-url> -ProjectUrl <project-a-url> -IntentGitUrl <intent-url>
pwsh test/pool/Set-PoolTestSet.ps1 -PoolId poolb -Name testset2 -FrameworkUrl <framework-url> -ProjectUrl <project-b-url> -IntentGitUrl <intent-url>
```

A pool holds exactly one `testSet`; assigning replaces the previous
one. Members do not split the work: every `poola` member clones
`<project-a-url>` and runs its full plan, reporting under the pool.

<a id="42383647-0019"></a>

### 5. Verify before the next cycle

```powershell
pwsh test/pool/Test-PoolIntent.ps1 -IntentGitUrl <intent-url>          # schema-validates the intent files
pwsh test/pool/Get-PoolStatus.ps1  -PoolId poola -IntentGitUrl <intent-url>
pwsh test/pool/Get-PoolStatus.ps1  -PoolId poolb -IntentGitUrl <intent-url>
```

`Test-PoolIntent.ps1` also enforces the one-pool-per-host rule;
`Get-PoolStatus.ps1` shows members, `desiredState`, and the assigned
test-set. Neither probes the repo URLs -- a typo first surfaces when a
member's next cycle clones. Each runner pulls intent at cycle start,
so assignments take effect next cycle with no restart.

<a id="42383647-001a"></a>

### 6. Operate the two pools independently

`desiredState` is per pool, so one can be paused while the other keeps
cycling:

```powershell
pwsh test/pool/Set-PoolDesiredState.ps1 -PoolId poolb -State paused -IntentGitUrl <intent-url>
pwsh test/pool/Set-PoolDesiredState.ps1 -PoolId poolb -State run    -IntentGitUrl <intent-url>
```

To move a host from Pool A to Pool B, drain it first, let its current
cycle finish, then remove and re-add:

```powershell
pwsh test/pool/Set-PoolDesiredState.ps1  -PoolId poola -State drain  -IntentGitUrl <intent-url>
pwsh test/pool/Remove-HostFromPool.ps1   -PoolId poola -HostId <host-2-uuid> -IntentGitUrl <intent-url>
pwsh test/pool/Add-HostToPool.ps1        -PoolId poolb -HostId <host-2-uuid> -IntentGitUrl <intent-url>
pwsh test/pool/Set-PoolDesiredState.ps1  -PoolId poola -State run    -IntentGitUrl <intent-url>
```

Draining stops the runner process on every Pool A member, so restart
`Start-TestRunner.ps1` on the hosts that stayed -- and on the moved
host once it is in Pool B. Full command reference and limitations:
[pool-admin.md](pool-admin.md).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.12

Back to [Yuruna](../README.md)
