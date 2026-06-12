# Yuruna memory

This file collects load-bearing rationale comments that used to live
inline in the codebase. Long historical explanations — "this code is
shaped this way because of incident X on date Y" — drift out of date
when scattered across files; gathering them in one place makes them
easier to update and easier to cross-reference.

The source files themselves stay short — each formerly large comment
block now collapses to a single line of the form:

```
# --- See https://yuruna.link/memory#<topic-slug>
```

The fragment resolves to a `### Why <topic>?` heading in this file.
Slugs follow the standard GitHub Markdown rule: lowercase the heading
text, strip everything that isn't `[a-z0-9_ -]`, then replace spaces
with hyphens. So `### Why we patch virt-install's phase-1 XML?` becomes
`#why-we-patch-virt-installs-phase-1-xml`.

This file is the sibling of [Yuruna definitions](definition.md) (for
terminology entries) and of [vmconfig topic reference](vmconfig.md)
(for `user-data` topic rationale). The same `# --- See` convention is
used in all three.

Adding a new entry:

1. Pick the source comment block.
2. Add a `### Why <topic>?` heading here with the migrated content.
3. Replace the source comment with a single
   `# --- See https://yuruna.link/memory#<slug>` line (or `// --- See …`
   for Go, etc.).
4. The yuruna.link `memory` key already redirects to this file on
   GitHub — no `yuruna.link.json` edit needed for individual topics.

---

## Build / install path

### Why we patch virt-install's phase-1 XML on KVM

The ubuntu.server.24 KVM guest uses `virt-install --cdrom --print-xml=1`,
patches the emitted XML, then `virsh define` + `virsh start` instead of
letting virt-install orchestrate the install. Each piece of the dance
addresses a specific virt-install behavior:

- **`--cdrom $baseImageFile` is the install method.** virt-install
  rejects the domain build without one of
  `--location` / `--cdrom` / `--pxe` / `--import` /
  `--boot hd|cdrom`; an earlier `--boot cdrom,hd` was not accepted as a
  substitute. The cidata `seed.iso` is added as a SECOND cdrom via
  `--disk` so subiquity can find it at `/dev/sr1` and consume the
  autoinstall config; `--cdrom` owns the install media slot and only
  takes one path.
- **`--wait 0` is critical.** With `--cdrom`, virt-install's default
  behavior is to block until the install completes (~5–10 min). The
  test runner expects `New-VM.ps1` to return promptly so the GUI
  sequence can pick up at "Continue with autoinstall?". `--wait 0`
  returns immediately after defining + starting the domain.
- **UEFI on x86_64** matches the macOS UTM and Hyper-V variants, both
  of which are UEFI-only by their hypervisor's choice. `ubuntu-installer`
  uses `efibootmgr` to add an `ubuntu` UEFI boot entry that takes
  priority over the CDROM in the firmware boot order, so the
  post-install reboot lands on the installed disk's GRUB. Without UEFI
  on legacy BIOS the CDROM would still be priority-1 and the live ISO
  would re-trigger autoinstall in a loop. `ovmf` is pulled by
  `install/ubuntu.kvm.sh` on x86_64; aarch64 already required UEFI
  (no BIOS on virt machine type).
- **The on_reboot dance.** virt-install's `--cdrom` install path is
  two-phase. Phase 1 generates an install XML with
  `<on_reboot>destroy</on_reboot>` baked in — that's how virt-install
  detects "install reboot just happened": libvirt destroys the domain
  on reboot, virt-install sees it gone, then generates phase 2 XML
  (without install media, `on_reboot=restart`) and starts the domain
  again. The `--events on_reboot=restart` flag does NOT override
  phase 1's hardcoded destroy; verified empirically — subiquity's
  post-install reboot at ~105 s killed the domain and
  `virsh screenshot failed` looped forever. Letting virt-install
  do its own phase-2 transition is not an option either: it requires
  `--wait > 0` (blocks until install completes), which the test runner
  can't tolerate.
- **Workaround.** Ask virt-install to print the phase-1 XML
  (`--print-xml=1`) instead of actually starting the domain,
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
virt-install warns about them when combined with `--print-xml` in some
versions.

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
depending on its version, and we have to handle both:

