# Yuruna install scripts — rationale

This file collects the load-bearing rationale that used to live as inline
comments in the three bootstrap installers:

- [install/windows.hyper-v.ps1](../install/windows.hyper-v.ps1)
- [install/macos.utm.sh](../install/macos.utm.sh)
- [install/ubuntu.kvm.sh](../install/ubuntu.kvm.sh)

The scripts themselves stay deliberately small — each section in this file
maps to a `# -- Section name --` divider in the script body. The single
`# --- See https://yuruna.link/install/explained` line near the top of
each installer is the operator's entry point to this document; from there
they can navigate to the section that matches the block divider in front
of the code they are studying.

Anchors follow the GitHub Markdown rule: lowercase the heading, strip
punctuation, replace spaces with hyphens. So `## Section name` becomes
`#section-name`.

The same `# --- See https://yuruna.link/<key>#<slug>` convention is also
used by [memory.md](memory.md), [definition.md](definition.md),
[vmconfig.md](vmconfig.md), and [network.md](network.md).

---

## All hosts (shared rationale)

### Two-repo split

The installer ships in TWO repos that share the same script:

- public  `https://github.com/alissonsol/yuruna`       (clone works unauthenticated)
- private `https://github.com/alissonsol/yurunadev`    (clone needs GitHub auth)

The copy committed to each repo points the `$YurunaRepo` / `$YURUNA_REPO`
default at its OWN URL so the `irm | iex` (or `curl | bash`) one-liner
clones the repo the operator chose to download the script from. Both
constants stay defined regardless of which copy is running so the
existing-checkout logic further down can recognize the remote a previous
run cloned from — and skip a pull that would just stall waiting for
GitHub credentials this run doesn't have.

### System-requirements preflight

Tested baselines:

- Windows host: 32 GB RAM, 512 GB free on system drive, Windows 11
  Pro/Enterprise/Education or Windows Server with Hyper-V on AMD64,
  16+ physical cores.
- macOS host: 32 GB RAM, 512 GB free, macOS 26+ on arm64, 16+ cores.
- Ubuntu host: 32 GB RAM, 512 GB free, Ubuntu 26+ on amd64, 16+ cores.

Anything below is permitted but UNTESTED — the script prompts the
operator before proceeding so an under-spec'd host does not burn an hour
of installs only to fail in the first test cycle. The check is silent
when every requirement is met. On Windows it is gated by `-SkipPreflight`
so self-relaunches (UAC elevation, PS5→PS7 bootstrap) do not re-prompt.

### Stop running Yuruna processes before updating

Re-runs of the installer must be able to upgrade installed packages and
the repository in place. An active Yuruna test run or status server
would fight with the upgrade for the working tree and port 8080. The
patterns killed: `Invoke-TestRunner.ps1`, `Invoke-TestInnerRunner.ps1`,
`Test-Sequence.ps1`, `Start-StatusServer.ps1`. Port 8080 is also freed
if the status server is still holding it.

### Preserve the yuruna-caching-proxy VM

The cache VM (`yuruna-caching-proxy`, formerly `squid-cache`) holds tens
of GB of pre-fetched `.deb` / `.iso` content built up across prior test
cycles. The installer never stops Hyper-V VMs (no `Stop-VM` / `Remove-VM`
in any installer), so the cache survives re-runs by default.

On macOS the detection is two-signal: a TCP-connect probe to the recorded
cache IP on port 3128 (authoritative, Apple-Events-independent) and a
fallback `utmctl status` parse that treats every uncertain status as
"preserve". This is the signal that survives a non-graphical launch
(SSH, no Apple Events). The previous detector trusted only `utmctl
status` and treated every non-`started` result — INCLUDING `utmctl
could not reach UTM` — as "not running"; an installer launched over SSH
then quit UTM, and the orphan-bundle sweep deleted the cache.

If the cache is running OR its state is uncertain, the macOS installer
skips the UTM cask upgrade so a quit-UTM window does not let the
orphaned-bundle sweep delete the multi-GB squid spool.

### Pull from the local repo's remote, not the script's default

For an existing checkout the installer pulls from whatever remote the
local repo was cloned from — not from whichever `$YurunaRepo` /
`$YURUNA_REPO` default this copy of the installer ships. A previous run
may have cloned the OTHER repo (the public `yuruna` checkout works for
everyone; the private `yurunadev` checkout needs GitHub auth) and we
must not silently migrate the operator's local tree to a different
remote.

