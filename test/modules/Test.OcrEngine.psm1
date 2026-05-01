<#PSScriptInfo
.VERSION 0.1
.GUID 42b8c9d0-e1f2-4a34-b5c6-7d8e9f0a1b2c
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2019-2026 Alisson Sol et al.
.TAGS Test.OcrEngine
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

<#
.SYNOPSIS
    Pluggable OCR engine registry. Enables running multiple OCR providers on the
    same image and combining their results.

.DESCRIPTION
    Provides a provider pattern for OCR engines. Each provider is registered with
    a name, an invocation scriptblock (image path -> text), and an availability
    check. Built-in providers: tesseract, winrt (Windows), macos-vision (macOS).

    Configuration:
      $env:YURUNA_OCR_ENGINES  — comma-separated list of provider names to enable.
                                  Default: "tesseract"
                                  Example: "tesseract,winrt"

    The combine mode for multi-engine results is controlled separately by the
    caller (see Wait-ForText in Invoke-Sequence.psm1).
#>

# ── Provider registry ───────────────────────────────────────────────────────

$script:OcrProviders = [ordered]@{}

function Register-OcrProvider {
    <#
    .SYNOPSIS
        Registers an OCR provider with the engine registry.
    .PARAMETER Name
        Unique name for this provider (e.g. 'tesseract', 'winrt', 'macos-vision').
    .PARAMETER Invoke
        Scriptblock that takes a single string parameter (image path) and returns
        the recognized text as a string.
    .PARAMETER IsAvailable
        Scriptblock that returns $true if this provider can run on the current platform.
    #>
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [scriptblock]$Invoke,
        [Parameter(Mandatory)] [scriptblock]$IsAvailable
    )
    $script:OcrProviders[$Name] = @{
        Name        = $Name
        Invoke      = $Invoke
        IsAvailable = $IsAvailable
    }
}

function Get-OcrProviderName {
    <#
    .SYNOPSIS
        Returns the names of all registered OCR providers.
    #>
    return @($script:OcrProviders.Keys)
}

function Test-OcrProviderAvailable {
    <#
    .SYNOPSIS
        Tests whether a named OCR provider is available on the current platform.
    #>
    param([Parameter(Mandatory)] [string]$Name)
    $provider = $script:OcrProviders[$Name]
    if (-not $provider) { return $false }
    return [bool](& $provider.IsAvailable)
}

function Invoke-OcrProvider {
    <#
    .SYNOPSIS
        Runs a single named OCR provider on an image and returns the recognized text.
    #>
    param(
        [Parameter(Mandatory)] [string]$Name,
        [Parameter(Mandatory)] [string]$ImagePath
    )
    $provider = $script:OcrProviders[$Name]
    if (-not $provider) { throw "OCR provider '$Name' is not registered." }
    return (& $provider.Invoke $ImagePath)
}

function Get-EnabledOcrProvider {
    <#
    .SYNOPSIS
        Returns the list of OCR provider names that are enabled via configuration
        AND available on the current platform.
    .DESCRIPTION
        Reads $env:YURUNA_OCR_ENGINES (comma-separated). Defaults to "tesseract".
        Filters out providers that are not available on the current platform.
    #>
    $envVal = $env:YURUNA_OCR_ENGINES
    $requested = if ($envVal) {
        $envVal -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    } else {
        @('tesseract', 'winrt', 'macos-vision')  # default order of preference
    }

    $available = @()
    foreach ($name in $requested) {
        if (Test-OcrProviderAvailable $name) {
            $available += $name
        } else {
            Write-Verbose "OCR provider '$name' not available on this platform — skipping."
        }
    }
    return $available
}

