# Windows Hyper-V Troubleshooting

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
[Get-HyperVScreenshot](modules/Yuruna.Host.psm1) uses are affected:

- `GetVirtualSystemThumbnailImage` (WMI, the OCR primary path) returns an
  all-black bitmap because the synthetic GPU has nothing to read out.
- `PrintWindow` against the `vmconnect` window (the click-by-OCR fallback)
  returns black because `vmconnect` itself can't render off-screen
  without DWM.

This is a Windows-side behavior, not a VM-side or harness-side bug. The
guest's own framebuffer (`getty@tty1` etc.) is fine — there's just
nothing on the host actively rendering it.

**Fixes** (any one):

1. **HDMI dummy plug** (~$5–10 hardware). Plugs into a physical port,
   Windows treats it as a real display, DWM keeps rendering. Lowest
   friction; survives reboots; no driver install. Recommended for
   dedicated test machines.
2. **Virtual display driver** — software equivalent of the dummy plug.
   [`usbmmidd_v2`](https://www.amyuni.com/forum/viewtopic.php?t=3030) is
   one option (free, signed). Once installed, Windows treats the
   indirect-display device as a connected monitor.
3. **Keep an RDP session connected to the host** — `mstsc` from any
   other machine, even idle and minimized. RDP creates a virtual
   display surface for the duration of the session; closing the
   session reverts to the headless symptom.

The harness will also surface a one-line warning at startup
(`Set-WindowsHostConditionSet`) when no display is detected, and
`Get-HyperVScreenshot` warns when the WMI thumbnail comes back
all-black — both point back at this section.

Back to [Windows Hyper-V Host Setup](README.md) · [Yuruna](../../README.md)

---

Copyright (c) 2019-2026 by Alisson Sol et al.
