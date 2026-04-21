<#PSScriptInfo
.VERSION 0.1
.GUID 42f0a1b2-c3d4-4e56-f789-0a1b2c3d4e11
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
    Installs the Kubernetes requirements on Windows 11.
.DESCRIPTION
    Installs Git, Docker Desktop, Kubernetes (kubectl), Helm, OpenTofu, PowerShell 7,
    mkcert, Graphviz, and Cloud CLIs (Azure, AWS, Google Cloud).
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

Write-Output "=== Installing Kubernetes requirements for Windows 11 ==="

# ===== Basic Tools =====
Write-Output ""
Write-Output ">>> Installing Basic Tools (Git, OpenSSH)..."
winget install --id Git.Git --accept-source-agreements --accept-package-agreements --silent
# Enable built-in OpenSSH server
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
Write-Output "<<< Basic Tools installation complete."

# ===== PowerShell 7 (check) =====
Write-Output ""
Write-Output ">>> Checking for PowerShell 7..."
$pwshPath = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwshPath) {
    Write-Output ""
    Write-Output "╔════════════════════════════════════════════════════════════╗"
    Write-Output "║  PowerShell 7 is required but not installed.              ║"
    Write-Output "║  Run windows.11.update.ps1 first to install it.          ║"
    Write-Output "╚════════════════════════════════════════════════════════════╝"
    Write-Output ""
    exit 1
}
Write-Output "PowerShell 7 found at $($pwshPath.Source)"

# Install powershell-yaml module
Write-Output ""
Write-Output ">>> Installing PowerShell module: powershell-yaml..."
pwsh -NoProfile -Command "if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null }; Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; Install-Module -Name powershell-yaml -Scope AllUsers -Force -Confirm:`$false" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Output "Note: powershell-yaml module installation attempted" }
Write-Output "<<< PowerShell module: powershell-yaml installation complete."

# ===== Cloud CLIs =====

# Azure CLI
Write-Output ""
Write-Output ">>> Installing Azure CLI..."
winget install --id Microsoft.AzureCLI --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< Azure CLI installation complete."

# AWS CLI
Write-Output ""
Write-Output ">>> Installing AWS CLI..."
winget install --id Amazon.AWSCLI --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< AWS CLI installation complete."

# Google Cloud SDK
Write-Output ""
Write-Output ">>> Installing Google Cloud SDK..."
winget install --id Google.CloudSDK --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< Google Cloud SDK installation complete."

# ===== Docker Desktop =====
Write-Output ""
Write-Output ">>> Installing Docker Desktop..."
winget install --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< Docker Desktop installation complete."

Write-Output ""
Write-Output "NOTE: Docker Desktop requires a restart to complete setup."
Write-Output "After restart, enable Kubernetes in Docker Desktop Settings > Kubernetes > Enable Kubernetes."

# ===== Kubernetes CLI (kubectl) =====
Write-Output ""
Write-Output ">>> Installing kubectl..."
winget install --id Kubernetes.kubectl --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< kubectl installation complete."

# ===== Helm =====
Write-Output ""
Write-Output ">>> Installing Helm..."
winget install --id Helm.Helm --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< Helm installation complete."

# ===== OpenTofu =====
Write-Output ""
Write-Output ">>> Installing OpenTofu..."
winget install --id OpenTofu.Tofu --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< OpenTofu installation complete."

# ===== Graphviz =====
Write-Output ""
Write-Output ">>> Installing Graphviz..."
winget install --id Graphviz.Graphviz --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< Graphviz installation complete."

# ===== GitHub CLI =====
Write-Output ""
Write-Output ">>> Installing GitHub CLI..."
winget install --id GitHub.cli --accept-source-agreements --accept-package-agreements --silent
Write-Output "<<< GitHub CLI installation complete."

# ===== mkcert and HTTPS Development Certificate =====
# mkcert is installed last because its root CA installation may require user interaction.
Write-Output ""
Write-Output ">>> Installing mkcert..."
winget install --id FiloSottile.mkcert --accept-source-agreements --accept-package-agreements --silent
# Refresh PATH so the newly installed mkcert is discoverable
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# Generate the HTTPS development certificate first. This auto-creates the mkcert root CA
# (rootCA.pem) on first run without triggering any dialog — only 'mkcert -install' does that.
Write-Output ""
Write-Output ">>> Creating HTTPS development certificate..."
$pfxDir = Join-Path $env:USERPROFILE ".aspnet\https"
New-Item -ItemType Directory -Path $pfxDir -Force | Out-Null
$certKey = Join-Path $pfxDir "aspnetapp.key"
$certFile = Join-Path $pfxDir "aspnetapp.crt"
$pfxFile = Join-Path $pfxDir "aspnetapp.pfx"
mkcert -key-file $certKey -cert-file $certFile localhost 127.0.0.1 ::1 2>$null
if (Test-Path $certKey) {
    # Convert PEM cert + key to PFX. CreateFromPemFile requires .NET 6+ (PowerShell 7).
    # This script runs under Windows PowerShell 5.1 (.NET Framework), so delegate to pwsh.
    pwsh -NoProfile -Command "
        `$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile('$certFile', '$certKey')
        `$pfxBytes = `$cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, 'password')
        [System.IO.File]::WriteAllBytes('$pfxFile', `$pfxBytes)
    "
    if (Test-Path $pfxFile) {
        Remove-Item -Path $certKey, $certFile -Force -ErrorAction SilentlyContinue
        Write-Output "HTTPS development certificate created at $pfxFile"
    } else {
        Write-Output "Note: PFX conversion failed. Certificate PEM files remain at $pfxDir"
    }
} else {
    Write-Output "Note: mkcert certificate generation failed. Run 'mkcert -install' manually and retry."
}
Write-Output "<<< HTTPS development certificate complete."

# Install the mkcert root CA silently into the LocalMachine trusted root store.
# We avoid 'mkcert -install' because it shows an unavoidable Windows Security Warning dialog.
# Import-Certificate into LocalMachine\Root is silent when running as Administrator.
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

# ===== Refresh PATH =====
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# ===== Version Check =====
Write-Output ""
Write-Output "=== Installation Summary ==="
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

Write-Output ""
Write-Output "=== Optional Steps ==="
Write-Output "1. Restart the computer to complete Docker Desktop setup"
Write-Output "2. Enable Kubernetes in Docker Desktop Settings"
Write-Output "3. Terminal restart may be needed for PATH changes to take effect"
