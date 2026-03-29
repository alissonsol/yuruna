<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456780
.AUTHOR Alisson Sol
.COMPANYNAME None
.COPYRIGHT (c) 2026 Alisson Sol et al.
.TAGS
.LICENSEURI http://www.yuruna.com
.PROJECTURI http://www.yuruna.com
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
.PRIVATEDATA
#>

<#
.SYNOPSIS
    Installs Tesseract OCR for VM screen text detection.

.DESCRIPTION
    Tesseract is used by the interaction sequence engine (Invoke-Sequence.psm1)
    to read text from VM screenshots, enabling waitForText actions that detect
    login prompts, password requests, and command completion.

    - Windows: installs via winget (UB-Mannheim.TesseractOCR) and adds to PATH
    - macOS:   installs via Homebrew (brew install tesseract)
#>

Write-Output ""
Write-Output "========================================="
Write-Output "  Tesseract OCR Setup"
Write-Output "========================================="
Write-Output ""

# === Check if already installed ===
$tesseract = Get-Command "tesseract" -ErrorAction SilentlyContinue
if ($tesseract) {
    $version = & tesseract --version 2>&1 | Select-Object -First 1
    Write-Output "[OK] Tesseract already installed: $version"
    Write-Output "     Path: $($tesseract.Source)"
    exit 0
}

# === Install ===
if ($IsMacOS) {
    if (-not (Get-Command "brew" -ErrorAction SilentlyContinue)) {
        Write-Error "Homebrew not found. Install from https://brew.sh then rerun this script."
        exit 1
    }
    Write-Output "Installing tesseract via Homebrew..."
    & brew install tesseract 2>&1 | ForEach-Object { Write-Output "  $_" }
} elseif ($IsWindows) {
    if (-not (Get-Command "winget" -ErrorAction SilentlyContinue)) {
        Write-Error "winget not found. Install Tesseract manually from https://github.com/UB-Mannheim/tesseract/wiki"
        exit 1
    }
    Write-Output "Installing Tesseract via winget..."
    & winget install UB-Mannheim.TesseractOCR --accept-source-agreements --accept-package-agreements 2>&1 | ForEach-Object { Write-Output "  $_" }

    # Add to PATH for the current session (winget installer adds to system PATH for new sessions)
    $tesseractPaths = @(
        "$env:ProgramFiles\Tesseract-OCR",
        "${env:ProgramFiles(x86)}\Tesseract-OCR",
        "$env:LOCALAPPDATA\Programs\Tesseract-OCR"
    )
    foreach ($p in $tesseractPaths) {
        if (Test-Path "$p\tesseract.exe") {
            if (-not ($env:Path -split ";" | Where-Object { $_ -eq $p })) {
                $env:Path = "$env:Path;$p"
                Write-Output "Added to session PATH: $p"
            }
            break
        }
    }
} else {
    Write-Error "Unsupported platform. Install tesseract manually: https://github.com/tesseract-ocr/tesseract"
    exit 1
}

# === Verify ===
$tesseract = Get-Command "tesseract" -ErrorAction SilentlyContinue
if ($tesseract) {
    $version = & tesseract --version 2>&1 | Select-Object -First 1
    Write-Output ""
    Write-Output "[OK] Tesseract installed: $version"
    Write-Output "     Path: $($tesseract.Source)"
} else {
    Write-Output ""
    Write-Warning "Tesseract installed but not yet in PATH for this session."
    Write-Output "Restart your terminal, then verify with: tesseract --version"
}
