<#PSScriptInfo
.VERSION 2026.11.05
.GUID 42b5652c-22fc-4a87-bb38-d276ad4ef1e0
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS yuruna host windows.hyper-v driver screenshot
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

# --- REGION: Screenshot helpers
# See https://yuruna.link/42e220c4-0004

# The realized settings of each VM and the management service, kept between
# frames: a wait captures every few seconds, and resolving both took two CIM
# queries per frame. A VM rebuilt under the same name has new settings, so a
# capture through kept objects that fails is resolved and tried once more.
$script:HyperVThumbnailTargets = @{}
$script:HyperVManagementService = $null

function Get-HyperVThumbnailByte {
    <#
    .SYNOPSIS
    Capture a screenshot of a Hyper-V VM via the WMI thumbnail API.

    .DESCRIPTION
    Uses Msvm_VirtualSystemManagementService.GetVirtualSystemThumbnailImage
    to grab the VM's framebuffer at its configured resolution, falling back to
    smaller supported thumbnail sizes during boot, and writes the returned size
    to $OutputPath as a PNG. Does not require a vmconnect window and runs
    even when the host is headless. Use the PrintWindow path (separate
    helper) when click-by-OCR needs coordinates that match vmconnect's
    client area.
    #>
        <#
    .SYNOPSIS
        Reads a realized VM thumbnail with an escaped and unambiguous WQL lookup.
    .PARAMETER VMName
        The VM display name.
    .PARAMETER Width
        Requested pixel width.
    .PARAMETER Height
        Requested pixel height.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseOutputTypeCorrectly', '', Justification = 'Unary comma preserves the byte array as one pipeline value.')]
    [OutputType([byte[]])]
    param([string]$VMName, [uint16]$Width = 640, [uint16]$Height = 480)
    foreach ($resolve in @($false, $true)) {
        $kept = (-not $resolve) -and $script:HyperVThumbnailTargets.ContainsKey($VMName) -and $script:HyperVManagementService
        if (-not $kept) {
            $literal = $VMName.Replace('\', '\\').Replace("'", "\'")
            $settings = @(Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_VirtualSystemSettingData -Filter "ElementName='$literal'" |
                Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' })
            if ($settings.Count -ne 1) { $script:HyperVThumbnailTargets.Remove($VMName); return $null }
            $script:HyperVThumbnailTargets[$VMName] = $settings[0]
            $script:HyperVManagementService = Get-CimInstance -Namespace root/virtualization/v2 -ClassName Msvm_VirtualSystemManagementService
        }
        $result = $null
        try {
            $result = Invoke-CimMethod -InputObject $script:HyperVManagementService -MethodName GetVirtualSystemThumbnailImage -Arguments @{
                TargetSystem = $script:HyperVThumbnailTargets[$VMName]; WidthPixels = $Width; HeightPixels = $Height
            }
        } catch {
            if (-not $kept) { throw }
            Write-Verbose "Hyper-V thumbnail through kept objects failed for '$VMName'; resolving them again: $($_.Exception.Message)"
        }
        if ($result -and $result.ReturnValue -eq 0 -and $result.ImageData -and $result.ImageData.Length -gt 0) {
            return ,([byte[]]$result.ImageData)
        }
        if (-not $kept) { return $null }
    }
    return $null
}

function Get-HyperVScreenshot {
    <# .SYNOPSIS
        Captures a Hyper-V console through the shared thumbnail or viewer fallback.
    #>
    param([string]$VMName, [string]$OutputPath)

    # --- REGION: Load C# type (once per session)
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
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr dpiContext);
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

    const uint PW_CLIENT_RENDER = 3;

    public static void EnsureDpiAware() {
        if (!dpiAware) { SetProcessDPIAware(); dpiAware = true; }
    }

    // Per-Monitor-V2 keeps PrintWindow and the click mapping in physical pixels.
    // A system-DPI-aware capture on a scaled display renders only the top-left
    // of the window, and OCR times out silently. See https://yuruna.link/4222e5f2-000c
    static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new IntPtr(-4);
    static IntPtr EnterPerMonitorV2() {
        try { return SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2); }
        catch { return IntPtr.Zero; }
    }
    static void RestoreThreadDpiContext(IntPtr prev) {
        if (prev == IntPtr.Zero) return;
        try { SetThreadDpiAwarenessContext(prev); } catch { }
    }

    static bool GetClientSize(IntPtr hWnd, out int w, out int h) {
        EnsureDpiAware();
        RECT r; GetClientRect(hWnd, out r);
        w = r.Right; h = r.Bottom;
        return w > 0 && h > 0;
    }

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
        IntPtr prevDpiCtx = EnterPerMonitorV2();
        try {
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
            using (var fs = OpenWriteWithRetry(path)) {
                WritePng(fs, w, h, pixels);
            }
            return true;
        } finally {
            RestoreThreadDpiContext(prevDpiCtx);
        }
    }

    // True when at least `darkFraction` of the pixels are dark (every channel below
    // `byteThreshold`): the all-black thumbnail of a host with no monitor attached,
    // which Get-HyperVScreenshot reports instead of letting OCR time out.
    // See https://yuruna.link/42dc5bb9-000a
    public static bool IsImageMostlyBlack(byte[] imageData, int w, int h, double darkFraction) {
        if (imageData == null || w <= 0 || h <= 0) return false;
        int expected16 = w * h * 2;
        int expected24 = w * h * 3;
        int expected32 = w * h * 4;
        long total = (long)w * h;
        if (total <= 0) return false;
        long dark = 0;
        const int byteThreshold = 16;
        if (imageData.Length >= expected32) {
            for (int i = 0; i < total; i++) {
                int p = i * 4;
                if (imageData[p] < byteThreshold && imageData[p+1] < byteThreshold && imageData[p+2] < byteThreshold) dark++;
            }
        } else if (imageData.Length >= expected24) {
            for (int i = 0; i < total; i++) {
                int p = i * 3;
                if (imageData[p] < byteThreshold && imageData[p+1] < byteThreshold && imageData[p+2] < byteThreshold) dark++;
            }
        } else if (imageData.Length >= expected16) {
            // RGB565: pack-value < 0x1083 ~= every channel below ~16/255.
            for (int i = 0; i < total; i++) {
                ushort pixel = (ushort)(imageData[i*2] | (imageData[i*2+1] << 8));
                if (pixel < 0x1083) dark++;
            }
        } else {
            return false;
        }
        return ((double)dark / total) >= darkFraction;
    }

    public static bool SaveRawImageAsPng(byte[] imageData, int w, int h, string path) {
        if (imageData == null || w <= 0 || h <= 0) return false;
        int expected32 = w * h * 4;
        int expected16 = w * h * 2;
        int expected24 = w * h * 3;
        byte[] bgra;
        if (imageData.Length >= expected32) {
            bgra = imageData;
        } else if (imageData.Length >= expected24) {
            bgra = new byte[expected32];
            for (int i = 0; i < w * h; i++) {
                bgra[i*4]   = imageData[i*3+2]; // B
                bgra[i*4+1] = imageData[i*3+1]; // G
                bgra[i*4+2] = imageData[i*3];   // R
                bgra[i*4+3] = 255;
            }
        } else if (imageData.Length >= expected16) {
            bgra = new byte[expected32];
            for (int i = 0; i < w * h; i++) {
                ushort pixel = (ushort)(imageData[i*2] | (imageData[i*2+1] << 8));
                byte r = (byte)(((pixel >> 11) & 0x1F) << 3);
                byte g = (byte)(((pixel >> 5) & 0x3F) << 2);
                byte b = (byte)((pixel & 0x1F) << 3);
                bgra[i*4] = b; bgra[i*4+1] = g; bgra[i*4+2] = r; bgra[i*4+3] = 255;
            }
        } else {
            return false;
        }
        using (var fs = OpenWriteWithRetry(path)) {
            WritePng(fs, w, h, bgra);
        }
        return true;
    }

    static void WritePng(Stream s, int w, int h, byte[] bgra) {
        s.Write(new byte[]{137,80,78,71,13,10,26,10}, 0, 8);
        var ihdr = new byte[13];
        WriteInt32BE(ihdr, 0, w); WriteInt32BE(ihdr, 4, h);
        ihdr[8]=8; ihdr[9]=2;
        WriteChunk(s, "IHDR", ihdr);
        using (var ms = new MemoryStream()) {
            // One Write per scanline rather than three per pixel. The compression
            // streams do not override WriteByte, so each of those calls allocates
            // a single-element array -- six million of them for one 1920x1080
            // frame, which costs far more than the compression itself.
            var row = new byte[1 + w * 3];
            using (var zs = new System.IO.Compression.ZLibStream(ms, System.IO.Compression.CompressionLevel.Optimal, true)) {
                for (int y = 0; y < h; y++) {
                    row[0] = 0;
                    int rowOff = y * w * 4;
                    int o = 1;
                    for (int x = 0; x < w; x++) {
                        int p = rowOff + x * 4;
                        row[o++] = bgra[p+2];
                        row[o++] = bgra[p+1];
                        row[o++] = bgra[p];
                    }
                    zs.Write(row, 0, row.Length);
                }
            }
            // ZLibStream emits the zlib header and the Adler-32 trailer itself,
            // and only flushes its final deflate block on dispose. Reading the
            // buffer before that produces a stream some decoders accept and
            // others reject outright -- so this must stay outside the using.
            WriteChunk(s, "IDAT", ms.ToArray());
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
    // Table-driven CRC: the IDAT chunk for one 1920x1080 frame is large enough
    // that a per-bit loop costs more than building this table once ever.
    static readonly uint[] CrcTable = BuildCrcTable();
    static uint[] BuildCrcTable() {
        var t = new uint[256];
        for (uint n = 0; n < 256; n++) {
            uint c = n;
            for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB88320 : c >> 1;
            t[n] = c;
        }
        return t;
    }
    static uint Crc32(byte[] type, byte[] data) {
        uint c = 0xFFFFFFFF;
        foreach (byte b in type) c = CrcTable[(c ^ b) & 0xFF] ^ (c >> 8);
        foreach (byte b in data) c = CrcTable[(c ^ b) & 0xFF] ^ (c >> 8);
        return c ^ 0xFFFFFFFF;
    }
}
"@
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_f06b7d9e3317cbea' -Arguments @{ value = "$_" })
    }

    # Imported only when its helper is missing: a forced import per frame re-read
    # the module on every poll of every wait.
    if (-not (Get-Command Initialize-YurunaLogDir -ErrorAction SilentlyContinue)) {
        Import-Module (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))) 'test/modules/Test.YurunaDir.psm1') -Global -ErrorAction SilentlyContinue -Verbose:$false
    }
    $debugDir = Join-Path (Initialize-YurunaLogDir) "Screenshot"
    if (-not (Test-Path $debugDir)) { New-Item -ItemType Directory -Force -Path $debugDir | Out-Null }

    # --- REGION: Primary: WMI GetVirtualSystemThumbnailImage
    try {
        $vmVideo = Hyper-V\Get-VMVideo -VMName $VMName -ErrorAction SilentlyContinue
        $reqW = $vmVideo ? [uint16]$vmVideo.HorizontalResolution : [uint16]1920
        $reqH = $vmVideo ? [uint16]$vmVideo.VerticalResolution : [uint16]1080
        # See https://yuruna.link/42e5cdfd-002b
        $thumbnailSizes = @(@{ Width = $reqW; Height = $reqH })
        foreach ($fallbackSize in @(@{ Width = 1024; Height = 768 }, @{ Width = 640; Height = 480 })) {
            if ($fallbackSize.Width -le $reqW -and $fallbackSize.Height -le $reqH -and
                ($fallbackSize.Width -lt $reqW -or $fallbackSize.Height -lt $reqH)) {
                $thumbnailSizes += $fallbackSize
            }
        }
        foreach ($size in $thumbnailSizes) {
            $captureW = [uint16]$size.Width
            $captureH = [uint16]$size.Height
            try {
                $bytes = Get-HyperVThumbnailByte -VMName $VMName -Width $captureW -Height $captureH
                if (-not $bytes) { continue }
                # See https://yuruna.link/42e5cdfd-002b
                if (-not $script:__YurunaHyperVBlankWarned -and
                    [HyperVCapture]::IsImageMostlyBlack(
                        [byte[]]$bytes, [int]$captureW, [int]$captureH, 0.99)) {
                    Write-Verbose "Hyper-V WMI thumbnail came back all-black for '$VMName' -- DWM is not painting the synthetic GPU (likely no monitor / RDP session on this host)."
                    Write-Verbose "See https://yuruna.link/monitorless"
                    $script:__YurunaHyperVBlankWarned = $true
                }
                $ok = [HyperVCapture]::SaveRawImageAsPng(
                    [byte[]]$bytes, [int]$captureW, [int]$captureH, $OutputPath)
                if ($ok -and (Test-Path $OutputPath)) {
                    # A duplicate of every frame, on a path polled for the whole
                    # length of a wait. Its value is comparing this capture with
                    # the fallback's, which only matters while debugging -- and
                    # a locked destination here raises a non-terminating error
                    # into the transcript an operator is reading at the time.
                    if ($global:DebugPreference -ne 'SilentlyContinue') {
                        Copy-Item -Path $OutputPath -Destination (Join-Path $debugDir "wmi_full.png") -Force
                    }
                    Write-Debug "Screenshot saved (WMI ${captureW}x${captureH}): $OutputPath"
                    return $OutputPath
                }
                [System.IO.File]::WriteAllText((Join-Path $debugDir "wmi_debug.txt"),
                    "size=${captureW}x${captureH} dataLen=$($bytes.Length) expected16=$(${captureW}*${captureH}*2) expected24=$(${captureW}*${captureH}*3) expected32=$(${captureW}*${captureH}*4)")
            } catch {
                Write-Verbose "Hyper-V WMI thumbnail ${captureW}x${captureH} failed for '$VMName': $($_.Exception.Message)"
            }
        }
        [System.IO.File]::WriteAllText((Join-Path $debugDir "wmi_debug.txt"), "No usable WMI thumbnail at configured ${reqW}x${reqH} or smaller fallback sizes.")
    } catch {
        [System.IO.File]::WriteAllText((Join-Path $debugDir "wmi_debug.txt"), "exception: $_")
    }

    # --- REGION: Fallback: PrintWindow via vmconnect window
    try {
        [HyperVCapture]::EnsureDpiAware()
        $hWnd = [HyperVCapture]::FindWindow($VMName)
        if ($hWnd -eq [IntPtr]::Zero) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_54ea5d7934b12c17' -Arguments @{ vMName = "$VMName" })
            return $null
        }
        $dpi = [HyperVCapture]::GetDpiForWindow($hWnd)
        $ok = [HyperVCapture]::CaptureToFile($hWnd, $OutputPath)
        if ($ok -and (Test-Path $OutputPath)) {
            # Gated for the same reason as the WMI branch above. Both are gated
            # rather than just one: this host takes the fallback path whenever
            # the WMI thumbnail comes back empty, so gating only the primary
            # would leave the duplicate running on the branch that is actually
            # hot while losing the comparison the pair exists to provide.
            if ($global:DebugPreference -ne 'SilentlyContinue') {
                Copy-Item -Path $OutputPath -Destination (Join-Path $debugDir "printwindow_full.png") -Force
            }
            $imgSize = (Get-Item $OutputPath).Length
            [System.IO.File]::WriteAllText((Join-Path $debugDir "printwindow_debug.txt"),
                "dpi=$dpi fileSize=$imgSize")
            Write-Debug "Screenshot saved (PrintWindow): $OutputPath"
            return $OutputPath
        }
    } catch {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_76032954131178ae' -Arguments @{ value = "$_" })
    }
    Write-Error (Format-YurunaOperatorMessage -Key 'host.operator_46fe17589543a111' -Arguments @{ vMName = "$VMName" })
    return $null
}

