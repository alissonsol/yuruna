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

On macOS UTM the fetch has an extra reason to run host-side: guests on VZ
shared-NAT cannot reach the cache VM directly, but the host can.

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

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.07.10

Back to [Yuruna](../README.md)
