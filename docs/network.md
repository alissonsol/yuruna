# Yuruna network workarounds

This file collects rationale for network-related workarounds in guest
scripts and the host harness. Centralising the long explanations here
keeps the source comments short and the workarounds discoverable from
one place.

Source files reference an entry with a single line of the form:

```
# --- See https://yuruna.link/network#<topic-slug>
```

The fragment resolves to a `### Defining <topic>` heading in this file.
Slugs follow the standard GitHub Markdown rule: lowercase the heading
text, strip everything that isn't `[a-z0-9_ -]`, then replace spaces
with hyphens.

This file is the network-specific sibling of [Yuruna definitions](definition.md),
[Yuruna memory](memory.md) (historical / incident rationale), and
[vmconfig topic reference](vmconfig.md). The same `# --- See`
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

1. Cycle 37 on a remote macOS UTM host (dnf transient DNS):

   ```
   Error: Error downloading packages:
     Curl error (6): Could not resolve hostname for
     https://cdn.amazonlinux.com/al2023/core/mirrors/.../mirror.list
     [Could not resolve host: cdn.amazonlinux.com]
   ```

2. Cycle 101 on a remote Windows Hyper-V host (GitHub edge 502):

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
(see [squid dep11 LM-factor trap in memory.md](memory.md)).

**Library.** All three retry wrappers live in
[automation/yuruna-retry.sh](../automation/yuruna-retry.sh) — single
source of truth. The library is deployed to every supported guest by
cloud-init's `write_files:` (base64-encoded) at install time, landing
at `/usr/local/lib/yuruna/yuruna-retry.sh` before any provisioning
script runs. Guest scripts source it after their arch-detection block:

```
# --- See https://yuruna.link/network#defining-yuruna-retry-lib
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

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.12

Back to [Yuruna](../README.md)
