<a id="42dc5bb9-0001"></a>

# Windows Hyper-V host -- troubleshooting

<a id="42dc5bb9-0002"></a>

## ARM64 hosts: `$env:PROCESSOR_ARCHITECTURE` reports the wrong answer

An ARM64 Windows host runs x64 processes under emulation, and inside such a
process `$env:PROCESSOR_ARCHITECTURE` is `AMD64` -- the emulated view, not
the machine. An operator checking the host by hand that way concludes the
machine is AMD64, and the answer differs between an x64 shell and a native
ARM64 one on the same host.

Everything that picks a guest image reads
`[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture`
instead, which reports `Arm64` for the host whether or not the process is
emulated. That is true of .NET 7 and later -- earlier runtimes, and .NET
Framework (so Windows PowerShell 5.1), report the emulated `X64` there
too, which is why the answer is only trustworthy from `pwsh`. To check by
hand:

```powershell
[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
```

An image fetched for the wrong architecture does not fail at download time.
It fails when the VM is started, as a guest that never boots.

<a id="42dc5bb9-0003"></a>

## ARM64 hosts: Amazon Linux 2023 needs qemu-img

Amazon publishes its `hyperv` platform (a zipped VHDX) for x86-64 only.
`guest.amazon.linux.2023/Get-Image.ps1` therefore pulls the ARM64 KVM
qcow2 on an ARM64 host and converts it locally, so `qemu-img` has to be on
the machine -- `winget install SoftwareFreedomConservancy.QEMU`. Without it
the script stops with a conversion error after a successful download.

`qemu-img` is not an ARM64-only dependency, though. Hyper-V boots VHDX and
the Ubuntu cloud image the four extension-service guests share ships as
qcow2, so those convert on AMD64 too. Only the Ubuntu Server and Windows 11
guests skip conversion entirely; they install from vendor ISOs.

The QEMU installer does not put `qemu-img` on PATH. Every caller resolves it
through `Resolve-QemuImgCommand`, which falls back to `%ProgramFiles%\qemu`,
so conversion works on a machine where `qemu-img --version` fails at a
prompt. If a report says `qemu-img` is missing, confirm with
`Test-Path "$env:ProgramFiles\qemu\qemu-img.exe"` before reinstalling.

<a id="42dc5bb9-0004"></a>

### The converted ARM64 image does not boot

The conversion is only a container change, and the guest inside it has no
Hyper-V drivers. Amazon's aarch64 kernel package ships no `drivers/hv/`
and no `drivers/net/hyperv/` at all -- no `hv_vmbus`, `hv_storvsc`,
`hv_netvsc`, `hid_hyperv`, or Hyper-V framebuffer. That is consistent with
Amazon publishing the `hyperv` platform for x86-64 only: the ARM64 image is
built for KVM, where the disk and NIC are virtio, and Hyper-V offers
neither. Every device a Gen2 Hyper-V guest has is synthetic and reached over
VMBus.

The failure is therefore not in the download or the conversion, both of
which succeed. GRUB runs (the firmware reads the disk through UEFI, not
through Linux), prints `Booting 'Amazon Linux ...'`, hands off, and the
kernel then never enumerates a root device:

```
dracut-initqueue: timeout, still waiting for following initqueue hooks:
/lib/dracut/hooks/initqueue/finished/devexists-...by-uuid...sh
```

It repeats until the step's whole budget is spent. The guest also never
sends a DHCP DISCOVER -- there is no NIC driver either -- so it is
unreachable by console and by SSH alike, and no host-side setting reaches
any of it: Generation 2, Secure Boot off, a `cidata`-labeled seed on a
SCSI DVD and a hand-built minimal `user-data` all reproduce it exactly.

