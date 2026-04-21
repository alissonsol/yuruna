<#PSScriptInfo
.VERSION 0.1
.GUID 42f0a1b2-c3d4-4e56-f789-0a1b2c3d4e10
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
    Updates Windows 11 system packages.
.DESCRIPTION
    Installs Windows updates, updates winget packages, and performs system cleanup.
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

# ===== Ensure execution policy allows scripts =====
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

# ===== PowerShell 7 (install if missing) =====
Write-Output ""
Write-Output ">>> Checking for PowerShell 7..."
$pwshPath = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwshPath) {
    Write-Output "PowerShell 7 not found. Installing..."
    winget install --id Microsoft.PowerShell --accept-source-agreements --accept-package-agreements --silent
    # Refresh PATH so the newly installed pwsh is discoverable
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
    Write-Output "<<< PowerShell 7 installation complete."
} else {
    Write-Output "PowerShell 7 found at $($pwshPath.Source)"
}

Write-Output ""
Write-Output ">>> Updating winget packages..."
winget upgrade --all --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< winget package update complete."

Write-Output ""
Write-Output ">>> Installing Windows Update module..."
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
}
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -Confirm:$false
}
Import-Module PSWindowsUpdate
Write-Output "<<< Windows Update module ready."

Write-Output ""
Write-Output ">>> Checking for Windows updates..."
Get-WindowsUpdate -AcceptAll -Install -AutoReboot:$false -Verbose
Write-Output "<<< Windows update check complete."

Write-Output ""
Write-Output ">>> Cleaning up temporary files..."
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
cleanmgr /sagerun:1 2>$null
Write-Output "<<< Cleanup complete."
