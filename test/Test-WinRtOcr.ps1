<#PSScriptInfo
.VERSION 0.1
.GUID 42e5f6a7-b8c9-4d01-e2f3-4a5b6c7d8e9f
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2019-2026 Alisson Sol et al.
.TAGS Test-WinRtOcr
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
    Demonstrates the "closed access" problem with Microsoft AI/OCR on modern PowerShell.

.DESCRIPTION
    Windows ships a capable OCR engine (Windows.Media.Ocr) as part of the Windows
    Runtime (WinRT). However, .NET 6+ removed built-in WinRT projection support,
    which means PowerShell 7+ (pwsh) cannot load WinRT types directly.

    The only two ways to use Windows.Media.Ocr are:

    1. Shell out to Windows PowerShell 5.1 (powershell.exe), which still has
       native WinRT interop. This is what yuruna's Test.OcrEngine.psm1 does
       (see the WinRT provider block).

    2. Add the Microsoft.Windows.SDK.NET.Ref NuGet package to a C# project
       and compile against it. This package is not redistributable and requires
       a Windows SDK installation.

    Neither option works as a simple "Add-Type" or "Import-Module" from pwsh.
    The types exist on every Windows machine, but the runtime bridge is gone.

    This script proves the point: it tries to load the OCR engine from pwsh
    (which fails), then falls back to powershell.exe (which succeeds).
    If an image path is provided, it also runs OCR on that image via
    powershell.exe and displays the extracted text.

.PARAMETER ImagePath
    Optional path to a PNG image file to OCR. If provided and the powershell.exe
    OCR probe succeeds, the image will be recognized and the text printed.

.EXAMPLE
    pwsh test/Test-WinRtOcr.ps1

.EXAMPLE
    pwsh test/Test-WinRtOcr.ps1 -ImagePath screenshot.png
#>

param(
    [string]$ImagePath
)

Write-Output ""
Write-Output "=== Windows.Media.Ocr access test ==="
Write-Output ""

# --- Attempt 1: Direct WinRT from pwsh (PowerShell 7+) ---
Write-Output "[1] Trying to load Windows.Media.Ocr directly from pwsh..."
Write-Output "    PowerShell edition : $($PSVersionTable.PSEdition)"
Write-Output "    PowerShell version : $($PSVersionTable.PSVersion)"
Write-Output "    .NET runtime       : $([System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)"
Write-Output ""

try {
    # This is the standard WinRT type-loading syntax. It works in PowerShell 5.1
    # but throws in PowerShell 7+ because the runtime no longer projects WinRT types.
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($engine) {
        Write-Output "    UNEXPECTED: OcrEngine loaded successfully from pwsh."
    } else {
        Write-Output "    UNEXPECTED: Type loaded but engine creation returned null."
    }
} catch {
    Write-Output "    EXPECTED FAILURE: $_"
    Write-Output ""
    Write-Output "    WinRT types cannot be loaded from PowerShell 7+ (.NET 6+)."
    Write-Output "    The runtime removed built-in WinRT interop (IInspectable projection)."
}

# --- Attempt 2: Add-Type with C# WinRT interop from pwsh ---
Write-Output ""
Write-Output "[2] Trying Add-Type with WinRT reference from pwsh..."

$csCode = @'
using System;

public static class WinRtOcrProbe
{
    public static string TryLoad()
    {
        try
        {
            // In .NET 6+, this assembly does not exist unless the
            // Microsoft.Windows.SDK.NET.Ref NuGet package is referenced
            // at compile time. It is not available at runtime.
            var asm = System.Reflection.Assembly.Load("Microsoft.Windows.SDK.NET");
            return "Loaded: " + asm.FullName;
        }
        catch (Exception ex)
        {
            return "FAILED: " + ex.GetType().Name + " - " + ex.Message;
        }
    }
}
'@

try {
    Add-Type -TypeDefinition $csCode -Language CSharp
    $result = [WinRtOcrProbe]::TryLoad()
    Write-Output "    $result"
} catch {
    Write-Output "    Compilation/load error: $_"
}

# --- Attempt 3: Shell out to Windows PowerShell 5.1 ---
Write-Output ""
Write-Output "[3] Trying via Windows PowerShell 5.1 (powershell.exe)..."

if ($IsWindows -and (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
    $ps51Script = @'
try {
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($engine) {
        Write-Output "SUCCESS: OcrEngine created. Recognizer language: $($engine.RecognizerLanguage.DisplayName)"
    } else {
        Write-Output "FAILED: TryCreateFromUserProfileLanguages returned null."
    }
} catch {
    Write-Output "FAILED: $_"
}
'@
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $ps51Script 2>&1
    foreach ($line in $output) {
        Write-Output "    $line"
    }
} else {
    Write-Output "    SKIPPED: powershell.exe not available (non-Windows or not installed)."
}

Write-Output ""
Write-Output "=== Summary ==="
Write-Output ""
Write-Output "Windows.Media.Ocr is installed on every Windows machine, but:"
Write-Output "  - PowerShell 7+ (.NET 6+) CANNOT access it (WinRT bridge removed)"
Write-Output "  - PowerShell 5.1 (.NET Framework) CAN access it (WinRT bridge built-in)"
Write-Output ""
Write-Output "The yuruna test harness works around this by spawning powershell.exe"
Write-Output "from pwsh to run OCR. There is no pure-pwsh path and no NuGet package"
Write-Output "that can be simply added at runtime to restore access."
Write-Output ""

# --- Attempt 4: OCR an actual image if provided ---
if ($ImagePath) {
    Write-Output "=== OCR: $ImagePath ==="
    Write-Output ""

    if (-not (Test-Path $ImagePath)) {
        Write-Output "    ERROR: File not found: $ImagePath"
        exit 1
    }

    $absPath = (Resolve-Path $ImagePath).Path

    if (-not $IsWindows -or -not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        Write-Output "    SKIPPED: OCR requires powershell.exe on Windows."
        exit 0
    }

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

    $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) 'Test-WinRtOcr-run.ps1'
    try {
        $ocrScript | Set-Content -Path $scriptFile -Encoding UTF8
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptFile $absPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errLines = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
            Write-Output "    OCR ERROR: $errLines"
        } else {
            $textLines = ($output | Where-Object { $_ -is [string] }) -join "`n"
            if ($textLines) {
                Write-Output "--- OCR result ---"
                Write-Output $textLines
                Write-Output "--- end ---"
            } else {
                Write-Output "    (no text recognized)"
            }
        }
    } finally {
        if (Test-Path $scriptFile) { Remove-Item $scriptFile -Force }
    }
    Write-Output ""
}
