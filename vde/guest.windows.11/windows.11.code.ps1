<#
.SYNOPSIS
    Installs Java (JDK), .NET SDK, Git, Visual Studio Code, and PowerShell 7 on Windows 11.
.DESCRIPTION
    Uses winget for package installation where available.
    Run this script in an elevated PowerShell terminal.
#>

# ===== Ensure running as Administrator =====
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  This script requires elevation (Run as Administrator)    ║" -ForegroundColor Cyan
    Write-Host "║  Right-click PowerShell and select 'Run as Administrator' ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    exit 1
}

# ===== Install JDK (OpenJDK via Microsoft Build) =====
Write-Host ""
Write-Host ">>> Installing JDK (Microsoft OpenJDK)..." -ForegroundColor Cyan
winget install --id Microsoft.OpenJDK.21 --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< JDK installation complete." -ForegroundColor Green

# ===== Install .NET SDK =====
Write-Host ""
Write-Host ">>> Installing .NET SDK..." -ForegroundColor Cyan
winget install --id Microsoft.DotNet.SDK.10 --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< .NET SDK installation complete." -ForegroundColor Green

# ===== Install Git =====
Write-Host ""
Write-Host ">>> Installing Git..." -ForegroundColor Cyan
winget install --id Git.Git --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< Git installation complete." -ForegroundColor Green

# ===== Install Visual Studio Code =====
Write-Host ""
Write-Host ">>> Installing Visual Studio Code..." -ForegroundColor Cyan
winget install --id Microsoft.VisualStudioCode --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< Visual Studio Code installation complete." -ForegroundColor Green

# ===== Install PowerShell 7 =====
Write-Host ""
Write-Host ">>> Installing PowerShell 7..." -ForegroundColor Cyan
winget install --id Microsoft.PowerShell --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< PowerShell 7 installation complete." -ForegroundColor Green

# ===== Install GitHub CLI =====
Write-Host ""
Write-Host ">>> Installing GitHub CLI..." -ForegroundColor Cyan
winget install --id GitHub.cli --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< GitHub CLI installation complete." -ForegroundColor Green

# ===== Refresh PATH =====
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# ===== Show installed versions =====
Write-Host ""
Write-Host "=== Installation Summary ===" -ForegroundColor Yellow
try { java --version 2>&1 | Select-Object -First 1 } catch { Write-Host "Java: restart terminal to verify" }
try { dotnet --version } catch { Write-Host ".NET: restart terminal to verify" }
try { git --version } catch { Write-Host "Git: restart terminal to verify" }
try { code --version 2>$null | Select-Object -First 1 } catch { Write-Host "VS Code: restart terminal to verify" }
try { pwsh --version } catch { Write-Host "PowerShell 7: restart terminal to verify" }
try { gh --version 2>$null | Select-Object -First 1 } catch { Write-Host "GitHub CLI: restart terminal to verify" }
