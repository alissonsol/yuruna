# Yuruna memory

This file collects load-bearing rationale comments that used to live
inline in the codebase. Long historical explanations — "this code is
shaped this way because of incident X on date Y" — drift out of date
when scattered across files; one place is easier to update and
cross-reference.

Source files stay short — each large comment block collapses to a
single line of the form:

```
# --- REGION: https://yuruna.link/memory#<topic-slug>
```

The fragment resolves to a `### Why <topic>?` heading in this file.
Slugs follow the GitHub Markdown rule: lowercase the heading text,
strip everything that isn't `[a-z0-9_ -]`, then replace spaces with
hyphens. So `### Why we patch virt-install's phase-1 XML on KVM` becomes
`#why-we-patch-virt-installs-phase-1-xml-on-kvm`.

Siblings of this file: [Yuruna definitions](definition.md) (terminology),
[vmconfig topic reference](vmconfig.md) (`user-data` topic rationale),
and [Yuruna network workarounds](network.md) (network-specific
rationale). All four use the same `# --- REGION:` convention.

Adding a new entry:

1. Pick the source comment block.
2. Add a `### Why <topic>?` heading here with the migrated content.
3. Replace the source comment with a single
   `# --- REGION: https://yuruna.link/memory#<slug>` line (or `// --- REGION: …`
   for Go, etc.).
4. The yuruna.link `memory` key already redirects to this file on
   GitHub — individual topics need no `yuruna.link.json` edit.

---

## Build / install path

### Why we patch virt-install's phase-1 XML on KVM

The ubuntu.server.24 KVM guest uses `virt-install --cdrom --print-xml=1`,
patches the emitted XML, then `virsh define` + `virsh start` instead of
letting virt-install orchestrate the install. Each piece addresses a
specific virt-install behavior:

- **`--cdrom $baseImageFile` is the install method.** virt-install
  rejects the domain build without one of
  `--location` / `--cdrom` / `--pxe` / `--import` /
  `--boot hd|cdrom`; `--boot cdrom,hd` is not accepted as a
  substitute. The cidata `seed.iso` is added as a SECOND cdrom via
  `--disk` so subiquity can find it at `/dev/sr1` and consume the
  autoinstall config; `--cdrom` owns the install media slot and only
  takes one path.
- **`--wait 0` is critical.** With `--cdrom`, virt-install blocks by
  default until the install completes (~5–10 min). The test runner
  expects `New-VM.ps1` to return promptly so the GUI sequence can pick
  up at "Continue with autoinstall?". `--wait 0` returns immediately
  after defining + starting the domain.
- **UEFI on x86_64** matches the macOS UTM and Hyper-V variants, both
  UEFI-only by their hypervisor's choice. `ubuntu-installer`
  uses `efibootmgr` to add an `ubuntu` UEFI boot entry that takes
  priority over the CDROM in the firmware boot order, so the
  post-install reboot lands on the installed disk's GRUB. Without UEFI
  on legacy BIOS the CDROM would still be priority-1 and the live ISO
  would re-trigger autoinstall in a loop. `ovmf` is pulled by
  `install/ubuntu.kvm.sh` on x86_64; aarch64 already required UEFI
  (no BIOS on virt machine type).
- **The on_reboot dance.** virt-install's `--cdrom` install path is
  two-phase. Phase 1 bakes `<on_reboot>destroy</on_reboot>` into the
  install XML — that's how virt-install detects "install reboot just
  happened": libvirt destroys the domain on reboot, virt-install sees
  it gone, generates phase 2 XML (no install media,
  `on_reboot=restart`) and starts the domain again. The
  `--events on_reboot=restart` flag does NOT override
  phase 1's hardcoded destroy; verified empirically — subiquity's
  post-install reboot at ~105 s killed the domain and
  `virsh screenshot failed` looped forever. Letting virt-install do its
  own phase-2 transition requires `--wait > 0`, which blocks until the
  install completes — equally intolerable for the test runner.
- **Workaround.** Ask virt-install to print the phase-1 XML
  (`--print-xml=1`) instead of starting the domain,
  regex-replace `on_reboot=destroy` to `on_reboot=restart`, then
  `virsh define` + `virsh start` ourselves. With `on_reboot=restart`
  from the start, subiquity's post-install reboot triggers a QEMU
  `system_reset` (NVRAM preserved), UEFI boots the `ubuntu` entry that
  efibootmgr added during install (priority 0 in BootOrder, ahead of
  the still-attached CDROM), and the same QEMU process keeps serving
  QMP screen-dumps to `virsh` — the harness's OCR loop never sees the
  install boundary.

`--noautoconsole` and `--wait 0` are no-ops with `--print-xml=1` (the
latter only governs install-time blocking, the former only governs
console attach); they're omitted from the `--print-xml` call because
some virt-install versions warn about the combination.

Source:
[`host/ubuntu.kvm/guest.ubuntu.server.24/New-VM.ps1`](../host/ubuntu.kvm/guest.ubuntu.server.24/New-VM.ps1).

### Why we swap boot order 1 and 2 in the install XML?

Even with `on_reboot=restart` patched in, subiquity's post-install
reboot lands back on the live ISO and re-runs autoinstall in a loop —
visible as "Continue with autoinstall?" reappearing right after
`${vmName} login:`. Root cause: OVMF re-evaluates QEMU `bootindex`
hints on EVERY `system_reset` (not just first boot), so the `ubuntu`
`Boot####` entry that subiquity's efibootmgr writes into NVRAM is
overridden by the QEMU hint on each subsequent boot — back to CDROM,
back to autoinstall.

virt-install `--cdrom` emits the boot ordering in one of two shapes
depending on its version; both must be handled:

- **(a) Per-device, single-quoted (older virt-install):**
  `<boot order='1'/>` on the install CDROM device,
  `<boot order='2'/>` on the qcow2 device.
  Swapping `order=1` ↔ `order=2` promotes the qcow2 to priority-1.
  A sentinel-based 3-step swap keeps the second replace from rewriting
  what the first just produced.
- **(b) Domain-level, double-quoted (current virt-install on Noble):**

  ```xml
  <os firmware="efi">
    <boot dev="cdrom"/>
    <boot dev="hd"/>
  </os>
  ```

  libvirt expands this into per-device `bootindex` behind the scenes;
  swapping the two elements has the same effect as the per-device swap.

In both cases, on first boot the qcow2 has no EFI System Partition so
OVMF falls through to the CDROM and the install runs normally. After
install, OVMF still tries the qcow2 first and finds the `ubuntu` boot
entry there. The `seed.iso` has no boot hint of its own in either
emitted XML, so it sits below both entries, unaffected by the swap.

The code errors loudly if neither pattern is present, so a future
virt-install format change surfaces as a noisy failure rather than a
silent regression back into the `virsh screenshot failed` reboot loop.

Source:
[`host/ubuntu.kvm/guest.ubuntu.server.24/New-VM.ps1`](../host/ubuntu.kvm/guest.ubuntu.server.24/New-VM.ps1).

### Why the bootstrap installer must stay ASCII-only?

`install/windows.hyper-v.ps1` is invoked from a fresh Windows where
`pwsh.exe` does not yet exist, via the one-liner

```
irm https://...windows.hyper-v.ps1 | iex
```

from the only shell that ships in-box: Windows PowerShell 5.1. PS 5.1's
`Invoke-RestMethod` returns the response body as a string WITHOUT
stripping a leading UTF-8 BOM (`EF BB BF`). When that string is piped
to `iex`, the BOM character (`U+FEFF`) becomes the first token of the
parse stream and PS 5.1 fails the very first line with "Unexpected
token at the beginning of the script." Direct invocation as a file
works either way — both PS 5.1 and pwsh handle BOM-prefixed files on
disk — but the `irm | iex` path is the documented installer entry
point (see `.EXAMPLE` in the script header) and MUST work.

Consequence: every comment, string, here-doc, and identifier in the
installer file MUST stay plain 7-bit ASCII. No em-dashes, no smart
quotes, no box-drawing characters. If a future edit introduces
non-ASCII content, replace it with an ASCII equivalent (e.g. `--`
instead of an em-dash) rather than adding a BOM.

Source:
[`install/windows.hyper-v.ps1`](../install/windows.hyper-v.ps1).

### Why the arm64 autoinstall apt block writes a curtin-owned sources.list.d entry?

The macOS UTM ubuntu.server.24 guest is arm64-only. When a cache is
reachable, the autoinstall apt block injects:

- **`proxy`** — routes apt (and, unavoidably, `http_proxy` /
  `https_proxy`) via squid.
- **`primary`** — pins the arm64 mirror to `ports.ubuntu.com` so
  subiquity doesn't elect `archive.ubuntu.com` (the amd64 default)
  and 404 behind the proxy.