If the local remote is `yurunadev`, demonstrate access before
`git fetch`: `git ls-remote` fails fast on 401/403, sparing the operator
a stalled credential prompt or an error transcript that looks like the
test harness broke when really only auth was missing. The pull is
skipped (not the rest of the install) so a contributor on a flaky or
unauthenticated session can still keep iterating with the last-known-good
code on disk. `GIT_TERMINAL_PROMPT=0` fails fast on missing credentials
instead of blocking the installer on an interactive `Username:` prompt.

### Backup-and-reclone on non-ff pull

When `git pull --ff-only` cannot advance the local repo (uncommitted
changes, divergent commits, detached HEAD), rather than leaving the
installer in a half-updated state the script moves the existing checkout
aside as a timestamped `<dir>.backup.<stamp>` and re-clones fresh. The
final-summary block surfaces the backup path loudly so the operator can
salvage local edits before deleting it. The `test/status` runtime state
was already captured to TEMP by the preservation block above, so cycle
history survives this path.

### Renormalize line endings under .gitattributes

`.gitattributes` (committed at the repo root) locks LF for every text
type a Linux guest reads — `*.sh`, `*.yml`, `user-data`, `meta-data`,
etc. Adding `.gitattributes` does NOT rewrite files already in the
working tree: without this step a developer who originally cloned with
`core.autocrlf=true` still has `fetch-and-execute.sh` sitting on disk
as CRLF, the host status server serves those CRLF bytes byte-faithfully
to the guest, and the guest's bash chokes with `$'\r': command not
found` on line 2 of the script. The installer forces a one-shot rebuild
of the working tree from the index so every file picks up the `eol=`
rules.

`core.autocrlf=input` is pinned on the LOCAL repo too, so any future
file added without a matching `.gitattributes` rule still avoids CRLF
on commit. Local config beats global; the change does not touch the
user's other repos.

`.gitconfig.yuruna` (tracked at the repo root) is included via
`include.path = ../.gitconfig.yuruna` for `pull.rebase` +
`rebase.autoStash` defaults so `git pull` here rebases instead of
creating merge commits. `include.path` can hold multiple values, so the
include is added idempotently rather than overwriting whatever else the
operator may have included.

If the working tree has uncommitted changes, only the index is
renormalized (`git add --renormalize .`) so the installer does not
clobber local edits. Otherwise the index is emptied and `git reset
--hard HEAD` rebuilds every file under the current `.gitattributes`.

### Preserve test/status runtime state across clone-update

Re-running the installer on a host that has been executing test cycles
must not lose the dashboard's history, per-cycle log transcripts, or
the runtime-dir state (`status.json` with `history[]`,
`runner.gating.json`, `runner.pid`, control flags). None of those are
tracked by git — per `.gitignore` every subdir under `test/status/` is
gitignored as runtime state. The clone/update/renormalize block is
designed to leave untracked files alone (`git rm -r --cached . &&
git reset --hard HEAD` only touches tracked files), but the installer
backstops that contract with an explicit snapshot-and-restore so a
future regression in the renormalize logic, or a manual delete of
`$YurunaDir` between attempts, cannot silently wipe weeks of cycle
history.

All harness runtime state lives under `test/status/<sub>/` for the
layout introduced in the status reorg: `runtime/`, `perf/`, `log/`,
`extension/`, `captures/`, `ssh/`. The installer preserves every subdir
so cycle history, perf JSONL, vault state, training/sequence captures,
and the generated SSH key pair all survive a clone/update.

### Baseline reset removes test-* VMs

An install is a return-to-baseline operation. Status server + runner
processes are killed earlier (`stop_yuruna_processes` / `Stop-YurunaProcess`);
their VMs are not. `test/Remove-TestVMFiles.ps1` enumerates VMs matching
the `test-` prefix and stops + removes each. The `yuruna-caching-proxy`
VM does NOT match this prefix and is preserved. Failure here is
non-fatal — a wedged hypervisor helper or locked image file on one VM
must not block the rest of the install. The step runs AFTER the repo
update so we use the just-pulled version of the script and its host
driver modules.

On Ubuntu, group activation needs care: `usermod -aG libvirt $USER`
adds the user to `/etc/group`, but the CURRENT shell's effective group
set was sampled at login and won't include `libvirt` until a re-login
or `newgrp`. Calling `pwsh` directly inherits the parent's stale group
set, so `virsh` fails with "Permission denied" on
`/var/run/libvirt/libvirt-sock` the very first time after group add.
`sg libvirt -c '<cmd>'` runs a subshell with libvirt as an effective
supplementary group, which works the instant `/etc/group` has the
membership — no re-login required.

### Enable-TestAutomation.ps1 is NOT auto-run

`host/<platform>/Enable-TestAutomation.ps1` is the explicit opt-in step
that turns a machine into a Yuruna test host (display sleep, screen
saver, screen-lock registry edits, storage-pool tweaks, Accessibility /
Screen Recording grants on macOS). Those are host-policy changes the
operator may not want, so they are left for manual invocation after
install.

### powershell-yaml install

`powershell-yaml` is required by `Resolve-CyclePlan` and every YAML
reader in the harness. pwsh 7 does NOT ship it, and `test/Test-Project.ps1`
preflight fails fast with "powershell-yaml is not installed" if the
module is missing — which used to be the friction of every fresh-host
bootstrap. Each installer now installs `powershell-yaml` (CurrentUser
scope, `-Force -AllowClobber` to auto-trust PSGallery on a fresh box).
`Install-PowerShellYamlIfMissing` in
[test/modules/Test.Host.psm1](../test/modules/Test.Host.psm1) is still
called from `Enable-TestAutomation.ps1` as a safety net for manual-clone
bootstraps.

---

## Windows Hyper-V

### ASCII-only constraint

`install/windows.hyper-v.ps1` is invoked from a fresh Windows where
`pwsh.exe` does not yet exist, via `irm <url> | iex` from the only shell
that ships in-box: Windows PowerShell 5.1. PS 5.1's `Invoke-RestMethod`
does NOT strip a leading UTF-8 BOM. When the response string is piped to
`iex`, the BOM character (`U+FEFF`) becomes the first parse token and
PS 5.1's parser stops recognising `param()` as a top-of-script
construct, failing at the `[CmdletBinding()]` line with `Unexpected
attribute 'CmdletBinding'`.

Direct invocation as a file works either way — both PS 5.1 and pwsh
handle BOM-prefixed files on disk — but the `irm | iex` path is the
documented installer entry point and it MUST work. So every comment,
string, here-doc, and identifier in the installer file MUST stay plain
7-bit ASCII. No em-dashes, no smart quotes, no box-drawing characters.
If a future edit introduces non-ASCII content, replace it with an ASCII
equivalent (e.g. `--` instead of an em-dash) rather than adding a BOM.

This is also captured in [memory.md](memory.md) under "Why the bootstrap
installer must stay ASCII-only?".

### param() default + irm | iex compatibility

The `[CmdletBinding()]` + `param()` block is at line 74 (after
`<#PSScriptInfo #>` and `<# .SYNOPSIS #>` headers). PS 5.1's `iex`
accepts `param()` as a top-of-script construct ONLY when the input has
no leading BOM and `param()` is positioned after the comment-based help
blocks. Both conditions are constraints on the file's byte layout, not
on PowerShell syntax.

