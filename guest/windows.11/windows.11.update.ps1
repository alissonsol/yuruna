<#PSScriptInfo
.VERSION 2026.06.30
.GUID 42f0a1b2-c3d4-4e56-f789-0a1b2c3d4e10
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
    Updates Windows 11 system packages.
.DESCRIPTION
    Installs Windows updates, updates winget packages, and performs system cleanup.
    Run this script in an elevated PowerShell terminal.
#>

# ===== Ensure running as Administrator =====
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Output ""
    Write-Output "=============================================================="
    Write-Output "|  This script requires elevation (Run as Administrator)    |"
    Write-Output "|  Right-click PowerShell and select 'Run as Administrator' |"
    Write-Output "=============================================================="
    Write-Output ""
    exit 1
}

# ===== Ensure execution policy allows scripts =====
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force

# ===== Detect architecture =====
$arch = $env:PROCESSOR_ARCHITECTURE
Write-Output "Detected architecture: $arch"
switch ($arch) {
    'AMD64' { Write-Output 'Environment: x86_64/amd64 (Hyper-V)' }
    'ARM64' { Write-Output 'Environment: arm64 (UTM on Apple Silicon / Surface Pro X)' }
    default {
        Write-Output "WARNING: Unsupported architecture: $arch"
        Write-Output "This script supports AMD64 (Hyper-V) and ARM64 (UTM on Apple Silicon)."
        exit 1
    }
}

# ===== Ensure PowerShell is installed =====
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

# ===== Install powershell-yaml module =====
# Installed for all users via pwsh 7 (not Windows PowerShell 5.1) so the
# module lands in the same PSModulePath the in-guest sequence planner and
# Get-SystemDiagnostic.ps1 use. Administrator elevation (checked at the
# top of this script) makes `-Scope AllUsers` succeed without an
# interactive UAC prompt. The trailing Import-Module check guards
# against the case where the manifest landed but the module won't load
# (which Install-Module reports as success).
Write-Output ""
Write-Output ">>> Installing PowerShell module: powershell-yaml..."
pwsh -NoProfile -Command "Install-Module -Name powershell-yaml -Scope AllUsers -Force"
pwsh -NoProfile -Command "Import-Module powershell-yaml; ConvertFrom-Yaml 'k: v' | Out-Null"
Write-Output "<<< PowerShell module: powershell-yaml installation complete."

# ===== Early yuruna framework extraction (host-side diagnostic prereq) =====
# The host's failure-path diagnostic shells back as
# `pwsh -NoProfile -File $HOME/yuruna/automation/Get-SystemDiagnostic.ps1`.
# If a later step in this script stalls the cycle watchdog fires, the
# orchestrator captures diagnostics, and that script must already be
# on disk -- else pwsh exits 64 and writes its usage banner instead of
# real guest state. Tarball-only here; the git-clone fallback lives in
# the late Materialize section below (which needs `git`, which winget
# may install in the Update system packages stage that follows).
# YURUNA_HOST_IP / YURUNA_HOST_PORT come from the host.env injection
# mechanism the Linux guests use, mapped to a Windows-side equivalent
# (C:\ProgramData\yuruna\host.env) when the host driver supports it;
# until then this block soft-fails (no env vars => no-op).
Write-Output ""
Write-Output ">>> Pre-fetching yuruna framework tarball (for diagnostic availability)..."
$yurunaRoot = Join-Path $env:USERPROFILE 'yuruna'
$hostEnv    = 'C:\ProgramData\yuruna\host.env'
if (Test-Path -LiteralPath $hostEnv -PathType Leaf) {
    Get-Content -LiteralPath $hostEnv | ForEach-Object {
        if ($_ -match '^\s*([A-Z_]+)\s*=\s*"?([^"]*)"?\s*$') {
            Set-Item -Path "env:$($Matches[1])" -Value $Matches[2]
        }
    }
}
if ($env:YURUNA_HOST_IP -and $env:YURUNA_HOST_PORT -and -not (Test-Path -LiteralPath $yurunaRoot -PathType Container)) {
    $livecheckUrl = "http://$($env:YURUNA_HOST_IP):$($env:YURUNA_HOST_PORT)/livecheck"
    $tarballUrl   = "http://$($env:YURUNA_HOST_IP):$($env:YURUNA_HOST_PORT)/yuruna-archive.tar.gz"
    try {
        # Livecheck probe: HEAD-equivalent via -Method Head so a present-but-
        # large /livecheck response isn't pulled into memory; status 200 is
        # the only success path we accept.
        $null = Invoke-WebRequest -Uri $livecheckUrl -Method Head -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        New-Item -ItemType Directory -Path $yurunaRoot -Force | Out-Null
        $tarPath = Join-Path $env:TEMP 'yuruna-archive.tar.gz'
        Invoke-WebRequest -Uri $tarballUrl -UseBasicParsing -OutFile $tarPath -ErrorAction Stop
        # tar.exe (bsdtar) ships in-box since Windows 10 1803 and reads .tar.gz directly.
        tar.exe -xzf $tarPath -C $yurunaRoot
        Remove-Item -LiteralPath $tarPath -Force -ErrorAction SilentlyContinue
        Write-Output "<<< Yuruna framework available at $yurunaRoot (early extract)."
    } catch {
        if (Test-Path -LiteralPath $yurunaRoot) { Remove-Item -LiteralPath $yurunaRoot -Recurse -Force -ErrorAction SilentlyContinue }
        Write-Output "yuruna: early tarball fetch failed -- $($_.Exception.Message)"
    }
} else {
    Write-Output "yuruna: host.env not present or yuruna already extracted -- skipping early extract."
}

