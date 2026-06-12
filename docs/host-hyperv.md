# Windows Hyper-V host — troubleshooting

## Cleaning Up Old Files

Run `Remove-OrphanedVMFiles.ps1`. It removes per-VM artifacts (VHDX, seed ISOs, NVRAM, etc.) for any VM that no longer exists in Hyper-V. Downloaded base images (named `host.windows.hyper-v.guest.<name>.*`) are explicitly KEPT so subsequent `New-VM.ps1` runs don't re-download them; refresh a base image with the matching `Get-Image.ps1`.

## Screen capture / OCR fails when no monitor is connected to the host

**Symptom:** `Invoke-TestRunner.ps1` runs, the VM boots fine and is reachable
over SSH, but every captured screenshot is all-black and `waitForText` /
OCR steps time out. Plugging a real monitor into the host (even briefly)
makes the next screenshot capture content as expected; unplugging it makes
captures go black again.

**Cause:** Hyper-V's synthetic GPU on Windows hands the guest framebuffer
to the host's Desktop Window Manager (DWM) for rendering. DWM is gated on
the host having an active display surface — when the host has no monitor
detected, DWM enters a low-power state and **stops painting the synthetic
GPU's framebuffer**. Both code paths
[Get-HyperVScreenshot](../host/windows.hyper-v/modules/Yuruna.Host.psm1) uses are affected:

- `GetVirtualSystemThumbnailImage` (WMI, the OCR primary path) returns an
  all-black bitmap because the synthetic GPU has nothing to read out.
- `PrintWindow` against the `vmconnect` window (the click-by-OCR fallback)
  returns black because `vmconnect` itself can't render off-screen
  without DWM.

This is a Windows-side behavior, not a VM-side or harness-side bug. The
guest's own framebuffer (`getty@tty1` etc.) is fine — there's just
nothing on the host actively rendering it.

**Optional fix (opt-in virtual display).**
Set `YURUNA_VIRTUAL_DISPLAY` to a truthy value (`true`/`1`/`yes`/`on`,
case-insensitive) to have the runner attach a *virtual* display that stays
present whether or not a physical monitor is connected, so DWM keeps painting
the whole time. When the variable is unset/false this is a complete no-op: no
virtual display is attached and the host's monitor topology, resolution, and
scaling are left untouched — capture then depends on a real monitor or a
manual fallback below. When enabled it runs **even when a real monitor is
currently attached** — gating on "currently headless" loses a race: a run
often starts with a monitor present and then a **KVM switch** (or an unplugged
monitor / closed lid) drops the physical display mid-cycle. The virtual
display is the stable surface the VMs render through; the physical monitor
merely makes it *visible* and can come and go freely.

**Setting it.** To persist the opt-in across sessions (run elevated):

```powershell
[Environment]::SetEnvironmentVariable('YURUNA_VIRTUAL_DISPLAY', 'true', 'Machine')
```

That writes the registry and broadcasts `WM_SETTINGCHANGE`, but it does **not**
update the current process's environment block — nor any child it launches,
since children inherit the parent's block. So `dir env:` in that shell won't
show it, and a brand-new terminal only picks it up if launched from Explorer /
the Start menu (not as a child of the shell that set it). The runner sidesteps
this: `Test-YurunaVirtualDisplayEnabled` (the gate behind
`Install-YurunaVirtualDisplay` and the scale enforcement) checks the live
process variable first, then falls back to the persisted **User** then
**Machine** scope — so a runner started even from the same stale shell still
attaches the display. An explicit per-shell value always wins, so a one-off
`$env:YURUNA_VIRTUAL_DISPLAY = 'true'` (or `'false'` to override a persisted
opt-in for that shell only) takes effect immediately.