### Self-elevation and PS5 → PS7 bootstrap

Every Yuruna script that needs elevation says so up front rather than
surprising the user midway through. After a `Test-SystemRequirement`
preflight gate, the script self-elevates via `Start-Process -Verb RunAs`
if not already running as Administrator. The relaunch preserves the
shell the user started from — `powershell.exe` on PS 5.1, `pwsh.exe`
on PS 7+ — so a pwsh session does not get silently downgraded to
Windows PowerShell across the UAC boundary.

For the `irm | iex` entry path the downloaded script has no
`$PSCommandPath`, and `iex` itself does not forward args to the invoked
code. The relaunch handler reconstructs an `iex`-equivalent bootstrap
that re-downloads the script and invokes it via
`[scriptblock]::Create(...)` with `-SkipPreflight` so the elevated
child does not re-prompt the requirements check.

If the elevated shell is still PS 5.x, the PS7 bootstrap block installs
`Microsoft.PowerShell` via winget, refreshes PATH so `pwsh.exe`
resolves in this same session, and re-executes the script under pwsh.
The child inherits the elevated token, so no second UAC prompt. The
PS7-bootstrap block must stay PS 5.1-compatible (no `?.` / `??` /
ternary / chain ops) — the whole file is parsed up front, and even one
PS 7-only token would fail the file to load on 5.1 before this check
can run.

