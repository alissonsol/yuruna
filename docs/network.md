# Yuruna network workarounds

This file collects rationale for network-related workarounds in guest
scripts and the host harness. Centralising the long explanations here
keeps the source comments short and the workarounds discoverable from
one place.

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
CDNs that occasionally fail on transient network conditions that
recover within seconds. Without a wrapper, a single flaky lookup
aborts the whole script via `set -e` and the cycle wastes its
remaining budget.

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

**Library.** All three retry wrappers live in
[automation/yuruna-retry.sh](../automation/yuruna-retry.sh) — single
source of truth. The library is deployed to every supported guest by
cloud-init's `write_files:` (base64-encoded) at install time, landing
at `/usr/local/lib/yuruna/yuruna-retry.sh` before any provisioning
script runs. Guest scripts source it after their arch-detection block:

```
# --- REGION: https://yuruna.link/network#defining-yuruna-retry-lib
. /usr/local/lib/yuruna/yuruna-retry.sh
```

The library exports four functions:

| Function | Wraps | Notes |
|---|---|---|
| `apt_retry`  | `apt-get …` | Ubuntu 24/26 guests |
| `dnf_retry`  | `dnf …`     | Amazon Linux 2023 guests |
| `curl_retry` | `curl …`    | Any caller; prepends `--retry 3 --retry-connrefused --retry-delay 5` so curl handles transient HTTP 5xx + connection-refused in-process before the outer attempt loop fires. Deliberately NOT `--retry-all-errors`: that would also retry 4xx (auth failures, 404s), which are non-transient and only waste attempts. |
| `pwsh_retry` | `sudo pwsh …` | Body on stdin (here-doc), piped to `sudo pwsh -NoProfile -Command -`. All pwsh streams (stdout, stderr, verbose, warning, information) appended to a caller-supplied log file under `/var/log/yuruna/` with a UTC-stamped per-attempt header. The log is the failure-collector handoff — see [`Defining Get-SystemDiagnostic`](definition.md#defining-get-systemdiagnostic), GUEST PROVISIONING section. Body must `throw` / `exit 1` on its own failure conditions (retry is driven by pwsh's exit code). Stdin pipe instead of a positional `-Command` arg avoids both the [32 K CreateProcess cmdline cap](memory.md#why-the-bootstrap-installer-must-stay-ascii-only) class and the quote-escaping pit. |

**Outer-loop behavior** (all three wrappers share `_yuruna_retry`):

1. Runs up to **5 attempts** (override via `YURUNA_RETRY_MAX_ATTEMPTS`).
2. Sleeps with **exponential backoff**: 10 s, 20 s, 40 s, 80 s, 160 s
   between attempts (override via `YURUNA_RETRY_DELAY`). Max total
   wait if all attempts fail: ~5 min.
3. Streams the wrapped command's stdout/stderr normally so the log
   shows exactly what the wrapped tool is doing.
4. Prints `!! <name>: attempt N/5 failed (rc=…)` banners between
   attempts so the log makes the retry visible.
5. After the final attempt returns the real exit code; `set -e` then
   aborts the script with a diagnosable failure.

For `curl_retry`, curl's own `--retry 3 --retry-connrefused` fires
first (sub-30 s for transient 5xx + ECONNREFUSED). Combined budget:
5 outer × 3 inner = 15 effective attempts — still bounded, sized for
a one-shot provisioning script under `set -euo pipefail`. 4xx
responses are NOT retried by curl (intentional — see the table above);
they propagate to the caller immediately.

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
| `YURUNA_K8S_MINOR` | Kubernetes apt-repo minor track (`pkgs.k8s.io/core:/stable:/v<minor>/deb`) | Ubuntu/AL2023 `*.k8s.sh` |
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
non-virtual) interfaces and flags any that are carrier-up yet hold no
global IPv4 address.

That "carrier up, no IPv4" state is the signal worth surfacing. A
carrier-up interface with neither a static address nor a DHCP lease
usually means **DHCP pool exhaustion**: on a bridged hypervisor the
guest competes with every other LAN client for the router's finite lease
pool, and a fast-booting guest that loses the lease race comes up with
only an IPv6 SLAAC address and no IPv4. IPv6-via-RA needs no DHCP server,
so its presence does not clear the flag. Other causes the banner names:
the DHCP server is down, a VLAN/cabling fault, or the link is not
forwarding yet.

`fetch-and-execute.sh` sources the library so a failing guest step can
attach this diagnostic to its failure output.

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

The probe MUST match whichever manager actually owns the link: server
spins default to systemd-networkd (where `nm-online` is absent), while
NetworkManager spins ship `nm-online`. A probe keyed on the wrong
manager silently no-ops — skipping the settle entirely — or blocks its
full timeout for nothing, so the scripts branch on the active manager.
Every branch is capped at 30 s so a broken stack cannot hang the cycle,
and non-zero exits are swallowed so `set -e` does not abort.

## Caching-proxy CA cert rc60 gate