# ===== Disable services that may suspend the machine =====
# Mirrors the Linux `systemctl mask sleep.target ...` block. Test cycles
# must not be interrupted by standby/hibernate/monitor-off. powercfg
# applies to the active power scheme; `/hibernate off` disables the
# feature entirely (and frees hiberfil.sys). 2>$null because /hibernate
# off prints a non-fatal "Hibernation is already disabled" line in
# environments where the BIOS already disabled it.
Write-Output ""
Write-Output "TESTHACK: Disabling services that may suspend the machine."
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change standby-timeout-dc 0 | Out-Null
powercfg /change hibernate-timeout-ac 0 | Out-Null
powercfg /change hibernate-timeout-dc 0 | Out-Null
powercfg /change monitor-timeout-ac 0 | Out-Null
powercfg /change monitor-timeout-dc 0 | Out-Null
powercfg /hibernate off 2>$null

# ===== Update system packages =====
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

# ===== Ensure Git is installed =====
Write-Output ""
Write-Output ">>> Ensuring Git is installed..."
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    winget install --id Git.Git --accept-source-agreements --accept-package-agreements --silent
    # Refresh PATH so the newly installed git is discoverable in the
    # current session (winget writes to Machine PATH but the live $env:Path
    # doesn't pick it up until reload).
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')
}
git --version
Write-Output "<<< Git ready."

# ===== Materialize the yuruna framework and project repos =====
# --- See https://yuruna.link/definition#defining-the-two-source-scheme-for-framework-and-project-urls
# Two-stage materialization, identical in spirit to the Linux scripts:
#   1. Tarball from the host status server when YURUNA_HOST_IP/PORT are
#      set (typically populated by C:\ProgramData\yuruna\host.env --
#      the early-extract block above reads the same file).
#   2. git clone of FRAMEWORK_URL / PROJECT_URL when the tarball path
#      isn't available or fails, with the URLs sourced from the host
#      status server's /control/test-config JSON endpoint.
# The $yurunaRoot existence guards make this a no-op when the early
# extract already succeeded.
$frameworkUrl = ''
$projectUrl   = ''
if ($env:YURUNA_HOST_IP -and $env:YURUNA_HOST_PORT) {
    $cfgUrl = "http://$($env:YURUNA_HOST_IP):$($env:YURUNA_HOST_PORT)/control/test-config"
    try {
        $cfg = Invoke-RestMethod -Uri $cfgUrl -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        if ($cfg.repositories.frameworkUrl) { $frameworkUrl = [string]$cfg.repositories.frameworkUrl }
        if ($cfg.repositories.projectUrl)   { $projectUrl   = [string]$cfg.repositories.projectUrl }
    } catch {
        Write-Output "yuruna: /control/test-config unreachable -- git clone fallback may not have URLs."
    }
}

