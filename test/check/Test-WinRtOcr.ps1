<#PSScriptInfo
.VERSION 2026.09.24
.GUID 42331174-548a-4a2c-a2ca-a56b9374880d
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Test-WinRtOcr
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
    pwsh test/check/Test-WinRtOcr.ps1

.EXAMPLE
    pwsh test/check/Test-WinRtOcr.ps1 -ImagePath screenshot.png
#>

param(
    [string]$ImagePath
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_5d7bc256d478e681')
Write-Output ""

# --- REGION: Attempt 1: Direct WinRT from pwsh (PowerShell 7+)
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_f0cc9253c8196e3f')
Write-Output "    PowerShell edition : $($PSVersionTable.PSEdition)"
Write-Output "    PowerShell version : $($PSVersionTable.PSVersion)"
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_0836a89873e31a02' -Arguments @{ frameworkDescription = "$([System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)" })
Write-Output ""

try {
    # This is the standard WinRT type-loading syntax. It works in PowerShell 5.1
    # but throws in PowerShell 7+ because the runtime no longer projects WinRT types.
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($engine) {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_723b931bd3a6c338')
    } else {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_2cfe3faa9f28b57b')
    }
} catch {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_11135e4f45f7ae77' -Arguments @{ value = "$_" })
    Write-Output ""
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_45ccb6a97d894430')
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_785a110bf5dc9284')
}

# --- REGION: Attempt 2: Add-Type with C# WinRT interop from pwsh
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_deb5472371b9e101')

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
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_4c61b35d38b409d0' -Arguments @{ value = "$_" })
}

# --- REGION: Attempt 3: Shell out to Windows PowerShell 5.1
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_eac4846c6788d158')

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
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_d18200873cd315db')
}

Write-Output ""
Write-Output "== Summary =="
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_fff495323f51f508')
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_17954986cc0d28c6')
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_e76cf89c53ed33b7')
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_69f5b50c30876f7e')
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_f2d3d5d8ac080630')
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_76100d765e66aa04')
Write-Output ""

# --- REGION: Attempt 4: OCR an actual image if provided
if ($ImagePath) {
    Write-Output "== OCR: $ImagePath =="
    Write-Output ""

    if (-not (Test-Path $ImagePath)) {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_ee6735a83a074220' -Arguments @{ imagePath = "$ImagePath" })
        exit 1
    }

    $absPath = (Resolve-Path $ImagePath).Path

    if (-not $IsWindows -or -not (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_634075f9a06b238e')
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

    # Unique per-run name so concurrent invocations (or a leftover from a killed
    # run) cannot collide in the shared temp directory; the finally block removes it.
    $scriptFile = Join-Path ([System.IO.Path]::GetTempPath()) ("Test-WinRtOcr-run-{0}.ps1" -f [guid]::NewGuid())
    try {
        $ocrScript | Set-Content -Path $scriptFile -Encoding UTF8
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptFile $absPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            $errLines = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
            Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_1de74f1ea0232c3b' -Arguments @{ errLines = "$errLines" })
        } else {
            $textLines = ($output | Where-Object { $_ -is [string] }) -join "`n"
            if ($textLines) {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_63d0ad7b256dd8cd')
                Write-Output $textLines
                Write-Output "--- end ---"
            } else {
                Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_60dfee814cfea059')
            }
        }
    } finally {
        if (Test-Path $scriptFile) { Remove-Item $scriptFile -Force }
    }
    Write-Output ""
}
