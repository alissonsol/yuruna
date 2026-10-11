<#PSScriptInfo
.VERSION 2026.10.11.1
.GUID 42c2bf4c-4df0-494d-8571-5945ed9ab682
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
    Write-Output "========"
    Write-Output "|  This script requires elevation (Run as Administrator)    |"
    Write-Output "|  Right-click PowerShell and select 'Run as Administrator' |"
    Write-Output "========"
    Write-Output ""
    exit 1
}

# See https://yuruna.link/42e220c4-0005
# --- REGION: Invoke-GuestWingetInstall
function Invoke-GuestWingetInstall {
    <#
    .SYNOPSIS
        Install a prerequisite or accept its documented already-present outcome.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PackageId)
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    $global:LASTEXITCODE = $null
    try {
        & winget install --id $PackageId --accept-source-agreements --accept-package-agreements --silent
        $wingetSucceeded = $?
        $wingetNativeExitCode = $global:LASTEXITCODE
    } catch {
        throw
    }
    $wingetExitCode = 0L
    if ($null -eq $wingetNativeExitCode -or -not [long]::TryParse([string]$wingetNativeExitCode, [ref]$wingetExitCode) -or $wingetExitCode -lt -2147483648 -or $wingetExitCode -gt 4294967295) {
        throw "Package installation failed for $PackageId without a valid native exit code."
    }
    if ($wingetExitCode -ge 2147483648) { $wingetExitCode -= 4294967296 }
    if ($wingetExitCode -notin @(0, -1978335189, -1978335135) -or ($wingetExitCode -eq 0 -and -not $wingetSucceeded)) {
        throw "Package installation failed for $PackageId (winget exit code $wingetExitCode)."
    }
}

