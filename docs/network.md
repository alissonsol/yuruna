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

## Package-manager retries

### Defining package-manager retry

Guest provisioning scripts call `apt-get` (Ubuntu) and `dnf` (Amazon
Linux 2023) to install workload dependencies. Both managers reach
external mirrors (`archive.ubuntu.com`, `cdn.amazonlinux.com`,
`packages.microsoft.com`, vendor PPAs, etc.) and both occasionally
fail mid-transaction on transient network conditions that recover
within seconds. Without a wrapper, a single flaky lookup aborts the
whole script via `set -e` and the cycle wastes its remaining budget.

**The failure mode that motivated this wrapper** (cycle 37 on a remote
macOS UTM host, captured at `/log/000037…/test-amazon-linux-2023-01/`):

```
Amazon Linux 2023 Kernel Livepatch repository    106 kB/s |  36 kB    00:00
...
Error: Error downloading packages:
  Curl error (6): Could not resolve hostname for
  https://cdn.amazonlinux.com/al2023/core/mirrors/.../mirror.list
  [Could not resolve host: cdn.amazonlinux.com]
```

The repo metadata refresh succeeded earlier in the same `dnf` call.
Two minutes later, the `saveSystemDiagnostic` SSH connect to the same
guest succeeded. The flap lasted less than the gap between dnf's own
in-process retries (which fire back-to-back inside librepo), so the
transaction reported failed even though the network was healthy a few
seconds later. Adjacent cycles (36 and 38) passed with the same code
on the same host.

The same pattern applies to apt: transient mirror flakes, DNS bounces
on first-boot DHCP, `Hash Sum mismatch` from a half-refreshed mirror
(see [squid dep11 LM-factor trap in memory.md](memory.md)).

**Contract.** Every guest script that uses a package manager declares
an `apt_retry` / `dnf_retry` helper after its arch-detection block and
wraps every package-manager call through it. The helper:

1. Runs up to **5 attempts**.
2. Sleeps with **exponential backoff**: 15 s, 30 s, 60 s, 120 s between
   attempts. Max total wait if all attempts fail: 225 s (~3:45).
3. Streams the wrapped command's stdout/stderr normally on each attempt
   so the log shows exactly what the package manager is doing.
4. Prints a labeled `!! apt_retry: attempt N/5 failed (rc=…)` banner
   between attempts so the log makes the retry visible.
5. After the final attempt returns the real exit code; `set -e` then
   aborts the script with a diagnosable failure.

**Call signature.** Generic — the helper takes the full command,
including the caller's `sudo` and any options:

```bash
apt_retry sudo apt-get update -y
apt_retry sudo apt-get install -y postgresql-18 postgresql-contrib-18

dnf_retry sudo dnf -y install libicu tar gzip
dnf_retry sudo dnf update -y
```

The two helper names (`apt_retry` / `dnf_retry`) share the same body
and exist only so the failure banner names the package manager
explicitly. macOS guests use `softwareupdate` (Apple's CDN already
retries internally) and need no equivalent wrapper.
