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

function Get-OcrProviderNames {
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

function Get-EnabledOcrProviders {
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
        @('tesseract,winrt,macos-vision')  # default order of preference
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
    foreach ($name in (Get-EnabledOcrProviders)) {
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

Import-Module (Join-Path $PSScriptRoot "Test.Tesseract.psm1") -Force

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
# Vision returns observations sorted by confidence; the script re-sorts by Y
# (top-to-bottom) then by X (left-to-right) within each row for reading order.

# The Swift source is stored once and reused across invocations.
$script:VisionOcrSwift = @'
import Vision
import AppKit

guard CommandLine.arguments.count > 1 else { exit(1) }
let imagePath = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: imagePath),
      let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let originalCGImage = bitmap.cgImage else {
    fputs("Failed to load image: \(imagePath)\n", stderr)
    exit(1)
}

// Upscale 2x for better OCR of small terminal text.
let w = originalCGImage.width * 2
let h = originalCGImage.height * 2
let cgImage: CGImage
if let ctx = CGContext(data: nil, width: w, height: h,
                       bitsPerComponent: originalCGImage.bitsPerComponent,
                       bytesPerRow: 0,
                       space: originalCGImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: originalCGImage.bitmapInfo.rawValue) {
    ctx.interpolationQuality = .high
    ctx.draw(originalCGImage, in: CGRect(x: 0, y: 0, width: w, height: h))
    cgImage = ctx.makeImage() ?? originalCGImage
} else {
    cgImage = originalCGImage
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = true
request.recognitionLanguages = ["en-US"]

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
    'Get-OcrProviderNames'
    'Test-OcrProviderAvailable'
    'Invoke-OcrProvider'
    'Get-EnabledOcrProviders'
    'Invoke-AllEnabledOcr'
    'Invoke-WinRtOcr'
    'Invoke-MacVisionOcr'
)
