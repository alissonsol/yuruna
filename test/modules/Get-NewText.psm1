# Get-NewText.psm1
# VERSION: 0.1
# Pure C# image processing (no System.Drawing dependencies).
# Requires PowerShell 7+ (.NET 10+).

# --- Tracing ---
# Set $env:NEWTEXT_TRACE = '1' to enable timing output, or call Enable-NewTextTrace / Disable-NewTextTrace.
$script:Trace = ($env:NEWTEXT_TRACE -eq '1')

# --- Vertical line removal ---
# Percentage of full screen height: vertical runs longer than this are considered UI borders.
# Override via $env:NEWTEXT_VLINE_PCT (default: 10).
$script:VLinePercent = if ($env:NEWTEXT_VLINE_PCT) { [int]$env:NEWTEXT_VLINE_PCT } else { 10 }

function Enable-NewTextTrace  { $script:Trace = $true  }
function Disable-NewTextTrace { $script:Trace = $false }

function Write-Trace {
    param([string]$Message, [System.Diagnostics.Stopwatch]$Stopwatch)
    if ($script:Trace) {
        $elapsed = if ($Stopwatch) { " [{0:N0}ms]" -f $Stopwatch.Elapsed.TotalMilliseconds } else { '' }
        Write-Host "[TRACE]$elapsed $Message" -ForegroundColor DarkGray
    }
}

# --- C# image processing (compiled at module load) ---

$csharpSource = @'
using System;
using System.IO;
using System.IO.Compression;
using System.Text;

// Simple RGBA image container - no external dependencies
public class RawImage
{
    public readonly int Width;
    public readonly int Height;
    public readonly byte[] Pixels; // RGBA, 4 bytes per pixel, row-major
    public readonly int Stride;    // bytes per row = Width * 4

    public RawImage(int width, int height)
    {
        Width = width;
        Height = height;
        Stride = width * 4;
        Pixels = new byte[Stride * height];
    }

    public RawImage(int width, int height, byte[] pixels)
    {
        Width = width;
        Height = height;
        Stride = width * 4;
        Pixels = pixels;
    }

    public void Fill(byte r, byte g, byte b, byte a)
    {
        for (int i = 0; i < Pixels.Length; i += 4)
        {
            Pixels[i] = r; Pixels[i + 1] = g;
            Pixels[i + 2] = b; Pixels[i + 3] = a;
        }
    }
}

// Pure C# PNG codec - reads and writes PNG files using only System.IO.Compression.
// Supports 8-bit grayscale, RGB, palette, gray+alpha, and RGBA input.
// Always writes 8-bit RGBA output.
public static class PngCodec
{
    private static readonly byte[] Signature = { 137, 80, 78, 71, 13, 10, 26, 10 };
    private static readonly uint[] CrcTable;