function Get-HyperVWindowScreenshot {
    <#
    .SYNOPSIS
        Captures the vmconnect client area via PrintWindow and returns hWnd
        + dimensions. Used by click-by-OCR -- the WMI thumbnail path from
        Get-HyperVScreenshot does NOT share vmconnect's coord space.
    .OUTPUTS
        Hashtable @{ ImagePath; HWnd; Width; Height } on success, or $null.
    #>
    param([string]$VMName, [string]$OutputPath)
    if (-not ('HyperVCapture' -as [type])) {
        $warmupPath = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna_warmup_${VMName}.png"
        Get-HyperVScreenshot -VMName $VMName -OutputPath $warmupPath | Out-Null
        Remove-Item $warmupPath -Force -ErrorAction SilentlyContinue
    }
    if (-not ('HyperVCapture' -as [type])) {
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_cf8e95c1480fece8')
        return $null
    }
    try {
        [HyperVCapture]::EnsureDpiAware()
        $hWnd = [HyperVCapture]::FindWindow($VMName)
        if ($hWnd -eq [IntPtr]::Zero) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_4b760cb1106fa1f1' -Arguments @{ vMName = "$VMName" })
            return $null
        }
        $ok = [HyperVCapture]::CaptureToFile($hWnd, $OutputPath)
        if (-not $ok -or -not (Test-Path $OutputPath)) {
            Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_0481de2c867ab7b9' -Arguments @{ vMName = "$VMName" })
            return $null
        }
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
        Write-Warning (Format-YurunaOperatorMessage -Key 'host.operator_b87fb2bbf66827b8' -Arguments @{ value = "$_" })
        return $null
    }
}
