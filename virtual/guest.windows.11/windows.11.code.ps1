<#PSScriptInfo
.VERSION 0.1
.GUID 42f0a1b2-c3d4-4e56-f789-0a1b2c3d4e12
.AUTHOR Alisson Sol
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
    Installs Java (JDK), .NET SDK, Git, Visual Studio Code, and PowerShell 7 on Windows 11.
.DESCRIPTION
    Uses winget for package installation where available.
    Run this script in an elevated PowerShell terminal.
#>

# ===== Ensure running as Administrator =====
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output ""
    Write-Output "╔════════════════════════════════════════════════════════════╗"
    Write-Output "║  This script requires elevation (Run as Administrator)    ║"
    Write-Output "║  Right-click PowerShell and select 'Run as Administrator' ║"
    Write-Output "╚════════════════════════════════════════════════════════════╝"
    Write-Output ""
    exit 1
}

# ===== Install JDK (OpenJDK via Microsoft Build) =====
Write-Output ""
Write-Output ">>> Installing JDK (Microsoft OpenJDK)..."
winget install --id Microsoft.OpenJDK.21 --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< JDK installation complete."

# ===== Install .NET SDK =====
Write-Output ""
Write-Output ">>> Installing .NET SDK..."
winget install --id Microsoft.DotNet.SDK.10 --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< .NET SDK installation complete."

# ===== Install Git =====
Write-Output ""
Write-Output ">>> Installing Git..."
winget install --id Git.Git --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< Git installation complete."

# ===== Install Visual Studio Code =====
Write-Output ""
Write-Output ">>> Installing Visual Studio Code..."
winget install --id Microsoft.VisualStudioCode --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< Visual Studio Code installation complete."

# ===== Install PowerShell 7 =====
Write-Output ""
Write-Output ">>> Installing PowerShell 7..."
winget install --id Microsoft.PowerShell --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< PowerShell 7 installation complete."

# ===== Install GitHub CLI =====
Write-Output ""
Write-Output ">>> Installing GitHub CLI..."
winget install --id GitHub.cli --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< GitHub CLI installation complete."

# ===== Refresh PATH =====
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# ===== Show installed versions =====
Write-Output ""
Write-Output "=== Installation Summary ==="
try { java --version 2>&1 | Select-Object -First 1 } catch { Write-Output "Java: restart terminal to verify" }
try { dotnet --version } catch { Write-Output ".NET: restart terminal to verify" }
try { git --version } catch { Write-Output "Git: restart terminal to verify" }
try { code --version 2>$null | Select-Object -First 1 } catch { Write-Output "VS Code: restart terminal to verify" }
try { pwsh --version } catch { Write-Output "PowerShell 7: restart terminal to verify" }
try { gh --version 2>$null | Select-Object -First 1 } catch { Write-Output "GitHub CLI: restart terminal to verify" }