    static PngCodec()
    {
        CrcTable = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            uint c = n;
            for (int k = 0; k < 8; k++)
                c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            CrcTable[n] = c;
        }
    }

    public static RawImage Load(string path)
    {
        byte[] file = File.ReadAllBytes(path);
        if (file.Length < 8)
            throw new InvalidDataException("File too small to be PNG: " + path);
        for (int i = 0; i < 8; i++)
            if (file[i] != Signature[i])
                throw new InvalidDataException("Not a PNG file: " + path);

        int width = 0, height = 0, bitDepth = 0, colorType = 0;
        byte[] palette = null;
        byte[] trns = null;

        using (var idatStream = new MemoryStream())
        {
            int pos = 8;
            while (pos + 12 <= file.Length)
            {
                uint chunkLen = ReadU32(file, pos);
                string type = Encoding.ASCII.GetString(file, pos + 4, 4);
                int dataStart = pos + 8;

                switch (type)
                {
                    case "IHDR":
                        width = (int)ReadU32(file, dataStart);
                        height = (int)ReadU32(file, dataStart + 4);
                        bitDepth = file[dataStart + 8];
                        colorType = file[dataStart + 9];
                        if (bitDepth != 8)
                            throw new NotSupportedException(
                                "Only 8-bit PNG supported, got " + bitDepth + "-bit");
                        if (file[dataStart + 12] != 0)
                            throw new NotSupportedException("Interlaced PNG not supported");
                        break;
                    case "PLTE":
                        palette = new byte[chunkLen];
                        Buffer.BlockCopy(file, dataStart, palette, 0, (int)chunkLen);
                        break;
                    case "tRNS":
                        trns = new byte[chunkLen];
                        Buffer.BlockCopy(file, dataStart, trns, 0, (int)chunkLen);
                        break;
                    case "IDAT":
                        idatStream.Write(file, dataStart, (int)chunkLen);
                        break;
                    case "IEND":
                        goto doneChunks;
                }
                pos = dataStart + (int)chunkLen + 4; // skip CRC
            }
            doneChunks:

            byte[] compressed = idatStream.ToArray();
            if (compressed.Length < 2)
                throw new InvalidDataException("No IDAT data in PNG");

            int channels;
            switch (colorType)
            {
                case 0: channels = 1; break;
                case 2: channels = 3; break;
                case 3: channels = 1; break;
                case 4: channels = 2; break;
                case 6: channels = 4; break;
                default: throw new NotSupportedException("PNG color type " + colorType);
            }

            int bpp = channels;
            int rawRowLen = width * bpp;
            int filterRowLen = 1 + rawRowLen;
            byte[] raw = new byte[filterRowLen * height];

            // Decompress: skip 2-byte zlib header
            using (var ms = new MemoryStream(compressed, 2, compressed.Length - 2))
            using (var ds = new DeflateStream(ms, CompressionMode.Decompress))
            {
                int total = 0;
                while (total < raw.Length)
                {
                    int n = ds.Read(raw, total, raw.Length - total);
                    if (n == 0) break;
                    total += n;
                }
            }

            // Apply row filters and convert to RGBA
            byte[] pixels = new byte[width * height * 4];
            byte[] prevRow = new byte[rawRowLen];
            byte[] curRow = new byte[rawRowLen];

            for (int y = 0; y < height; y++)
            {
                int fOff = y * filterRowLen;
                byte fType = raw[fOff];
                Buffer.BlockCopy(raw, fOff + 1, curRow, 0, rawRowLen);

                for (int i = 0; i < rawRowLen; i++)
                {
                    byte a = i >= bpp ? curRow[i - bpp] : (byte)0;
                    byte b = prevRow[i];
                    byte c = i >= bpp ? prevRow[i - bpp] : (byte)0;
                    switch (fType)
                    {
                        case 1: curRow[i] += a; break;
                        case 2: curRow[i] += b; break;
                        case 3: curRow[i] += (byte)((a + b) / 2); break;
                        case 4: curRow[i] += Paeth(a, b, c); break;
                    }
                }

                int outOff = y * width * 4;
                for (int x = 0; x < width; x++)
                {
                    int si = x * bpp;
                    int di = outOff + x * 4;
                    switch (colorType)
                    {
                        case 0: // Grayscale
                            pixels[di] = pixels[di + 1] = pixels[di + 2] = curRow[si];
                            pixels[di + 3] = 255;
                            break;
                        case 2: // RGB
                            pixels[di] = curRow[si];
                            pixels[di + 1] = curRow[si + 1];
                            pixels[di + 2] = curRow[si + 2];
                            pixels[di + 3] = 255;
                            break;
                        case 3: // Palette
                            int idx = curRow[si];
                            pixels[di] = palette[idx * 3];
                            pixels[di + 1] = palette[idx * 3 + 1];
                            pixels[di + 2] = palette[idx * 3 + 2];
                            pixels[di + 3] = (trns != null && idx < trns.Length)
                                ? trns[idx] : (byte)255;
                            break;
                        case 4: // Gray+Alpha
                            pixels[di] = pixels[di + 1] = pixels[di + 2] = curRow[si];
                            pixels[di + 3] = curRow[si + 1];
                            break;
                        case 6: // RGBA
                            pixels[di] = curRow[si];
                            pixels[di + 1] = curRow[si + 1];
                            pixels[di + 2] = curRow[si + 2];
                            pixels[di + 3] = curRow[si + 3];
                            break;
                    }
                }

                byte[] tmp = prevRow; prevRow = curRow; curRow = tmp;
            }
            return new RawImage(width, height, pixels);
        }
    }

    public static void Save(RawImage img, string path)
    {
        using (var fs = new FileStream(path, FileMode.Create))
        using (var bw = new BinaryWriter(fs))
        {
            bw.Write(Signature);

            // IHDR
            byte[] ihdr = new byte[13];
            WriteU32(ihdr, 0, (uint)img.Width);
            WriteU32(ihdr, 4, (uint)img.Height);
            ihdr[8] = 8; ihdr[9] = 6; // 8-bit RGBA
            WriteChunk(bw, "IHDR", ihdr);

            // IDAT: filter byte 0 (None) per row, then zlib compress
            int rowLen = img.Width * 4;
            byte[] raw = new byte[(1 + rowLen) * img.Height];
            for (int y = 0; y < img.Height; y++)
            {
                int rOff = y * (1 + rowLen);
                raw[rOff] = 0; // filter: None
                Buffer.BlockCopy(img.Pixels, y * rowLen, raw, rOff + 1, rowLen);
            }

            byte[] compressed;
            using (var ms = new MemoryStream())
            {
                ms.WriteByte(0x78); ms.WriteByte(0x9C); // zlib header
                using (var ds = new DeflateStream(ms, CompressionLevel.Fastest, true))
                    ds.Write(raw, 0, raw.Length);
                // Adler32 checksum
                uint adler = Adler32(raw);
                ms.WriteByte((byte)(adler >> 24));
                ms.WriteByte((byte)(adler >> 16));
                ms.WriteByte((byte)(adler >> 8));
                ms.WriteByte((byte)adler);
                compressed = ms.ToArray();
            }

            WriteChunk(bw, "IDAT", compressed);
            WriteChunk(bw, "IEND", Array.Empty<byte>());
        }
    }

    // --- helpers ---

    private static byte Paeth(byte a, byte b, byte c)
    {
        int p = a + b - c;
        int pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
        if (pa <= pb && pa <= pc) return a;
        return pb <= pc ? b : c;
    }

    private static uint ReadU32(byte[] d, int o) =>
        (uint)(d[o] << 24 | d[o + 1] << 16 | d[o + 2] << 8 | d[o + 3]);

    private static void WriteU32(byte[] d, int o, uint v)
    {
        d[o] = (byte)(v >> 24); d[o + 1] = (byte)(v >> 16);
        d[o + 2] = (byte)(v >> 8); d[o + 3] = (byte)v;
    }

    private static void WriteChunk(BinaryWriter bw, string type, byte[] data)
    {
        byte[] tb = Encoding.ASCII.GetBytes(type);
        byte[] lb = new byte[4];
        WriteU32(lb, 0, (uint)data.Length);
        bw.Write(lb);
        bw.Write(tb);
        bw.Write(data);

        byte[] crcBuf = new byte[4 + data.Length];
        Buffer.BlockCopy(tb, 0, crcBuf, 0, 4);
        Buffer.BlockCopy(data, 0, crcBuf, 4, data.Length);
        uint crc = Crc32(crcBuf, 0, crcBuf.Length);
        byte[] cb = new byte[4];
        WriteU32(cb, 0, crc);
        bw.Write(cb);
    }

    private static uint Crc32(byte[] buf, int off, int len)
    {
        uint crc = 0xFFFFFFFF;
        for (int i = off; i < off + len; i++)
            crc = CrcTable[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFF;
    }

    private static uint Adler32(byte[] data)
    {
        uint a = 1, b = 0;
        for (int i = 0; i < data.Length; i++)
        {
            a = (a + data[i]) % 65521;
            b = (b + a) % 65521;
        }
        return (b << 16) | a;
    }
}