- **`geoip: false`** — skips the HTTPS `geoip.ubuntu.com` lookup that
  otherwise goes through squid (`http_proxy` is exported globally when
  `apt.proxy` is set — `subiquity/server/controllers/proxy.py:43-44`)
  and can stall on the squid CONNECT path, keeping subiquity's
  mirror-election retry loop (`mirror.py:200-227`) alive.
- **`sources_list`** — legacy `/etc/apt/sources.list` with
  `ports.ubuntu.com` entries.
- **`preserve_sources_list: false`** — tells curtin it owns the
  sources.
- **`sources.yuruna-ports`** — curtin writes this entry to
  `/etc/apt/sources.list.d/yuruna-ports.list`. The 24.04 arm64 Server
  squashfs ships `ubuntu.sources` with ONLY a `file:/cdrom` entry, and
  curtin's `primary` modifymirrors step only *rewrites* an existing
  URI — it cannot add one. With no network URI in `ubuntu.sources`,
  curtin's mirror config never reaches the target and any postinstall
  `apt install <pkg>` for a package not on the cdrom fails with
  `E: Unable to locate package`. Writing a separate file under
  `sources.list.d/` bypasses that no-op: apt merges `ubuntu.sources`
  (cdrom) + `yuruna-ports.list` (network).

A background early-commands watcher racing to overwrite
`ubuntu.sources` before postinstall lost that race on an observed
arm64 Server install, and the install failed. Curtin-owned sources
land synchronously and deterministically.

The retry loop is the driver of the
"subiquity/Network/_send_update CHANGE enp0s1" console spam — each
retry's netplan re-apply fires `RTM_NEWLINK` events that subiquity
consumes in `update_link → _send_update`. Pinning `primary` +
disabling `geoip` makes the mirror election succeed on the first try.

Source:
[`host/macos.utm/guest.ubuntu.server.24/New-VM.ps1`](../host/macos.utm/guest.ubuntu.server.24/New-VM.ps1).

### Why the guest seed's apt Acquire retries are 3 x 30s?

Acquire tuning is a step-budget decision, not a networking preference.
apt blocks on each index fetch, and a sequence step that waits for a
completion marker has a fixed timeout (10–30 min). `Retries 5` x
`Timeout 120` allows ~12 minutes of stalling PER INDEX, so a single
unreachable mirror consumed an entire step budget and the step failed
with the guest still wedged inside apt — no marker, no error, nothing
to read but a truncated log. Three attempts at 30s bounds one index to
~90s, which leaves the failure legible and the remaining budget
available to the rest of the script. `Timeout` is an inactivity
timeout, not a transfer deadline, so a large `.deb` that keeps
streaming is unaffected.

`Languages "none"` drops the `Translation-*` indexes: fewer objects to
fetch means fewer chances to stall, and the guests never read localized
descriptions.

These values are NOT the guest's only copy, and must not be treated as
proof the installed system has them: whether the installer applies this
block is its business, and an unapplied block is indistinguishable from
an applied one without dumping apt's config on the guest. The ubuntu
update scripts write the same keys to
`/etc/apt/apt.conf.d/99yuruna-acquire` on every run, which is what the
runtime behavior actually rests on. This block still earns its place:
it is the only one of the two that exists during the install itself,
before any guest script has run.

Source:
[`automation/Yuruna.GuestSeed.psm1`](../automation/Yuruna.GuestSeed.psm1).

### Why osinfo-db variant detection parses canonical-token-first?

Ubuntu 24.04 may not be in the host's `osinfo-db` yet (the shipped
package can predate the release). The KVM `New-VM.ps1` probes
`virt-install --osinfo list` and falls back through `ubuntu22.04` →
`linux2022` generic so a fresh host doesn't fail at VM-create time
with "Unknown OS name 'ubuntu24.04'". Same pattern as
`guest.amazon.linux.2023/New-VM.ps1`.

Each line of `virt-install --osinfo list` is `<canonical>, <aliases>`
(e.g. `ubuntu24.04, ubuntunoble`), NOT one short-id per line. The
parser extracts the canonical id (first whitespace-or-comma-separated
token, trailing comma removed) before equality-checking, otherwise the
lookup never matches even when the variant is present.

Source:
[`host/ubuntu.kvm/guest.ubuntu.server.24/New-VM.ps1`](../host/ubuntu.kvm/guest.ubuntu.server.24/New-VM.ps1).

### Why the amazonlinux KVM guest uses SeaBIOS, not UEFI?

x86_64 amazon.linux.2023 on KVM uses the libvirt default (i440fx + SeaBIOS).
Switching to UEFI/q35 to chase a `dracut-initqueue: starting timeout
scripts` stall broke fresh boots with "No bootable option or device
was found", because the AL2023 KVM cloud image's EFI System Partition
only carries `\EFI\amazon\grubx64.efi` — it does NOT ship the fallback
`\EFI\BOOT\BOOTX64.EFI` that OVMF requires when the NVRAM has no boot
entries. `New-VM.ps1` calls `virsh undefine --nvram` every cycle, so
the NVRAM is always fresh on first boot and OVMF has nothing to load.
SeaBIOS reads the hybrid GRUB MBR directly and boots cleanly.

That stall under SeaBIOS+i440fx was disk-size truncation (now fixed:
`qemu-img create` with a SIZE smaller than the backing image clips
visible partitions and dracut waits forever for a rootfs device that
never enumerates). If it resurfaces, the next suspects are missing
virtio modules in the initramfs or a stale `root=` on the kernel
cmdline — root-cause those rather than re-disabling boot entirely.

aarch64 has no BIOS option in QEMU, so UEFI is mandatory there.

Source:
[`host/ubuntu.kvm/guest.amazon.linux.2023/New-VM.ps1`](../host/ubuntu.kvm/guest.amazon.linux.2023/New-VM.ps1).

### Why the macOS UTM ubuntu-server guest uses QEMU and HVF

This guest runs on QEMU+HVF (see the `config.plist.template` comment) to
get a `-vnc` RFB server for focus-independent harness control. HVF on
Apple Silicon does NOT expose nested virtualization, so `/dev/kvm` is
unavailable inside the guest; a cycle that depends on nested virt must
run on a different host (Hyper-V on Windows ships nested virt for Linux
guests).

Source:
[`host/macos.utm/guest.ubuntu.server.24/New-VM.ps1`](../host/macos.utm/guest.ubuntu.server.24/New-VM.ps1).

### Why cache VHDX uses Resize-VHD instead of qemu-img resize?

The Hyper-V caching-proxy-service VM's VHDX is grown to 512 GB for cache
storage (384 GB `squid cache_dir` + ~128 GB OS/logs/headroom). VHDX is
dynamic, so 512 GB is the APPARENT size only — actual disk consumption
stays low until squid starts caching (or unattended-upgrades pulls a
kernel). The `cache_dir` budget was raised from 128 GB so squid can
hold the macOS install image (~18 GB) plus other multi-GB objects with
breathing room — see
`host/vmconfig/caching-proxy-service.base.user-data` and the
`maximum_object_size 65 GB` directive.

Prefer Hyper-V's native `Resize-VHD`: `qemu-img` reports
"This image does not support resize" for VHDX files it creates, even
with `subformat=dynamic`. `Resize-VHD` handles VHDX correctly.

Source:
[`host/modules/Yuruna.Image.psm1`](../host/modules/Yuruna.Image.psm1).

---

## Test harness path

### Why YURUNA env vars are snapshotted and re-asserted across inner spawns?

A child process inherits the parent's environment — `Start-Process`
too, as long as `-UseNewEnvironment` is not passed — so anything in
`$env:` at spawn time reaches the inner automatically. That implicit
inheritance breaks down quietly when a long-running outer is mutated
mid-run (a module unset / overwrite, or a `Remove-Item Env:X` slipping
through), and the operator only finds out cycles later when the inner
says "no caching-proxy service". The snapshot in
`Invoke-TestRunner.ps1` makes the contract explicit:

- Captured ONCE at outer startup (from whatever shell launched us).
- RE-ASSERTED into `$env:` right before every inner spawn, so even if
  intermediate code clobbered a value, the inner sees the value the
  operator set when launching the outer.
- Logged at the banner AND on every spawn so there is a clear record
  of what was forwarded.

The inner pwsh is spawned with `-NoProfile` so the operator's `$PROFILE`
can't re-set these vars AFTER inheritance and override the snapshot.
Without that flag, a profile line like

```
$env:YURUNA_CACHING_PROXY_SERVICE_IP = '192.168.7.223'
```

silently wins in the child even when the operator cleared the var in
the outer shell — the inner inherited the cleared state but then ran
profile and re-wrote it. That produced a cycle pointing at an external
(stale) cache while `Test-CachingProxyService` reported the local
cache correctly. (With config-first resolution, a profile-injected env
value decides a cycle only when `vmStart.cachingProxyIp` is empty or
fails its probe, but the `-NoProfile` snapshot guard still protects
every other forwarded knob.)

