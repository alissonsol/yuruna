<#PSScriptInfo
.VERSION 2026.06.26
.GUID 42e5b4c3-d2a1-4f9a-6789-0b1c2d3e4f51
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna test host windows
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# Windows sibling of Test.HostCondition.psm1: applies AND asserts the
# per-host preconditions for unattended VM testing on host.windows.hyper-v
# (Hyper-V service, display timeout, inactivity lock, firewall rules for
# ICMPv4 + the status-service TCP port, and -- when YURUNA_VIRTUAL_DISPLAY
# is set -- display/text scale = 100% so HiDPI doesn't defeat OCR on VM
# screenshots). Loaded by the
# Test.HostCondition.psm1 facade; callers continue to import the facade
# and resolve these names through its Export-ModuleMember. See
# Test.HostCondition.psm1 for the per-platform split rationale.

function Test-YurunaVirtualDisplayEnabled {
    <#
    .SYNOPSIS
    True when the opt-in virtual display is requested via YURUNA_VIRTUAL_DISPLAY
    (truthy = true/1/yes/on, case-insensitive); $false otherwise.
    .DESCRIPTION
    Resolves the flag with the precedence the OS itself uses when it builds a
    process environment block: the live process variable wins, and only when it
    is unset/empty do we consult the persisted User then Machine registry
    scopes. The registry fallback exists because
    [Environment]::SetEnvironmentVariable with a User/Machine target writes the
    registry and broadcasts WM_SETTINGCHANGE but does NOT update the current
    process -- nor any child it spawns, since children inherit the parent's
    block. Without the fallback a runner launched from the same shell that just
    persisted the Machine var would never see it (and 'dir env:' would not show
    it either), so the virtual display would silently stay detached. An explicit
    process-level value still wins (truthy OR falsey), so a one-off
    $env:YURUNA_VIRTUAL_DISPLAY = 'false' overrides a persisted opt-in for that
    shell. Only the process variable is consulted off Windows -- the User and
    Machine targets are Windows registry scopes. See docs/host-hyperv.md.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $truthy = @('true', '1', 'yes', 'on')

    $value = "$($env:YURUNA_VIRTUAL_DISPLAY)".Trim()
    if (-not $value -and $IsWindows) {
        foreach ($scope in @('User', 'Machine')) {
            $persisted = "$([Environment]::GetEnvironmentVariable('YURUNA_VIRTUAL_DISPLAY', $scope))".Trim()
            if ($persisted) { $value = $persisted; break }
        }
    }

    return $value.ToLowerInvariant() -in $truthy
}

function Install-YurunaVirtualDisplay {
    <#
    .SYNOPSIS
    Ensure a virtual display is attached to this Hyper-V host so DWM keeps
    painting the synthetic GPU regardless of whether a physical monitor is
    connected (otherwise Get-HyperVScreenshot returns all-black images and OCR
    silently times out). Opt-in: gated on YURUNA_VIRTUAL_DISPLAY (see below).
    .DESCRIPTION
    Downloads the Amyuni usbmmidd_v2 indirect-display driver to a pinned,
    checksum-verified, machine-wide cache under ProgramData, stages the
    signed driver when its devnode is absent, and converges on exactly ONE
    virtual display (resetting via enableidd 0 then 1 whenever the count or
    health is not already exactly-one-healthy, so stale/duplicate monitors
    left by a mid-cycle KVM switch can't accumulate). It then mirrors that
    display onto the physical monitor (clone topology, not extend), makes the
    VIRTUAL display the primary so the captured surface survives the physical
    monitor being removed (the clone keeps the operator's physical monitor
    showing the same image while attached), and forces the clone source to
    >=1920x1080 so screen-capture/OCR keeps working when the physical monitor
    leaves -- see Set-YurunaDisplayCloneAndResolution.
    Opt-in via the YURUNA_VIRTUAL_DISPLAY environment variable: this entire
    routine is a no-op unless that variable is set to a truthy value
    (true/1/yes/on, case-insensitive). When it is unset/false NO virtual
    display is attached and the host's monitor topology, resolution, and
    scaling are left completely untouched. When enabled it is otherwise
    unconditional -- the virtual display is the stable surface the VMs render
    through and stays attached whether or not a physical monitor comes and
    goes (a KVM switch flipping inputs mid-cycle, an unplugged monitor, a
    closed lid), so it runs even when a real monitor is currently present.
    Idempotent: when exactly one healthy virtual display is already attached
    it is left in place (clone/resolution are re-asserted but the display
    itself does not flicker).
    Returns a status string: 'AlreadyActive', 'Activated', 'Failed',
    'Disabled' (YURUNA_VIRTUAL_DISPLAY not set), 'Skipped' (ShouldProcess
    declined / -WhatIf), or 'Unsupported' (non-Windows).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()

    if (-not $IsWindows) { return 'Unsupported' }

    # Opt-in gate: the virtual display (usbmmidd attach + clone / resolution /
    # scale enforcement) runs only when YURUNA_VIRTUAL_DISPLAY is truthy.
    # Unset/false makes this a complete no-op -- no virtual display is
    # attached and the host's topology, resolution, and scaling are left
    # untouched. Test-YurunaVirtualDisplayEnabled also honors a value persisted
    # to the User/Machine scope so a runner launched from a shell that set it
    # there (and thus has a stale process block) still attaches the display.
    # See docs/host-hyperv.md.
    if (-not (Test-YurunaVirtualDisplayEnabled)) {
        return 'Disabled'
    }

    # usbmmidd ships both a 32-bit (deviceinstaller) and 64-bit
    # (deviceinstaller64) installer. ARM64 Windows runs the x64 binary under
    # emulation, so deviceinstaller64 is correct on everything except a true
    # 32-bit x86 SKU.
    $installerExe = if ($env:PROCESSOR_ARCHITECTURE -eq 'x86') { 'deviceinstaller.exe' } else { 'deviceinstaller64.exe' }

    # Pinned source + SHA-256. The checksum gate fails closed: a mismatch
    # (vendor re-rolled the zip, truncated download, MITM) refuses to install
    # rather than running an unverified binary.
    $url            = 'https://www.amyuni.com/downloads/usbmmidd_v2.zip'
    $expectedSha256 = '629B51E9944762BAE73948171C65D09A79595CF4C771A82EBC003FBBA5B24F51'

    # Machine-wide cache: this is a host-level driver and the install needs
    # Administrator, so ProgramData is the natural home -- it survives across
    # users and repo re-clones, unlike a path under the working tree (which
    # the status server also serves).
    $cacheRoot = Join-Path $env:ProgramData 'Yuruna'
    $zipPath   = Join-Path $cacheRoot 'usbmmidd_v2.zip'
    $toolDir   = Join-Path $cacheRoot 'usbmmidd_v2'   # the zip's own top folder
    $installer = Join-Path $toolDir $installerExe

    if (-not (Get-Command Initialize-YurunaLogDir -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot 'Test.YurunaDir.psm1') -ErrorAction SilentlyContinue -Verbose:$false
    }
    $debugDir = Join-Path (Initialize-YurunaLogDir) 'VirtualDisplay'
    if (-not (Test-Path -LiteralPath $debugDir)) { New-Item -ItemType Directory -Force -Path $debugDir | Out-Null }
    $logPath = Join-Path $debugDir 'usbmmidd.log'

    # ── 1. Cache + verify the toolkit (download only when missing) ─────────
    if (-not (Test-Path -LiteralPath $installer)) {
        if (-not $PSCmdlet.ShouldProcess('Amyuni usbmmidd_v2 virtual-display driver', 'Download + verify')) {
            return 'Skipped'
        }
        if (-not (Test-Path -LiteralPath $cacheRoot)) { New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null }

        # Shared transient-fetch retry policy (squid 502/503, TLS blips). No
        # -Force on the import: that would evict an already-global copy and
        # break Module\Foo qualified calls elsewhere.
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        if (-not (Get-Command Invoke-WithYurunaRetry -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $repoRoot 'automation/Yuruna.Retry.psm1') -ErrorAction SilentlyContinue -Verbose:$false
        }

        $downloaded = $false
        if (Get-Command Invoke-WithYurunaRetry -ErrorAction SilentlyContinue) {
            # GetNewClosure so $url/$zipPath survive when the retry helper
            # invokes the scriptblock inside its own module scope -- a bare
            # scriptblock would resolve them to $null there.
            $fetch = { Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -TimeoutSec 120 }.GetNewClosure()
            $downloaded = (Invoke-WithYurunaRetry -Label 'download usbmmidd_v2' -LogPath $logPath -ScriptBlock $fetch).Success
        } else {
            try { Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -TimeoutSec 120; $downloaded = $true }
            catch { Add-Content -LiteralPath $logPath -Value "download failed: $($_.Exception.Message)" }
        }
        if (-not $downloaded -or -not (Test-Path -LiteralPath $zipPath)) {
            Write-Warning "Virtual-display driver download failed (see $logPath)."
            return 'Failed'
        }

        $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        if ($actual -ne $expectedSha256) {
            Write-Warning "Virtual-display driver checksum mismatch (expected $expectedSha256, got $actual) -- refusing to install."
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            return 'Failed'
        }

        if (Test-Path -LiteralPath $toolDir) { Remove-Item -LiteralPath $toolDir -Recurse -Force -ErrorAction SilentlyContinue }
        Expand-Archive -LiteralPath $zipPath -DestinationPath $cacheRoot -Force
    }
    if (-not (Test-Path -LiteralPath $installer)) {
        Write-Warning "Virtual-display installer missing after extract: $installer"
        return 'Failed'
    }
    $infName = (Get-ChildItem -LiteralPath $toolDir -Filter '*.inf' -ErrorAction SilentlyContinue | Select-Object -First 1).Name
    if (-not $infName) { Write-Warning "usbmmidd .inf not found in $toolDir"; return 'Failed' }

    # ── 2. usbmmidd monitor census ─────────────────────────────────────────
    # The vendor's enableidd is additive (up to 4 monitors), so a COUNT is the
    # source of truth, not a boolean "is one active?". A mid-cycle KVM switch
    # can leave a usbmmidd monitor PRESENT but not 'OK'; an "is one OK?" gate
    # then misfires and enableidd 1 stacks another monitor every cycle.
    # Converging on the count (section 4) collapses any leftover / duplicate /
    # unhealthy state back to exactly one.
    $isUsbmmidd  = { param($d) ($d.FriendlyName -like '*USB Mobile Monitor*') -or ($d.InstanceId -like '*USBMMIDD*') }
    $healthyCount = {
        @(Get-PnpDevice -PresentOnly -Class Monitor -ErrorAction SilentlyContinue |
            Where-Object { (& $isUsbmmidd $_) -and $_.Status -eq 'OK' }).Count
    }
    $presentCount = {
        @(Get-PnpDevice -PresentOnly -Class Monitor -ErrorAction SilentlyContinue |
            Where-Object { & $isUsbmmidd $_ }).Count
    }

    # ── 3. Stage the signed driver only when its devnode is absent ─────────
    # `install` creates a fresh root devnode on every call; gating on devnode
    # presence keeps re-runs (e.g. after a reboot dropped only the active
    # monitor) from piling up duplicate adapters.
    $devPresent = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like '*USBMMIDD*' -or $_.FriendlyName -like '*USB Mobile Monitor*' }).Count -gt 0
    if (-not $devPresent) {
        if ($PSCmdlet.ShouldProcess('Amyuni usbmmidd virtual-display driver', 'Install (stage signed driver)')) {
            Push-Location -LiteralPath $toolDir
            try {
                $out = & ".\$installerExe" install $infName usbmmidd 2>&1
                Add-Content -LiteralPath $logPath -Value "== install ==`n$($out | Out-String)"
            } finally { Pop-Location }
        } else { return 'Skipped' }
    }

    # ── 4. Converge to exactly ONE healthy virtual display ─────────────────
    # Leave a lone healthy monitor in place (no per-cycle flicker). For any
    # other state -- zero, several stacked, or one present-but-unhealthy --
    # reset deterministically: enableidd 0 disables ALL usbmmidd monitors,
    # then enableidd 1 brings up a single fresh one. The reset is independent
    # of the health detection, so it cannot keep stacking the way the old
    # "is one OK?" gate did when a monitor was present but not 'OK'.
    $alreadyOne = (((& $healthyCount) -eq 1) -and ((& $presentCount) -eq 1))
    if ($alreadyOne) {
        $status = 'AlreadyActive'
    } else {
        if ($PSCmdlet.ShouldProcess('Amyuni usbmmidd virtual display', 'Reset to exactly one virtual display (enableidd 0 then 1)')) {
            Push-Location -LiteralPath $toolDir
            try {
                $out = & ".\$installerExe" enableidd 0 2>&1
                Add-Content -LiteralPath $logPath -Value "== enableidd 0 (reset) ==`n$($out | Out-String)"
                Start-Sleep -Milliseconds 750
                $out = & ".\$installerExe" enableidd 1 2>&1
                Add-Content -LiteralPath $logPath -Value "== enableidd 1 ==`n$($out | Out-String)"
            } finally { Pop-Location }
        } else { return 'Skipped' }
        $status = 'Activated'
    }

    # ── 5. Confirm the VIRTUAL display specifically is live ────────────────
    # Confirm via the usbmmidd-specific signal only -- never a generic "any
    # monitor" count. With a physical monitor still attached, a generic count
    # would report success even if the virtual display never activated --
    # defeating the point, since capture must keep working once the physical
    # monitor leaves. The PnP devnode can lag the enableidd return, so poll on
    # a wall-clock deadline (not an iteration counter) before giving up.
    $deadlineUtc = [DateTime]::UtcNow.AddSeconds(20)
    $live = $false
    do {
        if ((& $healthyCount) -ge 1) { $live = $true; break }
        Start-Sleep -Milliseconds 1000
    } while ([DateTime]::UtcNow -lt $deadlineUtc)
    if (-not $live) { return 'Failed' }

    # ── 6. Mirror the main monitor, pin the virtual as primary, enforce ────
    #       the OCR resolution floor.
    # The virtual display must DUPLICATE (not extend) the physical one and be the
    # primary so the captured surface stays alive when the physical monitor is
    # removed (a cable unplug hot-removes the primary; if that were the physical
    # the capture would freeze). Because the topology is a clone, host windows
    # (Display Settings, etc.) still show on the physical monitor while it is
    # attached. The clone source must be >=1920x1080 or OCR on the captured frame
    # fails. Best-effort: a topology / resolution failure must not fail the cycle
    # (the attached monitor is the load-bearing part), so warn and keep the
    # monitor status.
    try { $null = Set-YurunaDisplayCloneAndResolution -LogPath $logPath }
    catch { Write-Warning "Display clone/resolution enforcement failed (non-fatal): $($_.Exception.Message)" }

    return $status
}

