<#
.SYNOPSIS
    Updates Windows 11 system packages.
.DESCRIPTION
    Installs Windows updates, updates winget packages, and performs system cleanup.
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

# ===== Ensure execution policy allows scripts =====
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

# ===== PowerShell 7 (install if missing) =====
Write-Host ""
Write-Host ">>> Checking for PowerShell 7..." -ForegroundColor Cyan
$pwshPath = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwshPath) {
    Write-Host "PowerShell 7 not found. Installing..." -ForegroundColor Yellow
    winget install --id Microsoft.PowerShell --accept-source-agreements --accept-package-agreements --silent
    # Refresh PATH so the newly installed pwsh is discoverable
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    Write-Host "<<< PowerShell 7 installation complete." -ForegroundColor Green
} else {
    Write-Host "PowerShell 7 found at $($pwshPath.Source)" -ForegroundColor Green
}

Write-Host ""
Write-Host ">>> Updating winget packages..." -ForegroundColor Cyan
winget upgrade --all --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< winget package update complete." -ForegroundColor Green

Write-Host ""
Write-Host ">>> Installing Windows Update module..." -ForegroundColor Cyan
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
}
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -Confirm:$false
}
Import-Module PSWindowsUpdate
Write-Host "<<< Windows Update module ready." -ForegroundColor Green

Write-Host ""
Write-Host ">>> Checking for Windows updates..." -ForegroundColor Cyan
Get-WindowsUpdate -AcceptAll -Install -AutoReboot:$false -Verbose
Write-Host "<<< Windows update check complete." -ForegroundColor Green

Write-Host ""
Write-Host ">>> Cleaning up temporary files..." -ForegroundColor Cyan
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
cleanmgr /sagerun:1 2>$null
Write-Host "<<< Cleanup complete." -ForegroundColor Green