function Invoke-AllEnabledOcr {
    <#
    .SYNOPSIS
        Runs all enabled OCR providers on the given image.
    .DESCRIPTION
        Returns an ordered hashtable: provider-name -> recognized text.
        Providers that fail are logged and their entry is set to empty string.
    .PARAMETER ImagePath
        Path to the image file to OCR.
    .OUTPUTS
        System.Collections.Specialized.OrderedDictionary. Keys are provider names,
        values are the recognized text (string).
    #>
    param([Parameter(Mandatory)] [string]$ImagePath)

    $results = [ordered]@{}
    foreach ($name in (Get-EnabledOcrProvider)) {
        try {
            $results[$name] = Invoke-OcrProvider -Name $name -ImagePath $ImagePath
        } catch {
            Write-Warning "OCR provider '$name' failed: $_"
            $results[$name] = ''
        }
    }
    return $results
}

# ── Built-in provider: Tesseract ────────────────────────────────────────────

Import-Module (Join-Path $PSScriptRoot "Test.Tesseract.psm1") -Force -Verbose:$false

Register-OcrProvider -Name 'tesseract' `
    -Invoke {
        param([string]$ImagePath)
        Invoke-TesseractOcr -ImagePath $ImagePath
    } `
    -IsAvailable {
        [bool](Find-Tesseract)
    }

# ── Built-in provider: WinRT (Windows only, via powershell.exe 5.1) ────────
# Windows.Media.Ocr is available on all Windows 10+ machines but requires
# PowerShell 5.1 (powershell.exe) because .NET 6+ removed WinRT projection.

function Invoke-WinRtOcr {
    <#
    .SYNOPSIS
        Runs Windows.Media.Ocr on an image by shelling out to powershell.exe (5.1).
    .PARAMETER ImagePath
        Path to a PNG image file.
    .OUTPUTS
        System.String. The recognized text.
    #>
    param([Parameter(Mandatory)] [string]$ImagePath)

    $absPath = (Resolve-Path $ImagePath).Path

    # The OCR script runs inside Windows PowerShell 5.1 which still has WinRT interop.
    $ocrScript = @'
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

[Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
$rawBitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
$bitmap = [Windows.Graphics.Imaging.SoftwareBitmap]::Convert(
    $rawBitmap,
    [Windows.Graphics.Imaging.BitmapPixelFormat]::Bgra8,
    [Windows.Graphics.Imaging.BitmapAlphaMode]::Premultiplied)

$ocrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
if (-not $ocrEngine) { throw 'WinRT OcrEngine not available' }
$ocrResult = Await ($ocrEngine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])

foreach ($line in $ocrResult.Lines) {
    $line.Text
}
'@

    $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) "yuruna_winrt_ocr_$([System.IO.Path]::GetRandomFileName()).ps1"
    try {
        $ocrScript | Set-Content -Path $scriptFile -Encoding UTF8
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptFile $absPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errLines = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
            throw "WinRT OCR failed (exit $LASTEXITCODE): $errLines"
        }
        $text = ($output | Where-Object { $_ -is [string] }) -join "`n"
        return $text
    } finally {
        Remove-Item $scriptFile -Force -ErrorAction SilentlyContinue
    }
}

Register-OcrProvider -Name 'winrt' `
    -Invoke {
        param([string]$ImagePath)
        Invoke-WinRtOcr -ImagePath $ImagePath
    } `
    -IsAvailable {
        $IsWindows -and [bool](Get-Command powershell.exe -ErrorAction SilentlyContinue)
    }