function Set-YurunaDisplayCloneAndResolution {
    <#
    .SYNOPSIS
    Put the physical and virtual displays into clone (duplicate) topology,
    make the VIRTUAL display the primary so the OCR capture surface survives the
    physical monitor being removed, and hold both at 1920x1080 so the duplicate
    keeps the operator's physical monitor mirroring that same OCR-sized image
    instead of a blank or extended desktop.
    .DESCRIPTION
    The runner reads the guest console off the host's primary display surface.
    When the PHYSICAL monitor is the primary and its cable is unplugged (a real
    display hot-removal, unlike a KVM switch that keeps the port's hot-plug line
    alive), the desktop loses its primary surface and the guest-console capture
    freezes -- the symptom is an OCR step that times out on a stale frame while
    the guest itself ran fine. Making the always-present usbmmidd virtual display
    the primary means removing the physical monitor only drops a secondary
    display, so the surface the runner captures never disappears; because the two
    are cloned, the operator still sees everything on the physical monitor while
    it is attached.

    A clone binds only when every display shares one identical mode; usbmmidd's
    native mode is 1920x1080, so the virtual display is held at 1920x1080 and set
    as the primary at desktop origin (0,0), and the physical monitor is normalised
    to that same 1920x1080 mode -- batched with CDS_NORESET and committed in one
    ChangeDisplaySettingsEx apply -- which is what lets the clone bind instead of
    silently falling back to an extended desktop (the symptom: host windows like
    Display Settings strand on a separate desktop region). Clone topology is then
    applied with SetDisplayConfig(SDC_APPLY|SDC_TOPOLOGY_CLONE); when the persisted
    topology database has no clone entry that call returns non-zero, so it falls
    back to DisplaySwitch.exe /clone (which rebuilds the entry and needs the
    interactive desktop session the runner already owns). The result is verified
    by re-reading every active display's position: any display still off (0,0)
    means Windows kept the desktop extended, which is surfaced as a warning.
    When the host has a single display (headless virtual-only, or physical-only)
    there is nothing to clone, so only the OCR resolution floor is held. The
    virtual display itself is pinned to 1920x1080 first (it powers up at a low
    1024x768 default that is too small for OCR and that the clone path would not
    otherwise resize while extended), so the capture surface is always at the
    floor whether or not a physical monitor is attached. The duplicate is
    enforced UNCONDITIONALLY when both a physical and a virtual display are
    present: a physical monitor running above 1920x1080 is downscaled to
    1920x1080 so the clone can bind (the cost of an always-duplicated surface),
    not left extended. The only fallback to extend is an exotic physical panel
    that advertises no 1920x1080 mode at all; the virtual display stays primary
    even then so the capture surface is still independent of the physical.
    Already-converged state (duplicated at 1920x1080, virtual primary) is detected
    and left untouched, so it does not flicker per cycle. Display SCALING on the
    primary is forced to 100% live via the CCD per-monitor DPI device-info call
    (the only way to apply it without a sign-out; the registry knobs in
    Set-WindowsHostConditionSet are the persisted backstop). Finally, every
    top-level app window whose centre sits off the primary monitor is pulled back
    onto it, so windows can't strand on an extended (invisible) desktop region.
    Idempotent; safe to call every cycle.
    Returns $true when topology, primary, resolution, or scale changed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([string]$LogPath)

    if (-not $IsWindows) { return $false }

    # Add-Type once per session (guarded). C# interop mirrors the PrintWindow
    # helper in host/windows.hyper-v/modules/Yuruna.Host.psm1 -- the repo idiom
    # for Win32 calls PowerShell has no cmdlet for.
    if (-not ([System.Management.Automation.PSTypeName]'Yuruna.DisplayConfig').Type) {
        try {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace Yuruna {
  public static class DisplayConfig {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
      public ushort dmSpecVersion;
      public ushort dmDriverVersion;
      public ushort dmSize;
      public ushort dmDriverExtra;
      public uint   dmFields;
      public int    dmPositionX;
      public int    dmPositionY;
      public uint   dmDisplayOrientation;
      public uint   dmDisplayFixedOutput;
      public short  dmColor;
      public short  dmDuplex;
      public short  dmYResolution;
      public short  dmTTOption;
      public short  dmCollate;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
      public ushort dmLogPixels;
      public uint   dmBitsPerPel;
      public uint   dmPelsWidth;
      public uint   dmPelsHeight;
      public uint   dmDisplayFlags;
      public uint   dmDisplayFrequency;
      public uint   dmICMMethod;
      public uint   dmICMIntent;
      public uint   dmMediaType;
      public uint   dmDitherType;
      public uint   dmReserved1;
      public uint   dmReserved2;
      public uint   dmPanningWidth;
      public uint   dmPanningHeight;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
      public int cb;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
      public uint StateFlags;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);
    [DllImport("user32.dll")]
    public static extern int SetDisplayConfig(uint numPathArrayElements, IntPtr pathArray, uint numModeInfoArrayElements, IntPtr modeInfoArray, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettingsEx(string deviceName, ref DEVMODE devMode, IntPtr hwnd, uint flags, IntPtr lParam);
    // Null-DEVMODE overload: commits a batch of per-device changes staged
    // with CDS_NORESET. Same native export, distinct managed signature so
    // the layout (primary + positions) applies atomically in one shot.
    [DllImport("user32.dll", EntryPoint = "ChangeDisplaySettingsExW", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettingsExApply(string deviceName, IntPtr devMode, IntPtr hwnd, uint flags, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern uint GetDpiForSystem();

    // ── Window-repositioning sweep ──────────────────────────────────────
    // Moves any top-level app window whose centre sits off the PRIMARY
    // monitor's work area back inside it, so windows can't strand on an
    // extended (invisible) virtual display. Centre-based so a window that is
    // merely hanging slightly off-edge is left alone; only windows that
    // genuinely live on the other monitor are pulled in.
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll", SetLastError = true)] public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, out RECT pvParam, uint fWinIni);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int left; public int top; public int right; public int bottom; }

    public static int ConstrainWindowsToPrimary() {
      const uint SPI_GETWORKAREA = 0x0030;
      const int  GWL_EXSTYLE     = -20;
      const int  GW_OWNER        = 4;
      const int  WS_EX_TOOLWINDOW = 0x00000080;
      const int  WS_EX_APPWINDOW  = 0x00040000;
      const uint SWP_NOSIZE = 0x0001, SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;
      RECT wa;
      if (!SystemParametersInfo(SPI_GETWORKAREA, 0, out wa, 0)) return -1;
      int waw = wa.right - wa.left, wah = wa.bottom - wa.top;
      if (waw <= 0 || wah <= 0) return -1;
      int moved = 0;
      EnumWindows((hWnd, lp) => {
        if (!IsWindowVisible(hWnd) || IsIconic(hWnd) || IsZoomed(hWnd)) return true;
        int ex = GetWindowLong(hWnd, GWL_EXSTYLE);
        if ((ex & WS_EX_TOOLWINDOW) != 0) return true;
        IntPtr owner = GetWindow(hWnd, GW_OWNER);
        if (owner != IntPtr.Zero && (ex & WS_EX_APPWINDOW) == 0) return true;
        if (GetWindowTextLength(hWnd) == 0) return true;
        // Skip the shell surfaces (desktop, taskbar) -- never reposition those.
        var cls = new System.Text.StringBuilder(64);
        GetClassName(hWnd, cls, cls.Capacity);
        string c = cls.ToString();
        if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") return true;
        RECT r;
        if (!GetWindowRect(hWnd, out r)) return true;
        int w = r.right - r.left, h = r.bottom - r.top;
        if (w <= 0 || h <= 0) return true;
        int cx = r.left + w / 2, cy = r.top + h / 2;
        bool centreInside = (cx >= wa.left && cx < wa.right && cy >= wa.top && cy < wa.bottom);
        if (centreInside) return true;
        int newX = (w > waw) ? wa.left : Math.Max(wa.left, Math.Min(r.left, wa.right - w));
        int newY = (h > wah) ? wa.top  : Math.Max(wa.top,  Math.Min(r.top,  wa.bottom - h));
        if (newX != r.left || newY != r.top) {
          if (SetWindowPos(hWnd, IntPtr.Zero, newX, newY, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)) moved++;
        }
        return true;
      }, IntPtr.Zero);
      return moved;
    }

    // ── Live per-monitor DPI scale (undocumented CCD device-info, stable
    //    since Windows 10 1607; the only way to set 100% without sign-out).
    //    The minimum scale Windows offers is always 100%, so setting the
    //    relative scale to its minimum is exactly 100% -- no DPI table needed.
    [StructLayout(LayoutKind.Sequential)]
    public struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_RATIONAL { public uint Numerator; public uint Denominator; }
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_SOURCE_INFO { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_TARGET_INFO {
      public LUID adapterId; public uint id; public uint modeInfoIdx;
      public uint outputTechnology; public uint rotation; public uint scaling;
      public DISPLAYCONFIG_RATIONAL refreshRate; public uint scanLineOrdering;
      public int targetAvailable; public uint statusFlags;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_INFO { public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo; public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo; public uint flags; }
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_MODE_INFO_BLOB { [MarshalAs(UnmanagedType.ByValArray, SizeConst = 64)] public byte[] data; }
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_DEVICE_INFO_HEADER { public int type; public uint size; public LUID adapterId; public uint id; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAYCONFIG_SOURCE_DEVICE_NAME { public DISPLAYCONFIG_DEVICE_INFO_HEADER header; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string viewGdiDeviceName; }
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SOURCE_DPI_SCALE_GET { public DISPLAYCONFIG_DEVICE_INFO_HEADER header; public int minScaleRel; public int curScaleRel; public int maxScaleRel; }
    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_SOURCE_DPI_SCALE_SET { public DISPLAYCONFIG_DEVICE_INFO_HEADER header; public int scaleRel; }

    [DllImport("user32.dll")] public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);
    [DllImport("user32.dll")] public static extern int QueryDisplayConfig(uint flags, ref uint numPathArrayElements, [Out] DISPLAYCONFIG_PATH_INFO[] pathInfoArray, ref uint numModeInfoArrayElements, [Out] DISPLAYCONFIG_MODE_INFO_BLOB[] modeInfoArray, IntPtr currentTopologyId);
    [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DEVICE_NAME requestPacket);
    [DllImport("user32.dll")] public static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DPI_SCALE_GET requestPacket);
    [DllImport("user32.dll")] public static extern int DisplayConfigSetDeviceInfo(ref DISPLAYCONFIG_SOURCE_DPI_SCALE_SET setPacket);

    // Returns: 1 set to 100%, 0 already 100%, -1 device not in active paths,
    // -2 a CCD call failed.
    public static int SetSourceDpiTo100(string gdiDeviceName) {
      const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;
      const int  GET_SOURCE_NAME = 1, GET_DPI_SCALE = -3, SET_DPI_SCALE = -4;
      uint numPath, numMode;
      if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out numPath, out numMode) != 0) return -2;
      var paths = new DISPLAYCONFIG_PATH_INFO[numPath];
      var modes = new DISPLAYCONFIG_MODE_INFO_BLOB[numMode];
      if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref numPath, paths, ref numMode, modes, IntPtr.Zero) != 0) return -2;
      for (uint i = 0; i < numPath; i++) {
        var src = paths[i].sourceInfo;
        var sn = new DISPLAYCONFIG_SOURCE_DEVICE_NAME();
        sn.header.type = GET_SOURCE_NAME;
        sn.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_SOURCE_DEVICE_NAME));
        sn.header.adapterId = src.adapterId; sn.header.id = src.id;
        if (DisplayConfigGetDeviceInfo(ref sn) != 0) continue;
        if (!string.Equals(sn.viewGdiDeviceName, gdiDeviceName, StringComparison.OrdinalIgnoreCase)) continue;
        var g = new DISPLAYCONFIG_SOURCE_DPI_SCALE_GET();
        g.header.type = GET_DPI_SCALE;
        g.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_SOURCE_DPI_SCALE_GET));
        g.header.adapterId = src.adapterId; g.header.id = src.id;
        if (DisplayConfigGetDeviceInfo(ref g) != 0) return -2;
        if (g.curScaleRel == g.minScaleRel) return 0; // already 100%
        var s = new DISPLAYCONFIG_SOURCE_DPI_SCALE_SET();
        s.header.type = SET_DPI_SCALE;
        s.header.size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_SOURCE_DPI_SCALE_SET));
        s.header.adapterId = src.adapterId; s.header.id = src.id;
        s.scaleRel = g.minScaleRel; // minimum relative == 100%
        if (DisplayConfigSetDeviceInfo(ref s) != 0) return -2;
        return 1;
      }
      return -1;
    }
  }
}
'@
        } catch {
            Write-Warning "Could not compile Yuruna.DisplayConfig interop; skipping clone/resolution enforcement: $($_.Exception.Message)"
            return $false
        }
    }

    $changed = $false

    # ── Win32 display flags (PowerShell-side constants) ────────────────────
    $ENUM_CURRENT_SETTINGS              = -1
    $DM_POSITION                        = 0x00000020
    $DM_PELSWIDTH                       = 0x00080000
    $DM_PELSHEIGHT                      = 0x00100000
    $CDS_UPDATEREGISTRY                 = 0x00000001
    $CDS_SET_PRIMARY                    = 0x00000010
    $CDS_NORESET                        = 0x10000000
    $DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 0x00000001
    $DISPLAY_DEVICE_PRIMARY             = 0x00000004
    $SDC_APPLY                          = 0x00000080
    $SDC_TOPOLOGY_CLONE                 = 0x00000002

    # Enumerate every display ATTACHED_TO_DESKTOP, tagging the usbmmidd virtual
    # monitor (by adapter OR child-monitor DeviceString) and reading its current
    # mode and desktop position. Position is the clone/extend tell: in clone
    # topology every active display shares one source at (0,0); a non-(0,0)
    # position means Windows kept the desktop extended.
    $enumActive = {
        $d = New-Object 'Yuruna.DisplayConfig+DISPLAY_DEVICE'
        $d.cb = [int][System.Runtime.InteropServices.Marshal]::SizeOf($d)
        $idx = 0
        while ([Yuruna.DisplayConfig]::EnumDisplayDevices($null, $idx, [ref]$d, 0)) {
            if (($d.StateFlags -band $DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) -ne 0) {
                $nm         = $d.DeviceName
                $adapterStr = $d.DeviceString
                $mon = New-Object 'Yuruna.DisplayConfig+DISPLAY_DEVICE'
                $mon.cb = [int][System.Runtime.InteropServices.Marshal]::SizeOf($mon)
                $monStr = ''
                if ([Yuruna.DisplayConfig]::EnumDisplayDevices($nm, 0, [ref]$mon, 0)) { $monStr = $mon.DeviceString }
                $md = New-Object 'Yuruna.DisplayConfig+DEVMODE'
                $md.dmSize = [uint16][System.Runtime.InteropServices.Marshal]::SizeOf($md)
                $hasMode = [bool][Yuruna.DisplayConfig]::EnumDisplaySettings($nm, $ENUM_CURRENT_SETTINGS, [ref]$md)
                [pscustomobject]@{
                    Name      = $nm
                    IsPrimary = (($d.StateFlags -band $DISPLAY_DEVICE_PRIMARY) -ne 0)
                    IsVirtual = (($adapterStr -like '*USB Mobile Monitor*') -or ($monStr -like '*USB Mobile Monitor*'))
                    HasMode   = $hasMode
                    Width     = [int]$md.dmPelsWidth
                    Height    = [int]$md.dmPelsHeight
                    PosX      = [int]$md.dmPositionX
                    PosY      = [int]$md.dmPositionY
                }
            }
            $idx++
            $d = New-Object 'Yuruna.DisplayConfig+DISPLAY_DEVICE'
            $d.cb = [int][System.Runtime.InteropServices.Marshal]::SizeOf($d)
        }
    }

    # Pick a 1920x1080-preferring mode the device supports: exact 1920x1080 when
    # available (usbmmidd's native mode and the OCR floor), else the smallest
    # mode that still clears the floor. $null when the panel cannot reach
    # 1920x1080 (e.g. a 1366x768 laptop) -- then no common clone mode exists
    # with the 1920x1080 virtual display. Returns @{ W; H } or $null.
    $pickFloorMode = {
        param($deviceName)
        $cands = [System.Collections.Generic.List[object]]::new()
        $j = 0
        while ($true) {
            $pm = New-Object 'Yuruna.DisplayConfig+DEVMODE'
            $pm.dmSize = [uint16][System.Runtime.InteropServices.Marshal]::SizeOf($pm)
            if (-not [Yuruna.DisplayConfig]::EnumDisplaySettings($deviceName, $j, [ref]$pm)) { break }
            if ($pm.dmPelsWidth -ge 1920 -and $pm.dmPelsHeight -ge 1080) {
                $cands.Add([pscustomobject]@{ W = [int]$pm.dmPelsWidth; H = [int]$pm.dmPelsHeight })
            }
            $j++
        }
        if ($cands.Count -eq 0) { return $null }
        $exact = @($cands | Where-Object { $_.W -eq 1920 -and $_.H -eq 1080 })
        if ($exact.Count -gt 0) { return $exact[0] }
        return ($cands | Sort-Object { $_.W * $_.H } | Select-Object -First 1)
    }

    # Stage a per-device width/height/position/primary change with CDS_NORESET
    # so a batch of displays is laid out coherently before one apply. Only
    # W/H/position are touched (refresh + colour depth left to Windows to keep
    # the mode valid). Returns the ChangeDisplaySettingsEx rc, or $null when the
    # device's current mode could not be read.
    $stageDeviceMode = {
        param($deviceName, $w, $h, $x, $y, $makePrimary)
        $dm = New-Object 'Yuruna.DisplayConfig+DEVMODE'
        $dm.dmSize = [uint16][System.Runtime.InteropServices.Marshal]::SizeOf($dm)
        if (-not [Yuruna.DisplayConfig]::EnumDisplaySettings($deviceName, $ENUM_CURRENT_SETTINGS, [ref]$dm)) { return $null }
        $dm.dmPelsWidth  = [uint32]$w
        $dm.dmPelsHeight = [uint32]$h
        $dm.dmPositionX  = [int]$x
        $dm.dmPositionY  = [int]$y
        $dm.dmFields     = $DM_PELSWIDTH -bor $DM_PELSHEIGHT -bor $DM_POSITION
        $flags = $CDS_UPDATEREGISTRY -bor $CDS_NORESET
        if ($makePrimary) { $flags = $flags -bor $CDS_SET_PRIMARY }
        return [Yuruna.DisplayConfig]::ChangeDisplaySettingsEx($deviceName, [ref]$dm, [IntPtr]::Zero, $flags, [IntPtr]::Zero)
    }

    # True when the device advertises an exact WxH mode. Used to decide whether
    # the physical monitor can share the virtual display's fixed 1920x1080 clone
    # mode, and whether the virtual display itself can reach the OCR floor.
    $supportsMode = {
        param($deviceName, $w, $h)
        $j = 0
        while ($true) {
            $pm = New-Object 'Yuruna.DisplayConfig+DEVMODE'
            $pm.dmSize = [uint16][System.Runtime.InteropServices.Marshal]::SizeOf($pm)
            if (-not [Yuruna.DisplayConfig]::EnumDisplaySettings($deviceName, $j, [ref]$pm)) { break }
            if ($pm.dmPelsWidth -eq $w -and $pm.dmPelsHeight -eq $h) { return $true }
            $j++
        }
        return $false
    }

    # The OCR capture surface and the clone's common mode are both pinned to
    # 1920x1080: it is the virtual display's native (and only universally
    # shared) mode, and it clears the resolution OCR needs to read a guest
    # console reliably.
    $cloneW = 1920
    $cloneH = 1080

    # ── 1. Force every VIRTUAL display to the 1920x1080 floor ──────────────
    # The usbmmidd monitor powers up at a low default mode (1024x768) that is too
    # small for reliable OCR, and when a physical monitor is attached and
    # extended the clone path below never resizes the virtual one. Pin it here
    # unconditionally so the capture surface is always >= 1920x1080 whether the
    # host is headless or has a physical monitor -- this is the surface the guest
    # VMs render through once a KVM switch removes the physical display.
    $active = @(& $enumActive)
    foreach ($v in @($active | Where-Object { $_.IsVirtual -and $_.HasMode })) {
        if ($v.Width -ge $cloneW -and $v.Height -ge $cloneH) { continue }
        if (-not (& $supportsMode $v.Name $cloneW $cloneH)) {
            Write-Warning "Virtual display '$($v.Name)' does not advertise a ${cloneW}x${cloneH} mode; OCR may fail. Check the usbmmidd EDID modes."
            continue
        }
        if ($PSCmdlet.ShouldProcess("Virtual display $($v.Name) ($($v.Width)x$($v.Height))", "Set ${cloneW}x${cloneH} (OCR floor)")) {
            $null    = & $stageDeviceMode $v.Name $cloneW $cloneH $v.PosX $v.PosY $false
            $applyRc = [Yuruna.DisplayConfig]::ChangeDisplaySettingsExApply($null, [IntPtr]::Zero, [IntPtr]::Zero, 0, [IntPtr]::Zero)
            if ($LogPath) { Add-Content -LiteralPath $LogPath -Value "== virtual '$($v.Name)' -> ${cloneW}x${cloneH} (OCR floor) apply rc=$applyRc ==" }
            if ($applyRc -eq 0) { $changed = $true }
        }
    }

    # Re-read after the virtual resize so the topology decision sees current modes.
    $active   = @(& $enumActive)
    $physical = @($active | Where-Object { -not $_.IsVirtual -and $_.HasMode })
    $virtuals = @($active | Where-Object {       $_.IsVirtual -and $_.HasMode })
    $extended = (@($active | Where-Object { $_.PosX -ne 0 -or $_.PosY -ne 0 }).Count -gt 0)

    if ($physical.Count -ge 1 -and $virtuals.Count -ge 1) {
        # ── 2. Physical + virtual attached → DUPLICATE (clone), always ─────
        # The VIRTUAL display is made the primary so the surface the runner
        # captures is anchored to the always-present display; unplugging the
        # physical monitor then only drops a secondary and the guest-console
        # capture never freezes. A clone binds only when every active display
        # shares one identical mode; the virtual display is fixed at 1920x1080
        # (step 1), so the physical monitor is normalised to 1920x1080 as well --
        # downscaled if it was running higher. Downscaling a high-resolution
        # monitor for the duration of a test run is the accepted cost of an
        # always-duplicated surface; the alternative (leaving a high-res monitor
        # extended) strands host windows on a separate desktop region. Because
        # the topology is a clone, the operator still sees the identical image on
        # the physical monitor while it is attached.
        $virtTarget = ($virtuals | Where-Object { $_.IsPrimary } | Select-Object -First 1)
        if (-not $virtTarget) { $virtTarget = $virtuals[0] }
        $physTarget = ($physical | Where-Object { $_.IsPrimary } | Select-Object -First 1)
        if (-not $physTarget) { $physTarget = $physical[0] }

        # A clone needs the physical monitor to share the virtual display's fixed
        # 1920x1080 mode. Virtually every monitor advertises it; an exotic panel
        # that does not cannot share a mode with the 1920x1080 virtual display, so
        # the desktop stays extended -- but the virtual display is still made
        # primary so the capture surface stays independent of the physical (the
        # window sweep below keeps the extended desktop usable).
        $canClone = (& $supportsMode $physTarget.Name $cloneW $cloneH)
        if (-not $canClone) {
            Write-Warning "Clone: physical display '$($physTarget.Name)' does not advertise a ${cloneW}x${cloneH} mode (the virtual display's only shared resolution); cannot duplicate. Making the virtual display primary anyway; the desktop stays extended."
        }

        # Skip the re-apply when already converged (duplicated at 1920x1080 with
        # the virtual display primary) so the steady state does not flicker every
        # cycle. In clone topology every active display reports position (0,0); a
        # non-(0,0) position is the extended tell.
        $converged = $canClone -and (-not $extended) -and $virtTarget.IsPrimary -and
                     ($virtTarget.Width -eq $cloneW) -and ($virtTarget.Height -eq $cloneH)

        if ($converged) {
            if ($LogPath) { Add-Content -LiteralPath $LogPath -Value "== already duplicated at ${cloneW}x${cloneH}, virtual '$($virtTarget.Name)' primary; no change ==" }
        } else {
            if ($PSCmdlet.ShouldProcess("Virtual display $($virtTarget.Name)", "Set ${cloneW}x${cloneH} + primary at (0,0); lay out the other monitor(s)")) {
                $null  = & $stageDeviceMode $virtTarget.Name $cloneW $cloneH 0 0 $true
                $nextX = $cloneW
                foreach ($other in @($active | Where-Object { $_.Name -ne $virtTarget.Name -and $_.HasMode })) {
                    # Stage the other display(s) at the SAME mode so the clone has
                    # an identical mode to bind to. Position is irrelevant once the
                    # clone binds, but lay them out to the right so the desktop is
                    # still usable if the clone cannot bind. A physical monitor that
                    # cannot reach 1920x1080 keeps its own mode (extended).
                    $ow = if ($canClone) { $cloneW } else { $other.Width }
                    $oh = if ($canClone) { $cloneH } else { $other.Height }
                    $null   = & $stageDeviceMode $other.Name $ow $oh $nextX 0 $false
                    $nextX += $ow
                }
                $applyRc = [Yuruna.DisplayConfig]::ChangeDisplaySettingsExApply($null, [IntPtr]::Zero, [IntPtr]::Zero, 0, [IntPtr]::Zero)
                if ($LogPath) { Add-Content -LiteralPath $LogPath -Value "== virtual '$($virtTarget.Name)' -> primary ${cloneW}x${cloneH} at (0,0); apply rc=$applyRc ==" }
                $changed = $true
            }

            if ($canClone) {
                # ── Clone (duplicate) topology across all active displays ──
                if ($PSCmdlet.ShouldProcess('All active displays', 'Set clone (duplicate) topology')) {
                    $rc = [Yuruna.DisplayConfig]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, ($SDC_APPLY -bor $SDC_TOPOLOGY_CLONE))
                    if ($LogPath) { Add-Content -LiteralPath $LogPath -Value "== SetDisplayConfig(clone) rc=$rc ==" }
                    if ($rc -ne 0) {
                        # Persisted topology DB had no clone entry; DisplaySwitch rebuilds it.
                        $displaySwitch = Join-Path $env:WINDIR 'System32\DisplaySwitch.exe'
                        if (Test-Path -LiteralPath $displaySwitch) {
                            try {
                                Start-Process -FilePath $displaySwitch -ArgumentList '/clone' -Wait -WindowStyle Hidden -ErrorAction Stop
                                if ($LogPath) { Add-Content -LiteralPath $LogPath -Value "== DisplaySwitch.exe /clone (fallback) ==" }
                            } catch {
                                Write-Warning "Clone topology: SetDisplayConfig rc=$rc and DisplaySwitch fallback failed: $($_.Exception.Message)"
                            }
                        } else {
                            Write-Warning "Clone topology: SetDisplayConfig rc=$rc and DisplaySwitch.exe not found."
                        }
                    }
                    $changed = $true
                }

                # ── Verify the clone actually bound ────────────────────────
                $postActive = @(& $enumActive)
                $stillExtended = (@($postActive | Where-Object { $_.PosX -ne 0 -or $_.PosY -ne 0 }).Count -gt 0)
                if ($stillExtended) {
                    $layout = ($postActive | ForEach-Object {
                            "$($_.Name)$(if ($_.IsVirtual) { ' (virtual)' })@$($_.PosX),$($_.PosY) $($_.Width)x$($_.Height)$(if ($_.IsPrimary) { ' [primary]' })"
                        }) -join '; '
                    Write-Warning "Clone enforcement: displays are still EXTENDED, not duplicated ($layout). The virtual display is primary so the capture surface is preserved, but the physical monitor shows a separate desktop region. See docs/host-hyperv.md."
                    if ($LogPath) { Add-Content -LiteralPath $LogPath -Value "== clone NOT bound; still extended: $layout ==" }
                } elseif ($LogPath) {
                    Add-Content -LiteralPath $LogPath -Value "== clone verified: all active displays at (0,0) =="
                }
            }
        }
    } else {
        # ── 3. Single display (headless virtual-only, or physical-only) ────
        # Nothing to clone. A headless host's lone virtual display was already
        # pinned to >= 1920x1080 in step 1; this also holds the floor on a
        # physical-only host that has no virtual display yet. Target the primary
        # by name -- EnumDisplaySettings against $null reads the calling thread's
        # window and returns nothing from a windowless runner step. No topology
        # change, so the converged state does not flicker per cycle.
        $primaryActive = ($active | Where-Object { $_.IsPrimary -and $_.HasMode } | Select-Object -First 1)
        if (-not $primaryActive) { $primaryActive = ($active | Where-Object { $_.HasMode } | Select-Object -First 1) }
        if ($primaryActive -and ($primaryActive.Width -lt $cloneW -or $primaryActive.Height -lt $cloneH)) {
            $mode = & $pickFloorMode $primaryActive.Name
            if ($mode) {
                if ($PSCmdlet.ShouldProcess("Primary display ($($primaryActive.Width)x$($primaryActive.Height))", "Set resolution $($mode.W)x$($mode.H) (OCR floor)")) {
                    $rc      = & $stageDeviceMode $primaryActive.Name $mode.W $mode.H $primaryActive.PosX $primaryActive.PosY $false
                    $applyRc = [Yuruna.DisplayConfig]::ChangeDisplaySettingsExApply($null, [IntPtr]::Zero, [IntPtr]::Zero, 0, [IntPtr]::Zero)
                    if ($LogPath) { Add-Content -LiteralPath $LogPath -Value "== floor primary '$($primaryActive.Name)' -> $($mode.W)x$($mode.H) (stage rc=$rc apply rc=$applyRc) ==" }
                    if ($applyRc -ne 0) { Write-Warning "Resolution floor: apply returned $applyRc (0 = success)." } else { $changed = $true }
                }
            } else {
                Write-Warning "Resolution floor: no display mode >= 1920x1080 is available on the primary; OCR may fail. Check the virtual display's EDID modes."
            }
        }
    }

    # ── Scaling: force the PRIMARY to 100% live ────────────────────────────
    # OCR needs 100%. The registry knobs in Set-WindowsHostConditionSet only
    # apply on next sign-in; the CCD per-monitor DPI device-info call applies
    # immediately (best-effort -- never fails the cycle). Re-read the primary's
    # GDI name after the layout changes above so the right source is targeted.
    $primaryName = ((@(& $enumActive) | Where-Object { $_.IsPrimary -and $_.HasMode } | Select-Object -First 1)).Name
    if ($primaryName) {
        if ($PSCmdlet.ShouldProcess("Primary display $primaryName", 'Set display scale to 100% (live)')) {
            try {
                $scaleRc = [Yuruna.DisplayConfig]::SetSourceDpiTo100($primaryName)
                if ($LogPath) { Add-Content -LiteralPath $LogPath -Value "== SetSourceDpiTo100('$primaryName') rc=$scaleRc (1=set 0=already100 -1=notfound -2=error) ==" }
                if ($scaleRc -eq 1) { $changed = $true }
                elseif ($scaleRc -lt 0) {
                    # Fall back to surfacing the system DPI so the operator still
                    # gets a signal even when the live set could not be applied.
                    $dpi = 96
                    try { $dpi = [int][Yuruna.DisplayConfig]::GetDpiForSystem() } catch { $dpi = 96 }
                    if ($dpi -gt 96) {
                        $pct = [int][math]::Round(($dpi / 96.0) * 100)
                        Write-Warning "Could not set display scale to 100% live (rc=$scaleRc); system scaling reads ${pct}%. Set-WindowsHostConditionSet writes the 100% registry knobs, but they apply on next sign-in -- sign out/in (or reboot) the host."
                    }
                }
            } catch {
                Write-Warning "Live display-scale enforcement failed (non-fatal): $($_.Exception.Message)"
            }
        }
    }

    # ── Pull any window stranded off the primary back onto it ──────────────
    # New windows open on the primary, but apps that remember a position (or a
    # window dragged onto the extended virtual display) can land off-screen.
    # Best-effort; never fails the cycle.
    if ($PSCmdlet.ShouldProcess('Top-level windows', 'Move windows off the primary back onto it')) {
        try {
            $movedCount = [Yuruna.DisplayConfig]::ConstrainWindowsToPrimary()
            if ($LogPath) { Add-Content -LiteralPath $LogPath -Value "== ConstrainWindowsToPrimary moved=$movedCount ==" }
            if ($movedCount -gt 0) {
                Write-Information "Moved $movedCount window(s) off the virtual display back onto the primary."
                $changed = $true
            }
        } catch {
            Write-Warning "Window-reposition sweep failed (non-fatal): $($_.Exception.Message)"
        }
    }

    return $changed
}