Return (not exit) is used at every relaunch site. `exit` at the script's
top level terminates the hosting PowerShell process, which would close
the user's own shell when the script is invoked via `irm | iex` in
their non-admin console.

### winget --source winget pinning

Without `--source winget` on every call, winget searches every
registered source (including msstore) and fails hard when one of them
has a stale or untrusted server cert, even if the package was found in
the trusted `winget` source. Seen in the wild as:

```
Failed when searching source: msstore
0x8a15005e : The server certificate did not match any of the
             expected values.
```

When that happens winget refuses to pick a source automatically and
aborts with "Please specify one of them using the `--source` option to
proceed." Pinning sidesteps the disambiguation.

### DISM.exe direct call, not Get-/Enable-WindowsOptionalFeature

`Get-WindowsOptionalFeature` / `Enable-WindowsOptionalFeature` dispatch
to the DISM provider via COM, and on some pwsh 7 sessions the COM class
fails to resolve with `Class not registered` (HRESULT `0x80040154`).
That terminates the script on re-runs; and when
`-ErrorAction SilentlyContinue` silences it on the first run, the
returned `$feature` becomes `$null` and the enable step is skipped
without the user noticing — which is why the first run of an earlier
revision of this installer could leave Hyper-V off. `DISM.exe` is a
plain Win32 tool with no COM dependency and is what the cmdlets wrap
internally.

### DISM "Enabled" cross-check against vmms presence

`DISM /Enable-Feature` flips State to `Enabled` immediately, but the
Hyper-V *components* (`vmms` service, `virtmgmt.msc`) are only deployed
once the pending reboot runs. On a second pass before that reboot,
`/Get-FeatureInfo` still says `Enabled` even though nothing actually
works — and the test harness would fail to launch `virtmgmt.msc` with
"file not found". The installer cross-checks DISM's `Enabled` against
the presence of `vmms` and `virtmgmt.msc`; if either is missing, the
script treats it as just-enabled and sets `$script:RestartNeeded` so
the finally-block "RESTART REQUIRED" path gives the user one clear
message.

### try/catch/finally with summary banner

Every install path (success, failure, reboot-pending) is wrapped in a
single `try/catch/finally`. The admin window spawned by
`Start-Process -Verb RunAs` closes the instant the script exits, and
without the wrap any failure (DISM exit code, winget non-zero, throw
from a called module) would close the window before the user could
read the message. The finally block prints a clear SUCCESS / FAILED /
RESTART REQUIRED summary and — on the success path — automates the
handoff to a fresh pwsh window with NEXT STEPS guidance.

There is no `exit 1` in the failure branch. That would terminate the
hosting PowerShell process, closing the user's own window when they
invoked the script directly. Falling through the finally block leaves
the user at their shell prompt.

### Handoff window with EncodedCommand

All NEXT STEPS guidance lives inside the spawned pwsh window's welcome
banner. The admin console this script is running in was spawned by the
self-elevation block via `Start-Process -Verb RunAs` and closes the
moment we return. Anything we `Write-Output` AFTER that exit is
unreadable — which is why a previous revision's NEXT STEPS block
vanished before the user could read it.

The handoff window is launched via `pwsh -NoExit -EncodedCommand <base64>`
to sidestep every shell-quoting pitfall for the spawned process.
pwsh.exe expects the base64 payload as UTF-16LE (Unicode) bytes. If
the handoff window doesn't open, the same guidance is printed in the
admin console with a 60-second `Start-Sleep` to keep the window readable
(no `Read-Host`, so an accidental Enter cannot end things early).

### Test-SystemRequirement is silent on success

The Windows preflight is silent when every requirement is met so an
operator on a tested box gets no extra noise. It only prints when
something is below baseline. The function uses `Get-CimInstance` (more
portable than WMI) and converts `TotalVisibleMemorySize` (KB) to GB via
`/ 1MB`.

### Display scaling check

Tesseract OCR on VM screenshots degrades when the host display scales
above 100%. vmconnect renders the guest framebuffer through the
DPI-scaled compositor; the upscaled bitmap defeats Tesseract
segmentation — `waitForText` silently times out on text a human reads
fine. Fresh Windows 11 (HiDPI, 4K) ships at 125–150% by default, so
this trap hits new hosts the first time they run a cycle.

