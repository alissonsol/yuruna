# Yuruna network workarounds

This file collects rationale for network-related workarounds in guest
scripts and the host harness, keeping source comments short and the
workarounds discoverable from one place.

Source files reference an entry with a single line of the form:

```
# --- REGION: https://yuruna.link/network#<topic-slug>
```

The fragment resolves to a `### Defining <topic>` heading in this file.
Slugs follow the standard GitHub Markdown rule: lowercase the heading
text, strip everything that isn't `[a-z0-9_ -]`, then replace spaces
with hyphens.

This file is the network-specific sibling of [Yuruna definitions](definition.md),
[Yuruna memory](memory.md) (historical / incident rationale), and
[vmconfig topic reference](vmconfig.md). The same `# --- REGION:`
convention is used in all four.

---

## Package-manager and curl retries

### Defining yuruna retry lib

Guest provisioning scripts call `apt-get` (Ubuntu) and `dnf` (Amazon
Linux 2023) to install workload dependencies, plus `curl` to fetch
release tags, install scripts, GPG keys, and binaries from GitHub /
filippo.io / dot.net / etc. All of these reach external mirrors and
CDNs that occasionally fail on transients that recover within seconds.
Without a wrapper, a single flaky lookup aborts the whole script via
`set -e` and the cycle wastes its remaining budget.

**Motivating failure modes.** Two examples:

1. A remote macOS UTM host (dnf transient DNS):

   ```
   Error: Error downloading packages:
     Curl error (6): Could not resolve hostname for
     https://cdn.amazonlinux.com/al2023/core/mirrors/.../mirror.list
     [Could not resolve host: cdn.amazonlinux.com]
   ```

2. A remote Windows Hyper-V host (GitHub edge 502):

   ```
   curl: (22) The requested URL returned error: 502
   ```

   from `curl -fsSLI https://github.com/PowerShell/PowerShell/releases/latest`.

In both cases adjacent cycles passed with the same code on the same
host. The flap lasted less than the package manager's own in-process
retry window (librepo) or curl's default no-retry behavior, so the
script failed even though the network was healthy seconds later.

The same pattern applies to apt: transient mirror flakes, DNS bounces
on first-boot DHCP, `Hash Sum mismatch` from a half-refreshed mirror
(transient, handled by `apt_retry`).

**Library.** All five retry wrappers live in
[automation/yuruna-retry.sh](../automation/yuruna-retry.sh) — single
source of truth. cloud-init's `write_files:` deploys it
(base64-encoded) to every supported guest at install time, landing at
`/usr/local/lib/yuruna/yuruna-retry.sh` before any provisioning
script runs. Guest scripts source it after their arch-detection block:

```
# --- REGION: https://yuruna.link/network#defining-yuruna-retry-lib
. /usr/local/lib/yuruna/yuruna-retry.sh
```

The library exports five functions:

| Function | Wraps | Notes |
|---|---|---|
| `apt_retry`  | `apt-get …` | Ubuntu 24/26 guests |
| `dnf_retry`  | `dnf …`     | Amazon Linux 2023 guests |
| `curl_retry` | `curl …`    | Any caller; prepends `--retry 3 --retry-connrefused --retry-delay 5` so curl handles transient HTTP 5xx + connection-refused in-process before the outer attempt loop fires. Deliberately NOT `--retry-all-errors`: that would also retry 4xx (auth failures, 404s), which are non-transient and only waste attempts. |
| `wget_try`   | `wget …`    | wget analogue of `curl_retry`: prepends `--tries=3 --waitretry=5 --retry-connrefused` for in-process transient handling and shares the transient/permanent gate below. |
| `pwsh_retry` | `sudo pwsh …` | Body on stdin (here-doc), piped to `sudo pwsh -NoProfile -Command -`. All pwsh streams (stdout, stderr, verbose, warning, information) appended to a caller-supplied log file under `/var/log/yuruna/` with a UTC-stamped per-attempt header. The log is the failure-collector handoff — see [`Defining Get-SystemDiagnostic`](definition.md#defining-get-systemdiagnostic), GUEST PROVISIONING section. Body must `throw` / `exit 1` on its own failure conditions (retry is driven by pwsh's exit code). Stdin pipe instead of a positional `-Command` arg avoids both the argv-length-cap class (32 K on Windows `CreateProcess`, `ARG_MAX` on Linux) and the quote-escaping pit. |

**Outer-loop behavior** (all five wrappers share `_yuruna_retry`):

1. Runs up to **5 attempts** (override via `YURUNA_RETRY_MAX_ATTEMPTS`).
2. Sleeps with **exponential backoff + equal jitter**: a random point
   in `[delay/2, delay]` rather than exactly `delay` (base 10 s, 20 s,
   40 s, 80 s; override via `YURUNA_RETRY_DELAY_SECONDS`), so parallel
   guests that failed in lock-step — a shared caching-proxy-service blip, a
   mirror 429 burst — don't all wake at the same instant and re-form
   the thundering herd that caused the failure. The jitter
   never exceeds the base delay, so the ~2.5-min worst-case total is
   unchanged.
3. Streams the wrapped command's stdout/stderr normally so the log
   shows what the wrapped tool is doing.
4. Prints `!! <name>: attempt N/5 failed (rc=…)` banners between
   attempts so the log makes the retry visible.
5. Returns the real exit code after the final attempt; `set -e` then
   aborts the script with a diagnosable failure.
6. **Transient/permanent gate** (`curl_retry` + `wget_try`): stops the
   ladder immediately on a deterministic **HTTP 404** (or other 4xx bar
   429) or a malformed URL, instead of burning all 5 attempts on
   something that cannot succeed. curl (exit 22) and wget (exit 8) both
   collapse every HTTP error to one exit code, so on that code the gate
   re-probes the status (a bounded, output-discarding GET through the
   same proxy env) to tell a permanent 4xx from a retryable one; `429`,
   `5xx`, timeouts, and network/SSL errors still retry. Conservative by
   design — any ambiguity retries, so a healthy fetch is never hardened
   into a failure. `YURUNA_RETRY_NO_TRANSIENT_GATE=1` restores
   retry-everything; `apt_retry`/`dnf_retry` keep retry-everything (they
   funnel every failure into one generic exit code, so a package-not-
   found gate would need stderr classification — not implemented).
7. **Structured attempt record.** Each failed attempt emits a
   machine-readable `YURUNA_RETRY {…}` line to stderr (`stack`, `label`,
   `attempt`, `maxAttempts`, `rc`, `permanent`). On the SSH verbs the
   host parses these into `retry_attempt` NDJSON events on the cycle
   stream; the host-side stacks (`Yuruna.Retry`, the sequence `retry`
   verb) emit the same `retry_attempt` / `retry_exhausted` events
   directly. See [Failure record schema](failure-schema.md).

For `curl_retry`, curl's own `--retry 3 --retry-connrefused` fires
first (sub-30 s for transient 5xx + ECONNREFUSED). Combined budget:
5 outer × 3 inner = 15 effective attempts — still bounded, sized for
a one-shot provisioning script under `set -euo pipefail`. curl's inner
`--retry` does not retry 4xx, and the transient gate (item 6) fails
fast on them, so a deterministic 404 costs one attempt, not the full
~2.5-min ladder.

**Call signature.** Generic — the wrapper takes the full command,
including the caller's `sudo` and any options:

```
apt_retry sudo apt-get update -y
apt_retry sudo apt-get install -y postgresql-18 postgresql-contrib-18

dnf_retry sudo dnf -y install libicu tar gzip
dnf_retry sudo dnf update -y

curl_retry -fsSL "https://example.com/release.tar.gz" -o /tmp/release.tar.gz
PS_TAG=$(curl_retry -fsSLI -o /dev/null -w '%{url_effective}' \
  "https://github.com/PowerShell/PowerShell/releases/latest")

pwsh_retry /var/log/yuruna/pwsh-yaml-install.log <<'PSEOF'
$ErrorActionPreference = 'Stop'
Install-Module -Name powershell-yaml -Scope AllUsers -Force -Verbose 4>&1
Import-Module powershell-yaml
$null = ConvertFrom-Yaml 'k: v'
PSEOF
```

`apt_retry` / `dnf_retry` / `curl_retry` share the same body and
exist only so the failure banner names the wrapped tool explicitly.
macOS guests use `softwareupdate` (Apple's CDN already retries
internally) and need no apt/dnf equivalent; `curl_retry` is
independent of OS and works anywhere the library is sourced.
`pwsh_retry` is the side-channel-logged variant for `sudo pwsh`
actions — see [`Why ubuntu/AL2023 guest update scripts wrap
Install-Module powershell-yaml with pwsh_retry?`](memory.md#why-ubuntu--al2023-guest-update-scripts-wrap-install-module-powershell-yaml-with-pwsh_retry).

`--retry-connrefused` is supported on every shipped guest OS
(present since curl 7.52, December 2016). Ubuntu 24/26, Amazon
Linux 2023, and macOS 26 all ship newer.

### Why the stall bound hoists timeout inside sudo and stays foreground

`_yuruna_retry` supports a per-attempt wall-clock bound
(`YURUNA_RETRY_STALL_TIMEOUT_SECONDS`, whole seconds; `0` = unbounded): an
HTTP transfer that stalls after response headers — or trickles too
slowly to trip the client's own connect/read-gap timeout — otherwise
hangs the attempt forever, and the retry loop never gets to retry on
a fresh connection (the stalled-transfer trap class: apt InRelease
fetches wedging mid-body behind a caching-proxy service). A malformed value
fails LOUD and unbounded, not silently unbounded — silence would leave
the operator believing a bound is active.

The bound mode is invariant across attempts: none | direct | sudo.
`timeout(1)` can only exec real commands, so shell-function attempts
(`pwsh_retry`'s helper) always run unbounded. When the command is a
plain `sudo <tool> ...`, the bound is hoisted INSIDE sudo so the
expiry TERM — and the unrelayable KILL backstop — land on the
privileged tool itself; signaling sudo from outside can reap sudo
while the root child survives, still holding e.g. the dpkg lock,
which would wedge every retry. The hoist is skipped when the word
after sudo is an option (it would be misread as an option of
timeout).

`--foreground` is load-bearing: without it timeout `setpgid()`s the
command into its own process group, which on a console/pty (these
scripts run on the guest console, and sudo's `use_pty` adds a pty of
its own) makes the command a BACKGROUND group of that terminal. The
first tty read or `tcsetattr` in a maintainer-script/hook then stops
the whole run with SIGTTIN/SIGTTOU — it freezes silently until the
expiry TERM+CONT wakes it to die, converting a healthy apt run into a
phantom 600 s "stall" (the background-pgrp tty-stop trap class). With
`--foreground` the command keeps the inherited foreground group; the
tradeoff — expiry signals only the direct child, not a group — is
what the sudo-hoist already assumes.

### Why apt and dnf attempts run unbounded by default

Package-manager attempts run UNBOUNDED by default (opt in via
`YURUNA_APT_STALL_TIMEOUT_SECONDS` / `YURUNA_DNF_STALL_TIMEOUT_SECONDS`, seconds). A
wall-clock bound here is attractive — a wedged mirror/proxy transfer
otherwise consumes the whole step budget as one silent hang — but
wrapping apt in `timeout(1)` is the wrapped-apt teardown-hang trap
class: with the wrapper as apt's parent, every apt run that performs
REAL dpkg work (upgrade with triggers, removal, install) has been
observed to block silently at end-of-transaction AFTER dpkg fully
commits (~0 CPU, no sockets, dpkg gone, locks held) until the bound
kills it, while a control guest running the identical transaction
unwrapped completes in seconds, every time. Until that interaction is
root-caused (suspects: apt's dpkg-pty EOF drain or its hook-child
wait under a `timeout(1)` parent), the safe default is the plain
unwrapped invocation; the mirror-stall exposure is instead bounded at
the transfer layer (curl/wget/git low-speed aborts, apt's own
`Acquire::http::Timeout`, and the caching-proxy service's `read_timeout`).

### Bounding apt-get update without bounding dpkg

`apt-get update` is the one package-manager call the guest update scripts DO
bound, and the reason is the same one that keeps every other call unbounded: it
fetches indexes and runs no dpkg transaction. A wall-clock kill there costs a
re-fetch rather than a half-applied package state, so the retry ladder can
absorb it and the teardown-hang trap class that rules out wrapping the
transactional calls cannot apply.

**The drop-in.** `/etc/apt/apt.conf.d/99yuruna-acquire` bounds how long apt will
sit on a single index fetch. apt's own `Acquire::http::Timeout` covers a silent
socket, not a mirror that answers and then trickles, so a degraded origin can
hold `apt-get update` open for as long as the step allows — which is how one
stalled `InRelease` consumed an entire 30-minute step budget with the guest at
0% CPU and nothing in the log after the last `Get:` line. The drop-in makes apt
give up and hand the failure to the retry ladder while the step still has time
to report it.

It is written on every cycle rather than relied on from the autoinstall seed,
because the guest update script must not depend on the installer having applied
the seed's apt block. The `99-` prefix sorts after curtin's own drop-ins, and
none of these keys overlap the proxy drop-in curtin writes.

**The stall bound.** 300s is roughly five times a healthy full update against a
cold cache; a mirror that has not finished by then is degraded, and every
further second is taken from the steps after this one. The bound is requested
only when the sourced retry lib advertises the safe wrapper (`timeout
--foreground`, hoisted inside `sudo`); against an older baked lib the expansion
is empty and the call falls back to unbounded rather than to a wrapper with the
background-pgrp tty-stop trap in it.

**The outer cap.** The retry ladder is capped at 2 attempts for this one call
because it is not the only retry in play: `Acquire::Retries "2"` already
re-fetches each index inside a single run, so the default 5 outer attempts would
mean up to fifteen tries per index. Cost is what rules that out rather than the
redundancy — 5 bounded attempts plus the doubling backoff is ~1575-1650s of an
1800s step, leaving nothing for `dist-upgrade` and the clones that follow, so a
persistent stall would still fail the step after spending the whole budget. Two
attempts cost ~610s and leave most of it, and a stall that outlasts both is an
outage the next cycle should retry rather than something to keep hammering here.

Both settings are handed back to their defaults immediately afterwards, because
everything below that point runs real dpkg transactions.

---

## Guest dependency version pins

### Defining yuruna versions pins

[automation/yuruna-versions.sh](../automation/yuruna-versions.sh) is the
single source of truth for the pinned upstream dependency versions the guest
provisioning scripts install. cloud-init deploys it (base64) to
`/usr/local/lib/yuruna/` alongside `yuruna-retry.sh`, and the retry library
sources it — so every guest script that sources the retry library also sees
the pins. Guest scripts reference the exported variables and **never** the version
literals.

| Variable | Pins | Consumed by |
|---|---|---|
| `YURUNA_K8S_MINOR` | Kubernetes apt-repo minor track (`pkgs.k8s.io/core:/stable:/v<minor>/deb`) | Ubuntu `*.k8s.sh` |
| `YURUNA_OPENTOFU_VERSION` | OpenTofu release for the standalone installer's `--opentofu-version` | guest OpenTofu install |
| `YURUNA_HELM_VERSION` | Helm release, passed to the installer as `DESIRED_VERSION=v<x>` | Ubuntu `*.k8s.sh` |
| `YURUNA_NVM_VERSION` | nvm release tag (`nvm-sh/nvm`) the Ubuntu guests fetch `install.sh` from | Ubuntu `*.n8n.sh` / `*.openclaw.sh` |
| `YURUNA_NODE_MAJOR` | Node.js major (`nvm install <major>`; nodesource `setup_<major>.x` on AL2023) | Ubuntu + AL2023 Node installs |

**Why pin at all.** Bump `YURUNA_K8S_MINOR` only across a minor your
kubeadm/kubelet/kubectl are validated on. `YURUNA_OPENTOFU_VERSION` exists so
the standalone installer never queries the rate-limited GitHub releases API for
"latest" — an unauthenticated `api.github.com` call that starts returning 403
once many guests share one NAT egress IP, which makes the fallback
non-deterministic exactly when a pool is busiest.

`YURUNA_HELM_VERSION` carries a second constraint: the guests must fetch
upstream's **`get-helm-4`** installer, not `get-helm-3`. The v3 script resolves
its default from `get.helm.sh/helm3-latest-version`, so it can only ever land a
3.x binary — a guest provisioned with it can never satisfy the Helm requirement
in `Yuruna.Requirement.yml`, however that requirement is bumped. Passing
`DESIRED_VERSION=v<x>` both pins the release (the installer verifies the tarball
checksum) and keeps the guest off the same unauthenticated "latest" lookup.

**Format is load-bearing.** Keep the file POSIX-simple — one `export KEY=value`
per line, value unquoted and free of spaces — so
[automation/Check-DependencyVersion.ps1](../automation/Check-DependencyVersion.ps1)
can parse it with a line regex instead of sourcing a shell. Values are
`export`ed so they survive into the `bash << 'EOF'` heredocs the nvm/node guest
scripts use; a child shell only inherits exported state.

**To bump a dependency.** Run `Check-DependencyVersion.ps1`; when it reports a
newer stable release upstream, edit the matching number here.

---

## Guest network diagnostics and DHCP lease release

### Defining deterministic guest MAC addresses

Every hypervisor hands a freshly-built VM a **random** MAC, and a Yuruna lab
rebuilds its guests constantly. On a bridged network that is a slow leak: each
build asks the DHCP server for a *new* lease while the old one is still held by a
guest that no longer exists. A pool serving one `/24` drains over hours until it
has nothing left, and guests then boot with **no IPv4 at all** — `wget` fails,
the guest script exits non-zero, and cycles fail on unrelated hosts and
hypervisors at once, with no shared cause visible from any single one of them.

The fix is to stop asking for new leases. `Get-YurunaGuestMacAddress`
([automation/Yuruna.Common.psm1](../automation/Yuruna.Common.psm1)) derives a MAC
from **identity instead of randomness**, so the same host rebuilding the same
guest slot presents the same address and the server hands back the lease it
already holds. Every `New-VM.ps1` on all three host types pins its NIC to it.

```
42 : HH:HH : VV:VV:VV
│    │       └─ SHA-256(host seed + "|" + VM name)
│    └───────── SHA-256(host seed)
└────────────── Yuruna's marker
```

* **`42`** is not decorative. `0x42` is `0100 0010`: the locally-administered bit
  (`0x02`) is set and the multicast bit (`0x01`) is clear, so it is a valid
  unicast LAA octet needing no correction — and it is the same `42` a Yuruna
  `hostId` carries, so an operator reading a DHCP lease table can tell Yuruna's
  addresses from everything else on the LAN at a glance.
* **The host pair is constant for every guest on one host**, so leases visibly
  group by machine in that same table.
* **The VM bytes hash the host in as well**, not the name alone. Guest slots are
  named identically on every host — `test-guest.ubuntu.server.24-01` exists
  everywhere — so hashing the name by itself would leave the whole address resting
  on the two host bytes, and two hosts landing on the same pair would then collide
  on every guest they share. Mixing the host in restores the full 40 bits.

The host seed is `runtime/host.uuid`, which survives reboots and the reimage
reclaim, so a rebuilt host keeps its guests' addresses. A host that has never
completed a cycle falls back to its hostname — deliberately something stable, never
a random value, which would reintroduce exactly the churn this removes.

**The name to key on is the guest's, not the VM's.** No guest keeps the name it was
built with: every one is built as the per-kind slot
(`test-guest.ubuntu.server.24-01`) and promoted to its real name when its baseline is
snapshotted — sometimes twice, through an intermediate tier. The address must not
move at either step, so it is derived at build time from the identity the guest keeps
for its whole life: its cloud-init hostname, which the sequence declares and every
`New-VM.ps1` that accepts `-Hostname` passes to `Get-YurunaGuestMacAddress` in place
of the VM name. Promotion is then a pure metadata change and the NIC is never touched.

Keying on the VM name instead is not a cosmetic mismatch. The guest is on the
network while it is built, and what it builds records the address it had: a
`kubeadm` control plane writes it into the apiserver's advertise address, etcd's
listen and peer URLs, the certificate SANs and every kubeconfig. Re-key the NIC after
that and the guest reboots onto a different lease, with a control plane that answers
at an address no longer assigned anywhere on the segment — `no route to host`, from a
cluster whose snapshot is deterministic, so every retry reproduces it exactly.

**A rename still releases the name it vacates.** A guest whose sequence declares no
hostname is pinned to the slot, and *that* address must not stay behind: it belongs
to a name the VM no longer answers to, so the next build of the slot asks for one
already in use. `virt-install` refuses that build outright (`in use by another
virtual machine`); UTM and Hyper-V accept it and put two live NICs with one address
on one segment, which surfaces later as guests answering for each other and reads as
a network fault rather than a naming one. So `Rename-VM` asks
`Test-YurunaGuestMacMatchesName` whether the NIC is still on the outgoing name's
address before it rewrites anything — libvirt in the same `define` that relocates the
disks, UTM while the app is quit (alongside the VNC display, which is frozen at build
time for the same reason), Hyper-V with `Set-VMNetworkAdapter` on the new name. An
address that is not the outgoing name's belongs to the guest, and is left alone.

The pool footprint this settles at is one address per *guest identity* a host has
built, not one per slot: two guests built one after another in the same slot now hold
two leases rather than passing one between them. That is the point — an address the
next guest can take is an address the previous guest cannot be found at — and it is
still bounded and still reclaimed, because the identities are declared in the
sequences and a rebuild of one presents the same address again.

### Defining guest DHCP client identity

A stable MAC is only half of it. systemd-networkd identifies itself to the DHCP
server with a DUID derived from `/etc/machine-id`, and NetworkManager with an
RFC 4361 client-id from the same source — and cloud-init *writes* machine-id on
first boot and restarts networking. The guest therefore re-requests under an
identity it did not have moments earlier, the server sees a new client, and leases
it a **second** address. Every build drew twice from the pool.

Every Linux guest Yuruna builds now pins its client identity to its MAC, by the
route its installer allows:

| Guest | How |
|---|---|
| Extension services, caching proxy | `dhcp-identifier: mac` in [guest-dhcp.network-config](../host/vmconfig/guest-dhcp.network-config), shipped on the cidata seed |
| `ubuntu.server.24` / `.26` | an autoinstall late-command patches the installed netplan in place — the installer owns netplan, and a second document matching the same interface is a conflict it reports at boot |
| `amazon.linux.2023` | a `runcmd` sets `ipv4.dhcp-client-id mac` on each NetworkManager profile |

The subiquity guests are patched rather than given an autoinstall `network:` key
on purpose: that key governs networking **during** the install too, where a wrong
match strands the installer with no route. Not a risk worth taking for one line.

### Defining lease release on teardown

**The guest returns its own lease.** `yuruna-dhcp-release.service`, installed by
the `ubuntu.server` and `amazon.linux.2023` seeds, calls `network_release`
(below) on the way down. Four lines carry it, and each fails silently if it is
wrong — the unit stays enabled, the shutdown stays clean, and the address simply
never comes back:

| Line | Why |
|---|---|
| `ExecStop=` (not `ExecStart=`) | the release belongs at stop; on start it drops the lease the harness is about to SSH to |
| `RemainAfterExit=yes` | a `Type=oneshot` goes inactive when `ExecStart` returns, and systemd runs no `ExecStop` for an inactive unit |
| `After=network.target` | shutdown reverses start order, so this is the only reason the stop happens while there is still a network to release onto |
| `TimeoutStopSec=15` | a guest wedged inside the unit is still a wedged guest, and must not stall the sweep |

Doing it from inside removes the three things a host-side release needs and
cannot always have: a login user, an address that still resolves, and a guest
that is still running. The guests that hold leases longest have none of them at
the only moment they could be asked — they are **stopped while running and
deleted while off**, so a host-side release has no point in their lifecycle at
which to happen.

`network_release` elevates through `_yuruna_net_sudo`, which is a no-op when
already root: the unit runs as root at a point where the authentication stack
`sudo` consults is being torn down, and a bare `sudo` there can fail on a
machine where it works perfectly from a login shell.

**The SSH path remains, for the kills the guest never sees.** Teardown is a hard
power-off on the paths that discard the disk, and a guest that is wedged or
already gone runs no shutdown unit. `Invoke-GuestDhcpRelease`
([Test.VMUtility.psm1](../test/modules/Test.VMUtility.psm1)) asks over SSH
immediately before the kill, calling the same `network_release` by path rather
than reimplementing it, so there stays one answer to "how does a guest give a
lease back". It is strictly best-effort and tightly bounded: one short attempt,
no address wait, no retry, every failure swallowed.

Neither path is what keeps the pool from draining — see
[What an unpinned host costs the whole lab](#what-an-unpinned-host-costs-the-whole-lab)
for the bound that does. Release shortens how long an abandoned address stays
abandoned; it cannot reduce how many are abandoned, because it can always miss.


### Defining yuruna network lib

The guest network helper lives in
[automation/yuruna-network.sh](../automation/yuruna-network.sh) — the
network-specific sibling of the retry library above. cloud-init deploys
it to `/usr/local/lib/yuruna/yuruna-network.sh` at install time. It
targets Ubuntu Server and Amazon Linux 2023, which both ship `ip` and a
systemd-networkd DHCP client. The file is `source`d by
[fetch-and-execute.sh](../automation/fetch-and-execute.sh) (for
`network_diag`, so a failing guest step can attach that diagnostic to
its failure output) and invoked by the `networkRelease` sequence action
(for `network_release`).

### Defining network diag

`network_diag` prints a connectivity diagnostic for the guest:
per-interface addresses, IPv4 and IPv6-default routes, and the
`/etc/resolv.conf` nameservers. It then walks the real (non-loopback,
non-virtual) interfaces and classifies each one.

**Link down.** An interface whose `operstate` is not `up` and whose
`carrier` does not read `1` is reported, not skipped. Reading
`/sys/class/net/<if>/carrier` on a down interface returns `EINVAL`, so
the value comes back empty and the report names both raw values
(`operstate=down,carrier=none`). A down link never reaches DHCP at all,
so lease-pool questions do not apply — the causes are host-side:
the virtual switch this vNIC is attached to has no live uplink, the
cable is out, or the port is administratively down. This is the loudest
verdict and is printed first, because it is the true cause whenever it
is present.

**Carrier up, no IPv4.** A carrier-up interface with neither a static
address nor a DHCP lease usually means **DHCP pool exhaustion**: on a
bridged hypervisor the guest competes with every other LAN client for
the router's finite lease pool, and a fast-booting guest that loses the
lease race comes up with only an IPv6 SLAAC address and no IPv4.
IPv6-via-RA needs no DHCP server, so its presence does not clear the
flag. Other causes the banner names: the DHCP server is down, a
VLAN/cabling fault, or the link is not forwarding yet.

**All clear** is claimed only when at least one interface was examined
and every one holds an IPv4 address. A walk that examined nothing
prints "no non-loopback interface is carrier-up" instead — that is a
finding, not a pass. The distinction is
load-bearing: "all carrier-up interfaces hold an IPv4 address" is
vacuously true on a guest whose only interface is DOWN. Both
post-mortem routes (SSH into the guest, and the host status service)
need exactly the network such a guest does not have, so this console
capture is its only record and its correctness carries
disproportionate weight.

Output is bounded: the link-down verdict reports the total count and
names only the first few interfaces, so the block stays a fixed number
of lines however many interfaces exist. That matters because the
diagnostic is printed immediately before the `NONZERO SCRIPT EXIT:`
marker the host's OCR watches for, and an unbounded block can push the
marker off the captured frame — turning a classified failure into an
unclassified timeout. For the same reason no message in this file may
contain the words "fetch" or "execute": they fuzzy-match the echoed
command line and would close a healthy run's OCR wait early.

`YURUNA_NET_SYSFS` overrides the sysfs root the walk reads (default
`/sys/class/net`) so the function can be driven against a fixture tree
in tests; production behavior with the variable unset is unchanged. It
covers only the sysfs reads — the `ip` invocations are live.

### Defining network release

`network_release` releases DHCP leases (and any other transient network
resources) so the address returns to the pool immediately instead of
lingering until lease expiry. It runs at end-of-sequence teardown so a
churning test fleet does not exhaust a shared LAN's DHCP pool. It is
best-effort across the DHCP clients a guest may run — a client that is
not installed is skipped:

- **systemd-networkd** (Ubuntu + Amazon Linux 2023): `networkctl down`
  per managed link. `SendRelease` defaults to yes, so bringing a link
  down emits a `DHCPRELEASE` for its lease.
- **classic dhclient** stacks: `dhclient -r` releases all held leases.
- **dhcpcd** stacks: `dhcpcd -k`.

### Defining yuruna network cli

The file is dual-use: `source` it to get the functions, or run it
directly with a verb so the `networkRelease` sequence action can invoke
it by path on the guest console
(`bash /usr/local/lib/yuruna/yuruna-network.sh release`). The
entrypoint dispatches `diag` → `network_diag` and `release` →
`network_release`; any other argument prints usage and exits 2.

## Guest-update network convergence before handoff

The Linux guest-update scripts wait for the network to settle before
signaling "script done". Package transactions (apt/dnf) that touch the
network stack, kernel, or systemd can bounce the primary connection at
the tail of the transaction, briefly dropping the DHCP lease. The
harness's next sequence step is `saveSystemDiagnostic`, which opens the
FIRST host->guest SSH of the run; if it fires during the bounce window
the host's neighbor entry is stale (the Hyper-V External vSwitch
ARP-discovery trap; UTM has the vmnet analogue) and SSH times out for
the full 180 s `Wait-SshReady` budget.

The probe MUST match whichever manager owns the link: server
spins default to systemd-networkd (where `nm-online` is absent), while
NetworkManager spins ship `nm-online`. A probe keyed on the wrong
manager silently no-ops — skipping the settle entirely — or blocks its
full timeout for nothing, so the scripts branch on the active manager.
Every branch is capped at 30 s so a broken stack cannot hang the cycle,
and non-zero exits are swallowed so `set -e` does not abort.

## Caching-proxy service CA cert rc60 gate

The Ubuntu `New-VM.ps1` scripts fetch the caching-proxy-service CA certificate on
the host and base64-embed it in the autoinstall seed
(`CA_CERT_BASE64_PLACEHOLDER`). The installer's late-commands write the
cert before any HTTPS apt fetch, so SSL-bump caching works from the first
install request.

An empty `$CaCertBase64` is NOT a harmless no-op: the seed still routes
the guest's HTTPS through the bump (`:3129`) and locks direct `:443`
egress, so a CA-less guest fails every HTTPS request with curl rc=60
("self-signed certificate in certificate chain"). That is why the CA
fetch is retried under the shared capped-backoff policy — one blip
against a slow or flapping caching-proxy service must not strand the guest
without the CA. See the memory capture
`feedback_sslbump_rc60_untrusted_chain_and_ca_gate_trap` for the incident
class.

A finite host-side retry budget can still be outlasted by a longer proxy
flap, so the empty-CA case is recovered at two further layers without
relaxing egress (`project_sslbump_ca_gating_durable_fix`):

- **Host-side fallback.** `Get-CachingProxyServiceCaCertBase64` (in
  `Test.CachingProxyService.psm1`, shared by all six ubuntu `New-VM.ps1`) persists
  each successfully fetched CA into the `yuruna-caching-proxy-service.yml` state
  file, keyed by cache host, and reuses it when a later live fetch flaps —
  so a guest provisioned during a flap can still bake a valid CA. When even that comes up empty (retry
  budget exhausted, nothing persisted), the `New-VM` scripts warn that the
  guest boots CA-less and will self-heal at update time; plain-HTTP caching
  via `:3128` is unaffected by the missing CA — only bumped `:3129` HTTPS
  needs the trust anchor.
- **Guest CA self-heal.** Before the first bumped HTTPS, the ubuntu update
  scripts detect an untrusted bump and re-fetch the CA from the host status
  server's `/ca.crt` endpoint over the RFC1918-permitted plain-HTTP path
  (`wget --no-proxy`), then `update-ca-certificates` and re-probe. The
  endpoint **live-reads the current cache** (never a stale cached CA),
  falling back to the persisted CA only when the cache is unreachable, and
  `404`s when neither resolves so the guest fails with a clear diagnostic
  rather than a silent pass. By update time the cache has usually recovered
  (apt over `:3128` already succeeds), so this is the layer that turns the
  flap-during-provisioning failure into a pass. Installing the CA
  does not relax egress: HTTPS still flows through the auditable bump; the
  self-heal only supplies the trust anchor the bump already expects. The
  guest side is best-effort and non-fatal: a missing `host.env`, an
  unreachable host, or an empty body leaves the guest in the original
  rc=60 state with a clear diagnostic, never aborting the update run.

On macOS UTM the fetch has an extra reason to run host-side: guests on VZ
shared-NAT cannot reach the cache VM directly, but the host can. The UTM
scripts must also resolve **which IP** serves the CA:

- An **external cache** (`YURUNA_CACHING_PROXY_SERVICE_IP` set to a valid IP) wins:
  `$CachingProxyServiceUrl` already points at the remote IP (no VZ-gateway
  rewrite), and the remote cache image is identical to the local one — the
  same Apache on `:80` serves `/yuruna-squid-ca.crt`. The
  `yuruna-caching-proxy-service.yml` state file is not updated for external caches,
  so the IP is read straight from the environment variable.
- Otherwise the persisted state file's `ipAddress` is used when it parses
  as an IP.
- When a proxy URL is set but neither source yields an IP, the script warns
  instead of silently skipping the fetch; the guest boots CA-less and
  relies on the update-time self-heal above.

## UTM cache-VM bridged discovery

### Defining utm cache vm bridged discovery

The macOS UTM ubuntu `New-VM.ps1` scripts detect the caching-proxy service and
inject its proxy URL into the autoinstall seed when available. The cache
VM is bridged to the host's physical NIC
(`VZBridgedNetworkDeviceAttachment` in `config.plist.template`), so it
carries its own LAN DHCP IP — e.g. `http://192.168.7.150:3128`. Install
VMs on shared NAT reach that LAN IP through VMnet's outbound NAT (the
same path they use to reach Ubuntu mirrors), so no host-side TCP
forwarder layer is needed. Discovery delegates to
`Test-CachingProxyServiceAvailable`, which owns the (state-file fast path ->
LAN /24 scan -> state refresh) logic.

Severity policy:

- `Test-CachingProxyServiceAvailable` returns a URL -> inject it.
- `utmctl` sees the cache VM started but no `:3128` answer on the LAN ->
  ERROR, exit 1 (the cache came up but is not on the LAN; a bridge
  interface or DHCP problem).
- Cache VM not registered / not started -> WARNING, proceed direct.

## Guest-to-guest addressing on KVM

### Defining the guest-to-guest rail

A second, stable address per guest on libvirt's NAT network, for guests that
have to reach **each other**.

The problem it solves is narrow and worth stating precisely. Guests are bridged
onto the site LAN so remote clients can reach them, which means their addresses
come from a DHCP server this lab does not control — and on a host with a short
lease, a guest that another guest is talking to can move mid-scenario. The
workload's answer today is for each guest to publish its address to the host and
for its peers to read that file back, which works only as often as the
publishing does.

libvirt's NAT network is the one piece of addressing this host owns outright:
`virbr0` holds a static gateway no lease can move, and a reservation keyed on
MAC pins both an address and a *name* that its dnsmasq answers for. So a guest
given a second NIC there has a coordinate for its peers that does not depend on
the site router, while its bridged NIC keeps carrying everything else.

What this deliberately does **not** do: move host-to-guest traffic. The harness
keeps reaching guests over the churning LAN, because surviving that is the
property this lab exists to prove, and routing around it would retire the test.

KVM-only by construction. The same workload runs on macOS/UTM and Hyper-V hosts
that have no libvirt network at all, so every consumer must treat a rail address
as an optimisation that may be absent, never as a dependency.

### Why the rail is not wired up

Nothing calls `host/ubuntu.kvm/modules/Yuruna.GuestRail.psm1`. It is kept for
the derivation and its tests, and wiring it back in as it stands would break VM
creation on the second guest of every cycle — which it did, twice, before being
disconnected.

The defect is in `Get-GuestRailAddress` and not in the plumbing around it: it
keys on the VM name, and guests here are *created* under a shared transient name
(`test-guest.ubuntu.server.24-01`) and renamed later by `saveDiskSnapshot`. So
every guest in a cycle derives the same MAC, the first one keeps it through the
rename, and libvirt refuses to define the second. The same assumption made the
reservation useless even when it succeeded: it was filed under the transient
name, while the peers that would resolve it ask for the final one.

A working version must key on an identity that survives a rename and is unique
per guest — the domain UUID, or a MAC allocated at creation and registered under
the final name once `saveDiskSnapshot` assigns it. Until then this stays
disconnected.

## Cache-VM seed host binding

The caching-proxy-service `New-VM.ps1` scripts on all three drivers
bake the Yuruna host's (status service) IP and port into the seed so
the cache VM's cloud-init build block fetches collector/parser source
from the LOCAL host working tree (`/yuruna-repo/`) instead of public
GitHub — a rebuild never waits on the private->public mirror.
`$env:YURUNA_GUEST_REACHABLE_HOST_IP` overrides the resolved host IP
on ubuntu.kvm and macos.utm (windows.hyper-v has no override); empty
values make the build fall back to GitHub.
`Start-CachingProxyServiceVM.ps1` ensures the status service the baked
address points at is running.

The reachable host address and the network the cache VM attaches to
are a topology-aware matched pair — the address only works from the
network it was derived for — so each driver resolves the two together:

- **ubuntu.kvm**: `Resolve-GuestHostBinding` resolves the libvirt
  network and the host address at once — the same helper every install
  guest uses, so the cache and the guests always land on the same
  network. On the bridged `yuruna-external` network the cache VM gets
  a LAN IP and reaches the host at its LAN address; on the NAT
  `default` network it reaches the host at the libvirt gateway
  (`192.168.122.1`).
- **macos.utm**: the host address mirrors the NetworkMode decision made
  in the same script: a wired (Ethernet) default route makes the cache
  VM bridged (LAN IP), reaching the host at its LAN address
  (`Get-BestHostIp`); a Wi-Fi default route makes it UTM Shared NAT,
  reaching the host at the VZ gateway
  (`Get-GuestReachableHostIp` = `192.168.64.1`).
- **windows.hyper-v**: `Get-GuestReachableHostIp -SwitchName` derives
  the host address from the vSwitch resolved earlier in the script
  (Default Switch = the `172.x` NAT gateway; External vSwitch = the
  host's LAN IP).

The matched pair is what makes the Hyper-V address sources
**switch-qualified** rather than best-effort.
`Wait-ExternalSwitchHostIpv4` prefers the `vEthernet (<switch>)`
address; its fallback source — the adapter carrying the host's IPv4
default route — is accepted only when that adapter belongs to the same
topology as the guest, i.e. it *is* `vEthernet (<switch>)`, or it is
the switch's own bound physical NIC (the `-AllowManagementOS:$false`
shape, where the host legitimately keeps its address on the bridged NIC
and the guest lands on that same L2 segment). A default-route address
on any other segment is not a degraded answer but a wrong one, in a way
the guest can only discover after its seed has been burned: the address
resolves on the host, so nothing fails host-side, while the guest dials
an address it holds no route to. An
unqualified match is rejected and the wait falls through to its
deadline rather than returning.

Returning nothing is the correct answer here, and callers are built for
it: every seed builder flattens a `$null` to an empty string and the
guest falls back to GitHub. When the management vNIC is confirmed
absent — no `Get-VMNetworkAdapter -ManagementOS -SwitchName` result at
all — the wait gives up on the first iteration instead of polling for
an adapter that cannot appear; the poll is reserved for the transient
it was written for, an adapter that exists but has not finished DHCP.

The same rule governs a **third** address, and it is the one that gets
missed: the `networkStorage` server (`ypool-nas` / `ystash-nas`). That
name is resolved on the HOST, so on a host running local lab storage it
resolves to the loopback address — correct for the host's own mount,
and meaningless inside a guest, which would dial its own loopback and
fail with `cifs_mount -111`. It must be derived for the guest's
network like the other two, not inherited from the host's resolver:
`Get-YurunaPoolSeedValue` / `Get-YurunaStashSeedValue`
(`test/modules/Test.PoolStorage.psm1`) substitute the guest-reachable
host address whenever the resolved one is loopback or link-local, and
the caching-proxy's `yuruna-config-fetch.sh` does the equivalent in the
guest for the address the config service hands it at runtime.

On **macos.utm** the mode is resolved once per build by
`Resolve-UtmNetworkMode` and rendered into the bundle's
`config.plist` (`__NETWORK_MODE__`), so the plist and the baked
addresses cannot disagree. A plist hardcoding `Bridged` while its
`New-VM.ps1` branches on `Test-MacUplinkNotBridgeable` yields, on a
Wi-Fi host, a VM bridged onto an uplink that vmnet cannot bridge (no
DHCP lease, ever) with the VZ gateway baked in as the host address. Stash
and pool-control are therefore Shared on Wi-Fi, with `Add-PortMap`
publishing them to the LAN through the host — as is the download-agent
service. No choice of port is arbitrary: stash takes `:2222` because the
Mac's own sshd owns `:22`; pool-control takes `:8081` because the
caching-proxy already forwards `:80` for its CA-cert endpoint —
reusing it would publish the cache at the URL the
pool-control bring-up prints; and the download-agent service takes
`:8082`, the next free port clear of all three. The allocation is
therefore fixed per service rather than picked at run time:

| Service | Host port on a Shared-NAT Mac | Guest port |
|---|---|---|
| caching-proxy service | `80` (plus its own squid/dashboard ports) | 80 |
| stash service | `2222` | 22 |
| pool-control service | `8081` | 80 |
| download-agent service | `8082` | 80 |

Because the beacon's announce is derived from the connection's source IP
— NAT-internal, and unroutable from any peer — the download-agent
service's **marker** carries the published endpoint instead:
`downloadAgentServiceBaseUrl` is written as
`http://<mac-lan-ip>:8082/` on a Shared-NAT bundle, and as the VM's own
address on a bridged one. A Shared-NAT Mac is still a reduced-value
placement for the agent; prefer a bridged host.

## Registry rate limits disguised as 400

### Defining registry rate limit 400

Workload scripts that `docker run` a local registry container detect
upstream pull throttling in the failure output before deciding whether
to retry. Two shapes must both be recognized:

- **Docker Hub** documents its throttle responses: the strings
  `pull rate limit`, `toomanyrequests`, and `429 Too Many Requests`.
- **AWS ECR Public** returns **400 Bad Request** — not 429 — when its
  anonymous-pull quota is exhausted, so a plain 429 match misses it.
  The detector pairs `400 Bad Request` with the `public.ecr.aws` host
  substring (in either order) to avoid treating every 400 as a
  throttle.

A rate limit is keyed to the egress IP's quota window and will not
clear on a 10–30 s retry, so the scripts surface operator guidance
(wait, authenticate the pull-through proxy, bake the image into the
guest base, or check the caching-proxy service's zot endpoint) and exit
immediately instead of burning the remaining retry budget on a
foregone conclusion.

## Apt signing-key fingerprint verification

The Ubuntu guest provisioning scripts (`*.k8s.sh`, `*.code.sh`) fetch
third-party apt signing keys — Docker
(`download.docker.com/linux/ubuntu/gpg`), Kubernetes
(`pkgs.k8s.io/.../Release.key`), and Microsoft
(`packages.microsoft.com/keys/microsoft.asc`) — over the guest's
SSL-bump caching-proxy service, which is a **trust boundary**: a tampering proxy
or CDN could otherwise land an attacker key in apt's trust store.
`_yuruna_verify_key_fpr` verifies every downloaded key against a pinned
allow-set of PRIMARY-key fingerprints before it is trusted:

- Call contract: arg1 is the key file; the remaining args are the
  ALLOWED primary fingerprints, and the FIRST of those is also REQUIRED
  to be present in the key file.
- Only **primary-key** fingerprints are checked, so a vendor rotating a
  signing *subkey* under a stable primary stays trusted without a pin
  update.
- **Fail-closed**: an unreadable key file, any fingerprint outside the
  allow-set, or a missing required fingerprint returns non-zero, and the
  call sites abort the script (`NONZERO SCRIPT EXIT: ... fingerprint
  mismatch`) rather than installing the key.
- The helper mirrors `verify_key_fingerprints` in
  [install/ubuntu.kvm.sh](../install/ubuntu.kvm.sh); keep the two in
  sync when the pinning scheme changes.

## Helm installer fetch

The Ubuntu `*.k8s.sh` scripts install Helm via upstream's **`get-helm-4`**
installer, never `get-helm-3`, passing
`DESIRED_VERSION=v$YURUNA_HELM_VERSION` — see
[`Defining yuruna versions pins`](#defining-yuruna-versions-pins) for why
the v3 script and the unauthenticated "latest" lookup are both ruled out.

The installer downloads the binary with its own un-retried curl/wget, so
a single transient blip leaves helm uninstalled. The scripts therefore
capture the installer script once with `curl_retry`, run it under
`_yuruna_retry` (same capped backoff as every other fetch), and then
verify the binary actually landed: a swallowed failure here otherwise
surfaces far away as a `helm: not recognized` abort in the k8s.website
workload.

## Why Hyper-V never bridges Wi-Fi or USB uplinks

`Get-OrCreateYurunaExternalSwitch`
(`host/windows.hyper-v/modules/Yuruna.Host.psm1`) opens with a
not-bridgeable-uplink divert that mirrors macos.utm's Shared-vs-Bridged
choice keyed on `Test-MacUplinkNotBridgeable`. An External vSwitch
bridges the guest MAC onto the uplink, and Wi-Fi (802.11) and USB
Ethernet adapters both refuse to carry that MAC — so when
`Test-WindowsUplinkNotBridgeable` reports such an uplink the function
never bridges: it returns `$null` and the caller falls back to the
built-in Default Switch (NAT + DHCP).

The divert supersedes an already-present External switch only when that
switch is the one the check actually looked at.
`Test-WindowsUplinkNotBridgeable` resolves the NIC behind the host's
IPv4 **default route** (following a `vEthernet (<switch>)` back to the
switch's physical NIC when the route rides one), so it answers "is the
uplink the host is currently reachable through bridgeable?" — not "is
every External switch on this host bridgeable?". On a host whose
default route rides a wired NIC the divert correctly reports `$false`
and control reaches the reuse branch, even when the switch about to be
reused is bound to a Wi-Fi/USB adapter, to a NIC that no longer exists,
or to nothing at all. A stale switch on a non-bridgeable uplink has a
dead port (its vEthernet sits at APIPA) and would strand guests with
eth0 DOWN; catching that is the reuse validation below, not this
divert. When either path declines to bridge, cache export to the LAN
rides host port-forwarders (`Test-CacheVmOnYurunaExternalSwitch` ->
`$false` -> `netsh portproxy`), exactly as macOS does over Wi-Fi.

The divert logs Verbose, not Warning: on a Wi-Fi/USB-uplink host this
is the permanent steady state, not an anomaly, and it is re-evaluated
once per VM creation — a warning would repeat for every guest of every
cycle while asking the operator to do nothing.
That severity policy is specific to the divert and does **not** carry
over to the reuse validation below: a wired host whose External switch
lost its uplink is an anomaly an operator has to act on, so it warns.

## Why a reused External vSwitch is validated before it is handed out

A Hyper-V vSwitch object outlives its uplink binding across a host
reboot. `Get-VMSwitch -Name 'Yuruna-External'` can return a switch with
`SwitchType 'External'` and `AllowManagementOS $true` while the bridge
behind it forwards nothing — the `vEthernet (Yuruna-External)` adapter
is gone, the host's IPv4 sits directly on the bare physical NIC, and
every guest attached to that switch boots with eth0 DOWN. The object's
survival is therefore no evidence that the bridge works, and reusing a
switch on existence alone hands every guest of every
subsequent cycle a dead port. `Get-OrCreateYurunaExternalSwitch`
classifies a switch before it returns its name.

**The verdicts.** `Test-YurunaExternalSwitchUplink` is driver-private
to
[`host/windows.hyper-v/modules/Yuruna.Host.psm1`](../host/windows.hyper-v/modules/Yuruna.Host.psm1)
(callers outside that module resolve it through `Get-Command` and treat
its absence as `unknown`). It returns exactly one string:

| Verdict | Meaning | Treated as |
|---|---|---|
| `healthy` | switch is External, bound to an adapter that is Up, and its management-OS vNIC holds a usable IPv4 | OK |
| `unknown` | not evaluable: non-Windows, a probe cmdlet missing, a throw, no switch record, or an ambiguous binding | OK |
| `not-external` | the name is taken by an Internal/Private switch | degraded |
| `uplink-missing` | the switch carries no adapter binding at all | degraded |
| `uplink-down` | the bound adapter is present but its `Status` is not `Up` | degraded |
| `management-os-detached` | `AllowManagementOS` is `$true` but the switch has no management-OS vNIC | degraded |
| `management-os-unaddressed` | the management-OS vNIC exists but holds no usable IPv4 (APIPA / no lease) | degraded |

**Fail-open is a hard rule.** Anything the classifier cannot evaluate
yields `unknown`, never a degraded verdict — a switch bound to a
Switch Embedded Team, an operator-renamed management vNIC, a host with
no `Get-VMSwitch` cmdlet. A false degraded verdict would demote a whole
healthy fleet to NAT; a false `healthy` costs one cycle of the failure
this validation exists to catch. Only positively-established faults
degrade.

`management-os-unaddressed` exists so the classifier and
`Wait-ExternalSwitchHostIpv4` cannot disagree: a switch whose vEthernet
sits at APIPA forwards nothing AND yields no seed address, so calling
it healthy would attach the guest to a dead bridge *and* bake an empty
host IP into its seed — strictly worse for diagnosis than declining the
switch.

**What a degraded verdict does.** The switch name is not returned. Both
reuse branches return `$null`, which the eight `guest.*/New-VM.ps1`
scripts already map to the built-in `Default Switch` (NAT + DHCP) —
the same fully-working topology every Wi-Fi host runs on every cycle.
Guests get no bridged LAN address, reach the host at the Default Switch
NAT gateway, and any LAN-facing service rides host port-forwarders.
Nothing is repaired and nothing is deleted: the switch object, and the
long-lived caching-proxy / stash / pool-control service VMs still
attached to it, are left exactly as they are.

Two bounds on that substitution:

- `Default Switch` ships only with Windows client SKUs and an operator
  can delete it, so the fallback name is checked before it is used.
  `New-VM` throws on a switch name that resolves to nothing, which
  would turn a degraded network into a failed provision for every
  guest; when the Default Switch is absent the scripts warn and attach
  to whatever vSwitch the host does have (non-External first, then by
  name). Non-External ranks first because this path is normally reached
  on a host whose uplink Hyper-V refuses to bridge, and an External
  switch there hands the guest a vNIC with no carrier at all, while an
  Internal or NAT switch still yields a working address. A bridge with
  no carrier still creates and boots a VM, which is strictly better
  than not creating one.
- With several External switches present, the healthy ones are ranked
  deterministically (the one whose bound NIC carries the IPv4 default
  route first, then by name) instead of taken in enumeration order. If
  External switches exist but none is healthy, the function declines
  rather than creating another one: Hyper-V allows one External switch
  per physical NIC, so a blind create tears the original down and
  disconnects every VM on it.

**What the runner does.** A degraded host is a *running* host. The
cycle-start host-network gate classifies every External switch, warns
naming the switch, the verdict, and the remedy, and lets the cycle run;
guests land on Default Switch NAT and the cycle passes. The gate
refuses a cycle only on total loss — no viable External path AND no
Default Switch address — the one state in which every guest is
guaranteed to fail identically. Escalation goes through the runner's
existing consecutive-failure notification gate (`AlertArmed` /
`FailuresBeforeAlert` / `SuccessesBeforeRearm`), so a host that stays
degraded alerts once per streak rather than once per cycle. A guest
failure that coincides with a degraded host verdict is filed as
`host_network_degraded`, a class deliberately kept out of the
fast-retry and warm-resume allow-lists (retrying cannot fix a switch
with no carrier) and exempt from per-guest quarantine streaks (a host
fault produces the identical class on every network-touching guest, so
counting it would quarantine them all and leave a green dashboard over
a dead uplink).

**There is no automatic repair, deliberately.** Every remedy below
reconfigures a live vSwitch on a machine that is usually headless and
unattended, and the failure mode of getting it wrong is that the host
loses its own management path with nothing left running to restore it.
Yuruna detects and degrades; an operator repairs.

### Diagnosing the switch by hand

Read-only, safe to run at any time (substitute the switch name):

```powershell
Get-VMSwitch -Name 'Yuruna-External' |
    Format-List Name, SwitchType, AllowManagementOS,
                NetAdapterInterfaceDescription, NetAdapterInterfaceDescriptions
Get-VMNetworkAdapter -ManagementOS -SwitchName 'Yuruna-External'
Get-NetAdapter | Format-Table Name, InterfaceDescription, Status, LinkSpeed
Get-NetIPAddress -AddressFamily IPv4 |
    Format-Table InterfaceAlias, IPAddress, PrefixOrigin
Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' |
    Format-Table InterfaceAlias, NextHop, RouteMetric
Get-VM | Get-VMNetworkAdapter | Where-Object SwitchName -eq 'Yuruna-External'
```

The fingerprint of the object-outlives-its-binding state is: the switch
lists `SwitchType External` and `AllowManagementOS True`,
`Get-VMNetworkAdapter -ManagementOS -SwitchName` returns nothing, and
the host's IPv4 plus default route sit on a bare physical NIC
(`Ethernet`) rather than on a `vEthernet (…)` alias.

### Repairing the switch by hand

Run these **at the host console**, never over an SSH/RDP session that
rides the adapter being reconfigured.

- `management-os-detached` / `management-os-unaddressed` — recreate the
  management vNIC. Setting a property to the value it already holds is
  a no-op, so toggle it:

  ```powershell
  Set-VMSwitch -Name 'Yuruna-External' -AllowManagementOS $false
  Set-VMSwitch -Name 'Yuruna-External' -AllowManagementOS $true
  ```

  The two halves carry very different risk. The `$false` step is inert
  in this state — there is no management vNIC left to remove, which is
  what the verdict says. The `$true` step is the one that re-plumbs the
  host's IP stack onto a new adapter, so it is the one to have console
  access for; see what a rebind costs, below.

- `uplink-missing` / `uplink-down` — check the cable and the switch
  port first (`uplink-down` is often physical). Then rebind to the live
  NIC:

  ```powershell
  Set-VMSwitch -Name 'Yuruna-External' -NetAdapterName 'Ethernet' -AllowManagementOS $true
  ```

- `not-external` — the preferred name is held by an Internal/Private
  switch. Confirm nothing is attached to it (the `Get-VM |
  Get-VMNetworkAdapter` line above), then remove it and let the next
  cycle create the External switch:

  ```powershell
  Remove-VMSwitch -Name 'Yuruna-External' -Force
  ```

  Removal is never automatic: nothing in the harness calls
  `Connect-VMNetworkAdapter`, so deleting a switch strands the vNICs of
  the long-lived service VMs with no code path back — they have to be
  reattached by hand.

**What a rebind costs.** Any command that binds a physical NIC into a
vSwitch (or removes one that is bound) re-plumbs the host's IP stack:
Windows strips the address off the physical adapter and moves it onto a
`vEthernet (<switch>)` adapter that carries a fresh Hyper-V-pool MAC.
A DHCP reservation or firewall-profile classification keyed to the old
MAC no longer matches, **so the host can come back on a different
address — or, if the new adapter gets no lease at all, on none**. The
NIC also drops for a few seconds while the binding changes. On a
single-NIC host that adapter is the only management path, which is
why this is an operator action with eyes on the console and not
something the runner does on its own.

## KVM host bridge netplan: identity pins

The generated netplan that moves the NIC onto the yuruna bridge
(`host/ubuntu.kvm/modules/Yuruna.Host.psm1`) carries three
identity/ownership pins so it behaves the same on every host:

- `renderer: networkd` on each stanza — a global
  `renderer: NetworkManager` (standard on Ubuntu Desktop) would turn the
  definitions into NM keyfiles and fight the explicit NIC handoff to
  systemd-networkd.
- `macaddress:` pins the bridge's MAC to the NIC's so the upstream DHCP
  server re-issues the same lease (host keeps its IP; the operator's SSH
  session reconnects). Without it, `MACAddressPolicy=persistent` hands
  the bridge a generated MAC: the IP changes, and MAC-filtering DHCP
  setups issue nothing. Note `[NetDev] MACAddress` only applies at
  device creation — the bridge must not already exist when the yaml is
  first applied.
- `dhcp-identifier: mac` — networkd's DHCPv4 client defaults to a
  machine-id-derived DUID, so even with the cloned MAC a server keying
  leases on client-id would renumber the host.

## Host address stability, and what happens without it

A host that renumbers under DHCP strands every guest it provisioned. Guests
are seeded with the host's status-service address at `New-VM` time, and
nothing in the guest image can notice that the address has moved: the
status service is simply unreachable, and the GitHub fallback cannot stand
in for it when the framework repository is private.

Two independent things address this. Pin the address where the lab allows
it; the discovery path below is the safety net for the labs that do not.

### What an unpinned host costs the whole lab

A host that renumbers does not only strand its own guests. Every address it
leaves behind stays allocated on the DHCP server until that lease expires, so
an unpinned host spends the pool at a rate set by **the lease time, not by how
many machines are on the LAN**. One host renewing every 30 minutes takes about
48 addresses a day. Three of them will empty a `/24` in under two days on a
week-long lease — while the same fault on a 20-minute lease recycles fast
enough to look healthy.

That asymmetry is why the check reads the *shape* of the changes rather than
their rate. A host renumbering on reboots and link events produces changes at
irregular intervals; a host whose DHCP identity is not being honored produces
them at one interval, repeated, because that interval **is** the renewal timer.
`Get-HostAddressChurnVerdict` ([Test.HostAddressBeacon.psm1](../test/modules/Test.HostAddressBeacon.psm1))
reports `renewal-churn` for the second shape at any period, so the verdict is
the same on a 20-minute lease and a week-long one.

When the pool does run out, the guests are what fail, and they fail in a way
that points away from the cause: `wget exit 4`, no IPv4 address on a
carrier-up interface, and a network diagnostic that can only list possibilities.
Nothing in that output names the host that consumed the addresses.

The pin and the observation are checked as a **pair**, by
`Get-HostAddressStabilityReport`, surfaced in `pwsh test/Test-Config.ps1`. A pin
the DHCP server ignores looks like a working pin from the configuration and
like no pin at all from the address log; only the pair separates "nobody pinned
it" (fix it here) from "it is pinned and the server does not care" (no pin will
help — reserve or go static).

### Pinning the host address

The bridge takes its MAC from the uplink NIC, so a reservation keyed on that
MAC is the durable fix — the same recipe the cache VM uses
([Pinning the cache VM's IP](caching.md#pinning-the-cache-vms-ip-stable-mac--dhcp-reservation)),
applied to the host instead:

```bash
cat /sys/class/net/yuruna-br0/address     # the MAC to reserve
```

Create a one-time reservation for it on the LAN router. Where the router is
not yours to program, give the bridge a static address instead. On a
NetworkManager-managed bridge (Ubuntu Desktop, and any host whose netplan
was rendered to NM keyfiles):

```bash
nmcli con mod yuruna-br0 ipv4.method manual \
    ipv4.addresses 192.168.7.10/24 ipv4.gateway 192.168.7.1 ipv4.dns "8.8.8.8,8.8.4.4"
nmcli con up yuruna-br0
```

The netplan identity pins described above (`macaddress:`,
`dhcp-identifier: mac`) do the equivalent where the netplan/networkd path owns
the bridge. `New-YurunaBridgeViaNmcli` sets the same identity in the nmcli
spelling — `ipv4.dhcp-client-id mac`, `ipv4.dhcp-iaid mac` — alongside
`ipv4.dhcp-send-release yes`, which hands the address back when the profile
goes down instead of parking it until expiry.

Cloning the MAC is not enough on its own, on either path. It fixes the layer-2
identity while the DHCP client still identifies itself with a
machine-id-derived DUID, so a server keying leases on client-id renumbers the
host anyway — the failure the `dhcp-identifier` line exists to prevent.

Both pins apply at profile creation, and nobody rebuilds a working bridge — so
a host built before they existed would keep renumbering forever while the
remedy sat in this document. `pwsh test/Test-Config.ps1` therefore **applies**
it rather than printing it, through `Set-HostBridgeDhcpIdentity`. That check is
the runner's pre-cycle gate, so it runs on every host at every runner start.

Running it unattended is safe for one narrow reason: `nmcli connection modify`
writes the stored profile and does **not** reactivate it. The live connection
keeps its address, no interface goes down, and no remote session is dropped;
the setting takes effect at the next activation. An `nmcli connection up` would
be a different thing entirely, and a test asserts it is absent.

A netplan-managed bridge is reported, never changed: fixing that one means
rewriting `/etc/netplan` and running `netplan apply`, which re-plumbs the
host's IP stack — an operator action with eyes on the console.

### When the address moves anyway

Identity is the constant, not the address. Each guest is seeded with two
coordinates DHCP cannot invalidate — the host's `hostId`, and the
caching-proxy machine's address, which is pinned by MAC reservation — and
the seeded status-service address is treated as a **hint**.

When that hint stops answering, `yuruna-host-locate` asks the pool
aggregator on the caching-proxy machine where the `hostId` lives now, probes
the answer from the guest's own vantage point, and rewrites
`/etc/yuruna/host.env`, the `yuruna-host` alias in `/etc/hosts`, and
`wgetrc`'s `no_proxy`. Consumers keep reading `YURUNA_STATUS_SERVICE_IP` and
never learn it moved. It runs at the top of every `fetch-and-execute` and on
a one-minute timer, so a step that runs for many minutes is covered too.

The directory it asks is kept current from the host side by a beacon that
announces on address change, on status-service start, and on a periodic
beat. Without that push, the aggregator learns a host's address only by
tailing the squid access log — which lags exactly when it matters, since a
host appears there only when it or its guests pull through the proxy.

Two properties are worth knowing:

- **A guest on a NAT network is already immune.** libvirt's `default`, the
  Hyper-V Default Switch and UTM's Shared mode all put the host at a gateway
  address no lease can move. The resolver is inert there by design.
- **A lab with no caching-proxy machine has no directory.** Those guests keep
  the seeded hint and behave exactly as they did before this mechanism
  existed, so pinning the host address is the whole answer there.

### Surviving a move that lands mid-step

Repairing coordinates keeps a guest able to *find* the host. It does not help
the work that was already in flight when the address moved, and on a host whose
lease turns over every half hour that is most of a cycle's long steps.

Three things cover that, and they are independent.

**The failure is named correctly.** `ssh` reports its own faults as exit 255 and
passes anything else through as the remote command's status. A dropped transport
and a script that genuinely exited 255 are therefore identical in exit status,
and the harness used to attribute both to the guest script — sending an operator
to read a script that had often run perfectly. The stderr text separates them
(an authentication refusal and a rejected host key are 255 too, and are *not*
transport losses), and a dropped transport is reported as `network_timeout`,
which is the class warm resume acts on.

**The work outlives the session.** A detached step runs its payload under a
supervisor on the guest; the output accumulates in a file, and a reconnect
attaches and resumes the stream from the last complete line rather than
re-running the command. This is what makes a step recoverable when its payload
is *not* safe to run twice — one that seeds records and then asserts counts over
them, where a second pass fails on its own assertion and names that instead of
the transport. See
[Surviving a dropped session](test-sequences.md#surviving-a-dropped-session).

**Discovery answers from what is current.** A guest that renumbers leaves its old
address in the host's neighbour table under the same MAC, aged to `STALE` but
still present, so the table routinely holds two addresses for one guest.
Candidates are ranked by how recently the kernel confirmed them; the guest agent,
which reports what the guest holds now over a channel carrying no IP, is asked
before the caches; and the address SSH last authenticated to is used as a last
resort before dialing a bare VM name. The neighbour sweep also falls back to the
last prefix the host held, so it still works during the seconds between leases —
which is exactly when it is needed.

### Knowing whether any of it was exercised

A cycle that passes on a renumbering host is only evidence that the harness
survives instability if instability happened while it ran. Each address change
is timestamped into `runtime/hostaddress.changes.ndjson`, and the number falling
inside a cycle is recorded on its `cycle_end` event as
`hostAddressChangesDuringCycle`; each re-attach is a `guest_run_reattach` event.
Pairing the two shows which steps were in flight when each change landed.

Where the lease is too long to produce changes on demand,
`test/lab/Invoke-HostAddressChurn.ps1` forces renewals on an interval so the
test does not depend on the router's mood. It needs permission to activate the
connection — `test/lab/yuruna-churn.sudoers` grants exactly that — and refuses
to start without it, rather than running all cycle and injecting nothing.

### Diagnosing it

From inside a guest, `automation/Test-YurunaHost.ps1` reports whether
`host.env`, the `yuruna-host` alias and the live service agree. A stale
name-to-address mapping is called out explicitly.

From the host, `runtime/ipaddresses.txt` is refreshed by the beacon on every
change; if it disagrees with `ip -4 addr`, the beacon is not running and the
pool's view of this host is as old as the file.

## Host coordinate resolution

### Defining yuruna host locate lib

A guest is seeded with the host's status-service address at `New-VM` time
and nothing refreshes it, so a host that renumbers under DHCP strands
every guest it provisioned: the status service is unreachable at the baked
address, and every consumer of `YURUNA_STATUS_SERVICE_IP` — the framework's
fetch path and the project's own scripts alike — builds URLs at a host that
is no longer there. Short non-sticky leases make that the normal case in a
lab whose DHCP server is the site router.

[automation/yuruna-host-locate.sh](../automation/yuruna-host-locate.sh)
(and its Windows peer `yuruna-host-locate.ps1`) is an indirection the
consumers never see. Identity is the constant on both ends: the host is
named by its `hostId`, persistent across reboots, reimages and address
changes, and the directory that resolves it lives on the caching-proxy
machine, whose address is pinned by MAC reservation and is therefore the
one coordinate a guest can be born knowing. Both are seeded as **facts**;
the status-service address is seeded as a **hint**.

Nothing here throws. A guest that cannot resolve ends up exactly where it
would have been — the caller degrades on a return code, and
`fetch-and-execute.sh` deliberately falls through to its existing
unreachable diagnostic rather than short-circuiting, so one place still
explains a dead host. The resolve path is bounded rather than instant:
when the baked coordinate is dead the directory is re-asked a few times
over some seconds, because a guest that starts looking at the moment the
host renumbers is racing the same change the directory is still learning.
That wait is paid only by a caller whose other option is to fail.

**Seeding the two identities.** `New-CloudInitUserData` defaults
`YURUNA_HOST_ID_PLACEHOLDER` and
`YURUNA_CACHING_PROXY_SERVICE_IP_PLACEHOLDER` centrally, for the same
reason it defaults the base64 script bodies: every seed wants the identical
answer, and a per-caller copy is a per-caller chance to seed a guest that
cannot find its way home. A caller with a better answer still wins — the
service-VM seeds pass a `hostId` they already resolved. Both are read from
the ambient environment rather than through the harness modules that own
them, keeping the leaf dependency-free, and empty is a supported outcome:
a lab with no pool directory seeds empty values and its guests behave as
they did before the indirection existed.

**Why Windows needs it most.** The seed ISO carrying
`windows-guest-bootstrap.ps1` is burned *before* Windows Setup runs, and
Setup takes longer than a short lease — so the address written into it can
already name a host that has moved by the time the guest first reads it.
An address cannot be the contract when the medium carrying it outlives its
validity. The generated bootstrap therefore does the coordinate work
unconditionally and gates only the git-credential work, runs the resolver
once at first logon before anything reads the coordinates, and registers a
SYSTEM scheduled task (`AtStartup` plus a one-minute repetition) to keep
them true. The resolver itself is seeded, never fetched: it decides *where*
the guest fetches from, so it must arrive over the same trusted channel as
the answer file rather than over the network it exists to repair.

On UTM the split is visible per network mode: under Shared (VZ NAT) the
host answers at a gateway address no lease can move and the seeded address
stays true on its own; under Bridged the guest takes a LAN lease alongside
the host, which is the case the resolver exists for.

### Defining host locate file targets

`YURUNA_HOST_ENV_FILE`, `YURUNA_HOSTS_FILE` and `YURUNA_WGETRC_FILE` name
the three files that carry the host's address into the guest's runtime.
They are overridable only so a test can drive the persistence against a
fixture tree; unset, they are the real paths and behavior is identical.

**The wall-clock caps are backstops, not budgets.** Every request this file
makes is a LAN round trip that completes in milliseconds when the peer is
up, so the timeouts exist for an unreachable peer, not for the normal path.
`YURUNA_LOCATE_PROBE_TIMEOUT` is the tightest because it is paid on *every*
call including the happy path, where it is pure overhead;
`YURUNA_LOCATE_QUERY_TIMEOUT` is paid only when the host has actually
moved, and a second of latency there is cheaper than a failed cycle.

**The retry knobs size a race, not a flaky link.** The directory learns the
host's new address from the host itself, so a guest that starts resolving
at the instant of a renumber can be told the address that just died — both
ends are racing the same change. `YURUNA_LOCATE_RETRY_ATTEMPTS` and
`YURUNA_LOCATE_RETRY_DELAY` space a few re-asks over roughly ten seconds to
cover that gap, against a cycle that otherwise ends; they are overridable so
a test can exercise the loop without paying the wall clock.

`YURUNA_LOCATE_DIRECTORY_PORT` is fixed rather than derived from the seed:
the port is a property of the pool-aggregator-service unit, not of this
guest's provisioning, so a guest seeded before a port change still asks the
right place. `YURUNA_LOCATE_MAX_BYTES` bounds a directory read because the
pool view grows with the member count and this parse runs during bootstrap
on a guest with no tooling installed — a bounded read keeps a pathological
(or hostile) body from becoming this guest's problem.

### Defining host locate http

`__yhl_http_get` is one bounded, proxy-free GET to stdout, non-zero when the
peer did not answer. `--no-proxy` / `--noproxy '*'` are load-bearing: the
caching proxy and the host are both on the LAN and both already sit in the
guest's `no_proxy` list, but a project script that exported its own
`http_proxy` would otherwise route this through squid and cache an address
lookup. An address lookup is the one answer in this framework that must
never be served from a cache — the whole point is that it changes, which is
also why the aggregator sets `Cache-Control: no-store` on the answer.

wget is tried first because it is what the rest of the fetch path uses;
curl second because Amazon Linux ships curl and not always wget. Neither
being present returns non-zero rather than reporting an error: it is a
resolvable state, and the caller degrades. The response is truncated at
`YURUNA_LOCATE_MAX_BYTES` through `head -c`, and the return code is taken
from `PIPESTATUS[0]` so the fetcher's own status is reported rather than
`head`'s, which succeeds whatever the transfer did.

`__yhl_livecheck` layers the single question that decides everything else
in this file — does a status service answer at this base URL — onto that
primitive, discarding the body and keeping only the verdict.

### Defining host locate plausible

A directory answer is a claim from another machine about where a third
machine lives, so `__yhl_plausible` refuses an address that is wrong on its
face before a probe is spent on it. The two forms that matter are loopback
and link-local: both would resolve *locally* and appear to work while
pointing at nothing — loopback at this guest itself, link-local at whatever
answers first on the segment. A probe cannot tell those apart from a real
host, so the rejection has to happen before the probe, not after it.

The check also requires an `http://` or `https://` scheme and a non-empty
host part, and rejects `0.0.0.0` and the multicast range `224.` – `239.`,
which name no single machine at all. The host part is peeled with parameter
expansion rather than a parser because this runs during bootstrap with no
tooling installed.

The Windows peer applies the same rule set through `System.Uri`, so the two
implementations accept and reject the same answers — a guest that adopts an
address its sibling would have refused is a divergence that could only be
diagnosed on one platform.

### Defining host locate directory read

`__yhl_query_directory` asks the pool aggregator where this `hostId` is now.
It deliberately does **not** use `/go/host`, which answers the same question
in one 302: that route mints a short-lived control proof into the redirect
fragment, and a guest holding a control proof for its own host is exactly
the capability the status service's control-route authentication exists to
deny. The read routes used here mint nothing.

Two routes are tried in order. `/api/v1/host-address?hostId=` answers one
host in a body small enough to parse with certainty, and 404s for a host the
pool does not know — so the guest can tell "the pool has never heard of this
host" from "the pool says it is nowhere", and only the first is worth
falling back for. `/api/v1/pool-status` predates it and is the compatibility
leg: a guest carrying this file still resolves against an aggregator that
has never heard of the narrow route, which is what lets the two sides ship
independently.

**Parsing without jq.** Nothing is installed yet at bootstrap, so the
fallback leg splits the payload on `{` and treats each fragment as one flat
object. That split is what keeps a host's own `hostId` distinct from the
`hostId` carried inside that host's nested `status` object — a nested object
ends its parent's fragment. Both keys must land on the *same* fragment for
the match to mean anything, so the `hostId` is required and the `baseUrl` is
taken from that line alone. The aggregator holds up its end by keeping
`hostId` and `baseUrl` adjacent and ahead of anything nested in `hostView`;
reordering those fields silently breaks this parser.

If the shape ever changes in a way this cannot read, the function finds
nothing and the caller degrades to the seeded hint. A wrong address is the
one outcome that must not be possible here, so silence is the safe failure.

### Defining host locate persist

The resolved address is written into three files, each write independent and
best-effort. Best-effort is the point, not a shortcut: a guest with a
read-only `/etc`, or one whose sudo is gone, has still resolved the address
correctly in memory, and the export the caller receives is what unblocks the
step it is running right now. Failing the resolve because a file could not
be written would trade a working step for a tidy filesystem.

`__yhl_install_file` moves a staged temp file over its destination directly
first — the elevation is not always needed, and a process that can already
write the file should not shell out to ask — then falls back to `sudo -n`.
The `-n` is what makes this safe: the resolver runs unattended, on the
bootstrap path behind a console the host is watching and on a timer with no
console at all. A prompting `sudo` there would not fail, it would **hang**,
holding the step open until the watchdog kills the cycle. Refusing to ask is
the only safe form of asking here.

- `host.env` is rewritten in place, substituting only the two coordinate
  lines, so the file keeps whatever else it carries — repo, ref, `hostId`,
  cache address.
- `/etc/hosts` removal is **line**-based, matching `Set-HostAlias` on the
  host side: a line mapping `yuruna-host` is dropped whole, including any
  aliases that shared it, so the two implementations cannot disagree about
  what "replace the mapping" means.
- `wgetrc`'s `no_proxy` is belt-and-braces for the one file that names an
  address. The environment's `no_proxy` already covers the RFC1918 ranges,
  but a single stale literal here sends a plain `wget` at the host through
  squid, which then caches a status-service response.

### Defining host locate entrypoint

`yuruna_host_locate` exports `YURUNA_STATUS_SERVICE_IP` / `_PORT` and
returns 0 when they are known-good; it returns 1 when they could not be
established, which the caller must treat as "behave as though this file did
not exist".

**Probe-first ordering is what keeps this affordable.** On the
overwhelmingly common path the baked coordinate is still correct, the
directory is never consulted, nothing is written, and the whole call costs
one LAN round trip — which is why it is safe in front of every
`fetch-and-execute` and on a one-minute timer. Its variables are `local`
because `fetch-and-execute.sh` *sources* this file, and anything left
unscoped would land in the caller's shell.

Both coordinates of the indirection are required before the directory is
asked. A guest imaged before this file existed carries neither, and a lab
with no caching-proxy machine has no directory — in both cases the honest
answer is that this guest cannot re-resolve, and the caller's existing
unreachable path is the right one.

**Every candidate is confirmed from the guest's own vantage point.** The
directory reports where *it* reached the host; this guest may sit on a
different segment, and an address that does not serve this guest is not an
improvement on the stale one it would replace. The same check is what makes
re-asking worthwhile — a stale answer fails it too, so the loop keeps asking
until the directory has caught up with the renumber. A base URL that carries
no port defaults to 80, and the move is announced on stderr naming the old
coordinate, the new one and the directory that supplied it, so a log makes
the repair visible.

**Sourcing versus executing.** Sourcing defines the function and does
nothing else, which is what `fetch-and-execute.sh` needs; the
`BASH_SOURCE`/`$0` guard runs it when the file is executed, which is the
refresh unit's entry point. That unit is ordered `Before=network-online.target`
and after whichever wait-online service the image ships, so anything in the
guest that waits on the network-online barrier never reads a stale address —
and it achieves that without naming a single consumer, which is the whole
point of the indirection. `Type=oneshot` because no state carries between
ticks and a oneshot cannot wedge, with `TimeoutStartSec=30` as the backstop
for the day one of the internal bounds is not honored. Windows guests get
the same cadence from a SYSTEM scheduled task instead.

## The yuruna-run supervisor

### Defining yuruna run supervisor

[automation/yuruna-run.sh](../automation/yuruna-run.sh) is the guest-side
start-or-attach supervisor behind a detached step. An SSH session dies when
either endpoint's address moves under it, and the command it was running
dies with it — all the host sees is `ssh`'s own exit 255, which says nothing
about whether the payload succeeded, failed, or is still going. The obvious
repair, re-running on reconnect, is available only to a payload that is safe
to run twice, and the payloads that most need recovering are not: a script
that seeds records and then asserts counts over them fails its own assertion
on the second pass, and names that instead of the transport that caused the
re-run.

This turns the reconnect into an **attach**. The payload runs detached, its
output accumulates in `out.log`, and every invocation — the first and each
reconnect after it — streams that file from a caller-supplied line offset
and reports the payload's real exit status once one exists. Invocations are
idempotent on the token: start if it is not running, attach if it is.

stdout carries payload bytes **only**. Every diagnostic goes to stderr,
because the host counts stdout lines to know where to resume, and a
supervisor line on stdout would both corrupt that count and land in the
transcript the OCR and checkpoint scanners read.

### Why the run directory is scoped to the boot id

The run directory is `${TMPDIR:-/tmp}/yuruna-run/<token>.<boot>`, keyed on
the first eight characters of `/proc/sys/kernel/random/boot_id` and not on
the token alone. Guests here are restored from disk snapshots ten times a
cycle, and a snapshot taken while a run was in flight carries that run's
directory — `pid`, `out.log` and all — back onto a machine where the process
it names does not exist, and where that pid may since belong to something
unrelated.

Without the boot component, the next attach on that token would find a
directory already claimed, holding a pid it cannot trust: dead, and the
attach declares the run vanished; reused by an unrelated process, and it
streams a file that will never grow again until the step's budget is spent.
Either way the payload never runs. Scoping on the boot makes the restored
corpse simply invisible — the token/boot pair has no directory, so the
caller wins the claim and starts a clean run. `noboot` is the fallback when
the file is unreadable, which degrades to token-only scoping rather than
failing.

### Why `mkdir` is the claim

Which caller starts the payload is decided by whether its `mkdir` of the run
directory succeeds. That one call is the whole concurrency story: it either
creates the directory or fails, atomically, with no window in which two
callers both believe they are the starter. A test-then-create — stat the
directory, create it when absent — has exactly that window, and two
supervisors running the same payload against the same `out.log` is precisely
the double execution this script exists to stop.

Losing the `mkdir` is not an error, it is the ordinary attach path: a
reconnect after a dropped session always loses it, logs
`YURUNA_RUN_ATTACH`, and goes straight to streaming from the caller's line
offset. The only genuine failure is losing the race and then finding no
directory there at all, which means the base path is not writable rather
than that someone else claimed it; that is reported as exit 74 instead of
being treated as a reason to start a second copy.

### Why a run directory is never removed

Nothing in this script removes a run directory. It is created once and from
then on only gains files, which makes the `mkdir` claim monotonic: no later
invocation can win a token that has already been claimed, whatever it
concludes about the state of the run.

The temptation is to clean up on a terminal verdict — a missing `--cmd-b64`,
a command that is not valid base64, a run judged dead because its pid is
gone. Every one of those hands the token back, and the next attach then
starts a **second copy** of a payload that may still be running. For a
script that seeds records and then asserts counts over them, that is the
same double execution the whole mechanism exists to prevent, arrived at from
the other direction: the verdict was about this invocation's ability to
proceed, never proof that no payload is alive.

So a terminal verdict is recorded as a status instead. `yr_terminate` writes
it to `status.tmp` and renames it into place, so no reader ever sees a
half-written status, and every later attach reads that value, reports it,
and runs nothing. Reclaiming the space is left to the boot-scoped directory
going away with `/tmp`.

### Why the claim is confirmed before it is used

`mkdir` is decided by exactly one caller on any POSIX filesystem, and the
tiebreak that follows it is the belt to that brace. Every winner appends its
pid to `claim` and settles briefly; only the process whose pid is the first
line of that file goes on to start the payload. A second winner logs
`YURUNA_RUN_CLAIM_YIELD` and falls through to the attach path, so even a
directory creation that somehow admitted two winners still yields one
runner.

The cost is one append and a fifth of a second, on the start path only, paid
once per step. What it buys is the guarantee everything else rests on — a
payload that seeds records and asserts counts over them must run once or not
at all — and "the filesystem promised" is a thin thing to rest that on when
the check is this cheap. It also makes the property testable rather than
assumed: on a filesystem whose `mkdir` is not atomic, the claim alone would
admit two starters, and the tiebreak is what keeps a double winner from
becoming a double run.

### Why the payload gets its own process group

Inside the detached runner, `set -m` puts the payload in a process group of
its own, with `$!` as the group id, which is recorded in `payload_pgid`. Two
things depend on that.

The budget watchdog signals the whole **group** — `SIGTERM` to `-PGID`, then
`SIGKILL` thirty seconds later — so a payload that backgrounds `helm`,
`kubectl` or a build does not leave those running into the next step.
`timeout(1)`, and any kill aimed at the payload's pid alone, reach only the
direct child. `--cancel` uses the same recorded group id for the same
reason. And the runner sits **outside** that group, so the signal does not
take down the one process whose job is to record the exit status; a budget
kill therefore comes back as a status the host can attribute to the budget,
not as the vanished-run report the supervisor emits when no status is ever
written.

Session detachment is a separate concern: `setsid` (or `nohup` where
util-linux is absent) keeps the SSH hangup from reaching the runner. Neither
path changes how the payload is bounded or reaped — that comes from `set -m`
in the runner either way.

### Why the replay counts only complete lines

Replay is by complete lines only, on both ends. `wc -l` counts newlines, so
`yr_drain` emits whole lines and advances its cursor by exactly those, and
the host banks stdout only up to its last newline and advances its resume
offset by the same count. A half-written trailing line is neither emitted
nor counted; the next attach re-sends it whole.

Emitting it would put the two ends permanently out of step. The host would
count the fragment as delivered and ask to resume past it, and the rest of
that line would be lost from the transcript the failure-pattern matcher and
the retry-marker parser read — dropping exactly the markers those consumers
exist to match on, and splitting them mid-token so no later pass recovers
them.

The rule has one exception, at the end. Once `status` exists nothing more
can be appended, so a final byte that is not a newline is a complete line
the payload merely failed to terminate; the supervisor appends the newline
itself before the last drain, so that line is delivered rather than held
back forever by the complete-lines rule.

## Driving a guest over SSH across an address change

### Why a proven address is remembered

Every rung of address discovery is a *report* about the guest — the guest
agent's, the lease database's, the kernel neighbour table's — and each rung
can decline. A proven address is different in kind: `ssh` completed a key
exchange with the guest there, so it was true rather than reported. That is
why the memo is the last word in discovery and not the first. It does not
prove the address is current, and it is consulted only after every rung has
declined, where the alternative is dialing the bare VM name and failing
inside `getaddrinfo` — a resolver error that names nothing about the real
fault, and one no guest-side change can fix. A renumbering host is exactly
where the other rungs go quiet, because the neighbour sweep needs a host
prefix the host is in the middle of changing.

Three properties keep the memo honest. It is banked on any exit other than
255, not only on success: an exit from the far end proves the session was
established, and banking only on success would forget the address precisely
on the runs that go on to need it. It is age-bounded (30 minutes by
default) because VM names are reused every cycle, so an entry with no expiry
would offer an address from a guest generation ago. And it is cleared
outright on a snapshot restore, where the identity-to-address binding is
known to be broken rather than merely suspected.

The table is anchored in the global scope for the same reason as the guest
SSH user overrides: the harness re-imports this module with `-Force`
mid-cycle, and a memo wiped at that moment is empty exactly when a renumber
is in progress.

### Why a detached step is bounded by a deadline

Detached mode changes what an attempt costs, so it cannot reuse the
non-detached retry accounting. A re-run may have the full `timeoutSeconds`
because it starts the work over. An attach may not: the payload has been
running on the guest the whole time the session was gone, and the step's
budget has been draining with it. Giving each attach a fresh full budget
would let a step declared at 1800 s occupy an hour and a half across three
reconnects, and the cycle's own schedule has no defence against that.

So the deadline is computed once when the call starts, and every attach is
bounded by what is left of it rather than by a per-attempt figure. The
inverse bound is deliberately absent: the number of reconnects is limited
only by the deadline, because on a host renumbering every ten minutes a
fixed small retry count is the thing that runs out first, and it would
abandon work that was still healthy. Each attach keeps a 30 s floor so a
reconnect is never started with no time to say anything.

When the deadline passes while reconnecting, the step reports the timeout
with everything already streamed, and says the guest may still be running
the payload — the host stopped watching, which is not the same as the work
having stopped.

### Why the supervisor status outranks `ssh`

The supervisor's contract gives the harness two separate channels: payload
bytes on stdout, the supervisor's own markers on stderr. The harness relies
on that split in both directions. Only *complete* lines of stdout are
banked, and the resume offset advances by exactly those, so a partial
trailing line is dropped and re-sent by the next attach — which is what
keeps the two ends from drifting apart on where the transcript resumes.

The `YURUNA_RUN_EXIT` line on stderr is the authority on how the payload
ended. `ssh`'s exit code describes only the session, and the two disagree
in exactly the case that matters: a payload that genuinely exits 255 is
indistinguishable from a dropped transport by exit code alone. When the
marker is present the question is settled and no reconnect is owed,
whatever `ssh` reported — reconnecting there would attach to a run that had
already finished and re-decide a verdict the guest had already given.

One reserved status is carried through rather than treated as a payload
failure: a run that disappeared before recording an exit status is reported
as lost, with a preface saying the output is everything it produced. That
is a different fault with a different owner than a script that ran and
failed.

### Why a started run with no exit is a lost session

When the exit marker is absent, its absence is itself the evidence. The
supervisor announces itself before it streams anything, so a start or
attach line with no exit line means the session ended while the run was
still live. That is a lost transport by construction, independent of what
the `ssh` client did or did not say about it.

That inference is worth more than the client's wording, and it is available
only on the detached path. The call sites run with `LogLevel=ERROR`, so
the client's own explanation is frequently absent altogether; classifying on
the text alone reported a step whose payload was merely mid-wait as the
guest script failing, and attempted no reconnect. A non-detached session
has no such witness and must still fall back to matching the client's
wording, which is why the two paths classify differently.

The classification reads the supervisor's stream alone, never the combined
output. Payload bytes arrive on stdout by the supervisor's contract, so
merging them in buries a one-line client message under kilobytes of
provisioning output — and the rule that treats a silent 255 as a transport
loss can then never fire at all, because the output is never empty.

### Why detached is the default for fetched scripts

`sshFetchAndExecute` carries long provisioning payloads, and the common
shape of those payloads is a script that seeds records and then asserts
counts over them. Such a payload cannot be re-run against the state it has
already changed: a second pass fails on its own assertion and names that
instead of the transport that forced the retry, sending an operator to read
a script that was healthy. Detaching makes the payload outlive the session,
so an address change costs a re-attach instead of the step, and
repeat-safety stops being a precondition for surviving one. That is why the
default here is the opposite of `sshExec`'s, which runs whatever the YAML
names and therefore cannot assume anything about repeating it.

The run token is derived from the step's coordinates — sequence file, step
number, VM — rather than generated per call, and that is load-bearing
twice. A reconnect inside the step attaches to the same run instead of
starting a second copy of the payload; and a warm resume that re-enters the
step on a guest that is still up attaches to work already in flight rather
than restarting it.

`transportRetries` is ignored while detached, since attaching needs no
judgement about whether the payload is safe to repeat. `detach: false`
opts a step out.

## Finding a guest's address on KVM

### Why neighbour entries are ranked, not taken in order

The host's neighbour table is not a map from MAC to address — it is a
map from address to MAC, and nothing evicts the old row when a guest
renumbers. The entry the guest has left ages to `STALE` and sits there
alongside the new one, so `ip -4 neigh show` routinely holds two
addresses for one guest MAC. Taking the first matching line returns
whichever the table's order happens to yield, and half the time that is
the address the guest no longer answers on — a lookup that succeeds
loudly and connects to nothing.

`Get-KvmNeighborIp` collects every row carrying the wanted MAC and
orders them by how recently the kernel confirmed the entry:
`REACHABLE` first (verified within the last few seconds), then
statically configured `PERMANENT`/`NOARP`, then the in-flight
`DELAY`/`PROBE` states, then `STALE`, which asserts only that the
mapping was true at some point. `FAILED` and `INCOMPLETE` are dropped
entirely: the kernel is publishing no link-layer address for them, so
they carry nothing to return.

A tie can only be stale-versus-stale, since the kernel keeps at most one
`REACHABLE` entry per address. Two stale rows carry no information to
choose between, so the tie is broken by asking — one bounded `ping -c 1
-W 1` per tied candidate, first reply wins, falling back to the
highest-ranked row when none answers.

Reading the table directly is also why this rung exists next to `virsh
domifaddr --source arp`. libvirt matches the same table but sees an
entry only while a link-layer address is published for it, so a guest
that is up and serving traffic vanishes from that source for as long as
its entry sits in `FAILED` or `INCOMPLETE`.

### Why the sweep remembers the last known prefix

Both `--source arp` and the neighbour rung are passive reads of a cache
that decays, and nothing in a normal cycle makes a guest talk to this
host often enough to keep its entry alive. `Update-GuestNeighborCache`
is the active half: one bounded ICMP sweep of the host's own subnet,
whose replies are irrelevant — the point is the ARP exchange each probe
forces, which is what lands in the table the next read consults.

The subnet to sweep comes from the host's own default-route IPv4, and a
host between leases has none for a few seconds; `Get-HostIpv4Prefix`
answers with nothing. Treating that as a reason to skip the sweep gets
the timing exactly backwards: a host that just renumbered is precisely
when the guest's neighbour entry has gone stale and a lookup is about to
fail. The subnet does not move when the address within it does, so
`$script:LastKnownHostPrefix` carries the last prefix this host held
forward and the sweep runs against it, turning "no prefix, no sweep, no
address" into a sweep that answers. Only a host that has never been seen
with an address declines.

The prefix is read rather than assumed for the same reason it is
width-checked: the sweep is defensible on a `/24` and nothing wider. At
`/16` it is 65k probes across the operator's LAN, which is a scan, not a
lookup. Two cheaper guards sit ahead of it — a per-VM cooldown, so a
polling caller cannot turn its poll interval into a sweep interval, and
a running-state check, so a stopped or absent domain never pays.

### Why the guest agent is asked first

`Get-VMIp` runs an ordered ladder — agent, lease, arp, neighbour table,
neighbour table after an active refresh — and the first rung to produce
an address ends it. That first-answer-wins shape is what makes the order
load-bearing: a rung that answers *wrongly* ends the ladder just as
surely as one that answers correctly, so the rung most likely to be
confidently wrong must not go first.

The lease database and the ARP/neighbour table are both records of what
was true earlier. On a guest that has just moved they do not fall silent
— they still hold the address it left, which is the worse failure,
because it produces a plausible target that refuses connections instead
of a `$null` the caller can narrate. The agent asks the guest what
addresses it holds right now, over a virtio-serial channel that carries
no IP and therefore cannot itself be broken by the renumbering this
ladder exists to survive.

It is a preference, not an authority. The channel needs a
`qemu-guest-agent` that has finished starting, so it is absent for the
whole boot window after every snapshot restore — which is when a cycle
does most of its address lookups. The cache rungs stay beneath it
unchanged for that window. Which rungs can answer at all is a property
of the host, not of this code: `lease` needs libvirt to be the DHCP
server, so it is silent for a guest on a bridge-forward network with no
`<dhcp>` element. Where both agent and lease are silent, the arp and
neighbour rungs are the whole of discovery.

### Why a MAC sweep is spent only on a failed bring-up

Address discovery is the step that fails first, and it can fail without the
caller ever probing the service it came for: a guest whose lease this host
cannot see — a bridged guest on a hypervisor that keeps no lease file for it,
carrying no guest agent — is invisible to every rung above while serving its
peers normally. A wait can then spend its entire budget on nothing.

The VM bundle's MAC is the identity that survives that. Matching it costs ICMP
sweeps of every candidate `/24` until one answers or their budgets run out,
measured at about two minutes when the cheap lookups have nothing to offer.
That is far too expensive to repeat on a poll, so it is not part of the ordinary
ladder at all.

It is spent in exactly one place: on a bring-up that has already failed, where
the alternative is reporting a healthy daemon as a failed one, and where two
minutes is cheap against the run that is otherwise about to be called a failure.
An address it recovers is also worth naming in the failure line, since a reader
comparing the guest's own address against the ones this host dialed cannot rule
out a candidate that was never printed.

## Proving the lab survives address churn

### Why churn is injected rather than waited for

A canary host proves nothing on a quiet network. If the harness simply
waits for the site router to renumber it, the evidence becomes a matter
of luck — the lease is what it is, the changes fall where they fall, and
a green cycle may only mean the run happened to sit inside a calm half
hour. `test/lab/Invoke-HostAddressChurn.ps1` drives the renewal instead,
so "this cycle passed through N address changes" describes the harness
rather than the router's mood. The 780-second default puts three or more
renewals inside a typical ~50-minute cycle without landing on the cycle's
own boot windows.

What it can force is a fresh lease negotiation, not a fresh address: the
DHCP server still decides. A server that hands back the same address
yields an honest "no change" line, and that outcome is reported rather
than retried — hammering until the address finally moves would
misrepresent how much churn the cycle actually met, and surviving a
renewal that keeps the address is a legitimate case too. Only real
changes reach the beacon's `runtime/hostaddress.changes.ndjson`, which is
what a cycle's count is read from; the injector's own
`hostaddress.churn.log` records intent, not evidence.

Each tick uses `nmcli connection up` rather than a down/up pair. Both
produce a DISCOVER, but taking the connection down first drops the bridge
out from under every running guest — a harsher event than the renumber
this is meant to model, and one that would test something other than
address instability.

### Why the privilege check runs before the first sleep

The injector's loop sleeps first and renews second, so with the default
unbounded `-Count` the first real attempt is thirteen minutes away. A
sidecar that starts cleanly and only then discovers it cannot activate
the connection would fail silently for the whole cycle, and that cycle
would still be filed as evidence of surviving churn that was never
injected. Refusing to start is the strictly better failure, so the
readability probe (`nmcli -t connection show`, which also catches a wrong
bridge name) and the privilege probe both run before the loop is entered.

Activating a connection is privileged and the test runner is deliberately
not root, so the probe is `sudo -n nmcli --version`. The `-n` matters:
without it a missing rule blocks on a password prompt that nobody is
present to answer, turning a hard failure into a hang. The error names
the exact `install` command for `test/lab/yuruna-churn.sudoers` and says
plainly that a pass without the rule is not evidence.

That sudoers file grants the two spelled-out commands — the version probe
and `nmcli connection up` on one named connection — instead of `nmcli *`,
which would also permit `connection modify`, `connection delete` and
`device disconnect`, any of which can take the host off the network
permanently rather than for the second a renewal costs. Because the probe
precedes the `ShouldProcess` gate, `-WhatIf` confirms the privilege is in
place without touching the network.

### Why a cycle records the churn it met

A verdict alone cannot be read as a claim about instability. `Stop-LogFile`
therefore counts the address changes falling between the cycle's start and
its close and carries the number on the `cycle_end` event as
`hostAddressChangesDuringCycle`. A pass with three changes inside it is
evidence the harness survives renumbering; a pass with none says only that
the network was quiet. Without the number both are the same word in the
same place.

Because zero is a *meaningful* answer, an unmeasurable cycle records `-1`
instead. A failure to count must not be able to imitate the reading that
says "this run proves nothing about churn" — reporting an unmeasured cycle
as zero is worse than reporting nothing, since it reads as evidence. The
same rule holds one level down: `Get-HostAddressChangeCount` returns `-1`
when `hostaddress.changes.ndjson` is absent, and skips unparseable rows
rather than throwing, since this feeds a report and no single malformed
line is worth failing a cycle over.

The beacon module is imported rather than probed for. A `Get-Command`
guard alone is always false for a module nothing else in this session
state loads, which is exactly how every cycle came to record 0; the beacon
imports nothing itself, so there is no import cycle to fear. The count is
announced out loud on a pass — that is the case where a low number quietly
weakens the claim, while a failing cycle already has a louder problem.

## Guest-side fetch and session behavior

### Why sshd notices a client that left

The long-lived service VMs — `pool-control-service`, `stash-service`,
`download-agent-service`, `caching-proxy-service` — install
`/etc/ssh/sshd_config.d/60-yuruna-keepalive.conf` from their seeds.
Upstream leaves `ClientAliveInterval` at `0`, so sshd never asks whether
the client is still there: a session broken by either endpoint
renumbering is noticed only when the kernel's TCP timeout finally
expires, minutes later. Until then the command the host was running
keeps running, unwatched, holding whatever it held — a dpkg lock, a
mount, a port. That lingering command, not the lost session, is what the
bound exists to prevent: the host reconnects and re-runs, and two copies
racing the same locks turn a recoverable blip into a new failure.

These VMs outlive the host that drives them, and that host moves on
every DHCP renewal. `15s x 4` mirrors the `ServerAliveInterval` /
`ServerAliveCountMax` pair `Invoke-GuestSsh` passes, so both ends give up
on the same schedule, and the reconnect wait in `Test.Ssh.psm1` is sized
off that bound with margin — the re-run then starts against a guest that
has already reaped the previous copy. A guest from an image predating
this drop-in reaps on the kernel timeout instead, far outside any wait
worth spending, which is the case for disabling transport retries
altogether. `TCPKeepAlive yes` stays on as the second, kernel-level path
to the same verdict.

### Why host coordinates are re-read per use

`/etc/yuruna/host.env` is a moving target. `yuruna-host-locate.timer`
rewrites it every 60 seconds, so the host's current address is always on
disk — but a script that sources it once at the top holds whatever the
address was when it started, and these scripts run for minutes on a host
whose DHCP lease moves under them. Re-sourcing immediately before each
use costs nothing and is the difference between following the host and
being stranded by it. The Ubuntu guest-update script wraps that read in
`yuruna_host_env`; the amisad guest scripts wrap the same shape in
`amisad_host_fetch`.

A failed fetch additionally earns one forced run of
`yuruna-host-locate.sh` rather than waiting for the timer to come round.
The file can be up to a full refresh interval behind the very move that
broke the fetch, so a retry that skips the refresh does nothing but
re-dial the address that already failed. Both callers spend exactly one
such attempt — the framework-tarball fetch runs its livecheck twice and
relocates in between — so a host that is genuinely gone still falls
through to the git-clone path instead of looping on a resolver that has
no better answer.

### Why the single-VM fallback is gated

The amisad fulfillment scenario resolves the edge VM's address — the KVM
`192.168.122.0/24` neighbour entry first, then the handoff file the host
status service publishes — and deploys `slice-runtime` there. When no
address resolves, the branch that follows can run the whole scenario
against this one VM instead, then assert the full Target Verification
Point over it and print `PASSED`. That is precisely the problem: a cycle
in which the edge was merely unreachable reports the same result as one
in which the distributed topology actually worked. On a host whose
address moves, an unreachable edge is a routine event rather than a rare
one, so the degraded shape would be entered often and silently.

The branch therefore refuses — exit 4, with the reason on stderr —
unless `AMISAD_ALLOW_SINGLE_VM=1` is set. The fallback is kept because
it is genuinely useful for working on the scenario without a second VM,
but entering it has to be a deliberate choice. Refusing rather than
degrading is what keeps a green cycle meaning that the thing the
scenario exists to test was the thing that ran.

### Why git never prompts here

These guests are driven by OCR of a console. There is no terminal for
git to ask a question on, so a credential prompt is not a failure but a
hang: the step burns its entire timeout before anyone learns the clone
could not authenticate. `GIT_TERMINAL_PROMPT=0` turns that into an
immediate, readable error, and the `git-askpass.sh` shim is what lets a
private clone succeed at all — git does not read `GH_TOKEN`, which is a
`gh(1)` convention rather than a git one. See
[Defining the two-source scheme for framework and project URLs](definition.md#defining-the-two-source-scheme-for-framework-and-project-urls).

The seeds write both variables unconditionally, and separately from the
token block, because the two have opposite conditions. A token being
present is what makes a private clone succeed; a token being *absent* is
what makes git prompt. Gating the prompt suppression on the token would
install it in exactly the case that does not need it and omit it from
the case that does.

The guest update scripts then export the same two variables again before
cloning, as belt to the seed's braces. They run under `sudo` and through
non-login shells, either of which drops what `/etc/profile.d` exported,
and a guest built from an older seed has no such export to drop in the
first place.

## Local Subnet Connectivity

During `setup.ps1` execution, service VMs (such as the caching-proxy or stash service) must reach the host across the local subnet (typically a `/24`). If host-level firewall rules or network isolation block that traffic, the `setup.ps1` preflight fails.

Follow the instructions below for your operating system.

---

## Ubuntu / Linux (UFW & iptables)

### 1. Check Firewall Status

Review active `ufw` rules:

```bash
sudo ufw status verbose

```

If `ufw` is active and contains outbound block rules (e.g., `DENY OUT` or `REJECT OUT` targeting a `/24` subnet such as `192.168.7.0/24`), service VMs on that subnet cannot reach the host.

### 2. Allow Local Subnet Traffic

Allow outbound and inbound traffic across your local `/24` subnet:

```bash
# Allow local subnet outbound traffic (replace 192.168.7.0/24 with your subnet)
sudo ufw allow out to 192.168.7.0/24

# If specific service ports are restricted, allow them explicitly
sudo ufw allow 8888/tcp
sudo ufw allow 8080/tcp

# Reload firewall rules
sudo ufw reload

```

### 3. Verify Connectivity

Test reachability to the local network interface or router:

```bash
ping -c 3 192.168.7.1

```

---

## Windows (Hyper-V & Windows Defender Firewall)

### 1. Check Outbound Rules

Open PowerShell as **Administrator** and inspect active outbound block rules:

```powershell
Get-NetFirewallRule -Direction Outbound -Enabled True -Action Block | Format-Table Name, DisplayName

```

### 2. Add Firewall Exception for Local Subnet

Allow local subnet communication through Windows Defender Firewall:

```powershell
# Allow all outbound traffic to the local subnet
New-NetFirewallRule -DisplayName "Yuruna Local Subnet Allow" `
                    -Direction Outbound `
                    -Action Allow `
                    -RemoteAddress LocalSubnet `
                    -Enabled True

# Allow incoming connections on required service ports
New-NetFirewallRule -DisplayName "Yuruna Service Ports" `
                    -Direction Inbound `
                    -Action Allow `
                    -Protocol TCP `
                    -LocalPort 8080, 8888 `
                    -Enabled True

```

### 3. Verify Connectivity

Test reachability from PowerShell:

```powershell
Test-Connection -TargetName 192.168.7.1 -Count 2

```

---

## macOS (UTM & PF Firewall)

### 1. Check Packet Filter (PF) Status

Inspect whether the macOS `pf` firewall is active and blocking local traffic:

```bash
sudo pfctl -s info

```

View active rules:

```bash
sudo pfctl -s rules

```

### 2. Allow Local Traffic

If custom anchor rules or `/etc/pf.conf` entries isolate local subnets, add a pass rule to your PF configuration:

1. Open `/etc/pf.conf` in a text editor:
```bash
sudo nano /etc/pf.conf

```


2. Add a rule permitting local subnet traffic:
```text
pass out quick on en0 proto tcp from any to 192.168.7.0/24

```


3. Reload the PF ruleset:
```bash
sudo pfctl -f /etc/pf.conf
sudo pfctl -e

```

### 3. Check macOS Application Firewall

Ensure `socketfilterfw` is not blocking incoming service connections:

```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate

```

---

## Related Links & Further Reading

* [Ubuntu UFW Firewall Documentation](https://help.ubuntu.com/community/UFW)
* [Microsoft Defender Firewall with Advanced Security](https://learn.microsoft.com/en-us/windows/security/operating-system-hardware-security/network-security/windows-firewall/)
* [macOS PF Firewall Guide](https://support.apple.com/guide/mac-help/mh34041/mac)

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.16

Back to [Yuruna](../README.md)