if (-not (Test-Path -LiteralPath $yurunaRoot -PathType Container)) {
    $hostOk = $false
    if ($env:YURUNA_HOST_IP -and $env:YURUNA_HOST_PORT) {
        $livecheckUrl = "http://$($env:YURUNA_HOST_IP):$($env:YURUNA_HOST_PORT)/livecheck"
        $tarballUrl   = "http://$($env:YURUNA_HOST_IP):$($env:YURUNA_HOST_PORT)/yuruna-archive.tar.gz"
        try {
            $null = Invoke-WebRequest -Uri $livecheckUrl -Method Head -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            Write-Output "yuruna: fetching committed tarball from $tarballUrl"
            New-Item -ItemType Directory -Path $yurunaRoot -Force | Out-Null
            $tarPath = Join-Path $env:TEMP 'yuruna-archive.tar.gz'
            Invoke-WebRequest -Uri $tarballUrl -UseBasicParsing -OutFile $tarPath -ErrorAction Stop
            tar.exe -xzf $tarPath -C $yurunaRoot
            Remove-Item -LiteralPath $tarPath -Force -ErrorAction SilentlyContinue
            $hostOk = $true
        } catch {
            Write-Output "yuruna: tarball fetch/extract failed - falling back to git clone"
            if (Test-Path -LiteralPath $yurunaRoot) { Remove-Item -LiteralPath $yurunaRoot -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    if (-not $hostOk) {
        if (-not $frameworkUrl) {
            Write-Error 'yuruna: repositories.frameworkUrl missing from test.config.yml - cannot clone framework'
            exit 1
        }
        $cloned = $false
        for ($attempt = 1; $attempt -le 3 -and -not $cloned; $attempt++) {
            git clone $frameworkUrl $yurunaRoot
            if ($LASTEXITCODE -eq 0) { $cloned = $true; break }
            Write-Output "git clone attempt $attempt failed"
            if (Test-Path -LiteralPath $yurunaRoot) { Remove-Item -LiteralPath $yurunaRoot -Recurse -Force -ErrorAction SilentlyContinue }
            if ($attempt -lt 3) { Start-Sleep -Seconds 60 }
        }
        if (-not $cloned) {
            Write-Error 'git clone failed after 3 attempts'
            exit 1
        }
    }
}

$yurunaProject = Join-Path $yurunaRoot 'project'
if (-not (Test-Path -LiteralPath $yurunaProject -PathType Container)) {
    $projectHostOk = $false
    if ($env:YURUNA_HOST_IP -and $env:YURUNA_HOST_PORT) {
        $projectTarballUrl = "http://$($env:YURUNA_HOST_IP):$($env:YURUNA_HOST_PORT)/yuruna-project-archive.tar.gz"
        Write-Output "yuruna: trying project tarball at $projectTarballUrl"
        try {
            New-Item -ItemType Directory -Path $yurunaProject -Force | Out-Null
            $tarPath = Join-Path $env:TEMP 'yuruna-project-archive.tar.gz'
            Invoke-WebRequest -Uri $projectTarballUrl -UseBasicParsing -OutFile $tarPath -ErrorAction Stop
            tar.exe -xzf $tarPath -C $yurunaProject
            Remove-Item -LiteralPath $tarPath -Force -ErrorAction SilentlyContinue
            if (Get-ChildItem -LiteralPath $yurunaProject -Force -ErrorAction SilentlyContinue) {
                $projectHostOk = $true
            } else {
                throw 'tarball produced empty project directory'
            }
        } catch {
            Write-Output "yuruna: project tarball not served (or empty) - falling back to git clone"
            if (Test-Path -LiteralPath $yurunaProject) { Remove-Item -LiteralPath $yurunaProject -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    if (-not $projectHostOk -and $projectUrl) {
        $cloned = $false
        for ($attempt = 1; $attempt -le 3 -and -not $cloned; $attempt++) {
            git clone $projectUrl $yurunaProject
            if ($LASTEXITCODE -eq 0) { $cloned = $true; break }
            Write-Output "project git clone attempt $attempt failed"
            if (Test-Path -LiteralPath $yurunaProject) { Remove-Item -LiteralPath $yurunaProject -Recurse -Force -ErrorAction SilentlyContinue }
            if ($attempt -lt 3) { Start-Sleep -Seconds 60 }
        }
        if (-not $cloned) {
            Write-Error 'project git clone failed after 3 attempts'
            exit 1
        }
    }
}

# ===== Clean up temporary files =====
Write-Output ""
Write-Output ">>> Cleaning up temporary files..."
Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
cleanmgr /sagerun:1 2>$null
Write-Output "<<< Cleanup complete."