Reading that boot has a trap of its own, and it is not specific to this
guest. The image pins `console=ttyS0,115200n8 console=tty0` on the kernel
cmdline, and on ARM64 there is no `ttyS0` -- the guest UART is the SBSA
PL011, `ttyAMA0`. A COM port attached with `Set-VMComPort` therefore stays
at zero bytes however far the guest gets, which reads as a dead guest
rather than a console pointed at a UART that does not exist. Override the
cmdline with `console=ttyAMA0,115200n8` to make the boot readable. That
same pin is what keeps the AL2023 framebuffer silent until `getty@tty1`
is enabled -- [vmconfig.md](vmconfig.md#al2023-framebuffer-console)
describes it from the x86 side, where `ttyS0` is a real device.

Console ORDER then decides where the interesting text lands. The last
`console=` on the cmdline becomes `/dev/console`, so with `console=tty0`
last the kernel's own printk still reaches the serial line while userspace
output -- dracut's `initqueue: timeout` warnings among them -- goes only to
the framebuffer, where `GetVirtualSystemThumbnailImage` is the way to read
it. Put `console=tty0` first when the message you need comes from
userspace. Streaming a boot over the synthetic COM port also slows that
boot down, so treat any timing measured through serial as suspect and
confirm it on a VM with no COM port attached. More in
`feedback_hyperv_arm64_diagnostics.md`.

For ARM64 coverage of this guest use `host.macos.utm` or `host.ubuntu.kvm`,
which present the virtio devices the image drives. On Hyper-V it is an
AMD64-only guest.

<a id="42dc5bb9-0005"></a>

## ARM64 hosts: the heartbeat channel wedges a Linux guest

**Symptom:** a Linux guest boots as far as its VMBus drivers and stops dead.
The console freezes on the three integration-service version lines and never
prints another, so `hv_storvsc` never registers, the root disk never
enumerates, and the installer is never reached:

```
hv_vmbus: Vmbus version:5.3
hv_vmbus: registering driver hv_netvsc
hv_utils: Registering HyperV Utility Driver
hv_utils: Heartbeat IC version 3.0
hv_utils: TimeSync IC version 4.0
        <- nothing further, ever
```

The harness reports it as whatever OCR step was waiting -- for Ubuntu Server
that is `waitForAndEnter: "Continue with autoinstall?"` timing out with the
console static for the whole window -- which points at the wrong thing.
Keystrokes are refused at the same time (`Msvm_Keyboard` returns 32775), for
the same reason: no guest driver has attached to the synthetic keyboard.

**Cause:** `hv_utils` answers each heartbeat request from a VMBus tasklet
(`heartbeat_onchannelcallback` -> `vmbus_sendpacket` -> `vmbus_setevent` ->
`hv_do_fast_hypercall8`). On ARM64 the channel re-arms faster than the
tasklet drains it, so CPU 0 never leaves softirq context; the kernel reports
`watchdog: BUG: soft lockup - CPU#0 stuck for Ns! [swapper/0:0]` with
`hv_do_fast_hypercall8` at the PC and RCU stalls behind it. Ubuntu 24.04 and
26.04 both do it, and so does the ISO's HWE kernel, so it is not a guest
version to wait out.

**Fix:** the Ubuntu guests call `Disable-HyperVHeartbeatForLinuxGuest` at VM
creation, which turns the Heartbeat integration service off on ARM64 and does
nothing on AMD64. Nothing in the harness depends on that service --
`Get-VMIp` resolves through KVP and ARP, and only the caching-proxy guest
reads the heartbeat, as one line of a readiness summary. A Windows guest is
unaffected either way and keeps it.

**What it does not fix.** The guest still runs far slower than the same image
on an AMD64 host, and still takes occasional soft lockups elsewhere
(`kick_all_cpus_sync` during module load, for one). Disabling the service is
the difference between a guest that never boots and one that installs, not
between a slow guest and a fast one -- which is why the autoinstall wait is
budgeted in tens of minutes rather than one.

<a id="42dc5bb9-0006"></a>

## ARM64 Hyper-V host: a Linux guest loses half its CPU to hypervisor intercepts

**Symptom:** everything works and everything is slow. The guest boots,
installs, logs in and runs its workloads, but a package step that costs
minutes elsewhere costs tens of minutes here, and step budgets sized on
another host expire on this one. Nothing in the guest or in the harness log
names a cause, because neither can see it.

**What it is.** Measured on this lab's ARM64 host with one 2-vCPU Ubuntu
guest installing packages, sampling the guest's Hyper-V virtual-processor
counters and comparing them with the root partition's counters at the same
moment:

| | root partition | Ubuntu guest |
|---|---|---|
| `% Guest Run Time` | 25.3 | 17.3 |
| `% Hypervisor Run Time` | 0.8 | **51.7** |
| `Total Intercepts/sec` | 38,810 | **3,856,173** |

The guest traps roughly a hundred times more often than the root partition on
the same machine at the same instant, and spends more of its scheduled time
inside the hypervisor than running its own code. That is the throughput
ceiling: it is not explained by the disk, network, or ordinary host load
alone.

**What it is not.** Two plausible-looking explanations do not survive
measurement here. The network is not it -- the same failing step pulls
442 MB of archives in 22 seconds (13.6 and 27.2 MB/s) and then spends half an
hour unpacking them. The host's anti-virus filter is not the main term
either: it accounts for about 0.09 of a core against the guest's 1.41 over
the same window. It is still worth excluding (see the storage filter stack
section of `Test-Config.ps1`), but it is a correction, not the cause.

**How to read it.** Sample these while a guest is under load; the instances
do not exist until the VM is running, so expand the wildcard per sample
rather than once:

```powershell
Get-Counter -Counter @(
  '\Hyper-V Hypervisor Virtual Processor(*)\% Guest Run Time'
  '\Hyper-V Hypervisor Virtual Processor(*)\% Hypervisor Run Time'
  '\Hyper-V Hypervisor Virtual Processor(*)\Total Intercepts/sec'
  '\Hyper-V Hypervisor Root Virtual Processor(*)\Total Intercepts/sec'
) -MaxSamples 1
```

The root-partition column is the control: it is what this machine's trap rate
looks like when nothing pathological is happening.

**What follows from it.** Budgets measured on an AMD64 host do not transfer
to this one, and a budget that expires here is reporting the ceiling rather
than a stuck guest -- which is why the failure classifier's `wait_timeout` on
a guest whose console is still moving means "too slow", not "wedged". The
vCPU cap (`Limit-HyperVLinuxGuestCoreCount`) is the one lever already applied:
more virtual processors raise the intercept rate without delivering more
guest compute, so the cap makes single-threaded work -- boot, install,
`dpkg` -- finish sooner rather than later.

<a id="42dc5bb9-0007"></a>

### Budgeting a step on this host

Two ceilings bound a step and they are not interchangeable. A sequence step's
own `timeoutSeconds` fails that step and names it. `testCycle.stepTimeoutSeconds`
is the outer watchdog: `runner.stepHeartbeat` is touched at the top of every
step, and the outer runner kills the whole inner process when one step's
heartbeat goes older than that. **Keep every step budget below the watchdog**,
or a slow step costs an unattributed runner kill instead of a precise failure.

Measured on this host for `ubuntu.server.26.code.sh` -- a JDK, the .NET SDK,
and Code with its GTK and X11 closure: 24 packages for the JDK and 149 for
Code. The durations below were measured with Code's full RECOMMENDED closure
installed and are an upper bound on the current script, which asks for Code
with `--no-install-recommends`:

| condition | duration |
|---|---|
| host otherwise quiet | 1373 s (JDK 456, .NET 20, Code 897) |
| a cycle running with the host busy | still short of done at 1810 s; JDK alone 854 s |

Host contention moves this by nearly 2x. A full clean run of the whole chain
measured this step at 2828 s and passed, so the step is budgeted at 3000 s and
`testCycle.stepTimeoutSeconds` ships at 3600 s to stay above it. The earlier
2700 s default would have killed that successful run a hundred seconds short
of the end -- as a watchdog kill of the whole inner runner, which names
nothing, rather than a failure naming the step.

<a id="42dc5bb9-0008"></a>

## ARM64 Hyper-V host: the first keystroke after a fresh login is dropped

**Symptom:** a typed command arrives missing its first character. The console
shows the shell answering `Command 'cho' not found` to an `echo`, and the
step waiting on that command's output spends its whole budget.

**Where it bites.** Only the first send to a console that has just come up --
a session established seconds earlier by a login. A console that has already
been typed at takes the next command whole. That makes it invisible in most
runs and fatal in the one step that types first, and a lost character does
not fail loudly: it silently turns one command into a different one, which
for a line that begins with a variable assignment or an absolute path can
mean running something other than what was asked for.

**Working around it.** Give the first command a sacrificial leading
character. The Linux sequences type ` echo ...` with a leading space: dropped,
the command still starts at `echo`; delivered, the shell ignores leading
whitespace. Because that step is the first thing typed after a login, it also
absorbs the loss for every step below it. This is a sequence-level
workaround, not a transport fix -- the per-character send path in
`Send-TextHyperV` does not yet prime the console itself.

Related PS/2 delivery traps on this host are in
`docs/host-io.md#hyper-v-ps2-scancode-behavior`: a multi-character payload in
one `TypeScancodes` call arrives as nothing, and a character sent after a
modifier-release burst is swallowed. All three return success.

<a id="42dc5bb9-0009"></a>

## Cleaning up old files

Run `Remove-OrphanedVMFiles.ps1`. It removes per-VM artifacts (VHDX, seed ISOs, NVRAM, etc.) for any VM that no longer exists in Hyper-V. Downloaded base images (named `host.windows.hyper-v.guest.<name>.*`) are KEPT so later `Get-Image.ps1` runs don't re-download them; refresh a base image with the matching `Get-Image.ps1`.

<a id="42dc5bb9-000a"></a>

## Screen capture / OCR fails when no monitor is connected to the host

**Symptom:** `Start-TestRunner.ps1` runs, the VM boots fine and is reachable
over SSH, but every captured screenshot is all-black and `waitForText` /
OCR steps time out. Plugging a real monitor into the host (even briefly)
makes the next screenshot capture content; unplugging it makes captures go
black again.

**Cause:** Hyper-V's synthetic GPU on Windows hands the guest framebuffer
to the host's Desktop Window Manager (DWM) for rendering. DWM is gated on
the host having an active display surface -- with no monitor detected DWM
enters a low-power state and **stops painting the synthetic GPU's
framebuffer**. Both code paths
[Get-HyperVScreenshot](../host/windows.hyper-v/modules/Yuruna.Host.psm1) uses are affected:

- `GetVirtualSystemThumbnailImage` (WMI, the OCR primary path) returns an
  all-black bitmap because the synthetic GPU has nothing to read out.
- `PrintWindow` against the `vmconnect` window (the click-by-OCR fallback)
  returns black because `vmconnect` can't render off-screen without DWM.

This is Windows-side behavior, not a VM-side or harness-side bug. The
guest's own framebuffer (`getty@tty1` etc.) is fine -- nothing on the host
is rendering it.

**Optional fix (opt-in virtual display).**
Set `YURUNA_VIRTUAL_DISPLAY` to a truthy value (`true`/`1`/`yes`/`on`,
case-insensitive) to have the runner attach a *virtual* display that stays
present whether or not a physical monitor is connected, so DWM keeps
painting. Unset or false is a no-op: the host's monitor topology, resolution, and
scaling are untouched -- capture then depends on a real monitor or a
manual fallback below. When enabled it runs
**even when a real monitor is attached**, because gating on "currently
headless" loses a race: a run often starts with a monitor present and then a
**KVM switch** (or an unplugged monitor / closed lid) drops the physical
display mid-cycle. The virtual display is the stable surface the VMs render
through; the physical monitor merely makes it *visible* and can come and go
freely.

**Setting it.** To persist the opt-in across sessions (run elevated):

```powershell
[Environment]::SetEnvironmentVariable('YURUNA_VIRTUAL_DISPLAY', 'true', 'Machine')
```

That writes the registry and broadcasts `WM_SETTINGCHANGE`, but does **not**
update the current process's environment block -- nor any child it launches,
since children inherit the parent's block. So `dir env:` in that shell won't
show it, and a new terminal only picks it up if launched from Explorer / the
Start menu (not as a child of the shell that set it). The runner sidesteps
this: `Test-YurunaVirtualDisplayEnabled` (the gate behind
`Install-YurunaVirtualDisplay` and the scale enforcement) checks the live
process variable first, then the persisted **User** then **Machine** scope --
so a runner started from the same stale shell still attaches the display. An
explicit per-shell value wins, so a one-off
`$env:YURUNA_VIRTUAL_DISPLAY = 'true'` (or `'false'` to override a persisted
opt-in for that shell only) takes effect immediately.

The attach is a **per-cycle** step, not an enable-time one, because the
physical monitor can come and go between cycles. The inner runner re-runs
`Initialize-HostDisplay` (-> `Install-YurunaVirtualDisplay`) at the start
of every cycle (idempotent),
and `Remove-TestVMFiles.ps1` tears it down via `Remove-HostDisplay`
(-> `Remove-YurunaVirtualDisplay`, a `deviceinstaller64 enableidd 0`) when
a machine stops running tests, so a stale/duplicate monitor left by a
mid-cycle KVM switch does not linger. `Enable-TestAutomation.ps1` does not
attach it.

It downloads the Amyuni `usbmmidd_v2` indirect-display driver to a
machine-wide cache (`%ProgramData%\Yuruna`), verifies a pinned SHA-256
(fails closed on mismatch), stages the signed driver, and activates one
virtual display (`deviceinstaller64 enableidd 1`). Idempotent -- an
already-active virtual display short-circuits the step, so it never stacks
extra monitors, and success is confirmed against the *usbmmidd* monitor
(not a generic monitor count, which a still-attached physical display
would satisfy). The activation may not survive a host reboot; the
next cycle's `Initialize-HostDisplay` re-activates the monitor without
re-downloading or re-staging the driver.
Install/activation/teardown transcripts land in
`test/status/log/VirtualDisplay/usbmmidd.log`.

**Manual fallbacks** (for hosts where auto-provisioning can't run -- host
is offline, the checksum doesn't match, or driver install is locked
down):

1. **HDMI dummy plug** (~$5-10). Plugs into a physical port; Windows
   treats it as a real display and DWM keeps rendering. Survives
   reboots, no driver install. Good for dedicated test machines.
2. **Virtual display driver** -- the software equivalent of the dummy
   plug, installed by hand.
3. **Keep an RDP session connected to the host** -- `mstsc` from any
   other machine, even idle and minimized. RDP creates a virtual
   display surface for the session; closing it reverts to the
   headless symptom.

If auto-provisioning fails, the per-cycle `Initialize-HostDisplay` step
falls back to a one-line warning, and `Get-HyperVScreenshot` warns when the
WMI thumbnail comes back all-black -- both point back at this section.

<a id="42dc5bb9-000b"></a>

## Host windows open on an invisible monitor (virtual display extends instead of duplicating)

**Symptom:** With a physical monitor attached (e.g. via a KVM switch),
windows are half off the visible screen, and opening Display Settings or
similar windows sends them somewhere you can't see. Dragging a window back
to the physical monitor works, but the phantom desktop region remains.

**Cause:** the opt-in virtual display (above) attaches in **extend**
mode by default, so the host desktop spans the physical monitor *plus* an
invisible region on the virtual one. A Windows clone (duplicate) binds
**only when every active display shares one identical mode**. usbmmidd's
native mode is 1920x1080, so when the physical monitor is at any other
resolution (2560x1440, 4K, a laptop panel) there is no common mode and
Windows keeps the desktop extended.

**Automatic fix.** After attaching the virtual display, the per-cycle
`Initialize-HostDisplay` step calls
[`Set-YurunaDisplayCloneAndResolution`](../test/modules/Test.HostCondition.Windows.psm1),
which:

- **pins the virtual display to 1920x1080 first** -- it powers up at a
  1024x768 default too small for OCR, and the clone step below would not
  otherwise resize it while the desktop is extended;
- makes the **virtual** monitor the **primary at desktop origin (0,0)**, so
  the captured surface survives the physical monitor being unplugged -- a cable
  unplug hot-removes the primary, and if that were the physical monitor the
  guest-console capture would freeze on a stale frame. Because the topology is a
  clone, the operator still sees the same image on the physical monitor
  while it is attached;
- **resolution policy** -- the physical monitor is **always normalized to
  1920x1080** so it shares the virtual display's only mode and the clone can
  bind, **downscaling** a higher-resolution monitor for the run (the accepted
  cost of an always-duplicated surface). The exception is an exotic panel that
  advertises **no 1920x1080 mode at all**, which stays extended because no
  common clone mode exists -- the virtual display stays primary even then, so
  the capture surface remains independent of the physical;
- applies clone (duplicate) topology via
  `SetDisplayConfig(SDC_TOPOLOGY_CLONE)` (falling back to
  `DisplaySwitch.exe /clone`) **whenever the physical monitor supports
  1920x1080** -- i.e. essentially always;
- **verifies** clone by re-reading every active display's desktop position
  (in a clone they all sit at `(0,0)`; any non-`(0,0)` means extended);
- forces the **primary's display scale to 100%** live via the CCD
  per-monitor DPI device-info call (OCR needs 100%; the registry knobs in
  `Set-WindowsHostConditionSet` are the persisted backstop, applied only
  on next sign-in);
- **pulls any window whose center sits off the primary** back onto it, so a
  window can't strand on an extended (invisible) virtual display -- this also
  covers the exotic-panel case that stays extended.

Idempotent: it does nothing once converged (already duplicated / already
100% / no stray windows), so the screen does not flicker each cycle.
Transcripts land in `test/status/log/VirtualDisplay/usbmmidd.log`.

Topology (clone vs extend) is mostly a **host-operability** concern (stranded
windows), but the virtual display's **resolution, scale, and health are not**:
the WMI-thumbnail capture comes back all-black when DWM has no live surface to
paint, and the vmconnect-window capture crops or mis-scales when the surface is
below 1920x1080 or above 100% scale -- either of which makes OCR silently time
out on text that is on the guest console but not in the captured frame. Hence
the resolution floor and 100% scale are enforced here, not just the topology.
After changing the interop in that module, **restart the runner**: the
`Yuruna.DisplayConfig` interop type is compiled once per process, so a new
method only appears in a fresh process.

<a id="42dc5bb9-000c"></a>

## Add-VMDvdDrive fails: "service account does not have permission to open attachment"

`New-VM.ps1` fails attaching the base ISO with `0x8007053C` / `0x80070005`,
even when elevated. This is **ACL bloat**, not a permissions problem: each
VM adds a per-VM ACE to the shared base image and `Remove-VM` never removes
it, so the file's DACL eventually hits the ~64 KB limit and Hyper-V can no
longer add the next VM's ACE. The harness prunes stale per-VM ACEs
before each attach and during cleanup. Full explanation, manual
remediation, and diagnostics: [Hyper-V base-image ACL bloat](vmconfig.md#hyper-v-iso-ace-bloat).

<a id="42dc5bb9-000d"></a>

## Display text scale must be 100% for OCR

OCR on VM screenshots (Tesseract, `Get-HyperVWindowScreenshot`) degrades when
the host display scales above 100%. `vmconnect` renders the guest
framebuffer through the DPI-scaled compositor; the upscaled bitmap
defeats Tesseract segmentation and `waitForText` silently times out on
text a human reads fine. Fresh Windows 11 (HiDPI, 4K) ships at 125% or
150%.

`Set-WindowsHostConditionSet` therefore resets three independent
scaling knobs (HKCU). All require sign-out to take effect; a warning
fires if any value changed.

| Knob | Registry | Reset to |
|------|----------|----------|
| Per-monitor DPI (Settings -> System -> Display -> Scale) | `HKCU:\Control Panel\Desktop\PerMonitorSettings\<id>\DpiValue` (offset from `RecommendedDpiValue`; 0 = recommended, negative = smaller) | 100% (i.e. `-RecommendedDpiValue`) |
| System-wide DPI fallback (non-per-monitor-aware processes) | `HKCU:\Control Panel\Desktop\LogPixels` + `Win8DpiScaling` | 96 + 1 |
| Win11 text size (Settings -> Accessibility -> Text size) | `HKCU:\Software\Microsoft\Accessibility\TextScaleFactor` | 100 |

<a id="42dc5bb9-000e"></a>

## ICMP echo (ping) and the host firewall

For `ping <host>` to work two conditions must hold: (a) an enabled Allow
rule for inbound ICMPv4 Echo Request in every profile whose interface you
want ping on -- Windows ships built-in rules ("File and Printer Sharing
(Echo Request - ICMPv4-In)") in all three profiles (Domain, Private,
Public) but DISABLED -- and (b) no higher-precedence block rule matches. A
custom `-InterfaceAlias`-scoped rule (e.g. for `vEthernet (Default
Switch)`) does not make ping work on its own: disabled built-ins coexist
with it untriggered, and Windows Firewall does not merge them. The
reliable fix (applied by `Test.HostCondition.Windows.psm1`) is to enable
the built-in echo-request rules across all profiles. This opens ping on
the LAN NIC too (expected -- operators also ping the host from peers for
diagnostics); no TCP is exposed. A custom scoped rule is still created
in case built-ins are missing (stripped server SKUs, GPO).

<a id="42dc5bb9-000f"></a>

## Host clock skew reaches the guests

Hyper-V seeds a guest's virtual RTC from the host clock at power-on. A host
whose clock is not disciplined starts every VM equally wrong; a few seconds
into boot the guest's own NTP client reaches a real time server and
**steps** the clock to true time, landing in the middle of whatever the
guest is starting.

The symptom is nowhere near the cause. On a Kubernetes guest the step
leaves the control-plane static pods and part of the workload `Running`
but never `Ready` -- with no probe-failure events, because kubelet recorded
their status at a timestamp now in the future (`kubectl` prints their age
as `<invalid>`). Services lose every endpoint and each NodePort refuses,
while `curl http://<podIP>:8080/health` from the node answers `200`. A
test that waits on a NodePort times out.

Not Hyper-V-specific -- all three hosts report and repair the clock the
same way, described in [test-harness.md](test-harness.md#the-host-clock).
On Windows: `Assert-WindowsHostConditionSet` measures against a public NTP
server (`Get-HostClockSkew`, direct UDP -- the Windows Time service is
exactly what is broken on a drifting host) and warns once per cycle past
120s of skew. The cycle runs on. Repair needs an Administrator shell no
unattended loop has, so it lives where someone can authorize it:
`Test-Config.ps1` reports the skew and offers the fix.

`Sync-WindowsHostClock` -- reached from `Set-WindowsHostConditionSet`, so
`Enable-TestAutomation.ps1` applies it -- fixes the underlying state: W32Time
set to Automatic, started, and resynchronized. W32Time ships trigger-started,
so on a lab host that never joins a domain it can sit stopped for weeks --
long enough to drift by hours. To repair by hand (elevated PowerShell):

```powershell
Set-Service W32Time -StartupType Automatic
Start-Service W32Time
w32tm /resync /force
w32tm /stripchart /computer:time.windows.com /samples:1 /dataonly   # verify
```

<a id="42dc5bb9-0010"></a>

## Host metrics and the commit limit

A Hyper-V host can refuse a VM allocation with `0x800705AA` while the host's
commit charge briefly exceeds its available commit budget. Physical free memory
alone cannot explain that refusal. The exporter and local sampler preserve the
commit charge and limit alongside CPU, storage, and VM evidence.

Windows hosts publish `http://<host>:9182/metrics` with the collectors `cpu`,
`hyperv`, `logical_disk`, `memory`, and `os`. The commit pair is
`windows_memory_commit_limit` and `windows_memory_committed_bytes`. Installation
and convergence request these collectors without making an unavailable exporter
a cycle failure. The service is automatic and its TCP 9182 firewall rule is
scoped to `vmStart.cachingProxyIp`, or `LocalSubnet` when no scrape address is
configured. Convergence preserves unrelated service arguments and restores the
prior command line if the changed service fails its readiness probe.

Readiness and capability are separate. A healthy payload can contain Hyper-V
host metrics while no VM is running. Guest runtime and dispatch-wait capability
are then `not-applicable`; with a running VM, missing series are `absent`, not
zero. The sampler records the actual build-info sample, exporter service command
line, VM census, and capabilities. Missing VM enumeration remains unknown.

Metric names depend on the installed exporter version. v0.31.8 publishes guest
and hypervisor runtime as
`windows_hyperv_hypervisor_virtual_processor_time_total{state="guest"|"hypervisor"}`;
newer documentation calls this `..._mode_time_total`. These are cumulative
seconds, so a per-instance `rate()` gives processor-time share. Keep VM/VP labels,
and exclude `_Total` before combining instances. The stock collector does not
publish intercept counts or costs. Its raw `CPU Wait Time Per Dispatch` series
omits the PDH base and must not be interpreted as average dispatch latency;
the local sampler retains the cooked PDH value and counter type instead.
See the [versioned collector source](https://github.com/prometheus-community/windows_exporter/blob/v0.31.8/internal/collector/hyperv/hyperv_hypervisor_virtual_processor.go)
and [PDH conversion](https://github.com/prometheus-community/windows_exporter/blob/v0.31.8/internal/pdh/collector.go).

The outer runner starts a dedicated host sampler outside the inner runner's
process tree. Every 15 seconds it collects per-instance runtime, intercepts and
cost, dispatch wait, context switches, frequency/performance, DPC/interrupt time,
disk latency/queues, and memory commit/paging. It discovers actual localized PDH
names through the host inventory and Perflib IDs. An inventory capability means
a path exists; each sampled row separately reports valid or unavailable data.
Version-specific counters that are absent remain explicitly marked as unavailable.

Records carry host UTC and monotonic QPC anchors, actual AC/DC state, and VM CPU
and memory configuration, including processor reserve/maximum/weight, nested
virtualization exposure, and dynamic-memory minimum/maximum/buffer. Unsupported
properties or failed configuration queries have explicit unavailable states;
recorded settings do not establish that the current scheduler enforces them. Recording metadata includes Windows build plus UBR,
firmware, scheduler event, and exporter identity. The sampler flushes an append-only
ring under `runtime/host-sampling/`: four segments of about 4 MiB each, with at
most four recordings retained. A supervisor ends collection after 45 seconds
without a new record, or three sampling intervals when that is longer. Failed
probes do not block guest execution. Failure diagnostics, explicit diagnostics,
and cycle completion copy the bounded ring into the cycle's evidence before
archiving; a killed inner process leaves the original runtime ring intact.

Set `YURUNA_HOST_SAMPLING_DISABLED=1` to opt out, or
`YURUNA_HOST_SAMPLE_INTERVAL_SECONDS` to choose 5 through 300 seconds. Compare a
sampled cycle with an unsampled cycle before adopting a tighter interval on a
slow host: collection adds work. These defaults are instrumentation limits, not
a measured claim that the overhead is negligible.

For an operator capture during a slow phase, run from the repository root:

```powershell
pwsh automation/Collect-HostPerformance.ps1 -Phase prerequisite-packages
```

The default records host evidence for 60 seconds at two-second intervals and
prints the ZIP path. It changes no host settings or VMs. Add
`-GuestAddress <address> -GuestUser <account>` to include the short Linux snapshot
using existing SSH key authentication and known-host trust. That optional command
runs halfway through the host recording after a valid sample exists, has a
20-second budget and records host UTC/QPC before and after it; guest boot ID
and uptime are in its output. The harness also collects guest snapshots at its
diagnostic steps. Host QPC and guest uptime are distinct clock domains; correlate
through these anchors rather than comparing their raw values.

`-Trace` additionally requests the installed WPR CPU profile in bounded memory
mode, saves the discovered profiles/status, and stops only a recording it
successfully started. An existing recording or unrecognized localized status is
preserved. Profile or ARM64 stack support is a runtime capability; this option
does not promise guest stacks or a complete Hyper-V intercept trace. If start or
stop cannot be confirmed, the bundle records that uncertainty for the operator.

To install or repair the exporter by hand (elevated):

```powershell
winget install --id Prometheus.WindowsExporter --exact --source winget --silent
pwsh .\host\windows.hyper-v\Enable-TestAutomation.ps1
```

`Disable-TestAutomation.ps1` removes the firewall rule and leaves the package
running. Uninstall it with `winget uninstall --id Prometheus.WindowsExporter`.
The monitoring filter and its live-update command are documented in
[vmconfig](vmconfig.md#429f3d06-0046).

<a id="42dc5bb9-0011"></a>

## A Hyper-V virtual switch that looks fine but is not bridging

A Hyper-V vSwitch object outlives its uplink binding across a host reboot,
so the switch still being defined is no evidence that it bridges anything.
Address and route dumps cannot show the difference either: a host whose
management address has moved off the switch onto the bare physical NIC
reads as entirely healthy in both. What does separate a working bridge from
a dead one is the bound physical NIC's link state, whether the
management-OS vNIC exists when the switch says it should, and whether that
vNIC holds a usable address -- so the diagnostic reports those three facts
next to the addresses they explain, and a degraded switch counts toward the
problem tally.

Every step in that check fails open: an unevaluable probe reports
`unknown` and raises nothing. The diagnostic also runs inside guests, which
have no Hyper-V cmdlets at all, and an unelevated host run has the cmdlets
but no access to them -- so a missing answer there is the normal case, not
a finding.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.09.18

Back to [Yuruna](../README.md)
