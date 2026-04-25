<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456714
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

#requires -version 7

# ── Screenshot capture ───────────────────────────────────────────────────────

<#
.SYNOPSIS
    Captures a screenshot of a VM window.
.DESCRIPTION
    UTM:     uses screencapture (macOS) targeting the UTM window.
    Hyper-V: uses Get-VMVideo / vmconnect bitmap capture.
    Returns the path to the saved PNG, or $null on failure.
#>
function Get-VMScreenshot {
    param(
        [string]$HostType,
        [string]$VMName,
        [string]$OutputPath
    )
    $dir = Split-Path -Parent $OutputPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    switch ($HostType) {
        "host.macos.utm" {
            return Get-UtmScreenshot -VMName $VMName -OutputPath $OutputPath
        }
        "host.windows.hyper-v" {
            return Get-HyperVScreenshot -VMName $VMName -OutputPath $OutputPath
        }
        default {
            Write-Error "Unknown host type for screenshot: $HostType"
            return $null
        }
    }
}

# ── VNC framebuffer capture ─────────────────────────────────────────────────
# QEMU-backed UTM VMs expose a loopback VNC server (`-vnc 127.0.0.1:N` in
# AdditionalArguments, where N is the per-VM display number from
# Get-VncDisplayForVm). Reading the framebuffer directly bypasses UTM's
# NSWindow entirely — the harness gets the VM's real screen regardless of
# whether UTM's window is focused, visible, occluded, or (because `-vnc`
# steals the spice-app display path) stuck on black. This is the macOS
# equivalent of Hyper-V's synthetic video channel: the VM's framebuffer
# lives in a server-owned buffer the viewer pulls from, not in an
# on-screen window the OS has to keep rendered.
#
# Only attempted on host.macos.utm. Caller falls back to `screencapture -l`
# / `-R` when VNC is unavailable (Apple VZ guests without a VNC server
# configured).

# Per-VM VNC display number. Hardcoding display 0 / port 5900 on every VM
# meant the capture path silently grabbed whichever QEMU bound 5900 first
# (e.g. a stale ubuntu-desktop guest's "Display output is not active."
# placeholder while the test was actually targeting an AVF ubuntu-server
# guest). Hashing the VM name into a unique display per VM keeps every
# QEMU-backed UTM VM on its own port, so the capture path connects to the
# right one. New-VM.ps1 substitutes the same value into the .utm bundle's
# AdditionalArguments so the producer and consumer agree.
function Get-VncDisplayForVm {
    <#
    .SYNOPSIS
        Maps a VM name to a deterministic QEMU VNC display number.
    .DESCRIPTION
        Returns an integer in 10..89 (corresponding to TCP ports 5910..5989).
        Both the producer (config.plist.template via New-VM.ps1) and the
        consumers (Get-UtmScreenshot, Connect-VNC) call this helper so they
        agree on which port a given VM serves on, with no sidecar file to
        keep in sync.
    .PARAMETER VMName
        The UTM VM's display name (matches the .utm bundle name and the
        kCGWindowName the harness searches for).
    .OUTPUTS
        [int] display number in 10..89.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    # Displays 0..9 are reserved for legacy/default callers so a pre-fix VM
    # still bound to port 5900 won't collide with a per-VM port computed for
    # a different VM. The 80-slot space is more than enough — the harness
    # runs a handful of VMs at once.
    $h = 0
    foreach ($ch in $VMName.ToCharArray()) {
        $h = (($h * 131) + [int][char]$ch) -band 0x3FFFFFFF
    }
    return ($h % 80) + 10
}

function Get-VncPortForVm {
    <#
    .SYNOPSIS
        Returns the TCP port a VM's QEMU VNC server should bind to.
    .DESCRIPTION
        Thin wrapper over Get-VncDisplayForVm: TCP port = 5900 + display
        number. Producers and consumers of the VNC framebuffer/keystroke
        path call this so the port is derived from the VM name in one place.
    .PARAMETER VMName
        The UTM VM's display name.
    .OUTPUTS
        [int] TCP port in 5910..5989.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][string]$VMName)
    return 5900 + (Get-VncDisplayForVm -VMName $VMName)
}