The Ubuntu `New-VM.ps1` scripts fetch the caching-proxy CA certificate on
the host and base64-embed it in the autoinstall seed
(`CA_CERT_BASE64_PLACEHOLDER`). The installer's late-commands write the
cert before any HTTPS apt fetch, so SSL-bump caching works from the first
install request.

An empty `$CaCertBase64` is NOT a harmless no-op: the seed still routes
the guest's HTTPS through the bump (`:3129`) and locks direct `:443`
egress, so a CA-less guest fails every HTTPS request with curl rc=60
("self-signed certificate in certificate chain"). That is why the CA
fetch is retried under the shared capped-backoff policy — one blip
against a slow or flapping caching proxy must not strand the guest
without the CA. See the memory capture
`feedback_sslbump_rc60_untrusted_chain_and_ca_gate_trap` for the incident
class.

A finite host-side retry budget can still be outlasted by a longer proxy
flap, so the empty-CA case is recovered at two further layers without
relaxing egress (`project_sslbump_ca_gating_durable_fix`):

- **Host-side fallback.** `Get-CachingProxyCaCertBase64` (in
  `Test.CachingProxy.psm1`, shared by all six ubuntu `New-VM.ps1`) persists
  each successfully fetched CA into the `yuruna-caching-proxy.yml` state
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
  rc=60 state with a clear diagnostic — never a silent pass, and never an
  abort of the update run by the self-heal itself.

On macOS UTM the fetch has an extra reason to run host-side: guests on VZ
shared-NAT cannot reach the cache VM directly, but the host can. The UTM
scripts must also resolve **which IP** serves the CA:

- An **external cache** (`YURUNA_CACHING_PROXY_IP` set to a valid IP) wins:
  `$CachingProxyUrl` already points at the remote IP (no VZ-gateway
  rewrite), and the remote cache image is identical to the local one — the
  same Apache on `:80` serves `/yuruna-squid-ca.crt`. The
  `yuruna-caching-proxy.yml` state file is not updated for external caches,
  so the IP is read straight from the environment variable.
- Otherwise the persisted state file's `ipAddress` is used when it parses
  as an IP.
- When a proxy URL is set but neither source yields an IP, the script warns
  instead of silently skipping the fetch; the guest boots CA-less and
  relies on the update-time self-heal above.

## UTM cache-VM bridged discovery

### Defining utm cache vm bridged discovery

The macOS UTM ubuntu `New-VM.ps1` scripts detect the caching proxy and
inject its proxy URL into the autoinstall seed when available. The cache
VM is bridged to the host's physical NIC
(`VZBridgedNetworkDeviceAttachment` in `config.plist.template`), so it
carries its own LAN DHCP IP — e.g. `http://192.168.7.150:3128`. Install
VMs on shared NAT reach that LAN IP through VMnet's outbound NAT (the
same path they use to reach Ubuntu mirrors), so no host-side TCP
forwarder layer is needed. Discovery delegates to
`Test-CachingProxyAvailable`, which owns the (state-file fast path ->
LAN /24 scan -> state refresh) logic.

Severity policy:

- `Test-CachingProxyAvailable` returns a URL -> inject it.
- `utmctl` sees the cache VM started but no `:3128` answer on the LAN ->
  ERROR, exit 1 (the cache came up but is not on the LAN; a bridge
  interface or DHCP problem).
- Cache VM not registered / not started -> WARNING, proceed direct.

## Registry rate limits disguised as 400

### Defining registry rate limit 400

Workload scripts that `docker run` a local registry container detect
upstream pull throttling in the failure output before deciding whether
to retry. Two shapes must both match:

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
guest base, or check the caching proxy's zot endpoint) and exit
immediately instead of burning the remaining retry budget on a
foregone conclusion.

## Apt signing-key fingerprint verification

The Ubuntu guest provisioning scripts (`*.k8s.sh`, `*.code.sh`) fetch
third-party apt signing keys — Docker
(`download.docker.com/linux/ubuntu/gpg`), Kubernetes
(`pkgs.k8s.io/.../Release.key`), and Microsoft
(`packages.microsoft.com/keys/microsoft.asc`) — over the guest's
SSL-bump caching proxy, which is a **trust boundary**: a tampering proxy
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
installer, never `get-helm-3`: the v3 script resolves its default version
from `get.helm.sh/helm3-latest-version`, so it can only ever land a 3.x
binary no matter what `Yuruna.Requirement.yml` asks for — a guest
provisioned with it could never satisfy the Helm requirement, however that
requirement is bumped. Passing `DESIRED_VERSION=v$YURUNA_HELM_VERSION`
pins the exact release (the installer verifies the tarball checksum) and
keeps the guest off the unauthenticated "latest" lookup — see
[`Defining yuruna versions pins`](#defining-yuruna-versions-pins).

The installer downloads the binary with its own un-retried curl/wget, so
a single transient blip leaves helm uninstalled. The scripts therefore
capture the installer script once with `curl_retry`, run it under
`_yuruna_retry` (same capped backoff as every other fetch), and then
verify the binary actually landed: a swallowed failure here otherwise
surfaces far away as a `helm: not recognized` abort in the k8s.website
workload.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.17

Back to [Yuruna](../README.md)