// Pixel-level image processing - works directly on RawImage byte arrays.
public static class ScreenDelta
{
    public struct DeltaResult
    {
        public int MinY;
        public int MaxY;
        public bool HasChanges;
    }

    /// <summary>
    /// Compares current and previous images pixel-by-pixel.
    /// Writes the delta into text: unchanged pixels become background,
    /// changed pixels keep their current value.
    /// Returns the vertical bounding box of changed rows for cropping.
    /// </summary>
    public static DeltaResult ProcessDelta(RawImage current, RawImage previous, RawImage text,
        byte bgR, byte bgG, byte bgB, byte bgA)
    {
        int width = current.Width;
        int height = current.Height;
        int stride = current.Stride;
        byte[] cur = current.Pixels;
        byte[] prev = previous.Pixels;
        byte[] txt = text.Pixels;

        int minY = height, maxY = -1;

        for (int y = 0; y < height; y++)
        {
            int rowOff = y * stride;
            bool changed = false;
            for (int x = 0; x < width; x++)
            {
                int i = rowOff + (x << 2);
                if (cur[i] == prev[i] && cur[i + 1] == prev[i + 1] &&
                    cur[i + 2] == prev[i + 2] && cur[i + 3] == prev[i + 3])
                {
                    txt[i] = bgR; txt[i + 1] = bgG;
                    txt[i + 2] = bgB; txt[i + 3] = bgA;
                }
                else
                {
                    txt[i] = cur[i]; txt[i + 1] = cur[i + 1];
                    txt[i + 2] = cur[i + 2]; txt[i + 3] = cur[i + 3];
                    changed = true;
                }
            }
            if (changed)
            {
                if (y < minY) minY = y;
                maxY = y;
            }
        }

        var r = new DeltaResult();
        r.HasChanges = (maxY >= 0);
        r.MinY = minY;
        r.MaxY = maxY;
        return r;
    }