Add new `YURUNA_*` knobs to `$script:ForwardEnvNames` when introduced;
only `YURUNA_RUNNER_RELAUNCH` is intentionally outer-internal (set
per-spawn, not snapshotted).

Source:
[`test/Invoke-TestRunner.ps1`](../test/Invoke-TestRunner.ps1).

### Why the inner spawn uses the call operator instead of Start-Process?

The outer test runner invokes the inner `pwsh` via the call operator
`& $pwshExe @argList` rather than
`Start-Process -NoNewWindow -Wait -PassThru`. On Windows, the
`Start-Process -Wait` shape was observed to never return after the
inner emitted its final cycle-end line.

Root cause: any long-running grandchild spawned by the inner that
inherited the inner's console handles kept the outer's `WaitForExit()`
from completing — the status service is the worst offender, which is
why `Start-StatusService.ps1` redirects its stdio explicitly. The call
operator hands inner invocation to PowerShell's native command
pipeline, which waits on the child's exit code directly without the
`.NET Process.WaitForExit` subtleties; with the grandchild stdio
redirection, control returns cleanly to the outer.

Source:
[`test/Invoke-TestRunner.ps1`](../test/Invoke-TestRunner.ps1).

### Why the diagnostic shows recent .yuruna/ file mtime as cycle footprint?

The yuruna runner streams its real-time log to a `GetTempFileName`
transcript that lives OUTSIDE the project tree
(`Set-Resource.ps1:78` / `Set-Workload.ps1:92`), so the diagnostic
dump can't reach it from the project root. What it CAN show is which
files the last cycle wrote: the top-N most-recently-modified files
under any `.yuruna/` working folder, with mtime and size. On an
aborted cycle the timestamp tells the operator how recent the failure
is, and the last few files hint at which stage was reached:

- mtime stops at a `templates/01-website.yml` → helm rendered but
  never installed.
- mtime stops at a `terraform.tfstate` → tofu apply succeeded but the
  workload phase never started.

Source:
[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1).

### Why the installer's baseline reset removes legacy test VMs?

An install is a "return-to-baseline" operation. Status service +
runner processes are killed earlier (`Stop-YurunaProcess`); their VMs
are not. `Remove-TestVMFiles.ps1` enumerates Hyper-V VMs matching the
`test-` prefix and stops + removes each. `yuruna-caching-proxy-service`
does NOT match this prefix and is preserved.

Skipped when Hyper-V was just enabled in this run — `vmms` only
exists after the pending reboot, and `Hyper-V\Get-VM` would fail with
the same "permission required" error `Enable-TestAutomation.ps1`
skips for the same reason. Failure on a single VM (locked `.vhdx`,
wedged `vmms`) is non-fatal; a try/catch keeps the cleanup going for
the remaining VMs.

Source:
[`install/windows.hyper-v.ps1`](../install/windows.hyper-v.ps1).

### Why the log tee writes HTML-encoded severity spans?

`Add-YurunaLogLine` appends one already-stringified line to the
per-cycle transcript via `[IO.File]::AppendAllText`, preserving
`Out-File`'s open/write/close per-call durability without the
PowerShell pipeline + `Out-File` cmdlet overhead — the thousands of
`Write-*` calls per cycle add up. A failed append is non-fatal
(swallowed to Verbose) so logging never breaks the caller; the catch
uses the fully-qualified `Microsoft.PowerShell.Utility\Write-Verbose`
to bypass the module's own override.

Severity is stamped as a CSS class on a wrapping `<span>` so the
transcript is both eye-scannable (a stylesheet can color
errors/warnings) and machine-filterable (select `.log-error` /
`.log-warning` records) without reparsing free text. Only the message
body is HtmlEncode'd; the span markup is emitted verbatim so it
renders as an element rather than escaped angle brackets inside the
`<pre>`. An unknown/empty severity degrades to
the neutral `log-output` class rather than dropping the record — the
tag is additive and never gates whether a line is written.

Source:
[`automation/Yuruna.Log.psm1`](../automation/Yuruna.Log.psm1).

### Why port-ownership diagnostics live in one module?

`Test.PortOwner.psm1` is shared by Start-StatusService, the test
prelude, the root-artifact scan, the installer, and future health
checks, so the Windows HTTP.sys / `netsh` versus Unix `lsof` dispatch
is written once. Every caller asks the same three questions in the
same order, and the answers are not interchangeable:

**Who holds the port?** `Get-PortListenerPid` uses `netsh` on Windows —
HTTP.sys hides the real owner from `Get-NetTCPConnection` — and `lsof`
on macOS/Linux. It returns empty when the holder belongs to another
user, because both tools hide those without elevation. Empty means
"no PID resolvable", not "port free", so it cannot be the source of
truth on its own.

**Can we bind?** `Test-PortListenerFree` attempts `http://*:$Port/` and
is the OS-agnostic source of truth: a holder owned by another user
still makes it `$false` even when no PID is resolvable.

**Were we merely not allowed to ask?** `Test-PortPrivilegeBlocked`
separates "something holds the port" from "this process may not RESERVE
the wildcard URL while the port is in fact empty". Wanting the bind and
being permitted to request it are different questions; a failed bind
alone cannot tell them apart.

`Resolve-PortOrphan` is the one opinionated entry point. It reclaims an
orphan pwsh holder this user owns; otherwise it classifies the port as
`Conflict`, or as `PrivilegeRequired` when nothing holds it and the
wildcard reservation was refused. Both outcomes refuse to start — the
status service binds the same prefix and would fail identically — but
only one of them has a holder that can be stopped. It returns a
structured result and never exits or throws, so the caller
(Start-StatusService) decides how to refuse, and that refusal aborts
the cycle instead of running blind with no status server.

`Get-ProcessOwnerName` and `Get-PortHolderServiceInfo` are the
best-effort identity helpers those classifications report with.

Source:
[`test/modules/Test.PortOwner.psm1`](../test/modules/Test.PortOwner.psm1).

### Why warm resume is sound?

On an eligible transient workload failure the runner re-runs the failed
sequence from its last-good step on the SAME live VM, instead of tearing
the guest down and redoing the whole (~40-minute) install from step 0.
`Test.WarmResume.psm1` is only the pure decision core, the checkpoint
reader, and the `warm_resume` event builder; the retry loop lives in
the runner (`Test.RunnerInnerLoop`) and the re-invocation in the engine
(`Invoke-Sequence`'s `-StartStep`, `Invoke-GuestSequenceList`'s
`-ResumeFromSequence` / `-ResumeFromStep`).

Two constraints make it sound. First, resume is attempted only for
genuinely transient failure classes — the same allow-list the outer
loop's gated auto-remediation uses. A hard, deterministic failure would
redo the install and fail again: nothing to gain, a cycle of wall-clock
to lose.

Second, resume runs only in the runner path, where each workload
sequence runs as a single file (`Invoke-SequenceByName`). That makes
`last_failure.json`'s file-local `repro.resumeFromStep` map directly onto
`Invoke-Sequence`'s file-local `-StartStep`. `Invoke-TestSequence`'s chain
runner concatenates baselines, which would make the same mapping
chain-global rather than file-local; the runner does not concatenate, so
the mapping is exact. See [failure-schema.md](failure-schema.md).

The mechanism is safe-on-failure regardless: a resume that targets the
wrong VM or step fails and falls through to the ordinary teardown plus
cold re-provision.

The module is a leaf: the runner resolves `Send-CycleEventSafely` at
call time (`Get-Command`-guarded); this module only builds the event
record.

Source:
[`test/modules/Test.WarmResume.psm1`](../test/modules/Test.WarmResume.psm1).

### Pester file-scope fixtures

The Pester test files keep helper functions and path fixtures at FILE
scope, above the first `Describe`. Two Pester behaviors force that
placement: a `Describe` body runs during discovery and its variables
and functions are discarded before any `It` executes, and the run pass
stops descending top-level statements at the first `Describe`. So
anything an `It` body needs must be defined above the first `Describe`.

Only the PATHS are computed at file scope. The directories, files, and
child processes those paths name are side effects, and the file body
runs twice (discovery, then run) — so the creation itself (`New-Item`
calls, spawned processes) stays inside `BeforeAll` / `It` bodies.

Source:
[`test/modules/Test.Notify.Tests.ps1`](../test/modules/Test.Notify.Tests.ps1),
[`test/modules/Test.SingleInstance.Tests.ps1`](../test/modules/Test.SingleInstance.Tests.ps1).

### Why the guest SSH-user overrides are anchored in the global scope?

`$GuestSshUserOverrides` holds per-cycle overrides for `Get-GuestSshUser`, populated by the runner (`Invoke-TestRunnerInnerLoop` / `Invoke-TestSequence`) from the cycle plan's `effectiveUsername`. That is how a workload's `variables.username:` cascade reaches every SSH callsite routed through `Get-GuestSshUser`: `Wait-SshReady`, `Invoke-GuestSsh`, `Save-GuestDiagnostic`, the host driver `Send-Text` / `Send-Key` SSH-mode dispatchers, and the inner runner's fetchAndExecute SSH path. The alternative -- a `-Username` parameter threaded through every public signature -- would touch every callsite and the host contract for the same outcome.