- **(a) Per-device, single-quoted (older virt-install):**
  `<boot order='1'/>` on the install CDROM device,
  `<boot order='2'/>` on the qcow2 device.
  Swapping `order=1` ↔ `order=2` promotes the qcow2 to priority-1.
  We use a sentinel-based 3-step swap so the second replace doesn't
  rewrite what the first replace just produced.
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
emitted XML, so it sits below both entries and isn't affected by the
swap.

The code errors loudly if neither pattern is present so a future
virt-install format change surfaces as a noisy failure rather than a
silent regression back into the same `virsh screenshot failed` reboot
loop.

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
works fine either way — both PS 5.1 and pwsh handle BOM-prefixed files
on disk — but the `irm | iex` path is the documented installer entry
point (see `.EXAMPLE` in the script header) and it MUST work.

Consequence: every comment, string, here-doc, and identifier in the
installer file MUST stay plain 7-bit ASCII. No em-dashes, no smart
quotes, no box-drawing characters. If a future edit introduces
non-ASCII content, replace it with an ASCII equivalent (e.g. `--`
instead of an em-dash) rather than adding a BOM — a BOM would land as
the first parse token under `irm | iex` and break the script.

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

An earlier implementation used a background early-commands watcher
that raced to overwrite `ubuntu.sources` before postinstall ran; that
race lost on one observed arm64 Server install and the install failed.
Curtin-owned sources land synchronously and deterministically.

The retry loop is the actual driver of the
"subiquity/Network/_send_update CHANGE enp0s1" console spam — each
retry's netplan re-apply fires `RTM_NEWLINK` events that subiquity
consumes in `update_link → _send_update`. Pinning `primary` +
disabling `geoip` makes the mirror election succeed on the first try.

Source:
[`host/macos.utm/guest.ubuntu.server.24/New-VM.ps1`](../host/macos.utm/guest.ubuntu.server.24/New-VM.ps1).

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
Commit `766e0a7` previously switched to UEFI/q35 chasing a
`dracut-initqueue: starting timeout scripts` stall the original author
observed; that change broke fresh boots with "No bootable option or
device was found", because the AL2023 KVM cloud image's EFI System
Partition only carries `\EFI\amazon\grubx64.efi` — it does NOT ship
the fallback `\EFI\BOOT\BOOTX64.EFI` that OVMF requires when the NVRAM
has no boot entries. `New-VM.ps1` calls `virsh undefine --nvram` every
cycle, so the NVRAM is always fresh on first boot, and OVMF has
nothing to load. SeaBIOS reads the hybrid GRUB MBR directly and boots
cleanly.

The `dracut-initqueue` stall the original revision saw with
SeaBIOS+i440fx was disk-size truncation (now fixed: `qemu-img create`
with a SIZE smaller than the backing image clips visible partitions
and dracut waits forever for a rootfs device that never enumerates).
If the stall ever resurfaces, the next suspects are missing virtio
modules in the initramfs or a stale `root=` on the kernel cmdline —
root-cause those rather than re-disabling boot entirely.

aarch64 has no BIOS option in QEMU, so UEFI is mandatory there.

Source:
[`host/ubuntu.kvm/guest.amazon.linux.2023/New-VM.ps1`](../host/ubuntu.kvm/guest.amazon.linux.2023/New-VM.ps1).

### Why the macOS UTM ubuntu-server guest switched from AVF to QEMU and HVF?

This guest used to ride Apple Virtualization (AVF) with nested
virtualization enabled so Docker Desktop could expose `/dev/kvm`
inside the guest. That required macOS 15+, M3+, and UTM v4.6+. The
backend has since moved to QEMU+HVF (see the `config.plist.template`
comment) to get a `-vnc` RFB server for focus-independent harness
control — HVF on Apple Silicon does NOT expose nested virtualization,
so the `/dev/kvm`-inside-guest pathway is no longer available here.
If a cycle depends on nested virt, that needs to move to a different
host (Hyper-V on Windows ships nested virt for Linux guests today).

Source:
[`host/macos.utm/guest.ubuntu.server.24/New-VM.ps1`](../host/macos.utm/guest.ubuntu.server.24/New-VM.ps1).

