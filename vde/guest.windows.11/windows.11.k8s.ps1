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
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║  This script requires elevation (Run as Administrator)    ║" -ForegroundColor Cyan
    Write-Host "║  Right-click PowerShell and select 'Run as Administrator' ║" -ForegroundColor Cyan
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    exit 1
}

Write-Host "=== Installing Kubernetes requirements for Windows 11 ==="

# ===== Basic Tools =====
Write-Host ""
Write-Host ">>> Installing Basic Tools (Git, OpenSSH)..." -ForegroundColor Cyan
winget install --id Git.Git --accept-source-agreements --accept-package-agreements --silent
# Enable built-in OpenSSH server
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
Write-Host "<<< Basic Tools installation complete." -ForegroundColor Green

# ===== PowerShell 7 (check) =====
Write-Host ""
Write-Host ">>> Checking for PowerShell 7..." -ForegroundColor Cyan
$pwshPath = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwshPath) {
    Write-Host ""
    Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║  PowerShell 7 is required but not installed.              ║" -ForegroundColor Yellow
    Write-Host "║  Run windows.11.update.ps1 first to install it.          ║" -ForegroundColor Yellow
    Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    exit 1
}
Write-Host "PowerShell 7 found at $($pwshPath.Source)" -ForegroundColor Green

# Install powershell-yaml module
Write-Host ""
Write-Host ">>> Installing PowerShell module: powershell-yaml..." -ForegroundColor Cyan
pwsh -NoProfile -Command "if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null }; Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; Install-Module -Name powershell-yaml -Scope AllUsers -Force -Confirm:`$false" 2>$null
if ($LASTEXITCODE -ne 0) { Write-Host "Note: powershell-yaml module installation attempted" }
Write-Host "<<< PowerShell module: powershell-yaml installation complete." -ForegroundColor Green

# ===== Cloud CLIs =====

# Azure CLI
Write-Host ""
Write-Host ">>> Installing Azure CLI..." -ForegroundColor Cyan
winget install --id Microsoft.AzureCLI --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< Azure CLI installation complete." -ForegroundColor Green

# AWS CLI
Write-Host ""
Write-Host ">>> Installing AWS CLI..." -ForegroundColor Cyan
winget install --id Amazon.AWSCLI --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< AWS CLI installation complete." -ForegroundColor Green

# Google Cloud SDK
Write-Host ""
Write-Host ">>> Installing Google Cloud SDK..." -ForegroundColor Cyan
winget install --id Google.CloudSDK --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< Google Cloud SDK installation complete." -ForegroundColor Green

# ===== Docker Desktop =====
Write-Host ""
Write-Host ">>> Installing Docker Desktop..." -ForegroundColor Cyan
winget install --id Docker.DockerDesktop --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< Docker Desktop installation complete." -ForegroundColor Green

Write-Host ""
Write-Host "NOTE: Docker Desktop requires a restart to complete setup." -ForegroundColor Yellow
Write-Host "After restart, enable Kubernetes in Docker Desktop Settings > Kubernetes > Enable Kubernetes." -ForegroundColor Yellow

# ===== Kubernetes CLI (kubectl) =====
Write-Host ""
Write-Host ">>> Installing kubectl..." -ForegroundColor Cyan
winget install --id Kubernetes.kubectl --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< kubectl installation complete." -ForegroundColor Green

# ===== Helm =====
Write-Host ""
Write-Host ">>> Installing Helm..." -ForegroundColor Cyan
winget install --id Helm.Helm --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< Helm installation complete." -ForegroundColor Green

# ===== OpenTofu =====
Write-Host ""
Write-Host ">>> Installing OpenTofu..." -ForegroundColor Cyan
winget install --id OpenTofu.Tofu --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< OpenTofu installation complete." -ForegroundColor Green

# ===== Graphviz =====
Write-Host ""
Write-Host ">>> Installing Graphviz..." -ForegroundColor Cyan
winget install --id Graphviz.Graphviz --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< Graphviz installation complete." -ForegroundColor Green