function Remove-YurunaVirtualDisplay {
    <#
    .SYNOPSIS
    Tear down every usbmmidd virtual display on this Hyper-V host so a machine
    that has stopped running tests does not keep a synthetic display attached,
    and any duplicate/stale monitor left by a mid-cycle KVM switch is cleaned up.
    .DESCRIPTION
    Inverse of Install-YurunaVirtualDisplay: runs the vendor's
    `deviceinstaller64 enableidd 0`, which disables ALL usbmmidd virtual
    monitors in one shot (matching how the install path converges on the count,
    not a single monitor), and VERIFIES the monitor census actually dropped to
    zero. `enableidd 0` is a soft teardown of the display SURFACE that keeps the
    signed driver staged in the ProgramData cache for a fast `enableidd 1` next
    cycle; when a monitor stubbornly lingers (a wedged devnode, or a mid-cycle
    KVM switch that left one present-but-unhealthy), it escalates to
    `stop usbmmidd`, which detaches the device node entirely. Either way the
    driver INF stays cached, so the next run re-attaches without a re-download.
    No-op when the cached installer is absent (driver never staged) or no
    usbmmidd monitor is present. Returns a status string: 'Removed',
    'AlreadyAbsent', 'Failed', 'Skipped' (ShouldProcess declined / -WhatIf), or
    'Unsupported' (non-Windows).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param()

    if (-not $IsWindows) { return 'Unsupported' }

    # Same architecture-pinned installer name + cache layout as the install
    # path; if those drift, both must change together.
    $installerExe = if ($env:PROCESSOR_ARCHITECTURE -eq 'x86') { 'deviceinstaller.exe' } else { 'deviceinstaller64.exe' }
    $cacheRoot = Join-Path $env:ProgramData 'Yuruna'
    $toolDir   = Join-Path $cacheRoot 'usbmmidd_v2'
    $installer = Join-Path $toolDir $installerExe

    # usbmmidd present-monitor census -- the same usbmmidd-specific signal the
    # install path converges on (never a generic "any monitor" count, which a
    # physical display would satisfy). Nothing present -> nothing to tear down.
    $isUsbmmidd   = { param($d) ($d.FriendlyName -like '*USB Mobile Monitor*') -or ($d.InstanceId -like '*USBMMIDD*') }
    $presentCount = {
        @(Get-PnpDevice -PresentOnly -Class Monitor -ErrorAction SilentlyContinue |
            Where-Object { & $isUsbmmidd $_ }).Count
    }

    if (-not (Test-Path -LiteralPath $installer)) {
        # Driver never staged on this host. If a usbmmidd monitor is somehow
        # present we cannot drive enableidd without the tool -- surface it;
        # otherwise there is genuinely nothing to clean up.
        if ((& $presentCount) -gt 0) {
            Write-Warning "usbmmidd virtual display(s) present but the cached installer is missing ($installer); cannot disable them."
            return 'Failed'
        }
        return 'AlreadyAbsent'
    }
    if ((& $presentCount) -eq 0) { return 'AlreadyAbsent' }

    if (-not $PSCmdlet.ShouldProcess('Amyuni usbmmidd virtual display', 'Disable all virtual displays (enableidd 0)')) {
        return 'Skipped'
    }

    if (-not (Get-Command Initialize-YurunaLogDir -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path $PSScriptRoot 'Test.YurunaDir.psm1') -ErrorAction SilentlyContinue -Verbose:$false
    }
    $debugDir = Join-Path (Initialize-YurunaLogDir) 'VirtualDisplay'
    if (-not (Test-Path -LiteralPath $debugDir)) { New-Item -ItemType Directory -Force -Path $debugDir | Out-Null }
    $logPath = Join-Path $debugDir 'usbmmidd.log'

    # Run a deviceinstaller verb, then poll the usbmmidd monitor census on a
    # wall-clock deadline (the PnP devnode can lag the command's return) and
    # report whether the monitor(s) went away. Returns $true once none remain.
    $runVerb = {
        param([string[]]$verbArgs, [string]$label)
        Push-Location -LiteralPath $toolDir
        try {
            $out = & ".\$installerExe" @verbArgs 2>&1
            Add-Content -LiteralPath $logPath -Value "== $label ==`n$($out | Out-String)"
        } finally { Pop-Location }
        $deadlineUtc = [DateTime]::UtcNow.AddSeconds(20)
        do {
            if ((& $presentCount) -eq 0) { return $true }
            Start-Sleep -Milliseconds 1000
        } while ([DateTime]::UtcNow -lt $deadlineUtc)
        return $false
    }

    # Tear down in escalating strength, stopping as soon as no usbmmidd monitor
    # remains. `enableidd 0` disables the monitor surface but leaves the device
    # staged for a fast `enableidd 1` next cycle. If a monitor still lingers (a
    # wedged devnode, or a mid-cycle KVM switch that left it present-but-
    # unhealthy), escalate to `stop usbmmidd`, which detaches the device node --
    # the vendor's own uninstall step. The signed driver INF stays in the
    # ProgramData cache either way, so the next run re-attaches without a
    # re-download (Install-YurunaVirtualDisplay re-stages the devnode if `stop`
    # removed it).
    if (& $runVerb @('enableidd', '0') 'enableidd 0 (teardown)') { return 'Removed' }

    Write-Warning "usbmmidd virtual display(s) still present after enableidd 0; escalating to 'stop usbmmidd'."
    if (& $runVerb @('stop', 'usbmmidd') 'stop usbmmidd (escalated teardown)') { return 'Removed' }

    Write-Warning "usbmmidd virtual display(s) still present after enableidd 0 and stop (see $logPath). Reconnect/disconnect the physical monitor or reboot the host to clear it."
    return 'Failed'
}