    /// <summary>
    /// Crops an image to the specified row range (full width).
    /// </summary>
    public static RawImage Crop(RawImage src, int minY, int maxY)
    {
        int h = maxY - minY + 1;
        var dst = new RawImage(src.Width, h);
        Buffer.BlockCopy(src.Pixels, minY * src.Stride, dst.Pixels, 0, h * src.Stride);
        return dst;
    }

    /// <summary>
    /// Pads an image vertically (centered) if shorter than minHeight.
    /// Returns the original if already tall enough.
    /// </summary>
    public static RawImage PadIfNeeded(RawImage src, byte bgR, byte bgG, byte bgB, byte bgA,
        int minHeight)
    {
        if (src.Height >= minHeight) return src;
        int padTop = (minHeight - src.Height) / 2;
        var dst = new RawImage(src.Width, minHeight);
        dst.Fill(bgR, bgG, bgB, bgA);
        Buffer.BlockCopy(src.Pixels, 0, dst.Pixels, padTop * dst.Stride, src.Height * src.Stride);
        return dst;
    }

    /// <summary>
    /// Pre-processing: detects thin vertical line segments (e.g. cursors) in
    /// primary and blanks the same pixel positions in BOTH primary and secondary.
    /// A vertical line is a continuous run of non-background pixels that exceeds
    /// minRunLength AND whose left/right neighbors are mostly background.
    /// secondary may be null (only primary is modified).
    /// Returns the number of columns blanked.
    /// </summary>
    public static int RemoveVerticalLines(RawImage primary, RawImage secondary,
        byte bgR, byte bgG, byte bgB, byte bgA, int minRunLength)
    {
        int width = primary.Width;
        int height = primary.Height;
        int stride = primary.Stride;
        byte[] px = primary.Pixels;
        byte[] sx = secondary != null ? secondary.Pixels : null;

        int blanked = 0;

        for (int x = 0; x < width; x++)
        {
            int col = x << 2;
            int runStart = -1;
            bool colBlanked = false;

            for (int y = 0; y <= height; y++)
            {
                bool isBg;
                if (y < height)
                {
                    int i = y * stride + col;
                    isBg = (px[i] == bgR && px[i + 1] == bgG && px[i + 2] == bgB);
                }
                else
                {
                    isBg = true;
                }

                if (isBg)
                {
                    if (runStart >= 0 && (y - runStart) > minRunLength)
                    {
                        // Thin-line check: neighbors should be mostly background
                        bool isThin = true;
                        if (x > 0 && x < width - 1)
                        {
                            int nonBg = 0;
                            int runLen = y - runStart;
                            for (int ry = runStart; ry < y; ry++)
                            {
                                int li = ry * stride + ((x - 1) << 2);
                                int ri = ry * stride + ((x + 1) << 2);
                                if (px[li] != bgR || px[li + 1] != bgG || px[li + 2] != bgB)
                                    nonBg++;
                                if (px[ri] != bgR || px[ri + 1] != bgG || px[ri + 2] != bgB)
                                    nonBg++;
                            }
                            if (nonBg > runLen * 2 * 0.3)
                                isThin = false;
                        }

                        if (isThin)
                        {
                            for (int ry = runStart; ry < y; ry++)
                            {
                                int ri = ry * stride + col;
                                px[ri] = bgR; px[ri + 1] = bgG;
                                px[ri + 2] = bgB; px[ri + 3] = bgA;
                            }
                            if (sx != null)
                            {
                                for (int ry = runStart; ry < y; ry++)
                                {
                                    int ri = ry * stride + col;
                                    sx[ri] = bgR; sx[ri + 1] = bgG;
                                    sx[ri + 2] = bgB; sx[ri + 3] = bgA;
                                }
                            }
                            colBlanked = true;
                        }
                    }
                    runStart = -1;
                }
                else if (runStart < 0)
                {
                    runStart = y;
                }
            }
            if (colBlanked) blanked++;
        }
        return blanked;
    }
}
'@

