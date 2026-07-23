<#PSScriptInfo
.VERSION 2026.07.22
.GUID 42f0a1b2-c3d4-4e56-f789-0a1b2c3d4e12
.AUTHOR Alisson Sol et al.
.COPYRIGHT (c) 2019-2026 by Alisson Sol et al.
.TAGS
.LICENSEURI https://yuruna.link/license
.PROJECTURI https://yuruna.com
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

# --- REGION: Ensure running as Administrator
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output ""
    Write-Output "=============================================================="
    Write-Output "|  This script requires elevation (Run as Administrator)    |"
    Write-Output "|  Right-click PowerShell and select 'Run as Administrator' |"
    Write-Output "=============================================================="
    Write-Output ""
    exit 1
}

# --- REGION: Install JDK (latest LTS OpenJDK, Eclipse Temurin)
Write-Output ""
Write-Output ">>> Installing JDK (latest LTS OpenJDK)..."
# winget OpenJDK/Temurin ids are all major-versioned (no float), so resolve
# the current LTS from the Adoptium API and install its MSI -- no pinned major.
$jdkArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x64' }
$jdkLts = (Invoke-RestMethod -UseBasicParsing -Uri 'https://api.adoptium.net/v3/info/available_releases').most_recent_lts
$jdkMsi = Join-Path $env:TEMP 'temurin-jdk.msi'
Invoke-WebRequest -UseBasicParsing -Uri "https://api.adoptium.net/v3/installer/latest/$jdkLts/ga/windows/$jdkArch/jdk/hotspot/normal/eclipse" -OutFile $jdkMsi
# Temurin MSI features: FeatureMain=JDK, FeatureEnvironment=add to PATH, FeatureJavaHome=set JAVA_HOME (all machine-level).
Start-Process msiexec.exe -ArgumentList "/i `"$jdkMsi`" /qn /norestart ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJavaHome" -Wait
Remove-Item $jdkMsi -Force -ErrorAction SilentlyContinue
Write-Output "<<< JDK installation complete."

# --- REGION: Install .NET SDK (latest LTS via dotnet-install.ps1)
Write-Output ""
Write-Output ">>> Installing .NET SDK..."
# winget DotNet.SDK ids are major-versioned (no float); use Microsoft's
# dotnet-install.ps1 -Channel LTS to track the current LTS with no pin.
$dotnetDir = Join-Path $env:ProgramFiles 'dotnet'
$dotnetScript = Join-Path $env:TEMP 'dotnet-install.ps1'
Invoke-WebRequest -UseBasicParsing -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $dotnetScript
& $dotnetScript -Channel LTS -InstallDir $dotnetDir
Remove-Item $dotnetScript -Force -ErrorAction SilentlyContinue
# dotnet-install.ps1 does not touch PATH/DOTNET_ROOT; register them machine-wide.
[Environment]::SetEnvironmentVariable('DOTNET_ROOT', $dotnetDir, 'Machine')
$machPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machPath -notlike "*$dotnetDir*") {
    [Environment]::SetEnvironmentVariable('Path', ($machPath.TrimEnd(';') + ';' + $dotnetDir), 'Machine')
}
Write-Output "<<< .NET SDK installation complete."

# --- REGION: Install Git
Write-Output ""
Write-Output ">>> Installing Git..."
winget install --id Git.Git --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< Git installation complete."

# --- REGION: Install Visual Studio Code
Write-Output ""
Write-Output ">>> Installing Visual Studio Code..."
winget install --id Microsoft.VisualStudioCode --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< Visual Studio Code installation complete."

# --- REGION: Install PowerShell 7
Write-Output ""
Write-Output ">>> Installing PowerShell 7..."
winget install --id Microsoft.PowerShell --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< PowerShell 7 installation complete."

# --- REGION: Install GitHub CLI
Write-Output ""
Write-Output ">>> Installing GitHub CLI..."
winget install --id GitHub.cli --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< GitHub CLI installation complete."

# --- REGION: Refresh PATH
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# --- REGION: Show installed versions
Write-Output ""
Write-Output "== Installation Summary =="
try { java --version 2>&1 | Select-Object -First 1 } catch { Write-Output "Java: restart terminal to verify" }
try { dotnet --version } catch { Write-Output ".NET: restart terminal to verify" }
try { git --version } catch { Write-Output "Git: restart terminal to verify" }
try { code --version 2>$null | Select-Object -First 1 } catch { Write-Output "VS Code: restart terminal to verify" }
try { pwsh --version } catch { Write-Output "PowerShell 7: restart terminal to verify" }
try { gh --version 2>$null | Select-Object -First 1 } catch { Write-Output "GitHub CLI: restart terminal to verify" }
