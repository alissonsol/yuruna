<#PSScriptInfo
.VERSION 0.1
.GUID 42f6a7b8-c9d0-4e12-f3a4-5b6c7d8e9f0a
.AUTHOR Alisson Sol
.COPYRIGHT (c) 2019-2026 Alisson Sol et al.
.TAGS Test-TesseractOcr
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

# --- Import shared Tesseract module ---
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "modules" | Join-Path -ChildPath "Test.Tesseract.psm1") -Force

if (-not (Assert-TesseractInstalled)) { exit 1 }

$tesseractExe = Find-Tesseract
Write-Output "Tesseract: $tesseractExe"

# Print version
$version = & $tesseractExe --version 2>&1 | Select-Object -First 1
Write-Output "Version:   $version"
Write-Output "Image:     $absPath"
Write-Output ""

# --- Run OCR ---
try {
    $text = Invoke-TesseractOcr -ImagePath $absPath
} catch {
    Write-Output "Tesseract failed: $_"
    exit 1
}

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
