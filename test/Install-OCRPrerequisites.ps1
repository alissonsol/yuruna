<#
.SYNOPSIS
    Installs prerequisites for the OCR engine used by the test harness.

.DESCRIPTION
    The test harness uses Windows.Media.Ocr (WinRT) for text recognition from VM screenshots.
    This script ensures the required components are installed:

    1. Windows App Runtime 1.8+ (for potential future TextRecognizer API support)
    2. .NET SDK 10+ (to build the WinAIOcr helper tool)
    3. English OCR language pack (required by Windows.Media.Ocr)
    4. Builds the WinAIOcr tool if .NET SDK is available

    Note: The Windows App SDK TextRecognizer API (Microsoft.Windows.AI.Imaging) requires
    the 'systemAIModels' restricted capability, which is only available to MSIX-packaged
    apps with Microsoft signing. Until Microsoft opens this to unpackaged apps, the test
    harness uses the legacy Windows.Media.Ocr engine with image preprocessing (grayscale,
    color inversion, 2x upscaling) to improve accuracy on terminal screenshots.

    Requires Administrator privileges for language pack installation.

.EXAMPLE
    .\Install-OCRPrerequisites.ps1
#>

#Requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Check Administrator privileges ---
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "This script requires Administrator privileges for language pack installation." -ForegroundColor Red
    Write-Host "Please re-run from an elevated PowerShell prompt." -ForegroundColor Red
    exit 1
}

Write-Host "=== OCR Prerequisites Installer ===" -ForegroundColor Cyan
Write-Host ""

# --- 1. Check Windows version ---
Write-Host "[1/5] Checking Windows version..." -ForegroundColor Yellow
$osVersion = [System.Environment]::OSVersion.Version
if ($osVersion.Build -lt 22000) {
    Write-Host "  Windows 11 (build 22000+) is required. Current build: $($osVersion.Build)" -ForegroundColor Red
    exit 1
}
Write-Host "  Windows 11 build $($osVersion.Build) - OK" -ForegroundColor Green

# --- 2. Install English OCR language pack ---
Write-Host "[2/5] Checking OCR language capabilities..." -ForegroundColor Yellow
$ocrCaps = Get-WindowsCapability -Online | Where-Object { $_.Name -match "Language\.OCR.*en-US" }
$needsInstall = $ocrCaps | Where-Object { $_.State -ne 'Installed' }
if ($needsInstall) {
    foreach ($cap in $needsInstall) {
        Write-Host "  Installing: $($cap.Name)..." -ForegroundColor Cyan
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
    }
    Write-Host "  OCR language pack installed." -ForegroundColor Green
} else {
    Write-Host "  English OCR language pack already installed." -ForegroundColor Green
}

# Also check for other installed OCR languages
$allOcr = Get-WindowsCapability -Online | Where-Object { $_.Name -match "Language\.OCR" -and $_.State -eq 'Installed' }
Write-Host "  Installed OCR languages: $($allOcr.Count)"
foreach ($lang in $allOcr) {
    $code = if ($lang.Name -match 'Language\.OCR~~~(\S+)~') { $Matches[1] } else { $lang.Name }
    Write-Host "    - $code" -ForegroundColor DarkGray
}

# --- 3. Check/install Windows App Runtime 1.8 ---
Write-Host "[3/5] Checking Windows App Runtime 1.8..." -ForegroundColor Yellow
$runtime = Get-AppxPackage -Name "Microsoft.WindowsAppRuntime.1.8" -ErrorAction SilentlyContinue |
    Where-Object { $_.Architecture -eq "X64" } |
    Sort-Object Version -Descending | Select-Object -First 1

if ($runtime) {
    Write-Host "  Windows App Runtime 1.8 installed (version $($runtime.Version))." -ForegroundColor Green
} else {
    Write-Host "  Windows App Runtime 1.8 not found. Installing via winget..." -ForegroundColor Cyan
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        winget install --id Microsoft.WindowsAppRuntime.1.8 --accept-source-agreements --accept-package-agreements
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Windows App Runtime 1.8 installed." -ForegroundColor Green
        } else {
            Write-Host "  winget install failed. You can install manually from:" -ForegroundColor Yellow
            Write-Host "  https://learn.microsoft.com/windows/apps/windows-app-sdk/downloads" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  winget not available. Install Windows App Runtime 1.8 manually from:" -ForegroundColor Yellow
        Write-Host "  https://learn.microsoft.com/windows/apps/windows-app-sdk/downloads" -ForegroundColor Yellow
    }
}

