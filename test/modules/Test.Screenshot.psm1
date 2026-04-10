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

function Get-UtmScreenshot {
    param([string]$VMName, [string]$OutputPath)

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

    # Query the UTM window bounds via System Events (Accessibility API)
    # WITHOUT activating UTM or raising the window. Uses screencapture -R
    # to capture the screen region at the window's position.
    # Note: UTM's SwiftUI windows do not expose an `id` property, so we
    # cannot use screencapture -l. However, -R works without activation
    # as long as the UTM window is not obscured by another window.
    $safeVMName = $VMName -replace '\\', '\\\\' -replace '"', '\\"'
    $boundsScript = @"
tell application "System Events"
    tell process "UTM"
        repeat with w in windows
            if name of w contains "$safeVMName" then
                -- Try content area (first group) to exclude title bar and toolbar.
                try
                    set contentArea to first group of w
                    set {cx, cy} to position of contentArea
                    set {cw, ch} to size of contentArea
                    return ("" & cx & "," & cy & "," & cw & "," & ch)
                end try
                -- Fallback: window frame with title-bar offset (28pt).
                set {wx, wy} to position of w
                set {ww, wh} to size of w
                set titleBarH to 28
                return ("" & wx & "," & (wy + titleBarH) & "," & ww & "," & (wh - titleBarH))
            end if
        end repeat
    end tell
    -- No match; list actual window names for diagnostics.
    set nameList to {}
    repeat with proc in (every process whose name contains "UTM")
        repeat with w in windows of proc
            set end of nameList to (name of proc) & ": " & (name of w)
        end repeat
    end repeat
    return "not_found|" & (nameList as text)
end tell
"@
    $boundsResult = & osascript -e $boundsScript 2>&1
    Write-Debug "      Window query result: $boundsResult"
    $captured = $false

    if ($LASTEXITCODE -eq 0 -and "$boundsResult" -match '^\d+,\d+,\d+,\d+$') {
        $captureErr = & screencapture -x -R "$boundsResult" "$OutputPath" 2>&1
        if (Test-Path $OutputPath) {
            $captured = $true
        } else {
            Write-Warning "screencapture -R '$boundsResult' failed: $captureErr"
        }
    } else {
        $diagInfo = "$boundsResult"
        if ($diagInfo -match '^not_found\|(.*)$') {
            $windowNames = $Matches[1]
            if ($windowNames) {
                Write-Warning "UTM window for '$VMName' not found. Available UTM windows: $windowNames"
            } else {
                Write-Warning "UTM window for '$VMName' not found. No UTM windows are visible."
            }
        } else {
            Write-Warning "Could not query UTM windows for '$VMName': $diagInfo"
        }
    }

    # Last resort: full-screen capture
    if (-not $captured) {
        Write-Warning "Falling back to full-screen capture."
        $captureErr = & screencapture -x "$OutputPath" 2>&1
        if (Test-Path $OutputPath) {
            $captured = $true
        } else {
            Write-Warning "Full-screen screencapture also failed: $captureErr"
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
        using (var fs = new FileStream(path, FileMode.Create)) {
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
        using (var fs = new FileStream(path, FileMode.Create)) {
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
        using (var fs = new FileStream(path, FileMode.Create)) {
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
        using (var fs = new FileStream(path, FileMode.Create)) {
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

    # Debug directory for inspecting captures
    Import-Module (Join-Path $PSScriptRoot "Test.LogDir.psm1") -Force -ErrorAction SilentlyContinue -Verbose:$false
    $debugDir = Join-Path (Get-YurunaLogDir) "Screenshot"
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

Export-ModuleMember -Function Get-VMScreenshot, Compare-Screenshot, Get-ScreenshotSchedule, Invoke-ScreenshotTest