# --- REGION: Install JDK
Write-Output ""
Write-Output ">>> Installing JDK (latest LTS OpenJDK)..."
# winget OpenJDK/Temurin ids are all major-versioned (no float), so resolve
# the current LTS from the Adoptium API and install its MSI -- no pinned major.
# See https://yuruna.link/42e220c4-0015
# CIM reports native ARM64 (12) even under Windows PowerShell 5.1 emulation.
$jdkProcessor = Get-CimInstance -ClassName Win32_Processor -Property Architecture -ErrorAction Stop | Select-Object -First 1
if ($null -eq $jdkProcessor) { throw 'Cannot determine the native processor architecture for the JDK installer.' }
$jdkArch = switch ($jdkProcessor.Architecture) {
    9 { 'x64' }
    12 { 'aarch64' }
    default { throw "Unsupported native processor architecture for the JDK installer: $($jdkProcessor.Architecture)." }
}
$jdkLts = (Invoke-RestMethod -UseBasicParsing -Uri 'https://api.adoptium.net/v3/info/available_releases' -ErrorAction Stop).most_recent_lts
$jdkMsi = Join-Path $env:TEMP 'temurin-jdk.msi'
try {
    if (Test-Path -LiteralPath $jdkMsi) {
        if (-not (Test-Path -LiteralPath $jdkMsi -PathType Leaf)) { throw "Expected a JDK installer file at $jdkMsi." }
        Remove-Item -LiteralPath $jdkMsi -Force -ErrorAction Stop
    }
    Invoke-WebRequest -UseBasicParsing -Uri "https://api.adoptium.net/v3/installer/latest/$jdkLts/ga/windows/$jdkArch/jdk/hotspot/normal/eclipse" -OutFile $jdkMsi -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $jdkMsi -PathType Leaf) -or (Get-Item -LiteralPath $jdkMsi -ErrorAction Stop).Length -eq 0) {
        throw 'The JDK download did not produce a nonempty installer file.'
    }
    # See https://yuruna.link/42e220c4-0005
    # These features set the machine PATH and JAVA_HOME alongside the JDK.
    $jdkInstall = Start-Process msiexec.exe -ArgumentList "/i `"$jdkMsi`" /qn /norestart ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJavaHome" -Wait -PassThru -ErrorAction Stop
    if ($null -eq $jdkInstall -or $null -eq $jdkInstall.ExitCode) { throw 'The JDK installer returned no process outcome.' }
    if ($jdkInstall.ExitCode -notin @(0, 1641, 3010)) { throw "JDK installation failed (msiexec exit code $($jdkInstall.ExitCode))." }
    if ($jdkInstall.ExitCode -ne 0) { Write-Warning "The JDK installation requires a restart (msiexec exit code $($jdkInstall.ExitCode))." }
} finally {
    if (Test-Path -LiteralPath $jdkMsi -PathType Leaf) { Remove-Item -LiteralPath $jdkMsi -Force -ErrorAction SilentlyContinue }
}
Write-Output "<<< JDK installation complete."

# --- REGION: Install .NET SDK
Write-Output ""
Write-Output ">>> Installing .NET SDK..."
# See https://yuruna.link/42e220c4-0005
# Use Microsoft's installer to follow the current .NET LTS channel.
$dotnetDir = Join-Path $env:ProgramFiles 'dotnet'
$dotnetScript = Join-Path $env:TEMP 'dotnet-install.ps1'
try {
    if (Test-Path -LiteralPath $dotnetScript) {
        if (-not (Test-Path -LiteralPath $dotnetScript -PathType Leaf)) { throw "Expected a .NET installer file at $dotnetScript." }
        Remove-Item -LiteralPath $dotnetScript -Force -ErrorAction Stop
    }
    Invoke-WebRequest -UseBasicParsing -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $dotnetScript -ErrorAction Stop
    if (-not (Test-Path -LiteralPath $dotnetScript -PathType Leaf) -or (Get-Item -LiteralPath $dotnetScript -ErrorAction Stop).Length -eq 0) {
        throw 'The .NET download did not produce a nonempty installer file.'
    }
    $global:LASTEXITCODE = 0
    & $dotnetScript -Channel LTS -InstallDir $dotnetDir -ErrorAction Stop
    $dotnetInstallSucceeded = $?
    $dotnetInstallExitCode = $global:LASTEXITCODE
    if (-not $dotnetInstallSucceeded -or $dotnetInstallExitCode -ne 0) { throw ".NET installation failed (installer exit code $dotnetInstallExitCode)." }
} catch {
    throw
} finally {
    if (Test-Path -LiteralPath $dotnetScript -PathType Leaf) { Remove-Item -LiteralPath $dotnetScript -Force -ErrorAction SilentlyContinue }
}
# Register machine-wide PATH and DOTNET_ROOT after the SDK installation succeeds.
[Environment]::SetEnvironmentVariable('DOTNET_ROOT', $dotnetDir, 'Machine')
$machPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if ($machPath -notlike "*$dotnetDir*") {
    [Environment]::SetEnvironmentVariable('Path', ($machPath.TrimEnd(';') + ';' + $dotnetDir), 'Machine')
}
Write-Output "<<< .NET SDK installation complete."

# --- REGION: Install Git
Write-Output ""
Write-Output ">>> Installing Git..."
Invoke-GuestWingetInstall -PackageId 'Git.Git'
Write-Output "<<< Git installation complete."

# --- REGION: Install Visual Studio Code
Write-Output ""
Write-Output ">>> Installing Visual Studio Code..."
Invoke-GuestWingetInstall -PackageId 'Microsoft.VisualStudioCode'
Write-Output "<<< Visual Studio Code installation complete."

# --- REGION: Ensure PowerShell is installed
Write-Output ""
Write-Output ">>> Installing PowerShell 7..."
Invoke-GuestWingetInstall -PackageId 'Microsoft.PowerShell'
Write-Output "<<< PowerShell 7 installation complete."

# --- REGION: Install GitHub CLI
Write-Output ""
Write-Output ">>> Installing GitHub CLI..."
Invoke-GuestWingetInstall -PackageId 'GitHub.cli'
Write-Output "<<< GitHub CLI installation complete."

# --- REGION: Refresh PATH
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# --- REGION: Installation summary
Write-Output ""
Write-Output "== Installation Summary =="
try { java --version 2>&1 | Select-Object -First 1 } catch { Write-Output "Java: restart terminal to verify" }
try { dotnet --version } catch { Write-Output ".NET: restart terminal to verify" }
try { git --version } catch { Write-Output "Git: restart terminal to verify" }
try { code --version 2>$null | Select-Object -First 1 } catch { Write-Output "VS Code: restart terminal to verify" }
try { pwsh --version } catch { Write-Output "PowerShell 7: restart terminal to verify" }
try { gh --version 2>$null | Select-Object -First 1 } catch { Write-Output "GitHub CLI: restart terminal to verify" }