The table is anchored in the GLOBAL scope because `Save-GuestDiagnostic` and several host drivers `-Force` re-import `Test.Ssh` defensively. A module-scoped `$script:GuestSshUserOverrides = @{}` would be re-initialized on every re-import, wiping the cascade value registered at plan-resolution time and falling SSH auth back to the per-guest default (e.g. `yauser1`) -- breaking exactly the workloads `variables.username:` was meant to serve. This is the same eviction-safe pattern `Test.Output` and the `Test.Registry`-based registries already use. `Set-Variable` / `Get-Variable -Scope Global` is used instead of `$global:` so PSSA's `PSAvoidGlobalVars` stays quiet for the rest of that large module.

Source: [`test/modules/Test.Ssh.psm1`](../test/modules/Test.Ssh.psm1).

### Why the test.config.yml cache key includes a content hash?

`Test.Config` is the single source of truth for reading `test.config.yml`. Centralizing the `Get-Content -Raw $cfg | ConvertFrom-Yaml -Ordered` flow keeps error handling uniform across callsites -- parse failures, `$null` on miss, and `-is [IDictionary]` validation all happen in one place, so a new rule (a schema check, say) reaches every caller automatically.

The cache key is absolute path + `LastWriteTimeUtc` + a SHA-256 of the first 64 KB of file content. The content hash defends against an editor restoring a file to its original size AND mtime -- a `git checkout` of a same-size revision, a `touch -d` to an exact prior timestamp, or a CI step that copies a backup over. mtime alone would return stale cached YAML, and downstream callers would silently see an old config for the rest of the process.

64 KB covers the entire repo's YAML files (the current largest is under 8 KB); reading more on every cache check would negate the benefit of caching for big files. Callers that need a guaranteed fresh read -- the outer loop's failure-pause config-mtime trigger, for instance -- pass `-NoCache`.

Source: [`test/modules/Test.Config.psm1`](../test/modules/Test.Config.psm1).

### Why the preflight gate child gets empty-pipeline stdin plus -NonInteractive?

No-prompt discipline, the same two measures every other child in the
harness gets, and neither is redundant.

The empty pipeline input is what redirects the child's stdin. Without
it a native command on the SOURCE side of a pipeline has its stdout
captured and its stdin INHERITED, so inside the child
`[Console]::IsInputRedirected` is `$false` and every prompt guard that
consults it concludes an operator is present — while the question it
then asks goes into the captured-output buffer, which is printed only
on a non-zero exit. A blocked child never exits, so that is a run
parked forever on a question nobody was shown. `@()` rather than `''`
so the child reads EOF immediately instead of one blank line: a blank
line is an answer, and an invented answer to a consent question is a
silent yes-or-no.

`-NonInteractive` makes an engine-level prompt an error rather than a
wait, which covers the reads that never consult a guard at all. That
error is NOT terminating: the read returns nothing and the child
carries on, so the switch bounds the damage to a wrong answer recorded
in the transcript, and the guards inside the child are still what
decide.

The native-command pipeline is kept deliberately: `$LASTEXITCODE` is
set only by a native command, and a hand-rolled two-pipe drain would
re-introduce the deadlock that a child filling one 64K buffer while the
reader blocks on the other produces. Converting this to
`[Diagnostics.Process]` means changing the exit-code read in the SAME
edit — a stale `$LASTEXITCODE` of 0 turns a FAILING gate into
`passed = $true`, which is worse than the hang.

Source:
[`test/modules/Test.ConfigPreflight.psm1`](../test/modules/Test.ConfigPreflight.psm1).

### Why the SSH readiness probe runs in-process with its own wall-clock cap?

`ConnectTimeout=5` only bounds TCP setup. If the SSH banner /
`kex_exchange_identification` stalls -- or the post-handshake session
goes half-dead, with TCP `ESTABLISHED` on both ends and no data flowing
-- `ssh` has no further timeout of its own. A foreground probe in the
runner runspace would make the outer
`while ((Get-Date) -lt $deadline)` deadline useless: it is checked only
between iterations, so one stuck `ssh` holds the loop forever and
`saveSystemDiagnostic` blows past `Save-GuestDiagnostic`'s cap.

An in-process .NET `Process.Start` + `WaitForExit(timeoutMs)` gives a
hard per-probe cap without the `Start-Job` / `Wait-Job` runspace cost
(~200-500 ms cold-start per iteration; ~18 iterations on a 90 s boot is
4-9 s of pure overhead). On timeout the child `ssh` is killed directly
via `Process.Kill($true)` -- the entire process tree -- which also
closes the OS-level `ssh` a `Start-Job` implementation leaks, since
`Stop-Job` cannot terminate the native child. The `ServerAlive` options
shorten in-flight detection of a half-dead session to ~6 s, so most
probes complete well under the cap on a healthy guest.

Source: [`test/modules/Test.Ssh.psm1`](../test/modules/Test.Ssh.psm1).

### Why the status service exposes a /log-upload/ write endpoint?

Subiquity's `error-commands` block runs **inside the installer
environment** -- not the half-built target -- when an install aborts, and
`PUT`s `/var/log/installer/*` here before the VM dies. Without this
endpoint the only failure evidence is the screen OCR; the apt stderr
and curtin trace are lost when the installer drops to a shell. It
mirrors the static `/log/` GET route, so an uploaded file appears in
the dashboard's cycle-log listing as soon as it lands.

The write surface is scoped narrowly:

| Constraint | Value |
|---|---|
| Method | `PUT` or `POST` only |
| Path | `log-upload/<rel>` with no `..` segments |
| Extension | `.log` `.txt` `.json` `.err` `.crash` — what `/var/log/installer/*` actually produces; rejects e.g. `.ps1` / `.exe` upload attempts |
| Body cap | 4 MB (a typical curtin-install.log tail is ~200 KB; the full file ~1-2 MB) |

The path is normalized and range-checked against `$logDir` so nothing
escapes the log mount.

Source: [`test/Start-StatusService.ps1`](../test/Start-StatusService.ps1).

---

## Host orchestration

### Why orphaned VM cleanup skips Hyper-V's VirtualMachinePath root?