# ===== GitHub CLI =====
Write-Host ""
Write-Host ">>> Installing GitHub CLI..." -ForegroundColor Cyan
winget install --id GitHub.cli --accept-source-agreements --accept-package-agreements --silent
Write-Host "<<< GitHub CLI installation complete." -ForegroundColor Green

# ===== mkcert and HTTPS Development Certificate =====
# mkcert is installed last because its root CA installation may require user interaction.
Write-Host ""
Write-Host ">>> Installing mkcert..." -ForegroundColor Cyan
winget install --id FiloSottile.mkcert --accept-source-agreements --accept-package-agreements --silent
# Refresh PATH so the newly installed mkcert is discoverable
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# Generate the HTTPS development certificate first. This auto-creates the mkcert root CA
# (rootCA.pem) on first run without triggering any dialog — only 'mkcert -install' does that.
Write-Host ""
Write-Host ">>> Creating HTTPS development certificate..." -ForegroundColor Cyan
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
        Write-Host "HTTPS development certificate created at $pfxFile" -ForegroundColor Green
    } else {
        Write-Host "Note: PFX conversion failed. Certificate PEM files remain at $pfxDir" -ForegroundColor Yellow
    }
} else {
    Write-Host "Note: mkcert certificate generation failed. Run 'mkcert -install' manually and retry." -ForegroundColor Yellow
}
Write-Host "<<< HTTPS development certificate complete." -ForegroundColor Green

# Install the mkcert root CA silently into the LocalMachine trusted root store.
# We avoid 'mkcert -install' because it shows an unavoidable Windows Security Warning dialog.
# Import-Certificate into LocalMachine\Root is silent when running as Administrator.
Write-Host ""
Write-Host ">>> Installing mkcert root CA into trusted store..." -ForegroundColor Cyan
$caRoot = & mkcert -CAROOT 2>$null
$rootCert = Join-Path $caRoot "rootCA.pem"
if (Test-Path $rootCert) {
    Import-Certificate -FilePath $rootCert -CertStoreLocation Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Out-Null
    Write-Host "mkcert root CA installed silently into LocalMachine\Root store." -ForegroundColor Green
} else {
    Write-Host "Note: mkcert root CA not found at '$rootCert'. Run 'mkcert -install' manually if needed." -ForegroundColor Yellow
}
Write-Host "<<< mkcert installation complete." -ForegroundColor Green

# ===== Refresh PATH =====
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# ===== Version Check =====
Write-Host ""
Write-Host "=== Installation Summary ===" -ForegroundColor Yellow
try { git --version } catch { Write-Host "Git: restart terminal to verify" }
try { docker --version } catch { Write-Host "Docker: restart required" }
try { kubectl version --client 2>$null } catch { Write-Host "kubectl: restart terminal to verify" }
try { pwsh --version } catch { Write-Host "PowerShell 7: restart terminal to verify" }
try { helm version --short 2>$null } catch { Write-Host "Helm: restart terminal to verify" }
try { tofu version 2>$null | Select-Object -First 1 } catch { Write-Host "OpenTofu: restart terminal to verify" }
try { mkcert --version 2>$null } catch { Write-Host "mkcert: restart terminal to verify" }
try { az --version 2>$null | Select-Object -First 1 } catch { Write-Host "Azure CLI: restart terminal to verify" }
try { aws --version 2>$null } catch { Write-Host "AWS CLI: restart terminal to verify" }
try { gcloud --version 2>$null | Select-Object -First 1 } catch { Write-Host "Google Cloud SDK: restart terminal to verify" }

Write-Host ""
Write-Host "=== Optional Steps ===" -ForegroundColor Yellow
Write-Host "1. Restart the computer to complete Docker Desktop setup"
Write-Host "2. Enable Kubernetes in Docker Desktop Settings"
Write-Host "3. Terminal restart may be needed for PATH changes to take effect"