# ── Built-in provider: macOS Vision framework ──────────────────────────────
# Uses Apple's Vision framework via Swift (VNRecognizeTextRequest).
# Available on macOS 10.15+ (Catalina and later).
#
# Two non-obvious things this Swift script does that a naive Vision call
# does NOT, both of which were silently breaking OCR on UTM screen
# captures of guest.ubuntu.server logins:
#
#  1. Find the densest text-content row cluster and crop to it.
#     UTM/screencapture screenshots are 2898x1698 with the actual login
#     text in only the top ~150 rows. Vision's text-region detector
#     fails entirely on images where the content fills <10% of the
#     vertical extent — it returns 0 observations on the full image
#     while finding all three lines on a tight crop. We compute lit-
#     pixel-per-row, skip a leading ALL-WHITE bar (UTM titlebar/chrome
#     when present), then pick the highest-total cluster of rows where
#     lit_count > 8, allowing gaps up to ~80 dark rows between cluster
#     members so a blank line between content lines doesn't split the
#     login prompt off from the Ubuntu banner above it.
#
#  2. Re-encode through PNG before handing to Vision.
#     macOS screencapture writes images tagged with kCGColorSpaceDisplayP3
#     and 144 DPI. Vision's text detector returns 0 observations on
#     full-frame DisplayP3 images that it reads cleanly when the same
#     pixels arrive tagged sRGB at 72 DPI. CGImageDestination/PNG round-
#     trip strips both tags. (The previous "2x upscale via CGContext"
#     branch silently never ran — the original CGImage's bitmapInfo
#     combined with bytesPerRow=0 makes CGContext init return nil, so
#     the script fell through to the original CGImage every time.)
#
# Vision parameters: usesLanguageCorrection=false because the strings
# we care about (cloud-init banners, hostnames with dashes, "ttyl" vs
# "tty1") are not natural English; correction was actively rewriting
# them into garbage like "ttyl." -> "tty1.".

# The Swift source is stored once and reused across invocations.
$script:VisionOcrSwift = @'
import Vision
import AppKit
import CoreGraphics
import ImageIO

guard CommandLine.arguments.count > 1 else { exit(1) }
let imagePath = CommandLine.arguments[1]

guard let image = NSImage(contentsOfFile: imagePath),
      let tiff  = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let original = bitmap.cgImage else {
    fputs("Failed to load image: \(imagePath)\n", stderr)
    exit(1)
}

// ── 1. Per-row lit-pixel count (luma > 96) ────────────────────────────────
let w = bitmap.pixelsWide, h = bitmap.pixelsHigh
let bpp = bitmap.bitsPerPixel, bpr = bitmap.bytesPerRow
guard let data = bitmap.bitmapData else {
    fputs("bitmapData nil — cannot find content cluster\n", stderr); exit(1)
}
let pxBytes = bpp / 8
var litPerRow = [Int](repeating: 0, count: h)
for y in 0..<h {
    let row = data + y * bpr
    var c = 0
    for x in 0..<w {
        let p = row + x * pxBytes
        if max(p[0], max(p[1], p[2])) > 96 { c += 1 }
    }
    litPerRow[y] = c
}

// Skip a leading "all-white" bar (UTM toolbar / window chrome when the
// capture includes it). Threshold 90% of width AT high luma rejects normal
// text rows and accepts only solid lit stripes.
var topSkip = 0
for y in 0..<h {
    if litPerRow[y] > Int(Double(w) * 0.9) { topSkip = y + 1 } else { break }
}

// ── 2. Cluster rows with > 8 lit pixels, gap up to ~80 dark rows ───────────
// 80 px ≈ 2 line-heights at this resolution; allows blank lines between
// content lines (login prompt below "Ubuntu 24.04..." banner) to stay in
// the same cluster, but separates content from later artifacts (cursor,
// status bar) hundreds of rows away.
let minRowLit = 8
let maxGap    = 80
var clusters: [(start: Int, end: Int, total: Int)] = []
var cs = -1, ce = -1, ct = 0, gap = 0
for y in topSkip..<h {
    if litPerRow[y] > minRowLit {
        if cs < 0 { cs = y }
        ce = y; ct += litPerRow[y]; gap = 0
    } else if cs >= 0 {
        gap += 1
        if gap > maxGap {
            clusters.append((cs, ce, ct))
            cs = -1; ce = -1; ct = 0; gap = 0
        }
    }
}
if cs >= 0 { clusters.append((cs, ce, ct)) }

guard let best = clusters.max(by: { $0.total < $1.total }) else {
    // No content — exit cleanly with no output.
    exit(0)
}

// ── 3. Crop to the densest cluster, padded ───────────────────────────────
// CGImage.cropping uses image-data (top-left) origin, NOT the bottom-left
// CGContext origin used elsewhere in CG. Mixing the two conventions
// produces bottom-of-image crops where the caller meant top-of-image,
// and Vision then sees a black tile and returns 0 obs.
let pad = 16
let cropY0 = max(0, best.start - pad)
let cropH  = min(h - cropY0, (best.end - cropY0) + pad + 1)
let cropped = original.cropping(to: CGRect(x: 0, y: cropY0, width: w, height: cropH))!

