<a id="4218e2fb-0001"></a>

# Adding a machine to a lab -- detailed walkthrough

The [lab operator guide](lab-operator.md) enrolls an additional machine
in three commands
([A.7](lab-operator.md#a7-enroll-each-additional-machine)) -- the right
density once you have done it before. This page is that same sequence
written out in full, including the parts that are not commands at all:
creating the account the harness runs as, signing into it, giving the
machine a GitHub credential, and reading the first `Test-Config.ps1`
report without chasing warnings that are simply what a machine that has
never run a cycle looks like.

**Where this starts.** The machine has a fresh, activated, updated OS
([operator.md B.1-B.2](operator.md#b1-operating-system-baseline-assumed))
and you have run the host installer one-liner on it once from your own
account ([operator.md A.1](operator.md#a1-install-the-framework)),
rebooting if it asked. Everything below happens on that machine.

**What the lab must already have.** A caching-proxy service with the
Grafana "Yuruna hosts" dashboard, a pool-control service, and at least
one machine cycling. The dashboard's **Lab token** tile -- a
6-character code -- is the credential this walkthrough redeems twice. It
rotates about once a minute and stays redeemable for about three, so
read it fresh at each step that needs it rather than writing it down.

---

<a id="4218e2fb-0002"></a>

## 1. Create the account the harness runs as

From your own administrator session, in the checkout the installer
made:

```
pwsh test/New-LocalTestUser.ps1 -Admin
```

Keep `-Admin`: later steps elevate, and an account created without it
cannot ([operator.md B.4](operator.md#b4-create-the-yuruna-test-user)
covers repairing one that was).

**Passwords on a managed machine.** On a domain-joined or MDM-managed
machine, the local account's password answers to the policy pushed to
the machine -- length, complexity, history, and possibly an expiry.
Choose one that satisfies that policy on the first try, and know where
the password lives afterward. When the authentication vault already
holds a local-OS password for this account name, the script creates the
account with *that* password, so the credential the harness hands out
keeps matching the account. Type a different one -- because the stored
one is not policy-compliant here, or because the machine forces a change
at first sign-in -- and the vault's copy is stale: Yuruna goes on
handing out the stored password until you update
`test/status/extension/authentication/vault.yml`
(`users.<key>.password`). The script warns when it sees that mismatch;
that warning is the one to act on rather than scroll past.

<a id="4218e2fb-0003"></a>

## 2. Sign in as the test account

Sign out and back in as the new account (default `yurunatest`).
Everything from here belongs to that account: the checkout, the vault,
the runtime state, and the runner.

It is also the moment to let the OS finish updating, before the machine
goes unattended -- a pending update reboots on its own schedule, which
will be the middle of a cycle. **Stay on the release channel while you
do it**: no Insider or beta builds, no optional preview updates. The
harness drives and reads this machine's screen, so a preview build moves
the host under it, on somebody else's release schedule.

<a id="4218e2fb-0004"></a>

## 3. Have the GitHub credential ready

Skip this if the framework and project repositories are both public.

Two credentials are easy to confuse, and only the first one is yours to
set up here:

- **This machine's own git credential** -- what `git` on the host uses
  to clone the framework and refresh it later. The next step asks for
  it.
- **`repositories.ghToken` in `test/test.config.yml`** -- copied into
  every guest so a VM can clone. You do not set this by hand on a
  joining machine; the sync in step 5 brings the reference machine's
  value across.

Take the token from wherever your lab keeps it -- if that is a stash
entry, see the [stash guide](stash-guide.md), remembering that the stash
has no login, so nothing stronger than a read-only token belongs
anywhere near it. Scope it as
[definition.md](definition.md#defining-the-two-source-scheme-for-framework-and-project-urls)
describes: a fine-grained token limited to the framework and project
repositories, **Contents: Read-only**, with the exact settings in
[CONTRIBUTING](../CONTRIBUTING.md#repositoriesghtoken--reading-a-private-frameworkproject-repo).

When git needs it, Git Credential Manager opens a GitHub sign-in dialog.
Choose **Token** and paste the value; the browser and device-code flows
are offered too, but the token is the one already in your hand. To see
which repository the checkout actually tracks -- the public framework or
your lab's private one -- ask git:

```
git config --get remote.origin.url
```

<a id="4218e2fb-0005"></a>

## 4. Re-run the installer one-liner as this account

The clone is per user, so the test account needs its own. Run the
one-liner for this host OS again
([operator.md A.1](operator.md#a1-install-the-framework)) in the test
account's session.

**On Windows, run it from PowerShell 7 (`pwsh`), not from Windows
PowerShell.** Started under 5.1 the installer has to bootstrap
PowerShell 7 first -- a winget install-or-upgrade and a re-exec of
itself -- which is a pure detour on a machine whose first run already
installed it for all users. `pwsh` is also the shell every command below
runs in.

This second run is quick: the dependencies are already in place, so it
clones the framework into this account's profile and seeds
`test/test.config.yml` from the template. It is also where a private
repository prompts for the credential from step 3. On Windows it
finishes by opening Hyper-V Manager, a `pwsh` prompt in `test/`, and
notepad on `test.config.yml` -- the last only while that file is still
identical to the template. On a machine joining a lab you can close
notepad without editing anything: the next step replaces the file with
the lab's configuration.

<a id="4218e2fb-0006"></a>

## 5. Sync the configuration from a machine already in the lab

```
pwsh test/lab/Sync-HostConfiguration.ps1 -ReferenceHost <ip-or-name>
```

`<ip-or-name>` is any machine already cycling in this lab; converting
between host types is the point, so it does not have to match this one.
Administrator on Windows; on macOS and Ubuntu run it unelevated and let
it ask for `sudo` when it writes `/etc/hosts`.

The sync needs the lab's internal authentication key to fetch the share
credential from the reference machine, and a machine joining the lab has
none yet, so it asks for one:

```
Internal authentication key -- or the dashboard's 6-character Lab token, which is redeemed for it (Enter to skip)
```

Paste the **Lab token** from the dashboard tile. The sync recognizes the
6-character shape, redeems it at the lab's pool aggregator, and enrolls
this machine in passing, so the key is here for later runs too.

It then copies the reference machine's `test.config.yml` whole --
converted for this host's share paths, mount points, and host aliases --
and finishes by running `Test-Config.ps1`. Before overwriting anything
it compares the fetched config against this machine's
`test.config.yml.template` and stops to ask when the reference is behind
it; fix that at the source rather than accepting the drift
([B.7](lab-operator.md#b7-each-additional-machine)).

**If this machine used to be a standalone Yuruna host**, run
`pwsh test/pool/Convert-ToPoolWorker.ps1 -ReferenceHost <ip-or-name>`
instead. It does the same sync and then retires the local service VMs
the lab now provides -- which otherwise keep winning the lookup and
quietly serve this machine's cycles while everything still looks green
([B.7](lab-operator.md#b7-each-additional-machine)).

<a id="4218e2fb-0007"></a>

## 6. Enable test automation

```
pwsh test/lab/Enable-TestAutomation.ps1
```

Administrator on Windows; unelevated on macOS and Ubuntu, where `sudo`
would land its PowerShell modules in root's profile instead of the test
account's. This is the explicit opt-in that turns the machine into a
test host: display sleep, screen saver, screen lock, display scaling on
Windows, TCC grants on macOS. It is idempotent and supports `-WhatIf`.

On Windows, sign out and back in if it reports display-scaling changes:
OCR needs 100% scaling, and a session keeps the scaling it started with.

<a id="4218e2fb-0008"></a>

## 7. Enroll with the Lab token, on the record

```
pwsh test/lab/Set-LabToken.ps1 -LabToken <code> -BounceStatusService
```

Read a fresh `<code>` off the dashboard tile -- the one used in step 5 is
long expired. Running this *after* the sync is deliberate: with
`test/test.config.yml` now in place, enrollment also binds this machine
to the lab's proxy (`vmStart.cachingProxyIp`) and seeds `pool.enabled`
and `pool.intentGitUrl`, none of which it can persist on a machine that
has no config file yet. `-BounceStatusService` restarts the status
service so the change is live now rather than at the next cycle. Safe to
re-run at any time -- a rotated token, a rebuilt proxy, or a doubtful
state is fixed by reading the current code and running it again.

<a id="4218e2fb-0009"></a>

## 8. Validate, and recognize what a first run looks like

```
pwsh test/Test-Config.ps1
```

Fix every **FAIL** -- this takes seconds and the first cycle takes many
minutes. Two of its findings, though, are just what a machine that has
never cycled looks like, and neither is worth chasing on this pass:

- **Host address stability.** There is no address history yet, because
  the status service records it and has never started here; the first
  cycle starts it. Later, with history to look at, this section may
  instead report that the bridge's DHCP identity is not pinned -- read
  it then, in
  [network.md](network.md#host-address-stability-and-what-happens-without-it).
- **Extension configs: `status/extension/notification/transports.yml`
  missing.** It means this machine emails nobody when a cycle fails;
  failures still reach the dashboard and the logs. Copy the template
  beside it and populate it when you want mail from this machine
  ([test-harness.md](test-harness.md#extension-areas)). Once the file
  exists but its Resend block is empty, the warning becomes
  `transports.resend is not configured` and says the same thing.

Everything else in that report is about this machine specifically and
deserves a look.

<a id="4218e2fb-000a"></a>

## 9. One cycle, then the runner

```
pwsh test/Invoke-TestProject.ps1
pwsh test/Start-TestRunner.ps1
```

One cycle with no loop around it is the cheapest place to debug a new
machine; the runner then cycles continuously and serves the status
dashboard at `http://<host>:8080/`
([runner-outer-loop.md](runner-outer-loop.md)).

A machine that belongs to no pool still cycles on its own configuration
and reports to the lab dashboards, but takes no assignment. Add it to a
pool from the pool-control service UI at
`http://<pool-control-service-vm-ip>/` and give that pool a test-set
([pool-admin.md](pool-admin.md)). Each runner pulls intent at the start
of a cycle, so the assignment takes effect on the next one with no
restart.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.18

Back to [Yuruna](../README.md)
