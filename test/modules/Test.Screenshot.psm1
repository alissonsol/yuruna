<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456714
.AUTHOR Alisson Sol
.COMPANYNAME None
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

    # Find the UTM window bounds for this VM.
    # Searches any process whose name contains "UTM" to handle variants
    # (UTM, UTM SE, etc.). Uses window bounds + screencapture -R instead
    # of window ID, because screencapture -l expects a CGWindowID which
    # may not match the AppleScript window id in SwiftUI apps like UTM.
    $boundsScript = @"
tell application "System Events"
    repeat with proc in (every process whose name contains "UTM")
        repeat with w in windows of proc
            if name of w contains "$VMName" then
                set {wx, wy} to position of w
                set {ww, wh} to size of w
                return ("" & wx & "," & wy & "," & ww & "," & wh)
            end if
        end repeat
    end repeat
    -- No match found; list actual window names for diagnostics.
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
    $captured = $false
    if ($LASTEXITCODE -eq 0 -and "$boundsResult" -match '^\d+,\d+,\d+,\d+$') {
        $captureErr = & screencapture -x -R "$boundsResult" "$OutputPath" 2>&1
        if (Test-Path $OutputPath) {
            $captured = $true
        } else {
            Write-Warning "screencapture -R '$boundsResult' failed: $captureErr"
            Write-Warning "Falling back to full-screen capture."
        }
    } else {
        # Parse diagnostic info from the AppleScript result
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
        Write-Warning "Falling back to full-screen capture."
    }
    if (-not $captured) {
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
    try {
        # Find the vmconnect window and capture it to PNG using only Win32 APIs.
        # Avoids System.Drawing which is not reliably available in PowerShell 7 / .NET Core.
        if (-not ('WindowCapturePng' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public class WindowCapturePng {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder sb, int max);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("gdi32.dll")]  public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")]  public static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);
    [DllImport("gdi32.dll")]  public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")]  public static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32.dll")]  public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")]  public static extern int GetDIBits(IntPtr hdc, IntPtr hbmp, uint start, uint lines, byte[] bits, ref BITMAPINFO bi, uint usage);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hdc);
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

    public static bool CaptureToFile(IntPtr hWnd, string path) {
        RECT r; GetWindowRect(hWnd, out r);
        int w = r.Right - r.Left, h = r.Bottom - r.Top;
        if (w <= 0 || h <= 0) return false;
        IntPtr screenDC = GetDC(IntPtr.Zero);
        IntPtr memDC = CreateCompatibleDC(screenDC);
        IntPtr hBmp = CreateCompatibleBitmap(screenDC, w, h);
        IntPtr old = SelectObject(memDC, hBmp);
        PrintWindow(hWnd, memDC, 2); // PW_RENDERFULLCONTENT
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

        $hWnd = [WindowCapturePng]::FindWindow($VMName)
        if ($hWnd -eq [IntPtr]::Zero) {
            Write-Warning "vmconnect window not found for '$VMName'."
            return $null
        }
        $ok = [WindowCapturePng]::CaptureToFile($hWnd, $OutputPath)
        if ($ok -and (Test-Path $OutputPath)) {
            Write-Output "Screenshot saved: $OutputPath"
            return $OutputPath
        }
    } catch {
        Write-Warning "Hyper-V screenshot failed: $_"
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

        $similarity = if ($sampled -gt 0) { [Math]::Round($matchingPixels / $sampled, 4) } else { 0.0 }

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
        $threshold = if ($cp.threshold) { [double]$cp.threshold } else { 0.85 }
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