The installer's preflight in
[install/windows.hyper-v.ps1](../install/windows.hyper-v.ps1)
(`Test-DisplayScaling`) is **warn-only** — it never blocks the install.
It reads three registry sources that can override the default 100%:

- `HKCU\Control Panel\Desktop\PerMonitorSettings\<display-id>\DpiValue`
  (per-monitor scale; Windows 10/11). The value is an offset from
  `RecommendedDpiValue` — 100% maps to `-recommended` regardless of the
  monitor's own recommended scale. Each step is +25%.
- `HKCU\Control Panel\Desktop\LogPixels` (system-wide DPI fallback for
  non-per-monitor-aware processes). Default is 96 (= 100%).
- `HKCU\Software\Microsoft\Accessibility\TextScaleFactor` (Windows 11
  "Text size" — independent of display scale; 100 to 225).

REG_DWORD values can be signed (DpiValue is often negative). The
installer uses the same UInt32→Int32 bit-reinterpret as the module's
reset function — a bare `[int]` cast on values with the high bit set
throws `OverflowException`.

The corresponding reset action lives in
[test/modules/Test.Host.psm1](../test/modules/Test.Host.psm1)
`Set-WindowsHostConditionSet`, called by
[host/windows.hyper-v/Enable-TestAutomation.ps1](../host/windows.hyper-v/Enable-TestAutomation.ps1).
It writes 100% to all three sources and emits per-monitor status lines
via `Write-Information`. The Enable-TestAutomation script sets
`$InformationPreference = 'Continue'` so those messages actually
surface to the operator (without the preference set, they're silent —
and the script's own header would lie about "informing of each
action"). Changes take effect after the operator signs out and back in
(or reboots) — `Set-WindowsHostConditionSet` emits a
`Write-Warning` reminder when any value was changed.

The install-side reader and the module-side reset deliberately
duplicate the three-source logic rather than share a module function:
the install preflight runs **before** the repo is cloned, so it cannot
`Import-Module Test.Host`. The shared knowledge is in this section,
not in code.

---

## macOS UTM

### Xcode CLT prereq for Homebrew

The installer waits for `xcode-select -p` to succeed in a poll loop
because `xcode-select --install` triggers a GUI prompt that the
operator has to dismiss. Skipping this would leave Homebrew unable to
build any source-only formula.

### Homebrew architecture detection

`brew shellenv` lives at `/opt/homebrew/bin/brew` on Apple Silicon and
`/usr/local/bin/brew` on Intel. The installer probes both and `eval`s
the right one so subsequent steps see `brew` on PATH regardless of CPU.

### Quit UTM before cask upgrade, preserve cache if running

`brew upgrade --cask utm` requires UTM closed. The installer
gracefully quits UTM via AppleScript (`tell application "UTM" to quit`)
and falls back to `pkill` if it refuses. If the squid-cache VM is
running (see [Preserve the yuruna-caching-proxy VM](#preserve-the-yuruna-caching-proxy-vm)),
the UTM cask upgrade is skipped this run; it gets upgraded on the next
install re-run when the cache happens to be stopped (or when the
operator quits UTM manually).

### brew_ensure_formula vs brew_ensure_cask

PowerShell ships as a brew formula on some taps and a cask on others.
The installer tries the formula first via `brew_ensure_formula
powershell`; if that fails it falls back to `brew_ensure_cask
powershell`. Either path leaves `pwsh` on PATH for subsequent steps.

### TCC permissions stay manual

macOS TCC (Privacy & Security → Accessibility, Screen Recording)
requires a human click in System Settings — no script (even with sudo)
can toggle Accessibility for another process. The installer prints
the System Settings path in the NEXT STEPS banner instead of trying
to automate.

### sudo announcement + keepalive

Every Yuruna script that needs elevation says so up front. The
installer primes sudo a single time so the Homebrew installer and cask
post-installs all reuse the same timestamp. A background keepalive
re-runs `sudo -n true` every 30s so the timestamp does not expire
mid-install while brew is running its own internal sudo calls.

`|| true` in the keepalive is load-bearing: under `set -e` (top of
file), a transient `sudo -n true` failure — e.g. brief timestamp-lock
contention while brew/cask post-install runs its own sudo — would
otherwise kill the subshell.

A single `EXIT` trap (`yuruna_install_cleanup`) releases the sudo
keepalive AND any test/status temp backup on every exit path: normal
completion, Ctrl-C, `set -e` abort.

### Activate Homebrew PATH in the caller's shell

The installer runs in its own subshell, so `brew`, `pwsh`, `git` from
Homebrew are not yet visible to the shell the user pasted the curl
command into. The NEXT STEPS banner tells them to either open a new
Terminal window or run `eval "$($BREW_PREFIX/bin/brew shellenv)"` to
patch the current session.

---

## Ubuntu KVM/libvirt

### ERR trap + _yuruna_step tracking

Under `set -euo pipefail` the shell quits silently on the first
non-zero command. An earlier revision silently aborted right after
"Refreshing apt index" with no message — the apt-get or apt-cache
probe failed and the operator had no way to see why.

`log()` records the current phase in `$_yuruna_step`. The `ERR` trap
fires before exit and prints the location (`$BASH_LINENO[0]`),
command (`$BASH_COMMAND`), and captured exit status. The next failure
is actionable instead of silent.

### CPU virtualization preflight (vmx/svm)

KVM acceleration requires Intel VT-x or AMD-V. The hard preflight
greps `/proc/cpuinfo` for `vmx|svm` — without acceleration the test
harness is unusable, so the installer refuses to burn time on apt/repo
work when the host obviously cannot host VMs. On aarch64 hosts where
`/proc/cpuinfo` does not expose `vmx`/`svm`, the check defers to the
post-install `/dev/kvm` assertion in the final preflight.

### Refresh apt index BEFORE probing for qemu-system-<arch>-hwe

On a fresh image the apt cache may not yet know that the `-hwe`
variant exists, and the probe would fall back to the base package even
though the HWE one is available. `apt-get update -q` (one quiet, not
`-qq`) keeps apt warnings and connectivity errors visible. With `-qq`,
a hung mirror or a signature verification failure aborted the script
with zero output, which made the silent exit "just after Refreshing
apt index" impossible to diagnose without re-running with `-x`.

### qemu-kvm split on Ubuntu 26.04 (resolute)

`qemu-kvm` is a VIRTUAL package starting with Ubuntu 26.04 — apt
refuses to pick between `qemu-system-<arch>` and
`qemu-system-<arch>-hwe` automatically. The installer defaults to the
GA (non-HWE) variant: it pulls in `ubuntu-virt`, which is the SAME
umbrella the rest of our packages (`libvirt-daemon-system`,
`libvirt-clients`, `ovmf`, `qemu-utils`, `virtinst`) depend on. The
`-hwe` variant depends on `ubuntu-virt-hwe`, which *Conflicts* with
`ubuntu-virt`, so any attempt to use `-hwe` while keeping the rest of
the stack on the GA branch produces an apt "two conflicting
assignments" error. Operator override: `YURUNA_QEMU_PKG=qemu-system-x86-hwe`
to try `-hwe` anyway once a future LTS ships matching `-hwe` libvirt
and ovmf.

### apt simulate-first

The installer runs apt's solver in `--simulate` mode FIRST. If a
dependency conflict exists — e.g. `-hwe` qemu pulling `ubuntu-virt-hwe`
against the rest of the stack's `ubuntu-virt` — it surfaces here
BEFORE we start actually installing anything, with the same "X depends
Y but it is not going to be installed" diagnostic the real install
would emit. `set -e` + the ERR trap means a non-zero apt-get exit
prints the abort block naming this step.

### osinfo-db refresh from pagure

Noble's apt-shipped `osinfo-db` can predate Ubuntu 24.04's release, so
`virt-install --osinfo list` may not include `ubuntu24.04` even after
the apt package is installed. Per-guest scripts already fall back to
`linux2022` when the precise variant is missing, but the operator is
better off with proper hypervisor tuning.

Best-effort upstream refresh: scrape `releases.pagure.org/libosinfo/`
for the latest `osinfo-db-YYYYMMDD.tar.xz`, fetch it, and import
system-wide via `osinfo-db-import --local` (writes to
`/usr/local/share/osinfo`, which libosinfo searches unconditionally on
Ubuntu). Any failure (no network, pagure.org down, malformed tarball)
emits a `warn` line and proceeds.

Variant lookup uses a regex match against `virt-install --osinfo list`
output. Each line is `<canonical-id>, <alias1> <alias2>` — so a naive
`grep -qx 'ubuntu24.04'` never matches because the line is actually
`ubuntu24.04, ubuntunoble`. `osinfo_has_variant` strips the alias
tail before exact-matching, which is what we actually want. That bug
masked the upstream-import success and kept the warning printing in
perpetuity before the regex fix.

### PowerShell apt vs tarball by architecture

x86_64 gets `powershell` from Microsoft's apt repo (canonical source).
aarch64 has no apt package, so the installer falls back to the
PowerShell tarball under `/opt/microsoft/powershell/7` with a
`/usr/local/bin/pwsh` symlink. Both paths leave `pwsh` on PATH for
subsequent steps. The tarball is pinned to a known LTS line
(`PWSH_VERSION=7.4.6`) since the 7.4.x stream maintains aarch64 builds.

### libvirt-qemu traverse ACL on $HOME

Ubuntu 24.04 cloud images create `/home/<user>` at mode 0750, which
blocks the `libvirt-qemu` user (uid 64055, gid kvm) that runs guest
qemu processes from traversing `$HOME` to reach VM disk files.
`virt-install` then errors out with "Cannot access storage file ...
Permission denied". The installer applies the traverse-only POSIX ACL
(`setfacl -m u:libvirt-qemu:--x "$HOME"`) up front so the operator
does not discover this the first time `New-VM.ps1` runs.

The final preflight verifies `libvirt-qemu` can actually reach files
under `$HOME` by `mktemp`-ing a probe file (mode 0644 — `mktemp`'s
default of 0600 would always fail the cross-user read regardless of
traverse), then `sudo -u libvirt-qemu test -r <probe>`. The test
isolates the directory-traverse question from the file-mode question.

### Default libvirt network — start + autostart

The `default` NAT network (`192.168.122.0/24`) is shipped by
`libvirt-daemon-system` but starts disabled. The installer ensures
it's autostart + up so `virt-install` can attach guests without a
manual `virsh net-start`.

### Final preflight — every check is a hard requirement

Up to the preflight section the installer APPLIED configuration. The
preflight VERIFIES the host actually reached the state
`Invoke-TestRunner.ps1` needs. Every check is a hard requirement; the
script collects all failures so the operator sees the full punch list
at once instead of fix-and-rerun N times. A partial install is worse
than no install — subsequent runs see "looks configured" and skip
steps that would have re-applied them.

The checks cover: `kvm-ok`, `/dev/kvm` character device, group
membership in `/etc/group` (the parent shell's stale group set is the
operator's problem, surfaced as a NEXT STEPS hint), `libvirtd` +
`virtlogd` systemd services active, `libvirt-qemu` system user
present, libvirt `default` network running + autostart,
`libvirt-qemu` `$HOME` traverse ACL working in practice, cloud-init
seed builder (`genisoimage` or `cloud-localds`), `pwsh` on PATH,
`virt-install` on PATH, osinfo-db variants the per-guest scripts
request, architecture-specific UEFI firmware (`ovmf` /
`qemu-efi-aarch64`), swtpm + swtpm_setup, GitHub CLI on PATH.

### GitHub CLI via cli.github.com apt repo

`gh` is not pinned to a current version in Ubuntu's default archive.
The installer follows cli.github.com's recommended apt-repo install:
keyring under `/etc/apt/keyrings`, repo source under
`/etc/apt/sources.list.d`, then `apt-get install gh`. Idempotent on
re-runs — an existing keyring or source-list file triggers a no-op.
The binary lands on PATH but is unauthenticated — `gh auth login`
once per host to authenticate.

### sg libvirt for the first-run cleanup

The `Remove-TestVMFiles.ps1` cleanup runs right after `usermod -aG
libvirt $USER`, so the current shell's group set does not yet include
`libvirt` and a direct `pwsh -File` call would inherit the stale
group set and fail with "Permission denied" on
`/var/run/libvirt/libvirt-sock`. `sg libvirt -c "pwsh ..."` runs a
subshell with libvirt as an effective supplementary group, which
works the instant `/etc/group` has the membership — no re-login
required.

`getent group libvirt` reads `/etc/group`, which `usermod -aG` has
just updated. Don't use `id -nG` here: it reflects the stale live
group set of THIS shell and would force the direct-pwsh fallback on
the first run.