// ── 4. PNG round-trip: strip DisplayP3 + 144 DPI metadata ────────────────
// macOS screencapture writes DisplayP3-tagged 144-DPI PNGs. Vision's text
// detector is reliable on sRGB/72-DPI inputs but returns 0 observations
// on the wide-gamut originals — empirically, on every UTM screen capture
// of the login prompt — so we route through CGImageDestination to drop
// both tags. Use a per-PID temp path so concurrent OCR runs don't clobber
// each other's intermediate file.
let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("yuruna-vision-\(getpid())-\(UUID().uuidString).png")
defer { try? FileManager.default.removeItem(at: tmpURL) }
let dest = CGImageDestinationCreateWithURL(tmpURL as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, cropped, nil)
CGImageDestinationFinalize(dest)
let reload = CGImageSourceCreateWithURL(tmpURL as CFURL, nil)!
let cleanCG = CGImageSourceCreateImageAtIndex(reload, 0, nil)!

// ── 5. OCR ────────────────────────────────────────────────────────────────
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
// usesLanguageCorrection = false: terminal text (hostnames, cloud-init
// timestamps, "ttyl"/"tty1", "@/0/1" punctuation) is not natural language.
// Language correction was actively rewriting valid OCR into nonsense and
// was the single most expensive accuracy hit on the engine.
request.usesLanguageCorrection = false
request.recognitionLanguages = ["en-US"]

let handler = VNImageRequestHandler(cgImage: cleanCG)
try handler.perform([request])

guard let observations = request.results, !observations.isEmpty else { exit(0) }

// Sort top-to-bottom, group into rows, then left-to-right within each row.
struct TextFragment {
    let text: String
    let x: CGFloat   // left edge (0..1)
    let y: CGFloat   // top edge (1 - bottomY - height; smaller = higher on screen)
    let h: CGFloat
}
var fragments: [TextFragment] = []
for obs in observations {
    guard let cand = obs.topCandidates(1).first else { continue }
    let b = obs.boundingBox
    let topY = 1.0 - b.origin.y - b.size.height
    fragments.append(TextFragment(text: cand.string, x: b.origin.x, y: topY, h: b.size.height))
}
fragments.sort { $0.y < $1.y }

let heights = fragments.map { $0.h }.sorted()
let medianH = heights[heights.count / 2]
let tolerance = max(medianH * 0.5, 0.005)

var rows: [[TextFragment]] = [[fragments[0]]]
var curY = fragments[0].y
for i in 1..<fragments.count {
    let f = fragments[i]
    if abs(f.y - curY) <= tolerance {
        rows[rows.count - 1].append(f)
    } else {
        rows.append([f]); curY = f.y
    }
}
for row in rows {
    print(row.sorted { $0.x < $1.x }.map { $0.text }.joined(separator: " "))
}
'@

function Invoke-MacVisionOcr {
    <#
    .SYNOPSIS
        Runs Apple Vision framework text recognition on an image via Swift.
    .PARAMETER ImagePath
        Path to a PNG image file.
    .OUTPUTS
        System.String. The recognized text.
    #>
    param([Parameter(Mandatory)] [string]$ImagePath)

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

Register-OcrProvider -Name 'macos-vision' `
    -Invoke {
        param([string]$ImagePath)
        Invoke-MacVisionOcr -ImagePath $ImagePath
    } `
    -IsAvailable {
        $IsMacOS -and [bool](Get-Command swift -ErrorAction SilentlyContinue)
    }

# ── Exports ─────────────────────────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Register-OcrProvider'
    'Get-OcrProviderName'
    'Test-OcrProviderAvailable'
    'Invoke-OcrProvider'
    'Get-EnabledOcrProvider'
    'Invoke-AllEnabledOcr'
    'Invoke-WinRtOcr'
    'Invoke-MacVisionOcr'
)
