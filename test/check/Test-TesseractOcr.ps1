<#PSScriptInfo
.VERSION 2026.09.18
.GUID 424c7cc6-4425-4493-95dc-35c015c4f9ed
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS Test-TesseractOcr
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
    pwsh test/check/Test-TesseractOcr.ps1 -ImagePath screenshot.png
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ImagePath
)

Import-Module (Join-Path $PSScriptRoot '../../automation/Yuruna.Globalization.psm1') -DisableNameChecking
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_c1879a78e88f9d94')
Write-Output ""

# --- REGION: Validate input
if (-not (Test-Path $ImagePath)) {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_b89efb6414cd8157' -Arguments @{ imagePath = "$ImagePath" })
    exit 1
}
$absPath = (Resolve-Path $ImagePath).Path

# --- REGION: Import shared Tesseract module
Import-Module (Join-Path -Path (Split-Path -Parent $PSScriptRoot) -ChildPath "modules" | Join-Path -ChildPath "Test.Tesseract.psm1") -Force

if (-not (Assert-TesseractInstalled)) { exit 1 }

$tesseractExe = Find-Tesseract
Write-Output "Tesseract: $tesseractExe"

$version = & $tesseractExe --version 2>&1 | Select-Object -First 1
Write-Output "Version:   $version"
Write-Output "Image:     $absPath"
Write-Output ""

# --- REGION: Run OCR
try {
    $text = Invoke-TesseractOcr -ImagePath $absPath
} catch {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_0bdc91031cb14550' -Arguments @{ value = "$_" })
    exit 1
}

if ([string]::IsNullOrWhiteSpace($text)) {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_00b29d459cc0c2c0')
} else {
    Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_63d0ad7b256dd8cd')
    Write-Output $text
    Write-Output "--- end ---"
}

Write-Output ""
Write-Output "== Comparison =="
Write-Output ""
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_b9f6acb318d4ee8c')
Write-Output "-------------------------------     -------------------------------"
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_654a4ccaaaba493e')
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_8c9ce555fb00a163')
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_7f7b869a3ba22e7a')
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_2c1aa93fe1d4ee75')
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_1ad8e252ab885e3a')
Write-Output (Format-YurunaOperatorMessage -Key 'runner.operator_bd50c7a471e9d2ae')
Write-Output ""