# Resolve referenced assemblies for C# compilation.
# .NET 10+ splits types across assemblies; collect all that the C# code needs.
$referencedAssemblies = @(
    [System.IO.Compression.DeflateStream],
    [System.IO.MemoryStream],
    [System.IO.File],
    [System.IO.BinaryWriter],
    [System.Buffer],
    [System.Text.Encoding],
    [System.Math]
) | ForEach-Object { $_.Assembly.Location } |
    Where-Object { $_ -and (Test-Path $_) } |
    Select-Object -Unique

if (-not ([System.Management.Automation.PSTypeName]'PngCodec').Type) {
    Add-Type -Language CSharp -TypeDefinition $csharpSource -ReferencedAssemblies $referencedAssemblies
}

# --- OCR engines ---

# Windows: use WinRT Windows.Media.Ocr (same engine as Snipping Tool).
# Runs via powershell.exe (Windows PowerShell 5.1) which has native WinRT support.
# The OCR engine may detect columns and return fragments out of reading order,
# so we reconstruct lines by grouping words by Y position and sorting by X.
$script:WinRtOcrScript = @'
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                   $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

function Await($WinRtTask, $ResultType) {
    $asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
    $netTask = $asTask.Invoke($null, @($WinRtTask))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

[Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
[Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
[Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null

$imagePath = $args[0]
$file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($imagePath)) ([Windows.Storage.StorageFile])
$stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
$decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
$bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

$ocrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if (-not $ocrEngine) { throw 'WinRT OcrEngine not available' }
$ocrResult = Await ($ocrEngine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])

# Collect all words with their bounding rectangles
$allWords = @()
foreach ($line in $ocrResult.Lines) {
    foreach ($word in $line.Words) {
        $r = $word.BoundingRect
        $allWords += [PSCustomObject]@{ Text = $word.Text; X = $r.X; Y = $r.Y; H = $r.Height }
    }
}

if ($allWords.Count -eq 0) { return }

# Group words into rows by Y position (tolerance = half the median word height)
$sortedByY = $allWords | Sort-Object Y
$medianH = ($allWords | Sort-Object H)[[int]($allWords.Count / 2)].H
$tolerance = [Math]::Max($medianH * 0.5, 3)

$rows = @()
$currentRow = @($sortedByY[0])
$currentY = $sortedByY[0].Y

for ($i = 1; $i -lt $sortedByY.Count; $i++) {
    $w = $sortedByY[$i]
    if ([Math]::Abs($w.Y - $currentY) -le $tolerance) {
        $currentRow += $w
    } else {
        $rows += ,($currentRow | Sort-Object X)
        $currentRow = @($w)
        $currentY = $w.Y
    }
}
$rows += ,($currentRow | Sort-Object X)

# Output one line per row, words joined with spaces
foreach ($row in $rows) {
    ($row | ForEach-Object { $_.Text }) -join ' '
}
'@

# macOS: use Apple Vision framework via swift.
# Vision returns observations sorted by confidence; we re-sort by Y (top-to-bottom)
# then by X (left-to-right) within each row to get proper reading order.
$script:VisionOcrSwift = @'
import Vision
import AppKit

guard CommandLine.arguments.count > 1 else { exit(1) }
let imagePath = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: imagePath),
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let cgImage = bitmap.cgImage else {
    fputs("Failed to load image: \(imagePath)\n", stderr)
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true

let handler = VNImageRequestHandler(cgImage: cgImage)
try handler.perform([request])

guard let observations = request.results, !observations.isEmpty else { exit(0) }

// Vision uses bottom-left origin; sort by Y descending (top-to-bottom),
// then group into rows and sort left-to-right within each row.
struct TextFragment {
    let text: String
    let x: CGFloat  // left edge (0..1)
    let y: CGFloat  // top edge as 1-topY (higher = lower on screen)
    let h: CGFloat  // height
}

var fragments: [TextFragment] = []
for obs in observations {
    guard let candidate = obs.topCandidates(1).first else { continue }
    let box = obs.boundingBox
    let topY = 1.0 - box.origin.y - box.size.height
    fragments.append(TextFragment(text: candidate.string, x: box.origin.x, y: topY, h: box.size.height))
}

fragments.sort { $0.y < $1.y }

// Group into rows (tolerance = half median height)
let heights = fragments.map { $0.h }.sorted()
let medianH = heights[heights.count / 2]
let tolerance = max(medianH * 0.5, 0.005)

var rows: [[TextFragment]] = []
var currentRow: [TextFragment] = [fragments[0]]
var currentY = fragments[0].y

for i in 1..<fragments.count {
    let f = fragments[i]
    if abs(f.y - currentY) <= tolerance {
        currentRow.append(f)
    } else {
        rows.append(currentRow.sorted { $0.x < $1.x })
        currentRow = [f]
        currentY = f.y
    }
}
rows.append(currentRow.sorted { $0.x < $1.x })

for row in rows {
    print(row.map { $0.text }.joined(separator: " "))
}
'@

# --- OCR dispatch ---

function Invoke-PlatformOcr {
    param([string]$ImagePath)

    if ($IsWindows) {
        # WinRT OCR via Windows PowerShell 5.1 (has native WinRT support).
        $absPath = (Resolve-Path $ImagePath).Path
        $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) 'WinRtOcr.ps1'
        $script:WinRtOcrScript | Set-Content -Path $scriptFile -Encoding UTF8
        try {
            $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptFile $absPath 2>&1
            if ($LASTEXITCODE -ne 0) {
                $errMsg = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
                throw "WinRT OCR failed: $errMsg"
            }
            return ($output | Where-Object { $_ -is [string] }) -join "`n"
        } finally {
            if (Test-Path $scriptFile) { Remove-Item $scriptFile -Force }
        }
    }
    elseif ($IsMacOS) {
        # Apple Vision framework via swift
        $swiftFile = [System.IO.Path]::GetTempFileName() + '.swift'
        try {
            $script:VisionOcrSwift | Set-Content -Path $swiftFile -Encoding UTF8
            $output = & swift $swiftFile $ImagePath 2>&1
            if ($LASTEXITCODE -ne 0) {
                $errMsg = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
                throw "Vision OCR failed: $errMsg"
            }
            return ($output | Where-Object { $_ -is [string] }) -join "`n"
        } finally {
            if (Test-Path $swiftFile) { Remove-Item $swiftFile -Force }
        }
    }
    else {
        throw 'No built-in OCR engine available on Linux. This module supports Windows (WinRT) and macOS (Vision).'
    }
}

# --- Public function ---

function Get-NewTextContent {
    <#
    .SYNOPSIS
        Extracts new text from a screen capture by diffing against a previous frame and running OCR.

    .DESCRIPTION
        Compares two bitmap images pixel-by-pixel to isolate newly appeared content.
        Unchanged pixels are replaced with the background color, and the result is
        cropped to the bounding box of changed rows before being passed to OCR
        for text extraction.

        All image processing is done in compiled C# with a built-in PNG codec,
        requiring no external image libraries (no System.Drawing, etc.).

        Uses platform-native OCR for best accuracy:
        - Windows: Windows.Media.Ocr (WinRT, same engine as Snipping Tool)
        - macOS: Apple Vision framework (VNRecognizeTextRequest)

        Requires PowerShell 7+ (.NET 10+).

        Set $env:NEWTEXT_TRACE = '1' before importing, or call Enable-NewTextTrace,
        to enable timing output that shows where time is spent.

    .PARAMETER CurrentScreenPath
        Path to the current screen capture PNG file.

    .PARAMETER PreviousScreenPath
        Optional path to the previous screen capture PNG file. If omitted, a blank
        background image is used as the reference, treating all content as new.

    .OUTPUTS
        System.String. The text extracted by OCR from the processed image.

    .EXAMPLE
        Get-NewTextContent -CurrentScreenPath '.\screenshots\0002.png' -PreviousScreenPath '.\screenshots\0001.png'

    .EXAMPLE
        Get-NewTextContent -CurrentScreenPath '.\screenshots\0001.png'
    #>
    [CmdletBinding()]
    [OutputType([System.String])]
    param(
        [Parameter(Mandatory=$true)]
        [string]$CurrentScreenPath,

        [Parameter(Mandatory=$false)]
        [string]$PreviousScreenPath
    )

    $totalSw = [System.Diagnostics.Stopwatch]::StartNew()

    # Background color (RGBA)
    $bgR = [byte]0; $bgG = [byte]0; $bgB = [byte]0; $bgA = [byte]255  # Black

    # Cross-platform temp directory
    $tempRoot = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
    $debugDir = Join-Path $tempRoot 'NewText'
    if (-not (Test-Path $debugDir)) {
        New-Item -ItemType Directory -Path $debugDir -Force | Out-Null
    }

    try {
        # Load current screen
        $currentImg = [PngCodec]::Load((Resolve-Path $CurrentScreenPath).Path)
        Write-Trace "Load current ($($currentImg.Width)x$($currentImg.Height))" $totalSw

        $width = $currentImg.Width
        $height = $currentImg.Height

        # Load or create previous screen
        if ([string]::IsNullOrEmpty($PreviousScreenPath)) {
            Write-Debug "No previous screen provided; treating entire image as new."
            $ocrInputPath = Join-Path $debugDir 'ocr_input.png'
            [PngCodec]::Save($currentImg, $ocrInputPath)
            Write-Trace "No-diff: save full image for OCR" $totalSw

            $ocrText = (Invoke-PlatformOcr -ImagePath $ocrInputPath).Trim()
            Write-Trace "OCR ($($ocrText.Length) chars)" $totalSw

            if (Test-Path $ocrInputPath) { Remove-Item $ocrInputPath -Force }
            $ocrText | Set-Content -Path (Join-Path $debugDir 'OcrResult.txt') -Encoding UTF8
            Write-Trace "Total Get-NewTextContent" $totalSw
            return $ocrText
        }

        $previousImg = [PngCodec]::Load((Resolve-Path $PreviousScreenPath).Path)
        Write-Trace "Load previous ($($previousImg.Width)x$($previousImg.Height))" $totalSw

        if ($currentImg.Width -ne $previousImg.Width -or $currentImg.Height -ne $previousImg.Height) {
            throw "Image dimensions do not match. Current: ${width}x${height}, Previous: $($previousImg.Width)x$($previousImg.Height)."
        }

        # Pre-processing: remove thin vertical lines (e.g. cursors) from BOTH images
        # before computing the delta, so they never affect row-change detection.
        $vlineThreshold = [int]($height * $script:VLinePercent / 100)
        $blankedCols = [ScreenDelta]::RemoveVerticalLines($currentImg, $previousImg,
            $bgR, $bgG, $bgB, $bgA, $vlineThreshold)
        Write-Trace "Remove vertical lines (threshold=${vlineThreshold}px=$($script:VLinePercent)% of ${height}, blanked=$blankedCols cols)" $totalSw

        # Compute pixel delta
        $textImg = [RawImage]::new($width, $height)
        $delta = [ScreenDelta]::ProcessDelta($currentImg, $previousImg, $textImg,
            $bgR, $bgG, $bgB, $bgA)
        Write-Trace "Pixel delta" $totalSw

        if (-not $delta.HasChanges) {
            Write-Debug "No pixel changes detected between frames."
            '' | Set-Content -Path (Join-Path $debugDir 'OcrResult.txt') -Encoding UTF8
            Write-Trace "Total Get-NewTextContent (no changes)" $totalSw
            return ''
        }

        Write-Debug "Changes detected in rows $($delta.MinY)..$($delta.MaxY) of $height"

        # Crop current image to bounding box of changed rows
        $croppedImg = [ScreenDelta]::Crop($currentImg, $delta.MinY, $delta.MaxY)
        Write-Trace "Crop to $($croppedImg.Width)x$($croppedImg.Height)" $totalSw

        # Pad if too short for OCR
        $minOcrHeight = 80
        $croppedImg = [ScreenDelta]::PadIfNeeded($croppedImg, $bgR, $bgG, $bgB, $bgA, $minOcrHeight)
        Write-Trace "Pad check (now $($croppedImg.Width)x$($croppedImg.Height))" $totalSw

        # Save for OCR
        $ocrInputPath = Join-Path $debugDir 'ocr_input.png'
        [PngCodec]::Save($croppedImg, $ocrInputPath)
        Write-Trace "Save OCR input" $totalSw

        # Save debug artifacts only when tracing (PNG encoding is expensive)
        if ($script:Trace) {
            [PngCodec]::Save($currentImg, (Join-Path $debugDir 'CurrentScreen.png'))
            [PngCodec]::Save($previousImg, (Join-Path $debugDir 'PreviousScreen.png'))
            [PngCodec]::Save($croppedImg, (Join-Path $debugDir 'ProcessedTextScreen.png'))
            Write-Trace "Debug artifacts saved" $totalSw
        }

        # OCR the cropped current image
        $currentText = (Invoke-PlatformOcr -ImagePath $ocrInputPath).Trim()
        Write-Trace "OCR current ($($currentText.Length) chars)" $totalSw

        # Text-level diff: OCR the same region from previous, keep only new lines
        $ocrText = $currentText
        $prevCropPath = Join-Path $debugDir 'ocr_prev_crop.png'
        $prevCropImg = [ScreenDelta]::Crop($previousImg, $delta.MinY, $delta.MaxY)
        $prevCropImg = [ScreenDelta]::PadIfNeeded($prevCropImg, $bgR, $bgG, $bgB, $bgA, $minOcrHeight)
        [PngCodec]::Save($prevCropImg, $prevCropPath)

        $prevText = (Invoke-PlatformOcr -ImagePath $prevCropPath).Trim()
        Write-Trace "OCR previous ($($prevText.Length) chars)" $totalSw

        $prevLines = [System.Collections.Generic.HashSet[string]]::new(
            [string[]]($prevText -split "`n"), [System.StringComparer]::Ordinal)
        $newLines = @()
        foreach ($line in ($currentText -split "`n")) {
            if (-not $prevLines.Contains($line)) {
                $newLines += $line
            }
        }
        $ocrText = ($newLines -join "`n").Trim()
        Write-Trace "Text diff: $($newLines.Count) new lines" $totalSw

        Remove-Item $prevCropPath -Force -ErrorAction SilentlyContinue

        # Clean up
        if (Test-Path $ocrInputPath) { Remove-Item $ocrInputPath -Force }
        $ocrText | Set-Content -Path (Join-Path $debugDir 'OcrResult.txt') -Encoding UTF8

        Write-Trace "Total Get-NewTextContent" $totalSw

        return $ocrText
    }
    catch {
        Write-Error "Get-NewTextContent failed: $_"
        throw
    }
}

Export-ModuleMember -Function Get-NewTextContent, Enable-NewTextTrace, Disable-NewTextTrace
