<#
.SYNOPSIS
    Alternative OCR option using Tesseract (open-source), independent of WinRT.

.DESCRIPTION
    Test-WinRtOcr.ps1 demonstrates the WinRT Windows.Media.Ocr engine, which
    requires shelling out to PowerShell 5.1 due to .NET 6+ dropping WinRT support.

    This script demonstrates a completely different approach: Tesseract OCR, an
    open-source engine that runs as a standalone executable. It works directly
    from pwsh (no powershell.exe shim), runs on Windows/macOS/Linux, and does
    not depend on any Windows Runtime API.

    Install Tesseract via any of:
      winget install UB-Mannheim.TesseractOCR
      choco install tesseract
      scoop install tesseract
      brew install tesseract          (macOS)
      sudo apt install tesseract-ocr  (Linux)

.PARAMETER ImagePath
    Path to a PNG or image file to OCR. Required.

.EXAMPLE
    pwsh test/Test-OcrOption.ps1 -ImagePath screenshot.png
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ImagePath
)

Write-Output ""
Write-Output "=== Tesseract OCR test ==="
Write-Output ""

# --- Validate input ---
if (-not (Test-Path $ImagePath)) {
    Write-Output "ERROR: File not found: $ImagePath"
    exit 1
}
$absPath = (Resolve-Path $ImagePath).Path

# --- Locate tesseract ---
# Common install locations on Windows (winget / Chocolatey / manual)
$searchPaths = @(
    "C:\Program Files\Tesseract-OCR"
    "C:\Program Files (x86)\Tesseract-OCR"
    "$env:LOCALAPPDATA\Programs\Tesseract-OCR"
)

$tesseractCmd = Get-Command tesseract -ErrorAction SilentlyContinue
if (-not $tesseractCmd) {
    foreach ($dir in $searchPaths) {
        $candidate = Join-Path $dir "tesseract.exe"
        if (Test-Path $candidate) {
            $tesseractCmd = $candidate
            break
        }
    }
}

if (-not $tesseractCmd) {
    Write-Output "Tesseract not found in PATH or common install locations."
    Write-Output ""
    Write-Output "Install via one of:"
    Write-Output "  winget install UB-Mannheim.TesseractOCR"
    Write-Output "  choco install tesseract"
    Write-Output "  scoop install tesseract"
    Write-Output "  brew install tesseract          (macOS)"
    Write-Output "  sudo apt install tesseract-ocr  (Linux)"
    exit 1
}

$tesseractExe = if ($tesseractCmd -is [string]) { $tesseractCmd } else { $tesseractCmd.Source }
Write-Output "Tesseract: $tesseractExe"

# Print version
$version = & $tesseractExe --version 2>&1 | Select-Object -First 1
Write-Output "Version:   $version"
Write-Output "Image:     $absPath"
Write-Output ""

# --- Run OCR ---
# tesseract outputs to a file by default; use "stdout" as output base to get text on stdout.
$output = & $tesseractExe $absPath stdout 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Output "Tesseract failed with exit code $LASTEXITCODE."
    # Show stderr on failure
    $errOutput = & $tesseractExe $absPath stdout 2>&1 | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
    foreach ($line in $errOutput) { Write-Output "  $line" }
    exit 1
}

$text = ($output | Where-Object { $_ -is [string] }) -join "`n"

if ([string]::IsNullOrWhiteSpace($text)) {
    Write-Output "(no text recognized)"
} else {
    Write-Output "--- OCR result ---"
    Write-Output $text
    Write-Output "--- end ---"
}

Write-Output ""
Write-Output "=== Comparison ==="
Write-Output ""
Write-Output "WinRT (Test-WinRtOcr.ps1)          Tesseract (this script)"
Write-Output "-------------------------------     -------------------------------"
Write-Output "Built into Windows                  Separate install required"
Write-Output "Requires powershell.exe (5.1)       Runs directly from pwsh"
Write-Output "No CLI, WinRT API only              Simple CLI (tesseract img out)"
Write-Output "Windows only                        Windows, macOS, Linux"
Write-Output "Closed source                       Open source (Apache 2.0)"
Write-Output "Good for short text / UI            Better for documents / paragraphs"
Write-Output ""