The attach is a **per-cycle** step, not an enable-time one: because the
physical monitor can come and go between cycles, the inner runner re-runs
`Initialize-HostDisplay` (→ `Install-YurunaVirtualDisplay`) at the start
of every cycle (idempotent — an already-active monitor short-circuits),
and `Remove-TestVMFiles.ps1` tears it down via `Remove-HostDisplay`
(→ `Remove-YurunaVirtualDisplay`, a `deviceinstaller64 enableidd 0`) when
a machine stops running tests, so a stale/duplicate monitor left by a
mid-cycle KVM switch does not linger. `Enable-TestAutomation.ps1` no
longer attaches it.

It downloads the Amyuni `usbmmidd_v2` indirect-display driver to a
machine-wide cache (`%ProgramData%\Yuruna`), verifies a pinned SHA-256
(fails closed on mismatch), stages the signed driver, and activates one
virtual display (`deviceinstaller64 enableidd 1`). Idempotent — an
already-active virtual display short-circuits the step, so it never stacks
extra monitors, and success is confirmed against the *usbmmidd* monitor
specifically (not a generic monitor count, which a still-attached physical
display would satisfy). The activation may not survive a host reboot; if
it doesn't, the next cycle re-activates the monitor automatically (the
per-cycle `Initialize-HostDisplay` step) without re-downloading or
re-staging the driver. Install/activation/teardown transcripts land in
`test/status/log/VirtualDisplay/usbmmidd.log`.

**Manual fallbacks** (used automatically when auto-provisioning can't run
— host is offline, the checksum doesn't match, or driver install is
locked down):

1. **HDMI dummy plug** (~$5–10 hardware). Plugs into a physical port,
   Windows treats it as a real display, DWM keeps rendering. Survives
   reboots; no driver install. Good for dedicated test machines.
2. **Virtual display driver** — the software equivalent of the dummy
   plug, installed by hand.
3. **Keep an RDP session connected to the host** — `mstsc` from any
   other machine, even idle and minimized. RDP creates a virtual
   display surface for the duration of the session; closing the
   session reverts to the headless symptom.

If auto-provisioning fails, the per-cycle `Initialize-HostDisplay` step
falls back to a one-line warning pointing here, and `Get-HyperVScreenshot`
warns when the WMI thumbnail comes back all-black — both point back at
this section.

## Host windows open on an invisible monitor (virtual display extends instead of duplicating)

**Symptom:** With a physical monitor attached (e.g. via a KVM switch),
windows are half off the visible screen, and opening Display Settings or
similar windows sends them somewhere you can't see. Dragging a window back
to the physical monitor works, but the phantom desktop region remains.

**Cause:** the opt-in virtual display (above) attaches in **extend**
mode by default, so the host desktop spans the physical monitor *plus* an
invisible region on the virtual one. A Windows clone (duplicate) binds
**only when every active display shares one identical mode**. usbmmidd's
native mode is 1920×1080, so when the physical monitor is at any other
resolution (2560×1440, 4K, a laptop panel) there is no common mode and
Windows keeps the desktop extended rather than duplicated.

**Automatic fix.** After attaching the virtual display, the per-cycle
`Initialize-HostDisplay` step calls
[`Set-YurunaDisplayCloneAndResolution`](../test/modules/Test.HostCondition.Windows.psm1),
which:

- **pins the virtual display to 1920×1080 first** — it powers up at a low
  1024×768 default that is too small for OCR, and the clone step below would
  not otherwise resize it while the desktop is extended;
- makes the **virtual** monitor the **primary at desktop origin (0,0)**, so
  the captured surface survives the physical monitor being unplugged — a cable
  unplug hot-removes the primary, and if that were the physical monitor the
  guest-console capture would freeze on a stale frame. Because the topology is a
  clone, the operator still sees the identical image on the physical monitor
  while it is attached;
- **resolution policy** — the physical monitor is **always normalised to
  1920×1080** so it shares the virtual display's only mode and the clone can
  bind, **downscaling** a higher-resolution monitor for the duration of the
  run (the accepted cost of an always-duplicated surface). The lone exception
  is an exotic panel that advertises **no 1920×1080 mode at all**, which then
  stays extended because no common clone mode exists — the virtual display
  stays primary even then so the capture surface is still independent of the
  physical;
