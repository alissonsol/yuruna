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

    The script checks for all prerequisites and attempts to install missing
    ones automatically. If auto-install is not possible, it prints the exact
    steps needed to fix the issue.

.NOTES
    Reference: https://appium.io/docs/en/latest/quickstart/
#>

$ErrorActionPreference = "Stop"
$AppiumDir = Join-Path $PSScriptRoot "appium"
$issues = [System.Collections.Generic.List[string]]::new()

Write-Output ""
Write-Output "========================================="
Write-Output "  Appium Setup"
Write-Output "========================================="
Write-Output ""

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1: Prerequisites check
# ─────────────────────────────────────────────────────────────────────────────

Write-Output "--- Checking prerequisites ---"
Write-Output ""

# === Platform ===
if ($IsWindows) {
    Write-Output "[OK]   Platform: Windows"
} elseif ($IsMacOS) {
    Write-Output "[OK]   Platform: macOS"
} else {
    Write-Output "[FAIL] Unsupported platform. Only Windows and macOS are supported."
    exit 1
}

# === Elevation (Windows only) ===
if ($IsWindows) {
    if (([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Output "[OK]   Running as Administrator"
    } else {
        Write-Output "[FAIL] Not running as Administrator"
        $issues.Add("Run this script from an elevated (Administrator) PowerShell prompt.")
    }
}

# === Package manager ===
if ($IsMacOS) {
    if (Get-Command "brew" -ErrorAction SilentlyContinue) {
        Write-Output "[OK]   Homebrew: $(& brew --version 2>&1 | Select-Object -First 1)"
    } else {
        Write-Output "[FAIL] Homebrew not found"
        $issues.Add("Install Homebrew: /bin/bash -c `"`$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)`"")
        $issues.Add("  See: https://brew.sh")
    }
}
if ($IsWindows) {
    if (Get-Command "winget" -ErrorAction SilentlyContinue) {
        Write-Output "[OK]   winget available"
    } else {
        Write-Output "[WARN] winget not found (Node.js auto-install unavailable)"
        Write-Output "       winget ships with Windows 11 and recent Windows 10 updates."
        Write-Output "       If missing, install Node.js manually from https://nodejs.org"
    }
}

# === Node.js ===
$nodeVersion = try { (& node --version 2>&1).Trim() } catch { $null }
if ($nodeVersion -and $nodeVersion -match '^v\d+') {
    $nodeMajor = [int]($nodeVersion -replace '^v', '' -split '\.')[0]
    if ($nodeMajor -ge 18) {
        Write-Output "[OK]   Node.js: $nodeVersion"
    } else {
        Write-Output "[FAIL] Node.js $nodeVersion is too old (need 18+)"
        if ($IsMacOS) {
            $issues.Add("Upgrade Node.js: brew upgrade node")
        } elseif ($IsWindows) {
            $issues.Add("Upgrade Node.js: winget upgrade OpenJS.NodeJS.LTS")
            $issues.Add("  Or download from: https://nodejs.org")
        }
    }
} else {
    Write-Output "[    ] Node.js not found. Attempting install..."
    $nodeInstalled = $false
    if ($IsMacOS -and (Get-Command "brew" -ErrorAction SilentlyContinue)) {
        Write-Output "       Running: brew install node"
        & brew install node 2>&1 | ForEach-Object { Write-Host "  $_" }
        $nodeInstalled = $true
    } elseif ($IsWindows -and (Get-Command "winget" -ErrorAction SilentlyContinue)) {
        Write-Output "       Running: winget install OpenJS.NodeJS.LTS"
        & winget install OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements 2>&1 | ForEach-Object { Write-Host "  $_" }
        # Refresh PATH for the current session
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        $nodeInstalled = $true
    }
    if ($nodeInstalled) {
        $nodeVersion = try { (& node --version 2>&1).Trim() } catch { $null }
    }
    if ($nodeVersion -and $nodeVersion -match '^v\d+') {
        Write-Output "[OK]   Node.js installed: $nodeVersion"
    } else {
        Write-Output "[FAIL] Node.js could not be installed automatically"
        if ($IsMacOS) {
            $issues.Add("Install Node.js: brew install node")
        } elseif ($IsWindows) {
            $issues.Add("Install Node.js: winget install OpenJS.NodeJS.LTS")
            $issues.Add("  Or download from: https://nodejs.org")
        }
        $issues.Add("After installing, restart your terminal and rerun this script.")
    }
}

# === npm ===
if ($IsWindows) { $npmCmd = Get-Command "npm.cmd" -ErrorAction SilentlyContinue }
else            { $npmCmd = Get-Command "npm"     -ErrorAction SilentlyContinue }
if ($npmCmd) {
    $npmVersion = try { (& $npmCmd.Source --version 2>&1).Trim() } catch { $null }
    Write-Output "[OK]   npm: $npmVersion ($($npmCmd.Source))"
} else {
    Write-Output "[FAIL] npm not found"
    $issues.Add("npm should be installed with Node.js. If Node.js is installed, restart your terminal.")
    if ($IsMacOS) {
        $issues.Add("  Or reinstall: brew reinstall node")
    } elseif ($IsWindows) {
        $issues.Add("  Or reinstall from: https://nodejs.org")
    }
}

# === WinAppDriver (Windows only) ===
if ($IsWindows) {
    $wadPath = "$env:ProgramFiles\Windows Application Driver\WinAppDriver.exe"
    if (Test-Path $wadPath) {
        Write-Output "[OK]   WinAppDriver: $wadPath"
    } else {
        Write-Output "[WARN] WinAppDriver not found"
        Write-Output "       Required for Appium to automate Hyper-V VM windows."
        Write-Output "       Download: https://github.com/microsoft/WinAppDriver/releases"
        Write-Output "       Then enable Developer Mode: Settings > Privacy & Security > For developers"
    }

    # Check Developer Mode
    $devMode = try {
        (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" -Name "AllowDevelopmentWithoutDevLicense" -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
    } catch { $null }
    if ($devMode -eq 1) {
        Write-Output "[OK]   Developer Mode: enabled"
    } else {
        Write-Output "[WARN] Developer Mode may not be enabled"
        Write-Output "       WinAppDriver requires Developer Mode."
        Write-Output "       Enable in: Settings > Privacy & Security > For developers"
    }
}

# === Accessibility (macOS only) ===
if ($IsMacOS) {
    Write-Output "[INFO] macOS requires Accessibility permissions for GUI automation."
    Write-Output "       Grant access to your terminal app when prompted, or add it in:"
    Write-Output "       System Settings > Privacy & Security > Accessibility"
}

# === Stop if prerequisites failed ===
Write-Output ""
if ($issues.Count -gt 0) {
    Write-Output "========================================="
    Write-Output "  Setup cannot continue. Fix the following:"
    Write-Output "========================================="
    Write-Output ""
    foreach ($issue in $issues) {
        Write-Output "  $issue"
    }
    Write-Output ""
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2: Install Appium and drivers
# ─────────────────────────────────────────────────────────────────────────────

# === Install Appium globally ===
Write-Output "--- Installing Appium ---"
# Check if appium is already installed by looking for it directly in PATH.
# Do NOT use npx here — npx auto-downloads missing packages and can hang.
$appiumVersion = $null
$appiumCmd = if ($IsWindows) { Get-Command "appium.cmd" -ErrorAction SilentlyContinue }
             else            { Get-Command "appium"     -ErrorAction SilentlyContinue }
if ($appiumCmd) {
    Write-Output "Found appium at: $($appiumCmd.Source)"
    $appiumVersion = try { (& $appiumCmd.Source --version 2>&1).Trim() } catch { $null }
    Write-Output "Version: $appiumVersion"
}
if ($appiumVersion -and $appiumVersion -match '^\d+\.\d+') {
    Write-Output "Appium already installed: $appiumVersion"
} else {
    Write-Output "Appium not found in PATH. Installing..."
    Write-Output "Running: $($npmCmd.Source) install -g appium"
    Write-Output "(this may take several minutes)"
    & $npmCmd.Source install -g appium 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to install Appium (exit code $LASTEXITCODE). Try running manually: npm install -g appium"
        exit 1
    }
    # Refresh PATH on Windows to pick up newly installed global npm binaries
    if ($IsWindows) {
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    }
    # Re-resolve appium command
    $appiumCmd = if ($IsWindows) { Get-Command "appium.cmd" -ErrorAction SilentlyContinue }
                 else            { Get-Command "appium"     -ErrorAction SilentlyContinue }
    if ($appiumCmd) {
        $appiumVersion = try { (& $appiumCmd.Source --version 2>&1).Trim() } catch { "unknown" }
    } else {
        $appiumVersion = "installed (not yet in PATH — restart terminal)"
    }
    Write-Output "Appium installed: $appiumVersion"
}

# === Install platform driver ===
Write-Output ""
if (-not $appiumCmd) {
    Write-Warning "appium command not found in PATH. Restart your terminal, then run:"
    if ($IsWindows) {
        Write-Output "  appium driver install --source=npm appium-windows-driver"
    } else {
        Write-Output "  appium driver install mac2"
    }
} elseif ($IsWindows) {
    Write-Output "--- Installing Appium Windows Driver ---"
    Write-Output "Running: appium driver install --source=npm appium-windows-driver"
    Write-Output "(this may take a few minutes)"
    & $appiumCmd.Source driver install --source=npm appium-windows-driver 2>&1 | ForEach-Object { Write-Host "  $_" }
} elseif ($IsMacOS) {
    Write-Output "--- Installing Appium Mac2 Driver ---"
    Write-Output "Running: appium driver install mac2"
    Write-Output "(this may take a few minutes)"
    & $appiumCmd.Source driver install mac2 2>&1 | ForEach-Object { Write-Host "  $_" }
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
    Write-Output "  (restart terminal to see drivers)"
}

# === Summary ===
Write-Output ""
Write-Output "========================================="
Write-Output "  Setup complete"
Write-Output "========================================="
Write-Output ""
Write-Output "  Appium:    $appiumVersion"
Write-Output "  Node.js:   $nodeVersion"
Write-Output "  npm:       $npmVersion"
Write-Output "  Platform:  $(if ($IsWindows) { 'Windows (appium-windows-driver)' } else { 'macOS (appium-mac2-driver)' })"
Write-Output ""
Write-Output "To start the Appium server manually:  appium"
Write-Output "The Test-Start extension scripts will start it automatically when needed."
