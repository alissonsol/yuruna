<#PSScriptInfo
.VERSION 2026.10.18
.GUID 42363f75-1d59-4ac0-a62f-c6d723656b28
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
    Installs the Kubernetes requirements on Windows 11.
.DESCRIPTION
    Installs Git, Docker Desktop, Kubernetes (kubectl), Helm, OpenTofu, PowerShell 7,
    mkcert, Graphviz, and Cloud CLIs (Azure, AWS, Google Cloud).
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

Write-Output "== Installing Kubernetes requirements for Windows 11 =="

# --- REGION: Install basic tools
Write-Output ""
Write-Output ">>> Installing Basic Tools (Git, OpenSSH)..."
Invoke-GuestWingetInstall -PackageId 'Git.Git'
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
Write-Output "<<< Basic Tools installation complete."

# --- REGION: Ensure PowerShell is installed
Write-Output ""
Write-Output ">>> Checking for PowerShell 7..."
$pwshPath = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwshPath) {
    Write-Output ""
    Write-Output "========"
    Write-Output "|  PowerShell 7 is required but not installed.              |"
    Write-Output "|  Run windows.11.update.ps1 first to install it.           |"
    Write-Output "========"
    Write-Output ""
    exit 1
}
Write-Output "PowerShell 7 found at $($pwshPath.Source)"

# --- REGION: Install powershell-yaml module
# See https://yuruna.link/42d69dfa-0038
Write-Output ""
Write-Output ">>> Installing PowerShell module: powershell-yaml..."
# 2.8.5.201 is Microsoft's documented TLS-1.2-capable NuGet provider
# bootstrap floor, not a workload pin.
$yamlInstall = "if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null }; Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; Install-Module -Name powershell-yaml -Scope AllUsers -Force -Confirm:`$false"
$yamlOk = $false
for ($attempt = 1; $attempt -le 3 -and -not $yamlOk; $attempt++) {
    pwsh -NoProfile -Command $yamlInstall
    # A fresh-process YAML round-trip verifies the installed module is usable.
    pwsh -NoProfile -Command "Import-Module powershell-yaml -ErrorAction Stop; if ((ConvertFrom-Yaml 'k: v').k -ne 'v') { exit 1 }"
    if ($LASTEXITCODE -eq 0) { $yamlOk = $true }
    else { Write-Output "powershell-yaml install/import attempt $attempt/3 failed; retrying..."; Start-Sleep -Seconds ($attempt * 5) }
}
if (-not $yamlOk) {
    Write-Error "powershell-yaml failed to install/import after 3 attempts; it is required by the in-guest sequence planner and Get-SystemDiagnostic.ps1."
    exit 1
}
Write-Output "<<< PowerShell module: powershell-yaml installation complete."

# --- REGION: Install cloud CLIs
# See https://yuruna.link/42a76c30-0008
Write-Output ""
Write-Output ">>> Installing Azure CLI..."
Invoke-GuestWingetInstall -PackageId 'Microsoft.AzureCLI'
Write-Output "<<< Azure CLI installation complete."

Write-Output ""
Write-Output ">>> Installing AWS CLI..."
Invoke-GuestWingetInstall -PackageId 'Amazon.AWSCLI'
Write-Output "<<< AWS CLI installation complete."

Write-Output ""
Write-Output ">>> Installing Google Cloud SDK..."
Invoke-GuestWingetInstall -PackageId 'Google.CloudSDK'
Write-Output "<<< Google Cloud SDK installation complete."

# --- REGION: Install Docker
Write-Output ""
Write-Output ">>> Installing Docker Desktop..."
Invoke-GuestWingetInstall -PackageId 'Docker.DockerDesktop'
Write-Output "<<< Docker Desktop installation complete."

Write-Output ""
Write-Output "NOTE: Docker Desktop requires a restart to complete setup."
Write-Output "After restart, enable Kubernetes in Docker Desktop Settings > Kubernetes > Enable Kubernetes."

# --- REGION: Install kubectl
Write-Output ""
Write-Output ">>> Installing kubectl..."
Invoke-GuestWingetInstall -PackageId 'Kubernetes.kubectl'
Write-Output "<<< kubectl installation complete."