- applies clone (duplicate) topology via
  `SetDisplayConfig(SDC_TOPOLOGY_CLONE)` (falling back to
  `DisplaySwitch.exe /clone`) **whenever the physical monitor supports
  1920×1080** — i.e. essentially always;
- **verifies** clone by re-reading every active display's desktop position
  (in a clone they all sit at `(0,0)`; any non-`(0,0)` means extended);
- forces the **primary's display scale to 100%** live via the CCD
  per-monitor DPI device-info call (OCR needs 100%; the registry knobs in
  `Set-WindowsHostConditionSet` are the persisted backstop that only apply
  on next sign-in);
- **pulls any window whose centre sits off the primary** back onto it, so a
  window can't strand on an extended (invisible) virtual display — this also
  covers the rare exotic-panel case that stays extended.

It is idempotent and does nothing once converged (already duplicated /
already 100% / no stray windows), so it does not flicker the screen each
cycle. Transcripts land in `test/status/log/VirtualDisplay/usbmmidd.log`.

Topology (clone vs extend) is mostly a **host-operability** concern (stranded
windows), but the virtual display's **resolution, scale, and health are not**:
the WMI-thumbnail capture comes back all-black when DWM has no live surface to
paint, and the vmconnect-window capture crops or mis-scales when the surface is
below 1920×1080 or above 100% scale — either of which makes OCR silently time
out on text that is on the guest console but not in the captured frame. That is
why the floor and 100% scale are enforced here, not just the topology. After
deploying a change to the interop in that module, **restart the runner** — the
`Yuruna.DisplayConfig` interop type is compiled once per process, so a new
method only appears in a fresh process.

## Add-VMDvdDrive fails: "service account does not have permission to open attachment"

`New-VM.ps1` fails attaching the base ISO with `0x8007053C` / `0x80070005`,
even when elevated. This is **ACL bloat**, not a permissions problem: each
VM adds a per-VM ACE to the shared base image and `Remove-VM` never removes
it, so the file's DACL eventually hits the ~64 KB limit and Hyper-V can no
longer add the next VM's ACE. The harness now prunes stale per-VM ACEs
before each attach and during cleanup. Full explanation, manual
remediation, and diagnostics: [Hyper-V base-image ACL bloat](hyperv-iso-ace-bloat.md).

## Display text scale must be 100% for OCR

OCR on VM screenshots (Tesseract, Get-HyperVWindowScreenshot) degrades when
the host display scales above 100%. `vmconnect` renders the guest
framebuffer through the DPI-scaled compositor; the upscaled bitmap
defeats Tesseract segmentation and `waitForText` silently times out on
text a human reads fine. Fresh Windows 11 (HiDPI, 4K) ships at 125% or
150% by default.

`Set-WindowsHostConditionSet` therefore resets three independent
scaling knobs (HKCU). All require sign-out to take effect; a warning
fires if any value changed.

| Knob | Registry | Reset to |
|------|----------|----------|
| Per-monitor DPI (Settings → System → Display → Scale) | `HKCU:\Control Panel\Desktop\PerMonitorSettings\<id>\DpiValue` (offset from `RecommendedDpiValue`; 0 = recommended, negative = smaller) | 100% (i.e. `-RecommendedDpiValue`) |
| System-wide DPI fallback (non-per-monitor-aware processes) | `HKCU:\Control Panel\Desktop\LogPixels` + `Win8DpiScaling` | 96 + 1 |
| Win11 text size (Settings → Accessibility → Text size) | `HKCU:\Software\Microsoft\Accessibility\TextScaleFactor` | 100 |

---

Copyright (c) 2019-2026 by Alisson Sol et al.

Last review: 2026.06.12

Back to [Yuruna](../README.md)