Hyper-V's `VirtualMachinePath` root contains service-owned metadata
that `vmms` keeps open for its lifetime: `data.vmcx` at the root,
`Resource Types\<GUID>.vmcx` per registered provider, plus empty
placeholder subdirs for planned/snapshot/undo state. Walking the whole
tree flags those files as "unclaimed" on a no-VMs host and tries to
delete them — `vmms` refuses every delete with "file in use",
producing ~26 warnings per cycle on a fresh install. The canonical
VM-data subtree is `Virtual Machines\`; that stays in scope along with
all of `VirtualHardDiskPath`.

Source:
[`host/windows.hyper-v/Remove-OrphanedVMFiles.ps1`](../host/windows.hyper-v/Remove-OrphanedVMFiles.ps1).

### Why utmctl list needs a UUID-anchored parser?

UTM 4.x `utmctl list` layout is
`<uuid 36c> <status 9-col-padded><name>`. UUID col is 37 wide
(UUID + 1 padding space); Status col is 9 wide (longest UTM.sdef enum
`starting`/`stopping` is 8 chars). So between UUID and Status there
is exactly ONE space: a `-split '\s{2,}'` parser sees only two tokens
— `<uuid> <status>` and `<name>` — and the UUID regex check on
`parts[0]` (44 chars) always fails. `$registeredVMs` then stays empty
and every bundle looks orphaned (the UUID-keyed orphan dedupe path
still works by accident through `Get-UTMBundleUUID`, but the
human-readable "registered VMs" listing is blank). A UUID-anchored
regex avoids the spacing trap entirely.

Source:
[`host/macos.utm/Remove-OrphanedVMFiles.ps1`](../host/macos.utm/Remove-OrphanedVMFiles.ps1).

### Why Remove-VM on KVM omits remove-all-storage?

`libvirt` walks every `<disk>` entry in the domain XML and deletes
the file at each path. For KVM guests in this repo that includes
ATTACHED INSTALL ISOs that live in the SHARED `~/yuruna/image/<guest>/`
tree:

- **Windows 11:** `--cdrom $winIso`
  (`~/yuruna/image/windows.11/host.ubuntu.kvm.guest.windows.11.iso`)
  plus `virtio-win.iso` (same dir).
- **Ubuntu Server 24.04:** `--cdrom $baseImageFile`
  (`~/yuruna/image/ubuntu.env/...iso`).

So `--remove-all-storage` silently nukes the upstream artifact every
cycle. Symptom on the next cycle: `Get-Image` fails, and on Windows 11
the operator must re-download the ISO from microsoft.com by hand
(no `wget`-able URL). The per-VM `Remove-Item` call cleans up
everything we created under `~/yuruna/vms/<vmname>/`, so plain
`undefine --nvram` is sufficient and safe.

Source:
[`host/ubuntu.kvm/modules/Yuruna.Host.psm1`](../host/ubuntu.kvm/modules/Yuruna.Host.psm1).

### Why the libvirt bridge self-heal probes brif and activates the slave?

A bring-up can create and activate the bridge NM connection but never
activate the matching `bridge-slave`, leaving the bridge interface up
with only tap ports (`vnetN`) attached and no LAN uplink. In that
state DHCP loops forever on the bridge,
any guest on this libvirt network stays stranded with no IP, and
`Start-CachingProxyServiceVM.ps1` times out at `Get-VMIp`.

- **Detection:** the bridge's `/sys/class/net/<br>/brif` directory
  lists only `vnet*` / `tap*` ports.
- **Repair:** find NM connection(s) whose `connection.master` is this
  bridge and `nmcli connection up` them. NM deactivates the
  conflicting profile on the slave's NIC (e.g. `netplan-<nic>`) as
  part of the user-initiated activation — this is the moment SSH may
  flap.

Idempotent and best-effort: a no-op on a healthy bridge or when NM
isn't active. On failure it logs a recovery hint but does not throw —
the caller (`New-YurunaExternalNetwork`) prefers to return the network
name and let the operator see the downstream timeout in full context.

Source:
[`host/ubuntu.kvm/modules/Yuruna.Host.psm1`](../host/ubuntu.kvm/modules/Yuruna.Host.psm1).

### Why the bridge residue sweep covers three backends

`Clear-YurunaExternalBridgeResidue` removes every stranded artifact a
failed bridge bring-up can leave behind, so the next build starts
clean. A half-built bridge strands THREE kinds of state, each from a
different backend, and any one makes the next attempt fail in a new
way:

- **NM connection profiles** (`$BridgeName` / `$BridgeName-slave-*`):
  re-adding on top of them errors out, and feeding NM conflicting
  profiles can trigger its nm-settings-utils.c assertion crash.
- **The netplan file** (`99-yuruna-external.yaml`): systemd-networkd
  keeps claiming the bridge + NIC, and netplan's generated udev rule
  marks them NM_UNMANAGED — which makes `nmcli connection up <bridge>`
  fail with "Failed to find a compatible device for this connection".
- **The kernel bridge device itself**: deleting the NM profile or the
  netplan file does NOT remove an already-created device, and a
  same-named device NM does not manage also produces that same
  "no compatible device" nmcli failure.

Source:
[`host/ubuntu.kvm/modules/Yuruna.Host.psm1`](../host/ubuntu.kvm/modules/Yuruna.Host.psm1).

### Why Remove-MacHostProxy sets state-off as the LAST step?

`networksetup` has no "remove server" verb; setting `0.0.0.0:0` is
the documented neutralizer. CRITICAL: `-setwebproxy` /
`-setsecurewebproxy` flip the proxy state back ON as a side-effect,
so `-setwebproxystate off` MUST be the last step or the system ends
up `Enabled=Yes` pointing at `0.0.0.0` — and .NET `HttpClient` (which
reads `CFNetworkCopySystemProxySettings`) then fails the next
`Invoke-WebRequest` with
"IPv4 address 0.0.0.0 ... cannot be used as a target address".
The re-enable is silent, so state-off first looks correct and fails
only later.

Public `Remove-HostProxy` in `Yuruna.Host` owns `ShouldProcess`; the
private helper suppresses to avoid a double-prompt.

Source:
[`host/macos.utm/modules/Yuruna.Host.psm1`](../host/macos.utm/modules/Yuruna.Host.psm1).

### Why the group-membership probe uses getent rather than the id command?

`id -nG` reports the RUNNING shell's group set, which was sampled at
login — on a first install run, `usermod -aG libvirt,kvm` has just
updated `/etc/group` but the parent shell still carries the stale
set, so `id -nG` would falsely claim the user is "not in 'libvirt'
group yet" even though the membership took. Masking that in
`install/ubuntu.kvm.sh` with `sg libvirt -c "sg kvm -c '...'"` does
not help: nested `sg` calls `initgroups()` fresh each time and only
the inner group survives, so the warning keeps firing for the outer
group. `getent` answers the question we actually mean ("is the user a
member?") without depending on the shell's snapshot.

Source:
[`host/ubuntu.kvm/Enable-TestAutomation.ps1`](../host/ubuntu.kvm/Enable-TestAutomation.ps1).

### Why Get-CacheVmCandidateIp emits a bare pipeline?

Callers that need a guaranteed array wrap with `@()`. The bare
pipeline shape avoids three traps:

1. **No leading `,` array-wrap** — it makes the function emit ONE
   `String[]`; `@(Get-CacheVmCandidateIp ...)` then wraps that into
   `Object[1]` whose sole element is the array, breaking
   `foreach ($ip in ...)` with
   "Cannot convert value to type System.String".
2. **No `[string[]](pipeline)` as the return expression** — on empty
   input the cast emits a single `$null` instead of zero items, so
   callers get a ghost element.
3. **No outer `@(...)`** — PSScriptAnalyzer statically infers
   `System.Array` from the `@`-subexpression even with string content,
   tripping `PSUseOutputTypeCorrectly`. The bare pipeline emits
   strings directly.

Source:
[`host/windows.hyper-v/modules/Yuruna.Host.psm1`](../host/windows.hyper-v/modules/Yuruna.Host.psm1).

### Why stash-service bring-up waits for the daemon, not just the VM?

Returning as soon as the VM is registered used to end
`Start-StashServiceVM.ps1` roughly fifteen to thirty minutes before the
service existed: a first boot installs a Go toolchain and compiles the
daemon, and until that finishes there is nothing listening. Everything
downstream inherited that gap. The dashboard's Extension cell has no
link, because the address a link needs comes from the daemon's own
announce and there is no daemon yet to announce — this host withholds
its own copy of the address whenever the VM sits on a
hypervisor-private network, which is every Wi-Fi UTM host. So the
operator finished a "successful" run and found an unlinked row, with
nothing to tell them it was merely early.

Waiting here costs the build's wall-clock and buys two things: the link
is live when the run ends, and a guest that never finishes building is
reported instead of passing silently. The budget is extended only on
the guest's own answer that cloud-init is still running, and the wait's
progress line quotes what was measured rather than naming a step
nothing observed.

The wait is NOT conditional on the runtime dir: the marker is a
dashboard concern, while readiness is the question of whether the
script's whole purpose was achieved. A host that could not open its
runtime dir must still be told its daemon never started.

Source:
[`test/Start-StashServiceVM.ps1`](../test/Start-StashServiceVM.ps1).

### Why Set-HostAlias writes the hosts file via a staged sibling swap?

The rewritten hosts file is written UTF-8 WITHOUT a BOM: a leading
`EF BB BF` confuses Linux/macOS resolvers (the first entry is read as
`<BOM>127.0.0.1`). On PS7 `Set-Content -Encoding utf8NoBOM` writes no
BOM and uses platform-native line endings.

The content is staged to a sibling temp file on the same volume, then
swapped in. A crash or disk-full mid-write can never truncate the
live hosts file (the half-written bytes land in the temp), and
`[IO.File]::Replace` preserves the live file's ACLs/owner — a plain
`Move-Item` would inherit the temp's. If the swap throws, the live
file is left intact and the temp is removed. `[NullString]::Value`
passes a real null for the (declined) backup argument; a bare `$null`
would bind as an empty path and fault.

Source:
[`automation/Set-HostAlias.ps1`](../automation/Set-HostAlias.ps1).

### Why the networkStorage vault sync probes before prompting, and rewrites on drift?

`Sync-ConfigSyncVaultCredential` converges every networkStorage user's vault entry onto the credential the REFERENCE host holds, fetched over the token-gated, encrypted endpoint, prompting the operator only for what the reference cannot supply. Two rules earn their keep:

- **Ask the reference what it can do BEFORE asking the operator for anything.** The shared lab-auth-token unlocks the fetch, but a reference host with no token of its own can never serve a credential, whatever the operator types. Prompting for the token, then for every password once the operator skips it, demands by hand precisely the values this sync exists to copy. The capability probe needs no token and turns that into one sentence naming the fix.
- **An existing vault entry is not a reason to stop.** Skipping every user who already had one makes the sync a one-shot bootstrap: a NAS password rotated on the reference never reaches a host holding the old one, and the mount fails with a credential the sync was staring right at. The fetched value is compared against the stored one and written only when they differ, so a re-run converges and a no-op run writes nothing.

Requires the authentication extension; degrades to warnings when it cannot be loaded.

Source: [`test/modules/Test.ConfigServiceSync.psm1`](../test/modules/Test.ConfigServiceSync.psm1).

---

## System diagnostics

### Why Get-SystemDiagnostic wraps each section in Invoke-DiagnosticSection?

Each diagnostic section runs inside a try/catch helper so a throw in
one section doesn't abort the whole dump. Sub-tools called from a
section already log their own failures via `Invoke-Tool`'s try/catch;
the wrapper is the safety net for inline pipelines (e.g. a `-f` format
mismatch when a regex returns no match on an unfamiliar
`/proc/cpuinfo`) that would otherwise unwind to the script top, run
the `finally` block, and rethrow with no SUMMARY.

The catch records the failing section in `$script:Problems` and
emits the inner exception's `PositionMessage` (file:line:col) so the
operator can jump straight to the failing line.

Source:
[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1).

### Why the CPU section guards against /proc/cpuinfo AutomationNull?

When `/proc/cpuinfo` has no `model name` line (some ARM cores,
qemu/KVM generic CPU, container-stripped cpuinfos), the pipeline
that extracts it produces `AutomationNull`. The downstream `-replace`
then also yields `AutomationNull`, which `-f` treats as ZERO
arguments — raising "Index (zero based) must be greater than or
equal to zero and less than the size of the argument list".

The CPU section captures the line first and falls back to a literal
`(unknown -- no "model name" line in /proc/cpuinfo)`, which keeps
the formatter happy and tells the operator why the value is missing
rather than showing a blank field. `@(...)` wraps the
processor-line count because on some PS versions a zero-match
pipeline returns `$null` instead of an empty array, which would
break the downstream `.Count` comparison.

Source:
[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1).

### Why Get-SystemDiagnostic flags helm releases not in deployed/superseded states?

`helm install` is the most common cycle-aborting step in this
harness: when the chart values are malformed (e.g. an empty
`componentsRegistry.registryLocation` that produces
`/<image>:<tag>`), helm typically exits non-zero with no release
created, leaving the target namespace empty and almost no other
signal in `kubectl get pods`. Listing helm releases + flagging any
release not in a healthy steady state surfaces this failure mode in
the SUMMARY without the operator having to remember `helm list -A`.

`deployed` and `superseded` are the healthy steady states (the
latter is what a prior revision moves to after a successful
upgrade). Anything else — `failed`, `pending-*`, `uninstalling`,
`unknown` — is worth flagging.

Source:
[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1).

### Why empty namespaces are flagged as "helm install never landed"?

On a yuruna cycle the namespace is created early (often by
`helm install` or `kubectl apply`) but the workload manifests come in
a later step; if that step fails silently (helm exit 0 with a
rendered-but-rejected manifest, or a fail-fast that doesn't
propagate), the namespace is left as a tombstone.

The diagnostic excludes the K8s built-ins (`default`, `kube-public`,
`kube-node-lease` are empty by design; `kube-system` and
`kube-flannel` are populated by the cluster bootstrap). Any OTHER
namespace that exists with zero Pods AND zero Deployments is the
smoking gun for "helm install never landed".

Source:
[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1).

### Why the journalctl sample redacts Get-SystemDiagnostic's own script echo?

PowerShell's `ScriptBlock_Compile_Detail` logging emits the body of
every compiled script (Get-SystemDiagnostic.ps1 included) into the
journal, split across "Creating Scriptblock text (N of M):" entries
whose script body lands on indented continuation lines. Left alone it
dominates the journal sample with an echo of this script.

The redactor catches each such entry via the `(N of M)` marker — no
end-of-script sentinel needed — and drops the indented continuation
lines carrying the source.

Source:
[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1).

### Why the .yuruna/ grep filters trigger-word identifiers via a denylist?

PowerShell preference variables (`$ErrorActionPreference`), helm/k8s
threshold knobs (`failureThreshold`), log-level constants
(`WarningLevel`) and similar identifiers incidentally CONTAIN our
trigger words but are NOT real failures.

Mechanism: each denylist match is wiped from a copy of the line
before re-testing the base pattern. If the stripped line no longer
matches `error|fail|warning`, the original hits were ALL inside
denylisted identifiers → skip the line. Lines that contain BOTH a
denylisted identifier AND an unrelated trigger word still surface
(e.g. `$ErrorActionPreference = 'Stop'  # real error here` because
stripping `ErrorAction` leaves "real error here").