# --- REGION: Install Helm
Write-Output ""
Write-Output ">>> Installing Helm..."
Invoke-GuestWingetInstall -PackageId 'Helm.Helm'
Write-Output "<<< Helm installation complete."

# --- REGION: Install OpenTofu
Write-Output ""
Write-Output ">>> Installing OpenTofu..."
Invoke-GuestWingetInstall -PackageId 'OpenTofu.Tofu'
Write-Output "<<< OpenTofu installation complete."

# --- REGION: Install Graphviz
# See https://yuruna.link/42a76c30-0008
Write-Output ""
Write-Output ">>> Installing Graphviz..."
Invoke-GuestWingetInstall -PackageId 'Graphviz.Graphviz'
Write-Output "<<< Graphviz installation complete."

# --- REGION: Install GitHub CLI
Write-Output ""
Write-Output ">>> Installing GitHub CLI..."
Invoke-GuestWingetInstall -PackageId 'GitHub.cli'
Write-Output "<<< GitHub CLI installation complete."

# --- REGION: Install mkcert
# mkcert is installed last because its root CA installation may require user interaction.
Write-Output ""
Write-Output ">>> Installing mkcert..."
Invoke-GuestWingetInstall -PackageId 'FiloSottile.mkcert'

# --- REGION: Refresh PATH
# mkcert was just installed and must be discoverable for the certificate work below.
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# --- REGION: Create the HTTPS development certificate
# Generate the HTTPS development certificate first. This auto-creates the mkcert root CA
# (rootCA.pem) on first run without triggering any dialog -- only 'mkcert -install' does that.
Write-Output ""
Write-Output ">>> Creating HTTPS development certificate..."
$pfxDir = Join-Path $env:USERPROFILE ".aspnet\https"
New-Item -ItemType Directory -Path $pfxDir -Force -ErrorAction Stop | Out-Null
$certKey = Join-Path $pfxDir "aspnetapp.key"
$certFile = Join-Path $pfxDir "aspnetapp.crt"
$pfxFile = Join-Path $pfxDir "aspnetapp.pfx"
$pfxPasswordFile = "$pfxFile.password"
foreach ($pemFile in @($certKey, $certFile)) {
    if (Test-Path -LiteralPath $pemFile) {
        if (-not (Test-Path -LiteralPath $pemFile -PathType Leaf)) { throw "Expected a certificate file at $pemFile." }
        Remove-Item -LiteralPath $pemFile -Force -ErrorAction Stop
    }
}
try {
    mkcert -key-file $certKey -cert-file $certFile localhost 127.0.0.1 ::1
} catch {
    throw "HTTPS development certificate generation failed: $($_.Exception.Message)"
}
if ($LASTEXITCODE -ne 0) { throw "HTTPS development certificate generation failed (mkcert exit code $LASTEXITCODE)." }
foreach ($pemFile in @($certKey, $certFile)) {
    if (-not (Test-Path -LiteralPath $pemFile -PathType Leaf) -or (Get-Item -LiteralPath $pemFile -ErrorAction Stop).Length -eq 0) {
        throw "HTTPS development certificate generation did not produce a nonempty PEM file at $pemFile."
    }
}
try {
    # See https://yuruna.link/42e220c4-0005
    # An earlier PFX pair must not satisfy this export's success gate.
    foreach ($exportFile in @($pfxFile, $pfxPasswordFile)) {
        if (Test-Path -LiteralPath $exportFile) {
            if (-not (Test-Path -LiteralPath $exportFile -PathType Leaf)) { throw "Expected a certificate file at $exportFile." }
            Remove-Item -LiteralPath $exportFile -Force -ErrorAction Stop
        }
    }
    # See https://yuruna.link/42e220c4-0005
    # PowerShell 7 creates the PFX and restricts its password file before writing.
    pwsh -NoProfile -Command "
        `$ErrorActionPreference = 'Stop'
        `$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile('$($certFile.Replace("'", "''"))', '$($certKey.Replace("'", "''"))')
        `$password = [Convert]::ToHexString([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
        `$pfxBytes = `$cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, `$password)
        New-Item -ItemType File -Path '$($pfxPasswordFile.Replace("'", "''"))' | Out-Null
        `$acl = Get-Acl -LiteralPath '$($pfxPasswordFile.Replace("'", "''"))'
        `$acl.SetAccessRuleProtection(`$true, `$false)
        `$acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl', 'Allow'))
        Set-Acl -LiteralPath '$($pfxPasswordFile.Replace("'", "''"))' -AclObject `$acl
        [System.IO.File]::WriteAllText('$($pfxPasswordFile.Replace("'", "''"))', `$password + [char]10)
        [System.IO.File]::WriteAllBytes('$($pfxFile.Replace("'", "''"))', `$pfxBytes)
    "
    if ($LASTEXITCODE -ne 0) { throw "HTTPS development certificate PFX conversion failed (pwsh exit code $LASTEXITCODE)." }
    foreach ($exportFile in @($pfxFile, $pfxPasswordFile)) {
        if (-not (Test-Path -LiteralPath $exportFile -PathType Leaf) -or (Get-Item -LiteralPath $exportFile -ErrorAction Stop).Length -eq 0) {
            throw "HTTPS development certificate export did not produce a nonempty file at $exportFile."
        }
    }
} catch {
    foreach ($exportFile in @($pfxFile, $pfxPasswordFile)) {
        if (Test-Path -LiteralPath $exportFile -PathType Leaf) { Remove-Item -LiteralPath $exportFile -Force -ErrorAction SilentlyContinue }
    }
    throw
}
Remove-Item -LiteralPath $certKey, $certFile -Force -ErrorAction Stop
Write-Output "HTTPS development certificate created at $pfxFile"
Write-Output "Its password is kept beside it in $pfxPasswordFile, readable only by the current user."
Write-Output "<<< HTTPS development certificate complete."

# --- REGION: Install the mkcert root CA
# Import-Certificate avoids mkcert's interactive Windows Security Warning.
Write-Output ""
Write-Output ">>> Installing mkcert root CA into trusted store..."
$caRoot = & mkcert -CAROOT 2>$null
$rootCert = Join-Path $caRoot "rootCA.pem"
if (Test-Path $rootCert) {
    Import-Certificate -FilePath $rootCert -CertStoreLocation Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Out-Null
    Write-Output "mkcert root CA installed silently into LocalMachine\Root store."
} else {
    Write-Output "Note: mkcert root CA not found at '$rootCert'. Run 'mkcert -install' manually if needed."
}
Write-Output "<<< mkcert installation complete."

# --- REGION: Refresh PATH
# Second refresh: winget put the remaining tools on the machine PATH after the first one.
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# --- REGION: Installation summary
Write-Output ""
Write-Output "== Installation Summary =="
try { git --version } catch { Write-Output "Git: restart terminal to verify" }
try { docker --version } catch { Write-Output "Docker: restart required" }
try { kubectl version --client 2>$null } catch { Write-Output "kubectl: restart terminal to verify" }
try { pwsh --version } catch { Write-Output "PowerShell 7: restart terminal to verify" }
try { helm version --short 2>$null } catch { Write-Output "Helm: restart terminal to verify" }
try { tofu version 2>$null | Select-Object -First 1 } catch { Write-Output "OpenTofu: restart terminal to verify" }
try { mkcert --version 2>$null } catch { Write-Output "mkcert: restart terminal to verify" }
try { az --version 2>$null | Select-Object -First 1 } catch { Write-Output "Azure CLI: restart terminal to verify" }
try { aws --version 2>$null } catch { Write-Output "AWS CLI: restart terminal to verify" }
try { gcloud --version 2>$null | Select-Object -First 1 } catch { Write-Output "Google Cloud SDK: restart terminal to verify" }

# --- REGION: Optional steps
Write-Output ""
Write-Output "== Optional Steps =="
Write-Output "1. Restart the computer to complete Docker Desktop setup"
Write-Output "2. Enable Kubernetes in Docker Desktop Settings"
Write-Output "3. Terminal restart may be needed for PATH changes to take effect"