# C# helper for the hot byte-swap loop. A pure-PowerShell loop over a
# 1920x1080 pixel buffer (2M iterations) takes multiple seconds; the
# compiled version is tens of milliseconds. Idempotent Add-Type via
# type-presence check so module re-import doesn't throw.
if (-not ('YurunaVncPixels' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
public static class YurunaVncPixels {
    // Convert QEMU's 32-bit little-endian BGRX framebuffer to P6 PPM
    // body bytes (R,G,B,R,G,B...). Writes directly into `dst` starting
    // at `dstOffset`. `src.Length` must be a multiple of 4.
    public static void BgrxToRgb(byte[] src, byte[] dst, int dstOffset) {
        int n = src.Length / 4;
        for (int i = 0; i < n; i++) {
            int s = i * 4;
            int d = dstOffset + i * 3;
            dst[d]     = src[s + 2]; // R
            dst[d + 1] = src[s + 1]; // G
            dst[d + 2] = src[s];     // B
        }
    }
}
'@
}

function Read-VncScreenshotBuffer {
    param([System.IO.Stream]$Stream, [int]$Count)
    $buf = [byte[]]::new($Count)
    $offset = 0
    while ($offset -lt $Count) {
        $n = $Stream.Read($buf, $offset, $Count - $offset)
        if ($n -eq 0) { throw "VNC connection closed after $offset/$Count bytes" }
        $offset += $n
    }
    return $buf
}

function Get-VncScreenshot {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$OutputPath,
        [int]$Port = 5900,
        [int]$TimeoutMs = 5000
    )

    $tcp = $null
    $ppmPath = $null
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $tcp.ReceiveTimeout = $TimeoutMs
        $tcp.SendTimeout    = $TimeoutMs
        $tcp.Connect('127.0.0.1', $Port)
        $stream = $tcp.GetStream()

        # RFB 3.8 handshake
        $null = Read-VncScreenshotBuffer -Stream $stream -Count 12     # server version
        $stream.Write([System.Text.Encoding]::ASCII.GetBytes("RFB 003.008`n"), 0, 12)
        $countBuf = Read-VncScreenshotBuffer -Stream $stream -Count 1
        $numTypes = [int]$countBuf[0]
        if ($numTypes -eq 0) { throw 'VNC server refused (0 security types offered)' }
        $typesBuf = Read-VncScreenshotBuffer -Stream $stream -Count $numTypes
        if ($typesBuf -notcontains 1) { throw "VNC server does not offer None-auth (got: $($typesBuf -join ','))" }
        $stream.WriteByte(1)
        $secResult = Read-VncScreenshotBuffer -Stream $stream -Count 4
        if ($secResult[0] -ne 0 -or $secResult[1] -ne 0 -or $secResult[2] -ne 0 -or $secResult[3] -ne 0) {
            throw "VNC security handshake failed"
        }
        # ClientInit: shared=1 (coexist with the keystroke connection from Invoke-Sequence.psm1)
        $stream.WriteByte(1)

        # ServerInit: width, height, pixel format, name length (24 bytes) + name
        # PowerShell's `-shl` on a [byte] keeps the result as a byte, so
        # shifting 8 bits truncates to zero. Cast to [int] first — or use
        # BitConverter, which reads a multi-byte integer natively. The RFB
        # wire format is big-endian; BitConverter is host-endian, so we
        # reverse before decoding.
        $initBuf = Read-VncScreenshotBuffer -Stream $stream -Count 24
        $wBytes = @($initBuf[1], $initBuf[0])
        $hBytes = @($initBuf[3], $initBuf[2])
        $nlBytes = @($initBuf[23], $initBuf[22], $initBuf[21], $initBuf[20])
        $w = [int][BitConverter]::ToUInt16([byte[]]$wBytes, 0)
        $h = [int][BitConverter]::ToUInt16([byte[]]$hBytes, 0)
        $nameLen = [int][BitConverter]::ToInt32([byte[]]$nlBytes, 0)
        $bpp = [int]$initBuf[4]
        $bigEndian = [int]$initBuf[6]
        if ($nameLen -gt 0) { $null = Read-VncScreenshotBuffer -Stream $stream -Count $nameLen }
        if ($bpp -ne 32)    { throw "Unsupported bpp=$bpp (this capture path assumes 32bpp BGRX)" }
        if ($bigEndian -ne 0) { throw "Unsupported big-endian framebuffer (this path assumes little-endian BGRX)" }

        # FramebufferUpdateRequest: non-incremental, full screen
        $req = [byte[]]::new(10)
        $req[0] = 3
        $req[1] = 0
        $req[6] = [byte](($w -shr 8) -band 0xFF); $req[7] = [byte]($w -band 0xFF)
        $req[8] = [byte](($h -shr 8) -band 0xFF); $req[9] = [byte]($h -band 0xFF)
        $stream.Write($req, 0, 10)

        # Read FramebufferUpdate header. Same big-endian-over-byte trap as
        # ServerInit — use BitConverter after swap.
        $updHdr = Read-VncScreenshotBuffer -Stream $stream -Count 4
        if ($updHdr[0] -ne 0) { throw "Expected FramebufferUpdate (0), got message type $($updHdr[0])" }
        $nRects = [int][BitConverter]::ToUInt16([byte[]]@($updHdr[3], $updHdr[2]), 0)

        # Accumulate pixels across rects into a full-frame buffer. QEMU's
        # VNC server typically returns one Raw rect covering the whole
        # screen for a non-incremental request, but honor the general case.
        $fbBytes = $w * $h * 4
        $fb = [byte[]]::new($fbBytes)
        for ($r = 0; $r -lt $nRects; $r++) {
            $rectHdr = Read-VncScreenshotBuffer -Stream $stream -Count 12
            $rx = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[1],  $rectHdr[0]),  0)
            $ry = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[3],  $rectHdr[2]),  0)
            $rw = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[5],  $rectHdr[4]),  0)
            $rh = [int][BitConverter]::ToUInt16([byte[]]@($rectHdr[7],  $rectHdr[6]),  0)
            $enc = [BitConverter]::ToInt32([byte[]]@($rectHdr[11], $rectHdr[10], $rectHdr[9], $rectHdr[8]), 0)
            if ($enc -ne 0) { throw "Unsupported VNC encoding $enc for rect $r (need Raw=0)" }
            $rectBytes = $rw * $rh * 4
            $pixels = Read-VncScreenshotBuffer -Stream $stream -Count $rectBytes
            # Blit row-by-row into the full-frame buffer
            for ($row = 0; $row -lt $rh; $row++) {
                $srcOff = $row * $rw * 4
                $dstOff = (($ry + $row) * $w + $rx) * 4
                [Array]::Copy($pixels, $srcOff, $fb, $dstOff, $rw * 4)
            }
        }

        # Build P6 PPM in memory, then hand off to `sips` for PNG conversion.
        # sips ships on macOS by default — no extra dependency.
        $headerBytes = [System.Text.Encoding]::ASCII.GetBytes("P6`n$w $h`n255`n")
        $ppm = [byte[]]::new($headerBytes.Length + $w * $h * 3)
        [Array]::Copy($headerBytes, 0, $ppm, 0, $headerBytes.Length)
        [YurunaVncPixels]::BgrxToRgb($fb, $ppm, $headerBytes.Length)
        $ppmPath = "$OutputPath.ppm"
        [System.IO.File]::WriteAllBytes($ppmPath, $ppm)

        $sipsErr = & sips -s format png $ppmPath --out $OutputPath 2>&1
        if (-not (Test-Path $OutputPath)) {
            Write-Debug "      VNC capture: sips conversion failed: $sipsErr"
            return $false
        }
        return $true
    } catch {
        Write-Debug "      VNC capture failed: $_"
        return $false
    } finally {
        if ($tcp) { try { $tcp.Close() } catch { Write-Debug "      VNC capture: tcp.Close() failed: $_" } }
        if ($ppmPath -and (Test-Path $ppmPath)) {
            Remove-Item -LiteralPath $ppmPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-UtmScreenshot {
    param([string]$VMName, [string]$OutputPath)

    # Attempt VNC framebuffer capture first. When the QEMU backend is in
    # use with `-vnc 127.0.0.1:N`, this is the ONLY path that returns real
    # pixels — UTM's NSWindow stays black because the vnc arg steals the
    # spice-app display output, so screencapture on that window would
    # return a uniformly black PNG and every OCR step would time out.
    # The per-VM port (5910..5989) keeps concurrent QEMU UTM VMs from
    # poaching each other's framebuffer. When VNC is not reachable (Apple VZ
    # guests, no QEMU bound to that port), we fall through to the
    # screencapture-based paths below.
    $vncPort = Get-VncPortForVm -VMName $VMName
    if (Get-VncScreenshot -OutputPath $OutputPath -Port $vncPort) {
        Write-Debug "      Captured via VNC (port $vncPort, VM $VMName)"
        Write-Output "Screenshot saved: $OutputPath"
        return $OutputPath
    }

    # One-time check: verify screencapture works at all (Screen Recording permission).
    if (-not $script:ScreencaptureChecked) {
        $script:ScreencaptureChecked = $true
        $testFile = Join-Path ([System.IO.Path]::GetTempPath()) "screencapture_test_$PID.png"
        $testErr = & screencapture -x "$testFile" 2>&1
        if (Test-Path $testFile) {
            $fileSize = (Get-Item $testFile).Length
            Remove-Item $testFile -Force -ErrorAction SilentlyContinue
            if ($fileSize -lt 100) {
                Write-Warning "screencapture produces empty files. Grant Screen Recording permission to your terminal:"
                Write-Warning "  System Settings > Privacy & Security > Screen Recording > enable your terminal app"
                Write-Warning "  Then restart the terminal."
                $script:ScreencaptureWorks = $false
            } else {
                $script:ScreencaptureWorks = $true
            }
        } else {
            Write-Warning "screencapture failed: $testErr"
            Write-Warning "Grant Screen Recording permission to your terminal:"
            Write-Warning "  System Settings > Privacy & Security > Screen Recording > enable your terminal app"
            Write-Warning "  Then restart the terminal."
            $script:ScreencaptureWorks = $false
        }
    }
    if ($script:ScreencaptureWorks -eq $false) { return $null }

    # Strategy: use CGWindowListCopyWindowInfo to find the VM window's
    # Core Graphics window ID by matching the window name. Then capture
    # with screencapture -l <windowID>, which captures ONLY that window
    # even if it is partially or fully obscured by other windows.
    # This avoids false OCR matches from terminal output or other apps.
    # kCGWindowListOptionAll (not OnScreenOnly) so the lookup still finds
    # UTM windows when the operator has switched to a different macOS Space
    # (e.g. to debug in VS Code). screencapture -l <id> works against the
    # window server regardless of which Space the window lives on.
    $safeVMName = $VMName -replace '\\', '\\\\' -replace "'", "\\'"
    $windowIdScript = @"
ObjC.import('CoreGraphics');
ObjC.import('CoreFoundation');
var winList = ObjC.unwrap(
    $.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, 0));
var vmName = '__VMNAME__';
var result = 'not_found';
for (var i = 0; i < winList.length; i++) {
    var w = winList[i];
    var owner = ObjC.unwrap(w.kCGWindowOwnerName) || '';
    var name  = ObjC.unwrap(w.kCGWindowName)      || '';
    if (owner.indexOf('UTM') >= 0 && name.indexOf(vmName) >= 0) {
        result = '' + ObjC.unwrap(w.kCGWindowNumber);
        break;
    }
}
result;
"@
    $windowIdScript = $windowIdScript -replace '__VMNAME__', $safeVMName
    $windowIdResult = & osascript -l JavaScript -e $windowIdScript 2>&1
    Write-Debug "      CG window ID query: $windowIdResult"
    $captured = $false

    # Method 1: screencapture -l <windowID> — captures only the VM window
    if ($LASTEXITCODE -eq 0 -and "$windowIdResult" -match '^\d+$') {
        $captureErr = & screencapture -x -o -l "$windowIdResult" "$OutputPath" 2>&1
        if (Test-Path $OutputPath) {
            $fileSize = (Get-Item $OutputPath).Length
            if ($fileSize -gt 100) {
                $captured = $true
            } else {
                Write-Debug "      screencapture -l produced small file ($fileSize bytes), trying -R fallback"
                Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
            }
        } else {
            Write-Debug "      screencapture -l failed: $captureErr"
        }
    }

    # Method 2: fall back to -R with window bounds from System Events
    if (-not $captured) {
        $safeVMNameAS = $VMName -replace '\\', '\\\\' -replace '"', '\\"'
        $boundsScript = @"
tell application "System Events"
    tell process "UTM"
        repeat with w in windows
            if name of w contains "$safeVMNameAS" then
                try
                    set contentArea to first group of w
                    set {cx, cy} to position of contentArea
                    set {cw, ch} to size of contentArea
                    return ("" & cx & "," & cy & "," & cw & "," & ch)
                end try
                set {wx, wy} to position of w
                set {ww, wh} to size of w
                set titleBarH to 28
                return ("" & wx & "," & (wy + titleBarH) & "," & ww & "," & (wh - titleBarH))
            end if
        end repeat
    end tell
    return "not_found"
end tell
"@
        $boundsResult = & osascript -e $boundsScript 2>&1
        Write-Debug "      Window bounds query: $boundsResult"

        if ($LASTEXITCODE -eq 0 -and "$boundsResult" -match '^\d+,\d+,\d+,\d+$') {
            $captureErr = & screencapture -x -R "$boundsResult" "$OutputPath" 2>&1
            if (Test-Path $OutputPath) {
                $captured = $true
                Write-Debug "      Captured via -R (window may include overlapping content)"
            } else {
                Write-Warning "screencapture -R '$boundsResult' failed: $captureErr"
            }
        } else {
            Write-Warning "UTM window for '$VMName' not found. CG: $windowIdResult, bounds: $boundsResult"
        }
    }

    if ($captured) {
        Write-Output "Screenshot saved: $OutputPath"
        return $OutputPath
    }
    Write-Error "Screenshot capture failed for '$VMName'"
    return $null
}

function Get-HyperVScreenshot {
    param([string]$VMName, [string]$OutputPath)

    # ── Load C# type (once per session) ────────────────────────────────────
    try {
        if (-not ('HyperVCapture' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public class HyperVCapture {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
    [DllImport("gdi32.dll")]  public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")]  public static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);
    [DllImport("gdi32.dll")]  public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")]  public static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")]  public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")]  public static extern int GetDIBits(IntPtr hdc, IntPtr hbmp, uint start, uint lines, byte[] bits, ref BITMAPINFO bi, uint usage);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hdc);
    static bool dpiAware = false;
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct BITMAPINFOHEADER {
        public uint biSize; public int biWidth; public int biHeight; public ushort biPlanes;
        public ushort biBitCount; public uint biCompression; public uint biSizeImage;
        public int biXPelsPerMeter; public int biYPelsPerMeter; public uint biClrUsed; public uint biClrImportant;
    }
    [StructLayout(LayoutKind.Sequential)] public struct BITMAPINFO { public BITMAPINFOHEADER bmiHeader; }

    public static IntPtr FindWindow(string titleContains) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hWnd, lp) => {
            if (!IsWindowVisible(hWnd)) return true;
            var sb = new StringBuilder(256);
            GetWindowText(hWnd, sb, 256);
            if (sb.ToString().Contains(titleContains)) { found = hWnd; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    const uint PW_CLIENT_RENDER = 3; // PW_CLIENTONLY | PW_RENDERFULLCONTENT

    // Ensure DPI awareness so GetClientRect returns physical pixels.
    // Without this, on displays with >100% scale, GetClientRect returns
    // logical pixels that are smaller than the actual rendered size,
    // causing PrintWindow to capture a truncated image.
    public static void EnsureDpiAware() {
        if (!dpiAware) { SetProcessDPIAware(); dpiAware = true; }
    }

    // Get the client area size in physical pixels, accounting for DPI.
    // After SetProcessDPIAware, GetClientRect already returns physical pixels,
    // but as a safety net we also check GetDpiForWindow.
    static bool GetClientSize(IntPtr hWnd, out int w, out int h) {
        EnsureDpiAware();
        RECT r; GetClientRect(hWnd, out r);
        w = r.Right; h = r.Bottom;
        return w > 0 && h > 0;
    }

    // Open a file for writing, retrying briefly on transient sharing
    // violations. Seen after pause/resume of a sequence: antivirus, Windows
    // Explorer's thumbnail previewer, or an operator viewing the PNG while
    // paused can hold the path open long enough that the next
    // FileMode.Create hits ERROR_SHARING_VIOLATION. Five attempts x 200ms =
    // ~1s of tolerance; if the lock persists past that, rethrow so the PS
    // caller's try/catch writes the warning and waitForText retries on the
    // next poll interval.
    static FileStream OpenWriteWithRetry(string path) {
        IOException last = null;
        for (int attempt = 0; attempt < 5; attempt++) {
            try {
                return new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
            } catch (IOException ex) {
                last = ex;
                if (attempt < 4) System.Threading.Thread.Sleep(200);
            }
        }
        throw last;
    }

    public static bool CaptureToFile(IntPtr hWnd, string path) {
        int w, h;
        if (!GetClientSize(hWnd, out w, out h)) return false;
        IntPtr screenDC = GetDC(IntPtr.Zero);
        IntPtr memDC = CreateCompatibleDC(screenDC);
        IntPtr hBmp = CreateCompatibleBitmap(screenDC, w, h);
        IntPtr old = SelectObject(memDC, hBmp);
        PrintWindow(hWnd, memDC, PW_CLIENT_RENDER);
        // Get pixel data as BGRA
        var bi = new BITMAPINFO();
        bi.bmiHeader.biSize = 40; bi.bmiHeader.biWidth = w; bi.bmiHeader.biHeight = -h;
        bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 32;
        byte[] pixels = new byte[w * h * 4];
        GetDIBits(memDC, hBmp, 0, (uint)h, pixels, ref bi, 0);
        SelectObject(memDC, old); DeleteObject(hBmp); DeleteDC(memDC); ReleaseDC(IntPtr.Zero, screenDC);
        // Write minimal PNG (uncompressed via zlib stored blocks)
        using (var fs = OpenWriteWithRetry(path)) {
            WritePng(fs, w, h, pixels);
        }
        return true;
    }

    // Capture only the bottom portion of the window (bottomFraction: 0.0-1.0).
    // Reuses the same PrintWindow capture but writes only the bottom rows to PNG.
    public static bool CaptureBottomToFile(IntPtr hWnd, string path, double bottomFraction) {
        int w, h;
        if (!GetClientSize(hWnd, out w, out h)) return false;
        IntPtr screenDC = GetDC(IntPtr.Zero);
        IntPtr memDC = CreateCompatibleDC(screenDC);
        IntPtr hBmp = CreateCompatibleBitmap(screenDC, w, h);
        IntPtr old = SelectObject(memDC, hBmp);
        PrintWindow(hWnd, memDC, PW_CLIENT_RENDER);
        var bi = new BITMAPINFO();
        bi.bmiHeader.biSize = 40; bi.bmiHeader.biWidth = w; bi.bmiHeader.biHeight = -h;
        bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 32;
        byte[] pixels = new byte[w * h * 4];
        GetDIBits(memDC, hBmp, 0, (uint)h, pixels, ref bi, 0);
        SelectObject(memDC, old); DeleteObject(hBmp); DeleteDC(memDC); ReleaseDC(IntPtr.Zero, screenDC);
        // Crop to bottom portion
        int cropH = Math.Max(150, (int)(h * bottomFraction));
        if (cropH > h) cropH = h;
        int startRow = h - cropH;
        byte[] cropPixels = new byte[w * cropH * 4];
        Array.Copy(pixels, startRow * w * 4, cropPixels, 0, cropPixels.Length);
        using (var fs = OpenWriteWithRetry(path)) {
            WritePng(fs, w, cropH, cropPixels);
        }
        return true;
    }

    // Capture the bottom N text lines from the window as a single PNG.
    // Scans pixel rows from the bottom upward to detect text-line boundaries
    // using row brightness analysis, then exports the region containing those
    // lines. Returns true if a non-empty region was found and saved.
    //
    // Algorithm:
    // 1. Determine the background color from the majority of pixels in the
    //    bottom-right corner (terminal background).
    // 2. Scan rows from bottom up. A row is "text" if >2% of pixels differ
    //    from the background. A "gap" row is all-background.
    // 3. Group consecutive text rows into lines, separated by gap rows.
    // 4. Take the bottom N lines (plus 2px padding) and write to PNG.
    public static bool CaptureBottomLinesFromPixels(byte[] pixels, int w, int h, string path, int lineCount) {
        if (pixels == null || w <= 0 || h <= 0) return false;

        // Step 1: detect background color from a 20x20 sample in bottom-right.
        // On a terminal the background fills most of the screen.
        int sampleSize = 20;
        int sr = Math.Max(0, h - sampleSize), sc = Math.Max(0, w - sampleSize);
        long bgR = 0, bgG = 0, bgB = 0; int bgCount = 0;
        for (int y = sr; y < h; y++) {
            for (int x = sc; x < w; x++) {
                int p = (y * w + x) * 4;
                bgB += pixels[p]; bgG += pixels[p+1]; bgR += pixels[p+2];
                bgCount++;
            }
        }
        int bgRi = (int)(bgR / bgCount), bgGi = (int)(bgG / bgCount), bgBi = (int)(bgB / bgCount);

        // Step 2: classify each row as text or gap, scanning from bottom up.
        // A row is "text" if more than 2% of pixels differ significantly from bg.
        int threshold = 30; // per-channel difference threshold
        double minTextFraction = 0.02;
        bool[] isTextRow = new bool[h];
        for (int y = h - 1; y >= 0; y--) {
            int diffCount = 0;
            int rowOff = y * w * 4;
            for (int x = 0; x < w; x++) {
                int p = rowOff + x * 4;
                int dr = Math.Abs(pixels[p+2] - bgRi);
                int dg = Math.Abs(pixels[p+1] - bgGi);
                int db = Math.Abs(pixels[p] - bgBi);
                if (dr > threshold || dg > threshold || db > threshold) diffCount++;
            }
            isTextRow[y] = ((double)diffCount / w) >= minTextFraction;
        }

        // Step 3: from the bottom, group consecutive text rows into lines.
        // Lines are separated by one or more gap (non-text) rows.
        // We collect line boundaries as (topRow, bottomRow) pairs.
        var lines = new System.Collections.Generic.List<int[]>(); // each: [topRow, bottomRow]
        int row = h - 1;
        // Skip trailing gap rows (empty space at very bottom)
        while (row >= 0 && !isTextRow[row]) row--;
        while (row >= 0 && lines.Count < lineCount) {
            // We're on a text row — find the top of this text line
            int lineBottom = row;
            while (row >= 0 && isTextRow[row]) row--;
            int lineTop = row + 1;
            lines.Add(new int[] { lineTop, lineBottom });
            // Skip gap rows between lines
            while (row >= 0 && !isTextRow[row]) row--;
        }

        if (lines.Count == 0) return false;

        // The region spans from the topmost line's top to the bottommost line's bottom
        int regionTop = lines[lines.Count - 1][0]; // last added = topmost
        int regionBottom = lines[0][1];             // first added = bottommost
        // Add 2px padding
        regionTop = Math.Max(0, regionTop - 2);
        regionBottom = Math.Min(h - 1, regionBottom + 2);
        int regionH = regionBottom - regionTop + 1;

        byte[] cropPixels = new byte[w * regionH * 4];
        Array.Copy(pixels, regionTop * w * 4, cropPixels, 0, cropPixels.Length);
        using (var fs = OpenWriteWithRetry(path)) {
            WritePng(fs, w, regionH, cropPixels);
        }
        return true;
    }

    // Convenience: capture window and extract bottom N lines in one call.
    public static bool CaptureBottomLinesToFile(IntPtr hWnd, string path, int lineCount) {
        int w, h;
        if (!GetClientSize(hWnd, out w, out h)) return false;
        IntPtr screenDC = GetDC(IntPtr.Zero);
        IntPtr memDC = CreateCompatibleDC(screenDC);
        IntPtr hBmp = CreateCompatibleBitmap(screenDC, w, h);
        IntPtr old = SelectObject(memDC, hBmp);
        PrintWindow(hWnd, memDC, PW_CLIENT_RENDER);
        var bi = new BITMAPINFO();
        bi.bmiHeader.biSize = 40; bi.bmiHeader.biWidth = w; bi.bmiHeader.biHeight = -h;
        bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 32;
        byte[] pixels = new byte[w * h * 4];
        GetDIBits(memDC, hBmp, 0, (uint)h, pixels, ref bi, 0);
        SelectObject(memDC, old); DeleteObject(hBmp); DeleteDC(memDC); ReleaseDC(IntPtr.Zero, screenDC);
        return CaptureBottomLinesFromPixels(pixels, w, h, path, lineCount);
    }

    // Convert raw image data (from WMI GetVirtualSystemThumbnailImage) to PNG.
    // Auto-detects format from array length:
    //   w*h*4 bytes → BGRA 32-bit (direct)
    //   w*h*2 bytes → RGB565 16-bit (convert)
    //   w*h*3 bytes → RGB 24-bit (convert)
    public static bool SaveRawImageAsPng(byte[] imageData, int w, int h, string path) {
        if (imageData == null || w <= 0 || h <= 0) return false;
        int expected32 = w * h * 4;
        int expected16 = w * h * 2;
        int expected24 = w * h * 3;
        byte[] bgra;
        if (imageData.Length >= expected32) {
            // BGRA 32-bit — use directly
            bgra = imageData;
        } else if (imageData.Length >= expected24) {
            // RGB 24-bit — convert to BGRA
            bgra = new byte[expected32];
            for (int i = 0; i < w * h; i++) {
                bgra[i*4]   = imageData[i*3+2]; // B
                bgra[i*4+1] = imageData[i*3+1]; // G
                bgra[i*4+2] = imageData[i*3];   // R
                bgra[i*4+3] = 255;
            }
        } else if (imageData.Length >= expected16) {
            // RGB565 16-bit — convert to BGRA
            bgra = new byte[expected32];
            for (int i = 0; i < w * h; i++) {
                ushort pixel = (ushort)(imageData[i*2] | (imageData[i*2+1] << 8));
                byte r = (byte)(((pixel >> 11) & 0x1F) << 3);
                byte g = (byte)(((pixel >> 5) & 0x3F) << 2);
                byte b = (byte)((pixel & 0x1F) << 3);
                bgra[i*4] = b; bgra[i*4+1] = g; bgra[i*4+2] = r; bgra[i*4+3] = 255;
            }
        } else {
            return false; // unknown format
        }
        using (var fs = OpenWriteWithRetry(path)) {
            WritePng(fs, w, h, bgra);
        }
        return true;
    }

    static void WritePng(Stream s, int w, int h, byte[] bgra) {
        // PNG signature
        s.Write(new byte[]{137,80,78,71,13,10,26,10}, 0, 8);
        // IHDR
        var ihdr = new byte[13];
        WriteInt32BE(ihdr, 0, w); WriteInt32BE(ihdr, 4, h);
        ihdr[8]=8; ihdr[9]=2; // 8-bit RGB
        WriteChunk(s, "IHDR", ihdr);
        // IDAT: convert BGRA rows to filtered RGB, then deflate
        using (var ms = new MemoryStream()) {
            using (var ds = new System.IO.Compression.DeflateStream(ms, System.IO.Compression.CompressionLevel.Fastest, true)) {
                for (int y = 0; y < h; y++) {
                    ds.WriteByte(0); // filter: none
                    int rowOff = y * w * 4;
                    for (int x = 0; x < w; x++) {
                        int p = rowOff + x * 4;
                        ds.WriteByte(bgra[p+2]); // R
                        ds.WriteByte(bgra[p+1]); // G
                        ds.WriteByte(bgra[p]);   // B
                    }
                }
            }
            byte[] compressed = ms.ToArray();
            // Wrap in zlib: header(78 01) + compressed + adler32
            using (var zlib = new MemoryStream()) {
                zlib.WriteByte(0x78); zlib.WriteByte(0x01);
                zlib.Write(compressed, 0, compressed.Length);
                // Compute Adler32 over unfiltered data
                uint a1=1, a2=0;
                for (int y=0; y<h; y++) {
                    a1=(a1+0)%65521; a2=(a2+a1)%65521; // filter byte=0
                    int rowOff = y * w * 4;
                    for (int x=0; x<w; x++) {
                        int p = rowOff + x * 4;
                        a1=(a1+bgra[p+2])%65521; a2=(a2+a1)%65521;
                        a1=(a1+bgra[p+1])%65521; a2=(a2+a1)%65521;
                        a1=(a1+bgra[p])%65521;   a2=(a2+a1)%65521;
                    }
                }
                var adler = new byte[4];
                WriteInt32BE(adler, 0, (int)((a2<<16)|a1));
                zlib.Write(adler, 0, 4);
                WriteChunk(s, "IDAT", zlib.ToArray());
            }
        }
        WriteChunk(s, "IEND", new byte[0]);
    }
    static void WriteChunk(Stream s, string type, byte[] data) {
        var len = new byte[4]; WriteInt32BE(len, 0, data.Length); s.Write(len,0,4);
        var t = Encoding.ASCII.GetBytes(type); s.Write(t,0,4);
        s.Write(data, 0, data.Length);
        uint crc = Crc32(t, data);
        var c = new byte[4]; WriteInt32BE(c, 0, (int)crc); s.Write(c,0,4);
    }
    static void WriteInt32BE(byte[] b, int off, int v) {
        b[off]=(byte)(v>>24); b[off+1]=(byte)(v>>16); b[off+2]=(byte)(v>>8); b[off+3]=(byte)v;
    }
    static uint Crc32(byte[] type, byte[] data) {
        uint c = 0xFFFFFFFF;
        foreach (byte b in type) c = CrcByte(c, b);
        foreach (byte b in data) c = CrcByte(c, b);
        return c ^ 0xFFFFFFFF;
    }
    static uint CrcByte(uint c, byte b) {
        c ^= b;
        for (int i=0;i<8;i++) c = (c&1)!=0 ? (c>>1)^0xEDB88320 : c>>1;
        return c;
    }
}
"@
        }
    } catch {
        Write-Warning "Failed to load HyperVCapture type: $_"
    }

    Import-Module (Join-Path $PSScriptRoot "Test.LogDir.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false
    $debugDir = Join-Path (Initialize-YurunaLogDir) "Screenshot"
    if (-not (Test-Path $debugDir)) { New-Item -ItemType Directory -Force -Path $debugDir | Out-Null }

    # ── Primary: WMI GetVirtualSystemThumbnailImage ─────────────────────────
    # Gets the full VM display at native resolution, bypassing vmconnect
    # entirely. No window chrome, no scaling, no zoom issues.
    try {
        $vmSettingData = Get-CimInstance -Namespace root/virtualization/v2 `
            -ClassName Msvm_VirtualSystemSettingData `
            -Filter "ElementName='$VMName'" |
            Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }
        if ($vmSettingData) {
            $vmms = Get-CimInstance -Namespace root/virtualization/v2 `
                -ClassName Msvm_VirtualSystemManagementService
            # Request screenshot at the configured VM resolution.
            $vmVideo = Get-VMVideo -VMName $VMName -ErrorAction SilentlyContinue
            $reqW = $vmVideo ? [uint16]$vmVideo.HorizontalResolution : [uint16]1920
            $reqH = $vmVideo ? [uint16]$vmVideo.VerticalResolution : [uint16]1080

            $result = Invoke-CimMethod -InputObject $vmms `
                -MethodName GetVirtualSystemThumbnailImage `
                -Arguments @{
                    TargetSystem = $vmSettingData
                    WidthPixels  = $reqW
                    HeightPixels = $reqH
                }
            if ($result.ReturnValue -eq 0 -and $result.ImageData -and $result.ImageData.Length -gt 0) {
                $ok = [HyperVCapture]::SaveRawImageAsPng(
                    [byte[]]$result.ImageData, [int]$reqW, [int]$reqH, $OutputPath)
                if ($ok -and (Test-Path $OutputPath)) {
                    Copy-Item -Path $OutputPath -Destination (Join-Path $debugDir "wmi_full.png") -Force
                    Write-Output "Screenshot saved (WMI ${reqW}x${reqH}): $OutputPath"
                    return $OutputPath
                }
                # Save raw data length for debugging
                [System.IO.File]::WriteAllText((Join-Path $debugDir "wmi_debug.txt"),
                    "dataLen=$($result.ImageData.Length) expected16=$(${reqW}*${reqH}*2) expected24=$(${reqW}*${reqH}*3) expected32=$(${reqW}*${reqH}*4)")
            } else {
                $rc = $result ? $result.ReturnValue : "null"
                $len = ($result -and $result.ImageData) ? $result.ImageData.Length : 0
                [System.IO.File]::WriteAllText((Join-Path $debugDir "wmi_debug.txt"), "rc=$rc dataLen=$len")
            }
        } else {
            [System.IO.File]::WriteAllText((Join-Path $debugDir "wmi_debug.txt"), "vmSettingData not found")
        }
    } catch {
        [System.IO.File]::WriteAllText((Join-Path $debugDir "wmi_debug.txt"), "exception: $_")
    }

    # ── Fallback: PrintWindow via vmconnect window ──────────────────────────
    try {
        [HyperVCapture]::EnsureDpiAware()
        $hWnd = [HyperVCapture]::FindWindow($VMName)
        if ($hWnd -eq [IntPtr]::Zero) {
            Write-Warning "vmconnect window not found for '$VMName'."
            return $null
        }
        # Log DPI and window dimensions for debugging
        $dpi = [HyperVCapture]::GetDpiForWindow($hWnd)
        $ok = [HyperVCapture]::CaptureToFile($hWnd, $OutputPath)
        if ($ok -and (Test-Path $OutputPath)) {
            Copy-Item -Path $OutputPath -Destination (Join-Path $debugDir "printwindow_full.png") -Force
            $imgSize = (Get-Item $OutputPath).Length
            [System.IO.File]::WriteAllText((Join-Path $debugDir "printwindow_debug.txt"),
                "dpi=$dpi fileSize=$imgSize")
            Write-Output "Screenshot saved (PrintWindow): $OutputPath"
            return $OutputPath
        }
    } catch {
        Write-Warning "PrintWindow screenshot failed: $_"
    }
    Write-Error "Screenshot capture failed for '$VMName'"
    return $null
}

# ── Window-bound screenshot (for click flows) ───────────────────────────────

<#
.SYNOPSIS
    Captures the VM's display via the host window (vmconnect / UTM), exposing
    the window handle / id so a follow-up click can land on the same coord space.
.DESCRIPTION
    Click actions need the screenshot and the click to share a coordinate
    system. Get-VMScreenshot prefers the WMI thumbnail path (no window
    required), which reports VM-native pixels that do NOT line up with
    vmconnect's client area when zoom/scale differs. This helper forces
    the window-capture path so OCR coordinates are directly usable for
    SendInput / CGEvent clicks.
.OUTPUTS
    Hashtable: @{ ImagePath; HWnd; Width; Height } on Hyper-V,
    @{ ImagePath; WindowId; OriginX; OriginY; Scale } on UTM,
    or $null on failure.
#>
function Get-VMWindowScreenshot {
    param(
        [string]$HostType,
        [string]$VMName,
        [string]$OutputPath
    )
    $dir = Split-Path -Parent $OutputPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    switch ($HostType) {
        "host.windows.hyper-v" {
            return Get-HyperVWindowScreenshot -VMName $VMName -OutputPath $OutputPath
        }
        "host.macos.utm" {
            return Get-UtmWindowScreenshot -VMName $VMName -OutputPath $OutputPath
        }
        default {
            Write-Error "Unknown host type for window screenshot: $HostType"
            return $null
        }
    }
}

function Get-HyperVWindowScreenshot {
    <#
    .SYNOPSIS
        Captures the vmconnect client area via PrintWindow and returns hWnd + dimensions.
    .DESCRIPTION
        Used by click-by-OCR flows that need the screenshot's pixel space to line
        up with ClientToScreen coordinates. The default Get-VMScreenshot path
        prefers WMI thumbnails which do NOT share vmconnect's coord space.
    .OUTPUTS
        Hashtable @{ ImagePath; HWnd; Width; Height } on success, or $null.
    #>
    param([string]$VMName, [string]$OutputPath)

    # Ensure the HyperVCapture type is loaded. The easiest way is to invoke
    # Get-HyperVScreenshot once; its Add-Type call is idempotent (guarded by
    # a type-existence check), and any captured PNG is overwritten below.
    if (-not ('HyperVCapture' -as [type])) {
        $warmupPath = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna_warmup_${VMName}.png"
        Get-HyperVScreenshot -VMName $VMName -OutputPath $warmupPath | Out-Null
        Remove-Item $warmupPath -Force -ErrorAction SilentlyContinue
    }
    if (-not ('HyperVCapture' -as [type])) {
        Write-Warning "HyperVCapture type failed to load. Click-by-OCR requires the Test.Screenshot module."
        return $null
    }

    try {
        [HyperVCapture]::EnsureDpiAware()
        $hWnd = [HyperVCapture]::FindWindow($VMName)
        if ($hWnd -eq [IntPtr]::Zero) {
            Write-Warning "vmconnect window not found for '$VMName'. Open a vmconnect session for this VM before using waitForAndClickButton."
            return $null
        }
        $ok = [HyperVCapture]::CaptureToFile($hWnd, $OutputPath)
        if (-not $ok -or -not (Test-Path $OutputPath)) {
            Write-Warning "PrintWindow capture failed for '$VMName'."
            return $null
        }
        # Report the captured image's dimensions for downstream click coord sanity checks
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $bmp = [System.Drawing.Bitmap]::new($OutputPath)
        try {
            return @{
                ImagePath = $OutputPath
                HWnd      = $hWnd
                Width     = $bmp.Width
                Height    = $bmp.Height
            }
        } finally { $bmp.Dispose() }
    } catch {
        Write-Warning "Get-HyperVWindowScreenshot failed: $_"
        return $null
    }
}

function Get-UtmWindowScreenshot {
    <#
    .SYNOPSIS
        Captures the UTM-hosted VM window and returns enough metadata for
        click-by-OCR to map image pixel coords back to screen point coords.
    .DESCRIPTION
        Reuses the CGWindowID lookup from Get-UtmScreenshot but additionally
        extracts the window's screen-point bounds (kCGWindowBounds, already in
        the same coordinate space CGEventPost uses) and computes the backing
        scale factor from captured-PNG pixels vs point-space width.

        Scale matters because `screencapture -l <id>` records the window at
        its backing store resolution (2x on retina), while CGEventPost takes
        coordinates in screen points. Send-ClickUtm does the conversion:
            screenX = OriginX + imageX / Scale
            screenY = OriginY + imageY / Scale
        Computing Scale from the actual captured PNG (rather than asking
        NSScreen.backingScaleFactor) stays correct when the VM window is
        dragged to a display with a different scale factor mid-test.
    .OUTPUTS
        Hashtable @{ ImagePath; WindowId; OriginX; OriginY; Width; Height;
                     PointWidth; PointHeight; Scale } on success, or $null.
    #>
    param([string]$VMName, [string]$OutputPath)

    # Piggyback on Get-UtmScreenshot's one-time Screen-Recording probe (sets
    # $script:ScreencaptureWorks). If it already concluded screencapture is
    # broken, don't bother hitting osascript first — fail fast with the same
    # permission message the caller has already seen.
    if ($script:ScreencaptureWorks -eq $false) { return $null }

    # One JXA query pulls window ID + bounds together. kCGWindowBounds is in
    # screen points (origin top-left of main display) — exactly what
    # CGEventPost consumes, so no extra coord-system conversion is needed
    # downstream for the click dispatch.
    # kCGWindowListOptionAll (not OnScreenOnly) so the lookup survives the
    # operator switching to another macOS Space — see the matching comment
    # in Get-UtmScreenshot above.
    $safeVMName = $VMName -replace '\\', '\\\\' -replace "'", "\\'"
    $windowScript = @"
ObjC.import('CoreGraphics');
var winList = ObjC.unwrap(
    `$.CGWindowListCopyWindowInfo(`$.kCGWindowListOptionAll, 0));
var vmName = '__VMNAME__';
var result = 'not_found';
for (var i = 0; i < winList.length; i++) {
    var w = winList[i];
    var owner = ObjC.unwrap(w.kCGWindowOwnerName) || '';
    var name  = ObjC.unwrap(w.kCGWindowName)      || '';
    if (owner.indexOf('UTM') >= 0 && name.indexOf(vmName) >= 0) {
        var id = ObjC.unwrap(w.kCGWindowNumber);
        var b  = ObjC.unwrap(w.kCGWindowBounds);
        result = '' + id + ',' + b.X + ',' + b.Y + ',' + b.Width + ',' + b.Height;
        break;
    }
}
result;
"@
    $windowScript = $windowScript -replace '__VMNAME__', $safeVMName
    $windowResult = & osascript -l JavaScript -e $windowScript 2>&1
    Write-Debug "      CG window query (window+bounds): $windowResult"

    # Expected shape: "id,x,y,w,h" with floats tolerated on the coord fields
    # (Cocoa routinely returns half-pixel origins on retina).
    $windowId = 0
    $originX  = 0.0
    $originY  = 0.0
    $pointW   = 0.0
    $pointH   = 0.0
    $cgOk     = $false
    if ($LASTEXITCODE -eq 0 -and "$windowResult" -match '^\d+,-?\d+(\.\d+)?,-?\d+(\.\d+)?,\d+(\.\d+)?,\d+(\.\d+)?$') {
        $parts    = "$windowResult".Split(',')
        $windowId = [int]$parts[0]
        $originX  = [double]$parts[1]
        $originY  = [double]$parts[2]
        $pointW   = [double]$parts[3]
        $pointH   = [double]$parts[4]
        $cgOk     = $true
    } else {
        # Fallback: enumerate UTM's windows via System Events (Accessibility
        # API). Symmetric with Get-UtmScreenshot's bounds fallback — we know
        # that path works because OCR has already succeeded in this cycle.
        # CGWindowList can return `not_found` for the UTM window even when
        # Screen Recording is granted: some UTM releases mint the VM
        # display window with NSWindowSharingNone, which keeps
        # kCGWindowName empty regardless of TCC state. AX title comes from
        # AXTitle (a different code path) and is unaffected.
        $safeVMNameAS = $VMName -replace '\\', '\\\\' -replace '"', '\\"'
        $boundsScript = @"
tell application "System Events"
    tell process "UTM"
        repeat with w in windows
            if name of w contains "$safeVMNameAS" then
                try
                    set contentArea to first group of w
                    set {cx, cy} to position of contentArea
                    set {cw, ch} to size of contentArea
                    return ("" & cx & "," & cy & "," & cw & "," & ch)
                end try
                set {wx, wy} to position of w
                set {ww, wh} to size of w
                set titleBarH to 28
                return ("" & wx & "," & (wy + titleBarH) & "," & ww & "," & (wh - titleBarH))
            end if
        end repeat
    end tell
    return "not_found"
end tell
"@
        $boundsResult = & osascript -e $boundsScript 2>&1
        Write-Debug "      Window bounds query (fallback): $boundsResult"
        if ($LASTEXITCODE -eq 0 -and "$boundsResult" -match '^-?\d+(\.\d+)?,-?\d+(\.\d+)?,\d+(\.\d+)?,\d+(\.\d+)?$') {
            $parts   = "$boundsResult".Split(',')
            $originX = [double]$parts[0]
            $originY = [double]$parts[1]
            $pointW  = [double]$parts[2]
            $pointH  = [double]$parts[3]
            # WindowId stays 0 — we have no CG handle. Click dispatch uses
            # OriginX/OriginY/Scale (global screen points), which is enough.
        } else {
            Write-Warning "UTM window for '$VMName' not found (CG: $windowResult, bounds: $boundsResult)."
            Write-Warning "  Open the VM in UTM.app before using waitForAndClickButton."
            return $null
        }
    }

    # Capture: -l <id> when we have a real CG handle (captures even when
    # obscured); -R <bounds> otherwise (captures whatever is currently at
    # those screen coordinates — caller must keep UTM frontmost).
    if ($cgOk) {
        $captureErr = & screencapture -x -o -l "$windowId" "$OutputPath" 2>&1
    } else {
        $region = "{0},{1},{2},{3}" -f $originX, $originY, $pointW, $pointH
        $captureErr = & screencapture -x -R "$region" "$OutputPath" 2>&1
    }
    if (-not (Test-Path $OutputPath)) {
        Write-Warning "screencapture failed for '$VMName': $captureErr"
        return $null
    }
    $fileSize = (Get-Item $OutputPath).Length
    if ($fileSize -lt 100) {
        Write-Warning "screencapture produced a ${fileSize}-byte PNG — likely Screen Recording permission missing."
        Write-Warning "  System Settings > Privacy & Security > Screen Recording > enable your terminal"
        Remove-Item $OutputPath -Force -ErrorAction SilentlyContinue
        return $null
    }

    # Parse the PNG's IHDR chunk to read pixel dimensions. Bytes 16-19 are
    # width (big-endian uint32), 20-23 are height. Using raw byte parsing
    # rather than System.Drawing.Common because the latter is not in the
    # default pwsh 7 install on macOS.
    try {
        $fs = [IO.File]::OpenRead($OutputPath)
        try {
            $buf = New-Object byte[] 24
            [void]$fs.Read($buf, 0, 24)
        } finally { $fs.Dispose() }
        $pixelW = ([int]$buf[16] -shl 24) -bor ([int]$buf[17] -shl 16) -bor ([int]$buf[18] -shl 8) -bor [int]$buf[19]
        $pixelH = ([int]$buf[20] -shl 24) -bor ([int]$buf[21] -shl 16) -bor ([int]$buf[22] -shl 8) -bor [int]$buf[23]
    } catch {
        Write-Warning "Failed to read PNG dimensions from '$OutputPath': $_"
        return $null
    }

    # Scale = pixels-per-point on whatever display the window currently sits
    # on. Retina reports ~2.0; non-retina 1.0. If the window reports zero
    # point-space width (shouldn't happen for a visible CGWindow, but guard
    # so downstream divisions don't NaN out), fall back to 1.0.
    $scale = if ($pointW -gt 0) { $pixelW / $pointW } else { 1.0 }
    Write-Debug "      UTM window: id=$windowId origin=($originX,$originY) point=${pointW}x${pointH} pixel=${pixelW}x${pixelH} scale=$scale"

    return @{
        ImagePath   = $OutputPath
        WindowId    = $windowId
        OriginX     = $originX
        OriginY     = $originY
        Width       = $pixelW
        Height      = $pixelH
        PointWidth  = $pointW
        PointHeight = $pointH
        Scale       = $scale
    }
}

# ── Screenshot comparison ────────────────────────────────────────────────────

<#
.SYNOPSIS
    Compares two PNG images and returns a similarity score (0.0 to 1.0).
.DESCRIPTION
    Uses pixel-level comparison. Returns 1.0 for identical images.
#>
function Compare-Screenshot {
    param(
        [string]$ReferencePath,
        [string]$ActualPath,
        [double]$Threshold = 0.85
    )
    if (-not (Test-Path $ReferencePath)) {
        Write-Error "Reference screenshot not found: $ReferencePath"
        return @{ match=$false; similarity=0.0; error="Reference not found" }
    }
    if (-not (Test-Path $ActualPath)) {
        Write-Error "Actual screenshot not found: $ActualPath"
        return @{ match=$false; similarity=0.0; error="Actual not found" }
    }

    try {
        Add-Type -AssemblyName System.Drawing
        $ref = [System.Drawing.Bitmap]::new($ReferencePath)
        $act = [System.Drawing.Bitmap]::new($ActualPath)

        # Resize actual to match reference if dimensions differ
        if ($ref.Width -ne $act.Width -or $ref.Height -ne $act.Height) {
            $resized = [System.Drawing.Bitmap]::new($act, $ref.Width, $ref.Height)
            $act.Dispose()
            $act = $resized
        }

        $matchingPixels = 0

        # Sample pixels (every 4th pixel for performance)
        $step = 4
        $sampled = 0
        for ($y = 0; $y -lt $ref.Height; $y += $step) {
            for ($x = 0; $x -lt $ref.Width; $x += $step) {
                $sampled++
                $rp = $ref.GetPixel($x, $y)
                $ap = $act.GetPixel($x, $y)
                $diff = [Math]::Abs([int]$rp.R - [int]$ap.R) +
                        [Math]::Abs([int]$rp.G - [int]$ap.G) +
                        [Math]::Abs([int]$rp.B - [int]$ap.B)
                # Allow per-pixel tolerance of 30 (out of 765 max diff)
                if ($diff -lt 30) { $matchingPixels++ }
            }
        }

        $similarity = $sampled -gt 0 ? [Math]::Round($matchingPixels / $sampled, 4) : 0.0

        $ref.Dispose()
        $act.Dispose()

        $isMatch = $similarity -ge $Threshold
        Write-Output "Screenshot comparison: similarity=$similarity threshold=$Threshold match=$isMatch"
        return @{ match=$isMatch; similarity=$similarity; error=$null }
    } catch {
        Write-Error "Screenshot comparison failed: $_"
        return @{ match=$false; similarity=0.0; error="$_" }
    }
}

# ── Schedule management ──────────────────────────────────────────────────────

<#
.SYNOPSIS
    Reads the screenshot schedule JSON for a guest.
.DESCRIPTION
    Returns an array of checkpoints: @( @{ name; delaySeconds; threshold } )
    Returns empty array if no schedule file exists.
#>
function Get-ScreenshotSchedule {
    param([string]$GuestKey, [string]$ScreenshotsDir)
    $scheduleFile = Join-Path $ScreenshotsDir "$GuestKey/schedule.json"
    if (-not (Test-Path $scheduleFile)) { return @() }
    try {
        $schedule = Get-Content -Raw $scheduleFile | ConvertFrom-Json
        return @($schedule.checkpoints)
    } catch {
        Write-Warning "Failed to read screenshot schedule: $scheduleFile — $_"
        return @()
    }
}

<#
.SYNOPSIS
    Executes all screenshot checkpoints for a running VM.
.DESCRIPTION
    Waits the specified delay, captures, and compares with reference.
    Returns a hashtable: { success, skipped, errorMessage }
#>
function Invoke-ScreenshotTest {
    param(
        [string]$HostType,
        [string]$GuestKey,
        [string]$VMName,
        [string]$ScreenshotsDir
    )
    $schedule = Get-ScreenshotSchedule -GuestKey $GuestKey -ScreenshotsDir $ScreenshotsDir
    if ($schedule.Count -eq 0) {
        return @{ success=$true; skipped=$true; errorMessage=$null }
    }

    $guestDir   = Join-Path $ScreenshotsDir $GuestKey
    $captureDir = Join-Path $guestDir "captures"
    if (-not (Test-Path $captureDir)) { New-Item -ItemType Directory -Force -Path $captureDir | Out-Null }

    foreach ($cp in $schedule) {
        $cpName    = $cp.name
        $delay     = [int]$cp.delaySeconds
        $threshold = $cp.threshold ? [double]$cp.threshold : 0.85
        $refFile   = Join-Path $guestDir "reference/$cpName.png"

        if (-not (Test-Path $refFile)) {
            return @{ success=$false; skipped=$false; errorMessage="Reference screenshot missing: $refFile. Run Train-Screenshots.ps1 -GuestKey $GuestKey first." }
        }

        Write-Output "  Screenshot checkpoint '$cpName': waiting ${delay}s..."
        Start-Sleep -Seconds $delay

        $capFile = Join-Path $captureDir "$cpName.png"
        $captured = Get-VMScreenshot -HostType $HostType -VMName $VMName -OutputPath $capFile
        if (-not $captured) {
            return @{ success=$false; skipped=$false; errorMessage="Failed to capture screenshot for checkpoint '$cpName'" }
        }

        $result = Compare-Screenshot -ReferencePath $refFile -ActualPath $capFile -Threshold $threshold
        if (-not $result.match) {
            $msg = "Screenshot '$cpName' mismatch: similarity=$($result.similarity) threshold=$threshold"
            if ($result.error) { $msg += " error=$($result.error)" }
            return @{ success=$false; skipped=$false; errorMessage=$msg }
        }
        Write-Output "  Screenshot checkpoint '$cpName': PASS (similarity=$($result.similarity))"
    }

    return @{ success=$true; skipped=$false; errorMessage=$null }
}

Export-ModuleMember -Function Get-VMScreenshot, Get-VMWindowScreenshot, Get-HyperVWindowScreenshot, Compare-Screenshot, Get-ScreenshotSchedule, Invoke-ScreenshotTest, Get-VncDisplayForVm, Get-VncPortForVm