function Set-YurunaDisplayScale100 {
    <#
    .SYNOPSIS
    Persist the host's display/text scale at 100% across three independent
    HKCU knobs (per-monitor DPI, system DPI fallback, Win11 TextScaleFactor)
    so HiDPI up-scaling doesn't defeat OCR on VM screenshots.
    .DESCRIPTION
    The registry backstop for the live CCD scale enforcement in
    Set-YurunaDisplayCloneAndResolution: these knobs apply on next sign-in, so
    they hold the scale at 100% across reboots once set. Part of the opt-in
    virtual-display feature -- callers gate it on YURUNA_VIRTUAL_DISPLAY.
    Returns $true when any knob changed (the caller surfaces the
    sign-in-required notice), $false when everything was already 100%.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param()

    # Display text scale -> 100% on three independent HKCU knobs
    # (per-monitor DPI, system DPI fallback, Win11 TextScaleFactor).
    # Rationale and registry keys: https://yuruna.link/host/hyperv
    $scaleChanged = $false

    # REG_DWORD → signed int32: Windows writes DpiValue as signed (e.g.
    # -2 for "two steps below recommended") but PowerShell surfaces
    # REG_DWORD as UInt32 — -2 arrives as 4294967294 and a bare [int]
    # cast throws OverflowException. Reinterpret bits: values with the
    # high bit set map to their two's-complement signed equivalent.
    $asSignedDword = {
        param($raw)
        if ($null -eq $raw) { return 0 }
        $u = [uint32]$raw
        if ($u -gt [int32]::MaxValue) { return [int32]($u - 0x100000000) } else { return [int32]$u }
    }

    # 7a. Per-monitor DPI
    # foreach statement (not ForEach-Object) so $scaleChanged writes
    # reach function scope — ForEach-Object's scriptblock runs in a
    # child scope where the assignment would be silently local.
    $perMonPath = 'HKCU:\Control Panel\Desktop\PerMonitorSettings'
    if (Test-Path -LiteralPath $perMonPath) {
        $monKeys = Get-ChildItem -LiteralPath $perMonPath -Recurse -ErrorAction SilentlyContinue |
                   Where-Object { $_.PSIsContainer }
        foreach ($mon in $monKeys) {
            $props = Get-ItemProperty -LiteralPath $mon.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) { continue }
            if (-not ($props.PSObject.Properties.Name -contains 'DpiValue')) { continue }
            $current     = & $asSignedDword $props.DpiValue
            $recommended = if ($props.PSObject.Properties.Name -contains 'RecommendedDpiValue') {
                               & $asSignedDword $props.RecommendedDpiValue
                           } else { 0 }
            # DpiValue is offset from recommended; target 100% = -recommended.
            $target = -$recommended
            if ($current -ne $target) {
                $label = $mon.PSChildName
                if ($PSCmdlet.ShouldProcess("Monitor $label", "Set DpiValue $current -> $target (100% display scale)")) {
                    Set-ItemProperty -LiteralPath $mon.PSPath -Name 'DpiValue' -Value $target -Type DWord
                    Write-Information "Set display scale to 100% for monitor $label (DpiValue: $current -> $target)."
                    $scaleChanged = $true
                }
            }
        }
    } else {
        Write-Verbose "HKCU:\Control Panel\Desktop\PerMonitorSettings absent; skipping per-monitor DPI override."
    }

    # 7b. System-wide DPI (LogPixels fallback for non-per-monitor-aware
    # apps). Touch only when LogPixels overrides the default (96).
    # Win8DpiScaling=1 is meaningful only alongside a non-96 LogPixels
    # — tells Windows to honor it. Default state (LogPixels=96,
    # Win8DpiScaling=0) is 100%; skip the write to avoid churning
    # the registry on a pristine system.
    $desktopPath = 'HKCU:\Control Panel\Desktop'
    $dp = Get-ItemProperty -LiteralPath $desktopPath -ErrorAction SilentlyContinue
    $currentLogPixels = if ($dp -and ($dp.PSObject.Properties.Name -contains 'LogPixels'))      { & $asSignedDword $dp.LogPixels }      else { 96 }
    $currentWin8      = if ($dp -and ($dp.PSObject.Properties.Name -contains 'Win8DpiScaling')) { & $asSignedDword $dp.Win8DpiScaling } else { 0 }
    if ($currentLogPixels -ne 96) {
        if ($PSCmdlet.ShouldProcess($desktopPath, "Set LogPixels=96, Win8DpiScaling=1 (100% system DPI)")) {
            Set-ItemProperty -LiteralPath $desktopPath -Name 'LogPixels'      -Value 96 -Type DWord
            Set-ItemProperty -LiteralPath $desktopPath -Name 'Win8DpiScaling' -Value 1  -Type DWord
            Write-Information "Set system DPI to 96 (100%) for the current user (LogPixels=$currentLogPixels -> 96, Win8DpiScaling=$currentWin8 -> 1)."
            $scaleChanged = $true
        }
    } else {
        Write-Information "System DPI (LogPixels) is already 96 (100%)."
    }

    # 7c. Windows 11 Accessibility "Text size"
    $accPath = 'HKCU:\Software\Microsoft\Accessibility'
    if (-not (Test-Path -LiteralPath $accPath)) {
        if ($PSCmdlet.ShouldProcess($accPath, 'Create Accessibility key')) {
            $null = New-Item -Path $accPath -Force
        }
    }
    $ap = Get-ItemProperty -LiteralPath $accPath -ErrorAction SilentlyContinue
    $currentTsf = if ($ap -and ($ap.PSObject.Properties.Name -contains 'TextScaleFactor')) { [int]$ap.TextScaleFactor } else { 100 }
    if ($currentTsf -ne 100) {
        if ($PSCmdlet.ShouldProcess($accPath, "Set TextScaleFactor $currentTsf -> 100")) {
            Set-ItemProperty -LiteralPath $accPath -Name 'TextScaleFactor' -Value 100 -Type DWord
            Write-Information "Set accessibility TextScaleFactor to 100 ($currentTsf -> 100)."
            $scaleChanged = $true
        }
    } else {
        Write-Information "Accessibility TextScaleFactor is already 100."
    }

    if ($scaleChanged) {
        Write-Warning "Display/text scale changes take effect on next sign-in."
        Write-Warning "Sign out and back in (or reboot) before running Invoke-TestRunner.ps1 again, or OCR will still see the old scale."
    }
    return $scaleChanged
}

