<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456717
.AUTHOR Alisson Sol
.COPYRIGHT Copyright (c) 2019-2026 by Alisson Sol et al.
.DESCRIPTION Diff-based OCR text extraction. Pure C# image processing (no System.Drawing dependencies). Requires PowerShell 7+ (.NET 10+).
#>

#requires -version 7

# --- Tracing ---
# Set $env:NEWTEXT_TRACE = '1' to enable timing output, or call Enable-NewTextTrace / Disable-NewTextTrace.
$script:Trace = ($env:NEWTEXT_TRACE -eq '1')

# --- Vertical line removal ---
# Percentage of full screen height: vertical runs longer than this are considered UI borders.
# Override via $env:NEWTEXT_VLINE_PCT (default: 10).
$script:VLinePercent = $env:NEWTEXT_VLINE_PCT ? [int]$env:NEWTEXT_VLINE_PCT : 10

function Enable-NewTextTrace {
    <#
    .SYNOPSIS
        Enables trace output for Get-NewText operations.
    #>
    $script:Trace = $true
}
function Disable-NewTextTrace {
    <#
    .SYNOPSIS
        Disables trace output for Get-NewText operations.
    #>
    $script:Trace = $false
}

function Write-Trace {
    param([string]$Message, [System.Diagnostics.Stopwatch]$Stopwatch)
    if ($script:Trace) {
        $elapsed = $Stopwatch ? (" [{0:N0}ms]" -f $Stopwatch.Elapsed.TotalMilliseconds) : ''
        Write-Information "[TRACE]$elapsed $Message"
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

    /// <summary>
    /// Converts an image to grayscale in-place using luminance weights.
    /// Improves OCR accuracy on colored text (e.g. green-on-red prompts).
    /// </summary>
    public static void ToGrayscale(RawImage img)
    {
        byte[] px = img.Pixels;
        int len = img.Width * img.Height;
        int stride = img.Stride;
        for (int y = 0; y < img.Height; y++)
        {
            int rowOff = y * stride;
            for (int x = 0; x < img.Width; x++)
            {
                int i = rowOff + (x << 2);
                // ITU-R BT.601 luminance: 0.299R + 0.587G + 0.114B
                byte gray = (byte)((px[i] * 77 + px[i + 1] * 150 + px[i + 2] * 29) >> 8);
                px[i] = gray;
                px[i + 1] = gray;
                px[i + 2] = gray;
                // alpha unchanged
            }
        }
    }

    /// <summary>
    /// Inverts RGB channels in-place (255 - value). Converts light-on-dark terminal
    /// screenshots to dark-on-light, which OCR engines handle much better.
    /// </summary>
    public static void InvertColors(RawImage img)
    {
        byte[] px = img.Pixels;
        int stride = img.Stride;
        for (int y = 0; y < img.Height; y++)
        {
            int rowOff = y * stride;
            for (int x = 0; x < img.Width; x++)
            {
                int i = rowOff + (x << 2);
                px[i]     = (byte)(255 - px[i]);
                px[i + 1] = (byte)(255 - px[i + 1]);
                px[i + 2] = (byte)(255 - px[i + 2]);
            }
        }
    }

    /// <summary>
    /// Stretches contrast in-place so the darkest pixel maps to 0 and the
    /// brightest maps to 255.  Operates on grayscale images (R=G=B).
    /// </summary>
    public static void StretchContrast(RawImage img)
    {
        byte[] px = img.Pixels;
        int stride = img.Stride;
        byte min = 255, max = 0;
        for (int y = 0; y < img.Height; y++)
        {
            int rowOff = y * stride;
            for (int x = 0; x < img.Width; x++)
            {
                byte v = px[rowOff + (x << 2)];
                if (v < min) min = v;
                if (v > max) max = v;
            }
        }
        if (max <= min) return;
        int range = max - min;
        for (int y = 0; y < img.Height; y++)
        {
            int rowOff = y * stride;
            for (int x = 0; x < img.Width; x++)
            {
                int i = rowOff + (x << 2);
                byte v = (byte)((px[i] - min) * 255 / range);
                px[i] = v; px[i + 1] = v; px[i + 2] = v;
            }
        }
    }

    /// <summary>
    /// Converts a grayscale image to pure black and white in-place using
    /// Otsu's threshold method.  Pixels above the threshold become 255 (white),
    /// pixels at or below become 0 (black).  Produces crisp edges for OCR.
    /// </summary>
    public static void ThresholdBW(RawImage img)
    {
        byte[] px = img.Pixels;
        int stride = img.Stride;
        int total = img.Width * img.Height;

        // Build histogram
        int[] hist = new int[256];
        for (int y = 0; y < img.Height; y++)
        {
            int rowOff = y * stride;
            for (int x = 0; x < img.Width; x++)
                hist[px[rowOff + (x << 2)]]++;
        }

        // Otsu's method: find threshold that maximises between-class variance
        long sumAll = 0;
        for (int i = 0; i < 256; i++) sumAll += (long)i * hist[i];

        long sumBg = 0;
        int wBg = 0;
        double bestVariance = 0;
        int bestThreshold = 0;
        for (int t = 0; t < 256; t++)
        {
            wBg += hist[t];
            if (wBg == 0) continue;
            int wFg = total - wBg;
            if (wFg == 0) break;
            sumBg += (long)t * hist[t];
            double meanBg = (double)sumBg / wBg;
            double meanFg = (double)(sumAll - sumBg) / wFg;
            double diff = meanBg - meanFg;
            double variance = diff * diff * wBg * wFg;
            if (variance > bestVariance)
            {
                bestVariance = variance;
                bestThreshold = t;
            }
        }

        // Apply threshold
        for (int y = 0; y < img.Height; y++)
        {
            int rowOff = y * stride;
            for (int x = 0; x < img.Width; x++)
            {
                int i = rowOff + (x << 2);
                byte v = px[i] > bestThreshold ? (byte)255 : (byte)0;
                px[i] = v; px[i + 1] = v; px[i + 2] = v;
            }
        }
    }

    /// <summary>
    /// Scales an image by 2x using nearest-neighbour interpolation.
    /// More pixels give OCR engines more detail to work with.
    /// </summary>
    public static RawImage Scale2x(RawImage src)
    {
        int dstW = src.Width * 2;
        int dstH = src.Height * 2;
        var dst = new RawImage(dstW, dstH);
        byte[] sp = src.Pixels, dp = dst.Pixels;
        int srcStride = src.Stride, dstStride = dst.Stride;

        for (int y = 0; y < src.Height; y++)
        {
            int srcRow = y * srcStride;
            int dstRow0 = (y * 2) * dstStride;
            int dstRow1 = dstRow0 + dstStride;
            for (int x = 0; x < src.Width; x++)
            {
                int si = srcRow + (x << 2);
                int di0 = dstRow0 + (x << 3); // x*2*4
                int di1 = dstRow1 + (x << 3);
                byte r = sp[si], g = sp[si + 1], b = sp[si + 2], a = sp[si + 3];
                // Top-left
                dp[di0] = r; dp[di0 + 1] = g; dp[di0 + 2] = b; dp[di0 + 3] = a;
                // Top-right
                dp[di0 + 4] = r; dp[di0 + 5] = g; dp[di0 + 6] = b; dp[di0 + 7] = a;
                // Bottom-left
                dp[di1] = r; dp[di1 + 1] = g; dp[di1 + 2] = b; dp[di1 + 3] = a;
                // Bottom-right
                dp[di1 + 4] = r; dp[di1 + 5] = g; dp[di1 + 6] = b; dp[di1 + 7] = a;
            }
        }
        return dst;
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

# --- OCR engine (pluggable via Test.OcrEngine) ---

Import-Module (Join-Path $PSScriptRoot "Test.OcrEngine.psm1") -Force

function Invoke-PlatformOcr {
    <#
    .SYNOPSIS
        Runs the first enabled OCR provider on the given image.
        Kept for backward compatibility; new code should use Invoke-AllEnabledOcr.
    #>
    param([string]$ImagePath)
    $enabled = Get-EnabledOcrProvider
    if ($enabled.Count -eq 0) { throw "No OCR providers are available." }
    return Invoke-OcrProvider -Name $enabled[0] -ImagePath $ImagePath
}

# --- Public functions ---

function Get-ProcessedScreenImage {
    <#
    .SYNOPSIS
        Diffs current vs previous screen capture and produces a preprocessed image
        ready for OCR. Does NOT run OCR itself.

    .DESCRIPTION
        Performs the same image processing pipeline as Get-NewTextContent (pixel diff,
        vertical line removal, grayscale, invert, contrast stretch, 2x scale) but
        returns the path to the processed image instead of running OCR.

        This is the entry point for multi-engine OCR: call this once to get the
        processed image, then run each OCR provider on it via Invoke-AllEnabledOcr.

    .PARAMETER CurrentScreenPath
        Path to the current screen capture PNG file.

    .PARAMETER PreviousScreenPath
        Optional path to the previous screen capture PNG file.

    .OUTPUTS
        System.String. Path to the processed image ready for OCR, or empty string
        if no pixel changes were detected between frames.
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

    # Use global YurunaLog directory for debug artifacts
    Import-Module (Join-Path $PSScriptRoot "Test.LogDir.psm1") -Force -ErrorAction SilentlyContinue
    $debugDir = Join-Path (Get-YurunaLogDir) 'NewText'
    if (-not (Test-Path $debugDir)) {
        New-Item -ItemType Directory -Path $debugDir -Force | Out-Null
    }

    try {
        # Load current screen
        $currentImg = [PngCodec]::Load((Resolve-Path $CurrentScreenPath).Path)
        Write-Trace "Load current ($($currentImg.Width)x$($currentImg.Height))" $totalSw

        $width = $currentImg.Width
        $height = $currentImg.Height

        # Detect whether the screen changed (used to return early if nothing new)
        $hasChanges = $true
        if (-not [string]::IsNullOrEmpty($PreviousScreenPath)) {
            $previousImg = [PngCodec]::Load((Resolve-Path $PreviousScreenPath).Path)
            Write-Trace "Load previous ($($previousImg.Width)x$($previousImg.Height))" $totalSw

            if ($currentImg.Width -eq $previousImg.Width -and $currentImg.Height -eq $previousImg.Height) {
                # Remove thin vertical lines (e.g. cursors) before comparing
                $vlineThreshold = [int]($height * $script:VLinePercent / 100)
                $blankedCols = [ScreenDelta]::RemoveVerticalLines($currentImg, $previousImg,
                    $bgR, $bgG, $bgB, $bgA, $vlineThreshold)
                Write-Trace "Remove vertical lines (blanked=$blankedCols cols)" $totalSw

                $textImg = [RawImage]::new($width, $height)
                $delta = [ScreenDelta]::ProcessDelta($currentImg, $previousImg, $textImg,
                    $bgR, $bgG, $bgB, $bgA)
                $hasChanges = $delta.HasChanges
                Write-Trace "Pixel delta (hasChanges=$hasChanges)" $totalSw
            }
        }

        if (-not $hasChanges) {
            Write-Debug "No pixel changes detected between frames."
            if ($script:Trace) {
                [PngCodec]::Save($currentImg, (Join-Path $debugDir 'CurrentScreen.png'))
                [PngCodec]::Save($previousImg, (Join-Path $debugDir 'PreviousScreen.png'))
                Write-Trace "Debug artifacts saved (no changes)" $totalSw
            }
            '' | Set-Content -Path (Join-Path $debugDir 'OcrResult.txt') -Encoding UTF8
            Write-Trace "Total Get-ProcessedScreenImage (no changes)" $totalSw
            return ''
        }

        if (-not [string]::IsNullOrEmpty($PreviousScreenPath)) {
            # Preprocess for OCR: grayscale -> invert -> contrast stretch -> scale 2x
            $ocrImg = [RawImage]::new($width, $height, [byte[]]$currentImg.Pixels.Clone())
            [ScreenDelta]::ToGrayscale($ocrImg)
            [ScreenDelta]::InvertColors($ocrImg)
            [ScreenDelta]::StretchContrast($ocrImg)
            $ocrImg = [ScreenDelta]::Scale2x($ocrImg)
            Write-Trace "Preprocess for OCR ($($ocrImg.Width)x$($ocrImg.Height))" $totalSw

            # Save ProcessedTextScreen — this is the exact image sent to OCR
            $processedPath = Join-Path $debugDir 'ProcessedTextScreen.png'
            [PngCodec]::Save($ocrImg, $processedPath)
            Write-Trace "Save ProcessedTextScreen" $totalSw
        } else {
            # No previous screen — send current image directly to OCR without preprocessing
            $processedPath = (Resolve-Path $CurrentScreenPath).Path
            Write-Trace "No previous screen, using current image as-is" $totalSw
        }

        # Save debug artifacts when tracing
        if ($script:Trace) {
            [PngCodec]::Save($currentImg, (Join-Path $debugDir 'CurrentScreen.png'))
            if ($previousImg) {
                [PngCodec]::Save($previousImg, (Join-Path $debugDir 'PreviousScreen.png'))
            } else {
                $blankImg = [RawImage]::new($width, $height)
                $blankImg.Fill($bgR, $bgG, $bgB, $bgA)
                [PngCodec]::Save($blankImg, (Join-Path $debugDir 'PreviousScreen.png'))
            }
            Write-Trace "Debug artifacts saved" $totalSw
        }

        Write-Trace "Total Get-ProcessedScreenImage" $totalSw
        return $processedPath
    }
    catch {
        Write-Error "Get-ProcessedScreenImage failed: $_"
        throw
    }
}

function Get-NewTextContent {
    <#
    .SYNOPSIS
        Extracts new text from a screen capture by diffing against a previous frame and running OCR.

    .DESCRIPTION
        Convenience wrapper: calls Get-ProcessedScreenImage to produce the preprocessed
        image, then runs OCR on it using the first enabled provider.

        For multi-engine OCR, call Get-ProcessedScreenImage directly, then use
        Invoke-AllEnabledOcr from Test.OcrEngine.psm1.

    .PARAMETER CurrentScreenPath
        Path to the current screen capture PNG file.

    .PARAMETER PreviousScreenPath
        Optional path to the previous screen capture PNG file. If omitted, a blank
        background image is used as the reference, treating all content as new.

    .OUTPUTS
        System.String. The text extracted by OCR from the processed image.
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

    $processedPath = Get-ProcessedScreenImage -CurrentScreenPath $CurrentScreenPath -PreviousScreenPath $PreviousScreenPath
    if (-not $processedPath) { return '' }

    # Use global YurunaLog directory for debug artifacts
    Import-Module (Join-Path $PSScriptRoot "Test.LogDir.psm1") -Force -ErrorAction SilentlyContinue
    $debugDir = Join-Path (Get-YurunaLogDir) 'NewText'

    # OCR the image using the first enabled provider (backward-compatible)
    $ocrText = (Invoke-PlatformOcr -ImagePath $processedPath).Trim()
    Write-Trace "OCR ($($ocrText.Length) chars)" $totalSw

    # Save OCR output
    $ocrText | Set-Content -Path (Join-Path $debugDir 'OcrResult.txt') -Encoding UTF8
    Write-Trace "Total Get-NewTextContent" $totalSw

    return $ocrText
}

Export-ModuleMember -Function Get-ProcessedScreenImage, Get-NewTextContent, Enable-NewTextTrace, Disable-NewTextTrace
