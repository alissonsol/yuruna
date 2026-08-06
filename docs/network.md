# Yuruna network workarounds

This file collects rationale for network-related workarounds in guest
scripts and the host harness. Centralizing the long explanations keeps
source comments short and the workarounds discoverable from one place.

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
CDNs that occasionally fail on transient conditions that recover within
seconds. Without a wrapper, a single flaky lookup aborts the whole
script via `set -e` and the cycle wastes its remaining budget.

**The failure modes that motivated this library.** Two examples:

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
script failed even though the network was healthy a few
seconds later.

The same pattern applies to apt: transient mirror flakes, DNS bounces
on first-boot DHCP, `Hash Sum mismatch` from a half-refreshed mirror
(transient, handled by the retry logic in `apt_retry`).

**Library.** All five retry wrappers live in
[automation/yuruna-retry.sh](../automation/yuruna-retry.sh) — single
source of truth. The library is deployed to every supported guest by
cloud-init's `write_files:` (base64-encoded) at install time, landing
at `/usr/local/lib/yuruna/yuruna-retry.sh` before any provisioning
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
   40 s, 80 s, 160 s; override via `YURUNA_RETRY_DELAY_SECONDS`), so parallel
   guests that failed in lock-step — a shared caching-proxy-service blip, a
   mirror 429 burst — don't all wake and retry on the same instant and
   re-form the thundering herd that caused the failure. The jitter
   never exceeds the base delay, so the ~5-min worst-case total is
   unchanged.
3. Streams the wrapped command's stdout/stderr normally so the log
   shows exactly what the wrapped tool is doing.
4. Prints `!! <name>: attempt N/5 failed (rc=…)` banners between
   attempts so the log makes the retry visible.
5. After the final attempt returns the real exit code; `set -e` then
   aborts the script with a diagnosable failure.
6. **Transient/permanent gate** (`curl_retry` + `wget_try`): stops the
   ladder immediately on a deterministic **HTTP 404** (or other 4xx bar
   429) and a malformed URL, instead of burning all 5 attempts on
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
a one-shot provisioning script under `set -euo pipefail`. 4xx
responses are not retried by curl's inner `--retry`, and the outer
loop's transient gate (item 6 above) also fails fast on them, so a
deterministic 404 costs one attempt, not the full ~5-min ladder.

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

---

## Guest dependency version pins

### Defining yuruna versions pins

[automation/yuruna-versions.sh](../automation/yuruna-versions.sh) is the
single source of truth for the pinned upstream dependency versions the guest
provisioning scripts install. cloud-init deploys it (base64) to
`/usr/local/lib/yuruna/` alongside `yuruna-retry.sh`, and the retry library
sources it — so every guest script that sources the retry lib also sees the
pins. Guest scripts reference the exported variables and **never** the version
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

### Defining yuruna network lib

The guest network helper lives in
[automation/yuruna-network.sh](../automation/yuruna-network.sh) — the
network-specific sibling of the retry library above. cloud-init deploys
it to `/usr/local/lib/yuruna/yuruna-network.sh` at install time. It
targets Ubuntu Server and Amazon Linux 2023, which both ship `ip` and a
systemd-networkd DHCP client. The file is `source`d by
[fetch-and-execute.sh](../automation/fetch-and-execute.sh) (for
`network_diag`) and invoked by the `networkRelease` sequence action (for
`network_release`).

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
so lease-pool questions do not apply to it — the causes are host-side:
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
vacuously true on a guest whose only interface is DOWN, and this
diagnostic is the sole artifact such a guest can still produce. Both
post-mortem routes (SSH into the guest, and the host status service)
need exactly the network it does not have, so the console capture is
the only record and its correctness carries disproportionate weight.

Output is bounded: the link-down verdict reports the total count and
names only the first few interfaces, so the block stays a fixed number
of lines however many interfaces exist. That matters because the
diagnostic is printed immediately before the `NONZERO SCRIPT EXIT:`
marker the host's OCR watches for, and an unbounded block can push the
marker off the captured frame — turning a classified failure into an
unclassified timeout. For the same reason no message in this file may
contain the words "fetch" or "execute": they fuzzy-match the echoed
command line and would close a healthy run's OCR wait early.

`fetch-and-execute.sh` sources the library so a failing guest step can
attach this diagnostic to its failure output.

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
not installed is simply skipped:

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
  so a guest provisioned during a flap can still bake a valid CA from a
  prior good fetch of the same cache. When even that comes up empty (retry
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
  confirmed flap-during-provisioning failure into a pass. Installing the CA
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

## Cache-VM seed host binding

The caching-proxy-service `New-VM.ps1` scripts on all three drivers
bake the Yuruna host's (status service) IP and port into the seed so
the cache VM's cloud-init build block fetches collector/parser source
from the LOCAL host working tree (`/yuruna-repo/`) instead of public
github — a rebuild never waits on the private->public mirror.
`$env:YURUNA_GUEST_REACHABLE_HOST_IP` overrides the resolved host IP
on ubuntu.kvm and macos.utm (windows.hyper-v has no override); empty
values make the build fall back to github.
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
on any other segment is not a degraded answer, it is a wrong one, and
it is wrong in a way the guest can only discover after its seed has
been burned: the address resolves on the host, so nothing on the host
side fails, while the guest dials an address it holds no route to. An
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
Wi-Fi host, a VM bridged onto an uplink vmnet cannot bridge (no DHCP
lease, ever) with the VZ gateway baked in as the host address. Stash
and pool-control are therefore Shared on Wi-Fi, with `Add-PortMap`
publishing them to the LAN through the host — as is the download-agent
service. No choice of port is arbitrary: stash takes `:2222` because the
Mac's own sshd owns `:22`; pool-control takes `:8081` because the
caching-proxy already forwards `:80` for its CA-cert endpoint —
reusing it would publish the cache at the URL the
pool-control bring-up prints; and the download-agent service takes
`:8082`, the next free port clear of all three. Asking for one already
taken would silently publish the wrong service at that URL, so the
allocation is fixed per service rather than picked at run time:

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
once per VM creation — a warning would repeat the same line for every
guest of every cycle without ever asking the operator to do anything.
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
survival is therefore not evidence that the bridge works, and reusing a
switch on the strength of its existence hands every guest of every
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
naming the switch, the verdict and the remedy, and lets the cycle run;
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
precisely why this is an operator action with eyes on the console and
not something the runner does on its own.

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

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.06

Back to [Yuruna](../README.md)