function Set-WindowsHostConditionSet {
    <#
    .SYNOPSIS
    Configures Windows for unattended VM testing: starts Hyper-V service,
    disables display timeout, disables inactivity lock, opens ICMPv4 +
    the status-service TCP port, and -- only when YURUNA_VIRTUAL_DISPLAY is
    set -- resets display/text scale to 100% (so HiDPI up-scaling doesn't
    defeat OCR on VM screenshots). Requires Admin. Idempotent. Scale changes
    take effect on next sign-in.
    .EXAMPLE
    Set-WindowsHostConditionSet          # apply all settings
    Set-WindowsHostConditionSet -WhatIf  # show what would change without applying
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $IsWindows) {
        Write-Warning "Set-WindowsHostConditionSet is only supported on Windows."
        return
    }

    # ── 0. Elevation check ───────────────────────────────────────────────
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]"Administrator")
    if (-not $isAdmin) {
        Write-Error "This script must be run as Administrator. Right-click PowerShell → Run as Administrator."
        return
    }

    $changed = $false

    # ── 1. Hyper-V service ───────────────────────────────────────────────
    $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $svc) {
        # vmms missing has two cases with different fixes:
        #   a) Hyper-V feature never enabled  → enable, reboot.
        #   b) Hyper-V enabled via DISM but reboot pending (DISM reports
        #      State=Enabled after /Enable-Feature /NoRestart even though
        #      components don't deploy until reboot) → just reboot; don't
        #      re-run Enable-WindowsOptionalFeature.
        # Distinguish by asking DISM directly instead of guessing.
        $dismExe = Join-Path $env:WINDIR 'System32\dism.exe'
        $featureState = 'Unknown'
        if (Test-Path -LiteralPath $dismExe) {
            $dismOut = & $dismExe /English /Online /Get-FeatureInfo /FeatureName:Microsoft-Hyper-V-All 2>&1
            if ($LASTEXITCODE -eq 0) {
                foreach ($line in $dismOut) {
                    if ($line -match '^State\s*:\s*(\S+)') { $featureState = $Matches[1]; break }
                }
            }
        }
        if ($featureState -eq 'Enabled') {
            Write-Warning "Hyper-V feature is Enabled but components (vmms) are not deployed yet."
            Write-Warning "  A Windows RESTART is pending. Reboot, then re-run this script."
        } else {
            Write-Warning "Hyper-V service (vmms) is not installed (feature state: $featureState)."
            Write-Warning "  Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All"
            Write-Warning "  Then reboot and re-run this script."
        }
    } elseif ($svc.Status -ne 'Running') {
        if ($PSCmdlet.ShouldProcess("Hyper-V service (vmms)", "Start")) {
            Write-Information "Starting Hyper-V Virtual Machine Management service..."
            Start-Service vmms
            $changed = $true
        }
    } else {
        Write-Information "Hyper-V service (vmms) is already running."
    }

    # ── 2. Display timeout → Never ───────────────────────────────────────
    $acTimeout = powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null |
        Select-String 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)' |
        Select-Object -First 1
    $currentAc = if ($acTimeout) { [Convert]::ToInt32($acTimeout.Matches[0].Groups[1].Value, 16) } else { 0 }

    if ($currentAc -ne 0) {
        $minutes = [math]::Round($currentAc / 60)
        if ($PSCmdlet.ShouldProcess("Display timeout AC (currently $minutes min)", "Set to 0 (Never)")) {
            Write-Information "Setting display timeout to Never (AC and DC)..."
            & powercfg /change monitor-timeout-ac 0
            & powercfg /change monitor-timeout-dc 0
            $changed = $true
        }
    } else {
        Write-Information "Display timeout (AC) is already set to Never."
    }

    # ── 3. Machine inactivity lock → disabled ────────────────────────────
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $lockTimeout = $null
    $regProps = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
    if ($regProps -and $regProps.PSObject.Properties.Name -contains 'InactivityTimeoutSecs') {
        $lockTimeout = $regProps.InactivityTimeoutSecs
    }

    if ($lockTimeout -and $lockTimeout -gt 0) {
        if ($PSCmdlet.ShouldProcess("Inactivity lock timeout (currently ${lockTimeout}s)", "Set to 0 (disabled)")) {
            Write-Information "Disabling machine inactivity lock..."
            Set-ItemProperty -Path $regPath -Name 'InactivityTimeoutSecs' -Value 0
            $changed = $true
        }
    } else {
        Write-Information "Machine inactivity lock is already disabled."
    }

    # ── 4. Lock screen on resume → disabled ──────────────────────────────
    # power-plan consolelock via powercfg
    $consoleLock = powercfg /query SCHEME_CURRENT SUB_NONE CONSOLELOCK 2>$null |
        Select-String 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)' |
        Select-Object -First 1
    $consoleLockVal = if ($consoleLock) { [Convert]::ToInt32($consoleLock.Matches[0].Groups[1].Value, 16) } else { $null }

    if ($consoleLockVal -and $consoleLockVal -ne 0) {
        if ($PSCmdlet.ShouldProcess("Console lock on resume (currently enabled)", "Disable")) {
            Write-Information "Disabling lock screen on resume from sleep..."
            & powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
            & powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_NONE CONSOLELOCK 0
            & powercfg /SETACTIVE SCHEME_CURRENT
            $changed = $true
        }
    } else {
        Write-Information "Lock screen on resume is already disabled (or not applicable)."
    }

    # ── 5. Allow ICMPv4 echo (ping) from VM guests and the LAN ──────────
    # For `ping <host>` to work:
    #   (a) An Allow rule for inbound ICMPv4 Echo Request must exist and
    #       be enabled for every profile whose interface you want ping
    #       on. Windows ships built-in rules
    #       ('File and Printer Sharing (Echo Request - ICMPv4-In)') in
    #       all three profiles (Domain, Private, Public) but DISABLED.
    #   (b) No higher-precedence block rule matches.
    #
    # A custom -InterfaceAlias-scoped rule (e.g. for 'vEthernet (Default
    # Switch)') doesn't make ping work on its own — disabled built-ins
    # coexist with it without being triggered, and Windows Firewall
    # doesn't merge them. The reliable fix is to enable the built-in
    # echo-request rules across all profiles. This opens ping on the
    # LAN NIC too (expected — operators also want to ping the host from
    # peers for diagnostics). No TCP is exposed; ping is just a liveness
    # probe.
    #
    # A custom scoped rule is still created as belt-and-suspenders in
    # case built-ins are missing (stripped server SKUs, GPO, etc.).

    # 5a. Enable built-in Allow + Inbound + ICMPv4 Echo Request rules.
    $icmpAllowRules = Get-NetFirewallRule -Direction Inbound -Action Allow -ErrorAction SilentlyContinue |
        Where-Object {
            $fltr = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $null -ne $fltr -and $fltr.Protocol -eq 'ICMPv4'
        } |
        Where-Object {
            $icmp = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            # IcmpType '8' (echo request) may be listed as '8:*' or similar;
            # match on the leading 8. When it's 'Any', keep it too since
            # 'Any' includes echo request.
            $types = ($icmp.IcmpType -join ',')
            $types -match '(^|,)8(:|\*|,|$)' -or $types -match '(^|,)Any($|,)'
        }
    $enabledAny = $false
    foreach ($rule in $icmpAllowRules) {
        if ($rule.Enabled -ne 'True') {
            if ($PSCmdlet.ShouldProcess("$($rule.DisplayName) [$($rule.Profile)]", 'Enable built-in ICMPv4 Echo Request rule')) {
                Enable-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
                Write-Information "Enabled ICMPv4 echo rule: $($rule.DisplayName) [profile: $($rule.Profile)]"
                $enabledAny = $true
                $changed = $true
            }
        }
    }
    if (-not $enabledAny) {
        Write-Information "ICMPv4 echo-request rules: all matching Allow rules already enabled (count: $($icmpAllowRules.Count))."
    }

    # 5b. Belt-and-suspenders: our own always-on rule, profile Any.
    $icmpRuleName = 'Yuruna: Allow ICMPv4 Echo Request'
    $existingRule = Get-NetFirewallRule -DisplayName $icmpRuleName -ErrorAction SilentlyContinue
    if ($existingRule) {
        if ($existingRule.Enabled -ne 'True') {
            if ($PSCmdlet.ShouldProcess($icmpRuleName, 'Enable existing firewall rule')) {
                Enable-NetFirewallRule -DisplayName $icmpRuleName
                Write-Information "Enabled firewall rule: $icmpRuleName"
                $changed = $true
            }
        } else {
            Write-Information "Firewall rule already present and enabled: $icmpRuleName"
        }
    } else {
        if ($PSCmdlet.ShouldProcess($icmpRuleName, 'Create ICMPv4 echo allow rule (all profiles)')) {
            Write-Information "Creating firewall rule: $icmpRuleName (all profiles)..."
            $null = New-NetFirewallRule `
                -DisplayName $icmpRuleName `
                -Description 'Allow inbound ICMPv4 Echo Request on all profiles so guest VMs and LAN peers can ping the host. Created by Yuruna Enable-TestAutomation (host\windows.hyper-v).' `
                -Direction Inbound `
                -Action Allow `
                -Protocol ICMPv4 `
                -IcmpType 8 `
                -Profile Any
            $changed = $true
        }
    }

    # 5c. Diagnostic: surface any enabled *Block* rule on ICMPv4 Echo that
    # would veto our allow, so the user sees the blocker instead of
    # wondering why ping still fails.
    $icmpBlockRules = Get-NetFirewallRule -Direction Inbound -Action Block -ErrorAction SilentlyContinue |
        Where-Object { $_.Enabled -eq 'True' } |
        Where-Object {
            $fltr = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $null -ne $fltr -and $fltr.Protocol -eq 'ICMPv4'
        }
    if ($icmpBlockRules) {
        Write-Warning "Found enabled ICMPv4 Block rules that may override the Allow rules above:"
        foreach ($r in $icmpBlockRules) {
            Write-Warning "  $($r.DisplayName) [profile: $($r.Profile)]"
        }
        Write-Warning "If ping still fails, disable these or ask your admin — GPO may be pushing them."
    }

    # ── 6. Allow inbound TCP on the status-service port ───────────────────
    # Start-StatusService.ps1 binds HttpListener to http://*:$Port/ which
    # covers every interface at the socket level — but Windows Firewall
    # drops inbound TCP on non-loopback interfaces without an Allow
    # rule. On a fresh install localhost works (loopback is never
    # filtered) while a LAN browser on http://<host-ip>:8080/ hangs.
    # Port is read from test.config.yml (same source as Start-StatusService),
    # default 8080 when missing/unset.
    $statusPort = 8080
    $configPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'test.config.yml'
    if (Test-Path -LiteralPath $configPath) {
        try {
            $cfg = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Yaml -Ordered
            if ($cfg.statusService -and $cfg.statusService.port) { $statusPort = [int]$cfg.statusService.port }
        } catch {
            Write-Verbose "test.config.yml parse failed: $($_.Exception.Message)"
        }
    }

    $statusRuleName = "Yuruna: Allow inbound TCP :$statusPort (Status server)"
    $existingStatusRule = Get-NetFirewallRule -DisplayName $statusRuleName -ErrorAction SilentlyContinue
    if ($existingStatusRule) {
        # Pre-existing rule may have the right name but wrong port (user
        # changed statusService.port in test.config.yml after running
        # this once). Verify + rebuild instead of silently leaving it.
        $portFilter = $existingStatusRule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        $rulePortMatches = $portFilter -and ($portFilter.Protocol -eq 'TCP') -and ($portFilter.LocalPort -eq "$statusPort")
        if (-not $rulePortMatches) {
            if ($PSCmdlet.ShouldProcess($statusRuleName, "Recreate with port $statusPort")) {
                Write-Information "Rebuilding firewall rule for status server on port $statusPort..."
                Remove-NetFirewallRule -DisplayName $statusRuleName -ErrorAction SilentlyContinue
                $null = New-NetFirewallRule `
                    -DisplayName $statusRuleName `
                    -Description "Allow inbound TCP on the yuruna status-service port so LAN clients can reach http://<host>:$statusPort/status/. Created by Yuruna Enable-TestAutomation (test/modules/Test.HostContract.psm1)." `
                    -Direction Inbound `
                    -Action Allow `
                    -Protocol TCP `
                    -LocalPort $statusPort `
                    -Profile Any
                $changed = $true
            }
        } elseif ($existingStatusRule.Enabled -ne 'True') {
            if ($PSCmdlet.ShouldProcess($statusRuleName, 'Enable existing firewall rule')) {
                Enable-NetFirewallRule -DisplayName $statusRuleName
                Write-Information "Enabled firewall rule: $statusRuleName"
                $changed = $true
            }
        } else {
            Write-Information "Firewall rule already present and enabled: $statusRuleName"
        }
    } else {
        if ($PSCmdlet.ShouldProcess($statusRuleName, "Create TCP :$statusPort inbound allow rule (all profiles)")) {
            Write-Information "Creating firewall rule: $statusRuleName (all profiles)..."
            $null = New-NetFirewallRule `
                -DisplayName $statusRuleName `
                -Description "Allow inbound TCP on the yuruna status-service port so LAN clients can reach http://<host>:$statusPort/status/. Created by Yuruna Enable-TestAutomation (test/modules/Test.HostContract.psm1)." `
                -Direction Inbound `
                -Action Allow `
                -Protocol TCP `
                -LocalPort $statusPort `
                -Profile Any
            $changed = $true
        }
    }

    # 6b. Diagnostic: any enabled TCP Block rule covering this port
    # vetoes the Allow above — surface it instead of leaving the user
    # wondering why LAN clients can't connect.
    $tcpBlockRules = Get-NetFirewallRule -Direction Inbound -Action Block -ErrorAction SilentlyContinue |
        Where-Object { $_.Enabled -eq 'True' } |
        Where-Object {
            $f = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $null -ne $f -and $f.Protocol -eq 'TCP' -and (
                $f.LocalPort -eq "$statusPort" -or $f.LocalPort -eq 'Any'
            )
        }
    if ($tcpBlockRules) {
        Write-Warning "Found enabled TCP Block rules that may override the status-service Allow rule:"
        foreach ($r in $tcpBlockRules) {
            Write-Warning "  $($r.DisplayName) [profile: $($r.Profile)]"
        }
        Write-Warning "If remote clients still get 'connection timed out' on port $statusPort, disable these or ask your admin — GPO may be pushing them."
    }

    # Display/text scale = 100% (HKCU per-monitor DPI, system DPI, Win11
    # TextScaleFactor) is the persisted backstop for the opt-in virtual
    # display's live CCD scale enforcement (Set-YurunaDisplayCloneAndResolution).
    # Apply it only when YURUNA_VIRTUAL_DISPLAY is truthy, so with the feature
    # off the host's scaling is left untouched -- matching the same gate in
    # Install-YurunaVirtualDisplay. See docs/host-hyperv.md.
    if (Test-YurunaVirtualDisplayEnabled) {
        if (Set-YurunaDisplayScale100) { $changed = $true }
    } else {
        Write-Verbose "Display/text scale enforcement skipped (YURUNA_VIRTUAL_DISPLAY not set to true)."
    }

    # The opt-in virtual display is NOT attached here. When set,
    # YURUNA_VIRTUAL_DISPLAY makes it a per-cycle surface (a KVM switch can
    # drop the physical monitor mid-run, so the monitor census must be
    # re-evaluated every cycle, not once at enable time): Initialize-HostDisplay
    # invokes Install-YurunaVirtualDisplay at the start of each cycle, and
    # Remove-HostDisplay tears it down during Remove-TestVMFiles. See
    # docs/host-hyperv.md.

    if ($changed) {
        Write-Information ""
        Write-Information "Settings updated. Re-run Assert-HostConditionSet to verify:"
        Write-Information "  Assert-HostConditionSet -HostType 'host.windows.hyper-v'"
    }
}

function Assert-WindowsHostConditionSet {
    <#
    .SYNOPSIS
    Single gate for Windows prerequisites: Administrator elevation and
    Hyper-V service. Returns $true on non-Windows or when all pass;
    $false with diagnostics on failure.
    #>
    param([string]$HostType)
    if ($HostType -ne "host.windows.hyper-v") { return $true }

    # 1. Administrator elevation
    if (-not (Assert-Elevation -HostType $HostType)) { return $false }

    # 2. Hyper-V management service must be running
    $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne 'Running') {
        Write-Warning "═══════════════════════════════════════════════════════════════════"
        Write-Warning " Hyper-V Virtual Machine Management service (vmms) is not running."
        Write-Warning ""
        Write-Warning " Quick fix — run from an elevated PowerShell at the repo root:"
        Write-Warning "   pwsh .\host\windows.hyper-v\Enable-TestAutomation.ps1"
        Write-Warning ""
        Write-Warning " If Hyper-V is not installed, enable it first:"
        Write-Warning "   Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All"
        Write-Warning " then reboot."
        Write-Warning "═══════════════════════════════════════════════════════════════════"
        return $false
    }

    # 3. Screen lock / display timeout — warn if display will turn off
    try {
        $acTimeout = (powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null |
            Select-String 'Current AC Power Setting Index:\s+0x([0-9a-fA-F]+)' |
            Select-Object -First 1)
        if ($acTimeout) {
            $seconds = [Convert]::ToInt32($acTimeout.Matches[0].Groups[1].Value, 16)
            if ($seconds -ne 0) {
                $minutes = [math]::Round($seconds / 60)
                Write-Warning "═══════════════════════════════════════════════════════════════════"
                Write-Warning " Display timeout is set to $minutes minute(s) on AC power."
                Write-Warning " The screen will blank during long test runs, which may cause"
                Write-Warning " Hyper-V Enhanced Session screen captures to fail."
                Write-Warning ""
                Write-Warning " Quick fix — run from an elevated PowerShell at the repo root:"
                Write-Warning "   pwsh .\host\windows.hyper-v\Enable-TestAutomation.ps1"
                Write-Warning "═══════════════════════════════════════════════════════════════════"
                return $false
            }
        }
    } catch {
        Write-Debug "Display timeout check failed: $_"
    }

    # 4. Lock screen timeout — warn if machine will lock
    try {
        $lockTimeout = $null
        $regProps = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction SilentlyContinue
        if ($regProps -and $regProps.PSObject.Properties.Name -contains 'InactivityTimeoutSecs') {
            $lockTimeout = $regProps.InactivityTimeoutSecs
        }
        if ($lockTimeout -and $lockTimeout -gt 0) {
            Write-Warning "═══════════════════════════════════════════════════════════════════"
            Write-Warning " Machine inactivity lock is set to $lockTimeout second(s)."
            Write-Warning " The lock screen will activate during long test runs."
            Write-Warning ""
            Write-Warning " Quick fix — run from an elevated PowerShell at the repo root:"
            Write-Warning "   pwsh .\host\windows.hyper-v\Enable-TestAutomation.ps1"
            Write-Warning "═══════════════════════════════════════════════════════════════════"
            return $false
        }
    } catch {
        Write-Debug "Lock screen timeout check failed: $_"
    }

    return $true
}

function Test-WindowsHostMinimum {
    <#
    .SYNOPSIS
        Hyper-V quick-check for [Test-HostRequirement] (Administrator
        elevation + vmms service). Emits actionable warnings on failure
        and returns $false; emits nothing and returns $true when both
        conditions are met.
    .DESCRIPTION
        Lighter than Assert-WindowsHostConditionSet (which also gates
        on display timeout / lock screen) -- this exists for one-off
        operator helpers (Remove-TestVMFiles.ps1 etc.) where the
        screen-lock check would be a false positive during interactive
        maintenance.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $ok = $true
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]'Administrator')
    if (-not $isAdmin) {
        Write-Warning "host.windows.hyper-v requires Administrator. Re-run this script from an elevated PowerShell -- without elevation, Hyper-V cmdlets (Get-VM/Stop-VM/Remove-VM) fail with 'You do not have the required permission...' before any friendlier check can run."
        $ok = $false
    }
    $svc = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Warning "Hyper-V Virtual Machine Management service (vmms) is not installed. Enable Hyper-V from an elevated PowerShell: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All  (then reboot)."
        $ok = $false
    } elseif ($svc.Status -ne 'Running') {
        Write-Warning "Hyper-V Virtual Machine Management service (vmms) is not running. Start it from an elevated PowerShell: Start-Service vmms"
        $ok = $false
    }
    return $ok
}

Export-ModuleMember -Function Set-WindowsHostConditionSet, Assert-WindowsHostConditionSet, Test-WindowsHostMinimum, Install-YurunaVirtualDisplay, Remove-YurunaVirtualDisplay, Set-YurunaDisplayCloneAndResolution, Set-YurunaDisplayScale100, Test-YurunaVirtualDisplayEnabled