### Why cache VHDX uses Resize-VHD instead of qemu-img resize?

The Hyper-V caching-proxy image is resized to 512 GB for cache storage
(384 GB `squid cache_dir` + ~128 GB OS/logs/headroom). VHDX is
dynamic, so 512 GB is the APPARENT size only — actual disk consumption
stays low until squid starts caching (or unattended-upgrades pulls a
kernel). The `cache_dir` budget was bumped up from 128 GB so squid
can hold the macOS install image (~18 GB) plus other multi-GB objects
with breathing room — see `host/vmconfig/caching-proxy.base.user-data` and the
`maximum_object_size 65 GB` directive.

Prefer Hyper-V's native `Resize-VHD`: `qemu-img` reports
"This image does not support resize" for VHDX files it creates, even
with `subformat=dynamic`. `Resize-VHD` handles VHDX correctly.

Source:
[`host/windows.hyper-v/guest.caching-proxy/Get-Image.ps1`](../host/windows.hyper-v/guest.caching-proxy/Get-Image.ps1).

---

## Test harness path

### Why YURUNA env vars are snapshotted and re-asserted across inner spawns?

`Start-Process` (without `-UseNewEnvironment`) already inherits the
parent's environment, so anything in `$env:` at spawn time reaches the
inner automatically. That implicit inheritance breaks down quietly when
a long-running outer is mutated mid-run (a module unset / overwrite, or
a `Remove-Item Env:X` slipping through), and the operator only finds
out cycles later when the inner says "no caching proxy". The snapshot
in `Invoke-TestRunner.ps1` makes the contract explicit:

- Captured ONCE at outer startup (from whatever shell launched us).
- RE-ASSERTED into `$env:` right before every inner `Start-Process`,
  so even if intermediate code clobbered a value, the inner sees the
  value the operator set when launching the outer.
- Logged at the banner AND on every spawn so there is a clear record
  of what was forwarded.

The inner pwsh is spawned with `-NoProfile` so the operator's `$PROFILE`
can't re-set these vars AFTER inheritance and override the snapshot.
Without that flag, a profile line like

```
$env:YURUNA_CACHING_PROXY_IP = '192.168.7.223'
```

silently wins in the child even when the operator cleared the var in
the outer shell — the inner inherited the cleared state but then ran
profile and re-wrote it. That was the exact failure mode behind a
cycle pointing at an external (stale) cache while `Test-CachingProxy`
reported the local cache correctly.

Add new `YURUNA_*` knobs to `$script:ForwardEnvNames` when introduced;
only `YURUNA_RUNNER_RELAUNCH` is intentionally outer-internal (set
per-spawn, not snapshotted).

Source:
[`test/Invoke-TestRunner.ps1`](../test/Invoke-TestRunner.ps1).

### Why the inner spawn uses the call operator instead of Start-Process?

The outer test runner invokes the inner `pwsh` via the call operator
`& $pwshExe @argList` rather than the prior
`Start-Process -NoNewWindow -Wait -PassThru` pattern. On Windows, the
`Start-Process -Wait` shape was observed to never return after the
inner emitted its final cycle-end line.

Root cause: any long-running grandchild spawned by the inner that
inherited the inner's console handles (status server is the worst
offender; `Start-StatusService.ps1` was patched in the same change to
redirect its stdio explicitly) kept the outer's `WaitForExit()` from
completing. The call operator hands inner invocation to PowerShell's
native command pipeline, which waits on the child's exit code directly
without the `.NET Process.WaitForExit` subtleties; combined with the
grandchild stdio fix, it cleanly hands control back to the outer.

Source:
[`test/Invoke-TestRunner.ps1`](../test/Invoke-TestRunner.ps1).

### Why the diagnostic shows recent .yuruna/ file mtime as cycle footprint?

The yuruna runner streams its real-time log to a `GetTempFileName`
transcript that lives OUTSIDE the project tree
(`Set-Resource.ps1:85` / `Set-Workload.ps1:92`), so the diagnostic
dump can't reach it from the project root. What it CAN show is which
files the last cycle wrote: the top-N most-recently-modified files
under any `.yuruna/` working folder, with mtime and size. If the
cycle aborted, the timestamp tells the operator how recent the failure
is, and the last few files give a hint about which stage was reached:

- mtime stops at a `templates/01-website.yml` → helm rendered but
  never installed.
- mtime stops at a `terraform.tfstate` → tofu apply succeeded but the
  workload phase never started.

Source:
[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1).

### Why the installer's baseline reset removes legacy test VMs?

An install is a "return-to-baseline" operation. Status server +
runner processes are killed earlier (`Stop-YurunaProcess`); their VMs
are not. `Remove-TestVMFiles.ps1` enumerates Hyper-V VMs matching the
`test-` prefix and stops + removes each. The `yuruna-caching-proxy`
VM does NOT match this prefix and is preserved.

Skipped when Hyper-V was just enabled in this run — `vmms` only
exists after the pending reboot, and `Hyper-V\Get-VM` would fail with
the same "permission required" error `Enable-TestAutomation.ps1`
skips for the same reason. Failure on a single VM (locked `.vhdx`,
wedged `vmms`) is non-fatal; the script's own try/catch keeps the
cleanup going for the remaining VMs.

Source:
[`install/windows.hyper-v.ps1`](../install/windows.hyper-v.ps1).

---

## Host orchestration

### Why orphaned VM cleanup skips Hyper-V's VirtualMachinePath root?

Hyper-V's `VirtualMachinePath` root contains service-owned metadata
that `vmms` keeps open for its lifetime: `data.vmcx` at the root,
`Resource Types\<GUID>.vmcx` per registered provider, plus empty
placeholder subdirs for planned/snapshot/undo state. An earlier
version walked the whole tree, flagged those files as "unclaimed" on
a no-VMs host, and tried to delete them — `vmms` refused every delete
with "file in use", producing ~26 warnings per cycle on a fresh
install. The canonical VM-data subtree is `Virtual Machines\`; that
stays in scope along with all of `VirtualHardDiskPath`.

Source:
[`host/windows.hyper-v/Remove-OrphanedVMFiles.ps1`](../host/windows.hyper-v/Remove-OrphanedVMFiles.ps1).

### Why utmctl list needs a UUID-anchored parser?

UTM 4.x `utmctl list` layout is
`<uuid 36c> <status 9-col-padded><name>`. UUID col is 37 wide
(UUID + 1 padding space); Status col is 9 wide (longest UTM.sdef enum
`starting`/`stopping` is 8 chars). So between UUID and Status there
is exactly ONE space — the old `-split '\s{2,}'` parser only saw two
tokens: `<uuid> <status>` and `<name>`, and the UUID regex check on
`parts[0]` (44 chars) always failed. Result: `$registeredVMs` stayed
empty and every bundle looked orphaned (the UUID-keyed orphan dedupe
path worked by accident through `Get-UTMBundleUUID`, but the
human-readable "registered VMs" listing was always blank). A
UUID-anchored regex avoids the spacing trap entirely.

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
the operator has to manually re-download the ISO from microsoft.com
(no `wget`-able URL). The per-VM `Remove-Item` call cleans up
everything we created under `~/yuruna/vms/<vmname>/`, so plain
`undefine --nvram` is sufficient and safe.

Source:
[`host/ubuntu.kvm/modules/Yuruna.Host.psm1`](../host/ubuntu.kvm/modules/Yuruna.Host.psm1).

### Why the libvirt bridge self-heal probes brif and activates the slave?

A previous bring-up may have created the bridge NM connection and
activated it, but never activated the matching `bridge-slave` —
leaving the bridge interface up with only tap ports (`vnetN`) attached
and no LAN uplink. In that state DHCP loops forever on the bridge,
any guest on this libvirt network stays stranded with no IP, and
`Start-CachingProxy.ps1` times out at `Get-VMIp`.

- **Detection:** the bridge's `/sys/class/net/<br>/brif` directory
  lists only `vnet*` / `tap*` ports.
- **Repair:** find NM connection(s) whose `connection.master` is this
  bridge and `nmcli connection up` them. NM deactivates the
  conflicting profile on the slave's NIC (e.g. `netplan-<nic>`) as
  part of the user-initiated activation — this is the moment SSH may
  flap.

Idempotent and best-effort: no-op on a healthy bridge or when NM
isn't active. On failure logs a clear recovery hint but does not
throw, since the caller (`New-YurunaExternalNetwork`) prefers to
return the network name and let the operator see the downstream
timeout with full context.

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
Earlier ordering put state-off first and that re-enable was silent.

Public `Remove-HostProxy` in `Yuruna.Host` owns `ShouldProcess`; the
private helper suppresses to avoid a double-prompt.

Source:
[`host/macos.utm/modules/Yuruna.Host.psm1`](../host/macos.utm/modules/Yuruna.Host.psm1).

### Why the group-membership probe uses getent rather than the id command?

`id -nG` reports the RUNNING shell's group set, which was sampled at
login — on a first install run, `usermod -aG libvirt,kvm` has just
updated `/etc/group` but the parent shell still carries the stale
set, so `id -nG` would falsely claim the user is "not in 'libvirt'
group yet" even though the membership took. The wrapper in
`install/ubuntu.kvm.sh` tried to mask this with
`sg libvirt -c "sg kvm -c '...'"`, but nested `sg` calls
`initgroups()` fresh each time and only the inner group survives —
so the warning kept firing for the outer group. `getent` answers the
question we actually mean to ask ("is the user a member?") without
depending on the shell's snapshot.

Source:
[`host/ubuntu.kvm/Enable-TestAutomation.ps1`](../host/ubuntu.kvm/Enable-TestAutomation.ps1).

### Why Get-CacheVmCandidateIp emits a bare pipeline?

Callers that need a guaranteed array wrap with `@()`. The bare
pipeline shape avoids three traps:

1. **No leading `,` array-wrap** — made the function emit ONE
   `String[]`; `@(Get-CacheVmCandidateIp ...)` then wrapped into
   `Object[1]` whose sole element was the array, breaking
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

---

## System diagnostics

### Why Get-SystemDiagnostic wraps each section in Invoke-DiagnosticSection?

Each diagnostic section runs inside a try/catch helper so a thrown
exception in one section doesn't abort the whole dump. Sub-tools
called from a section already log their own failures via
`Invoke-Tool`'s try/catch; the wrapper is the safety net for inline
pipelines (e.g. a `-f` format mismatch when a regex returns no match
on an unfamiliar `/proc/cpuinfo`) that would otherwise unwind to the
script top, run the `finally` block, and rethrow with no SUMMARY.

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
rather than just showing a blank field. `@(...)` wraps the
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
release not in a healthy steady state surfaces this exact failure
mode in the SUMMARY without requiring the operator to remember to
run `helm list -A` themselves.

`deployed` and `superseded` are the healthy steady states (the
latter is what a prior revision moves to after a successful
upgrade). Anything else — `failed`, `pending-*`, `uninstalling`,
`unknown` — is worth flagging.

Source:
[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1).

### Why empty namespaces are flagged as "helm install never landed"?

On a yuruna cycle, the namespace is created early (often by
`helm install` or `kubectl apply`) but the workload manifests come
in a later step; if that step fails silently (helm exit 0 with a
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
whose script body lands on indented continuation lines. Left alone
it dominates the journal sample with an echo of this very script.

The redactor catches each such entry via the `(N of M)` marker — no
end-of-script sentinel needed — and drops the indented continuation
lines that carry the source.

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
match case-insensitive whether the caller passes `-CaseSensitive` or
not; `\b` at the start anchors to a word boundary; `\w*` at the end
greedily eats any camelCase / PascalCase suffix, so a deny entry of
`ErrorAction` also covers `ErrorActionPreference` and
`failureThreshold` covers `failureThresholdSeconds`. Deny entries
are *root identifiers* — list the shortest prefix you want to
suppress.

The `linesFiltered` counter is surfaced in the tail summary so an
unexpectedly-quiet section still reveals that the denylist did its
job.

Source:
[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1).

### Why SUMMARY is outside Invoke-DiagnosticSection?

SUMMARY is intentionally OUTSIDE `Invoke-DiagnosticSection`: if it
threw (which it shouldn't — it just iterates `$script:Problems`),
there'd be no later section to fall through to anyway, and wrapping
SUMMARY in the safety-net would swallow what is the most important
section to surface.

Source:
[`automation/Get-SystemDiagnostic.ps1`](../automation/Get-SystemDiagnostic.ps1).

---

## Resource / project pipeline

### Why Set-Resource fails fast on empty tofu outputs?

`tofu output -json` returning `'{}'` means apply ran but every `output`
block evaluated to nothing. Empirically the cause is always an upstream
silent failure inside a `null_resource` provisioner — typically a
`local-exec` script that wrote no JSON to stdout when its underlying
command (a `docker run`, a `pwsh` data-source program) failed without
propagating a non-zero exit. Letting that empty block flow downstream
causes the helm step to render an `InvalidImageName` pod, masking the
real cause in a long helm trace.

The throw surfaces the failing resource's template path and the tail
of `tofu.stderr.log`, so the operator lands on the provisioner script,
not on a confused kubelet event.

Source:
[`automation/Yuruna.Resource.psm1`](../automation/Yuruna.Resource.psm1).

### Why tofu init retries before failing?

`tofu init` downloads providers from `registry.opentofu.org`,
`releases.opentofu.org`, and the GitHub release CDN. All three return
transient 5xx under load; a single blip on any of them is enough to
fail provider download. A swallowed first-attempt exit then cascades
into `tofu output -json` returning `{}`, an empty `resources.output.yml`
block, and a helm chart rendering an `InvalidImageName` pod — the
failure surfaces ~30 minutes downstream from the cause.

Three attempts with a 5 s + 10 s backoff cover ~15 s of upstream
wobble. Longer outages still surface, but framed as
"tofu init failed after 3 attempts" with the stderr tail attached, so
the operator immediately sees whether it's a 5xx, a checksum mismatch,
or something else entirely. The retry sits **inside** the per-resource
helper so the captured `tofu.stderr.log` records each attempt's exit
code separately.

Source:
[`automation/Yuruna.Resource.psm1`](../automation/Yuruna.Resource.psm1).

### Why Set-Resource uses a saved planfile for apply?

Default `tofu apply` re-runs refresh before applying, which
re-evaluates every `data` source and re-invokes any provisioner
program lookups. A successful plan does not guarantee a successful
apply because the apply pass exercises those external programs a
second time — pwsh cold-start jitter, transient HTTPS errors, or a
script's stdout being briefly empty are all enough to fail the second
read even though the plan cleared. `data "external"` blocks were the
most common offender: spawning pwsh, parsing stdin JSON, and emitting
JSON on stdout, on every apply.

Switching to `tofu plan -out=tfplan` followed by `tofu apply tfplan`
makes apply deterministic: the planfile pins all values, no refresh
runs, no external programs re-execute. The class of "plan succeeded
but apply failed" failures collapses to zero.

Defensive fallback: if the planfile is missing at apply time (e.g.
someone called the apply helper directly without a prior plan pass),
the helper logs a verbose note and falls back to the previous
refreshing-apply behavior rather than hard-failing.

Source:
[`automation/Yuruna.Resource.psm1`](../automation/Yuruna.Resource.psm1).

### Why tofu failure throws include the stderr tail?

The per-resource `tofu.stderr.log` lives inside the guest VM and gets
cleaned up after a failed cycle, so "Inspect $tofuLogFile" alone
forces the operator to SSH into a VM that may no longer exist.
Appending the last 30 lines of that log to every throw makes the
cycle log self-contained — the test-runner output already captures
the throw message, so the actual tofu Error frame (header, frame
hint, inner provider message) is preserved without any extra
plumbing.

Thirty lines is sized to capture a typical tofu Error block
(`Error: ...` header + 1-2 frame lines + provider message) without
flooding the test-runner log on a multi-screen warning dump. The
helper that builds the tail is null-safe: a missing log file yields
an empty string, so throws that fire before the first
`Add-Content -LiteralPath $tofuLogFile` still surface cleanly.

Source:
[`automation/Yuruna.Resource.psm1`](../automation/Yuruna.Resource.psm1).

---

### Why ubuntu guest update scripts install PowerShell first?

[`guest/ubuntu.server.24/ubuntu.server.24.update.sh`](../guest/ubuntu.server.24/ubuntu.server.24.update.sh)
and its 26 sibling install `pwsh` as early as possible so that even
if a later step in the script aborts under `set -euo pipefail`, the
host-side failure diagnostic (which shells back into the guest as
`pwsh -NoProfile -File $HOME/yuruna/automation/Get-SystemDiagnostic.ps1`)
still has `pwsh` available to gather state.

The version is discovered at install time by resolving the GitHub
`/releases/latest` redirect, so this stays current without code edits
when Microsoft ships a new pwsh.

Source:
[`guest/ubuntu.server.24/ubuntu.server.24.update.sh`](../guest/ubuntu.server.24/ubuntu.server.24.update.sh),
[`guest/ubuntu.server.26/ubuntu.server.26.update.sh`](../guest/ubuntu.server.26/ubuntu.server.26.update.sh).

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

Tarball-only at this position: the git-clone fallback at the original
position later in the script stays put because it needs `git`, which
requires `apt-get` to work, which is exactly what may be stuck.

Source:
[`guest/ubuntu.server.24/ubuntu.server.24.update.sh`](../guest/ubuntu.server.24/ubuntu.server.24.update.sh),
[`guest/ubuntu.server.26/ubuntu.server.26.update.sh`](../guest/ubuntu.server.26/ubuntu.server.26.update.sh).

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
so the failure is not a version regression. The same one-line error
is what PowerShellGet emits for at least four distinct failure
modes, none of which can be discriminated from the rendered text:

| Failure mode | What actually happened upstream |
|---|---|
| PSGallery OData edge 5xx / empty body | `https://www.powershellgallery.com/api/v2/Search()?searchTerm='powershell-yaml'` returned 0 results that one moment |
| NuGet provider bootstrap fetch flake | First `Install-Module` on a fresh pwsh fetches the NuGet provider; if that one GET fails, the search runs without a provider and returns empty |
| DNS / TLS blip in the guest at the install window | systemd-resolved or CA chain transiently unhappy |
| Cache-VM HTTPS CONNECT stall | Squid VM saturated when multiple guests install in parallel |