Pattern: `(?i)\b(?:term1|term2|...)\w*\b` — `(?i)` makes the deny
match case-insensitive whether or not the caller passes
`-CaseSensitive`; leading `\b` anchors to a word boundary; trailing
`\w*` eats any camelCase / PascalCase suffix, so `ErrorAction` also
covers `ErrorActionPreference`, and `failureThreshold` covers
`failureThresholdSeconds`. Deny entries are *root identifiers* — list
the shortest prefix you want suppressed.

The `linesFiltered` counter appears in the tail summary, so an
unexpectedly quiet section still shows the denylist did its job.

Source:
[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1).

### Why SUMMARY is outside Invoke-DiagnosticSection?

SUMMARY sits OUTSIDE `Invoke-DiagnosticSection` deliberately: if it
threw (which it shouldn't — it just iterates `$script:Problems`),
there is no later section to fall through to, and the safety-net
would swallow the most important section to surface.

Source:
[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1).

---

## Resource / project pipeline

### Why Set-Resource fails fast on empty tofu outputs?

`tofu output -json` returning `'{}'` means apply ran but every `output`
block evaluated to nothing. The cause is always an upstream silent
failure inside a `null_resource` provisioner — typically a
`local-exec` script that wrote no JSON to stdout because its
underlying command (a `docker run`, a `pwsh` data-source program)
failed without propagating a non-zero exit. Letting that empty block
flow downstream makes the helm step render an `InvalidImageName` pod,
masking the real cause in a long helm trace.

The throw surfaces the failing resource's template path and the tail
of `tofu.stderr.log`, so the operator lands on the provisioner script,
not on a confused kubelet event.

Source:
[`automation/Yuruna.Resource.psm1`](../automation/Yuruna.Resource.psm1).

### Why tofu init retries before failing?

`tofu init` downloads providers from `registry.opentofu.org`,
`releases.opentofu.org`, and the GitHub release CDN. All three return
transient 5xx under load, and a single blip fails the provider
download. A swallowed first-attempt exit then cascades into
`tofu output -json` returning `{}`, an empty `resources.output.yml`
block, and a helm chart rendering an `InvalidImageName` pod — the
failure surfaces ~30 minutes downstream from the cause.

The shared Yuruna.Retry policy (five attempts, 10 s initial delay,
jittered exponential backoff) covers a few minutes of upstream wobble.
Longer outages still surface, framed as "tofu init failed ... after N
attempts" with the stderr tail attached, so the operator immediately
sees whether it's a 5xx, a checksum mismatch, or something else. The
retry sits **inside** the per-resource helper so the captured
`tofu.stderr.log` records each attempt's exit code separately.

Source:
[`automation/Yuruna.Resource.psm1`](../automation/Yuruna.Resource.psm1).

### Why Set-Resource uses a saved planfile for apply?

Default `tofu apply` re-runs refresh before applying, which
re-evaluates every `data` source and re-invokes any provisioner
program lookups. A successful plan does not guarantee a successful
apply: the apply pass exercises those external programs a second time,
and pwsh cold-start jitter, transient HTTPS errors, or a briefly empty
stdout are each enough to fail that second read. `data "external"`
blocks are the most common offender — spawning pwsh, parsing stdin
JSON, and emitting JSON on stdout, on every apply.

Switching to `tofu plan -out=tfplan` followed by `tofu apply tfplan`
makes apply deterministic: the planfile pins all values, no refresh
runs, no external programs re-execute. The class of "plan succeeded
but apply failed" failures collapses to zero.

Defensive fallback: if the planfile is missing at apply time (e.g.
someone called the apply helper directly without a prior plan pass),
the helper logs a verbose note and falls back to a refreshing apply
rather than hard-failing.

Source:
[`automation/Yuruna.Resource.psm1`](../automation/Yuruna.Resource.psm1).

### Why tofu failure throws include the stderr tail?

The per-resource `tofu.stderr.log` lives inside the guest VM and gets
cleaned up after a failed cycle, so "Inspect $tofuLogFile" alone
forces the operator to SSH into a VM that may no longer exist.
Appending the last 30 lines of that log to every throw makes the
cycle log self-contained — the test-runner output already captures
the throw message, so the tofu Error frame (header, frame hint, inner
provider message) is preserved with no extra plumbing.

Thirty lines captures a typical tofu Error block (`Error: ...` header
+ 1-2 frame lines + provider message) without flooding the
test-runner log on a multi-screen warning dump. The
helper that builds the tail is null-safe: a missing log file yields
an empty string, so throws that fire before the first
`Add-Content -LiteralPath $tofuLogFile` still surface cleanly.

Source:
[`automation/Yuruna.Resource.psm1`](../automation/Yuruna.Resource.psm1).

---

### Why ubuntu guest update scripts install PowerShell first?

[`guest/ubuntu.server.24/ubuntu.server.24.update.sh`](../guest/ubuntu.server.24/ubuntu.server.24.update.sh)
and its `ubuntu.server.26` sibling install `pwsh` as early as possible
so that if a later step aborts under `set -euo pipefail`, the
host-side failure diagnostic (which shells back into the guest as
`pwsh -NoProfile -File $HOME/yuruna/automation/Get-SystemDiagnostic.ps1`)
still has `pwsh` to gather state.

The version is discovered at install time by resolving the GitHub
`/releases/latest` redirect, so this stays current without code edits
when Microsoft ships a new pwsh.

The same install-early rationale applies to the Amazon Linux 2023
guest. AL2023 ships no first-party pwsh package, so its update script
installs the same GitHub release tarball the ubuntu `code.sh` script
uses, which works on both x86_64 and aarch64.

Source:
[`guest/ubuntu.server.24/ubuntu.server.24.update.sh`](../guest/ubuntu.server.24/ubuntu.server.24.update.sh),
[`guest/ubuntu.server.26/ubuntu.server.26.update.sh`](../guest/ubuntu.server.26/ubuntu.server.26.update.sh),
[`guest/amazon.linux.2023/amazon.linux.2023.update.sh`](../guest/amazon.linux.2023/amazon.linux.2023.update.sh).

---

### Why ubuntu guest update scripts pre-extract the yuruna tarball?

Both `ubuntu.server.{24,26}.update.sh` pre-extract the yuruna
framework tarball before the long `apt-get update` / `apt-get upgrade`
block.

If the apt-get block stalls (UTM bridge throughput is the known
culprit on macOS hosts) the cycle watchdog fires, the orchestrator
captures diagnostics, and `Get-SystemDiagnostic.ps1` must already be
on disk — else `pwsh` exits 64 and writes its usage banner instead of
real guest state.

Tarball-only at this position: the git-clone fallback stays later in
the script because it needs `git`, which requires `apt-get` to work —
exactly what may be stuck.

The same rationale applies to the other supported guests:

- **Amazon Linux 2023**: identical structure with `dnf` in the stuck
  role — the early extract runs before the long dnf transaction, and
  the git-clone fallback stays late because it needs `git`, which
  needs a working `dnf`.
- **Windows 11**: the update script pre-fetches the tarball before the
  winget / Windows Update stages (the analogous stall risks), while
  the git-clone fallback lives in the late "Materialize" section
  because it needs `git`, which winget may only install in the update
  stage that follows. The host coordinates (`YURUNA_STATUS_SERVICE_IP` /
  `YURUNA_STATUS_SERVICE_PORT`) come from `C:\ProgramData\yuruna\host.env` — the
  Windows-side equivalent of the Linux `host.env` injection — written
  when the host driver supports it; when the file or the variables are
  absent the early-extract block soft-fails into a no-op.

Source:
[`guest/ubuntu.server.24/ubuntu.server.24.update.sh`](../guest/ubuntu.server.24/ubuntu.server.24.update.sh),
[`guest/ubuntu.server.26/ubuntu.server.26.update.sh`](../guest/ubuntu.server.26/ubuntu.server.26.update.sh),
[`guest/amazon.linux.2023/amazon.linux.2023.update.sh`](../guest/amazon.linux.2023/amazon.linux.2023.update.sh),
[`guest/windows.11/windows.11.update.ps1`](../guest/windows.11/windows.11.update.ps1).

---

### Why ubuntu / AL2023 guest update scripts wrap Install-Module powershell-yaml with pwsh_retry?

A bare `sudo pwsh -NoProfile -Command "Install-Module -Name powershell-yaml -Scope AllUsers -Force"` fails periodically with:

```
Install-Package: No match was found for the specified search criteria and module name 'powershell-yaml'.
                 Try Get-PSRepository to see all available registered module repositories.
Import-Module: The specified module 'powershell-yaml' was not loaded ...
ConvertFrom-Yaml: The term 'ConvertFrom-Yaml' is not recognized ...
```

Adjacent cycles on the same host with the same `pwsh` build succeed,
so it is not a version regression. PowerShellGet emits that same
one-line error for at least four distinct failure modes, none
discriminable from the rendered text:

| Failure mode | What actually happened upstream |
|---|---|
| PSGallery OData edge 5xx / empty body | `https://www.powershellgallery.com/api/v2/Search()?searchTerm='powershell-yaml'` returned 0 results that one moment |
| NuGet provider bootstrap fetch flake | First `Install-Module` on a fresh pwsh fetches the NuGet provider; if that one GET fails, the search runs without a provider and returns empty |
| DNS / TLS blip in the guest at the install window | systemd-resolved or CA chain transiently unhappy |
| Cache-VM HTTPS CONNECT stall | Squid VM saturated when multiple guests install in parallel |

Wrapping the call in
[`pwsh_retry`](network.md#defining-yuruna-retry-lib) does two things:

1. **Rides out the transient.** Five attempts with jittered
   exponential backoff (10/20/40/80 s base) absorb a couple of minutes
   of PSGallery edge flapping at no cost on the happy path.
2. **Captures the discriminating evidence.** Each attempt's
   `Resolve-DnsName www.powershellgallery.com` + HEAD on
   `api/v2/` is appended to
   `/var/log/yuruna/pwsh-yaml-install.log` along with the
   `Install-Module -Verbose 4>&1` stream, plus a one-shot pre-
   flight (`Get-PSRepository`, `Get-PackageProvider -ListAvailable`,
   PowerShellGet + PSResourceGet versions) recorded before the loop.

The matching `Import-Module powershell-yaml; ConvertFrom-Yaml 'k: v'`
smoke test lives inside the retried body so a manifest that lands
without a loadable module re-triggers instead of slipping through.

Failure-collector handoff: `Get-SystemDiagnostic.ps1`'s
[GUEST PROVISIONING (Linux) section](definition.md#defining-get-systemdiagnostic)
cats every file under `/var/log/yuruna/` and flags any log
containing `all N attempts exhausted` (the `_yuruna_retry`
exhaustion string) as a problem. The operator gets the full
per-attempt timeline without re-shelling into the guest.

Source:
[`guest/ubuntu.server.24/ubuntu.server.24.update.sh`](../guest/ubuntu.server.24/ubuntu.server.24.update.sh),
[`guest/ubuntu.server.26/ubuntu.server.26.update.sh`](../guest/ubuntu.server.26/ubuntu.server.26.update.sh),
[`guest/amazon.linux.2023/amazon.linux.2023.update.sh`](../guest/amazon.linux.2023/amazon.linux.2023.update.sh).

---

### Why fetch-and-execute tees into a well-known per-run log?

[`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh)
tees the inner script's combined stdout/stderr into
`/tmp/yuruna-last-fetch-and-execute.log` so the harness can `scp` it
back on failure
(`Copy-FailureArtifactsToStatusLog` → `Save-GuestFetchAndExecuteLog`).
The file is truncated at every fetch-and-execute call so it always
holds the LAST script's output — the most useful post-mortem artifact
for a sequence that ended on a `fetchAndExecute` step.

Without the tee — say a workload wrapper exits 0 with no useful
output — that wrapper's console output has already scrolled
off-screen behind the `test-localhost.sh` poll loop, and the OCR
screenshot captures only the polling, not the wrapper.

The header records WHICH script was fetched, so a reader of the file
alone can tell whether the last fetch was the workload wrapper or a
smaller helper (`test-localhost.sh`, etc.). The tee runs in a subshell
so the inner script still sees a "regular" stdout/stderr (some tools
behave differently under a pipe — e.g. `docker build`'s progress UI).

Source:
[`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh).

---

### Why fetch-and-execute self-heals the yuruna_retry library?

[`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh)
sources `/usr/local/lib/yuruna/yuruna-retry.sh` at startup so the
inner script (spawned via `bash -c "$script_content"`) inherits
`apt_retry` / `dnf_retry` / `curl_retry` via `export -f`.

Cloud-init drops the library into `/usr/local/lib/yuruna/` at install
time (`write_files: base64`). If that didn't happen (hand-cloned
guest, a future host platform), fetch-and-execute fetches it once from
the resolved `BASE_URL`. A missing library is still non-fatal
(`[ -r ... ] && . ...`); the inner script just runs without the
retry helpers in scope.

Source:
[`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh).

---

### Why the Yuruna result-manifest is shaped this way?

`New-YurunaResultManifest` (in
[`automation/Yuruna.Result.psm1`](../automation/Yuruna.Result.psm1)) is
the project-wide contract for what publish-step functions return.

Every key is always present so callers can branch on values without
`ContainsKey` gymnastics:

| Key            | Type            | Meaning                                                                   |
|----------------|-----------------|---------------------------------------------------------------------------|
| `success`      | `[bool]`        | `$true` iff the operation completed without error.                        |
| `skipped`      | `[bool]`        | `$true` iff the operation was a soft no-op (precondition not met).        |
| `errorMessage` | `[string]`      | Short human reason on failure, `''` on success.                           |
| `failureClass` | `[string]`      | One of `ok`, `config_error`, `cluster_unreachable`, `chart_invalid`, `tool_failed`, `unknown`. |
| `exitCode`     | `[int]`         | External-tool exit code (kubectl/helm/tofu/docker/etc) or `0` on no-tool failure. |
| `durationMs`   | `[long]`        | Wall-clock duration of the operation.                                     |
| `artifacts`    | `[hashtable[]]` | Zero or more artifact descriptors (`path`, `kind`, `sizeBytes`) for things written to disk. |

`Save-GuestDiagnostic` in
[`test/modules/Test.Diagnostic.psm1`](../test/modules/Test.Diagnostic.psm1)
returns a manifest of the same shape family
(`success`/`exitCode`/`skipped`/...). `Yuruna.Result.psm1` is the
reusable builder; new manifest-returning functions in `automation/`
should call `New-YurunaResultManifest` rather than hand-roll the
literal hashtable.

Source:
[`automation/Yuruna.Result.psm1`](../automation/Yuruna.Result.psm1).

### Why Set-Resource pre-seeds TF_PLUGIN_CACHE_DIR?

`Publish-ResourceList` points `TF_PLUGIN_CACHE_DIR` at an on-disk
provider cache shared across resources and cycles. Once `tofu init`
has fetched a provider, later inits reuse the cached plugin instead of
round-tripping to github.com — guarding against the
registry-5xx-burst class where releases.opentofu.org /
registry.opentofu.org returns the same 5xx within a tight retry
window: a per-attempt retry loop cannot survive the burst, but a
cached plugin sidesteps it.

The cache is self-populating; nothing external (squid, network
mirror) needs to be reachable. The operator can override the path via
`TF_PLUGIN_CACHE_DIR`; otherwise it lives under the project's
`.yuruna/` tree so a `yuruna clear` purges it. Upstream's
`plugin_cache_may_break_dependency_lock_file` caveat is harmless here
because every resource is its own working dir with its own
`.terraform.lock.hcl`.

Source:
[`automation/Yuruna.Resource.psm1`](../automation/Yuruna.Resource.psm1).

### Why Publish-ComponentList splits its pipeline through a state hashtable?

`Invoke-ComponentCommand` replays each phase's captured streams via
`Write-Output` so the transcript stays informative, but those strings
would array-wrap the result manifest in `Publish-ComponentList`'s
pipeline output and trip callers' hashtable-shape check
(`$result = Publish-ComponentList ...` becomes `String[]+Hashtable`).
The inner scriptblock's pipeline is therefore split at the call site:
hashtables go to `$state.manifest`, everything else routes to the
host via `Out-Default` (the caller's `Start-Transcript` still
captures it). See
`feedback_powershell_writeoutput_pipeline_pollution.md` for the trap.

State is held in a hashtable so the `ForEach-Object` child scope can
mutate it; a plain `$manifest = $_` would only write the child scope.

Source:
[`automation/Yuruna.Component.psm1`](../automation/Yuruna.Component.psm1).

### Why the chart deploy lints before installing?

A non-zero `helm lint` exit indicates the chart has a
schema/required-field violation that WILL cascade to a failed install
— e.g. an `image: /<repo>:<tag>` produced when
`componentsRegistry.registryLocation` rendered as `""` because
`resources.output.yml` had `componentsRegistry: {}`. The captured
output goes to the Information stream and the cycle aborts BEFORE
install.

The chart PATH (`.`, the pushed-to work folder) must be passed
explicitly: helm 4 made it a required argument, where helm 3
defaulted it to the current directory. A bare `helm lint` exits 1
with "requires at least 1 argument", which reads as a rejected chart
and fails the cycle before install.

Source:
[`automation/Yuruna.Workload.psm1`](../automation/Yuruna.Workload.psm1).

### Why the chart deploy rolls back pending helm releases pre-flight?

A watchdog SIGKILL of helm mid-upgrade (or a host crash) leaves the
release in a `pending-*` state. Helm's atomic-rollback guarantees
fire only on a helm-detected failure — a process kill bypasses them.
The next cycle's `helm upgrade --install` then exits with "another
operation in progress", and no auto-recovery is wired downstream. The
deploy therefore probes `helm status` first, detects a `pending-*`
state, and clears it via `helm rollback` (which preserves history) so
the upgrade proceeds cleanly.

Rollback to revision 0 fails when there is no prior good revision
(the very first upgrade was the one that was killed); the recovery
then falls through to `helm uninstall --no-hooks` so the next
`upgrade --install` can land a fresh release.

Source:
[`automation/Yuruna.Workload.psm1`](../automation/Yuruna.Workload.psm1).

### Why chart deploys use one atomic helm upgrade?

`helm upgrade --install --atomic` is idempotent in the
"release-already-exists" case (no uninstall/install race window where
the release disappears mid-cycle) AND atomic in the failure case
(automatic rollback to the prior revision on any helm-detected
failure, so an interrupted deployment never leaves a half-rendered
release in the namespace). A two-step uninstall+install pair would, on
a watchdog kill between the two calls, strand the operator with no
release, a dirty namespace, and no recovery beyond a full rerun.

A non-zero exit is still authoritative — the release did NOT land (or
it landed and was auto-rolled-back). The captured output is ALSO
scanned for helm's terminal error shapes because helm can return 0 on
certain post-render rejections (server-side admission failures that
surface only in the trailing log). Either signal aborts the test
sequence.

Source:
[`automation/Yuruna.Workload.psm1`](../automation/Yuruna.Workload.psm1).

---

## Kubernetes guest bootstrap

### Why the k8s guest configures the docker registry mirror before installing docker-ce?

`/etc/docker/daemon.json` is written **before** `docker-ce` is installed.
The package `postinst` auto-starts `dockerd`, and `dockerd` reads
`daemon.json` only at startup — inserting the file afterward would
require a service restart and races with workloads that may already be
pulling.

`registry-mirrors` routes every `docker.io` pull through the
yuruna-caching-proxy-service's zot pull-through cache. The cache's
stale-on-error semantics mask upstream rate-limit blips (e.g. AWS ECR
Public returning HTTP 400 for `library/registry:2` manifest HEADs — an
incident class that has taken out multiple test hosts at once).
`CACHE_HOST` is parsed from the guest's system-wide
`$http_proxy`, falling back to the well-known `yuruna-caching-proxy-service`
hostname.

Source:
[`guest/ubuntu.server.24/ubuntu.server.24.k8s.sh`](../guest/ubuntu.server.24/ubuntu.server.24.k8s.sh)
(and its `ubuntu.server.26` sibling).

---

### Why the k8s guest fetches the Flannel manifest from the in-tree path at the latest-release tag?

The install tracks the newest Flannel release but fetches the in-tree
`Documentation/kube-flannel.yml` at that tag instead of
`releases/latest/download/kube-flannel.yml`.

That download URL relies on the maintainers attaching a
`kube-flannel.yml` *release asset*, and a release can ship without one
(v0.28.6 did) — `releases/latest` then 302s to an assetless tag and the
download 404s, aborting the whole install under `set -euo pipefail`.
`Documentation/kube-flannel.yml` is generated from the repo tree, so it
is present at every tag and is byte-for-byte equivalent to the release
asset.

The tag is resolved from the `releases/latest` web redirect, **not** the
`api.github.com` "latest" endpoint, which 403s once many guests share
one NAT egress IP (the same constraint as the OpenTofu install below).

Source:
[`guest/ubuntu.server.24/ubuntu.server.24.k8s.sh`](../guest/ubuntu.server.24/ubuntu.server.24.k8s.sh)
(and its `ubuntu.server.26` sibling).

---

### Why the k8s guest wraps the OpenTofu install in a retry with a pinned version?

OpenTofu is installed via the deb method (primary) with a standalone
fallback, then verified. The deb method fetches the signing key from
`get.opentofu.org` and the standalone method the binary release; both
can blip, and the third-party `install-opentofu.sh` runs those inner
fetches with no retry, so a single transient blip is otherwise fatal
even on a healthy host. Each invocation is wrapped in `_yuruna_retry`
for the same backoff every other fetch in the script gets.

Both paths pass `--opentofu-version "$YURUNA_OPENTOFU_VERSION"` so
neither asks the GitHub releases API for "latest" — an unauthenticated
`api.github.com` call that 403s on rate limits once many guests share
one NAT egress IP, which would leave the standalone fallback as fragile
as the deb path it backs up.

The post-install `command -v tofu` guard aborts when both fail, because
every downstream `Set-Resource` step needs `tofu`; a missing binary
otherwise surfaces far away as an HTTP 503 at the ingress.

Source:
[`guest/ubuntu.server.24/ubuntu.server.24.k8s.sh`](../guest/ubuntu.server.24/ubuntu.server.24.k8s.sh)
(and its `ubuntu.server.26` sibling).

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.08.06

Back to [Yuruna](../README.md)
