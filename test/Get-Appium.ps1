<#PSScriptInfo
.VERSION 0.1
.GUID 42a1b2c3-d4e5-4f67-8901-bc0123456750
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
    Installs Appium and the platform-appropriate driver for VM GUI automation.

.DESCRIPTION
    Sets up Appium (https://appium.io) for automating VM console windows.
    - Windows: installs appium + appium-windows-driver (for vmconnect/Hyper-V)
    - macOS:   installs appium + appium-mac2-driver (for UTM windows)

    Prerequisites:
      - Node.js 18+ and npm must be installed and in PATH.
      - Windows: run as Administrator.
      - macOS: grant Accessibility permissions to Terminal/iTerm when prompted.

.NOTES
    Reference: https://appium.io/docs/en/latest/quickstart/
#>

$ErrorActionPreference = "Stop"
$AppiumDir = Join-Path $PSScriptRoot "appium"

# === Locate npm and node executables ===
# On Windows, npm ships as npm.cmd; calling it directly avoids cmd.exe
# argument parsing issues and output buffering.
if ($IsWindows) {
    $npmCmd = Get-Command "npm.cmd" -ErrorAction SilentlyContinue
    $npxCmd = Get-Command "npx.cmd" -ErrorAction SilentlyContinue
} else {
    $npmCmd = Get-Command "npm" -ErrorAction SilentlyContinue
    $npxCmd = Get-Command "npx" -ErrorAction SilentlyContinue
}

# === Check Node.js ===
$nodeVersion = try { (& node --version 2>&1).Trim() } catch { $null }
if (-not $nodeVersion) {
    if ($IsWindows) {
        Write-Error "Node.js not found. Install via: winget install OpenJS.NodeJS.LTS"
    } else {
        Write-Error "Node.js not found. Install Node.js 18+ from https://nodejs.org"
    }
    exit 1
}
$nodeMajor = [int]($nodeVersion -replace '^v', '' -split '\.')[0]
if ($nodeMajor -lt 18) {
    Write-Error "Node.js $nodeVersion is too old. Appium requires Node.js 18+."
    exit 1
}
Write-Output "Node.js: $nodeVersion"

# === Check npm ===
if (-not $npmCmd) {
    Write-Error "npm not found. It should be installed with Node.js."
    exit 1
}
$npmVersion = try { (& $npmCmd.Source --version 2>&1).Trim() } catch { $null }
Write-Output "npm:     $npmVersion"
Write-Output "npm at:  $($npmCmd.Source)"

# === Elevation check (Windows only) ===
if ($IsWindows) {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Error "Please run this script as Administrator on Windows."
        exit 1
    }
}

# === Install Appium globally ===
Write-Output ""
Write-Output "--- Installing Appium ---"
# Check if appium is already installed by looking for it directly in PATH.
# Do NOT use npx here — npx auto-downloads missing packages and can hang.
$appiumVersion = $null
$appiumExisting = if ($IsWindows) { Get-Command "appium.cmd" -ErrorAction SilentlyContinue }
                  else            { Get-Command "appium"     -ErrorAction SilentlyContinue }
if ($appiumExisting) {
    Write-Output "Found appium at: $($appiumExisting.Source)"
    $appiumVersion = try { (& $appiumExisting.Source --version 2>&1).Trim() } catch { $null }
    Write-Output "Version: $appiumVersion"
}
if ($appiumVersion -and $appiumVersion -match '^\d+\.\d+') {
    Write-Output "Appium already installed: $appiumVersion"
} else {
    Write-Output "Appium not found in PATH. Installing..."
    Write-Output "Installing Appium via npm (this may take several minutes)..."
    Write-Output "Running: $($npmCmd.Source) install -g appium"
    & $npmCmd.Source install -g appium 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to install Appium (exit code $LASTEXITCODE)."
        Write-Output "Try running manually: npm install -g appium"
        exit 1
    }
    # Re-resolve npx after install
    if ($IsWindows) { $npxCmd = Get-Command "npx.cmd" -ErrorAction SilentlyContinue }
    else            { $npxCmd = Get-Command "npx"     -ErrorAction SilentlyContinue }
    $appiumVersion = try { (& $npxCmd.Source appium --version 2>&1).Trim() } catch { "unknown" }
    Write-Output "Appium installed: $appiumVersion"
}

# Locate the appium command for driver installs
$appiumCmd = if ($IsWindows) { Get-Command "appium.cmd" -ErrorAction SilentlyContinue }
             else            { Get-Command "appium"     -ErrorAction SilentlyContinue }

# === Install platform driver ===
Write-Output ""
if ($IsWindows) {
    Write-Output "--- Installing Appium Windows Driver ---"
    Write-Output "This driver automates Windows desktop applications (vmconnect for Hyper-V VMs)."
    Write-Output "Installing driver (this may take a few minutes)..."
    if ($appiumCmd) {
        & $appiumCmd.Source driver install --source=npm appium-windows-driver 2>&1 | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Warning "appium command not found in PATH. Restart your terminal and retry."
    }

    Write-Output ""
    Write-Output "--- Checking WinAppDriver ---"
    $wadPath = "$env:ProgramFiles\Windows Application Driver\WinAppDriver.exe"
    if (Test-Path $wadPath) {
        Write-Output "WinAppDriver found: $wadPath"
    } else {
        Write-Output "WinAppDriver not found at: $wadPath"
        Write-Output "Download from: https://github.com/microsoft/WinAppDriver/releases"
        Write-Output "Install it, then enable Developer Mode in Windows Settings > Privacy & Security > For developers."
    }
} elseif ($IsMacOS) {
    Write-Output "--- Installing Appium Mac2 Driver ---"
    Write-Output "This driver automates macOS applications (UTM VM windows)."
    Write-Output "Installing driver (this may take a few minutes)..."
    if ($appiumCmd) {
        & $appiumCmd.Source driver install mac2 2>&1 | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Warning "appium command not found in PATH. Restart your terminal and retry."
    }

    Write-Output ""
    Write-Output "IMPORTANT: macOS requires Accessibility permissions for GUI automation."
    Write-Output "When prompted, grant access to Terminal (or your terminal app) in:"
    Write-Output "  System Settings > Privacy & Security > Accessibility"
} else {
    Write-Error "Unsupported platform. Only Windows and macOS are supported."
    exit 1
}

# === Create appium directory for local config ===
if (-not (Test-Path $AppiumDir)) {
    New-Item -ItemType Directory -Path $AppiumDir -Force | Out-Null
}

# === List installed drivers ===
Write-Output ""
Write-Output "--- Installed Appium drivers ---"
if ($appiumCmd) {
    & $appiumCmd.Source driver list --installed 2>&1 | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Output "  (appium not in PATH — restart terminal to see drivers)"
}

# === Summary ===
Write-Output ""
Write-Output "=== Setup complete ==="
Write-Output "  Appium:    $appiumVersion"
Write-Output "  Node.js:   $nodeVersion"
Write-Output "  Platform:  $(if ($IsWindows) { 'Windows (appium-windows-driver)' } else { 'macOS (appium-mac2-driver)' })"
Write-Output ""
Write-Output "To start the Appium server manually:  appium"
Write-Output "The Test-Start extension scripts will start it automatically when needed."