Wrapping the call in
[`pwsh_retry`](network.md#defining-yuruna-retry-lib) does two things:

1. **Rides out the transient.** Five attempts with exponential
   backoff (10/20/40/80/160 s) absorbs ~5 min of PSGallery edge
   flapping at no cost on the happy path.
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
exhaustion string) as a problem. The operator sees the full
per-attempt timeline post-mortem without re-shelling into the
guest.

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
holds the LAST script's output — the most useful artifact for
post-mortem of a sequence that ended on a `fetchAndExecute` step.

Without the tee, when a workload wrapper exits 0 but produces no
useful output, the wrapper's console output is already scrolled
off-screen by the `test-localhost.sh` poll loop and the OCR
screenshot only captures the polling, not the wrapper itself.

The header records WHICH script was fetched so a reader of the file
alone can tell whether the last fetch was the workload wrapper or a
smaller helper (`test-localhost.sh`, etc.). The tee runs inside a
subshell so the inner script still sees a "regular" stdout/stderr
(some tools behave differently under a pipe — e.g. `docker build`'s
progress UI).

Source:
[`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh).

---

### Why fetch-and-execute self-heals the yuruna_retry library?

[`automation/fetch-and-execute.sh`](../automation/fetch-and-execute.sh)
sources `/usr/local/lib/yuruna/yuruna-retry.sh` at startup so the
inner script (spawned via `bash -c "$script_content"`) inherits
`apt_retry` / `dnf_retry` / `curl_retry` via `export -f`.

Cloud-init drops the library into `/usr/local/lib/yuruna/` at install
time (`write_files: base64`). If for any reason that didn't happen
(hand-cloned guest, a future host platform), fetch-and-execute fetches
it once from the resolved `BASE_URL` so the guest can still benefit
from the retry wrappers — but a missing library is non-fatal
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
formal, reusable builder; new manifest-returning functions in
`automation/` should depend on `New-YurunaResultManifest` rather than
hand-rolling the literal hashtable.

Source:
[`automation/Yuruna.Result.psm1`](../automation/Yuruna.Result.psm1).

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.12

Back to [Yuruna](../README.md)