# --- 4. Check .NET SDK ---
Write-Host "[4/5] Checking .NET SDK..." -ForegroundColor Yellow
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnet) {
    $dotnetVersion = & dotnet --version 2>$null
    Write-Host "  .NET SDK $dotnetVersion found." -ForegroundColor Green
    $major = [int]($dotnetVersion -split '\.')[0]
    if ($major -lt 9) {
        Write-Host "  .NET SDK 9+ is recommended for building the WinAIOcr tool." -ForegroundColor Yellow
        Write-Host "  Install from: https://dotnet.microsoft.com/download" -ForegroundColor Yellow
    }
} else {
    Write-Host "  .NET SDK not found. Required for building the WinAIOcr tool." -ForegroundColor Yellow
    Write-Host "  Install from: https://dotnet.microsoft.com/download" -ForegroundColor Yellow
}

# --- 5. Build WinAIOcr tool ---
Write-Host "[5/5] Building WinAIOcr tool..." -ForegroundColor Yellow
$projectDir = Join-Path $PSScriptRoot 'tools\WinAIOcr'
$csproj = Join-Path $projectDir 'WinAIOcr.csproj'

if (-not (Test-Path $csproj)) {
    Write-Host "  WinAIOcr project not found at: $csproj" -ForegroundColor Yellow
    Write-Host "  Skipping build." -ForegroundColor Yellow
} elseif (-not $dotnet) {
    Write-Host "  .NET SDK not available. Skipping build." -ForegroundColor Yellow
} else {
    # Ensure NuGet source is configured
    $sources = & dotnet nuget list source 2>$null
    if ($sources -notmatch 'nuget\.org') {
        Write-Host "  Adding nuget.org package source..." -ForegroundColor Cyan
        & dotnet nuget add source https://api.nuget.org/v3/index.json --name nuget.org 2>$null
    }

    $buildOutput = & dotnet build $csproj -c Release --nologo -v q 2>&1
    if ($LASTEXITCODE -eq 0) {
        $exe = Get-ChildItem (Join-Path $projectDir 'bin\Release') -Filter 'WinAIOcr.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        Write-Host "  WinAIOcr built: $($exe.FullName)" -ForegroundColor Green
    } else {
        Write-Host "  Build failed:" -ForegroundColor Red
        $buildOutput | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }
}

# --- Summary ---
Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "OCR Engine: Windows.Media.Ocr (WinRT) with preprocessing" -ForegroundColor White
Write-Host "  The legacy engine is enhanced with grayscale conversion, color inversion," -ForegroundColor DarkGray
Write-Host "  and 2x upscaling to improve accuracy on terminal screenshots." -ForegroundColor DarkGray
Write-Host ""
Write-Host "TextRecognizer (Microsoft.Windows.AI.Imaging) status:" -ForegroundColor White

# Test TextRecognizer availability
$testExe = Get-ChildItem (Join-Path $projectDir 'bin\Release') -Filter 'WinAIOcr.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($testExe) {
    # Create a tiny test PNG
    $testPng = Join-Path $env:TEMP 'ocr_prereq_test.png'
    # Minimal valid 1x1 white PNG (67 bytes)
    $pngBytes = [byte[]]@(
        137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,0,1,0,0,0,1,8,2,0,0,0,
        144,119,83,222,0,0,0,12,73,68,65,84,8,215,99,248,207,192,0,0,0,3,0,1,54,
        40,175,214,0,0,0,0,73,69,78,68,174,66,96,130)
    [System.IO.File]::WriteAllBytes($testPng, $pngBytes)
    $testOutput = & $testExe.FullName $testPng 2>&1
    $testExit = $LASTEXITCODE
    Remove-Item $testPng -Force -ErrorAction SilentlyContinue

    if ($testExit -eq 0) {
        Write-Host "  Available and working! WinAIOcr will be used for OCR." -ForegroundColor Green
    } elseif ($testExit -eq 2) {
        $errMsg = ($testOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join " "
        if ($errMsg -match 'Access is denied') {
            Write-Host "  Not available: requires 'systemAIModels' restricted capability." -ForegroundColor Yellow
            Write-Host "  This API is currently limited to MSIX-packaged apps signed by Microsoft." -ForegroundColor Yellow
            Write-Host "  The legacy OCR engine with preprocessing will be used instead." -ForegroundColor Yellow
        } else {
            Write-Host "  Not available: $errMsg" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Test failed (exit $testExit). Legacy OCR will be used." -ForegroundColor Yellow
    }
} else {
    Write-Host "  WinAIOcr tool not built. Legacy OCR will be used." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Setup complete." -ForegroundColor Green
